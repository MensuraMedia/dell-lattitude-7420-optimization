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

### Phase 5b — Interference from a running installer 🔍

Three attempts to create the LUKS container produced no change on disk. Diagnosis:

```
root  5039  /usr/lib/udisks2/udisks2-inhibit /usr/lib/ubiquity/bin/ubiquity gtk_ui
mint  5045  /usr/bin/python3 /usr/lib/ubiquity/bin/ubiquity gtk_ui
root  7658  sh -c /usr/share/ubiquity/activate-dmraid && /bin/partman
```

The Mint installer (`ubiquity` + `partman`) had been running since **13:22** — before
the 14:30 repartition — holding a cached partition map of the *old Windows layout*.
This is also why its manual-partitioning screen still displayed
`/dev/nvme0n1p1  efi  104 MB  Windows Boot Manager` after the wipe.

The device itself was verified healthy by a direct write test:

```
$ echo "TESTWRITE-…" | sudo dd of=/dev/nvme0n1p3 bs=512 count=1 conv=fsync
$ sudo dd if=/dev/nvme0n1p3 bs=512 count=1 | xxd
00000000: 5445 5354 5752 4954 452d 3137 3836 3731  TESTWRITE-178671
```

Write landed at 140 MB/s and read back intact; no read-only flags, no I/O errors, and
`dmesg` showed no disk activity between 14:30 and 14:50. The test signature was then
zeroed (`dd if=/dev/zero bs=1M count=4`).

> **Lesson for future rebuilds:** close the installer before any manual disk work.
> `partman` caches the partition table at launch and does not re-read it. Both
> `scripts/build-encrypted-stack.sh` and the procedure in
> [08 — Reference Architecture](08-reference-architecture.md) assume the installer is
> **not** running.

---

### Phase 6 — LUKS2 container ✅

```bash
sudo cryptsetup luksFormat --type luks2 \
     --cipher aes-xts-plain64 --key-size 512 \
     --hash sha256 --pbkdf argon2id \
     --label cryptsystem /dev/nvme0n1p3
sudo cryptsetup open /dev/nvme0n1p3 cryptsystem
```

**Verified:**
```
Version:        2
Label:          cryptsystem
Key:            512 bits
Cipher:         aes-xts-plain64
Cipher key:     512 bits
PBKDF:          argon2id
Time cost:      9
Memory:         1048576        (1 GiB)
Threads:        4
```

All parameters match the design in
[08 — Reference Architecture §3.4](08-reference-architecture.md#34-why-luks2-with-these-parameters).
The 1 GiB argon2id memory cost is comfortably within early-boot RAM on a 16 GB machine.

> ⚠️ **A TEMPORARY PASSPHRASE WAS SET.** The interactive path failed repeatedly, so the
> container was created non-interactively to unblock the build. **It must be changed
> before the machine carries any real data:**
> ```bash
> sudo cryptsetup luksChangeKey /dev/nvme0n1p3
> ```
> This is instant and non-destructive — it re-wraps the master key in a new keyslot;
> the filesystems above are untouched. Not yet done at time of writing.

---

### Phase 7 — LVM + filesystems ✅

```bash
sudo pvcreate -ff -y /dev/mapper/cryptsystem
sudo vgcreate vg_mint /dev/mapper/cryptsystem
sudo lvcreate -y -L 120G -n lv_root vg_mint
sudo lvcreate -y -L 280G -n lv_home vg_mint
sudo lvcreate -y -L  20G -n lv_swap vg_mint
sudo mkfs.ext4 -F -L mint-root /dev/vg_mint/lv_root
sudo mkfs.ext4 -F -L mint-home /dev/vg_mint/lv_home
sudo mkswap       -L mint-swap /dev/vg_mint/lv_swap
```

**Verified — volume group:**
```
VG Size          473.92 GiB
PE Size          4.00 MiB
Total PE         121324
Alloc PE / Size  107520 / 420.00 GiB
Free  PE / Size   13804 /  53.92 GiB      <- the reserve, as designed
```

The **53.92 GiB free** is the deliberate over-provisioning reserve from
[§3.8](08-reference-architecture.md#38-why-53-gib-is-left-unallocated) — 11.4% of the
container left unwritten for the DRAM-less controller and LVM snapshots.

**Verified — logical volumes and filesystem UUIDs:**

| Volume | Size | FS | Label | UUID |
|---|---|---|---|---|
| `/dev/vg_mint/lv_root` | 120.00 GiB | ext4 | `mint-root` | `a7e15b90-7034-4cbf-a707-c72475305fa1` |
| `/dev/vg_mint/lv_home` | 280.00 GiB | ext4 | `mint-home` | `57ebd2a7-8f3d-4923-bd30-788ede2077ed` |
| `/dev/vg_mint/lv_swap` | 20.00 GiB | swap | `mint-swap` | `4c724c8c-87d5-4e5f-9932-c748f54d39e9` |

---

### Phase 8+ — Install, crypttab repair, tuning ⏸️ pending

Per [09 — Installer Reference Table](09-installer-reference-table.md) Table 1, then
`scripts/post-install-crypttab.sh`, then
[05 — Post-Install Optimization](05-post-install-optimization.md).

---

## State after Phase 7 (current)

```
NAME                    SIZE TYPE  FSTYPE      LABEL       MOUNTPOINT
nvme0n1               476.9G disk
├─nvme0n1p1               1G part  vfat        ESP         (→ /boot/efi)
├─nvme0n1p2               2G part  ext4        boot        (→ /boot)
└─nvme0n1p3           473.9G part  crypto_LUKS cryptsystem
  └─cryptsystem       473.9G crypt LVM2_member
    ├─vg_mint-lv_root   120G lvm   ext4        mint-root   (→ /)
    ├─vg_mint-lv_home   280G lvm   ext4        mint-home   (→ /home)
    └─vg_mint-lv_swap    20G lvm   swap        mint-swap   (→ swap)
```

| Property | Before | After |
|---|---|---|
| Logical sector size | 512 B | **4096 B** |
| Sector count | 1,000,215,216 | 125,026,902 |
| Partition table GUID | `34400F9E-…` | `62881706-…` |
| Partitions | 4 (Windows) | 3 (Linux) |
| ESP | 100 MiB | **1024 MiB** |
| Operating system | Windows 11 | *(none — install pending)* |
| Encryption | none | **LUKS2, AES-256-XTS, argon2id** ⚠️ temp passphrase |
| Volume management | none | **LVM2, VG `vg_mint`** |
| Swap | none | **20 GiB, encrypted, hibernation-capable** |
| Unallocated reserve | — | **53.92 GiB** |

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
- **LUKS passphrase is TEMPORARY** — must be changed with
  `sudo cryptsetup luksChangeKey /dev/nvme0n1p3` before the machine carries real data.
- **Mint not yet installed.**

---

## 2026-08-15 — Gaming stack, cooling optimization, adversarial review

**Environment:** installed system (no longer live USB). Mint 22.3 Cinnamon,
kernel 7.0.0-28-generic, BIOS 1.50.1, X11, AC power. LUKS+LVM on NVMe.

**Rollback point:** Timeshift RSYNC snapshot `2026-08-15_05-03-29`
("pre-steam-install"), verified — 587,493 files, 14 GB, `/home/user` excluded.
Restore with `sudo timeshift --restore --snapshot 2026-08-15_05-03-29`.

> Snapshots live on `/home/timeshift`, i.e. the same LUKS container on the same
> NVMe. Protects against a bad package or config; **not** against drive failure.

### Installed

| Package | Purpose |
|---|---|
| `steam-installer` 1:1.0.0.79~ds-2 | Native Steam (199 pkgs, 498 MB, i386 multiarch) |
| `mangohud` 0.6.9.1 | Frame/power overlay (**amd64 only** — `mangohud:i386` absent from noble) |
| `intel-gpu-tools` 1.28 | Required by MangoHud to read Intel GPU stats |
| `libgamemodeauto0:i386` 1.8.1 | Stops 32-bit LD_PRELOAD errors in the Steam chain |

Verified `mesa-vulkan-drivers` / `libgl1-mesa-dri` at **25.2.8** on *both* amd64 and
i386, and the shared `intel_icd.json` resolving per-arch via a relative
`library_path`. Age of Empires: DE (AppID 1017900, 12.93 GB) installed and launched
under Proton Experimental + DXVK.

### Configuration applied

| Change | File / knob | Note |
|---|---|---|
| Lock-screen / greeter background | `/etc/lightdm/slick-greeter.conf` | Image placed in `/usr/share/backgrounds/` — `/home/user` is `750` and unreadable by `lightdm` |
| gamemode tuning | `/etc/gamemode.ini` | `desiredgov=powersave` is a **no-op**, retained only to suppress gamemode's `performance` default; `defaultgov` deliberately unset |
| `gamemode` group | `usermod -aG gamemode user` | Grants `RLIMIT_NICE` via `limits.d/10-gamemode.conf` — **needs re-login** |
| Compositor unredirect | `org.cinnamon.muffin unredirect-fullscreen-windows=true` | Was `false`; fullscreen games were composited every frame |
| `hwp_dynamic_boost` | `/sys/devices/system/cpu/intel_pstate/` | `0` → `1`; not persistent across reboot |
| Platform profile | `platform_profile=cool` | Writes BIOS token `ThermalManagement=Cool`; **provisional** — see [17 §7](17-cooling-optimization.md) |

### Reverted / corrected during the session

- **`MESA_SHADER_CACHE_MAX_SIZE=10G`** added to `/etc/environment`, then **removed**.
  Inert three ways (pam_env applies at login; `steamclient.so` sets the variable
  itself; foz cache mode ignores size eviction). Real shader working set: **8.7 MB**.
- **`platform-profile-cool.service`** installed with `WantedBy=suspend.target` —
  those targets activate *before* sleep, not after resume. The BIOS token also
  appears self-persistent, so the unit may be redundant entirely. **Left in place
  pending one reboot to confirm.**
- **Launch options** corrected from `gamemoderun mangohud %command%` to
  **`MANGOHUD=1 gamemoderun %command%`** — the `mangohud` wrapper's `$LIB` expands
  to `i386-linux-gnu` for the 32-bit half of the Steam chain, where the library
  does not exist.

### Measurement corrections

The session's central power model was **wrong** and was corrected by review:

| Claimed | Actual |
|---|---|
| "18.7 W sustained cap" | **18.75 W is the MMIO short-term limit.** Sustained is ~28–30 W (`intel-rapl-mmio:0`) |
| "DXVK_state_cache populating" | **0 files** — DXVK 2.x removed it |
| "shader cache proves compile stutter" | 659 MB of 668 MB is `transcoded_video.foz` — **video, not shaders** |
| "act < cur proves GPU idle" | `gt_act_freq_mhz` reads **0** in RC6; a steady 750 MHz means awake and **clamped** |

Full detail in [18 — Adversarial Review Log](18-adversarial-review-log.md).

### Added

- `docs/16-thermal-and-power-architecture.md` — mechanism and concepts
- `docs/17-cooling-optimization.md` — measurements, applied config, procedure
- `docs/18-adversarial-review-log.md` — review findings and alternates not taken
- `scripts/post-reboot-gaming-baseline.sh` — resumable FPS baseline + profile A/B harness

### Outstanding

| Priority | Item |
|---|---|
| 🔴 | **Battery charge policy** — TLP's `START_CHARGE_THRESH_BAT0=95` is **silently inert**; sysfs reports 50/100 because `PrimaryBattChargeCfg=Adaptive` makes custom values read-only. Cell is at 23.6% health and held at 100% SoC. See [17 §6](17-cooling-optimization.md) and [F-01](07-findings-and-risks.md#f-01). |
| 🟠 | **No FPS baseline exists** — all GPU-saturation conclusions are inference |
| 🟠 | `platform_profile` final selection — pending controlled A/B at steady state |
| 🟡 | `perf_event_paranoid=4` blocks `intel_gpu_top` for non-root; MangoHud GPU fields stay blank until lowered to 2 (security tradeoff) |
| 🟡 | Confirm whether `platform-profile-cool.service` is needed at all |

---

## 2026-08-16 — Camera subsystem characterisation

**Scope:** read-only investigation of the integrated webcam. **No persistent system
change was made.** Full detail in [23 — Camera & Imaging Subsystem](23-camera-and-imaging.md).

**Environment:** installed system (not live USB), kernel 7.0.0-28-generic, BIOS 1.50.1.

### Executed

| Action | Persistent? |
|---|---|
| `apt-get install -y v4l-utils` — required tooling, absent on stock Mint 22.3 | **Yes** (package only) |
| `v4l2-ctl -c exposure_dynamic_framerate=0` then `=1` — A/B framerate test | **No** — restored to as-found value `1` |
| Two single-frame captures to verify the pipeline | **No** — `shred`-deleted; only dimensions, pixel format and luminance statistics were read, no image content inspected |
| Sustained + concurrent stream tests | **No** — all frames written to `/dev/null` |

### Measured

- **Dual-sensor device confirmed:** two UVC functions behind one USB device —
  `if 0+1` → `/dev/video0` RGB, `if 2+3` → `/dev/video2` IR 8-bit greyscale.
  `/dev/video1` and `/dev/video3` are metadata-only nodes.
- **1080p framerate defect reproduced:** 22 fps with `exposure_dynamic_framerate=1`
  (as found) versus **30 fps** with it disabled. The UVC default for this control is
  `0`; this unit reports `1`.
- **RGB and IR stream concurrently** without contention.
- Camera access is granted by **systemd-logind per-seat ACL**, not `video` group
  membership — the operator account is not in `video`.
- USB runtime autosuspend is active and already optimal (`suspended`, 2000 ms delay).

### Added

- `docs/23-camera-and-imaging.md` — full subsystem characterisation, findings F-C1…F-C7
- `scripts/camera-diagnostics.sh` — read-only collector; redacts the webcam serial by
  default; optional `--throughput` measurement that stores no image data

### Outstanding

| Priority | Item |
|---|---|
| 🟠 | **F-C1** — `exposure_dynamic_framerate` costs 25% of 1080p framerate. Fix is a udev rule ([23 §6.2](23-camera-and-imaging.md)); **not applied**, because it trades away low-light brightness. Owner decision. |
| 🟡 | **F-C4** — `collect-diagnostics.sh` does **not** redact the webcam serial (it is unprefixed and embedded in `/dev/v4l/by-id/` paths). Fold the pattern from `camera-diagnostics.sh` into it before the next diagnostics run is committed. |
| 🟡 | **F-C3** — `dell-privacy` does not map this firmware's privacy keycodes (type `0x0012`, code `0x002d`); no desktop indicator. Upstream driver gap; protection itself is unaffected. |
| 🔵 | Whether this unit has a physical SafeShutter or an electronic-only privacy cut is **undetermined** — indistinguishable from software, needs visual inspection. |
| 🔵 | IR sensor is functional and unused; available for `howdy` face auth if wanted. |
## 2026-08-22 — Lid power-on investigation; sleep unmasked

Triggered by a single question: *is the laptop automatically turning on when the
lid opens?* It is. Full analysis in
**[21 — Lid Power-On & Sleep](21-lid-power-and-sleep.md)**.

### Found

| Finding | Evidence |
|---|---|
| **`PowerOnLidOpen=Enabled`** (Dell factory default) — the EC cold-boots the machine from S5 on lid open | `dell-wmi-sysman` attribute read as root |
| **`sleep.target`, `suspend.target`, `hibernate.target`, `hybrid-sleep.target` all masked** → `/dev/null` | Symlinks, all stamped **2026-08-16 23:29:55** |
| The masking appears in **no script and no doc in this repo** — a manual action taken outside the tooling | `grep -rn 'systemctl mask' scripts/ docs/` → only `power-profiles-daemon` |
| **No suspend-to-RAM has ever completed on this install** | `journalctl \| grep -c "PM: suspend entry"` → **0** across all retained boots |
| **One hibernation was attempted 2026-08-16 06:35 and did not complete** — froze userspace, preallocated a 4.3 GB image, entered ACPI **S4**, came back out, no image written, no power-off. 17 h later all four sleep targets were masked | Kernel log: `Preparing to enter system sleep state S4` → `Waking up from system sleep state S4` → `Restarting tasks` |
| Three further suppressors below the masking: Cinnamon `lid-close-*-action=blank`, `sleep-inactive-*-type=nothing`, and a `csd-power` **block** inhibitor on `handle-lid-switch` ("Multiple displays attached") | `gsettings`, `systemd-inhibit --list` |
| Platform is **s2idle-only — no S3** | `/sys/power/mem_sleep` = `[s2idle]`; `ACPI: PM: (supports S0 S4 S5)` |
| **Hibernate is blocked by an Ubuntu polkit rule**, not by hardware — every kernel/swap prerequisite passes | logind debug trace ends at `PolicyKit1 … CheckAuthorization`; `com.ubuntu.desktop.rules:65` returns `polkit.Result.NO` |

Together the first two explain the reported behaviour completely: with suspend
impossible, **S5 was the only low-power state the machine ever reached** — and S5 is
exactly the state `PowerOnLidOpen` acts from.

### Applied

| Change | Command | Verified |
|---|---|---|
| Unmasked all four sleep targets | `systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target` | All four report `static`; no mask symlinks remain in `/etc` or `/run` |
| — | `systemctl daemon-reload` | `CanSuspend` **`no` → `yes`** via `busctl` on `login1.Manager` |

### Deliberately not applied

- **`PowerOnLidOpen` left Enabled.** Firmware setting, user's call. `dell-wmi-sysman`
  cannot write it anyway — `authentication/Admin/is_enabled=0`, and the driver
  refuses attribute writes without a BIOS admin password. F2 → Power Management.
- **Lid close still only blanks.** The Cinnamon actions and the `csd-power`
  inhibitor were left as found; changing them is a behavioural preference, not a fix.
- **Hibernate left blocked.** An override rule is drafted in
  [21 §6](21-lid-power-and-sleep.md) but not installed and not tested against the
  LUKS-backed swap LV.

### Side effects checked

- `swapoff /dev/zram0` was used briefly to rule out zram as the hibernate blocker,
  then restored with `swapon -p 100 /dev/zram0`. Usage was 0 B throughout; priorities
  are back to `dm-3 = -1`, `zram0 = 100`.
- `systemd-logind` log level was raised to `debug` via the `LogControl1` D-Bus
  interface for two queries and **returned to `info`**.

### Added

- `docs/21-lid-power-and-sleep.md` — includes §7, lid behaviour when docked behind a KVM
- `docs/06` — lid rows in the Power Management table, firmware-vs-OS section,
  s2idle confirmation, pre-install checklist item

### Outstanding

| Priority | Item |
|---|---|
| 🟠 | **Suspend permitted but never exercised.** `CanSuspend=yes` is not proof that s2idle resumes cleanly under LUKS with `i915.enable_dpcd_backlight=0`. Test deliberately; the backlight regression in [13](13-display-and-keyboard-backlight.md) is the most plausible interaction. |
| 🟡 | Decide whether lid close should suspend, and whether the external-display inhibitor is wanted. |
| 🟡 | Hibernate: apply the polkit rule and test, or record the decision not to. |
| 🟡 | Audit whether anything else was changed manually in the undocumented 2026-08-16 23:29 session. |
| 🟡 | **Lid close is inert only while a Cinnamon session runs** — `csd-power`'s inhibitor does not exist at the greeter or on a TTY, where `HandleLidSwitch=suspend` now applies. Drop-in to make it unconditional is in [21 §7](21-lid-power-and-sleep.md); recommended for docked/KVM use, **not applied**. |

### Follow-up — drive migration documentation (same day)

Documentation only; no change to the machine. Two hardware facts were established
that were not previously recorded anywhere in this repo:

| Finding | Evidence | Consequence |
|---|---|---|
| **The SSD slot is PCIe 4.0 x4, not 3.0** — root port `00:06.0` advertises `LnkCap 16GT/s`, CPU-attached. `LnkSta` reads 8GT/s only because the KIOXIA BG4 is a Gen3 part | `lspci -vv -s 00:06.0` | A Gen4 replacement negotiates Gen4. `docs/01` previously recorded only the endpoint's link and implied Gen3 was the ceiling |
| **The M.2 2230 WWAN slot is occupied and is USB-wired** — Dell **DW5829e-eSIM** Snapdragon X20 LTE on USB bus 004 | `lsusb`, `lspci` | Rules out the widely-circulated "put a 2230 SSD in the spare WWAN slot" trick on this unit, twice over |

Also noted: the SD card reader is a Realtek **RTS525A** at `72:00.0` — **PCIe**-attached
rather than USB, which makes it better than the usual laptop card reader.

### Added

- `docs/22-drive-migration.md` — clone procedure, ten copy methods compared, M.2
  selection criteria, other storage expansion paths
- `docs/01` — endpoint vs slot link rows, Gen4 note, upgrade pointer
- `docs/02` — §9's 4 KiB LBA opportunity re-opened now that dual-boot is gone, with
  the clone-vs-rebuild tradeoff it implies
