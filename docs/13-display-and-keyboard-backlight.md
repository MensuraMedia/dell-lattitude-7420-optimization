# 13 — Display and Keyboard Backlight

Investigation and resolution of two backlight faults found on first use of the
rebuilt system, 2026-08-14.

Both were traced to control-path selection rather than to hardware failure, and
both were fixed without replacing any component. They are documented together
because they share a diagnostic lesson: **in each case the operating system
reported success while the hardware ignored it.** Every OS-visible indicator was
green throughout. Believing those indicators is what made the display fault take
roughly an hour to isolate instead of two minutes.

---

## Contents

1. [Summary](#1-summary)
2. [Fault A — display backlight stuck dim](#2-fault-a--display-backlight-stuck-dim)
3. [Fault B — keyboard backlight will not stay lit](#3-fault-b--keyboard-backlight-will-not-stay-lit)
4. [Changes applied](#4-changes-applied)
5. [Verification](#5-verification)
6. [Rollback](#6-rollback)
7. [Gaps this exposed in the build tooling](#7-gaps-this-exposed-in-the-build-tooling)
8. [Register and attribute reference](#8-register-and-attribute-reference)

---

## 1. Summary

| | Fault A — display | Fault B — keyboard |
|---|---|---|
| Symptom | Panel very dim; brightness keys do nothing | Keys unlit, or dim out seconds after typing |
| Layer at fault | Kernel — i915 backlight interface selection | Firmware — BIOS timeout overriding the OS |
| Trigger | Kernel upgrade 6.14.0-37 → 7.0.0-28 | Pre-existing BIOS defaults |
| OS reported | `1023/1023`, writes accepted | `brightness=1`, stable, writes accepted |
| Hardware did | Ignored every write | Cut the LED on its own timer |
| Fix | `i915.enable_dpcd_backlight=0` | `KbdBacklightTimeoutAc/Batt = Never` |
| Needs reboot | Yes | No |
| Survives reboot | Yes (GRUB) | Yes (NVRAM) |

Neither fault was caused by anything in this repository's scripts. Fault A was
introduced by the kernel that `preflight-and-upgrade.sh` legitimately installed;
Fault B predates the Linux install entirely.

---

## 2. Fault A — display backlight stuck dim

### 2.1 Symptom as reported

> "first order of business should be to optimize or improve display brightness.
> it's very low and does not seem to improve."

Refined by two later observations that proved decisive:

> "display is working at boot especially when revealing the mint logo but after
> the desktop comes up the screen is dimmed significantly"

> "screen brightness worked perfectly before last boot"

The second statement reclassified the problem from a tuning question into a
**regression**, which is what made it tractable. Everything before that point was
hypothesis generation; everything after was bisection.

### 2.2 Environment

| Field | Value |
|---|---|
| Model | Dell Latitude 7420 |
| BIOS | 1.50.1 (2026-04-23) — confirmed current, no LVFS update available |
| GPU | Intel TigerLake-LP GT2 \[Iris Xe] `8086:9a49`, subsystem Dell `1028:0a36` |
| Driver | `i915` (`xe` present but bound to nothing, refcount 0) |
| Panel | AU Optronics `06af:3d24`, EDID model `B140HAK` / `9PN3R` |
| Panel size | 1920×1080, 309 mm × 174 mm, eDP-1, connector 587 |
| DPCD revision | 1.1 |
| OS | Linux Mint 22.3 (Cinnamon), X11 |

### 2.3 Regression window

```
boot -2   11:34 – 19:03   kernel 6.14.0-37-generic    brightness WORKED
boot -1   19:04 – 19:07   kernel 7.0.0-28-generic     broken
boot  0   19:07 – …       kernel 7.0.0-28-generic     broken
```

Between boot -2 and boot -1, `preflight-and-upgrade.sh` ran a full `apt upgrade`
(18:16–18:17). Graphics-relevant packages changed:

| Package | From | To |
|---|---|---|
| `linux-image-generic-hwe-24.04` | 6.14.0-37 | **7.0.0-28** |
| `cinnamon-settings-daemon` | 6.6.2+zena | 6.6.4+zena |
| `mesa` (`libgl1-mesa-dri` et al.) | 25.0.7 | 25.2.8 |
| `xserver-xorg-core` | 21.1.12-1ubuntu1.5 | 21.1.12-1ubuntu1.6 |
| `libdrm*` | 2.4.122 | 2.4.125 |

`/etc/default/grub` was modified in the same window, but the diff is only
`GRUB_TIMEOUT_STYLE=hidden→menu` and `GRUB_TIMEOUT=0→3`. **No kernel command-line
parameters were added.** The pre-upgrade copy in
`system-state-20260814-181724.tar.gz` (`state/07-grub-default`) confirms this.

### 2.4 What the OS reported — all of it misleading

```
/sys/class/backlight/intel_backlight/
  brightness        = 1023
  max_brightness    = 1023
  actual_brightness = 1023
  bl_power          = 0
  type              = raw
  scale             = unknown
```

Backlight pinned at maximum. `xrandr` reported `Brightness: 1.0`,
`Gamma: 1.0:1.0:1.0`, identity transform; `xgamma` reported `1.000` on all three
channels. Cinnamon night light disabled, `idle-dim-ac` false, no
redshift/gammastep running. Journal showed `csd-power` correctly driving the
backlight to maximum:

```
csd-backlight-helper --set-brightness 973   ← restored at login
csd-backlight-helper --set-brightness 1023  ← ×13, user pressing brightness-up
```

Thirteen consecutive writes of the same maximum value is the signature of a user
holding a key against a ceiling that is already reached.

### 2.5 Hypotheses considered

| # | Hypothesis | Verdict |
|---|---|---|
| a | PSR (Panel Self Refresh) engaging after compositor settles | **Refuted** |
| b | Wrong backlight interface selected by i915 | **CONFIRMED** |
| c | colord / ICC `vcgt` curve crushing luminance after login | **Refuted** |
| d | `csd-power` or session actor dimming at login | **Refuted** |
| e | Panel genuinely at max; perception/expectation gap | **Refuted** |
| f | Dell firmware power-budget clamp (45 W adapter, dead battery) | **Refuted** |

Hypotheses (c) and (f) deserved serious weight and were not cheap to dismiss.
(c) fit the "fine at Plymouth, dim after desktop" timeline perfectly — an ICC
profile is applied at session start, exactly when the dimming appeared. (f) fit
the independently-confirmed hardware findings F-01 and F-09 (see
`docs/07-findings-and-risks.md`): a battery at 23.6 % of design health and an
adapter delivering 45 W on a 65 W platform.

### 2.6 How each was refuted

**(c) ICC / gamma.** The EDID-derived profile
`~/.local/share/icc/edid-e5a21f55070684e3332e251c2756d75b.icc` was parsed
directly from its tag table. It carries 14 tags —
`desc cprt wtpt chad rXYZ bXYZ gXYZ rTRC gTRC bTRC chrm meta dmnd dmdd` — and
**no `vcgt` tag**. There is nothing in it that can load a gamma ramp.

`xrandr`'s `Gamma: 1.0` summary is a curve fit and can hide a scaled ramp, so the
ramps were dumped directly via `XF86VidModeGetGammaRamp` and `XRRGetCrtcGamma`.
CRTC 62 (the one driving eDP-1) returned a perfect identity ramp across 1024
entries with a maximum of **65535** — full scale, no attenuation.

**(a) PSR.** Sampled 20× over 10 s on the idle desktop. Status never left `IDLE`,
busy frontbuffer bits stayed `0x0`, and the performance counter — which
increments on every self-refresh entry — stayed **frozen at 5** for the entire
window. PSR was enabled but not engaging during precisely the period the dimness
was perceived. It also has no luminance mechanism: PSR changes which device
drives refresh, not backlight level. Independently, PSR was disabled at runtime
via `i915_edp_psr_debug` with no observed change, then re-enabled.

**(f) Power budget.** Under 24 s of sustained 4-thread load (package 45 → 61 °C),
both the sysfs value and the panel's own DPCD level register stayed pinned at
1023 for every sample. RAPL `PL1` is clamped to **13.5 W** against a 28 W maximum
— a real and separately noteworthy constraint — but it did **not** move under
load, making it a static DPTF/`ThermalManagement` setting rather than a dynamic
adapter response.

The mechanism is also architecturally impossible here. Brightness is set by the
panel TCON from a value the *GPU driver* writes over the AUX channel. The
embedded controller has no path into DPCD `0x722` while the OS owns AUX. And
(f) specifically predicted a clamp *invisible to sysfs* — but sysfs and the
panel's own register agreed exactly at every sample. There was no hidden clamp.

BIOS `PowerWarn` (Enable Adapter Warnings) is **Disabled**, which is why the
under-spec adapter never produced a firmware warning. Worth re-enabling on
principle; unrelated to this fault.

**(e) Perception gap.** Refuted by test 2.7.1 below. A working backlight stepped
from 1023 to 40 would be very nearly black.

### 2.7 The three decisive tests

#### 2.7.1 Brightness sweep — proved the control path was inert

`intel_backlight/brightness` was stepped `1023 → 700 → 400 → 150 → 40 → 150 →
400 → 700 → 1023`, three seconds apart, with the operator watching the panel.

`actual_brightness` faithfully echoed **every** value. The operator reported
**no visible change whatsoever.**

This single result eliminated (a), (c), (d) and (e) simultaneously. None of them
can make a sysfs write inert — a write to `/sys/class/backlight/` bypasses X,
the compositor, colord and the session entirely. A backlight at 40/1023 that
looks identical to 1023/1023 is not a backlight under software control.

#### 2.7.2 `bl_power` toggle — proved even power control was inert

`bl_power` was set to `4` (`FB_BLANK_POWERDOWN`) for two seconds and returned to
`0`, with guaranteed restore via a shell `trap`. The panel **did not blank.**

The driver could not even turn the backlight *off*. This is stronger than 2.7.1:
it rules out a mis-scaled or compressed range and establishes that the interface
had no authority over the hardware at all.

#### 2.7.3 DPCD control-mode switch — identified the culprit and proved the fix

Reading the panel's DPCD directly over `/dev/drm_dp_aux0` produced the finding
that closed the case:

```
0x721 BL_CONTROL_MODE      = 0x0a   → mode 2 = DPCD AUX
0x722/0x723 brightness     = 0x03FF → 1023, full scale
0x724 PWMGEN_BIT_COUNT     = 10     → explains max_brightness = 2^10-1 = 1023
0x728 FREQ_SET             = 132    → 27 MHz / (132 × 2^10) ≈ 199.7 Hz
      DYNAMIC_BACKLIGHT_ENABLE = 0  → CABC off
0x340–0x36F Intel HDR block = all zeros → interface not supported by this panel
```

i915 had **already** auto-selected the VESA eDP DPCD AUX backlight interface.
The entire VESA configuration was internally consistent and correct — the driver
was writing well-formed values to the right registers at full scale, and the
panel's own register agreed. **The panel simply does not honour that interface.**

Two consequences worth recording, because they close off otherwise-obvious fixes:

- `i915.enable_dpcd_backlight=1` would be a **no-op** — AUX is already active.
- `i915.enable_dpcd_backlight=3` (Intel HDR interface) is **impossible** — the
  HDR capability block reads all zeros on this panel.

The test forced `0x721` to `0x08` (PWM pin) and back to `0x0a` (AUX) across three
cycles of 8 s bright / 4 s dim, self-reverting in a `finally` block. The operator
narrated the transitions in real time, in cadence:

> "it's working" … "now it's dim again. now it's working again." … "now it's dim again."

**PWM-pin mode → bright. AUX mode → dim. Reproducible on demand.**

### 2.8 Root cause

Kernel 7.0.0-28's i915 selects the VESA DPCD AUX backlight interface for this
AU Optronics panel. The panel accepts AUX backlight writes, acknowledges them,
and reflects them in its own registers, but **does not act on them** — including
power-off. Because the driver believes AUX is in use, it stops driving the PCH
PWM pin, leaving the panel at whatever duty the firmware last set.

This explains every observation, including the one that seemed strangest:

- **Bright during Plymouth** — firmware had the panel in PWM-pin mode at a high
  duty, and i915 had not yet completed backlight setup.
- **Dim once the desktop appears** — i915 finishes init, switches the panel to
  AUX mode, and the PWM pin stops being driven.
- **Brightness keys do nothing** — writes land in AUX registers the panel ignores.
- **`bl_power` cannot blank the panel** — same path, same indifference.

Kernel 6.14.0-37 used the native PWM path on this panel and worked. That
specific claim is **inferred** from the regression window plus the operator's
testimony, not directly measured: no display state was captured before the
reboot (see §7), so 6.14's `0x721` value and `max_brightness` are unknown.

### 2.9 Fix

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_dpcd_backlight=0"
```

`0` disables DPCD backlight and forces the native PWM path, restoring the full
chain: Fn keys → `csd-power` → sysfs → PCH PWM duty → panel.

Applied to `/etc/default/grub`, regenerated with `update-grub`, and confirmed
present on the `linux` lines for **both** installed kernels. **Requires a reboot.**

An interim measure was applied to avoid leaving the machine dim while waiting for
that reboot: `0x721` was set to `0x08` directly. This yields a bright panel but
**is not dimmable**, because i915 still routes its writes to AUX. It does not
survive reboot and is superseded by the parameter above.

---

## 3. Fault B — keyboard backlight will not stay lit

### 3.1 Symptom

> "ensure keys are permanently backlit at lowest brightness"

and, after the first attempt:

> "backlit keys continue to dim after not using the keys. needs to stay on."

### 3.2 What the OS reported — again misleading

```
/sys/class/leds/dell::kbd_backlight/
  brightness      = 2  (of max 2)   ← at maximum, not lowest
  stop_timeout    = 10s
  start_triggers  = +keyboard +touchpad
```

### 3.3 Two false starts, both worth recording

**False start 1 — misreading `start_triggers`.** These are the events that turn
the light **on**, not off. Disabling both (`-keyboard -touchpad`) to "stop it
switching off" left nothing able to switch it **on**, and the keyboard went
permanently dark — strictly worse than the reported fault. Reverted immediately
to `+keyboard +touchpad`.

Note also that the driver parses one token per write: writing
`"-keyboard -touchpad"` in a single operation applied only the first. Each
trigger must be written separately.

**False start 2 — treating it as an OS problem.** `stop_timeout` was raised to
`12h`. Probing established the sysfs-writable set:

```
accepted : 5s 30s 1m 5m 15m 30m 1h 2h 4h 12h
rejected : 0s never 23h 24h 63h 1d 7d 0m 0h
```

`12h` appeared to be the ceiling, and `0s`/`never` were rejected outright. **The
keys still went out.** Sampling the LED every 3 s for 60 s with no keyboard
contact showed `brightness=1` for all 20 samples — the sysfs value never moved
while the light physically went out. The cut was happening **below the OS.**

`fuser` showed `upowerd` (PID 1154) holding the LED open, which was a red
herring: `csd-power` observes UPower's `KbdBacklight` interface but was not the
agent switching it off.

### 3.4 Root cause

Dell firmware owns the keyboard backlight timeout and overrides the OS. The
`dell_wmi_sysman` module exposes the governing BIOS attributes under
`/sys/class/firmware-attributes/dell-wmi-sysman/attributes/`:

```
KeyboardIllumination     current = Dim    possible = Disabled;Dim;Bright
KbdBacklightTimeoutAc    current = 10s    possible = 5s;10s;15s;30s;1m;5m;15m;Never
KbdBacklightTimeoutBatt  current = 5s     possible = 5s;10s;15s;30s;1m;5m;15m;Never
```

`Never` is available at firmware level but **not reachable through sysfs** — which
is precisely why every OS-level approach failed.

### 3.5 Fix

No BIOS admin password is set (`authentication/Admin/is_enabled = 0`), so the
attributes were writable directly:

```bash
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
echo -n Never | sudo tee $A/KbdBacklightTimeoutAc/current_value
echo -n Never | sudo tee $A/KbdBacklightTimeoutBatt/current_value
# KeyboardIllumination left at Dim — already the lowest lit level
```

`KeyboardIllumination=Dim` satisfies "lowest brightness": the scale is
`Disabled / Dim / Bright`, so `Dim` *is* the dimmest lit state. The kernel LED
node's `brightness=1` of max `2` is the same level expressed differently.

Because these are NVRAM settings they persist across reboots with **no systemd
unit, udev rule, or startup script required.**

### 3.6 Independent confirmation

The `stop_timeout` sysfs node was read as `12h` when the 60-second sampling run
began and **`63h` when it ended**, with nothing in the OS having written it. The
BIOS `Never` propagated down into the `dell-laptop` driver, which encodes it as
`63h` — the maximum its 6-bit field can represent.

That value is unreachable from userspace: a direct write of `63h` had been
**rejected** during earlier probing (§3.3). It could therefore only have
originated in firmware, independently confirming the setting took effect.

---

## 4. Changes applied

| # | Change | Scope | Persists | Reboot |
|---|---|---|---|---|
| 1 | `i915.enable_dpcd_backlight=0` in `GRUB_CMDLINE_LINUX_DEFAULT` | `/etc/default/grub` | yes | **required** |
| 2 | `KbdBacklightTimeoutAc` `10s → Never` | BIOS NVRAM | yes | no |
| 3 | `KbdBacklightTimeoutBatt` `5s → Never` | BIOS NVRAM | yes | no |
| 4 | DPCD `0x721 = 0x08` (interim bright panel) | volatile | **no** | superseded by 1 |

Backup of the original GRUB file:
`/etc/default/grub.bak-preclaude-20260814-194848`

Not changed: `KeyboardIllumination` (already `Dim`), PSR (tested, restored),
`intel_backlight` brightness (restored to 1023), `start_triggers` (restored to
`+keyboard +touchpad`).

`update-grub` emits `ERROR: unsupported sector size 4096 on /dev/dm-*` from
`os-prober`. This is expected on this 4Kn LUKS/LVM layout, is not caused by these
changes, and does not affect the generated configuration.

---

## 5. Verification

After the next reboot:

```bash
# 1. parameter is live
grep -o 'i915.enable_dpcd_backlight=[0-9]' /proc/cmdline

# 2. driver is no longer on the AUX path — expect 0x08, not 0x0a
sudo python3 -c "
import os; fd=os.open('/dev/drm_dp_aux0',os.O_RDWR); os.lseek(fd,0x721,0)
print('0x721 = 0x%02x'%os.read(fd,1)[0])"

# 3. range should no longer be the AUX-derived 1023
cat /sys/class/backlight/intel_backlight/max_brightness

# 4. control now has authority — this must be VISIBLE
echo 300 | sudo tee /sys/class/backlight/intel_backlight/brightness
echo 1023 | sudo tee /sys/class/backlight/intel_backlight/brightness

# 5. Fn+F6 / Fn+F7 must step brightness

# 6. keyboard: type, then wait 60s — light must stay on
cat /sys/class/leds/dell::kbd_backlight/brightness   # expect 1
```

Acceptance criteria:

- [ ] `0x721` reads `0x08`
- [ ] Step 4 produces a **visible** change (the criterion the old build missed)
- [ ] Fn+F6 / Fn+F7 step brightness
- [ ] Keyboard backlight lit and stable after 60 s idle, on AC and on battery
- [ ] Settings survive a second reboot

---

## 6. Rollback

**Display parameter:**

```bash
sudo cp /etc/default/grub.bak-preclaude-20260814-194848 /etc/default/grub
sudo update-grub
```

**Fallback kernel.** 6.14.0-37 remains installed and is present in GRUB's
*Advanced options for Linux Mint 22.3 Cinnamon* submenu. The build set
`GRUB_TIMEOUT_STYLE=menu` / `GRUB_TIMEOUT=3`, so the menu is reachable without
key-mashing.

⚠️ If the 6.14 fallback is ever made permanent, note that
`linux-image-generic-hwe-24.04` now tracks 7.0.0-28 and will reinstate it as
default on the next kernel upgrade. Making a rollback stick requires pinning
`GRUB_DEFAULT` to the 6.14 entry or holding the HWE metapackage. Do not rely on
selecting it manually each boot.

**Keyboard:** set `KbdBacklightTimeoutAc` / `…Batt` back to `10s` / `5s`, or use
BIOS Setup (F2) → *System Configuration* → *Keyboard Backlight*.

---

## 7. Gaps this exposed in the build tooling

### 7.1 `collect-diagnostics.sh` captures nothing about the display

The script has roughly 30 sections covering DMI, Secure Boot, TPM, CPU,
vulnerabilities, memory, block devices, partition tables, NVMe SMART, NVMe error
logs, battery, AC adapter, thermals and PCI. The **only** graphics content is
`lsmod | grep i915` inside "Loaded modules".

Consequently **no pre-upgrade display state exists anywhere** — not in the
committed diagnostics, not in `logs/stage1-20260814.log` (which contains only
libdrm *package* lines), and not in `system-state-20260814-181724.tar.gz`.
`docs/01-hardware-inventory.md` §5 records the GPU device ID and driver but
nothing about the panel or its backlight.

Had a single `cat /sys/class/backlight/*/{max_,actual_,}brightness` been
captured before the upgrade, the changed range would have been visible
immediately and §2 would have been a two-minute diagnosis.

**Recommended section** for `collect-diagnostics.sh`:

```bash
section_sh "Display / backlight" '
  for d in /sys/class/backlight/*/; do
    echo "== $d"
    for f in type scale brightness actual_brightness max_brightness bl_power; do
      [ -r "$d$f" ] && echo "  $f = $(cat "$d$f")"
    done
  done
  echo "-- i915 backlight params"
  for p in enable_dpcd_backlight enable_psr invert_brightness; do
    echo "  $p = $(cat /sys/module/i915/parameters/$p 2>/dev/null)"
  done
  echo "-- LED backlights"
  for d in /sys/class/leds/*kbd*/; do
    echo "== $d"
    for f in brightness max_brightness stop_timeout start_triggers; do
      [ -r "$d$f" ] && echo "  $f = $(cat "$d$f")"
    done
  done
  echo "-- connectors"
  for c in /sys/class/drm/card*-*/status; do echo "  $c = $(cat $c)"; done
'
```

Also worth capturing: `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/*/current_value`.
Fault B lived entirely in that tree and it is currently unrecorded — the
`PowerWarn=Disabled` finding surfaced there too.

### 7.2 Acceptance criteria that cannot fail

`docs/11`'s criteria are structural (LUKS version, mount presence, TRIM
granularity). Nothing exercises a **user-visible output path**. A display can be
unreadable while every criterion passes, which is exactly what happened.

Suggested addition: a check that a backlight write produces a *changed*
`actual_brightness` on a device whose `bl_power` is 0, and — since this fault
would have defeated even that — an explicit operator confirmation step for
anything that can only be validated by eye.

### 7.3 `core.filemode` on the vfat working copy

The flash-drive clone lives on vfat, which cannot store the Unix exec bit, while
`core.filemode` was `true`. `git status` therefore showed all seven scripts as
modified with **zero** content change:

```
mode change 100755 => 100644 scripts/build-encrypted-stack.sh   (×7)
```

Committing from that copy would have stripped the executable bit from every
script in the repository. Set `core.filemode=false` on any clone kept on
removable media.

### 7.4 Concurrent diagnostic sessions corrupted a measurement

A verification agent's load-correlation test overlapped a brightness sweep run
from another session. The sweep's `1023→700→400→150→40→…` pattern appeared in
the agent's samples as a textbook load-correlated fade and was very nearly
reported as the smoking gun for hypothesis (f). It was caught only by comparing
timestamps against the sweep script.

**Serialise anything that writes to a shared hardware knob**, and prefer reading
a value's provenance over inferring causation from correlated samples.

---

## 8. Register and attribute reference

### 8.1 eDP DPCD backlight — VESA block

Accessed via `/dev/drm_dp_aux0` (eDP-1). Names per
`include/drm/display/drm_dp.h`.

| Offset | Name | Observed | Meaning |
|---|---|---|---|
| `0x721` | `EDP_BACKLIGHT_MODE_SET` | `0x0a` | bits 1:0 = mode. `0x08` = PWM pin, `0x0a` = DPCD AUX |
| `0x722` | `EDP_BACKLIGHT_BRIGHTNESS_MSB` | `0x03` | with LSB = 1023 |
| `0x723` | `EDP_BACKLIGHT_BRIGHTNESS_LSB` | `0xFF` | full scale |
| `0x724` | `EDP_PWMGEN_BIT_COUNT` | `10` | drives `max_brightness` = 2¹⁰−1 = 1023 |
| `0x728` | `EDP_BACKLIGHT_FREQ_SET` | `132` | 27 MHz / (132 × 2¹⁰) ≈ 199.7 Hz |
| `0x340`–`0x36F` | Intel HDR backlight block | all zero | interface unsupported |

### 8.2 `i915.enable_dpcd_backlight`

| Value | Behaviour | Applicability here |
|---|---|---|
| `-1` | Auto, per VBT panel type — **the broken default** | selects AUX |
| `0` | Disabled — force native PWM | **the fix** |
| `1` | Enable DPCD backlight | no-op, already active |
| `2` | Force VESA interface | no-op, already active |
| `3` | Force Intel HDR interface | impossible, block reads zero |

Note the parameter file is mode `0400` — readable only as root. Reading it as an
ordinary user returns empty and can be mistaken for an unset value.

### 8.3 Dell BIOS attributes (`dell_wmi_sysman`)

Path: `/sys/class/firmware-attributes/dell-wmi-sysman/attributes/<name>/current_value`

| Attribute | Was | Now | Notes |
|---|---|---|---|
| `KeyboardIllumination` | `Dim` | `Dim` | `Disabled;Dim;Bright` — `Dim` is lowest lit |
| `KbdBacklightTimeoutAc` | `10s` | **`Never`** | `Never` unreachable via sysfs |
| `KbdBacklightTimeoutBatt` | `5s` | **`Never`** | |
| `PowerWarn` | `Disabled` | `Disabled` | why the 45 W adapter never warned — consider re-enabling |

Writes require the BIOS admin password when one is set; check
`authentication/Admin/is_enabled` first.

### 8.4 Related hardware findings

Neither caused these faults; both are independently actionable and are tracked in
`docs/07-findings-and-risks.md`.

- **F-01** — battery at **23.6 %** of design health (14.6376 Wh of 61.8944 Wh).
- **F-09** — adapter negotiating **15 V × 3 A = 45 W** on a 65 W platform,
  confirmed at `/sys/class/power_supply/ucsi-source-psy-USBC000:002/`.
- **RAPL PL1 clamped to 13.5 W** against a 28 W maximum. Static, not
  load-responsive. Not investigated further; worth a look during power tuning.
