# 14 — Backlight Architecture

How display and keyboard backlight control actually work on this machine, from
the key you press down to the photons the panel emits.

This is the **concept** document. It explains the mechanisms.
`docs/13-display-and-keyboard-backlight.md` is the **incident** document: what
broke on 2026-08-14, how it was diagnosed, and what was changed.

Read this one if you want to understand the stack, reason about a new symptom,
or judge whether a proposed fix addresses the right layer. Read 13 if you want
the specific fault and its remedy.

---

## Contents

1. [Why this document exists](#1-why-this-document-exists)
2. [The display backlight stack](#2-the-display-backlight-stack)
3. [The two eDP backlight transports](#3-the-two-edp-backlight-transports)
4. [How the kernel chooses an interface](#4-how-the-kernel-chooses-an-interface)
5. [The Linux backlight class](#5-the-linux-backlight-class)
6. [Everything above the kernel](#6-everything-above-the-kernel)
7. [The keyboard backlight stack](#7-the-keyboard-backlight-stack)
8. [Failure modes and how to tell them apart](#8-failure-modes-and-how-to-tell-them-apart)
9. [Diagnostic method — descending the stack](#9-diagnostic-method--descending-the-stack)
10. [Quick reference](#10-quick-reference)

---

## 1. Why this document exists

The central lesson of the 2026-08-14 incident is this:

> **Acknowledgement is not actuation.**

Every layer of the backlight stack will happily accept a value, store it, report
it back to you correctly, and pass it downward — regardless of whether the
hardware at the bottom does anything with it. There is no error propagation.
Nothing returns `EIO` when a panel ignores a brightness write.

That means the usual diagnostic instinct — check the setting, confirm it reads
back correctly, conclude the setting is fine — **actively misleads you here**.
During the incident, `sysfs` read `1023/1023`, `xrandr` reported `Brightness:
1.0`, the panel's own DPCD register read `0x03FF` full scale, and the screen was
too dim to use. Every indicator was green. All of them were true. None of them
meant the backlight was working.

The only reliable diagnostic is **a change you can see**, correlated with a
change you deliberately made. Everything in this document is ultimately in
service of finding which layer stops propagating that change.

---

## 2. The display backlight stack

```
   ┌──────────────────────────────────────────────────────────────┐
   │  Fn+F6 / Fn+F7                                               │
   │    → ACPI video bus  OR  dell-wmi hotkey → input event       │  user intent
   └───────────────────────────┬──────────────────────────────────┘
                               │  KEY_BRIGHTNESSDOWN / _UP
   ┌───────────────────────────▼──────────────────────────────────┐
   │  csd-power  (Cinnamon settings daemon)                       │
   │    via RandR Backlight property, else                        │  desktop
   │    via pkexec csd-backlight-helper → sysfs                   │
   └───────────────────────────┬──────────────────────────────────┘
   ┌───────────────────────────▼──────────────────────────────────┐
   │  /sys/class/backlight/intel_backlight/brightness             │  kernel ABI
   │    type: raw | platform | firmware                           │
   └───────────────────────────┬──────────────────────────────────┘
   ┌───────────────────────────▼──────────────────────────────────┐
   │  i915 backlight backend — CHOOSES ONE:                       │
   │    (a) native PCH PWM pin                                    │  ◀ the fork
   │    (b) eDP DPCD AUX  (VESA, or Intel HDR)                    │    that broke
   └──────────────┬──────────────────────────┬────────────────────┘
                  │ (a) PWM duty cycle       │ (b) AUX transaction
   ┌──────────────▼──────────────────────────▼────────────────────┐
   │  Panel TCON (timing controller) — decides which input to     │  hardware
   │  obey, based on its BL_CONTROL_MODE register                 │
   └───────────────────────────┬──────────────────────────────────┘
   ┌───────────────────────────▼──────────────────────────────────┐
   │  LED driver → backlight → photons                            │
   └──────────────────────────────────────────────────────────────┘
```

The fault in `docs/13` lived at the marked fork: the kernel chose (b), the panel
was listening on (a), and **neither side reported an error**.

---

## 3. The two eDP backlight transports

An embedded DisplayPort panel can be dimmed by two entirely separate physical
mechanisms. This is the single most important concept in this document.

### 3.1 The PWM pin (native)

A dedicated hardware pin on the display controller carries a square wave. The
panel's backlight driver averages the duty cycle: 100 % duty is full brightness,
10 % duty is dim. The PCH generates it; the panel just follows the wire.

- **Level range** is whatever the PWM counter's period register allows —
  typically some thousands of steps. `max_brightness` reflects it directly.
- **Frequency** is set from the VBT; too low and the panel visibly flickers.
- The panel does not need to understand anything. It follows the pin.

### 3.2 The AUX channel (DPCD)

DisplayPort carries a low-speed bidirectional side channel called AUX. Brightness
is set by **writing registers in the panel's DPCD address space** and asking the
panel's own timing controller to do the dimming internally.

Two competing register sets exist:

| Interface | Registers | Notes |
|---|---|---|
| **VESA eDP standard** | `0x720`–`0x72F` | The portable one. Used here. |
| **Intel HDR / "custom"** | `0x340`–`0x36F` | Intel-specific. **Not supported by this panel — the block reads all zeros.** |

The critical register is `0x721`, `EDP_BACKLIGHT_MODE_SET`. Its low two bits tell
the panel **which transport to obey**:

| `0x721 & 0x03` | Panel obeys |
|---|---|
| `0` | the PWM pin |
| `2` | the DPCD brightness registers (`0x722`/`0x723`) |

### 3.3 Why this is the fragile part

Both sides must agree. If the driver writes brightness over AUX while the panel
is in PWM-pin mode, the writes land in registers the panel is not reading. If the
driver drives the PWM pin while the panel is in AUX mode, the pin is ignored.

**In neither case is an error raised.** AUX writes are acknowledged at the
transaction layer — the panel confirms it *received* the bytes, which says
nothing about whether it *acts* on them. That acknowledgement is what makes
`0x722/0x723` read back a perfectly correct `0x03FF` on a panel that is ignoring
the value entirely.

On this machine, kernel 7.0 set `0x721 = 0x0a` (AUX mode) and wrote levels over
AUX, and the panel did not respond to them. Forcing `0x721 = 0x08` (PWM pin) made
the panel bright immediately, because the firmware had left the PWM pin at a high
duty.

---

## 4. How the kernel chooses an interface

### 4.1 First choice — which *class* of backlight

Before i915 is even consulted, the kernel decides which kind of backlight device
should exist, via `acpi_video_get_backlight_type()`. Three types, in descending
priority:

| Type | Device | Meaning |
|---|---|---|
| `firmware` | `acpi_video0` | ACPI `_BCM`/`_BCL` methods — firmware does the work |
| `platform` | vendor-specific | e.g. `dell_backlight` via SMI/WMI |
| `raw` | `intel_backlight` | The GPU driver drives the panel directly |

The decision uses the ACPI video capability bits, DMI quirk tables, and the
`acpi_backlight=` kernel parameter. On this machine the result is `raw` — only
`intel_backlight` exists, and it was `raw` on both 6.14 and 7.0. **The class
choice was not what changed.**

Override with `acpi_backlight=native|video|vendor|none` if the wrong class is
chosen. That is a different fix from the one this machine needed, and applying it
here would not have helped.

### 4.2 Second choice — which *transport*, inside i915

Having decided it owns the panel, i915 then picks PWM pin versus DPCD AUX. This
is governed by `i915.enable_dpcd_backlight`:

| Value | Behaviour |
|---|---|
| `-1` | **Auto** — decide from the VBT panel descriptor. The default. |
| `0` | Disabled — force the native PWM path. |
| `1` | Enable DPCD backlight. |
| `2` | Force the VESA interface. |
| `3` | Force the Intel HDR interface. |

The auto path reads the Video BIOS Table, which is supplied by firmware and
describes what the panel supposedly supports. **If the VBT claims AUX backlight
support on a panel whose TCON does not honour it, auto-detection selects a
transport that silently does nothing** — which is exactly the failure here.

Kernel version matters because the auto heuristics change between releases. The
same VBT, the same panel, and two kernels can reach different conclusions. That
is why a kernel upgrade broke a working display without any configuration change.

> **Gotcha.** `/sys/module/i915/parameters/*` is mode `0400`. Reading it as an
> ordinary user returns an empty string, which looks identical to "unset". Always
> read it as root before concluding a parameter has no value.

---

## 5. The Linux backlight class

`/sys/class/backlight/<device>/` is a deliberately thin ABI:

| File | Meaning |
|---|---|
| `brightness` | Requested level. **Writable.** |
| `actual_brightness` | Level read back from the driver. |
| `max_brightness` | Upper bound. Lower bound is always 0. |
| `bl_power` | `0` = on. `4` = `FB_BLANK_POWERDOWN`. |
| `type` | `raw`, `platform` or `firmware`. |
| `scale` | `linear`, `non-linear`, or `unknown`. |

Three properties of this interface cause most misdiagnosis:

**`actual_brightness` is not a measurement.** It is what the driver believes it
set, read back through the driver, not sensed from the panel. When the panel
ignores the driver, `actual_brightness` still agrees with `brightness`. It agreed
throughout the incident.

**`max_brightness` is derived from the chosen transport, not from the panel.**
On AUX it comes from `EDP_PWMGEN_BIT_COUNT`: this panel reported 10, giving
2¹⁰−1 = **1023**. On the native PWM path it comes from the PWM period register
and is usually a different number entirely. **A change in `max_brightness`
across a kernel upgrade is therefore a strong signal that the transport changed**
— and is exactly the datum that would have solved this in minutes, had anything
been recording it. See `docs/13` §7.1.

**Writes never fail meaningfully.** A write is rejected only if it is
out of range or malformed. "The hardware ignored it" is not an error condition
the ABI can express.

---

## 6. Everything above the kernel

Layers above sysfs matter for *ergonomics* — which key does what — but none of
them can cause, or fix, a panel that ignores the driver. During the incident all
of them were exonerated by a single test: a direct sysfs write bypasses every one
of them, and it changed nothing.

### 6.1 systemd-backlight

`systemd-backlight@backlight:intel_backlight.service` saves the level at shutdown
into `/var/lib/systemd/backlight/` and restores it at boot. Harmless, but it
means **a brightness level can survive a reboot and appear to be "sticky"**. If
you are testing changes, account for the restore.

### 6.2 X11 and the RandR Backlight property

The `modesetting` driver may export a `Backlight` property on the output,
allowing brightness changes through the RandR protocol. Whether it appears
depends on the driver finding a usable backlight device at server start.

On kernel 7.0 this property is **absent**, and `csd-power` logs:

```
gnome-rr not supported for display backlight, using backlight-helper for future calls
```

falling back to `pkexec /usr/libexec/csd-backlight-helper`. This is a visible
symptom of the underlying change but **not itself the fault** — the helper writes
sysfs directly and works correctly.

### 6.3 csd-power, UPower and logind

`csd-power` owns brightness policy: idle dimming, restoring level at login,
handling brightness keys. Relevant `gsettings` under
`org.cinnamon.settings-daemon.plugins.power` include `idle-dim-ac`,
`idle-dim-battery`, `idle-brightness` and `idle-dim-time`.

A useful signature in the journal: **repeated identical `--set-brightness`
values** mean a user is holding a key against a ceiling that is already reached.
Thirteen consecutive writes of `1023` is what "the brightness keys do nothing"
looks like from the log side.

### 6.4 The brightness keys themselves

Fn+F6/F7 can reach the OS by two different routes:

- **ACPI video bus** — `LNXVIDEO`/`acpi.video_bus`, emitting standard key events.
- **Vendor WMI** — `dell-wmi`, via `sparse_keymap`.

Which one is active affects whether keys work, but **not** whether the resulting
brightness change is honoured. Between 6.14 and 7.0 the ACPI video bus device
moved in the device tree — from `LNXSYSTM:00/…/LNXVIDEO:00` to
`pci0000:00/acpi.video_bus.0` — which is a real, observable difference, and a red
herring for this fault.

---

## 7. The keyboard backlight stack

Structurally similar, and it fails in the same *shape*: the OS believes it is in
control and is not.

```
   csd-power ── D-Bus ──▶ UPower KbdBacklight
                              │
                              ▼
        /sys/class/leds/dell::kbd_backlight/brightness
                              │  (dell-laptop driver, SMI to the EC)
                              ▼
                    Embedded Controller  ◀── BIOS NVRAM settings
                              │                (timeout, illumination level)
                              ▼
                         keyboard LEDs
```

### 7.1 The kernel LED interface

| File | Meaning |
|---|---|
| `brightness` | `0`–`max_brightness`. Here max is `2`, so `1` is the lowest lit level. |
| `stop_timeout` | How long the light stays on after a trigger. |
| `start_triggers` | **What turns the light ON.** |

> **Gotcha, learned the hard way.** `start_triggers` is not a list of things that
> switch the light off. Clearing it (`-keyboard -touchpad`) removes everything
> capable of switching the light **on**, leaving the keyboard permanently dark.
> The driver also parses **one token per write** — `"-keyboard -touchpad"` in a
> single write applies only the first.

### 7.2 Firmware owns the timeout

The EC implements the auto-off timer, and its configuration lives in BIOS NVRAM,
**above the OS in authority**. The kernel's `stop_timeout` node can only express
values the firmware exposes to it. On this machine sysfs accepts up to `12h` and
rejects `Never` outright — so no amount of OS-level configuration can produce a
keyboard light that stays on indefinitely.

The real control surface is `dell_wmi_sysman`, which exposes BIOS Setup itself:

```
/sys/class/firmware-attributes/dell-wmi-sysman/attributes/<name>/
    current_value      read/write
    possible_values    the enumeration
    type               enumeration | integer | string
```

| Attribute | Values | Purpose |
|---|---|---|
| `KeyboardIllumination` | `Disabled;Dim;Bright` | Brightness level. `Dim` is the lowest **lit** state. |
| `KbdBacklightTimeoutAc` | `5s;10s;15s;30s;1m;5m;15m;Never` | Auto-off on AC |
| `KbdBacklightTimeoutBatt` | same | Auto-off on battery |

Writes require the BIOS admin password when one is set; check
`authentication/Admin/is_enabled` first. Because these are NVRAM settings, they
persist across reboots and OS reinstalls with **no systemd unit, udev rule or
startup script**.

### 7.3 The propagation tell

Setting `KbdBacklightTimeoutAc=Never` causes the kernel's `stop_timeout` to begin
reading `63h` — the maximum its 6-bit field can encode. Since userspace cannot
write `63h` (it is rejected), observing that value is **proof the firmware
setting took effect**. This is a rare case where a lower layer reporting an
otherwise-unreachable value serves as positive confirmation.

---

## 8. Failure modes and how to tell them apart

| Symptom | Likely layer | Distinguishing test |
|---|---|---|
| Dim, sysfs at max, writes have **no visible effect** | Transport mismatch (§3) | Read `0x721`. Toggle it. |
| Dim, but sysfs writes **do** change brightness | Panel range or user expectation | Compare `max_brightness` to a known-good boot |
| No `/sys/class/backlight/*` at all | Class selection (§4.1) | `acpi_backlight=native` |
| Brightness keys dead, sysfs works | Input routing (§6.4) | `evtest`, check for key events |
| Brightness resets after login | `csd-power` / systemd-backlight (§6.1–6.3) | Watch the journal at login |
| Brightness drops when idle | `idle-dim-*` gsettings | `gsettings list-recursively …plugins.power` |
| Flicker, not dimness | PWM frequency, or PSR | `0x728` FREQ_SET; `i915.enable_psr=0` |
| Whole image dark but backlight fine | Gamma / ICC / CTM | Dump the gamma ramp; check for a `vcgt` tag |
| Keyboard light times out despite OS config | Firmware timeout (§7.2) | `dell_wmi_sysman` attributes |
| Keyboard light never comes on at all | `start_triggers` cleared (§7.1) | Read `start_triggers`; expect `+` |

---

## 9. Diagnostic method — descending the stack

The reliable procedure is to **start at the bottom**, because the bottom is the
only layer that cannot lie to you, and to **insist on a visible change** at each
step.

1. **Establish the transport.** Read DPCD `0x721`. This tells you which physical
   path the panel is obeying, independent of what any software thinks.

2. **Prove authority, do not assume it.** Write a *large* change — `max` to
   roughly 4 % — and look at the panel. A small step is not a test; it is an
   invitation to imagine a difference. If a 25× reduction is invisible, the
   control path is inert and everything above it is irrelevant.

3. **Try to turn it off.** `bl_power=4` should blank the panel completely. A
   driver that cannot power the backlight down certainly cannot dim it. This is
   a stronger test than any level change and takes two seconds.

4. **Toggle, repeatedly, and let a human judge.** A single change invites
   confirmation bias in both directions. Cycling — 8 s in state A, 4 s in state
   B, three times — produces a rhythm an observer can confirm or deny with
   confidence. This is what finally settled the incident.

5. **Only now consider the upper layers.** If a raw sysfs write produces a
   visible change, the kernel and hardware are fine, and the fault is in policy:
   the desktop, the keys, the idle timers.

6. **Always guarantee reversion.** Anything that can blank a screen must restore
   itself without operator input — a shell `trap`, a Python `finally`, or a
   self-reverting timer. Never leave a display in a test state that depends on
   the next command running.

7. **Serialise.** Two agents writing the same hardware knob produce correlated
   samples that look exactly like causation. During the incident a load test and
   a brightness sweep overlapped and very nearly produced a confident, wrong
   conclusion. One writer at a time.

---

## 10. Quick reference

```bash
# --- ground truth: which transport is the panel obeying? ---
sudo python3 -c "
import os; fd=os.open('/dev/drm_dp_aux0',os.O_RDWR); os.lseek(fd,0x721,0)
m=os.read(fd,1)[0]; print('0x721=0x%02x'%m, ['PWM pin',None,'DPCD AUX'][m&3])"

# --- full state snapshot + acceptance checks ---
bash scripts/backlight-handoff.sh --capture
bash scripts/backlight-handoff.sh --verify

# --- does the control path have authority? (must be VISIBLE) ---
echo 40   | sudo tee /sys/class/backlight/intel_backlight/brightness
echo 1023 | sudo tee /sys/class/backlight/intel_backlight/brightness

# --- can it power the backlight off at all? ---
echo 4 | sudo tee /sys/class/backlight/intel_backlight/bl_power; sleep 2
echo 0 | sudo tee /sys/class/backlight/intel_backlight/bl_power

# --- parameters (MUST be read as root; 0400) ---
sudo cat /sys/module/i915/parameters/enable_dpcd_backlight

# --- keyboard: the layer that actually decides ---
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
cat $A/KeyboardIllumination/current_value
cat $A/KbdBacklightTimeoutAc/current_value
cat $A/KbdBacklightTimeoutBatt/current_value
```

### Parameters worth knowing

| Parameter | Effect |
|---|---|
| `i915.enable_dpcd_backlight=0` | Force native PWM. **The fix applied here.** |
| `i915.enable_dpcd_backlight=2` | Force VESA AUX. |
| `acpi_backlight=native` | Force the `raw` GPU-driven class. |
| `acpi_backlight=video` | Force the ACPI `firmware` class. |
| `i915.enable_psr=0` | Disable panel self-refresh — for flicker, not dimness. |
| `i915.invert_brightness=1` | For panels wired with inverted PWM polarity. |

---

## See also

- `docs/13-display-and-keyboard-backlight.md` — the 2026-08-14 incident
- `docs/05-post-install-optimization.md` §4 — graphics tuning, PSR note
- `docs/07-findings-and-risks.md` — F-01 battery, F-09 adapter
- `scripts/backlight-handoff.sh` — capture, verify, restore
