# 11 — Post-Boot Runbook

**Ordered task list for the first session after Linux Mint boots successfully.**

Work top to bottom. The order is deliberate — it runs security and data-loss
insurance before convenience, and respects dependencies (TPM enrolment must follow
Secure Boot, or it binds to a PCR state that is about to change).

Each step states **why**, the **command**, and a **verification** you can check before
moving on. Skip anything that does not match your usage — but do not reorder Phase A.

---

# Phase 0 — BEFORE the first boot ⛔

**This runs while still in the live USB session, immediately after the Mint installer
finishes. It is not optional.**

## Step 0 — Repair the encryption configuration

When the installer completes, it offers **Restart Now** / **Continue Testing**.

> ⛔ **Choose "Continue Testing". Do NOT reboot.**

The Mint installer was handed `/dev/mapper/vg_mint-*` devices and has **no idea a LUKS
container exists underneath them**. It therefore does not reliably write
`/etc/crypttab`, and may omit `cryptsetup` and `lvm2` from the initramfs.

Reboot without fixing that and the machine drops to a `(initramfs)` prompt, never
finds the root filesystem, and cannot be recovered without a live USB.

```bash
sudo /home/mint/dell-7420-optimization/scripts/post-install-crypttab.sh
```

Run it from a **desktop terminal** (Menu → Terminal, or `Ctrl+Alt+T`). It will ask for
your LUKS passphrase once, to reopen the container.

### What it does

| | Action | Why |
|---|---|---|
| 1 | Opens the LUKS container, activates `vg_mint`, mounts `/`, `/boot`, `/boot/efi` and bind-mounts `/dev`, `/proc`, `/sys`, `/run` | Builds a working chroot into the installed system |
| 2 | Writes `cryptsystem UUID=<luks-uuid> none luks,discard` to `/etc/crypttab` | Tells the initramfs which device to unlock. **`discard` is what lets TRIM reach the SSD** — without it `fstrim` silently does nothing on this DRAM-less drive |
| 3 | Installs `cryptsetup-initramfs` and `lvm2` inside the chroot | Without these the initramfs cannot unlock LUKS or find the volume group |
| 4 | `update-initramfs -u -k all` | Rebuilds the boot image with that tooling included |
| 5 | `update-grub` | Regenerates the boot menu |
| 6 | `cryptsetup luksHeaderBackup` → `/root/luks-backup/` | Insurance against total, unrecoverable data loss |
| 7 | Asserts 7 conditions, unmounts via EXIT trap | Refuses to say "safe to reboot" unless every one passes |

### The 7 assertions

All must report **PASS**:

```
  /etc/crypttab has the LUKS UUID ... PASS
  cryptsetup present in initramfs  ... PASS
  lvm present in initramfs         ... PASS
  /boot entry in fstab             ... PASS
  /boot/efi entry in fstab         ... PASS
  GRUB EFI binary installed        ... PASS
  LUKS header backup taken         ... PASS
```

Ending in:
```
════════════════════════════════════════════════════════════════
 ALL CHECKS PASSED — safe to reboot
════════════════════════════════════════════════════════════════
```

**If any check FAILS, do not reboot.** The script exits non-zero and prints what
failed. Cross-reference the recovery table in
[09 — Installer Reference Table](09-installer-reference-table.md#recovery--if-it-will-not-boot).

### Then reboot

```bash
sudo reboot
```

Remove the USB stick when prompted. You should get a **LUKS passphrase prompt**, then
the Mint desktop. That prompt appearing is proof steps 2–4 worked.

> **If you see `(initramfs)` instead:** the repair did not take. Boot the live USB and
> re-run the script — it is idempotent and safe to run again. It will detect the
> existing `crypttab` entry and header backup and skip them.

---

# Phase A onward — after the first successful boot

> **Prerequisite:** the machine boots, prompts for the LUKS passphrase, and reaches the
> desktop.

---

## Priority summary

| # | Phase | Task | Time | Why now |
|---|---|---|---|---|
| **0** | **0** | **`post-install-crypttab.sh`** | **5 min** | **Before first boot. Skip it and the machine is unbootable.** |
| **1** | A | CPU microcode | 3 min | Machine is **actively vulnerable** to Downfall |
| **2** | A | Get the LUKS header backup off-machine | 5 min | Single point of total data loss |
| **3** | A | Verify the boot chain is real | 2 min | Confirm you can recover before you depend on it |
| **4** | B | TRIM timer | 1 min | DRAM-less SSD degrades without it |
| **5** | B | `noatime` in fstab | 3 min | Removes a write per file read |
| **6** | B | swappiness + cache pressure | 2 min | 16 GB RAM, wear-sensitive drive |
| **7** | B | zram | 3 min | Keeps routine swap off the SSD |
| **8** | C | thermald | 2 min | Tiger Lake sustained-load cliff |
| **9** | C | TLP + charge thresholds | 10 min | 14.6 Wh battery — every watt counts |
| **10** | D | VA-API hardware video | 5 min | Video on CPU is a large needless drain |
| **11** | E | Firmware updates | 10 min | Do **before** TPM enrolment |
| **12** | E | Secure Boot | 10 min | Must precede TPM PCR 7 binding |
| **13** | E | TPM auto-unlock | 5 min | Last — depends on 11 and 12 |
| **14** | F | Hibernation | 10 min | The safety net for a dying battery |
| **15** | F | Timeshift | 10 min | Recovery for everything after this |
| **16** | F | journald cap | 1 min | Bounded log writes |
| **17** | G | Full validation | 5 min | Confirm the whole stack |
| **18** | H | **Battery + adapter** | — | **Hardware. Nothing above substitutes.** |

Total software time: roughly 90 minutes.

---

# Phase A — Do these first

Security and data-loss insurance. Nothing else should precede them.

### 1. CPU microcode — the machine is vulnerable right now

[F-06](07-findings-and-risks.md#f-06): Gather Data Sampling (Downfall,
CVE-2022-40982) reports **Vulnerable**. This CPU has full AVX-512, squarely in scope.
The mitigation ships in microcode, not the kernel.

```bash
sudo apt update
sudo apt install intel-microcode
sudo reboot
```

**Verify after reboot:**
```bash
grep . /sys/devices/system/cpu/vulnerabilities/gather_data_sampling
```
Expect `Mitigation: Microcode` or `Not affected`. BIOS 1.50.1 is current, so if it
still reports vulnerable, the BIOS-supplied microcode is already the newest for this
stepping — nothing further to do.

---

### 2. Move the LUKS header backup off the machine

`scripts/post-install-crypttab.sh` wrote it to `/root/luks-backup/`. **A header backup
stored on the disk it protects is worthless when that disk fails.**

The LUKS2 header holds the wrapped master key. Damage it — a bad write, a stray `dd`,
a firmware fault — and all 473 GiB become permanently unrecoverable. Your passphrase
will not help. This is the only failure mode in the design with no fallback.

```bash
sudo ls -l /root/luks-backup/
sudo cp /root/luks-backup/luks-header-nvme0n1p3.img /media/<you>/<usb>/
sudo chmod 600 /media/<you>/<usb>/luks-header-nvme0n1p3.img
```

> ⚠️ Treat this file as key material. Combined with your passphrase it unlocks the
> disk, so store it as you would a key — offline, not in cloud sync, not in this repo.

**Consider a second keyslot too.** You currently have exactly one. A corrupted keyslot
or a forgotten passphrase means total loss:
```bash
sudo cryptsetup luksAddKey /dev/nvme0n1p3     # add a long recovery passphrase
sudo cryptsetup luksDump /dev/nvme0n1p3 | grep -c 'luks2'    # expect 2
```
Store that recovery passphrase in a password manager.

**Restore procedure**, if ever needed:
```bash
sudo cryptsetup luksHeaderRestore /dev/nvme0n1p3 \
     --header-backup-file luks-header-nvme0n1p3.img
```

---

### 3. Prove the boot chain actually works

Confirm the encryption stack is genuinely wired up — before you come to depend on it.

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
cat /etc/crypttab
findmnt /boot /boot/efi / /home
swapon --show
```

**Expect:**
- `crypttab` contains one line: `cryptsystem UUID=… none luks,discard`
- `/`, `/home`, `/boot`, `/boot/efi` all mounted from the right devices
- swap active on `/dev/mapper/vg_mint-lv_swap`

`discard` in `crypttab` is what lets TRIM reach the SSD through the LUKS layer. Without
it, step 4 silently does nothing.

---

# Phase B — Storage and memory

### 4. Enable periodic TRIM

The KIOXIA BG4 is **DRAM-less**. Neglected TRIM degrades it disproportionately.

```bash
sudo systemctl enable --now fstrim.timer
sudo fstrim -av
```

**Verify:**
```bash
systemctl status fstrim.timer
lsblk --discard        # DISC-GRAN and DISC-MAX must be non-zero on nvme0n1
```
`fstrim -av` should report bytes trimmed on `/` and `/home`. If it reports 0 or errors,
`discard` is missing from `/etc/crypttab` — fix that first.

> Use the **weekly timer, not `discard` in `/etc/fstab`.** Continuous TRIM issues a
> command on every delete, causing latency spikes on a DRAM-less controller. Batched
> is strictly better here. (`discard` in *crypttab* is a different thing — that is
> pass-through, and it is required.)

---

### 5. Add `noatime`

Removes a metadata **write** on every file **read**.

```bash
sudo cp /etc/fstab /etc/fstab.bak
sudo nano /etc/fstab
```

Add `noatime` to the `/`, `/home` and `/boot` entries:
```
UUID=a7e15b90-…  /       ext4  defaults,noatime,errors=remount-ro  0 1
UUID=57ebd2a7-…  /home   ext4  defaults,noatime                    0 2
UUID=826b3c21-…  /boot   ext4  defaults,noatime                    0 2
```

`errors=remount-ro` on root matters given [F-04](07-findings-and-risks.md#f-04) — on
filesystem error the system goes read-only rather than writing into damage.

```bash
sudo mount -o remount /
sudo mount -o remount /home
findmnt -o TARGET,OPTIONS / /home | grep noatime
```

> Verify with `findmnt` **before rebooting**. A malformed fstab drops you to an
> emergency shell at boot. `/etc/fstab.bak` is your way back.

---

### 6. Kernel VM tuning

```bash
sudo tee /etc/sysctl.d/99-mint-tuning.conf >/dev/null <<'EOF'
# 16 GB RAM, wear-sensitive DRAM-less SSD: swap late, keep metadata cached
vm.swappiness=10
vm.vfs_cache_pressure=50
EOF
sudo sysctl --system
```

**Verify:** `sysctl vm.swappiness vm.vfs_cache_pressure` → `10` and `50`.

> Do **not** set `swappiness=0`. That does not disable swap — it makes the OOM killer
> fire instead of swapping. 10 is correct.

---

### 7. zram

Compressed RAM swap absorbs pressure without touching the SSD.

```bash
sudo apt install zram-tools
sudo tee /etc/default/zramswap >/dev/null <<'EOF'
ALGO=zstd
PERCENT=25
PRIORITY=100
EOF
sudo systemctl restart zramswap
```

**Verify:**
```bash
swapon --show
```
Expect `/dev/zram0` at **priority 100** and `/dev/dm-3` (lv_swap) at a lower priority.
The kernel fills compressed RAM first and only spills to disk under real pressure.

> **Keep the 20 GiB disk swap.** zram cannot hold a hibernation image. Both coexist
> deliberately — see step 14.

---

# Phase C — Power and thermal

### 8. thermald

Tiger Lake in a thin chassis hits a hard thermal cliff under sustained multi-core load
without DPTF-aware management.

```bash
sudo apt install thermald
sudo systemctl enable --now thermald
systemctl status thermald
```

---

### 9. TLP and charge thresholds

⚠️ **Do not run TLP alongside `power-profiles-daemon`** — they fight over the same
sysfs knobs.

```bash
sudo apt install tlp tlp-rdw
sudo systemctl enable --now tlp
systemctl status power-profiles-daemon    # must be masked/inactive
```

```bash
sudo tee /etc/tlp.d/01-latitude-7420.conf >/dev/null <<'EOF'
CPU_DRIVER_OPMODE_ON_AC=active
CPU_DRIVER_OPMODE_ON_BAT=active
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# Enables the NVMe deep power states (0.05 W / 0.005 W)
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

INTEL_GPU_MIN_FREQ_ON_AC=100
INTEL_GPU_MIN_FREQ_ON_BAT=100

WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

USB_AUTOSUSPEND=1
USB_EXCLUDE_BTUSB=1

START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
EOF
sudo systemctl restart tlp
sudo tlp-stat -s -b -p
```

> `powersave` looks wrong but is correct. With `intel_pstate` in **active** mode,
> `powersave` is the full-range HWP governor — the CPU still reaches 4.4 GHz. The
> `performance` governor merely pins maximum frequency and wastes power. Behaviour is
> steered by `CPU_ENERGY_PERF_POLICY` (the EPP hint), which is the knob set above.

> ⚠️ **Apply charge thresholds to the replacement battery, not the current one.**
> Capping a 14.6 Wh cell at 80% leaves ~11.7 Wh — under an hour. Set
> `STOP_CHARGE_THRESH_BAT0=100` until the new battery arrives.

**Verify:** `cat /sys/class/power_supply/BAT0/charge_control_end_threshold`

---

# Phase D — Graphics and media

### 10. Hardware video acceleration

Without VA-API, video decodes on the CPU — a large, needless drain on a battery this
degraded.

```bash
sudo apt install intel-media-va-driver-non-free vainfo
vainfo | grep -E 'VAProfile(H264|HEVC|VP9|AV1)'
```

Expect H264, HEVC, VP9 and AV1 profiles. Use the `-non-free` package — the `-free`
variant lacks several codec profiles. Despite the name it is redistributable firmware,
not a proprietary kernel driver.

**Firefox** (`about:config`):
```
media.ffmpeg.vaapi.enabled                  = true
media.hardware-video-decoding.force-enabled = true
```
Confirm in `about:support` → *Media* → decoder should report hardware.

---

# Phase E — Boot security

**Order matters. 11 → 12 → 13.** Firmware updates and Secure Boot both change TPM PCR
values; enrolling the TPM first means immediately re-enrolling it.

### 11. Firmware updates — before TPM enrolment

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

⚠️ AC power required (`fwupd` enforces this). BIOS 1.50.1 is current, so a BIOS update
is unlikely to be pending. SSD firmware updates carry small nonzero risk and the drive
is healthy — no reason to apply one.

---

### 12. Secure Boot

Every component of this machine uses an in-tree driver
([F-14](07-findings-and-risks.md#f-14)) — there are no unsigned modules to break.

```bash
sudo apt install --reinstall shim-signed grub-efi-amd64-signed
sudo update-grub
```

Reboot → **F2** → **Secure Boot → Enabled**, Mode → **Deployed Mode**.

**Verify:** `mokutil --sb-state` → `SecureBoot enabled`

> If it fails to boot, re-enter setup and disable it. Nothing is damaged — it is a
> reversible firmware policy toggle.

---

### 13. TPM auto-unlock — last

Full-disk encryption with no passphrase prompt. PCR 0 binds to firmware, PCR 7 to
Secure Boot state; the key is released only if neither was tampered with.

```bash
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
sudo update-initramfs -u -k all
sudo reboot
```

**Verify:** `sudo systemd-cryptenroll /dev/nvme0n1p3` lists a `tpm2` slot, and the
machine boots without prompting.

> **Keep your passphrase.** A BIOS update changes PCR 0 and invalidates the binding,
> requiring the passphrase and a re-enrol. That is the mechanism working correctly, not
> a fault. PCR 7 only carries weight because you did step 12 first.

---

# Phase F — Resilience

### 14. Hibernation

The 20 GiB swap volume exists for this. Ubuntu-derived distributions disable
hibernation by default.

Given [F-01](07-findings-and-risks.md#f-01), hibernate-on-critical-battery is the one
mechanism that preserves unsaved work when a degraded cell collapses.

```bash
SWAP_UUID=$(sudo blkid -s UUID -o value /dev/vg_mint/lv_swap)
echo "$SWAP_UUID"
```

Add `resume=UUID=<that>` to `GRUB_CMDLINE_LINUX_DEFAULT` in `/etc/default/grub`, then:

```bash
sudo update-grub
echo "RESUME=UUID=$SWAP_UUID" | sudo tee /etc/initramfs-tools/conf.d/resume
sudo update-initramfs -u -k all
sudo systemctl hibernate      # test it
```

Then hibernate on critical battery:
```bash
sudo tee -a /etc/UPower/UPower.conf >/dev/null <<'EOF'
CriticalPowerAction=Hibernate
PercentageAction=4
EOF
sudo systemctl restart upower
```

**Also check suspend drain** ([F-12](07-findings-and-risks.md#f-12)):
```bash
cat /sys/power/mem_sleep
```
`[s2idle]` alone means Modern Standby only. If overnight drain is severe and `deep` is
available, add `mem_sleep_default=deep` to the GRUB cmdline. On a 14.6 Wh cell this
matters more than it would on a healthy battery.

---

### 15. Timeshift

```bash
sudo apt install timeshift
```
Menu → **Timeshift** → **RSYNC** → target `/home` or external media.

> ⚠️ **Do not target the same volume as `/`.** A full root then breaks both the system
> and its backups. `lv_home` is a separate LV, so it is an acceptable target — external
> media is better.

---

### 16. Cap journald

```bash
sudo sed -i 's/^#\?SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
journalctl --disk-usage
```

---

# Phase G — Validation

### 17. Full check

```bash
echo "--- sector size (expect 4096) ---";        sudo blockdev --getss /dev/nvme0n1
echo "--- LUKS ---";                             sudo cryptsetup luksDump /dev/nvme0n1p3 | grep -E 'Version|Cipher|PBKDF'
echo "--- LVM reserve (expect ~53 GiB) ---";     sudo vgdisplay vg_mint | grep -E 'VG Size|Free'
echo "--- TRIM ---";                             lsblk --discard | head -3; systemctl is-enabled fstrim.timer
echo "--- swap (zram prio 100 first) ---";       swapon --show
echo "--- mitigations ---";                      grep . /sys/devices/system/cpu/vulnerabilities/*
echo "--- power ---";                            sudo tlp-stat -s | head -20
echo "--- charge threshold ---";                 cat /sys/class/power_supply/BAT0/charge_control_end_threshold
echo "--- secure boot ---";                      mokutil --sb-state
echo "--- TPM enrolment ---";                    sudo systemd-cryptenroll /dev/nvme0n1p3
echo "--- video accel ---";                      vainfo 2>&1 | grep -cE 'VAProfile(H264|HEVC|VP9|AV1)'
echo "--- SSD health ---";                       sudo smartctl -a /dev/nvme0n1 | grep -E 'Percentage|Available Spare|Media and Data|Unsafe'
echo "--- thermals ---";                         sensors | grep -E 'Package|Composite|fan'
```

### Acceptance criteria

| Check | Pass |
|---|---|
| Sector size | `4096` |
| LUKS | Version 2, `aes-xts-plain64`, `argon2id` |
| LVM free | > 50 GiB |
| TRIM | `fstrim.timer` enabled, `DISC-MAX` non-zero |
| Swap | zram priority 100, `lv_swap` lower, total ≥ 20 GiB |
| **GDS** | **not `Vulnerable`** |
| Charge threshold | `80` (or `100` until the battery is replaced) |
| Secure Boot | `SecureBoot enabled` |
| TPM | a `tpm2` token listed |
| VA-API | 4 profiles |
| SSD | `Percentage Used` ≤ 10%, `Media and Data Integrity Errors: 0` |
| **Unsafe Shutdowns** | **still 26 — must not be climbing** |
| Hibernate | `systemctl hibernate` resumes |

---

# Phase H — Hardware. No software substitutes for this.

### 18. Battery and adapter

| | |
|---|---|
| 🔴 **[F-01](07-findings-and-risks.md#f-01)** | **Battery at 23.65% of design health** — 14.6 Wh of 61.9 Wh. Dell part family `TN2GY` / `WY9DX` / `M42XW`; verify against the service tag before ordering. |
| 🟠 **[F-09](07-findings-and-risks.md#f-09)** | **Adapter negotiating 45 W** on a 65 W platform. Check the label; replace with the Dell 65 W USB-C PD unit if it reads 45 W. |

Everything in Phases A–G is worth doing regardless. But understand what it does not do:

**These two findings caused the disk corruption that made this rebuild necessary.**
A cell at 23.6% health sags under load and drops the machine — that is where the 26
unsafe shutdowns came from, and those produced the 8,851 NTFS cluster mismatches.

ext4's journal recovers from power loss faster and more reliably than NTFS did, but it
is **not immunity**. Leave the battery as it is and the same pattern will corrupt the
new filesystem exactly as it corrupted the old one.

**Re-check in a month:**
```bash
sudo smartctl -a /dev/nvme0n1 | grep -E 'Unsafe Shutdowns|Error Information'
```
The count should be frozen at 26. If it is climbing, power delivery is still failing.

---

## Quick reference — the whole thing

```bash
# Phase 0 — in the live session, BEFORE rebooting ("Continue Testing")
sudo /home/mint/dell-7420-optimization/scripts/post-install-crypttab.sh
# all 7 assertions must PASS, then:
sudo reboot

# Phase A — first
sudo apt update && sudo apt install -y intel-microcode && sudo reboot
# (copy /root/luks-backup/*.img to external media)
sudo cryptsetup luksAddKey /dev/nvme0n1p3          # optional second keyslot

# Phase B — storage
sudo systemctl enable --now fstrim.timer && sudo fstrim -av
sudo nano /etc/fstab                                # add noatime
printf 'vm.swappiness=10\nvm.vfs_cache_pressure=50\n' | sudo tee /etc/sysctl.d/99-mint-tuning.conf
sudo sysctl --system
sudo apt install -y zram-tools                      # then set PRIORITY=100

# Phase C — power
sudo apt install -y thermald tlp tlp-rdw
sudo systemctl enable --now thermald tlp            # then write /etc/tlp.d/01-latitude-7420.conf

# Phase D — media
sudo apt install -y intel-media-va-driver-non-free vainfo && vainfo

# Phase E — boot security, in this order
sudo fwupdmgr refresh --force && sudo fwupdmgr update
sudo apt install --reinstall -y shim-signed grub-efi-amd64-signed && sudo update-grub
# reboot -> F2 -> enable Secure Boot
sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/nvme0n1p3
sudo update-initramfs -u -k all

# Phase F — resilience
# resume=UUID=... in GRUB, RESUME= in initramfs conf, then:
sudo update-grub && sudo update-initramfs -u -k all && sudo systemctl hibernate
sudo apt install -y timeshift
```
