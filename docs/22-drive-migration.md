# 22 — Drive Migration & M.2 Options

Moving this LUKS + LVM installation to a new M.2 SSD, the alternative copy methods
and when each is appropriate, and what can physically go in this chassis.

> **Current disk state:** [02 — Storage Analysis](02-storage-analysis.md)
> **Hardware:** [01 — Hardware Inventory](01-hardware-inventory.md#4-storage)
> **The stack being moved:** [08 — Reference Architecture](08-reference-architecture.md)

Captured **2026-08-22**. BIOS 1.50.1, kernel 7.0.0-28-generic.

---

## 1. The constraint that shapes everything

**The 7420 has one M.2 slot for storage.** The old drive and the new drive can never
be inside the machine at the same time, so every method here routes through an
external USB/Thunderbolt enclosure. That is not a workaround — it is the only
topology available.

It also hands you a free safety net: **the drive you remove is a complete,
untouched rollback.** Nothing in this document destroys it. Keep it in a drawer
until the new one has run for a week.

---

## 2. What is installed now

| Property | Value | How verified |
|---|---|---|
| Model | **KIOXIA KBG40ZNS512G** (BG4, **DRAM-less**) | `nvme id-ctrl`, `lspci` |
| Capacity | 476.9 GiB | `lsblk` |
| Endurance used | 9% — ~91% of write life remains | SMART, [01](01-hardware-inventory.md#health-smart-nvme-log-0x02) |
| Logical sector size | **512 B** (format 0, `Rel_Perf 3` — the slower one) | `nvme id-ns`, [02 §9](02-storage-analysis.md) |
| Endpoint link | PCIe **3.0** x4 (`LnkCap 8GT/s`) | `lspci -vv -s 01:00.0` |
| **Slot link** | **PCIe 4.0 x4** (`LnkCap 16GT/s`, root port `00:06.0`, CPU-attached) | `lspci -vv -s 00:06.0` |

> ⚠️ **The slot is Gen4; the drive is not.** `LnkSta` reads 8GT/s only because the
> BG4 is a Gen3 part. A Gen4 SSD in this slot will negotiate Gen4 — roughly double
> the sequential ceiling. Read the *root port's* `LnkCap`, never the endpoint's, when
> judging what a slot can do.

### The layout being moved

```
nvme0n1  476.9G
├─p1      1G  vfat         /boot/efi
├─p2      2G  ext4         /boot
└─p3  473.9G  crypto_LUKS
      └─cryptsystem → vg_mint
            ├─lv_root  120G ext4  /       (15G used)
            ├─lv_home  280G ext4  /home   (72G used)
            └─lv_swap   20G swap          (sized for hibernation)
```

**~87 GB of real data on a 477 GB disk.** That gap is what makes the file-level
methods in §6 viable, and it is worth knowing before you commit to imaging 477 GB.

---

## 3. Recommended — direct disk-to-disk clone

Put the **new** drive in the enclosure and copy straight onto it. One pass, no
intermediate image, no staging capacity required.

### Why this one

Block-level copy reproduces the LUKS2 header, every filesystem UUID, the LVM
metadata and the GPT partition GUIDs exactly. That means `/etc/fstab`,
`/etc/crypttab`, the `resume=UUID=…` on the kernel command line and the EFI NVRAM
boot entry all remain valid. **Nothing needs reconfiguring — it boots identically.**
No chroot, no `update-initramfs`, no `grub-install`, no `efibootmgr`.

### Preflight

```bash
# 1. Back up the LUKS header somewhere OFF this machine. Non-negotiable.
sudo cryptsetup luksHeaderBackup /dev/nvme0n1p3 \
     --header-backup-file ~/luks-header-nvme0n1p3-$(date +%F).img
#    scripts/post-install-crypttab.sh already does this — reuse it if you prefer.

# 2. Record the current identity so you can prove the clone matched.
lsblk -o NAME,SIZE,FSTYPE,UUID /dev/nvme0n1
sudo cryptsetup luksUUID /dev/nvme0n1p3
sudo sgdisk --print /dev/nvme0n1

# 3. Confirm the drive is healthy enough to read end-to-end.
sudo nvme smart-log /dev/nvme0n1 | grep -iE "critical|percentage_used|media_errors"
```

### Clone

**Boot a Mint live USB.** Do not do this from the running system — imaging mounted,
active filesystems produces an inconsistent copy.

```bash
lsblk -o NAME,SIZE,MODEL,TRAN          # identify the enclosure, e.g. /dev/sda
                                       # ⚠️ get this wrong and you overwrite the wrong disk

sudo dd if=/dev/nvme0n1 of=/dev/sda bs=64M status=progress conv=fsync,noerror
sync
```

Verify before you trust it — compare the source against the first 477 GiB of the
target (a larger target has trailing space that will not match):

```bash
SRC_BYTES=$(sudo blockdev --getsize64 /dev/nvme0n1)
sudo cmp -n "$SRC_BYTES" /dev/nvme0n1 /dev/sda && echo "IDENTICAL"
```

Then power off, swap the M.2, and boot. You should get the usual LUKS passphrase
prompt and an unchanged desktop.

> `dd` is silent by nature. `status=progress` gives throughput; expect the run to be
> bounded by the enclosure, not the SSDs — USB 3.2 Gen2 tops out near 1 GB/s, TB4
> near 3 GB/s, and a USB 3.0 enclosure will make 477 GB genuinely tedious.

---

## 4. Variant — image to a file first

This is the flow as originally proposed: image to a file on an external drive, swap
the M.2, restore from the file. It costs a second full pass but leaves you holding
an archived snapshot of the old system, which the direct clone does not.

```bash
# Capture (from the live USB)
sudo dd if=/dev/nvme0n1 of=/mnt/ext/7420-$(date +%F).img bs=64M status=progress conv=fsync
sha256sum /mnt/ext/7420-*.img | tee /mnt/ext/7420.sha256

# Restore, after swapping the drive
sudo dd if=/mnt/ext/7420-*.img of=/dev/nvme0n1 bs=64M status=progress conv=fsync
```

Two things to know:

- **Budget the full 477 GB and do not compress.** The image is almost entirely LUKS
  ciphertext, which is incompressible; `gzip`/`zstd` will burn CPU for approximately
  nothing. This is a property of encrypting the disk, not a flaw in the method.
- **The image *is* the disk.** The same passphrase opens it. Store the external
  drive with the same care you give the laptop, and keep the LUKS header backup
  somewhere else — one stolen bag should not contain both.

---

## 5. Growing into a larger drive

A block clone reproduces the *old* partition table, so a larger drive comes up with
the extra space unallocated. Grow the chain from the outside in:

```bash
sudo sgdisk --move-second-header /dev/nvme0n1      # GPT backup header to the new end
sudo parted /dev/nvme0n1 resizepart 3 100%         # extend the LUKS partition
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem    # (already open if booted from it)
sudo cryptsetup resize cryptsystem                 # extend the dm-crypt mapping
sudo pvresize /dev/mapper/cryptsystem              # extend the LVM PV
sudo lvextend -l +100%FREE /dev/vg_mint/lv_home    # give the space to /home
sudo resize2fs /dev/vg_mint/lv_home                # grow the filesystem (online is fine)
```

`lv_root` at 120 GB with 15 GB used needs nothing. `lv_swap` should stay at 20 GB —
it is sized to hold a hibernation image of 16 GB of RAM
([21 §6](21-lid-power-and-sleep.md)); shrinking it forecloses hibernation.

> ⚠️ **A smaller target cannot take a block clone.** 477 GB of source will not fit,
> even though only 87 GB is in use — `dd` copies the geometry, not the contents.
> Shrink the filesystems and partition first, or use a file-level method from §6.

---

## 6. Alternative copy methods

| Method | Copies | Preserves UUIDs / LUKS header | Target may be smaller | Verdict for this machine |
|---|---|---|---|---|
| **`dd` disk-to-disk** | Every sector | ✅ exactly | ❌ | ✅ **Recommended.** Simplest correct thing; §3 |
| **`dd` to image file** | Every sector | ✅ exactly | ❌ | ✅ Use when you also want an archive; §4 |
| **`ddrescue`** | Every sector, resumable, tolerates read errors | ✅ exactly | ❌ | ✅ Better than `dd` **if the source is failing**. This drive is at 9% wear with 0 media errors, so not needed — but it is the right tool for a sick disk |
| **Clonezilla** | Per-filesystem "used blocks only" | ✅ | ❌ (device mode) | ⚠️ Works, but **cannot see inside LUKS** — it treats `p3` as one opaque blob and silently falls back to sector-by-sector. You get `dd` with extra steps and no space saving |
| **`partclone` direct** | Used blocks per filesystem | ✅ | ❌ | ⚠️ Same LUKS blindness as Clonezilla; useful only for `p1`/`p2` |
| **`dd` of the *opened* LVs** | Decrypted contents, per volume | ❌ new header | ✅ | 🔧 Advanced. Lets you build a fresh LUKS2 header and copy ~87 GB instead of 477 GB. More moving parts than `rsync` for the same result |
| **`rsync` file-level** | Files only (~87 GB) | ❌ must be rebuilt | ✅ | ✅ **The right choice if the new drive is smaller, or if you want 4 KiB LBA (§7)**. Requires the rebuild steps below |
| **`tar` / `fsarchiver`** | Files, as an archive | ❌ must be rebuilt | ✅ | ✅ Equivalent to `rsync`; pick it if you want a single portable archive file |
| **Timeshift** (installed on Mint) | `/` only — **excludes `/home` by default** | ❌ | ✅ | ⚠️ Fine as a rollback tool, wrong tool for a whole-disk move. The 72 GB in `/home` is the bulk of your data |
| **`lvmove` / `pvmove`** | LVM extents, live | ✅ LVM-level | ✅ | ❌ Needs both PVs online at once. Possible with the new drive in the enclosure, but adds LVM surgery to a job `dd` does in one command |
| **Fresh install + restore** | Nothing — rebuild from scratch | ❌ | ✅ | ⚠️ Only if you want to change the layout anyway. `scripts/build-encrypted-stack.sh` already automates the stack |

### If you go file-level, these are the steps `dd` saves you

Because a fresh stack means new UUIDs, you must repoint everything that names one:

1. Build the target stack — `scripts/build-encrypted-stack.sh` follows
   [08 — Reference Architecture](08-reference-architecture.md).
2. `rsync -aHAXx --info=progress2` each filesystem (`/`, `/home`, `/boot`) and
   `rsync -aHAX` the ESP.
3. Rewrite `/etc/fstab` and `/etc/crypttab` with the **new** UUIDs
   (`blkid`, `cryptsetup luksUUID`).
4. Update `resume=UUID=…` in `/etc/default/grub` **and**
   `/etc/initramfs-tools/conf.d/resume` — the swap LV UUID changes too.
5. `mount --bind` `/dev`, `/proc`, `/sys`, `/run`, then chroot and run
   `update-initramfs -u -k all`, `grub-install`, `update-grub`.
6. Re-add the EFI boot entry with `efibootmgr` if firmware does not find it.

Secure Boot is **disabled** on this machine ([06](06-bios-uefi-configuration.md)),
so no shim signing or MOK enrolment enters into it.

---

## 7. Choosing the replacement M.2

### What the slot will accept

| Property | This machine | Notes |
|---|---|---|
| Interface | **PCIe 4.0 x4, NVMe** | Verified from the root port; Gen3 drives work at Gen3 |
| Keying | **M-key, NVMe only** | M.2 **SATA** (B+M key) is not supported on this platform |
| Form factor | **M.2 2280 and M.2 2230** | The 7420 provides mounting for both — ⚠️ **verify visually**, see below |
| Sidedness | **Single-sided strongly preferred** | Thin chassis with a thermal pad above the module |
| Capacity | 1–2 TB is the sweet spot | 4 TB single-sided 2280 exists but runs hot and costs disproportionately |

> ⚠️ **Check the form factor before ordering.** The installed `KBG40ZNS512G` is a
> KIOXIA BG4, a series shipped as a **single-sided M.2 2230**. Dell's 7420 service
> manual lists both 2230 and 2280 support, with different standoff positions. The
> bottom panel comes off with captive Phillips screws ([20 §Access](20-fan-and-cooling-hardware.md)) —
> look at where the retention screw actually sits before you buy. If the standoff is
> only populated for 2230, a 2280 drive needs the correct Dell standoff or an
> adapter bracket.

### What to prioritise, in order

1. **DRAM cache.** This is the single biggest upgrade available.
   [01 §DRAM-less caveat](01-hardware-inventory.md#the-dram-less-caveat) documents
   why: the BG4 has no onboard DRAM, leans on Host Memory Buffer, and degrades as it
   fills. A DRAM-equipped drive removes an entire class of "why is it sluggish"
   from this machine. If you buy only one improvement, buy this one.
2. **Gen4, because the slot is Gen4.** Free headroom now that §2 has established the
   root port does 16GT/s.
3. **Idle power / ASPM L1.2 support.** This is a laptop on a battery at **23.6%
   health** ([F-01](07-findings-and-risks.md#f-01)). A desktop-class Gen4 controller
   that idles hot will cost you runtime and add to a thermal budget that
   [17](17-cooling-optimization.md) already found tight. Prefer efficiency over peak
   sequential numbers — you will never notice 7 GB/s on this workload, but you will
   notice the drain.
4. **4 KiB LBA support.** See below.
5. **Endurance (TBW)** — largely academic. The current drive reached 9% wear in
   8,490 hours; almost any modern replacement outlives the chassis.

### The 4 KiB LBA opportunity

[02 §9](02-storage-analysis.md) records that the current drive runs the **slower**
512 B sector format when a 4096 B format (`Rel_Perf 1`) is available, and notes it
is only actionable on a clean wipe. **A drive migration is that moment.** On the new
drive, before building anything:

```bash
sudo nvme id-ns /dev/nvme0n1 -H | grep -i "lba format"   # find a 4096-byte, Rel_Perf 0/1 format
sudo nvme format /dev/nvme0n1 --lbaf=<n> --force          # ⚠️ ERASES THE DRIVE
```

> **This is the one real advantage the file-level path has over `dd`.** A block clone
> reproduces the 512 B format along with everything else, and the logical block size
> must match for the copy to be meaningful. If you want 4 KiB sectors, you must
> rebuild rather than clone. Whether that is worth the extra steps is a judgement
> call — the gain is real but modest, and it is largest on DRAM-less drives, which
> you are hopefully leaving behind.

---

## 8. Other ways to add storage

Since the internal slot is single-occupancy, everything else is external or
already spoken for:

| Option | Verified state | Practical value |
|---|---|---|
| **Thunderbolt 4 / USB4 NVMe enclosure** | Two TB4 ports; `ThunderboltPorts=Enabled`, `DisUsb4Pcie=Disabled`, TB security `none` | ✅ **Best expansion.** Near-internal speeds, no authorization prompt to fight |
| **USB 3.2 Gen2 enclosure** | `UsbPortsExternal=Enabled` | ✅ Cheaper, ~1 GB/s, perfectly adequate for bulk and backups |
| **SD card reader** | Realtek **RTS525A**, PCIe-attached at `72:00.0` | ⚠️ Present and PCIe-attached rather than USB, so better than most. Still slow — cold data and media only |
| **M.2 2230 WWAN slot** | ❌ **Occupied** — Dell **DW5829e-eSIM** Snapdragon X20 LTE, enumerating on **USB** bus 004 | ❌ Not a storage option. It is filled, and it is wired for USB, not PCIe — an NVMe module would not enumerate even if you evicted the modem |
| **RAM as cache** | 16 GB LPDDR4x, **soldered** ([01](01-hardware-inventory.md)) | ❌ No expansion path; also why HMB pressure matters on DRAM-less drives |

The WWAN finding is worth stating plainly because the "put a 2230 SSD in the spare
WWAN slot" trick circulates widely for Latitudes. **On this unit it is doubly
blocked** — the slot is full, and the interface is wrong.

---

## 9. Pitfalls

- **Identify the target device every single time.** `dd` will overwrite `/dev/sda`
  without comment. Re-run `lsblk -o NAME,SIZE,MODEL,TRAN` immediately before the
  command, not from memory, and never from a previous shell session.
- **Never image a mounted, running filesystem.** Boot the live USB.
- **Do not wipe the old drive on migration day.** It is the rollback. A week of
  uneventful use, then repurpose it — an enclosure turns it into a 512 GB portable.
- **The clone inherits the 26 unsafe shutdowns' worth of history and the 512 B LBA
  format**, but not any drive wear — endurance counters belong to the drive, not the
  data.
- **Firmware boot entries usually survive**, because the GPT partition GUID is
  cloned. If the machine boots straight to firmware setup anyway, the fix is
  `efibootmgr` or `Boot Configuration → Add Boot Option`, not a reinstall
  ([06 §Boot order](06-bios-uefi-configuration.md)).
- **Keep the LUKS header backup and the disk image apart.** Together they are the
  whole machine.

---

## 10. Post-migration verification

```bash
# Identity carried over as expected
lsblk -o NAME,SIZE,FSTYPE,UUID
sudo cryptsetup luksUUID /dev/nvme0n1p3

# The slot is now actually running at Gen4, if you bought Gen4
sudo lspci -vv -s 00:06.0 | grep -E "LnkCap:|LnkSta:"

# Hibernation still points somewhere real
cat /proc/cmdline | tr ' ' '\n' | grep resume
cat /sys/power/resume

# New drive's health baseline, recorded on day one
sudo nvme smart-log /dev/nvme0n1

# TRIM is running on the new drive
systemctl status fstrim.timer
sudo fstrim -av
```

Then re-run the machine's own baseline tooling so the new drive is measured, not
assumed — `scripts/collect-diagnostics.sh` regenerates the inventory that
[01](01-hardware-inventory.md) and [02](02-storage-analysis.md) were built from.
