# 13 — Build Log: Post-Boot Tuning Applied

Record of the session that ran `02-post-boot-tuning.sh` (and through it
`scripts/post-boot-setup.sh`) against the live machine, taking the runbook from
"Phase 0/A/B partially done" to "everything except Phase E complete".

Date: 2026-08-14. Continues [12 — Build Log: First Boot](12-build-log-first-boot.md),
which ends with post-boot tuning *staged but not run*.

Docs [13](13-display-and-keyboard-backlight.md) and
[14](14-backlight-architecture.md) were written concurrently by a parallel session
working on the backlight faults. They reach the same conclusion this log does from a
different direction — see §7.

---

## Summary

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | `noatime` written to fstab but never remounted — step reported OK regardless | High | Fixed + script patched |
| 2 | TLP charge thresholds inert; firmware cap stood at 90% | Medium | Applied directly; script patched |
| 3 | TLP rejected its own config: `INTEL_GPU_MAX_FREQ_ON_AC=""` | Medium | Fixed + script patched |
| 4 | Battery health check read `energy_*`, absent on this platform → silent `n/a` | Medium | Script patched |
| 5 | GDS/Downfall — no BIOS update exists | Known | Closed, unfixable |
| 6 | Brightness parameter shares the GRUB cmdline with `resume=` | Medium | Verified intact; runbook step added |

Steps 5, 6, 7, 9, 10, 14 and 16 are now applied and verified. Phase E remains.

---

## What was applied

| Step | Result |
|---|---|
| 5 `noatime` | fstab rewritten **and remounted** — `/`, `/home`, `/boot` all `noatime` |
| 6 sysctl | `vm.swappiness` 60 → **10**, `vm.vfs_cache_pressure` 100 → **50** |
| 7 zram | `/dev/zram0`, 3.8 G, zstd, **priority 100**, above `lv_swap` at -1 |
| 9 TLP | installed and active, `power-profiles-daemon` masked, EPP `balance_performance` |
| 10 VA-API | `intel-media-va-driver-non-free` — profiles 31 → **43** |
| 14 hibernation | `resume=UUID=4c724c8c…` in GRUB and initramfs; UPower `CriticalPowerAction=Hibernate` |
| 16 journald | `SystemMaxUse=200M` |

Zero failed units afterwards. `crypttab`, initramfs and the boot chain verified intact.

---

## 1. `noatime` was written but never live (high)

`post-boot-setup.sh` step 5 edited `/etc/fstab` correctly, then "verified" with:

```bash
if findmnt -n / >/dev/null; then ok; else red "CHECK /etc/fstab"; fi
```

`findmnt -n /` only asks whether `/` is mounted **at all**, which is unconditionally
true inside a running system. It can never fail, so the step printed green while
`/proc/mounts` still showed:

```
/ rw,relatime,errors=remount-ro
/home rw,relatime
/boot rw,relatime
```

Editing `fstab` changes nothing until a remount. The option would have appeared applied
and stayed dormant until the next reboot — and because nothing else reads it, a run that
was never followed by a reboot would leave the machine permanently un-tuned while every
report claimed otherwise.

**This is the same failure mode as the `pipefail`/`grep -q` bug in
[12](12-build-log-first-boot.md#a-bug-class-worth-knowing-about): a check whose
successful path does not actually test the thing it names.**

Fixed in the script by validating, remounting, and then confirming against
`/proc/mounts`:

- `findmnt --verify --fstab`, rolling back from the timestamped backup if it fails.
  A malformed `fstab` on a LUKS root means an emergency shell, so this must be caught
  while a shell still exists.
- `mount -o remount` on all three targets.
- Re-read `/proc/mounts` per target and fail loudly naming any that did not take.

The verification loop deliberately avoids `... | grep -q`, for the SIGPIPE reason
documented in 12.

---

## 2. TLP charge thresholds were inert (medium)

`post-boot-setup.sh` writes `START_CHARGE_THRESH_BAT0` / `STOP_CHARGE_THRESH_BAT0` into
`/etc/tlp.d/01-latitude-7420.conf` and restarts TLP. Both were written. Neither reached
the hardware:

```
config: START=95 STOP=100
sysfs:  charge_control_start_threshold = 50
        charge_control_end_threshold   = 90
```

`tlp-stat -b` explains it:

```
+++ Battery Care
Plugin: generic
Supported features: none available
```

TLP 1.6.1 loads its **generic** battery plugin on this Latitude and reports no threshold
capability, so those two keys are silently ignored. The 50/90 values are Dell firmware
defaults, not anything TLP set.

The consequence is small in percentage terms and large in practice: the battery is at
23.6% of design health (14.6 Wh of 61.9 Wh), and a 90% cap removes roughly 1.5 Wh from a
runtime already under an hour. The runbook's stated intent for the original battery is
explicitly *no cap* until it is replaced.

The kernel accepts a direct write:

```bash
echo 100 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```

Applied, and the script now verifies sysfs after restarting TLP rather than assuming the
config took, writing directly when it did not.

> ⚠️ **This does not persist.** TLP cannot manage the threshold here, so it reverts to
> the firmware's 90 on every boot. The durable fix is BIOS → **Power → Battery
> Configuration**, which can be folded into the Phase E BIOS visit for Secure Boot.
> The script now emits this as a note rather than implying the setting is permanent.

**General lesson, same shape as §1:** writing a config file is not evidence that the
setting is in force. Check the sysfs value, not the file you just wrote.

---

## 3. TLP rejected its own config (medium)

Every `tlp start` printed:

```
Error in configuration at INTEL_GPU_MAX_FREQ_ON_AC="": frequency invalid or out of range
```

The generated config set `INTEL_GPU_MIN_FREQ_ON_{AC,BAT}=100` but no `MAX`. TLP 1.6 then
evaluates an empty `MAX` and errors out of config parsing.

The setting was pointless anyway — `gt_RPn_freq_mhz` (the hardware floor) is already
100 MHz, so it requested exactly the default:

```
gt_RPn_freq_mhz = 100   (GPU min)
gt_RP0_freq_mhz = 1300  (GPU max)
```

Removed from the generated config. TLP now starts clean. Live config backed up to
`/etc/tlp.d/01-latitude-7420.conf.bak`.

---

## 4. Battery health check silently reported `n/a` (medium)

Step 9's health check guarded on `/sys/class/power_supply/BAT0/energy_full_design`. This
platform exposes **`charge_*` (mAh), not `energy_*` (µWh)**, so the guard never matched
and the check printed a yellow `n/a` on every run.

F-01 — the degraded battery — is the single most consequential finding in the entire
build, the root cause of the 26 unsafe shutdowns and the filesystem corruption that made
the rebuild necessary. The one automated check for it was silently inoperative on the one
machine it describes.

Fixed with a fallback to `charge_full_design` / `charge_full`. The check now correctly
reports:

```
battery health    23% of design — REPLACE (F-01)
```

---

## 5. GDS is now formally closed

[12 §3](12-build-log-first-boot.md#3-gds--downfall-is-unreachable-via-apt) established
that `intel-microcode` cannot raise this CPU past revision 0xBE, and left a BIOS update
as the only remaining avenue. `fwupdmgr` closes it:

```
Dell Inc. Latitude 7420
└─System Firmware:
    Current version:  1.50.1
    Minimum Version:  1.50.1
```

No update is offered, and the SSD is already at its latest firmware. There is no
mechanism left by which this machine can mitigate GDS/Downfall.

`docs/11`'s acceptance criterion has been amended to "not `Vulnerable`, **or** documented
as firmware-limited", as 12 recommended. Phase E step 11 (firmware) is now known to be a
no-op on this hardware and can be treated as satisfied.

---

## 6. Display brightness — verified intact across the GRUB rewrite

The FN brightness keys and the Cinnamon slider work, via a kernel parameter:

```
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash i915.enable_dpcd_backlight=0 resume=UUID=…"
```

At the time this session began, that parameter appeared in no file in this repository —
it existed only as untracked state on the machine. It has since been documented in depth
by a parallel session, in [13 — Display and Keyboard Backlight](13-display-and-keyboard-backlight.md)
and [14 — Backlight Architecture](14-backlight-architecture.md), which supersede anything
this log would have said about the mechanism. What remained missing was an entry in the
*ordered* task list, so [11 step 10b](11-post-boot-runbook.md#10b-display-brightness-control)
now carries the step and points at 13 and 14 for the analysis.

### The collision between the two workstreams

`i915.enable_dpcd_backlight=0` and step 14's `resume=` share
`GRUB_CMDLINE_LINUX_DEFAULT`. `post-boot-setup.sh` appends via a capture group:

```bash
sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"\(.*\)\"|GRUB_CMDLINE_LINUX_DEFAULT=\"\1 resume=UUID=$SWAP_UUID\"|"
```

`\1` re-emits the existing content, so the brightness parameter survived — verified after
the run. Any future step that touches GRUB must append the same way. Overwriting that
line costs hibernation and the backlight controls together, and neither failure is
obvious until a reboot.

---

## 7. The common thread — checks that cannot fail

All four defects in §§1–4 are the same bug, wearing four costumes:

| § | The check | Why it could not fail |
|---|---|---|
| 1 | `findmnt -n /` after editing fstab | Asks whether `/` is mounted, which is always true inside a running system |
| 2 | writing `*_CHARGE_THRESH_BAT0` | Confirms the file was written, never that the hardware honoured it |
| 3 | writing the TLP config | TLP rejected it at parse time; nothing read the exit path |
| 4 | `[[ -r energy_full_design ]]` | Guard tests a path this platform does not expose, so the branch never ran |

In each case the tooling reported green while the system was unchanged. This is the same
class as the `pipefail`/`grep -q` false negative in
[12](12-build-log-first-boot.md#a-bug-class-worth-knowing-about), and — arrived at
independently, on entirely different hardware paths — the same conclusion
[13 §7.2](13-display-and-keyboard-backlight.md#72-acceptance-criteria-that-cannot-fail)
draws from the backlight faults:

> A display can be unreadable while every criterion passes, which is exactly what
> happened.

Two sessions, one working on power and storage and one on display, both found that the
build's acceptance criteria are **structural** — they assert that configuration exists,
not that it took effect. Structural checks are cheap and catch typos. They do not catch
a driver ignoring a write, a firmware overriding a policy, or a guard whose condition is
false on the only machine it will ever run on.

**The rule both sessions converged on:** verify at the layer that carries the
consequence. Read `/proc/mounts`, not `/etc/fstab`. Read `charge_control_end_threshold`,
not the config that hoped to set it. Where the consequence is only visible to a human —
panel brightness — say so explicitly and ask the operator, rather than asserting a proxy
that always passes.

---

## Verification after the run

```
/ rw,noatime,errors=remount-ro
/home rw,noatime
/boot rw,noatime
vm.swappiness = 10
vm.vfs_cache_pressure = 50
/dev/zram0 partition 3.8G 0B 100
/dev/dm-3  partition  20G 0B  -1
tlp active / power-profiles-daemon inactive / thermald active
VA-API: 43 profiles
charge_control_end_threshold = 100   (until reboot — see §2)
failed units: none
crypttab + initramfs: intact
```

**A reboot is required** for `resume=` and the rebuilt initramfs to take effect. Nothing
is in a broken state without it; the charge cap reverts to 90 until the BIOS setting is
changed.

---

## Remaining

Unchanged in order from [12](12-build-log-first-boot.md) and `handoff.sh`:

1. Second LUKS keyslot — still **one** way into this disk. Re-take the header backup
   afterwards; keyslot changes invalidate it.
2. Encrypted backup stick. The current USB is FAT32 — no POSIX ownership or permissions,
   4 GiB file cap, and it stores `/etc/shadow` and the LUKS header in the clear.
3. Phase E: Secure Boot → TPM. Step 11 (firmware) is now a confirmed no-op. Re-take the
   header backup again after TPM enrolment. **Set the BIOS charge policy during the same
   visit** (§2).
4. `ufw` — installed, unit active, ruleset **inactive**. No firewall.
5. Remove `/etc/sudoers.d/99-claude-temp` when the build is finished.

Hardware, unchanged and still gating the outcome: F-01 battery at 23.6% of design, F-09
adapter negotiating 45 W on a 65 W platform. Unsafe shutdowns holding at **26** — recheck
in a month.
