# Dell Latitude 7420 — Linux Mint Optimization & Partitioning

A complete hardware audit, storage analysis, partitioning design, and optimization
reference for **Linux Mint 22.3 "Zena"** on a **Dell Latitude 7420**
(Tiger Lake, i5-1145G7).

All data here was captured from a **live Linux Mint 22.3 USB session** on the target
machine on **2026-08-14**, before any modification of the internal disk.
**No destructive operation has been performed.**

---

## Status

> **AUDIT COMPLETE · DISK REBUILT THROUGH PHASE 5 · INSTALL PENDING**
>
> The owner confirmed the system is **new and no data requires retention**. Windows
> was discarded and the disk **has been rebuilt from bare metal** per
> **[08 — Reference Architecture](docs/08-reference-architecture.md)**.
>
> **Already executed** (see [10 — Change Log](docs/10-change-log.md)):
> - ✅ SSD reformatted to **4 KiB LBA** — now reports `Relative Performance: 0x1 Better (in use)`
> - ✅ New GPT: **1 GiB ESP** (was 100 MiB) + **2 GiB `/boot`** + **473.9 GiB LUKS container**
> - ✅ All three partitions verified **optimally aligned**; TRIM path confirmed to the device
> - ✅ ESP and `/boot` filesystems created
>
> **Remaining:** LUKS passphrase (owner-entered), LVM volumes, Mint install,
> `crypttab` repair, tuning. **The machine has not been rebooted** — it is still in
> the live USB session.

**One finding is not resolved by rebuilding: the battery is at 23.6% of design
health and must be replaced.** It is also the probable root cause of the disk
corruption found. See [F-01](docs/07-findings-and-risks.md#f-01).

---

## Start here

| If you want to… | Read |
|---|---|
| **Fill in the Mint installer screen** | **[09 — Installer Reference Table](docs/09-installer-reference-table.md)** |
| **Know what to do after the installer** | **[11 — Post-Boot Runbook](docs/11-post-boot-runbook.md)** |
| **Build the machine** | **[08 — Reference Architecture](docs/08-reference-architecture.md)** |
| See what was already done to this disk | [10 — Change Log](docs/10-change-log.md) |
| Know what's wrong with it | [07 — Findings & Risk Register](docs/07-findings-and-risks.md) |
| Set the BIOS correctly | [06 — BIOS/UEFI Configuration](docs/06-bios-uefi-configuration.md) |
| Tune it after installing | [05 — Post-Install Optimization](docs/05-post-install-optimization.md) |
| Understand cooling and power limits | [16 — Thermal & Power Architecture](docs/16-thermal-and-power-architecture.md) |
| Optimize cooling / measure gaming load | [17 — Cooling Optimization](docs/17-cooling-optimization.md) |
| **Pick up the gaming/cooling work after a reboot** | **[19 — Gaming & Cooling Runbook](docs/19-gaming-cooling-runbook.md)** |

---

## Contents

| Document | Purpose |
|---|---|
| [01 — Hardware Inventory](docs/01-hardware-inventory.md) | Component-level profile: CPU, RAM, SSD, GPU, Wi-Fi, TPM, battery, thermals |
| [02 — Storage Analysis](docs/02-storage-analysis.md) | Partition table as found, filesystem state, SSD health, ESP sizing |
| [03 — Partitioning Plan](docs/03-partitioning-plan.md) | *Superseded.* Dual-boot layout, retained for reference |
| [04 — Blockers & Prerequisites](docs/04-blockers-and-prerequisites.md) | *Superseded.* NTFS/hibernation remediation, retained for reference |
| [05 — Post-Install Optimization](docs/05-post-install-optimization.md) | Power, thermal, SSD, graphics, audio and desktop tuning |
| [06 — BIOS/UEFI Configuration](docs/06-bios-uefi-configuration.md) | Correct firmware settings, Secure Boot, Thunderbolt security |
| [07 — Findings & Risk Register](docs/07-findings-and-risks.md) | All 15 findings, severity-ranked, with root-cause linkage |
| **[08 — Reference Architecture](docs/08-reference-architecture.md)** | **The build. Target design, rationale, procedure, validation.** |
| **[09 — Installer Reference Table](docs/09-installer-reference-table.md)** | **The Mint installer screen, filled in. Sizes, mount points, format flags — copy at the keyboard.** |
| [10 — Change Log](docs/10-change-log.md) | Exactly what was executed, with verified before/after state |
| **[11 — Post-Boot Runbook](docs/11-post-boot-runbook.md)** | **Ordered task list from the end of the installer through full validation** |
| [12 — Build Log: First Boot](docs/12-build-log-first-boot.md) | First successful LUKS boot through full patching, with findings |
| [13 — Display & Keyboard Backlight](docs/13-display-and-keyboard-backlight.md) | Kernel 7.0 eDP backlight regression and BIOS keyboard timeout, with root cause and fixes |
| [14 — Backlight Architecture](docs/14-backlight-architecture.md) | How backlight control works end to end: PWM pin vs DPCD AUX, interface selection, firmware ownership, diagnostic method |
| [15 — Build Log: Post-Boot Tuning](docs/15-build-log-post-boot-tuning.md) | Runbook steps 5–16 applied; four tooling defects found and fixed |
| [16 — Thermal & Power Architecture](docs/16-thermal-and-power-architecture.md) | How power and heat are governed: MSR vs MMIO RAPL, EC fan ownership, `platform_profile` as a BIOS token, measurement pitfalls |
| [17 — Cooling Optimization](docs/17-cooling-optimization.md) | Measured thermal/power data under gaming load, applied configuration, reproducible procedure |
| [18 — Adversarial Review Log](docs/18-adversarial-review-log.md) | Two independent reviews of the cooling work: what survived verification, what did not, and the alternates not taken |
| **[19 — Gaming & Cooling Runbook](docs/19-gaming-cooling-runbook.md)** | **Ordered task list from the next reboot onward: 13 steps, commands, verification, and which script runs each** |
| [20 — Fan & Cooling Hardware](docs/20-fan-and-cooling-hardware.md) | Fan spec and measured capability, health assessment method and verdict, replaceability, airflow diagram, and every logical/physical cooling option with evidence |
| [scripts/](scripts/) | Diagnostics collector, guarded build script, post-install repair, backlight handoff, gaming baseline harness, gaming handoff report, aggressive cooling control |

---

## The machine

| Item | Value |
|---|---|
| Model | Dell Latitude 7420 |
| BIOS | 1.50.1 (2026-04-23) — current |
| CPU | Intel Core i5-1145G7 (Tiger Lake-UP3), 4C/8T, 400 MHz–4.4 GHz, AVX-512, AES-NI, SHA-NI |
| RAM | 16 GB LPDDR4x — **soldered, permanently unexpandable** |
| GPU | Intel Iris Xe (TigerLake-LP GT2), `i915` |
| SSD | KIOXIA KBG40ZNS512G, 512 GB NVMe — **DRAM-less BG4 controller** |
| Wi-Fi | Intel Wi-Fi 6 AX201, `iwlwifi` |
| Audio | Intel Tiger Lake-LP SST (SOF capable) |
| TPM | TPM 2.0, present and active |
| Firmware | UEFI native, GPT, Secure Boot capable |

**Hardware support is excellent.** Every component is driven natively by the Mint 22.3
kernel (6.14). No proprietary drivers, no DKMS, no out-of-tree modules — which is
precisely what makes Secure Boot practical here.

---

## Target configuration

```
/dev/nvme0n1 — 476.9 GiB, reformatted to 4096-byte LBA, GPT, UEFI
│
├─ p1    1 GiB    ESP           FAT32   → /boot/efi   [unencrypted]
├─ p2    2 GiB    boot          ext4    → /boot       [unencrypted]
└─ p3  ~473 GiB   cryptsystem   LUKS2   → AES-256-XTS, argon2id, TPM-unlockable
        │
        └─ LVM2  "vg_mint"
             ├─ lv_root   120 GiB  ext4  → /
             ├─ lv_home   280 GiB  ext4  → /home
             ├─ lv_swap    20 GiB  swap  → hibernation-capable, encrypted
             └─ ~53 GiB unallocated      → SSD over-provisioning + snapshot reserve

+ zram 4 GiB (zstd, priority 100) — absorbs swap before the SSD
```

Every layer traces to a **measured property of this machine**, not to generic advice.
The full derivation is in
[08 — Reference Architecture, Part 1](docs/08-reference-architecture.md#part-1--design-inputs).
Briefly:

- **LVM** because RAM and disk are both permanently fixed — internal re-slicing is the
  only flexibility obtainable.
- **ext4, not btrfs**, because the DRAM-less controller handles copy-on-write write
  amplification worst, and the drive is already at 9% endurance used.
- **LUKS2 by default** because the CPU has AES-NI and SHA-NI — encryption is free in
  performance terms, and TPM 2.0 makes it passphrase-free at boot.
- **20 GiB swap** because hibernation needs ≥ RAM, and hibernate-on-critical-battery
  is genuinely valuable on a cell this degraded.
- **~53 GiB left unallocated** because a DRAM-less SSD's performance collapses when
  full. This is over-provisioning, not waste.

---

## Findings summary

| Severity | ID | Finding | Resolution |
|---|---|---|---|
| 🔴 | [F-01](docs/07-findings-and-risks.md#f-01) | **Battery at 23.65% of design health** (14.6 Wh of 61.9 Wh) | **Hardware replacement — no software fix exists** |
| 🟠 | [F-04](docs/07-findings-and-risks.md#f-04) | 26 unsafe shutdowns (6.1% of all power cycles) | Root cause is F-01 |
| 🟠 | [F-06](docs/07-findings-and-risks.md#f-06) | Gather Data Sampling (Downfall) reported **Vulnerable** | `apt install intel-microcode` — day one |
| 🟠 | [F-09](docs/07-findings-and-risks.md#f-09) | AC adapter negotiating **45 W** on a 65 W platform | Verify and replace the adapter |
| 🟠 | [F-02](docs/07-findings-and-risks.md#f-02) | NTFS corrupt — 8,851 cluster accounting mismatches | Resolved by wipe |
| 🟠 | [F-03](docs/07-findings-and-risks.md#f-03) | 6.3 GB hibernation image (Fast Startup) | Resolved by wipe |
| 🟡 | [F-07](docs/07-findings-and-risks.md#f-07) | ESP undersized at 100 MiB | Resolved by wipe → 1 GiB |
| 🟡 | [F-08](docs/07-findings-and-risks.md#f-08) | SSD running 512 B LBA; 4096 B rated faster | Resolved by wipe → `nvme format --lbaf=1` |
| ✅ | [F-13](docs/07-findings-and-risks.md#f-13) | SSD health: SMART PASSED, 9% used, **0 integrity errors** | No action |

Several findings are one chain, not independent problems:

```
F-01  Battery at 23.6% health
  ├──► F-04  26 unsafe shutdowns
  │      ├──► F-02  NTFS corruption
  │      └──► F-05  109 NVMe error-log entries
  └── aggravated by ──► F-09  45 W adapter
```

**Replacing the battery and verifying the adapter closes four findings at once.**
Rebuilding the disk clears the downstream damage — but if F-01 and F-09 are left
unaddressed, F-04 will recur and corrupt the new Linux filesystem exactly as it
corrupted the old NTFS one.

---

## Build sequence

```
 1. Set BIOS                    → docs/06  (UEFI, CSM off, TPM on, Secure Boot off for now)
 2. nvme format --lbaf=1        → 4 KiB sectors     ⚠️ ERASES THE DRIVE
 3. parted: ESP / boot / LUKS   → docs/08 Step 3
 4. cryptsetup luksFormat       → LUKS2, AES-256-XTS, argon2id
 5. pvcreate → vgcreate → lvcreate
 6. mkfs
 7. Install Mint ("Something else")   — do NOT reboot at the end
 8. chroot: fix /etc/crypttab, initramfs, GRUB   ← skipping this = unbootable
 9. Reboot, verify
10. TPM auto-unlock             → systemd-cryptenroll
11. Enable Secure Boot          → shim-signed, re-enrol TPM
12. Apply tuning                → docs/05
13. Validate                    → docs/08 Part 6
```

---

## Reproducing the audit

```bash
sudo ./scripts/collect-diagnostics.sh
```

Writes a timestamped, **serial-redacted** report to `diagnostics/`. Strictly read-only:
it never writes to a block device, never mounts anything read-write, and never changes
configuration.

```bash
sudo ./scripts/collect-diagnostics.sh --no-redact   # full detail — DO NOT COMMIT
```

---

## Safety notes

- Commands that write to disk are marked ⚠️ **DESTRUCTIVE**. The diagnostic tooling
  never executes them.
- Device serials, the Dell service tag, MAC addresses and UUIDs are **redacted** from
  all committed output. **This is a public repository** — re-check anything you add.
- Device names (`/dev/nvme0n1pN`) reflect the layout at audit time and **change after
  repartitioning**. Always re-run `lsblk` before acting on any command here.
- Back up the GPT before partitioning:
  `sudo sgdisk --backup=/media/usb/gpt-backup.bin /dev/nvme0n1`
  (restores the partition *table* only — not filesystem contents).

---

## Audit environment

- Linux Mint 22.3 "Zena" (Ubuntu 24.04 "noble" base), live USB session
- Kernel 6.14.0-37-generic
- Live medium: 14.5 GB USB flash drive, booted UEFI
- Root filesystem: overlayfs over squashfs (non-persistent)
- Tooling installed for the audit: `smartmontools`, `nvme-cli`, `git`, `gh`

---

## License

Documentation released under [CC BY 4.0](LICENSE). Scripts under MIT.
Hardware-specific values apply to one machine — verify against your own before use.
