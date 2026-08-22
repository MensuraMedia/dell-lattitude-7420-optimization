# 21 — Lid Power-On & Sleep

Why this machine powers itself on when the lid is opened, why it had never once
suspended, and what each of the two independent mechanisms actually controls.

> **BIOS settings:** [06 — BIOS/UEFI Configuration](06-bios-uefi-configuration.md)
> **Power/thermal mechanism:** [16 — Thermal & Power Architecture](16-thermal-and-power-architecture.md)
> **What changed:** [10 — Change Log](10-change-log.md)

Captured **2026-08-22**. BIOS 1.50.1, kernel 7.0.0-28-generic, systemd 255.4-1ubuntu8.17.

---

## 1. The question

> *Is the laptop automatically turning on when the lid opens?*

**Yes — and it is firmware doing it, from a fully powered-off state.**

Two entirely separate mechanisms are involved, and conflating them is the usual
source of confusion:

| Layer | Owner | Governs | State it acts from |
|---|---|---|---|
| **Power On Lid Open** | Embedded controller (BIOS token) | Cold **power-on** | **S5 — fully off** |
| **Lid switch handling** | `systemd-logind` + desktop | Suspend / blank / resume | S0 (running) |

The firmware mechanism needs no operating system, survives reinstalls, and is
unaffected by anything in `/etc`. The OS mechanism cannot power on a machine that
is off — it is not running.

On this machine the firmware mechanism is **enabled**, and the OS mechanism was
**incapable of sleeping at all**. Together those two facts fully explain the
observed behaviour: the machine is always in S5 when closed, so every lid open is
a cold boot.

---

## 2. Firmware layer — the actual cause

Dell exposes BIOS tokens read/write through `dell-wmi-sysman`:

```bash
A=/sys/class/firmware-attributes/dell-wmi-sysman/attributes
for a in PowerOnLidOpen LidSwitch WakeOnAc WakeOnDock BlockSleep; do
  printf '%-16s %s\n' "$a" "$(sudo cat $A/$a/current_value)"
done
```

| Token | Display name | Current | Factory default | Effect |
|---|---|---|---|---|
| **`PowerOnLidOpen`** | Power On Lid Open | **Enabled** | Enabled | **Powers the system on from S5 when the lid opens** |
| **`LidSwitch`** | Enable Lid Switch | **Enabled** | Enabled | Master enable for the lid Hall sensor |
| `WakeOnAc` | Wake on AC | Disabled | Disabled | — |
| `WakeOnDock` | Wake on Dell USB-C Dock | Enabled | Enabled | Dock attach wakes the system |
| `WakeOnLan` | Wake on LAN | Disabled | Disabled | — |
| `BlockSleep` | Block Sleep | Disabled | Disabled | ✅ correct — would otherwise veto suspend |

`current_value` is `0600 root:root`. Reading it **requires `sudo`**; an unprivileged
`cat` returns an empty string, which reads as "unset" and is a trap.

### Mechanism

The EC remains powered in S5 (that is what keeps the power button alive). It polls
the lid Hall-effect sensor, and with `PowerOnLidOpen=Enabled` it asserts the power
rail on an open transition — identical to a power-button press. No ACPI, no kernel,
no `logind`. It behaves the same on battery and on AC.

`LidSwitch=Disabled` would disable the sensor entirely — including lid-close
suspend under Linux — so it is the wrong lever for this.

---

## 3. OS layer — why the machine had never slept

Four independent settings each suppressed suspend. Any one of them alone would
have been enough.

| # | Layer | State as found | Effect |
|---|---|---|---|
| 1 | systemd units | `sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` **masked** → `/dev/null` | Suspend structurally impossible |
| 2 | Cinnamon | `lid-close-ac-action` = `lid-close-battery-action` = **`blank`** | Lid close only blanks the panel |
| 3 | Cinnamon | `sleep-inactive-ac-type` = `sleep-inactive-battery-type` = **`nothing`** | No idle suspend |
| 4 | Inhibitor | `csd-power` holds `handle-lid-switch` in **block** mode, reason *"Multiple displays attached"* | Overrides logind's `HandleLidSwitch=suspend` |

`/etc/systemd/logind.conf` is entirely stock (every line commented), so logind's
own default was `HandleLidSwitch=suspend` the whole time — it simply never got to
act, because of #1 and #4.

### The masking was undocumented

```
lrwxrwxrwx 1 root root 9 Aug 16 23:29 /etc/systemd/system/sleep.target -> /dev/null
lrwxrwxrwx 1 root root 9 Aug 16 23:29 /etc/systemd/system/suspend.target -> /dev/null
lrwxrwxrwx 1 root root 9 Aug 16 23:29 /etc/systemd/system/hibernate.target -> /dev/null
lrwxrwxrwx 1 root root 9 Aug 16 23:29 /etc/systemd/system/hybrid-sleep.target -> /dev/null
```

All four share the timestamp **2026-08-16 23:29:55** — a single deliberate
`systemctl mask` command. It appears in **no script and no document in this
repository**; `grep -rn 'systemctl mask' scripts/ docs/` finds only
`power-profiles-daemon`. It was a manual action taken outside the tooling and never
recorded.

> ⚠️ This is exactly the class of drift this repo exists to prevent. `docs/06` even
> recommended *"Enable Block Sleep → Disabled — would prevent suspend"*, while the
> OS was suppressing suspend more completely than Block Sleep ever would have.

### Evidence it had never suspended

```bash
journalctl --no-pager | grep -icE "PM: suspend entry|Entering sleep state"   # → 0
```

Zero, across every boot retained in the journal. Every prior boot ends at
`poweroff.target`. The most recent lid cycle demonstrates it directly:

```
Aug 22 13:51:12  systemd-logind: Lid closed.
Aug 22 13:52:47  systemd-logind: Lid opened.
```

No `PM: suspend entry`, no resume, no `Restarting tasks` between them. The panel
blanked and unblanked; the system never left S0.

---

## 4. Why the two combine into "it turns on when I open it"

```
lid closed  →  screen blanks (Cinnamon), system stays fully awake in S0
     ↓
user shuts down later                      →  S5
     ↓
lid opened  →  EC sees the Hall sensor transition
            →  PowerOnLidOpen=Enabled  →  asserts power
            →  cold boot, LUKS passphrase prompt
```

Because the machine could never enter S3/s2idle, **S5 was the only low-power state
it ever reached**, and S5 is precisely the state `PowerOnLidOpen` acts from. The
behaviour was therefore reproducible every single time — which is what made it look
like a fault rather than a setting.

---

## 5. Change applied 2026-08-22 — sleep unmasked

```bash
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target
sudo systemctl daemon-reload
```

All four now report `static` (their normal state — they are not user-enablable
targets) and no mask symlinks remain anywhere in `/etc` or `/run`.

Verification:

```bash
for m in CanSuspend CanHibernate CanHybridSleep CanSuspendThenHibernate; do
  printf '%-24s ' "$m"
  busctl call org.freedesktop.login1 /org/freedesktop/login1 \
         org.freedesktop.login1.Manager $m
done
```

| Method | Before | After |
|---|---|---|
| `CanSuspend` | `no` | ✅ **`yes`** |
| `CanHibernate` | `no` | `no` — see §6 |
| `CanHybridSleep` | `no` | `no` — see §6 |
| `CanSuspendThenHibernate` | `no` | `no` — see §6 |

> **Suspend is now possible but is still not bound to the lid.** Items 2–4 of §3
> were deliberately left untouched. Lid close continues to blank only. To make lid
> close suspend, set `org.cinnamon.settings-daemon.plugins.power lid-close-*-action`
> to `'suspend'` — and note that `csd-power`'s *"Multiple displays attached"*
> inhibitor will still block it while an external display is connected.

### Suspend type available on this platform

```bash
cat /sys/power/mem_sleep    # → [s2idle]
dmesg | grep "ACPI: PM: (supports"   # → ACPI: PM: (supports S0 S4 S5)
```

The firmware offers **S0ix / Modern Standby only — there is no S3**. Suspend-to-RAM
here means `s2idle`. This is normal for a Tiger Lake Latitude and is not a
misconfiguration, but it means suspend quality depends on runtime PM rather than a
hardware sleep state, and idle drain will be higher than a classic S3 machine.

---

## 6. Hibernate is blocked by distro policy, not by this machine

Every hardware and systemd prerequisite passes. Hibernate is refused by a
**polkit rule shipped by Ubuntu**.

Prerequisites, all verified present:

| Requirement | State |
|---|---|
| Kernel sleep state `disk` | ✅ supported (`/sys/power/state` = `freeze mem disk`) |
| Disk sleep mode | ✅ `platform` (`/sys/power/disk`) |
| ACPI S4 | ✅ `ACPI: PM: (supports S0 S4 S5)` |
| Resume device | ✅ `/sys/power/resume` = `252:3` → `/dev/dm-3` (the LUKS-backed swap LV) |
| `resume=` on cmdline | ✅ `resume=UUID=4c724c8c-…` |
| initramfs `RESUME=` | ✅ `/etc/initramfs-tools/conf.d/resume` |
| Swap size | ✅ 20 GiB vs 16 GB RAM |
| zram interference | ✅ none — logind correctly ignores `/dev/zram0` |

Captured from `systemd-logind` with debug logging enabled at runtime:

```bash
sudo busctl set-property org.freedesktop.login1 /org/freedesktop/LogControl1 \
     org.freedesktop.LogControl1 LogLevel s debug
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
     org.freedesktop.login1.Manager CanHibernate
sudo journalctl -u systemd-logind --since "-15s"
sudo busctl set-property org.freedesktop.login1 /org/freedesktop/LogControl1 \
     org.freedesktop.LogControl1 LogLevel s info     # put it back
```

```
Sleep state 'disk' is supported by kernel.
Disk sleep mode 'platform' is supported by kernel.
Swap partition '/dev/zram0' is a zram device, ignoring.
Detected enough swap for hibernation: Active(anon)=1551172 kB, size=20971516 kB, used=0 kB, threshold=98%
… method_call → org.freedesktop.PolicyKit1 … member=CheckAuthorization
```

Every check passes, then the decision is handed to polkit — and polkit says no.
The rule is `/usr/share/polkit-1/rules.d/com.ubuntu.desktop.rules:65`:

```javascript
// Disable hibernate by default in Ubuntu
polkit.addRule(function(action, subject) {
    if (action.id == "org.freedesktop.upower.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.handle-hibernate-key" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions") {
            return polkit.Result.NO;
    }
});
```

Upstream systemd's own policy (`org.freedesktop.login1.policy`) grants
`<allow_active>yes</allow_active>` — Ubuntu overrides it.

To re-enable, add a **higher-priority** rule (files are read in lexical order;
`50-` sorts before `com.ubuntu.…`), never by editing the packaged file, which
`apt` will overwrite:

```bash
sudo tee /etc/polkit-1/rules.d/50-enable-hibernate.rules >/dev/null <<'EOF'
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.login1.hibernate" ||
         action.id == "org.freedesktop.login1.hibernate-multiple-sessions" ||
         action.id == "org.freedesktop.login1.handle-hibernate-key" ||
         action.id == "org.freedesktop.upower.hibernate") &&
        subject.local && subject.active && subject.isInGroup("sudo")) {
            return polkit.Result.YES;
    }
});
EOF
```

> ⚠️ **Not applied.** Hibernating into a LUKS-backed swap LV is sound on this
> layout, but it has never been tested here, and a failed resume on an encrypted
> root is an unpleasant thing to discover with unsaved work. Test deliberately —
> `systemctl hibernate` from a clean desktop — before relying on it.

---

## 7. The `/proc/acpi/wakeup` red herring

```
LID0	  S3	*enabled   platform:PNP0C0D:00
PBTN	  S3	*enabled   platform:PNP0C0C:00
```

This is **not** the power-on setting. It arms the lid as an **ACPI wake source for
a system that is already asleep**. The `S3` column is the deepest declared state,
not the state in use.

While sleep was masked this entry did nothing at all. Now that suspend is available
again it becomes live and correct: opening the lid will resume from `s2idle`.
Disabling it (`echo LID0 | sudo tee /proc/acpi/wakeup`) would mean the lid can no
longer wake the machine — and would still not stop `PowerOnLidOpen`, because that
runs below ACPI.

---

## 8. Turning the lid power-on off

The BIOS setup screen is the reliable route:

> **F2** at the Dell logo → **Power Management** → **Power On Lid Open** → *Disabled*

The sysfs route **does not work on this machine as configured**:

```bash
$ cat /sys/class/firmware-attributes/dell-wmi-sysman/authentication/Admin/is_enabled
0
```

`dell-wmi-sysman` refuses attribute writes unless a **BIOS admin password** is set
and supplied through
`/sys/class/firmware-attributes/dell-wmi-sysman/authentication/Admin/current_password`.
With no admin password configured, writes to `current_value` are rejected. Setting
one purely to script this trades a memorable failure mode for a forgettable one; on
a single-user machine, use F2.

There is no reason to disable it unless the machine is transported in a bag where
the lid can spring open — the failure mode being a laptop that boots and cooks
inside an enclosed space. On this chassis, with a battery at 23.6 % health
([F-01](07-findings-and-risks.md#f-01)), that is worth a moment's thought.

---

## 9. Quick reference

```bash
# Is lid power-on enabled? (needs sudo — unprivileged read returns empty)
sudo cat /sys/class/firmware-attributes/dell-wmi-sysman/attributes/PowerOnLidOpen/current_value

# Can this system sleep at all?
busctl call org.freedesktop.login1 /org/freedesktop/login1 \
       org.freedesktop.login1.Manager CanSuspend
systemctl is-enabled sleep.target suspend.target      # "masked" is the failure

# What does the desktop do on lid close?
gsettings get org.cinnamon.settings-daemon.plugins.power lid-close-ac-action

# What is blocking suspend right now?
systemd-inhibit --list

# Did it actually sleep?
journalctl -b | grep -E "PM: suspend entry|Lid (opened|closed)"
```

---

## 10. Open items

| Priority | Item |
|---|---|
| 🟠 | **Suspend has never been exercised on this install.** `CanSuspend=yes` proves it is permitted, not that s2idle resumes cleanly with LUKS + `i915.enable_dpcd_backlight=0`. Test deliberately and record the result — see [13 §backlight](13-display-and-keyboard-backlight.md) for the regression that most plausibly interacts with resume. |
| 🟡 | Lid close still only blanks. Decide whether it should suspend, and whether `csd-power`'s external-display inhibitor is wanted behaviour. |
| 🟡 | Hibernate remains polkit-blocked by distro default. Rule drafted in §6, **not applied**, untested against the LUKS swap LV. |
| 🟡 | Confirm nothing else was changed manually in the same undocumented 2026-08-16 23:29 session. |
