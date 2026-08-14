# 05 — Post-Install Optimization

Tuning specific to the Dell Latitude 7420 (Tiger Lake i5-1145G7, Iris Xe, AX201,
KIOXIA BG4 DRAM-less NVMe) running Linux Mint 22.3.

> Apply these **after** a successful installation and a confirmed-working boot.
> Each section states *why* — skip anything that does not match your usage.

---

## Priority order

Ranked by actual measured impact on **this** machine, not generic advice:

| Priority | Action | Why it matters here |
|---|---|---|
| 🔴 1 | **Replace the battery** | 23.6% health — no software fix exists |
| 🔴 2 | Install `intel-microcode` | GDS/Downfall shows as **vulnerable** |
| 🟠 3 | Enable periodic TRIM | DRAM-less SSD degrades badly when unmaintained |
| 🟠 4 | Install `tlp` and configure | Meaningful battery gain, and a *very* small battery |
| 🟠 5 | Set charge thresholds | Protects the *replacement* battery |
| 🟡 6 | Enable VA-API hardware video | Big power saving during video playback |
| 🟡 7 | zram swap | Reduces SSD writes on a 9%-worn drive |
| 🟡 8 | Wi-Fi power-save tuning | Only if you observe dropouts |

---

## 1. CPU microcode — do this first

[01 — Hardware Inventory](01-hardware-inventory.md#security-mitigation-status) found
**Gather Data Sampling (GDS / "Downfall", CVE-2022-40982)** reported as
**Vulnerable**. The mitigation ships in CPU microcode.

```bash
sudo apt update
sudo apt install intel-microcode
sudo reboot
```

Verify afterwards:
```bash
grep . /sys/devices/system/cpu/vulnerabilities/gather_data_sampling
grep 'microcode' /proc/cpuinfo | head -1
```

Expect `Mitigation: Microcode` or `Not affected`. BIOS 1.50.1 is current, so if it
still reports vulnerable after this, the BIOS-supplied microcode is being used and is
already the latest available for the part.

---

## 2. SSD maintenance — DRAM-less drive, treat with care

The KIOXIA BG4 has **no onboard DRAM cache**. It relies on Host Memory Buffer and
degrades disproportionately when the filesystem is full or TRIM is neglected.

### Enable periodic TRIM

```bash
sudo systemctl enable --now fstrim.timer
systemctl status fstrim.timer
sudo fstrim -av        # run once now
```

**Use the weekly timer, not `discard` in `/etc/fstab`.** Continuous discard issues a
TRIM on every delete, which on a DRAM-less controller creates latency spikes. Batched
weekly TRIM is strictly better here.

> Exception: `discard` **is** correct in `/etc/crypttab` — that is TRIM *pass-through*
> through the LUKS layer, which is what allows `fstrim` to reach the drive at all.
> Without it, periodic TRIM silently does nothing. See
> [03 — Partitioning Plan](03-partitioning-plan.md#6-post-install-make-encryption-unlock-correctly).

Confirm TRIM reaches the device:
```bash
lsblk --discard      # DISC-GRAN and DISC-MAX must be non-zero for nvme0n1
```

### Reduce swappiness

With 16 GB RAM and a wear-sensitive SSD, avoid swapping until genuinely necessary:

```bash
echo 'vm.swappiness=10' | sudo tee /etc/sysctl.d/99-swappiness.conf
echo 'vm.vfs_cache_pressure=50' | sudo tee -a /etc/sysctl.d/99-swappiness.conf
sudo sysctl --system
```

`vfs_cache_pressure=50` makes the kernel retain directory/inode caches longer,
reducing metadata re-reads.

> Do **not** set `swappiness=0`. It does not "disable swap" — it makes the OOM killer
> fire instead of swapping, which is worse. 10 is the right value.

### Mount options

Add `noatime` to the root and home entries in `/etc/fstab` — it removes a metadata
write on every file *read*:

```
UUID=<root-uuid>  /      ext4  defaults,noatime,errors=remount-ro  0 1
UUID=<home-uuid>  /home  ext4  defaults,noatime                    0 2
```

`relatime` is the kernel default and already reduces this, but `noatime` eliminates
it. Nothing in a normal desktop workload needs atime.

### Keep 15–20% free

On this controller that is a performance requirement, not a guideline. The
~36 GiB of unallocated LVM extents in the recommended layout exists for exactly this.

```bash
df -h /        # keep under ~85%
```

### I/O scheduler

```bash
cat /sys/block/nvme0n1/queue/scheduler
```
Expect `[none]`. That is **correct for NVMe** — the drive's own queues outperform any
kernel scheduler. Do not change it.

---

## 3. Power management

### Install TLP

Mint ships with `laptop-mode-tools` conflicts avoided; TLP is the better choice on
Tiger Lake.

```bash
sudo apt install tlp tlp-rdw
sudo systemctl enable --now tlp
```

⚠️ **Do not install `tlp` and `power-profiles-daemon` together** — they fight over the
same knobs. Mint 22.3 ships `power-profiles-daemon`; installing TLP masks it
automatically, but verify:

```bash
systemctl status power-profiles-daemon   # should be masked/inactive
sudo tlp-stat -s
```

### TLP configuration for this machine

Create `/etc/tlp.d/01-latitude-7420.conf`:

```ini
# --- CPU: intel_pstate active mode, HWP energy-performance preference ---
CPU_DRIVER_OPMODE_ON_AC=active
CPU_DRIVER_OPMODE_ON_BAT=active
CPU_SCALING_GOVERNOR_ON_AC=powersave
CPU_SCALING_GOVERNOR_ON_BAT=powersave
CPU_ENERGY_PERF_POLICY_ON_AC=balance_performance
CPU_ENERGY_PERF_POLICY_ON_BAT=balance_power
CPU_BOOST_ON_AC=1
CPU_BOOST_ON_BAT=0

# --- PCIe ASPM: enables the NVMe deep power states (0.05W / 0.005W) ---
PCIE_ASPM_ON_AC=default
PCIE_ASPM_ON_BAT=powersupersave

# --- NVMe / SATA link power ---
AHCI_RUNTIME_PM_ON_AC=on
AHCI_RUNTIME_PM_ON_BAT=auto

# --- Graphics: Iris Xe ---
INTEL_GPU_MIN_FREQ_ON_AC=100
INTEL_GPU_MIN_FREQ_ON_BAT=100

# --- Wi-Fi AX201: 'off' avoids iwlwifi latency spikes; see Wi-Fi section ---
WIFI_PWR_ON_AC=off
WIFI_PWR_ON_BAT=on

# --- USB autosuspend, but never for input devices ---
USB_AUTOSUSPEND=1
USB_EXCLUDE_BTUSB=1

# --- Battery charge thresholds (see below) ---
START_CHARGE_THRESH_BAT0=75
STOP_CHARGE_THRESH_BAT0=80
```

Apply and inspect:
```bash
sudo systemctl restart tlp
sudo tlp-stat -b -p -d
```

> `CPU_SCALING_GOVERNOR=powersave` looks wrong but is correct. With `intel_pstate` in
> **active** mode, `powersave` is the full-range HWP governor — the CPU still reaches
> 4.4 GHz. The `performance` governor merely pins it to maximum frequency and wastes
> power. Frequency behaviour is controlled by `CPU_ENERGY_PERF_POLICY` (the HWP EPP
> hint), which is why that is the knob set above.

### Battery longevity

The kernel exposes native charge thresholds on this machine:

```bash
cat /sys/class/power_supply/BAT0/charge_control_start_threshold
cat /sys/class/power_supply/BAT0/charge_control_end_threshold
```

TLP sets these via the config above. For a laptop that lives on AC — which this one
must, given the current battery — capping charge at **80%** dramatically slows
calendar ageing. Lithium cells degrade fastest when held at 100%.

Manual alternative without TLP:
```bash
echo 75 | sudo tee /sys/class/power_supply/BAT0/charge_control_start_threshold
echo 80 | sudo tee /sys/class/power_supply/BAT0/charge_control_end_threshold
```
(not persistent across reboot — use TLP or a systemd unit)

> ⚠️ **Apply thresholds to the replacement battery, not the current one.** On a cell
> at 23.6% health, capping to 80% leaves ~11.7 Wh usable — under an hour. There is
> nothing left to preserve on the existing battery.

### Verify power draw

```bash
sudo apt install powertop
sudo powertop --calibrate     # takes several minutes, on battery
sudo powertop
```

The **Tunables** tab lists remaining opportunities. Do **not** run
`powertop --auto-tune` at boot alongside TLP — they conflict. Use powertop for
*measurement*, TLP for *policy*.

---

## 4. Graphics — Iris Xe

### Hardware video acceleration

The Iris Xe decodes H.264, HEVC, VP9 and AV1 in hardware. Without VA-API configured,
video decodes on the CPU — a large, needless battery drain.

```bash
sudo apt install intel-media-va-driver-non-free vainfo
vainfo
```

`intel-media-va-driver-non-free` is the correct package for Tiger Lake (the `-free`
variant lacks several codec profiles). Despite the name it is redistributable
firmware, not a proprietary kernel driver.

Expect `VAProfileHEVCMain`, `VAProfileVP9Profile0`, `VAProfileAV1Profile0` in the
output.

Enable it in Firefox (`about:config`):
```
media.ffmpeg.vaapi.enabled     = true
media.hardware-video-decoding.force-enabled = true
```
Confirm via `about:support` → *Media* → decoder should report hardware.

### Keep `i915`, not `xe`

Kernel 6.14 includes the newer `xe` driver, and it will load on Tiger Lake if forced.
**Do not.** `i915` is the mature, fully-validated path for Gen12 / Tiger Lake; `xe`
targets Lunar Lake and later. There is no benefit and real regression risk.

### Panel self-refresh

Tiger Lake supports PSR, a genuine idle power saving. Mint 22.3's kernel enables it
by default. Only if you observe flickering:

```bash
# /etc/default/grub → GRUB_CMDLINE_LINUX_DEFAULT="... i915.enable_psr=0"
sudo update-grub
```

---

## 5. Wi-Fi stability

The AX201 under `iwlwifi` can show latency spikes or dropouts with aggressive power
saving on some access points. If you see them:

```bash
# Diagnose
iw dev wlp0s20f3 get power_save

# Persistent fix
echo 'options iwlwifi power_save=0' | sudo tee /etc/modprobe.d/iwlwifi.conf
echo 'options iwlmvm power_scheme=1' | sudo tee -a /etc/modprobe.d/iwlwifi.conf
sudo update-initramfs -u
sudo reboot
```

`power_scheme=1` is "always active". This costs battery — apply it only if you
actually experience the problem. The TLP config above already disables Wi-Fi power
save on AC, which resolves most cases without a battery penalty.

Also disable NetworkManager's MAC randomisation if it interferes with enterprise
networks or DHCP reservations:
```ini
# /etc/NetworkManager/conf.d/wifi-no-random-mac.conf
[device]
wifi.scan-rand-mac-address=no
```

---

## 6. Audio

The 7420's speaker and DMIC array behave better under **SOF** than legacy HDA.
The audit found `snd_hda_intel` in use with SOF modules loaded but inactive.

If microphone or speaker problems appear:

```bash
sudo apt install firmware-sof-signed
echo 'options snd-intel-dspcfg dsp_driver=3' | sudo tee /etc/modprobe.d/sof.conf
sudo reboot
```
`dsp_driver=3` forces SOF. Revert with `dsp_driver=1` (legacy HDA) if it regresses.

Verify: `aplay -l` and `dmesg | grep -i sof`.

If audio is already working correctly, **change nothing** — this is a fix, not an
improvement.

---

## 7. zram — reduce SSD writes

With 16 GB RAM and a drive at 9% endurance, compressed RAM swap absorbs pressure
without touching the SSD:

```bash
sudo apt install zram-tools
```

```bash
# /etc/default/zramswap
ALGO=zstd
PERCENT=25
PRIORITY=100
```

```bash
sudo systemctl restart zramswap
swapon --show
```

zram gets priority 100 (higher than the disk swap partition's default -2), so the
kernel fills compressed RAM first and only spills to the LVM swap volume under real
pressure.

> **Keep the 20 GiB disk swap volume.** zram cannot hold a hibernation image —
> hibernation requires real disk swap. Both coexist correctly.

---

## 8. Firmware updates

`fwupd` is installed and the machine is fully supported by the LVFS:

```bash
sudo fwupdmgr refresh --force
sudo fwupdmgr get-updates
sudo fwupdmgr update
```

`fwupd` detected these updatable devices: **System Firmware (BIOS)**, the **KIOXIA
NVMe SSD**, the **Intel CPU microcode**, plus Thunderbolt and the ME.

⚠️ **Requirements before updating firmware:**
- **AC power connected** — `fwupd` enforces this, and on this battery it matters.
- **Secure Boot state affects TPM-bound LUKS.** A BIOS update changes PCR 0 and will
  invalidate a TPM auto-unlock enrolment. Have your LUKS passphrase available, then
  re-enrol afterwards.

BIOS 1.50.1 (2026-04-23) is current — no BIOS update is expected to be pending.

---

## 9. Thermal management

Idle thermals are healthy (44 °C package, fan at 0 RPM). The `dell_smm` interface
works, so fan and temperature data are readable.

```bash
sudo apt install lm-sensors
sudo sensors-detect --auto
watch -n2 sensors
```

For Tiger Lake, install Intel's thermal daemon — it uses the platform's DPTF tables
for better sustained performance than the kernel's generic fallback:

```bash
sudo apt install thermald
sudo systemctl enable --now thermald
```

`thermald` is specifically beneficial on Tiger Lake ultrabooks: it prevents the
aggressive thermal cliff that otherwise occurs under sustained multi-core load in a
thin chassis.

Monitor NVMe temperature under load — the drive's warning threshold is 83 °C:
```bash
sudo smartctl -a /dev/nvme0n1 | grep -i temperature
```

---

## 10. Filesystem and system hygiene

### Timeshift

Mint's flagship recovery tool. Configure it immediately after install:

> Menu → **Timeshift** → **RSYNC** mode → target `/home` volume or external media

⚠️ **Do not place Timeshift snapshots on the same LVM volume as `/`** — a full root
filesystem then breaks both the system *and* its backups. Target `lv_home`, or better,
external media.

### Journald size cap

Prevents unbounded log growth writing to the SSD:
```bash
sudo sed -i 's/^#SystemMaxUse=.*/SystemMaxUse=200M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
```

### Trim the boot set

Old kernels accumulate in `/boot`. With `/boot` on the root LV this is not urgent,
but keep it tidy:
```bash
sudo apt autoremove --purge
```

---

## 11. What *not* to do

Common advice that is wrong for this specific machine:

| Don't | Why |
|---|---|
| Set the `performance` governor | With `intel_pstate` active + HWP, `powersave` already reaches 4.4 GHz. `performance` only wastes power. |
| Add `discard` to `/etc/fstab` | Continuous TRIM causes latency spikes on a DRAM-less controller. Use `fstrim.timer`. |
| Run `powertop --auto-tune` at boot | Conflicts with TLP; can suspend input devices. |
| Install both TLP and `power-profiles-daemon` | They fight over the same sysfs knobs. |
| Switch to the `xe` GPU driver | `i915` is the validated path for Tiger Lake. |
| Set `vm.swappiness=0` | Triggers the OOM killer instead of swapping. Use 10. |
| Disable the NVMe deep power states | They are the largest single idle battery saving available. |
| Expect tuning to fix the battery | 23.6% health is a hardware condition. Replace the cell. |

---

## Verification

After applying everything:

```bash
# Mitigations
grep . /sys/devices/system/cpu/vulnerabilities/*

# Power policy
sudo tlp-stat -s -b -p

# TRIM active
systemctl status fstrim.timer && lsblk --discard

# Swap topology (zram first, disk swap second)
swapon --show

# Video acceleration
vainfo 2>&1 | grep -E 'VAProfile(H264|HEVC|VP9|AV1)'

# Thermals
sensors

# SSD health
sudo smartctl -a /dev/nvme0n1 | grep -E 'Percentage|Available Spare|Media and Data'
```
