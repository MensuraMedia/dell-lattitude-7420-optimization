# 03 — Partitioning Plan

> ⛔ **Do not execute anything in this document until every checkbox in**
> [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md) **is ticked.**
> The filesystem is currently corrupt and hibernated. Resizing it now would destroy data.

---

## Design constraints

Every decision below follows from facts established in
[01 — Hardware Inventory](01-hardware-inventory.md) and
[02 — Storage Analysis](02-storage-analysis.md):

| Constraint | Consequence for the plan |
|---|---|
| 16 GB RAM, **soldered** — never upgradeable | Swap sized for hibernation; no room to grow into later |
| **DRAM-less** KIOXIA BG4 SSD | Keep 15–20% free; avoid write-amplifying layouts; TRIM matters |
| ESP is **100 MiB** and impractical to enlarge | GRUB only. **systemd-boot / UKI is ruled out** |
| TPM 2.0 present + AES-NI in CPU | Full-disk encryption is free in performance terms — **use it** |
| Windows uses only 55 GB of 477 GB | ~400 GB genuinely reclaimable |
| Battery at 23.6% health | AC power mandatory during the operation |
| UEFI native, GPT | No MBR/CSM concerns |

---

## Recommended layout — dual-boot, encrypted Linux

Windows keeps a comfortable 120 GiB; Linux gets 356 GiB.

```
/dev/nvme0n1  (476.9 GiB, GPT)
│
├─ p1    100 MiB  EFI System Partition   FAT32    [KEEP — shared by Windows + GRUB]
├─ p2     16 MiB  Microsoft Reserved              [KEEP — do not touch]
├─ p3    120 GiB  Windows 11              NTFS    [SHRINK from 476 GiB]
├─ p5    356 GiB  Linux (LUKS2 container)         [NEW]
│         │
│         └─ LUKS2 → LVM VG "mintvg"
│              ├─ lv_root   100 GiB  ext4   →  /
│              ├─ lv_home   200 GiB  ext4   →  /home
│              ├─ lv_swap    20 GiB  swap   →  [hibernation-capable]
│              └─ ~36 GiB unallocated       →  [reserve: snapshots, growth]
│
└─ p4    797 MiB  Windows Recovery        NTFS    [KEEP — do not touch]
```

### Exact sector geometry

Sector size is 512 B, so 1 GiB = 2,097,152 sectors. All boundaries are
2048-sector aligned.

| Partition | Start (sector) | End (sector) | Sectors | Size | Action |
|---|---:|---:|---:|---|---|
| p1 ESP | 2,048 | 206,847 | 204,800 | 100 MiB | unchanged |
| p2 MSR | 206,848 | 239,615 | 32,768 | 16 MiB | unchanged |
| **p3 Windows** | 239,616 | **251,897,855** | **251,658,240** | **120 GiB** | **shrink** |
| **p5 Linux** | **251,897,856** | **998,580,223** | **746,682,368** | **356 GiB** | **create** |
| p4 WinRE | 998,580,224 | 1,000,212,479 | 1,632,256 | 797 MiB | unchanged |

Alignment check: `251,897,856 ÷ 2048 = 122,997` exactly. ✅

> The new partition is numbered **p5** because GPT slot 4 is already occupied by
> WinRE. Partition *numbers* need not match physical *order* — this is normal and
> correct. Do not renumber anything; Windows references WinRE by PARTUUID.

---

## Why these choices

### Why keep Windows at all?

Only you can answer this. Two facts inform it: Windows occupies just 55 GB and the
profile was last touched 2026-07-16. If Windows is genuinely unused, **Layout C**
(below) is simpler, safer, and faster. Dual-boot is the assumed default here only
because destroying an existing OS is not a decision to make on someone's behalf.

### Why 120 GiB for Windows?

Windows currently uses ~46 GB excluding scratch files. 120 GiB leaves room for
feature updates (which need 20–30 GB transiently), the pagefile, and a few
applications, without hoarding space. Shrinking below ~80 GiB makes future Windows
feature updates fail.

### Why LUKS2 full-disk encryption?

This is a **portable business laptop** with an end-of-life battery and no encryption
on the Windows side either. The CPU has **AES-NI and SHA-NI** — encryption overhead is
effectively unmeasurable on this hardware. There is no performance reason to skip it
and a strong physical-security reason to use it.

With TPM 2.0 present, the passphrase can be auto-released at boot after installation
(see [Optional: TPM auto-unlock](#optional-tpm-auto-unlock)) — encryption without a
daily passphrase prompt.

### Why LVM instead of raw partitions?

The 16 GB RAM is soldered and the disk is fixed at 512 GB. **This machine's resources
can never be expanded**, so the ability to re-slice space *internally* without moving
partitions is worth real money here. LVM lets you shrink `/home` and grow `/` later
with the volumes online. Raw partitions do not.

### Why ext4 rather than btrfs?

Btrfs offers snapshots, which Timeshift integrates with nicely. But:

- The BG4 is **DRAM-less**, and btrfs copy-on-write increases write amplification —
  the exact weakness of this controller.
- The drive is already at 9% endurance used.
- Timeshift's rsync mode works perfectly well on ext4 and is Mint's default.

**ext4 is the right trade for this specific drive.** If you strongly prefer btrfs
snapshots, see [Layout B](#layout-b--btrfs-alternative) — it is a legitimate choice,
just not the one this hardware argues for.

### Why a separate `/home`?

It lets you reinstall or replace the distribution without touching user data — the
single highest-value structural choice in a Linux layout. The cost (fixed sizes) is
neutralised by LVM.

### Swap sizing

20 GiB, i.e. RAM + 25%.

| Goal | Required swap |
|---|---|
| No swap use, zram only | 0 |
| Ordinary overcommit safety | 4–8 GiB |
| **Reliable hibernation (16 GB RAM)** | **≥ 16 GiB, 20 GiB with margin** |

Hibernation needs to write the *entire* RAM image plus headroom. 20 GiB guarantees it.

Given this battery is at 23.6% health and prone to sudden collapse,
**hibernate-on-critical-battery is a genuinely useful safety net** — it is the one
power feature that protects unsaved work on a dying battery. That justifies the
20 GiB even though it is generous.

Swap sits **inside** the LUKS container, so hibernation images are encrypted too —
important, since a hibernation image is a complete dump of RAM.

### Why leave ~36 GiB unallocated in the VG?

1. **DRAM-less SSD performance** degrades sharply when full. Unallocated LVM extents
   are never written, preserving SSD over-provisioning.
2. **LVM snapshots** need free extents to exist at all.
3. **Future flexibility** on a machine that can never be expanded.

This is deliberate headroom, not wasted space.

---

## Execution

### Method A — shrink from **within Windows** (recommended)

Counter-intuitive but correct: **let Windows shrink its own filesystem.** Windows
knows where its unmovable files (MFT, pagefile, volume shadow copies) live; Linux
tools have to infer it. This is the lowest-risk path.

1. Complete all of [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md),
   **including disabling the pagefile** — with hibernation and pagefile both off,
   Windows can shrink much further.
2. In Windows: **Disk Management** (`diskmgmt.msc`) → right-click `C:` → **Shrink Volume**
3. Enter the amount to shrink in MB: **364,544** (= 356 GiB)
4. Apply. Leave the resulting space **unallocated** — do not create a Windows volume in it.
5. Re-enable the pagefile, then shut down fully (`shutdown /s /t 0`).
6. Boot the Mint live USB and continue at [Creating the Linux layout](#creating-the-linux-layout).

> If Windows refuses to shrink that far, it is an unmovable file near the end of the
> volume — usually a shadow copy. Run `vssadmin delete shadows /all` as Administrator,
> then defragment (`defrag C: /X /U /V`) and retry. Fall back to Method B if needed.

### Method B — shrink with GParted from the live USB

Use only if Method A cannot reach the target size.

1. Boot the Mint live USB, connected to **AC power**.
2. Re-run all three verification checks from
   [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md#re-verification--from-the-mint-live-usb).
   ⛔ **If any check fails, stop.**
3. Launch **GParted** (`sudo gparted`).
4. Select `/dev/nvme0n1`, right-click `/dev/nvme0n1p3` → **Resize/Move**.
5. Set **New size** to `122880` MiB (120 GiB). Leave *free space preceding* at **0** —
   ⚠️ never move the partition's start; only its end.
6. **Apply.** Do not interrupt. This is the point of no return.

GParted calls `ntfsresize` internally, then adjusts the partition table. It will
refuse if the filesystem is still inconsistent — which is exactly why the
prerequisites exist.

<details>
<summary>Equivalent CLI (advanced — GParted is safer)</summary>

⚠️ **DESTRUCTIVE.** Filesystem must be shrunk *before* the partition, and the
partition must never end up smaller than the filesystem.

```bash
# 1. Shrink the filesystem first (dry run — ALWAYS do this first)
sudo ntfsresize --no-action --size 128849018880 /dev/nvme0n1p3

# 2. Real filesystem shrink (irreversible)
sudo ntfsresize --size 128849018880 /dev/nvme0n1p3

# 3. Then shrink the partition to match
sudo sgdisk --delete=3 /dev/nvme0n1
sudo sgdisk --new=3:239616:251897855 \
            --typecode=3:0700 \
            --change-name=3:"Basic data partition" \
            --partition-guid=3:fbd50fdb-8039-426e-b999-a091ee564d6b \
            /dev/nvme0n1
sudo partprobe /dev/nvme0n1
```

Preserving the original **PARTUUID** (`--partition-guid`) is essential — Windows BCD
and WinRE reference the partition by that GUID. Change it and Windows will not boot.

</details>

---

## Creating the Linux layout

From the Mint live USB, with ~356 GiB unallocated.

⚠️ Every command below is **DESTRUCTIVE** to the target region. Re-read
`lsblk` output and confirm device names before each one — device numbering can change.

```bash
# Confirm the current state first — never skip this
lsblk -o NAME,SIZE,TYPE,FSTYPE,PARTUUID /dev/nvme0n1
sudo parted /dev/nvme0n1 unit s print free
```

### 1. Create the Linux partition

```bash
sudo sgdisk --new=5:251897856:998580223 \
            --typecode=5:8309 \
            --change-name=5:"Linux LUKS" \
            /dev/nvme0n1
sudo partprobe /dev/nvme0n1
```
`8309` is the GPT type code for *Linux LUKS*. Use `8300` (*Linux filesystem*) if you
decide against encryption.

### 2. Create the LUKS2 container

```bash
sudo cryptsetup luksFormat --type luks2 \
     --cipher aes-xts-plain64 \
     --key-size 512 \
     --hash sha256 \
     --pbkdf argon2id \
     /dev/nvme0n1p5
```

Notes on these choices:
- `aes-xts-plain64` with a 512-bit key = AES-256-XTS, hardware-accelerated by AES-NI.
- `argon2id` is the LUKS2 default KDF and is memory-hard. On a 16 GB machine the
  default memory cost is fine — but note it is also used at *unlock* time, so do not
  raise it beyond available boot-time RAM.

```bash
sudo cryptsetup open /dev/nvme0n1p5 cryptmint
```

### 3. Build the LVM stack

```bash
sudo pvcreate /dev/mapper/cryptmint
sudo vgcreate mintvg /dev/mapper/cryptmint

sudo lvcreate -L 100G -n lv_root mintvg
sudo lvcreate -L  20G -n lv_swap mintvg
sudo lvcreate -L 200G -n lv_home mintvg
# ~36 GiB deliberately left unallocated

sudo vgs && sudo lvs      # verify
```

### 4. Create filesystems

```bash
sudo mkfs.ext4 -L mint-root /dev/mintvg/lv_root
sudo mkfs.ext4 -L mint-home /dev/mintvg/lv_home
sudo mkswap    -L mint-swap /dev/mintvg/lv_swap
```

### 5. Run the Mint installer

Launch **Install Linux Mint** and choose **"Something else"** (manual partitioning).
Assign:

| Device | Mount point | Filesystem | Format? |
|---|---|---|---|
| `/dev/mintvg/lv_root` | `/` | ext4 | ✅ yes |
| `/dev/mintvg/lv_home` | `/home` | ext4 | ✅ yes |
| `/dev/mintvg/lv_swap` | swap | — | — |
| **`/dev/nvme0n1p1`** | **`/boot/efi`** | **EFI System Partition** | **❌ NO — do not format** |

> ⛔ **Formatting the ESP will destroy the Windows Boot Manager and Dell's firmware
> update payloads.** The installer must be told to *use* it, not format it. This is
> the single most common way people break a dual-boot install.

Set **"Device for boot loader installation"** to `/dev/nvme0n1` (the disk, not a
partition).

### 6. Post-install: make encryption unlock correctly

The Mint installer does not always write `/etc/crypttab` correctly for a manually
created LUKS container. Before rebooting, chroot in and verify:

```bash
sudo mount /dev/mintvg/lv_root /mnt
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for d in dev dev/pts proc sys run; do sudo mount --bind /$d /mnt/$d; done
sudo chroot /mnt

# inside the chroot:
blkid /dev/nvme0n1p5     # note the LUKS UUID
echo "cryptmint UUID=<LUKS-UUID> none luks,discard" >> /etc/crypttab
update-initramfs -u -k all
update-grub
exit
```

`discard` in `/etc/crypttab` enables TRIM pass-through to the SSD through the LUKS
layer. On a DRAM-less drive this matters. It carries a minor, well-documented
information-leak trade-off (an attacker can infer how much space is used) — accept it
here; the SSD longevity benefit outweighs it on this hardware.

### 7. Fix the boot order

```bash
sudo efibootmgr -v     # find the "ubuntu" entry number
sudo efibootmgr -o <ubuntu>,0004,0000,0001
```
Put `ubuntu` (GRUB) first so the dual-boot menu appears. GRUB's `os-prober` will
detect Windows automatically; if it does not, ensure
`GRUB_DISABLE_OS_PROBER=false` in `/etc/default/grub` and re-run `sudo update-grub`.

---

## Optional: TPM auto-unlock

With TPM 2.0 active, LUKS can release the key automatically at boot — full-disk
encryption with no passphrase prompt. Do this **after** a confirmed-working install:

```bash
sudo systemd-cryptenroll --tpm2-device=auto \
     --tpm2-pcrs=0+7 /dev/nvme0n1p5
sudo update-initramfs -u -k all
```

PCR 0 binds to firmware and PCR 7 to Secure Boot state — the key is released only if
neither has been tampered with.

> **Keep your passphrase.** A BIOS update changes PCR 0 and will invalidate the TPM
> binding, requiring the passphrase and a re-enrol. That is the mechanism working as
> designed, not a failure.

---

## Layout B — btrfs alternative

If you prefer snapshot-based rollback (Timeshift integrates with btrfs natively) and
accept the extra write amplification on a DRAM-less drive:

```
p5 356 GiB → LUKS2 → btrfs (single filesystem, no LVM)
     ├─ @          →  /
     ├─ @home      →  /home
     ├─ @snapshots →  /.snapshots
     └─ @log, @cache → /var/log, /var/cache   [nodatacow, excluded from snapshots]
```

Mount options tuned for this SSD:
```
compress=zstd:1,ssd,noatime,space_cache=v2,discard=async
```

- `compress=zstd:1` — level 1 is fast and *reduces* total bytes written, partly
  offsetting CoW amplification. Worth it here.
- `discard=async` — batched TRIM; strictly better than synchronous `discard` on NVMe.
- `noatime` — removes a write on every read.
- No LVM: btrfs handles its own subvolume sizing, so LVM adds nothing.

Swap on btrfs requires a `nodatacow`, non-compressed swapfile:
```bash
sudo btrfs subvolume create /swap
sudo btrfs filesystem mkswapfile --size 20g /swap/swapfile
```

**This is a defensible choice.** ext4 is recommended above only because of this
drive's DRAM-less controller and existing 9% endurance consumption.

---

## Layout C — Linux only (wipe Windows)

⚠️⚠️ **DESTROYS WINDOWS COMPLETELY AND IRREVERSIBLY** ⚠️⚠️

Choose this only if Windows is confirmed unnecessary and data is backed up.
It is genuinely the better outcome if Windows is not being used: simpler, faster,
and it unlocks two improvements that dual-boot cannot have.

```
/dev/nvme0n1  (476.9 GiB, GPT)
├─ p1   512 MiB  EFI System Partition   FAT32   /boot/efi
├─ p2     1 GiB  /boot                  ext4    [unencrypted — kernels + initramfs]
└─ p3   475 GiB  LUKS2 → LVM "mintvg"
          ├─ lv_root  120 GiB  ext4  →  /
          ├─ lv_home  300 GiB  ext4  →  /home
          ├─ lv_swap   20 GiB  swap
          └─ ~35 GiB unallocated reserve
```

Advantages unique to this layout:

1. **A properly sized 512 MiB ESP**, removing the constraint documented in
   [02 — Storage Analysis](02-storage-analysis.md#esp-sizing-assessment).
2. **The 4 KiB LBA reformat becomes possible** — measurably better performance on
   this DRAM-less controller. Do it *before* partitioning:
   ```bash
   # ⚠️⚠️ ERASES THE ENTIRE DRIVE ⚠️⚠️
   sudo nvme format /dev/nvme0n1 --lbaf=1 --force
   ```

A separate unencrypted `/boot` is used here so GRUB does not have to unlock LUKS
itself — faster boot and fewer failure modes than GRUB's `cryptodisk` support.

---

## Rollback

**Before the resize** — everything is reversible. Nothing has been written.

**After the resize, before installing** — restore by growing NTFS back:
```bash
sudo sgdisk --delete=5 /dev/nvme0n1
# recreate p3 at its original extent, then:
sudo ntfsresize --size $(sudo blockdev --getsize64 /dev/nvme0n1p3) /dev/nvme0n1p3
```

**After installing Mint** — Windows is recoverable via WinRE (`p4`, intact), but the
Linux partition must be deleted and Windows expanded back, and the GRUB entry removed
with `efibootmgr -b <num> -B`.

**Insurance worth taking.** Save the partition table before you start:
```bash
sudo sgdisk --backup=/media/usb/nvme0n1-gpt-backup.bin /dev/nvme0n1
```
Restore with:
```bash
sudo sgdisk --load-backup=/media/usb/nvme0n1-gpt-backup.bin /dev/nvme0n1
```
This restores the *partition table only* — not filesystem contents. It rescues an
accidental deletion, not an interrupted resize. **It is not a substitute for a backup.**

---

## Summary of what to run, in order

| Step | Where | Reversible? |
|---|---|---|
| 1. Back up user data | Live USB (`mount -o ro`) or Windows | — |
| 2. `sgdisk --backup` partition table | Live USB | — |
| 3. `powercfg /h off` + disable Fast Startup | **Windows** | ✅ yes |
| 4. `chkdsk C: /f` + reboot ×2 | **Windows** | ✅ yes |
| 5. Verify all 3 checks pass | Live USB | ✅ yes |
| 6. Shrink C: to 120 GiB | **Windows Disk Mgmt** (or GParted) | ⚠️ **point of no return** |
| 7. Create p5, LUKS2, LVM, filesystems | Live USB | ❌ destructive to new region |
| 8. Install Mint — **do not format the ESP** | Installer | ❌ |
| 9. Fix `/etc/crypttab`, initramfs, boot order | chroot | ✅ yes |
| 10. Apply tuning | [05 — Post-Install Optimization](05-post-install-optimization.md) | ✅ yes |
