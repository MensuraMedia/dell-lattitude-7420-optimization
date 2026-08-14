# 09 — Installer Reference Table

**Copy-this-at-the-keyboard reference for the Linux Mint installer.**

This mirrors what the Mint installer's manual-partitioning screen
("**Something else**") actually shows, so it can be filled in directly without
re-deriving anything. Keep this page open during install and on every future
reinstall of this machine.

---

## ⚠️ The two mistakes that break the install

1. **Selecting the wrong "Device for boot loader installation."**
   It must be the **disk** `/dev/nvme0n1`, **never** a partition like `/dev/nvme0n1p1`.
2. **Skipping the post-install `crypttab` step.** The Mint installer does not reliably
   write `/etc/crypttab` for a manually created LUKS container. Skip it and the machine
   **will not boot**. See [Step 8](08-reference-architecture.md#step-8--repair-the-encryption-configuration).

---

## The installer screen

Reach it via: **Install Linux Mint → Installation type → Something else → Continue**

The screen presents exactly these seven columns, with `+` / `−` / **Change…** buttons
beneath the list, **New Partition Table…** and **Revert** on the right, and a
**Device for boot loader installation** dropdown at the bottom:

```
┌──────────────────┬──────┬─────────────┬─────────┬────────┬────────┬────────────────────────┐
│ Device           │ Type │ Mount point │ Format? │ Size   │ Used   │ System                 │
├──────────────────┼──────┼─────────────┼─────────┼────────┼────────┼────────────────────────┤
│ /dev/nvme0n1     │      │             │         │        │        │                        │
│  free space      │      │             │    ☐    │   1 MB │        │                        │
│  /dev/nvme0n1p1  │ efi  │             │    ☐    │ 104 MB │ 104 MB │ Windows Boot Manager   │
│  /dev/nvme0n1p2  │      │             │    ☐    │  16 MB │unknown │                        │
└──────────────────┴──────┴─────────────┴─────────┴────────┴────────┴────────────────────────┘
  [ + ] [ − ] [ Change… ]              [ New Partition Table… ] [ Revert ]

  Device for boot loader installation:
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │ /dev/nvme0n1   KBG40ZNS512G NVMe KIOXIA 512GB (512.1 GB)                    ▼│
  └──────────────────────────────────────────────────────────────────────────────┘
```

> ⚠️ **The layout above is the OLD Windows one** and is what the installer shows if it
> was opened before the rebuild. The disk no longer looks like this.
> **Close the installer and relaunch it** to pick up the current partition table —
> or click **Revert**, which re-reads the disk. If you still see
> `Windows Boot Manager`, you are looking at a stale view.

**`Size` and `Used` are decimal MB (10⁶), not MiB.** That is why the old 100 MiB ESP
displayed as `104 MB`. Use the conversion table below.

`Type` shows the *current on-disk* filesystem (`efi`, `ext4`, `ntfs`, `unknown`) — it is
**not** what you are setting. You set the filesystem in the **Change…** dialog, which
is also where `Mount point` and `Format?` live. Select a row, click **Change…**, fill in
the three fields, click **OK**.

---

### Table 1 — Encrypted build ▸ **this machine's actual configuration**

Fill in via **Change…** on each row.

| Device | Type | Mount point | Format? | Size | Used | System |
|---|---|---|---|---|---|---|
| `/dev/nvme0n1` | | | | | | *(disk header row — not selectable)* |
| `/dev/nvme0n1p1` | `efi` → **EFI System Partition** | *(none — automatic)* | ☑ **Yes** | **1074 MB** | 1 MB | |
| `/dev/nvme0n1p2` | `ext4` → **Ext4 journaling file system** | **`/boot`** | ☑ **Yes** | **2147 MB** | 66 MB | |
| `/dev/nvme0n1p3` | *(blank — LUKS container)* | — | ☐ **No — leave alone** | 508888 MB | unknown | ⚠️ do **not** assign; use the mapper rows |
| `/dev/mapper/vg_mint-lv_root` | **Ext4 journaling file system** | **`/`** | ☑ **Yes** | **128849 MB** | | |
| `/dev/mapper/vg_mint-lv_home` | **Ext4 journaling file system** | **`/home`** | ☑ **Yes** | **300648 MB** | | |
| `/dev/mapper/vg_mint-lv_swap` | **swap area** | *(none)* | — | **21475 MB** | | |

> **Device for boot loader installation:**
> `/dev/nvme0n1   KBG40ZNS512G NVMe KIOXIA 512GB (512.1 GB)`
> ← **the disk**, never `/dev/nvme0n1p1`

**If the `/dev/mapper/*` rows are missing**, the LUKS container is not open or the
volume group is not active. Quit the installer, run the two commands below, then
relaunch it:

```bash
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem
sudo vgchange -ay vg_mint
```

**Selecting `EFI System Partition` as the Type removes the Mount point field** — that
is correct. It mounts at `/boot/efi` automatically.

---

### Table 2 — Unencrypted equivalent (same layout, no LUKS)

| Device | Type | Mount point | Format? | Size | Used | System |
|---|---|---|---|---|---|---|
| `/dev/nvme0n1p1` | **EFI System Partition** | *(automatic)* | ☑ **Yes** | 1074 MB | | |
| `/dev/nvme0n1p2` | **Ext4 journaling file system** | `/boot` | ☑ **Yes** | 2147 MB | | |
| `/dev/mapper/vg_mint-lv_root` | **Ext4 journaling file system** | `/` | ☑ **Yes** | 128849 MB | | |
| `/dev/mapper/vg_mint-lv_home` | **Ext4 journaling file system** | `/home` | ☑ **Yes** | 300648 MB | | |
| `/dev/mapper/vg_mint-lv_swap` | **swap area** | *(none)* | — | 21475 MB | | |

> Bootloader device: `/dev/nvme0n1`

---

### Table 3 — Dual-boot with Windows ▸ reference only, **not** this build

Kept so a future dual-boot install does not have to re-derive it. Sizes below are the
factory Windows layout as originally found on this machine.

| Device | Type | Mount point | Format? | Size | Used | System |
|---|---|---|---|---|---|---|
| `/dev/nvme0n1p1` | `efi` | *(automatic)* | ☐ **NO — NEVER** | 104 MB | 104 MB | **Windows Boot Manager** |
| `/dev/nvme0n1p2` | *(blank — MSR)* | — | ☐ No | 16 MB | unknown | |
| `/dev/nvme0n1p3` | `ntfs` | — | ☐ No | 511151 MB | 55000 MB | **Windows 11** |
| `/dev/nvme0n1p5` | **Ext4** *(or LUKS)* | `/` | ☑ Yes | *(from the shrink)* | | ← the new Linux partition |
| `/dev/nvme0n1p4` | `ntfs` | — | ☐ No | 836 MB | unknown | *(Windows Recovery)* |

> ⛔ **Formatting the ESP destroys the Windows Boot Manager** and Dell's firmware
> update payloads in `\EFI\Dell\`. In a dual-boot install the ESP is *used*, never
> formatted. This is the single most common way people break a working dual-boot.
>
> Note the `System` column is how you identify what not to touch — it names
> `Windows Boot Manager` against the ESP. If that column is populated, another OS is
> present and you are not doing a clean install.

---

## Size conversion reference

The Mint installer takes sizes in **MB (decimal, 10⁶)**, while `parted`, `lvcreate`
and `lsblk` report **MiB/GiB (binary, 2²⁰/2³⁰)**. Mixing them is the usual reason a
partition ends up slightly the wrong size.

| Intended | Binary | Bytes | **Shown/entered in installer (MB)** |
|---|---|---:|---|
| 1 GiB (ESP) | 1024 MiB | 1,073,741,824 | **1074** |
| 2 GiB (`/boot`) | 2048 MiB | 2,147,483,648 | **2147** |
| 20 GiB (swap) | 20480 MiB | 21,474,836,480 | **21475** |
| 120 GiB (`/`) | 122880 MiB | 128,849,018,880 | **128849** |
| 280 GiB (`/home`) | 286720 MiB | 300,647,710,720 | **300648** |
| 473.9 GiB (LUKS p3) | 485,274 MiB | 508,887,564,288 | **508888** (508.9 GB) |
| Whole disk | 476.9 GiB | 512,110,190,592 | **512110** (512.1 GB) |

Formula: `MB = GiB × 1073.741824`

**Proof this matters:** the factory ESP was exactly 100 MiB, and the installer
displayed it as `104 MB` — visible in the screen layout above. Enter `1024` when you
mean 1 GiB and you will get a partition 5% smaller than intended.

The whole-disk figure `512.1 GB` is what appears in the bootloader dropdown, which is
a useful confirmation you are pointed at the right device:
`/dev/nvme0n1   KBG40ZNS512G NVMe KIOXIA 512GB (512.1 GB)`

> When using `parted` or `lvcreate` directly (as this build does), **always suffix the
> unit** — `1025MiB`, `-L 120G`. Unsuffixed numbers are interpreted inconsistently
> between tools.

---

## Rebuild from scratch — the whole command sequence

Everything needed to recreate this machine's layout on a blank drive. Run from a Mint
live USB, **on AC power**.

```bash
# ── 0. CONFIRM THE TARGET ─────────────────────────────────────────────────
lsblk -o NAME,SIZE,TYPE,MODEL,TRAN          # target = nvme0n1, NOT sda (live USB)
cat /sys/class/power_supply/AC*/online      # must be 1

# ── 1. UNMOUNT ANYTHING ON THE TARGET ─────────────────────────────────────
sudo umount /dev/nvme0n1p* 2>/dev/null; sudo swapoff -a 2>/dev/null

# ── 2. ⚠️ DESTRUCTIVE: 4 KiB LBA REFORMAT ─────────────────────────────────
sudo apt install -y nvme-cli
sudo nvme id-ns /dev/nvme0n1 -H | grep -i lbaf       # confirm lbaf 1 = 4096B
sudo nvme format /dev/nvme0n1 --lbaf=1 --force
sudo blockdev --getss /dev/nvme0n1                   # expect 4096

# ── 3. ⚠️ DESTRUCTIVE: PARTITION ──────────────────────────────────────────
sudo parted -s /dev/nvme0n1 mklabel gpt
sudo parted -s /dev/nvme0n1 mkpart ESP fat32 1MiB 1025MiB
sudo parted -s /dev/nvme0n1 set 1 esp on
sudo parted -s /dev/nvme0n1 mkpart boot ext4 1025MiB 3073MiB
sudo parted -s /dev/nvme0n1 mkpart cryptsystem 3073MiB 100%
sudo sgdisk --typecode=1:ef00 --typecode=2:8300 --typecode=3:8309 /dev/nvme0n1
sudo partprobe /dev/nvme0n1
for n in 1 2 3; do sudo parted /dev/nvme0n1 align-check optimal $n; done   # all "aligned"

# ── 4. BOOT FILESYSTEMS ───────────────────────────────────────────────────
sudo mkfs.vfat -F32 -n ESP  /dev/nvme0n1p1
sudo mkfs.ext4 -F   -L boot /dev/nvme0n1p2

# ── 5. LUKS2 (prompts for passphrase — type YES in capitals first) ────────
sudo cryptsetup luksFormat --type luks2 \
     --cipher aes-xts-plain64 --key-size 512 \
     --hash sha256 --pbkdf argon2id \
     --label cryptsystem /dev/nvme0n1p3
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem

# ── 6. LVM ────────────────────────────────────────────────────────────────
sudo pvcreate /dev/mapper/cryptsystem
sudo vgcreate vg_mint /dev/mapper/cryptsystem
sudo lvcreate -L 120G -n lv_root vg_mint
sudo lvcreate -L 280G -n lv_home vg_mint
sudo lvcreate -L  20G -n lv_swap vg_mint
sudo vgdisplay vg_mint | grep Free       # ~53 GiB reserve must remain

# ── 7. FILESYSTEMS ────────────────────────────────────────────────────────
sudo mkfs.ext4 -L mint-root /dev/vg_mint/lv_root
sudo mkfs.ext4 -L mint-home /dev/vg_mint/lv_home
sudo mkswap    -L mint-swap /dev/vg_mint/lv_swap

# ── 8. RUN THE INSTALLER — use Table 1 above. DO NOT REBOOT AT THE END. ──

# ── 9. POST-INSTALL: FIX crypttab (skipping this = unbootable) ────────────
sudo mount /dev/vg_mint/lv_root /mnt
sudo mount /dev/nvme0n1p2 /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for d in dev dev/pts proc sys run; do sudo mount --bind /$d /mnt/$d; done
sudo cp /etc/resolv.conf /mnt/etc/resolv.conf
sudo chroot /mnt /bin/bash <<'CHROOT'
LUKS_UUID=$(blkid -s UUID -o value /dev/nvme0n1p3)
echo "cryptsystem UUID=${LUKS_UUID} none luks,discard" >> /etc/crypttab
apt install -y cryptsetup-initramfs lvm2
update-initramfs -u -k all
update-grub
CHROOT

# ── 10. VERIFY, UNMOUNT, REBOOT ───────────────────────────────────────────
sudo lsinitramfs /mnt/boot/initrd.img-* | grep -c cryptsetup     # must be > 0
for d in run sys proc dev/pts dev; do sudo umount /mnt/$d; done
sudo umount /mnt/boot/efi /mnt/boot /mnt
sudo reboot
```

---

## Mount point rationale

| Mount point | Device | Encrypted? | Why it is where it is |
|---|---|---|---|
| `/boot/efi` | `nvme0n1p1` (ESP, 1 GiB) | ❌ no | UEFI firmware can only read FAT32 and cannot decrypt. 1 GiB (vs the 100 MiB factory ESP) permanently allows UKI/systemd-boot later. |
| `/boot` | `nvme0n1p2` (ext4, 2 GiB) | ❌ no | Keeps GRUB out of the LUKS-unlocking business — faster boot, fewer failure modes than `GRUB_ENABLE_CRYPTODISK`. Mitigated by Secure Boot + TPM PCR binding. |
| `/` | `vg_mint/lv_root` (120 GiB) | ✅ yes | Generous for a desktop with Flatpaks; growable from the reserve via `lvresize`. |
| `/home` | `vg_mint/lv_home` (280 GiB) | ✅ yes | Separate volume so the OS can be reinstalled without touching user data — the highest-value structural choice in the layout. |
| swap | `vg_mint/lv_swap` (20 GiB) | ✅ yes | ≥ RAM so hibernation works. Encrypted because a hibernation image is a full RAM dump. |
| *(unallocated)* | ~53 GiB in `vg_mint` | — | SSD over-provisioning for the DRAM-less controller + LVM snapshot space. Deliberate, not waste. |

---

## Resizing later

The point of LVM: volumes resize **online**, with no repartitioning and no live USB.

```bash
# Grow / by 30 GiB from the free reserve
sudo lvresize -L +30G --resizefs /dev/vg_mint/lv_root

# Shrink /home by 50 GiB, then give it to /   (⚠️ requires unmounting /home)
sudo umount /home
sudo lvresize -L -50G --resizefs /dev/vg_mint/lv_home
sudo mount /home
sudo lvresize -L +50G --resizefs /dev/vg_mint/lv_root

# Check what's free
sudo vgdisplay vg_mint | grep -E 'Free|VG Size'
sudo lvs -o lv_name,lv_size,data_percent
```

> ⚠️ **ext4 can be grown online but must be unmounted to shrink.** Growing `/` while
> running is safe; shrinking `/home` requires logging out to a TTY and unmounting, or
> doing it from the live USB. Never shrink a mounted ext4 filesystem.

---

## Recovery — if it will not boot

Boot the live USB and chroot back in:

```bash
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem
sudo vgchange -ay vg_mint
sudo mount /dev/vg_mint/lv_root /mnt
sudo mount /dev/nvme0n1p2 /mnt/boot
sudo mount /dev/nvme0n1p1 /mnt/boot/efi
for d in dev dev/pts proc sys run; do sudo mount --bind /$d /mnt/$d; done
sudo chroot /mnt /bin/bash
```

| Symptom | Cause | Fix inside the chroot |
|---|---|---|
| No passphrase prompt; drops to initramfs | `/etc/crypttab` missing or wrong | Re-add the entry, `update-initramfs -u -k all` |
| Passphrase accepted, then "volume group not found" | `lvm2` missing from initramfs | `apt install lvm2 && update-initramfs -u -k all` |
| Boots straight to firmware / no GRUB | EFI boot entry missing | `grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu && update-grub` |
| GRUB appears but kernel not found | `/boot` not mounted at install | Check `/etc/fstab` has the `/boot` entry |
| Hibernate never resumes | `resume=` not set | Set `RESUME=UUID=…` in `/etc/initramfs-tools/conf.d/resume`, rebuild initramfs |
