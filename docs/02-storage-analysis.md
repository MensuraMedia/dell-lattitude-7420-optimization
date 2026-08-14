# 02 — Storage Analysis

State of `/dev/nvme0n1` as found on 2026-08-14, before any modification.

---

## 1. Current partition table

Disk: `/dev/nvme0n1` — KIOXIA KBG40ZNS512G, 476.9 GiB, GPT
Sector size: 512 B logical / 512 B physical
Disk GUID: `34400F9E-59F2-416C-BBCD-AF4D5D02B27A`

| # | Start (s) | End (s) | Size | Type code | Filesystem | Flags | Purpose |
|---|---|---|---|---|---|---|---|
| — | 34 | 2047 | 2014 s (~1 MiB) | — | — | — | GPT alignment gap (normal) |
| 1 | 2,048 | 206,847 | **100 MiB** | `EF00` | FAT32 | boot, esp | EFI System Partition |
| 2 | 206,848 | 239,615 | **16 MiB** | `0C01` | — | msftres | Microsoft Reserved (MSR) |
| 3 | 239,616 | 998,580,223 | **476 GiB** | `0700` | NTFS | msftdata | **Windows 11 C:** |
| 4 | 998,580,224 | 1,000,212,479 | **797 MiB** | `2700` | NTFS | hidden, diag | Windows Recovery (WinRE) |
| — | 1,000,212,480 | 1,000,215,182 | 2703 s (~1.3 MiB) | — | — | — | GPT tail (normal) |

**Total unallocated space on the disk: 4,717 sectors ≈ 2.3 MiB.**
For practical purposes, the disk is **completely full at the partition level**.

This is the stock Dell factory / standard Windows 11 UEFI layout. Partitions are
2048-sector aligned, which is correct.

### Partition UUIDs (for reference)

| Partition | PARTUUID | FS UUID |
|---|---|---|
| p1 (ESP) | `8483e7c7-1c79-4eda-bfe9-83369c2b81ec` | `8C36-9C9D` |
| p2 (MSR) | `b2a52ea3-8d1f-4714-9a2e-3515ab26fd39` | — |
| p3 (Windows) | `fbd50fdb-8039-426e-b999-a091ee564d6b` | `F0B43844B4381018` |
| p4 (WinRE) | `6df35fc6-537d-4af2-8209-6f6b9920de11` | `D0CAEC2ACAEC0F12` |

---

## 2. There is no Linux installation

Confirmed: no ext4, XFS, btrfs, LVM, or LUKS signature exists anywhere on the
internal disk. The only Linux present is the **live USB** (`/dev/sda`, 14.5 GB,
FAT32, label `LINUX MINT`), running as an overlayfs on squashfs.

Installing Mint therefore requires **creating new space**, not adopting existing
partitions. There is only one way to do that on a disk with 2.3 MiB free:
**shrink `/dev/nvme0n1p3`.**

---

## 3. Filesystem occupancy — the encouraging part

```
Filesystem      Type     Size  Used Avail Use% Mounted on
/dev/nvme0n1p3  fuseblk  477G   55G  422G  12% /mnt/win
```

Windows occupies **55 GB of 477 GB — 12%**. There is ~422 GB of genuinely free space
inside the NTFS filesystem.

### Where the 55 GB goes

| Path | Size |
|---|---|
| `/Windows` | 27 GB |
| `/Program Files` | 6.7 GB |
| **`hiberfil.sys`** | **6.3 GB** |
| `/Users` | 5.5 GB |
| **`pagefile.sys`** | **2.9 GB** |
| `/Program Files (x86)` | 2.7 GB |
| `/ProgramData` | 2.0 GB |
| `/System Volume Information` | 1.8 GB |
| `swapfile.sys` | 16 MB |
| `$Recycle.Bin` | 2.6 MB |

There is exactly one user profile: `/Users/user` (last modified 2026-07-16).
`/Users` at 5.5 GB indicates a lightly-used installation — but **verify this against
the actual owner's expectations before touching anything**; user data may also live
on OneDrive or an external drive.

Note that `hiberfil.sys` + `pagefile.sys` + `swapfile.sys` = **9.2 GB** of the 55 GB
is Windows scratch space that disappears the moment hibernation is disabled and
reappears differently after. Real Windows footprint is closer to **46 GB**.

---

## 4. ⚠️ Blocker 1 — NTFS filesystem is inconsistent

A non-destructive `ntfsresize --info` query was run. It performs a consistency check
before reporting shrink headroom. Result:

```
Current volume size: 511150387712 bytes (511151 MB)
Current device size: 511150391296 bytes (511151 MB)
Checking filesystem consistency ...
100.00 percent completed
Accounting clusters ...
Cluster accounting failed at 7478 (0x1d36): extra cluster in $Bitmap
Cluster accounting failed at 7479 (0x1d37): extra cluster in $Bitmap
  ... (8,851 total mismatches) ...
Filesystem check failed! Totally 8851 cluster accounting mismatches.
ERROR: NTFS is inconsistent. Run chkdsk /f on Windows then reboot it TWICE!
The usage of the /f parameter is very IMPORTANT! No modification was
and will be made to NTFS by this software until it gets repaired.
```

### What this means

`$Bitmap` is NTFS's allocation map — the record of which clusters are in use.
"Extra cluster in `$Bitmap`" means the bitmap marks clusters as allocated that the
MFT does not actually reference. The filesystem's two accounts of "what is used"
disagree in **8,851 places**.

### Why it blocks resizing

`ntfsresize` must relocate every in-use cluster out of the region being truncated.
If the allocation map is wrong, it will either move the wrong clusters or fail to
move real data — **silently destroying files**. `ntfsresize` refuses to run, which is
correct and protective behaviour.

**GParted uses `ntfsresize` internally and will refuse for the same reason.**
Windows' own Disk Management will also typically fail or produce a corrupt result.

### Severity

**Not, in itself, alarming.** This class of inconsistency is the routine aftermath of
unclean shutdowns — and this machine has recorded **26 unsafe shutdowns**. `chkdsk`
repairs it reliably. But it is an **absolute hard stop** for partitioning.

### Fix

See [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md).

---

## 5. ⚠️ Blocker 2 — Hibernation / Fast Startup is active

```
-rwxrwxrwx 1 root root 6757179392 Aug 14 12:07 hiberfil.sys
```

A 6.3 GB `hiberfil.sys` exists and was **written today at 12:07**, shortly before this
audit. Windows was not shut down — it was **hibernated**, almost certainly by
Windows 11's **Fast Startup**, which is enabled by default and performs a partial
hibernation on every "Shut down".

### Why it blocks resizing

When Windows hibernates, RAM state — including the filesystem's in-memory metadata
and cache — is frozen to disk. On resume, Windows restores that state and assumes the
on-disk filesystem is **exactly** as it left it.

If Linux shrinks the partition while a hibernation image exists, Windows resumes into
a filesystem that no longer matches its cached metadata. The result is severe
corruption, frequently unrecoverable.

This is also why the `ntfs3`/`ntfs-3g` drivers mount hibernated volumes **read-only**
by default. That protection saved this session — the audit mount was explicitly `ro`.

### Compounding factor

While `hiberfil.sys` exists, `chkdsk` cannot fully repair the volume either, because
Windows will resume from the hibernation image rather than performing a true boot.
**Blocker 2 must be cleared before Blocker 1 can be fixed.** Order matters.

---

## 6. ESP sizing assessment

The ESP (`/dev/nvme0n1p1`) is **100 MiB**.

| | |
|---|---|
| Microsoft minimum | 100 MiB |
| Dell factory default | 100 MiB |
| **Modern Linux best practice** | **512 MiB – 1 GiB** |

100 MiB is workable but tight for dual-boot. It must hold:
- `\EFI\Microsoft\` — Windows Boot Manager (~30 MiB with recovery)
- `\EFI\Dell\` — Dell firmware update payloads and logs (already present)
- `\EFI\Boot\` — fallback bootloader
- `\EFI\ubuntu\` — GRUB, shim, MOK manager (new, ~10 MiB)

Contents observed on the ESP today:
```
/EFI/Microsoft/Boot
/EFI/Microsoft/Recovery
/EFI/Boot/bootx64.efi
/EFI/Dell/logs
/EFI/Dell/bios
```

### Practical risk

With GRUB installed alongside, ~100 MiB will hold everything **as long as kernels are
not staged on the ESP**. Mint's default GRUB setup keeps kernels and initramfs in
`/boot` on the root filesystem, not on the ESP, so this is fine.

**It would not be fine if you chose systemd-boot or any Unified Kernel Image (UKI)
scheme**, which places kernels + initramfs directly on the ESP. Each Mint initramfs is
~100 MB — a single kernel would not fit. This constraint **rules out systemd-boot on
this machine** unless the ESP is enlarged.

### Can the ESP be enlarged?

Not easily. `p2` (Microsoft Reserved) sits immediately after it at sector 206,848,
and `p3` immediately after that. Growing `p1` requires moving both — a long,
risky operation on a live Windows install for marginal benefit.

**Recommendation: keep the 100 MiB ESP and use GRUB.** Do not create a second ESP —
some firmware handles multiple ESPs poorly, and Dell's firmware update mechanism
expects to find its payloads on the first one. Revisit only if the machine is ever
wiped Linux-only, in which case build a 512 MiB ESP from scratch.

---

## 7. Boot configuration

Secure Boot: **disabled**. Boot order and entries:

| Order | ID | Entry |
|---|---|---|
| 1 | `0002` | UEFI USB Flash Disk (**current — the live USB**) |
| 2 | `0000` | UEFI KIOXIA NVMe → `\EFI\Boot\BootX64.efi` (auto-created) |
| 3 | `0004` | **Windows Boot Manager** → `\EFI\Microsoft\Boot\bootmgfw.efi` |
| 4 | `0001` | UEFI HTTPs Boot |

Boot entries are healthy. After installing Mint, a `ubuntu` entry will be added and
should be placed **first** in the boot order so GRUB presents the dual-boot menu.

Note entry `0000` is an auto-created fallback pointing at the ESP's generic
`\EFI\Boot\BootX64.efi`. Dell firmware regenerates these; it is harmless.

---

## 8. SSD health — see also [01 — Hardware Inventory](01-hardware-inventory.md#health-smart-nvme-log-0x02)

| Metric | Value | Assessment |
|---|---|---|
| SMART overall | **PASSED** | ✅ |
| Percentage used | 9% | ✅ ~91% endurance left |
| Available spare | 100% | ✅ |
| Media/data integrity errors | **0** | ✅ |
| Power-on hours | 8,490 | |
| Power cycles | 423 | |
| Unsafe shutdowns | **26** | ⚠️ 6% of power cycles were unclean |
| Error log entries | 109 | ⚠️ |
| Temperature | 34 °C | ✅ |

**The drive is healthy and safe to repartition** once the filesystem blockers are
cleared. The unsafe-shutdown count correlates strongly with both the NTFS corruption
and the 23.6%-health battery — treat them as one linked issue, not three.

---

## 9. LBA format opportunity (informational)

The drive supports two sector formats:

| Format | Data size | Metadata | Relative performance |
|---|---|---|---|
| 0 (**in use**) | 512 B | 0 | `3` (worst) |
| 1 | 4096 B | 0 | **`1` (best)** |

The drive is running the **slower** format. Switching to 4 KiB LBA aligns the
logical sector size with the NAND page/mapping granularity and typically improves
write performance and reduces write amplification — particularly valuable on a
DRAM-less controller like the BG4.

⚠️ **This requires `nvme format --lbaf=1`, which erases the entire drive.**
It is only worth doing if the machine is being wiped completely (Linux-only install
with no Windows to preserve). It cannot be done in a dual-boot scenario without
destroying Windows.

If you ever do a clean Linux-only install on this machine, do it **before**
partitioning:
```bash
# ⚠️⚠️ DESTRUCTIVE — ERASES THE ENTIRE DRIVE ⚠️⚠️
sudo nvme format /dev/nvme0n1 --lbaf=1 --force
```
Recorded here as a documented opportunity, **not** a recommendation for the current
dual-boot path.

---

## 10. Summary

| Item | Status |
|---|---|
| Disk partition-level free space | ❌ 2.3 MiB — effectively zero |
| Existing Linux install | ❌ none |
| Windows filesystem occupancy | ✅ 55 GB / 477 GB (12%) |
| Reclaimable after repair | ✅ ~400 GB |
| NTFS consistency | ❌ **8,851 mismatches — blocks resize** |
| Hibernation file | ❌ **6.3 GB present — blocks resize** |
| ESP size | ⚠️ 100 MiB — adequate for GRUB, rules out systemd-boot |
| SSD health | ✅ PASSED, 9% used, 0 errors |
| Partition alignment | ✅ correct (2048-sector) |
| GPT integrity | ✅ valid |

**Nothing here is unfixable. But nothing can proceed until the two blockers are
cleared from within Windows.**
