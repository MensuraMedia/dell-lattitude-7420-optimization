# 08 — Reference Architecture: Complete Optimized Configuration

**The authoritative target-state design for this machine.**

> **Scope changed 2026-08-14:** the owner confirmed the system is **new and no data
> requires retention**. Windows is therefore discarded and the machine is built
> **Linux-only from bare metal**.
>
> This removes every blocker documented in
> [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md) — there is no NTFS
> to repair and no hibernation image to clear — and unlocks two optimizations that a
> dual-boot layout structurally cannot have (4 KiB LBA reformat, properly sized ESP).
>
> This document supersedes [03 — Partitioning Plan](03-partitioning-plan.md), which is
> retained for reference should dual-boot ever be revisited.

---

## Part 1 — Design inputs

Every decision in this document traces to a measured property of *this* machine.
Nothing here is generic advice.

| # | Measured property | Design consequence |
|---|---|---|
| **D1** | 16 GB LPDDR4x, **soldered — permanently unexpandable** | Swap must cover hibernation (20 GiB). zram absorbs pressure. Layout must be re-sliceable without repartitioning → **LVM**. |
| **D2** | KIOXIA BG4 **DRAM-less** NVMe controller | Performance collapses when full → **reserve ~11% unallocated**. Avoid write-amplifying filesystems → **ext4 over btrfs**. Batched TRIM, never continuous. |
| **D3** | SSD formatted **512 B LBA**; 4096 B available at `Rel_Perf 1` vs `3` | Full wipe makes the **destructive 4 K reformat viable** — aligns logical sectors to NAND mapping granularity. |
| **D4** | SSD at **9% endurance used**, 27.9 TB written, **0 integrity errors** | Healthy, but minimise gratuitous writes: `noatime`, zram, capped journald. |
| **D5** | **TPM 2.0 active** + **AES-NI / SHA-NI** in CPU | Encryption is free in performance terms and auto-unlockable → **LUKS2 is the default, not an option**. |
| **D6** | **Battery at 23.6% health** (14.6 Wh of 61.9 Wh) | Hardware replacement required. Charge thresholds prepared for the new cell. Suspend behaviour must be verified (S0ix drain). |
| **D7** | **26 unsafe shutdowns** recorded | Filesystem must be crash-resilient → ext4 with journaling, `errors=remount-ro`. Root cause is D6. |
| **D8** | Tiger Lake i5-1145G7, `intel_pstate` **active** mode + HWP | Governor stays `powersave`; tuning happens via **EPP**, not governor. |
| **D9** | **UEFI native**, GPT, Secure Boot capable, no CSM | GPT-only, `shim-signed` path available. |
| **D10** | Every component has an **in-tree driver** | No DKMS, no out-of-tree modules → **Secure Boot can be enabled without friction**. |
| **D11** | Whole disk now available (Windows discarded) | **1 GiB ESP** — removes the 100 MiB constraint that ruled out UKI/systemd-boot. |
| **D12** | GDS/Downfall reported **Vulnerable** | `intel-microcode` is a day-one requirement, not an optimization. |

---

## Part 2 — Target layout

```
/dev/nvme0n1 — KIOXIA KBG40ZNS512G, 476.9 GiB
REFORMATTED TO 4096-BYTE LBA  ·  GPT  ·  UEFI
│
├─ p1    1 GiB    ESP            FAT32   → /boot/efi     [unencrypted]
├─ p2    2 GiB    boot           ext4    → /boot         [unencrypted]
└─ p3  ~473 GiB   cryptsystem    LUKS2   → [encrypted container]
        │
        └─ LVM2 volume group  "vg_mint"
             ├─ lv_root   120 GiB   ext4   → /
             ├─ lv_home   280 GiB   ext4   → /home
             ├─ lv_swap    20 GiB   swap   → [hibernation-capable, encrypted]
             └─ ~53 GiB UNALLOCATED        → [reserve — see D2]

Plus, at runtime:
   zram      4 GiB (25% of RAM, zstd)  priority 100  → absorbs swap before disk
```

### Geometry

Created with `parted` in MiB units, which auto-aligns to 1 MiB boundaries — correct
for both 512 B and 4 KiB sector sizes.

| Part | Start | End | Size | Type | Label |
|---|---|---|---|---|---|
| p1 | 1 MiB | 1025 MiB | **1024 MiB** | EFI System (`ef00`) | `ESP` |
| p2 | 1025 MiB | 3073 MiB | **2048 MiB** | Linux filesystem (`8300`) | `boot` |
| p3 | 3073 MiB | 100% | **~484,310 MiB** | Linux LUKS (`8309`) | `cryptsystem` |

---

## Part 3 — Why each decision

### 3.1 Why reformat to 4 KiB LBA

The drive advertises two sector formats:

| Format | Sector | Relative performance |
|---|---|---|
| 0 (as shipped) | 512 B | `3` — worst |
| **1 (target)** | **4096 B** | **`1` — best** |

The NAND's internal page and mapping granularity is 4 KiB. Running 512 B logical
sectors forces the controller to perform read-modify-write cycles and inflates the
mapping table it must hold — and on a **DRAM-less** controller (D2) that table lives
in borrowed host memory, so keeping it small has outsized benefit.

Expected gains: lower write amplification, better sustained random write, longer
endurance. This is the **single largest storage optimization available** on this
machine, and it is only possible because the disk is being wiped (D3).

⚠️ **`nvme format` erases everything irreversibly and cannot be undone.**

### 3.2 Why a 1 GiB ESP

The factory ESP was **100 MiB** — Microsoft's minimum. That size ruled out
systemd-boot and Unified Kernel Images entirely, because a single Mint initramfs is
~100 MB (see [02 — Storage Analysis](02-storage-analysis.md#esp-sizing-assessment)).

1 GiB costs 0.2% of the disk and permanently removes that constraint. It also leaves
room for Dell's firmware capsule payloads (`\EFI\Dell\`), multiple bootloaders, and
future migration to UKI without repartitioning.

**There is no reason to be frugal here.** An undersized ESP is one of the most
annoying mistakes to correct later, because it sits at the front of the disk with
everything else behind it.

### 3.3 Why a separate unencrypted `/boot`

GRUB *can* unlock LUKS itself (`GRUB_ENABLE_CRYPTODISK=y`), but doing so means:
- GRUB's own LUKS2/argon2id support does the key derivation — slow, and historically
  fragile across argon2 parameter changes.
- You type the passphrase twice (GRUB, then initramfs).

A separate 2 GiB unencrypted `/boot` avoids both. It holds kernels and initramfs
images with generous room for many kernel generations.

**Security trade-off, stated plainly:** an unencrypted `/boot` means kernel and
initramfs are modifiable by someone with physical access (an "evil maid" attack).
That is mitigated — not eliminated — by **Secure Boot** verifying the boot chain and
by **TPM PCR binding** (§3.6) refusing to release the key if the measured boot state
changes. For a laptop that is not carrying state secrets, this is the correct balance,
and it matches what Ubuntu's and Mint's own installers produce.

### 3.4 Why LUKS2 with these parameters

```
--type luks2 --cipher aes-xts-plain64 --key-size 512 --hash sha256 --pbkdf argon2id
```

| Parameter | Choice | Reason |
|---|---|---|
| `luks2` | v2 header | Redundant metadata, argon2 support, TPM enrolment |
| `aes-xts-plain64` + `--key-size 512` | AES-256-XTS | XTS uses two 256-bit keys; 512 here means **AES-256**, not AES-512 |
| `argon2id` | memory-hard KDF | Resists GPU/ASIC brute force. LUKS2 default. |
| `sha256` | header hash | Hardware-accelerated by `sha_ni` (D5) |

The CPU has AES-NI **and** SHA-NI. Encryption overhead on this hardware is within
measurement noise for desktop workloads. **There is no performance argument against
encrypting**, which is why it is the default here rather than an option.

> Keep argon2id memory cost at the default. It is used at *unlock* time, when only
> the initramfs is running — setting it above available early-boot RAM produces a
> machine that cannot unlock itself.

### 3.5 Why LVM inside LUKS

D1 is the deciding factor: **this machine's RAM and disk are both permanently fixed.**
Nothing can be added later. The one form of flexibility still obtainable is the
ability to re-slice storage *internally*, online, without moving partitions.

```bash
sudo lvresize -L -50G --resizefs /dev/vg_mint/lv_home
sudo lvresize -L +50G --resizefs /dev/vg_mint/lv_root
```

That is impossible with raw partitions inside LUKS. LVM also gives one LUKS unlock
for all volumes, and snapshot capability from the reserve extents.

### 3.6 Why ext4 rather than btrfs

Btrfs snapshots are genuinely attractive, and Timeshift integrates with them natively.
The case against, **on this specific drive**:

- The BG4 is **DRAM-less** (D2). Copy-on-write multiplies small random writes — the
  precise workload this controller handles worst.
- The drive is already at **9% endurance used** (D4).
- Btrfs metadata is duplicated by default, doubling metadata writes.
- Timeshift's rsync mode is Mint's default and works correctly on ext4.

ext4's journaling also matters given **26 recorded unsafe shutdowns** (D7) — it
recovers from power loss quickly and predictably.

**Btrfs is a legitimate choice**, documented in
[03 — Partitioning Plan](03-partitioning-plan.md#layout-b--btrfs-alternative). It is
simply not what this drive argues for.

### 3.7 Why 20 GiB swap plus zram

| Requirement | Sizing |
|---|---|
| Overcommit safety with 16 GB RAM | 4–8 GiB would do |
| **Reliable hibernation** | **≥ RAM = 16 GiB; 20 GiB with margin** |

Hibernation writes the entire RAM image plus headroom. 20 GiB guarantees it.

**Hibernation is unusually valuable on this machine.** With the battery at 23.6%
health (D6), hibernate-on-critical-battery is the only mechanism that preserves
unsaved work when the cell collapses. That justifies the generous sizing.

Swap sits **inside LUKS**, so the hibernation image — a complete dump of RAM,
including keys and open documents — is encrypted. An unencrypted hibernation
partition would defeat the entire disk encryption scheme.

**zram (4 GiB, zstd, priority 100)** sits in front of it: the kernel fills compressed
RAM first and only spills to the disk swap under real pressure. This eliminates most
routine swap writes to the SSD (D4) while keeping hibernation available.

### 3.8 Why ~53 GiB is left unallocated

Not waste — three concrete purposes:

1. **SSD over-provisioning (D2).** Extents never allocated are never written, so the
   controller keeps them as spare blocks. On a DRAM-less drive this directly sustains
   write performance as the filesystem fills.
2. **LVM snapshots** require free extents to exist at all.
3. **Future re-slicing** on a machine that can never be expanded (D1).

11% reserve is the low end of the 15–20%-free guidance for DRAM-less drives; the rest
of the margin comes from not filling `lv_root` and `lv_home` to capacity.

---

## Part 4 — Build procedure

> ⚠️⚠️ **EVERY COMMAND IN THIS SECTION DESTROYS DATA.**
> Confirmed authorised: the system is new and no data requires retention.
> Run from the Linux Mint 22.3 live USB, **on AC power** (D6 — see the power warning in
> [04 — Blockers & Prerequisites](04-blockers-and-prerequisites.md#-special-warning-for-this-machine-power-stability)).

### Step 0 — Confirm the target and the power source

```bash
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN
sudo nvme list
cat /sys/class/power_supply/AC*/online     # MUST be 1
```

Confirm the target is `/dev/nvme0n1`, the 512 GB KIOXIA — **not** `/dev/sda`, which is
the live USB you are running from. Getting this wrong destroys the installer.

### Step 1 — Set BIOS

Apply the settings in
[06 — BIOS/UEFI Configuration](06-bios-uefi-configuration.md#pre-installation-bios-checklist)
before continuing. In particular: UEFI mode, CSM disabled, AHCI/NVMe, TPM on,
Secure Boot **disabled during installation**, Fastboot Thorough.

### Step 2 — Reformat the SSD to 4 KiB LBA

```bash
sudo apt install nvme-cli

# Confirm format 1 is 4096 bytes with Rel_Perf 1
sudo nvme id-ns /dev/nvme0n1 -H | grep -i lbaf

# ⚠️⚠️ ERASES THE ENTIRE DRIVE ⚠️⚠️
sudo nvme format /dev/nvme0n1 --lbaf=1 --force

# Verify
sudo nvme id-ns /dev/nvme0n1 -H | grep -i 'in use'
sudo blockdev --getss /dev/nvme0n1      # expect 4096
```

If `nvme format` reports the operation is not supported, the drive's firmware has
disabled it. Skip this step — everything below still works at 512 B, you simply
forgo the gain from §3.1.

### Step 3 — Partition

```bash
sudo parted -s /dev/nvme0n1 mklabel gpt
sudo parted -s /dev/nvme0n1 mkpart ESP         fat32 1MiB    1025MiB
sudo parted -s /dev/nvme0n1 set 1 esp on
sudo parted -s /dev/nvme0n1 mkpart boot        ext4  1025MiB 3073MiB
sudo parted -s /dev/nvme0n1 mkpart cryptsystem       3073MiB 100%

sudo partprobe /dev/nvme0n1
sudo parted /dev/nvme0n1 print
sudo parted /dev/nvme0n1 align-check optimal 1
sudo parted /dev/nvme0n1 align-check optimal 2
sudo parted /dev/nvme0n1 align-check optimal 3
```

All three alignment checks must return `1 aligned`.

### Step 4 — Create the LUKS2 container

```bash
sudo cryptsetup luksFormat --type luks2 \
     --cipher aes-xts-plain64 \
     --key-size 512 \
     --hash sha256 \
     --pbkdf argon2id \
     --label cryptsystem \
     /dev/nvme0n1p3
```

Type `YES` in capitals, then set a **strong passphrase**.

> This passphrase is the only thing standing between an attacker and the disk, and
> — until TPM enrolment in Step 10 — the only way you can boot. **Record it somewhere
> safe before continuing.** There is no recovery mechanism.

```bash
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem
sudo cryptsetup luksDump /dev/nvme0n1p3 | head -20
```

### Step 5 — Build the LVM stack

```bash
sudo pvcreate /dev/mapper/cryptsystem
sudo vgcreate vg_mint /dev/mapper/cryptsystem

sudo lvcreate -L 120G -n lv_root vg_mint
sudo lvcreate -L 280G -n lv_home vg_mint
sudo lvcreate -L  20G -n lv_swap vg_mint
# ~53 GiB deliberately left unallocated — see §3.8

sudo vgs
sudo lvs
sudo vgdisplay vg_mint | grep -i free      # confirm the reserve exists
```

### Step 6 — Create filesystems

```bash
sudo mkfs.vfat -F32 -n ESP        /dev/nvme0n1p1
sudo mkfs.ext4       -L boot      /dev/nvme0n1p2
sudo mkfs.ext4       -L mint-root /dev/vg_mint/lv_root
sudo mkfs.ext4       -L mint-home /dev/vg_mint/lv_home
sudo mkswap          -L mint-swap /dev/vg_mint/lv_swap
```

### Step 7 — Install Mint

Launch **Install Linux Mint** → **Something else** (manual partitioning) and assign:

| Device | Mount point | Filesystem | Format? |
|---|---|---|---|
| `/dev/nvme0n1p1` | `/boot/efi` | EFI System Partition | ✅ yes |
| `/dev/nvme0n1p2` | `/boot` | ext4 | ✅ yes |
| `/dev/vg_mint/lv_root` | `/` | ext4 | ✅ yes |
| `/dev/vg_mint/lv_home` | `/home` | ext4 | ✅ yes |
| `/dev/vg_mint/lv_swap` | swap | — | — |

Set **"Device for boot loader installation"** to `/dev/nvme0n1` — the **disk**, not a
partition.

> Unlike the dual-boot plan, formatting the ESP here is correct and expected — there
> is no Windows Boot Manager to preserve.

**Do not reboot when the installer finishes.** Choose **Continue Testing**.

### Step 8 — Repair the encryption configuration

The Mint installer does not reliably write `/etc/crypttab` for a manually created
LUKS container. Without this the machine **will not boot**.

```bash
sudo mount /dev/vg_mint/lv_root /mnt
sudo mount /dev/nvme0n1p2 /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for d in dev dev/pts proc sys run; do sudo mount --bind /$d /mnt/$d; done
sudo cp /etc/resolv.conf /mnt/etc/resolv.conf
sudo chroot /mnt /bin/bash
```

Inside the chroot:

```bash
LUKS_UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
echo "cryptsystem UUID=${LUKS_UUID} none luks,discard" >> /etc/crypttab
cat /etc/crypttab

# Ensure cryptsetup lands in the initramfs
apt install -y cryptsetup-initramfs lvm2

update-initramfs -u -k all
update-grub
exit
```

**`discard` is deliberate.** It enables TRIM pass-through from the filesystem, through
LVM, through LUKS, to the SSD. Without it `fstrim` silently does nothing and the
DRAM-less drive (D2) degrades. The known trade-off — an attacker can infer how much of
the container is in use — is acceptable and far outweighed by the SSD benefit here.

### Step 9 — Verify, then reboot

```bash
sudo cat /mnt/etc/fstab
sudo cat /mnt/etc/crypttab
sudo lsinitramfs /mnt/boot/initrd.img-$(uname -r) | grep -c cryptsetup   # must be > 0

for d in run sys proc dev/pts dev; do sudo umount /mnt/$d; done
sudo umount /mnt/boot/efi /mnt/boot /mnt
sudo reboot
```

You should be prompted for the LUKS passphrase, then reach the Mint desktop.

### Step 10 — TPM auto-unlock (after a confirmed-working boot)

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
sudo update-initramfs -u -k all
sudo reboot
```

PCR 0 binds to firmware, PCR 7 to Secure Boot state — the key is released only if
neither has been tampered with.

> **Keep the passphrase.** A BIOS update changes PCR 0 and invalidates the binding,
> requiring the passphrase and a re-enrol. That is the mechanism working correctly.
> PCR 7 only carries real weight once Secure Boot is enabled (Step 11).

### Step 11 — Enable Secure Boot

Every component of this machine uses an in-tree driver (D10), so there are no unsigned
modules to break.

```bash
sudo apt install --reinstall shim-signed grub-efi-amd64-signed
sudo update-grub
```

Reboot into BIOS (F2) → **Secure Boot → Enabled**, Mode → **Deployed Mode**. Then:

```bash
mokutil --sb-state      # expect "SecureBoot enabled"
```

Re-enrol the TPM binding afterwards, since PCR 7 has now changed:
```bash
sudo systemd-cryptenroll --wipe-slot=tpm2 --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
sudo update-initramfs -u -k all
```

---

## Part 5 — Post-install optimization

Apply [05 — Post-Install Optimization](05-post-install-optimization.md) in full. The
items that are **mandatory** for this build rather than optional:

| Action | Traces to | Why mandatory |
|---|---|---|
| `apt install intel-microcode` | D12 | GDS/Downfall reported **Vulnerable** |
| `systemctl enable --now fstrim.timer` | D2 | DRAM-less drive degrades without TRIM |
| `discard` in `/etc/crypttab` | D2 | Without it, TRIM never reaches the SSD |
| `noatime` on `/` and `/home` | D4 | Removes a write per file read |
| zram at priority 100 | D4 | Keeps routine swap off the SSD |
| `vm.swappiness=10` | D1, D4 | 16 GB RAM, wear-sensitive drive |
| `apt install thermald` | D8 | Prevents Tiger Lake sustained-load thermal cliff |
| TLP with the supplied profile | D6 | Every watt counts on a 14.6 Wh battery |
| Charge thresholds 75/80 | D6 | Protects the **replacement** cell |
| VA-API (`intel-media-va-driver-non-free`) | D6 | Video on CPU is a large needless drain |

### Fstab additions

After install, add `noatime` to the root and home entries:

```
UUID=<root-uuid>  /       ext4  defaults,noatime,errors=remount-ro  0 1
UUID=<home-uuid>  /home   ext4  defaults,noatime                    0 2
UUID=<boot-uuid>  /boot   ext4  defaults,noatime                    0 2
UUID=<esp-uuid>   /boot/efi vfat umask=0077,shortname=winnt         0 1
```

`errors=remount-ro` on root matters given D7 — on filesystem error the system goes
read-only rather than continuing to write into a damaged filesystem.

### Enable hibernation

The 20 GiB swap volume exists for this (§3.7), but Ubuntu-derived distributions
disable hibernation by default:

```bash
# Find the swap device UUID
sudo blkid /dev/vg_mint/lv_swap

# /etc/default/grub
GRUB_CMDLINE_LINUX_DEFAULT="quiet splash resume=UUID=<swap-uuid>"
```
```bash
sudo update-grub
echo "RESUME=UUID=<swap-uuid>" | sudo tee /etc/initramfs-tools/conf.d/resume
sudo update-initramfs -u -k all
sudo systemctl hibernate     # test it
```

Then enable hibernate-on-critical-battery — the safety net that matters most given D6:

```ini
# /etc/systemd/logind.conf
HandlePowerKey=suspend
```
```ini
# /etc/UPower/UPower.conf
CriticalPowerAction=Hibernate
PercentageAction=4
```
```bash
sudo systemctl restart upower
```

---

## Part 6 — Validation

Run after the build is complete. Every check should pass.

```bash
#!/usr/bin/env bash
echo "=== Sector size (expect 4096 if Step 2 succeeded) ==="
sudo blockdev --getss /dev/nvme0n1

echo "=== Partition alignment (expect '1 aligned' x3) ==="
for n in 1 2 3; do sudo parted /dev/nvme0n1 align-check optimal $n; done

echo "=== LUKS2 header ==="
sudo cryptsetup luksDump /dev/nvme0n1p3 | grep -E 'Version|Cipher|PBKDF|tpm2'

echo "=== LVM reserve (Free PE must be > 0) ==="
sudo vgdisplay vg_mint | grep -E 'Free|VG Size'

echo "=== TRIM path: LUKS -> device ==="
lsblk --discard                        # DISC-GRAN/DISC-MAX non-zero throughout
systemctl is-enabled fstrim.timer

echo "=== Swap topology: zram priority 100, disk swap lower ==="
swapon --show

echo "=== CPU mitigations (gather_data_sampling must NOT say Vulnerable) ==="
grep . /sys/devices/system/cpu/vulnerabilities/*

echo "=== Power policy ==="
sudo tlp-stat -s -b -p | head -40
cat /sys/class/power_supply/BAT0/charge_control_end_threshold

echo "=== Secure Boot / TPM ==="
mokutil --sb-state
sudo systemd-cryptenroll /dev/nvme0n1p3    # should list a tpm2 slot

echo "=== Video acceleration ==="
vainfo 2>&1 | grep -E 'VAProfile(H264|HEVC|VP9|AV1)'

echo "=== SSD health ==="
sudo smartctl -a /dev/nvme0n1 | grep -E 'Percentage|Available Spare|Media and Data|Temperature:'

echo "=== Sleep state ==="
cat /sys/power/mem_sleep
```

### Acceptance criteria

| Check | Pass condition |
|---|---|
| Sector size | `4096` (or `512` if firmware refused the reformat) |
| Alignment | `1 aligned` for all three partitions |
| LUKS | `Version: 2`, `aes-xts-plain64`, `argon2id` |
| LVM reserve | `Free PE / Size` > 50 GiB |
| TRIM | `fstrim.timer` enabled, `DISC-MAX` non-zero on `nvme0n1` |
| Swap | zram at priority 100, `lv_swap` at lower priority, total ≥ 20 GiB |
| GDS | **not** `Vulnerable` |
| Charge threshold | `80` |
| Secure Boot | `SecureBoot enabled` |
| TPM | a `tpm2` token listed on the LUKS device |
| VA-API | H264, HEVC, VP9, AV1 profiles present |
| SSD | `Percentage Used` ≤ 10%, `Media and Data Integrity Errors: 0` |
| Hibernate | `systemctl hibernate` resumes correctly |

---

## Part 7 — Outstanding hardware actions

Software configuration cannot address these.

| Priority | Action | Detail |
|---|---|---|
| 🔴 **1** | **Replace the battery** | 23.6% health (14.6 Wh of 61.9 Wh design). Dell part family for the 7420 4-cell 63 Wh: `TN2GY` / `WY9DX` / `M42XW` — **verify against the service tag before ordering**. This is also the most likely cause of the 26 unsafe shutdowns. |
| 🟠 **2** | **Verify the AC adapter** | The unit observed negotiated **15 V / 3 A = 45 W**. The 7420 is rated for **65 W**. An under-spec adapter charges slowly and can throttle under combined CPU+GPU load. |
| 🟡 **3** | **Check suspend drain** | `cat /sys/power/mem_sleep`. If S0ix/Modern Standby drains excessively, look for an S3 option in the BIOS — on a 14.6 Wh cell, overnight drain is fatal to usability. |

---

## Part 8 — Design summary

| Layer | Choice | Primary driver |
|---|---|---|
| Sector format | 4096 B LBA | D3 — better `Rel_Perf` on DRAM-less NAND |
| Partition table | GPT | D9 — UEFI native |
| ESP | 1 GiB FAT32 | D11 — removes the 100 MiB constraint permanently |
| `/boot` | 2 GiB ext4, unencrypted | Avoids GRUB cryptodisk fragility; Secure Boot + TPM PCR mitigate |
| Encryption | LUKS2, AES-256-XTS, argon2id | D5 — free on this CPU, TPM-unlockable |
| Volume management | LVM2 | D1 — only remaining flexibility on fixed hardware |
| Root / Home | ext4, separate volumes | D2, D4, D7 — low write amplification, crash-resilient, reinstall-safe |
| Swap | 20 GiB in LUKS + 4 GiB zram | D1, D6 — hibernation capable, minimises SSD writes |
| Reserve | ~53 GiB unallocated | D2 — SSD over-provisioning + snapshots |
| CPU policy | `intel_pstate` active, EPP-tuned | D8 |
| Boot security | Secure Boot + TPM PCR 0+7 | D5, D10 |

**Every layer traces to a measured property of this machine.** Nothing is cargo-culted.
