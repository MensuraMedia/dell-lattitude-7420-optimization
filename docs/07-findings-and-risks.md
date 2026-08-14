# 07 — Findings & Risk Register

Every finding from the 2026-08-14 audit, severity-ranked, with evidence and remediation.

**Severity key**
🔴 Critical · 🟠 High · 🟡 Medium · 🔵 Low / informational · ✅ Healthy

> **Scope note (2026-08-14):** the owner subsequently confirmed the system is new and
> **no data requires retention**. Findings F-02 and F-03 were *blockers* only for the
> dual-boot path; wiping the disk resolves both. They are retained below because they
> document the machine's real condition and point to a common root cause (F-04/F-05).

---

## Register

| ID | Severity | Finding | Status |
|---|---|---|---|
| [F-01](#f-01) | 🔴 | Battery at 23.65% of design health | **Open — hardware replacement required** |
| [F-02](#f-02) | 🟠 | NTFS filesystem inconsistent (8,851 mismatches) | Resolved by wipe |
| [F-03](#f-03) | 🟠 | Hibernation image present (6.3 GB) | Resolved by wipe |
| [F-04](#f-04) | 🟠 | 26 unsafe shutdowns recorded by the SSD | **Open — root cause is F-01** |
| [F-05](#f-05) | 🟡 | 109 NVMe controller error-log entries | Monitor |
| [F-06](#f-06) | 🟠 | Gather Data Sampling (Downfall) reported vulnerable | Fix at install (`intel-microcode`) |
| [F-07](#f-07) | 🟡 | ESP undersized at 100 MiB | Resolved by wipe (1 GiB ESP) |
| [F-08](#f-08) | 🟡 | SSD running 512 B LBA instead of 4096 B | Resolved by wipe (`nvme format --lbaf=1`) |
| [F-09](#f-09) | 🟡 | AC adapter negotiating 45 W against a 65 W platform | **Open — verify adapter** |
| [F-10](#f-10) | 🔵 | Secure Boot disabled | Enable post-install |
| [F-11](#f-11) | 🔵 | No swap configured | Resolved by build (20 GiB + zram) |
| [F-12](#f-12) | 🔵 | S0ix/Modern Standby drain unverified | Verify post-install |
| [F-13](#f-13) | ✅ | SSD health excellent | No action |
| [F-14](#f-14) | ✅ | Full native driver support | No action |
| [F-15](#f-15) | ✅ | BIOS current (1.50.1) | No action |

---

## F-01
### 🔴 Battery at 23.65% of design health

**Evidence**
```
energy-full-design:  61.8944 Wh
energy-full:         14.6376 Wh
capacity:            23.6493%
model:               DELL TN2GY15 (SMP, lithium-polymer)
```

**Impact**
The cell retains under a quarter of its original capacity — roughly 1–1.5 hours of
real-world runtime against a design figure of 8–10. Beyond the usability cost, a
degraded lithium cell exhibits **voltage sag under load**, which can drop the machine
instantly even when the gauge reads a healthy percentage. That behaviour is the most
plausible explanation for [F-04](#f-04) and, transitively, [F-02](#f-02).

**Why software cannot fix this**
Power tuning multiplies runtime by a percentage. TLP, powertop, and aggressive PCIe
ASPM might yield 15–25% more runtime — but 25% more of 1.2 hours is 1.5 hours. The
capacity itself is gone. **This is a hardware condition with a hardware fix.**

**Remediation**
Replace the battery. Dell part family for the 7420 4-cell 63 Wh: `TN2GY` / `WY9DX` /
`M42XW` — **verify against the service tag before ordering**, as the 7420 shipped in
multiple revisions.

**Then** apply charge thresholds to protect the new cell:
```bash
# via TLP (see docs/05)
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
```
Native sysfs support was confirmed present on this machine:
`/sys/class/power_supply/BAT0/charge_control_{start,end}_threshold`.

> ⚠️ Do **not** apply thresholds to the current battery. Capping a 14.6 Wh cell at 80%
> leaves ~11.7 Wh — under an hour. There is nothing left to preserve.

---

## F-02
### 🟠 NTFS filesystem inconsistent — 8,851 cluster accounting mismatches

**Evidence**
```
Accounting clusters ...
Cluster accounting failed at 7478 (0x1d36): extra cluster in $Bitmap
  ... 8,851 total ...
ERROR: NTFS is inconsistent. Run chkdsk /f on Windows then reboot it TWICE!
```

**Impact**
`$Bitmap` (the allocation map) disagreed with the MFT in 8,851 places. Any resize
operation relocates clusters based on that map; a wrong map means wrong data moved, or
live data left inside the truncated region — **silent data loss**. `ntfsresize` and
GParted both refuse to proceed, correctly.

**Root cause**
Almost certainly the 26 unsafe shutdowns ([F-04](#f-04)), themselves attributable to
[F-01](#f-01).

**Status — resolved by scope change**
With the disk being wiped, no NTFS repair is needed. Had dual-boot been retained, the
fix was `chkdsk C: /f` followed by two full reboots, documented in
[04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md#blocker-2--repair-the-ntfs-filesystem).

---

## F-03
### 🟠 Hibernation image present — Fast Startup active

**Evidence**
```
-rwxrwxrwx 1 root root 6757179392 Aug 14 12:07 /mnt/win/hiberfil.sys
```
6.3 GB, written the same day as the audit. Windows was hibernated, not shut down —
the default behaviour of Windows 11 Fast Startup.

**Impact**
A hibernated volume carries frozen in-memory filesystem metadata. Resizing it means
Windows resumes into a filesystem that no longer matches its own cache — reliably
catastrophic. It also prevented `chkdsk` from performing a true repair, since Windows
would resume rather than boot, making [F-03](#f-03) a prerequisite of [F-02](#f-02).

**Status — resolved by scope change.** Had dual-boot been retained: `powercfg /h off`,
disable Fast Startup, full shutdown.

---

## F-04
### 🟠 26 unsafe shutdowns recorded

**Evidence**
```
Power Cycles:        423
Unsafe Shutdowns:     26      (6.1% of all power cycles)
```

**Impact**
An unsafe shutdown is power loss without a cache flush. At 6% of all power cycles this
is well above what a healthy machine produces, and it is the direct cause of
[F-02](#f-02). Left unaddressed it will corrupt the new Linux filesystem too.

**Root cause**
[F-01](#f-01) — voltage sag on a battery at 23.6% health. Possibly compounded by
[F-09](#f-09), an under-spec adapter unable to sustain peak draw while charging.

**Remediation**
1. Replace the battery ([F-01](#f-01)).
2. Verify the adapter ([F-09](#f-09)).
3. Mitigate in the build: `errors=remount-ro` on root, ext4 journaling, and
   hibernate-on-critical-battery — all specified in
   [08 — Reference Architecture](08-reference-architecture.md).
4. Re-check the counter after a month of use:
   ```bash
   sudo smartctl -a /dev/nvme0n1 | grep 'Unsafe Shutdowns'
   ```
   It should stop incrementing once the battery is replaced.

---

## F-05
### 🟡 109 NVMe controller error-log entries

**Evidence**
```
Error Information Log Entries: 109
Media and Data Integrity Errors: 0
```

**Impact**
Low. Crucially, **media and data integrity errors are zero** — no data has been
corrupted at the device level. NVMe error-log entries accumulate from a wide range of
benign causes including aborted commands during unclean shutdowns, which is consistent
with [F-04](#f-04).

**Remediation**
Monitor. Inspect the actual entries if the count climbs after the battery is replaced:
```bash
sudo nvme error-log /dev/nvme0n1 | head -40
```
Escalate only if `Media and Data Integrity Errors` ever becomes non-zero.

---

## F-06
### 🟠 Gather Data Sampling (Downfall, CVE-2022-40982) reported vulnerable

**Evidence**
```
Vulnerability Gather data sampling: Vulnerable
```
All other mitigations report mitigated or not-affected.

**Impact**
Downfall allows a local attacker to extract data from AVX gather instructions across
security boundaries — including from other users and VMs. This CPU has full AVX-512,
making it squarely in scope.

**Remediation**
The mitigation ships in **CPU microcode**, not the kernel. On a live USB the running
microcode is whatever the BIOS supplied.

```bash
sudo apt install intel-microcode
sudo reboot
grep . /sys/devices/system/cpu/vulnerabilities/gather_data_sampling
```

Expect `Mitigation: Microcode` or `Not affected`. BIOS 1.50.1 is current
([F-15](#f-15)), so if it still reports vulnerable afterwards, the BIOS-supplied
microcode is already the latest available for this stepping.

**This is a day-one install task, not an optimization.**

---

## F-07
### 🟡 ESP undersized at 100 MiB

**Evidence** `/dev/nvme0n1p1` — 100 MiB FAT32, the Microsoft minimum and Dell factory
default. Already carrying `\EFI\Microsoft\`, `\EFI\Dell\`, `\EFI\Boot\`.

**Impact**
Workable for GRUB, which keeps kernels in `/boot` rather than on the ESP. But it
**structurally rules out systemd-boot and Unified Kernel Images**, since a single Mint
initramfs is ~100 MB. Enlarging it in place was impractical: the Microsoft Reserved
partition sits immediately behind it.

**Status — resolved by scope change.** The rebuild creates a **1 GiB ESP**, permanently
removing the constraint. See
[08 — Reference Architecture §3.2](08-reference-architecture.md#32-why-a-1-gib-esp).

---

## F-08
### 🟡 SSD running the slower 512 B LBA format

**Evidence**
```
Supported LBA Sizes (NSID 0x1)
Id Fmt  Data  Metadt  Rel_Perf
 0 +     512       0         3     <- in use
 1 -    4096       0         1     <- better
```

**Impact**
The drive runs the format it rates **worst**. NAND page and mapping granularity is
4 KiB; 512 B logical sectors force read-modify-write cycles and inflate the mapping
table. On a **DRAM-less** BG4 controller that table lives in borrowed host memory, so
the penalty is larger than on a DRAM-equipped drive.

**Status — resolved by scope change.** The reformat is destructive and was impossible
while Windows had to survive. It is now step 2 of the build:
```bash
sudo nvme format /dev/nvme0n1 --lbaf=1 --force
```

---

## F-09
### 🟠 AC adapter negotiating 45 W on a 65 W platform

**Evidence**
```
ucsi_source_psy_USBC000:002
in0:    15.00 V  (min +5.00 V, max +15.00 V)
curr1:   3.00 A  (max +3.00 A)
```
15 V × 3 A = **45 W**. The Latitude 7420 is rated for a **65 W** USB-C PD adapter.

**Impact**
Slow charging, and potential throttling under combined CPU+GPU load while charging —
the i5-1145G7 alone can draw 28 W PL2. It may also contribute to [F-04](#f-04): an
adapter at its ceiling cannot cover a peak draw that a healthy battery would normally
buffer, and this battery ([F-01](#f-01)) cannot.

**Remediation**
Verify the adapter's rating on its label. If it is a 45 W unit, replace it with the
correct Dell 65 W USB-C PD adapter. Re-check after replacement:
```bash
sensors | grep -A2 ucsi
```

---

## F-10
### 🔵 Secure Boot disabled

**Evidence** `mokutil --sb-state` → `SecureBoot disabled`. TPM 2.0 is present and
active.

**Impact**
No verification of the boot chain. More specifically, it weakens the TPM auto-unlock
design: **PCR 7 measures Secure Boot state**, so binding the LUKS key to PCR 7 with
Secure Boot disabled protects considerably less than it appears to.

**Remediation**
Enable after installation — every component of this machine uses an in-tree driver
([F-14](#f-14)), so there are no unsigned modules to break.
See [08 — Reference Architecture, Step 11](08-reference-architecture.md#step-11--enable-secure-boot).

---

## F-11
### 🔵 No swap configured

**Evidence** `swapon --show` → empty; `/proc/swaps` empty. (Expected — this was a live
session.)

**Impact**
None at audit time. Recorded because it drives a design decision: with 16 GB of
**soldered, unexpandable** RAM, swap sizing must be settled at build time.

**Status — resolved by build.** 20 GiB LVM swap inside LUKS (hibernation-capable) plus
4 GiB zram at priority 100. Rationale in
[08 — Reference Architecture §3.7](08-reference-architecture.md#37-why-20-gib-swap-plus-zram).

---

## F-12
### 🔵 Suspend behaviour unverified

**Impact**
The 7420 defaults to **S0ix / Modern Standby**. Linux support on Tiger Lake is good but
imperfect, and some units drain noticeably while suspended. On a healthy 61.9 Wh
battery that is a nuisance; on the current 14.6 Wh cell ([F-01](#f-01)) it would flatten
the machine overnight.

**Remediation** — verify after installation:
```bash
cat /sys/power/mem_sleep
```
- `[s2idle]` only → Modern Standby; no S3 exposed by this BIOS
- `s2idle [deep]` → S3 available

If drain is excessive and `deep` is available:
```
GRUB_CMDLINE_LINUX_DEFAULT="... mem_sleep_default=deep"
```
Measure empirically — record battery percentage before and after a several-hour suspend.

---

## F-13
### ✅ SSD health excellent

| Metric | Value |
|---|---|
| SMART overall | **PASSED** |
| Critical warning | `0x00` |
| Percentage used | **9%** |
| Available spare | 100% (threshold 50%) |
| **Media and data integrity errors** | **0** |
| Data units written | 27.9 TB |
| Power-on hours | 8,490 |
| Temperature | 34 °C idle |

Zero integrity errors across 27.9 TB written is a clean record. At 9% endurance
consumed after ~354 days of power-on time, the drive projects to a long remaining
life. **Safe to repartition and rely on.**

---

## F-14
### ✅ Complete native driver support

| Component | Driver | Status |
|---|---|---|
| CPU / power | `intel_pstate` (active mode) | ✅ |
| GPU — Iris Xe | `i915` | ✅ |
| NVMe SSD | `nvme` | ✅ |
| Wi-Fi — AX201 | `iwlwifi` | ✅ |
| Audio — TGL SST | `snd_hda_intel` / SOF available | ✅ |
| TPM 2.0 | `tpm_crb` | ✅ |
| Thermal / fan | `dell_smm`, `INT3400` | ✅ |
| Thunderbolt 4 | `thunderbolt` | ✅ |

**No proprietary drivers, DKMS modules, or out-of-tree patches are required.** This
directly enables Secure Boot ([F-10](#f-10)) without signing friction.

---

## F-15
### ✅ BIOS current

BIOS **1.50.1**, dated 2026-04-23. `fwupd` reports System Firmware `78337` with
`Update State: Success`. The machine is LVFS-supported, so future BIOS updates can be
applied from Linux with `fwupdmgr` — no Windows or bootable USB required.

---

## Root-cause linkage

Several findings are not independent. Treated as one chain:

```
F-01  Battery at 23.6% health
  │        (voltage sag under load)
  ├──────────────► F-04  26 unsafe shutdowns
  │                  │
  │                  ├──────► F-02  NTFS corruption (8,851 mismatches)
  │                  └──────► F-05  109 NVMe error-log entries
  │
  └── possibly aggravated by ──► F-09  45 W adapter on a 65 W platform
```

**Replacing the battery and verifying the adapter addresses four findings at once.**
Rebuilding the disk clears the downstream damage, but if F-01 and F-09 are left
unaddressed, F-04 will recur and corrupt the new Linux filesystem exactly as it
corrupted the old NTFS one.

---

## Action summary

| Priority | Action | Findings closed |
|---|---|---|
| 🔴 1 | Replace the battery | F-01, and prevents F-04 recurring |
| 🟠 2 | Verify / replace the AC adapter | F-09 |
| 🟠 3 | `apt install intel-microcode` at install time | F-06 |
| 🟠 4 | Rebuild the disk per [08 — Reference Architecture](08-reference-architecture.md) | F-02, F-03, F-07, F-08, F-11 |
| 🔵 5 | Enable Secure Boot after install | F-10 |
| 🔵 6 | Measure suspend drain | F-12 |
| 🔵 7 | Re-check unsafe shutdowns after 1 month | F-04, F-05 |
