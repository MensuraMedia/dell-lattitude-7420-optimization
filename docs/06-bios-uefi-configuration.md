# 06 — BIOS/UEFI Configuration

Firmware settings for running Linux Mint on the Dell Latitude 7420.
Current BIOS: **1.50.1** (2026-04-23) — current, no update needed.

Enter setup by pressing **F2** repeatedly at the Dell logo.
One-time boot menu: **F12**.

---

## Current state (as audited)

| Setting | Observed value | Assessment |
|---|---|---|
| Boot mode | **UEFI** (native, no CSM) | ✅ correct |
| SATA operation | **AHCI/NVMe** — inferred, see below | ✅ correct |
| Secure Boot | **Disabled** | ⚠️ works, but see below |
| TPM | **2.0, active** (`/dev/tpm0` present) | ✅ correct |
| Virtualization | **VT-x, EPT, VPID enabled** | ✅ correct |
| Boot order | USB → NVMe → Windows Boot Manager → HTTPs | ⚠️ reorder after install |

### How SATA operation was confirmed

This is the single most common cause of "the installer can't see my disk" on Dell
laptops. Dell ships the 7420 with **SATA Operation = RAID On** (Intel RST), which
hides the NVMe drive from any OS without the RST driver — including every Linux
installer.

**On this machine it is already correct.** The audit found the drive enumerated as
`/dev/nvme0n1` with `Kernel driver in use: nvme` at PCI address `01:00.0`. That only
happens in AHCI/NVMe mode. **No change is required.**

> ⚠️ If you ever *do* switch this setting, note that **Windows will fail to boot**
> with an `INACCESSIBLE_BOOT_DEVICE` bugcheck unless you first enable safe mode:
> ```cmd
> bcdedit /set {current} safeboot minimal
> ```
> …change the BIOS setting, boot Windows once in safe mode, then:
> ```cmd
> bcdedit /deletevalue {current} safeboot
> ```
> Since the setting is already correct here, **do not touch it.**

---

## Recommended settings

### System Configuration

| Setting | Value | Reason |
|---|---|---|
| **SATA Operation** | **AHCI/NVMe** | Required for Linux to see the SSD. **Already set — leave alone.** |
| Integrated NIC | Enabled w/ PXE (or Disabled) | Only matters with a dock |
| USB Configuration → Enable USB Boot Support | **Enabled** | Required to boot the live USB |
| Thunderbolt Adapter Configuration | Enabled | `thunderbolt` driver is native |
| Thunderbolt Security Level | **User Authorization** | Balances DMA protection vs usability |
| Enable Thunderbolt Boot Support | Disabled | Reduces attack surface |
| Enable Thunderbolt pre-boot modules | Disabled | Reduces attack surface |

> **Thunderbolt security matters on a portable machine.** "No Security" permits DMA
> from any connected device — a real attack vector. "User Authorization" requires
> approval per device; `boltctl` manages this from Linux.

### Boot Configuration

| Setting | Value | Reason |
|---|---|---|
| Boot List Option | **UEFI** | GPT + UEFI. Never Legacy/CSM. |
| **Enable Legacy Option ROMs / CSM** | **Disabled** | CSM breaks UEFI dual-boot |
| Enable Attempt Legacy Boot | Disabled | — |
| Boot sequence | Reorder after install (below) | — |

### Security

| Setting | Recommended | Reason |
|---|---|---|
| **TPM 2.0 Security** | **On** | Enables LUKS TPM auto-unlock |
| TPM State | Enabled, Activated | — |
| PPI Bypass for Clear Command | Disabled | Prevents silent TPM wipe |
| **Secure Boot** | **See discussion below** | Currently disabled |
| Intel SGX | Software Controlled | Unused by Linux desktop |
| **Absolute® / Computrace** | **Disabled** — unless corporate policy requires it | Firmware-level persistence agent |
| Admin (Setup) Password | **Set one** | Prevents boot-order tampering |
| Master Password Lockout | Disabled | Leave alone |

> ⚠️ **Absolute (Computrace)** is a firmware-resident tracking agent that reinstalls
> itself into the OS. It cannot be removed once *activated* — only before. If this is
> a company-managed asset, leave it as policy dictates. On a personally owned machine,
> disable it.

> ⚠️ **Do not set a hard drive (HDD) password.** It is separate from LUKS, cannot be
> recovered if forgotten, and adds nothing on top of full-disk encryption.

### Virtualization Support

| Setting | Value |
|---|---|
| Intel Virtualization Technology (VT-x) | **Enabled** ✅ already |
| VT for Direct I/O (VT-d) | **Enabled** |
| Trusted Execution | Off |
| DMA Protection → Pre-boot DMA Support | Enabled |
| DMA Protection → Kernel DMA Support | Enabled |

VT-d plus Kernel DMA Protection enables the IOMMU, which protects against DMA attacks
from Thunderbolt/PCIe devices. Linux uses it automatically. Both are also required if
you intend to run VMs with device passthrough.

### Power Management

| Setting | Recommended | Reason |
|---|---|---|
| **Enable Advanced Battery Charge Mode** | Disabled | Conflicts with Linux `charge_control_*` thresholds |
| **Primary Battery Charge Configuration** | **Adaptive**, or Custom 75%/80% | See discussion |
| Enable Block Sleep | Disabled | Would prevent suspend |
| Enable USB Wake Support | Enabled | Wake from external keyboard |
| **Power On Lid Open** | **Your call — see below** | ⚠️ **Enabled.** Cold-boots the machine from S5 whenever the lid opens |
| **Enable Lid Switch** | **Enabled** | Master enable for the lid sensor; disabling also kills lid-close suspend |
| Wake on Dell USB-C Dock | Enabled | Dock attach wakes the system |
| Wake on AC | Disabled | ✅ already |
| Enable Intel Speed Shift Technology | **Enabled** | Required for HWP / `intel_pstate` active mode |
| Enable Thermal Management | **Optimized** | Balanced fan curve |
| **Block Sleep (S0ix / Modern Standby)** | see below | — |

#### Charge thresholds — BIOS or Linux, not both

Two mechanisms exist and they conflict:

1. **BIOS: Primary Battery Charge Configuration → Custom** (set 75% start / 80% stop)
2. **Linux: TLP** writing `/sys/class/power_supply/BAT0/charge_control_*`

The kernel exposes those sysfs nodes on this machine (confirmed in the audit), so
**either works**. Pick one:

- **BIOS thresholds** — enforced regardless of OS, survives reboots into Windows.
  **Recommended for a dual-boot machine.**
- **TLP thresholds** — easier to change on the fly, Linux-only.

If you set thresholds in the BIOS, remove `START_CHARGE_THRESH_BAT0` /
`STOP_CHARGE_THRESH_BAT0` from the TLP config in
[05 — Post-Install Optimization](05-post-install-optimization.md).

> Applies to the **replacement** battery. The current cell at 23.6% health has
> nothing left to protect.

#### Lid behaviour — firmware vs OS

**Power On Lid Open** (`PowerOnLidOpen`) is enabled on this machine, which is Dell's
factory default. It is an **embedded-controller** function: with the system fully
off (S5), opening the lid asserts power exactly as a power-button press would. It
is independent of the operating system and of every `logind` and desktop setting.

This is not the same thing as the lid **waking** a sleeping machine — that is
`/proc/acpi/wakeup`'s `LID0` entry, which only applies once the system is actually
asleep. Two mechanisms, two states, frequently confused.

> ⚠️ Between 2026-08-16 and 2026-08-22 this machine **could not suspend at all** —
> `sleep.target` and friends were masked outside the tooling — so S5 was the only
> low-power state it ever reached, and every lid open was a cold boot. Corrected
> 2026-08-22. Full analysis, evidence and the polkit hibernate block:
> **[21 — Lid Power-On & Sleep](21-lid-power-and-sleep.md)**.

#### Modern Standby (S0ix) vs S3

The 7420 defaults to **S0ix / Modern Standby**. Linux support on Tiger Lake is good
but not flawless — some users see battery drain during suspend.

Check what the firmware offers:
```bash
cat /sys/power/mem_sleep
```
- `[s2idle]` only → Modern Standby, no S3 available in this BIOS
- `s2idle [deep]` → S3 available and selected

**Confirmed on this machine 2026-08-22: `[s2idle]` only.** `dmesg` agrees —
`ACPI: PM: (supports S0 S4 S5)`, with no S3 declared. BIOS 1.50.1 exposes no option
to change this, so `mem_sleep_default=deep` would be inert here. Suspend-to-RAM on
this laptop means s2idle, and idle drain depends on runtime PM rather than a
hardware sleep state.

If suspend drains the battery excessively, look for **"Enable S3 sleep"** or a
sleep-state option under Power Management. Not all 7420 BIOS revisions expose it. If
`deep` is available, force it:
```bash
# /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT="... mem_sleep_default=deep"
sudo update-grub
```

On a battery at 23.6% health this is worth checking — suspend drain that would be
unnoticeable on a healthy cell will flatten this one overnight.

### POST Behaviour

| Setting | Value | Reason |
|---|---|---|
| Fastboot | **Thorough** | Full device init; more reliable dual-boot detection |
| Extend BIOS POST Time | 0 seconds | — |
| Fn Lock Options | Personal preference | — |

`Fastboot = Minimal` occasionally skips USB controller init, which can prevent the
live USB from being detected. **Thorough** avoids a class of frustrating problems for
a cost of about a second.

---

## Secure Boot — enable or not?

Currently **disabled**. Both choices are defensible.

### Keep it disabled

- Simplest. Nothing to configure.
- Required if you will ever build out-of-tree kernel modules (VirtualBox, proprietary
  drivers, DKMS packages) without signing them.
- **This machine needs no such modules** — every component has an in-tree driver
  (see [01 — Hardware Inventory](01-hardware-inventory.md#10-summary-of-driver-support)).

### Enable it (recommended here)

- Mint supports Secure Boot natively via `shim-signed` + signed GRUB.
- Protects against bootkits — meaningful on a portable business laptop.
- **Required for meaningful TPM PCR 7 binding.** If you use the TPM auto-unlock
  described in [03 — Partitioning Plan](03-partitioning-plan.md#optional-tpm-auto-unlock),
  PCR 7 measures Secure Boot state. With Secure Boot off, that measurement protects
  much less.

### To enable it

1. **Install Mint first, with Secure Boot disabled.** Enabling it before installation
   complicates the process needlessly.
2. Ensure the signed bootloader is present:
   ```bash
   sudo apt install --reinstall shim-signed grub-efi-amd64-signed
   sudo update-grub
   ```
3. Reboot into BIOS → Secure Boot → **Enabled**, Secure Boot Mode → **Deployed Mode**
4. If prompted, enroll a MOK password and complete enrollment on the next boot.
5. Verify from Linux:
   ```bash
   mokutil --sb-state     # expect "SecureBoot enabled"
   ```

> If the machine fails to boot after enabling Secure Boot, re-enter setup and disable
> it. Nothing is damaged — it is a firmware policy toggle, fully reversible.

---

## Boot order after installing Mint

The installer adds a `ubuntu` (GRUB) entry. Dell firmware sometimes places Windows
Boot Manager first, which bypasses the GRUB menu entirely.

From Linux:
```bash
sudo efibootmgr -v                  # identify the ubuntu entry number
sudo efibootmgr -o <ubuntu>,0004,0000,0001
```

Or in the BIOS: **Boot Configuration → Boot Sequence** → move **ubuntu** to the top.

The pre-install order was:
```
0002  UEFI USB Flash Disk          (live media)
0000  UEFI KIOXIA NVMe (fallback)
0004  Windows Boot Manager
0001  UEFI HTTPs Boot
```

If GRUB does not offer Windows, enable OS detection:
```bash
# /etc/default/grub
GRUB_DISABLE_OS_PROBER=false
```
```bash
sudo update-grub
```

---

## Firmware updates from Linux

The 7420 is fully supported by the LVFS — BIOS updates work from Linux without a
Windows installation or a bootable USB:

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-devices
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

`fwupd` reported these updatable devices on this machine: **System Firmware (BIOS)**,
**KIOXIA NVMe SSD firmware**, **Intel CPU microcode**, Thunderbolt, and the ME.

⚠️ **Before any firmware update:**
- Connect AC power (`fwupd` refuses without it).
- **A BIOS update changes PCR 0** and will break a TPM-bound LUKS auto-unlock. Keep
  your passphrase to hand and re-enrol afterwards with `systemd-cryptenroll`.
- SSD firmware updates carry a small but nonzero risk. Given the drive is healthy
  (SMART PASSED, 0 errors), there is no pressing reason to update it.

---

## Pre-installation BIOS checklist

- [ ] Boot mode = **UEFI**, CSM/Legacy Option ROMs **Disabled**
- [ ] SATA Operation = **AHCI/NVMe** (already correct — verify, don't change)
- [ ] USB Boot Support = **Enabled**
- [ ] Fastboot = **Thorough**
- [ ] TPM 2.0 = **On / Activated**
- [ ] VT-x and VT-d = **Enabled**
- [ ] Intel Speed Shift = **Enabled**
- [ ] Secure Boot = **Disabled** during installation (optionally enable afterwards)
- [ ] **Power On Lid Open** — decide deliberately; **Enabled** by default ([21](21-lid-power-and-sleep.md))
- [ ] Admin/Setup password set
- [ ] AC power connected
