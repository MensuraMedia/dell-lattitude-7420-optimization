# 10 — Change Log

An exact record of what was executed on this machine, with verified before/after
state. Every command that ran against the disk is listed.

---

## 2026-08-14 — Bare-metal rebuild

**Operator authorisation:** owner confirmed the system is new and **no data requires
retention**. Windows and all existing partitions discarded.

**Environment:** Linux Mint 22.3 live USB, kernel 6.14.0-37-generic, UEFI mode,
**AC power connected** (verified `online: 1` before starting).

---

### Phase 0 — Audit (read-only, no changes)

Tooling installed into the live session's overlay (not persistent):
`smartmontools`, `nvme-cli`, `git`, `gh`.

Windows and ESP partitions were mounted **read-only** for inspection and unmounted
before any write. Findings recorded in
[07 — Findings & Risk Register](07-findings-and-risks.md).

---

### Phase 1 — State before

```
Disk /dev/nvme0n1: 1000215216 sectors, 476.9 GiB
Sector size (logical/physical): 512/512 bytes
Disk identifier (GUID): 34400F9E-59F2-416C-BBCD-AF4D5D02B27A
Total free space is 4717 sectors (2.3 MiB)

Number  Start (sector)    End (sector)  Size       Code  Name
   1            2048          206847   100.0 MiB   EF00  Basic data partition
   2          206848          239615   16.0 MiB    0C01  Microsoft reserved
   3          239616       998580223   476.0 GiB   0700  Basic data partition   (Windows 11, NTFS)
   4       998580224      1000212479   797.0 MiB   2700  Windows Recovery
```

Archived verbatim at [`diagnostics/original-partition-table.txt`](../diagnostics/original-partition-table.txt).

State at this point:
- Windows 11 occupying 55 GB of 477 GB
- NTFS **inconsistent** — 8,851 cluster accounting mismatches ([F-02](07-findings-and-risks.md#f-02))
- `hiberfil.sys` 6.3 GB present, Fast Startup active ([F-03](07-findings-and-risks.md#f-03))
- 2.3 MiB unallocated — effectively no room for any Linux install
- SSD running 512 B LBA, its worst-rated format ([F-08](07-findings-and-risks.md#f-08))
- ESP 100 MiB, ruling out UKI/systemd-boot ([F-07](07-findings-and-risks.md#f-07))

---

### Phase 2 — Pre-flight safety checks ✅

| Check | Result |
|---|---|
| AC power online | `1` ✅ |
| Battery state | 100%, Full |
| Target device confirmed | `/dev/nvme0n1` — KIOXIA 512 GB NVMe ✅ |
| Live USB distinguished | `/dev/sda1` mounted at `/cdrom` — **not** the target ✅ |
| Partitions unmounted | `/mnt/esp`, `/mnt/win` unmounted; `swapoff -a` ✅ |
| Nothing mounted from target | verified clear ✅ |
| Original layout archived | `diagnostics/original-partition-table.txt` ✅ |

---

### Phase 3 — ⚠️ SSD reformat to 4 KiB LBA

```bash
sudo nvme format /dev/nvme0n1 --lbaf=1 --force
```

```
Success formatting namespace:1
```

**Verified:**
```
$ sudo blockdev --getss /dev/nvme0n1
4096
$ sudo blockdev --getpbsz /dev/nvme0n1
4096
$ sudo nvme id-ns /dev/nvme0n1 -H | grep 'in use'
LBA Format  1 : Metadata Size: 0 bytes - Data Size: 4096 bytes
                - Relative Performance: 0x1 Better (in use)
```

**Result:** the drive moved from its worst-rated format (512 B, `Rel_Perf 3`) to its
best (4096 B, `Rel_Perf 1`). Closes [F-08](07-findings-and-risks.md#f-08).

Rationale: [08 — Reference Architecture §3.1](08-reference-architecture.md#31-why-reformat-to-4-kib-lba).
Addressable sector count changed from 1,000,215,216 (512 B) to 125,026,902 (4 KiB) —
same 512 GB, larger sectors.

---

### Phase 4 — ⚠️ New GPT partition table

```bash
sudo parted -s /dev/nvme0n1 mklabel gpt
sudo parted -s /dev/nvme0n1 mkpart ESP fat32 1MiB 1025MiB
sudo parted -s /dev/nvme0n1 set 1 esp on
sudo parted -s /dev/nvme0n1 mkpart boot ext4 1025MiB 3073MiB
sudo parted -s /dev/nvme0n1 mkpart cryptsystem 3073MiB 100%
sudo sgdisk --typecode=1:ef00 --typecode=2:8300 --typecode=3:8309 /dev/nvme0n1
sudo partprobe /dev/nvme0n1
```

**Result:**
```
Disk /dev/nvme0n1: 125026902 sectors, 476.9 GiB
Sector size (logical/physical): 4096/4096 bytes
Disk identifier (GUID): 62881706-43F5-4D93-8991-9A887DF256EF
Partitions will be aligned on 256-sector boundaries

Number  Start (sector)    End (sector)  Size        Code  Name
   1             256          262399   1024.0 MiB  EF00  ESP
   2          262400          786687   2.0 GiB     8300  boot
   3          786688       125026815   473.9 GiB   8309  cryptsystem
```

**Alignment verified — all three optimal:**
```
p1: 1 aligned
p2: 2 aligned
p3: 3 aligned
```

Note the 256-sector alignment granularity: 256 × 4096 B = 1 MiB, the same physical
1 MiB boundary as the old 2048 × 512 B. Alignment is preserved across the reformat.

---

### Phase 5 — Boot filesystems

```bash
sudo mkfs.vfat -F32 -n ESP  /dev/nvme0n1p1
sudo mkfs.ext4 -F   -L boot /dev/nvme0n1p2
```

**Result:**
```
/dev/nvme0n1p1: LABEL="ESP"  UUID="6913-0F75"                             TYPE="vfat" BLOCK_SIZE="4096"
/dev/nvme0n1p2: LABEL="boot" UUID="826b3c21-476e-4ddb-ba18-069b031bf589"  TYPE="ext4" BLOCK_SIZE="4096"
```

`/boot` (ext4): 524,288 × 4 KiB blocks, 131,072 inodes, journal enabled.

**TRIM path verified end-to-end:**
```
NAME        DISC-ALN DISC-GRAN DISC-MAX DISC-ZERO
nvme0n1            0        4K       2T         0
├─nvme0n1p1        0        4K       2T         0
├─nvme0n1p2        0        4K       2T         0
└─nvme0n1p3        0        4K       2T         0
```
Non-zero `DISC-GRAN`/`DISC-MAX` confirms discard reaches the device — a prerequisite
for the DRAM-less controller's long-term performance
([D2](08-reference-architecture.md#part-1--design-inputs)).

---

### Phase 6 — LUKS2 container ⏸️ **awaiting operator passphrase**

Deliberately **not** automated: the passphrase must be typed by the owner and must
never appear in a transcript or a repository.

```bash
sudo cryptsetup luksFormat --type luks2 \
     --cipher aes-xts-plain64 --key-size 512 \
     --hash sha256 --pbkdf argon2id \
     --label cryptsystem /dev/nvme0n1p3

sudo cryptsetup open /dev/nvme0n1p3 cryptsystem
```

Parameter rationale: [08 — Reference Architecture §3.4](08-reference-architecture.md#34-why-luks2-with-these-parameters).

---

### Phase 7 — LVM + filesystems ⏸️ pending Phase 6

```bash
sudo pvcreate /dev/mapper/cryptsystem
sudo vgcreate vg_mint /dev/mapper/cryptsystem
sudo lvcreate -L 120G -n lv_root vg_mint
sudo lvcreate -L 280G -n lv_home vg_mint
sudo lvcreate -L  20G -n lv_swap vg_mint
sudo mkfs.ext4 -L mint-root /dev/vg_mint/lv_root
sudo mkfs.ext4 -L mint-home /dev/vg_mint/lv_home
sudo mkswap    -L mint-swap /dev/vg_mint/lv_swap
```

---

### Phase 8+ — Install, crypttab repair, tuning ⏸️ pending

Per [09 — Installer Reference Table](09-installer-reference-table.md) and
[08 — Reference Architecture](08-reference-architecture.md) Steps 7–11.

---

## State after Phase 5 (current)

```
NAME          SIZE TYPE FSTYPE LABEL PARTLABEL     MOUNTPOINT
nvme0n1     476.9G disk
├─nvme0n1p1     1G part vfat   ESP   ESP           (→ /boot/efi)
├─nvme0n1p2     2G part ext4   boot  boot          (→ /boot)
└─nvme0n1p3 473.9G part              cryptsystem   (→ LUKS2, pending)
```

| Property | Before | After |
|---|---|---|
| Logical sector size | 512 B | **4096 B** |
| Sector count | 1,000,215,216 | 125,026,902 |
| Partition table GUID | `34400F9E-…` | `62881706-…` |
| Partitions | 4 (Windows) | 3 (Linux) |
| ESP | 100 MiB | **1024 MiB** |
| Unallocated | 2.3 MiB | 1.3 MiB (GPT tail) |
| Operating system | Windows 11 | *(none — install pending)* |
| Encryption | none | LUKS2 (pending passphrase) |

---

## Findings closed by this rebuild

| ID | Finding | How |
|---|---|---|
| [F-02](07-findings-and-risks.md#f-02) | NTFS corrupt, 8,851 mismatches | NTFS destroyed |
| [F-03](07-findings-and-risks.md#f-03) | 6.3 GB hibernation image | Partition destroyed |
| [F-07](07-findings-and-risks.md#f-07) | ESP undersized at 100 MiB | Rebuilt at 1024 MiB |
| [F-08](07-findings-and-risks.md#f-08) | SSD on 512 B LBA | Reformatted to 4096 B |
| [F-11](07-findings-and-risks.md#f-11) | No swap configured | 20 GiB `lv_swap` in the design |

## Findings still open

| ID | Finding | Required action |
|---|---|---|
| 🔴 [F-01](07-findings-and-risks.md#f-01) | Battery at 23.65% health | **Replace the battery** — hardware, no software fix |
| 🟠 [F-04](07-findings-and-risks.md#f-04) | 26 unsafe shutdowns | Follows from F-01; re-check the counter in a month |
| 🟠 [F-06](07-findings-and-risks.md#f-06) | GDS/Downfall vulnerable | `apt install intel-microcode` after install |
| 🟠 [F-09](07-findings-and-risks.md#f-09) | 45 W adapter on a 65 W platform | Verify the adapter's label; replace if 45 W |
| 🔵 [F-10](07-findings-and-risks.md#f-10) | Secure Boot disabled | Enable after install |
| 🔵 [F-12](07-findings-and-risks.md#f-12) | Suspend drain unverified | Measure after install |

> ⚠️ **F-01 and F-09 are not cosmetic.** They caused the disk corruption that made this
> rebuild necessary. If the battery and adapter are left as they are, the same
> unsafe-shutdown pattern will corrupt the new ext4 filesystem just as it corrupted the
> NTFS one. The rebuild treats the symptom; replacing the battery treats the cause.

---

## Not done

- **No reboot performed** — the machine remains in the live USB session, as instructed.
- **No BIOS settings changed** — [06 — BIOS/UEFI Configuration](06-bios-uefi-configuration.md)
  documents what to set; firmware changes require the F2 setup screen at boot.
- **No LUKS passphrase set** — deliberately left to the owner.
- **Mint not yet installed.**
