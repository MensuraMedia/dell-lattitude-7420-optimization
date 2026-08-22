# 01 — Hardware Inventory

Captured from a Linux Mint 22.3 live session on 2026-08-14, kernel 6.14.0-37-generic.
Serial numbers and the Dell service tag are redacted.

---

## 1. System identity

| Field | Value | Source |
|---|---|---|
| Vendor | Dell Inc. | `/sys/class/dmi/id/sys_vendor` |
| Product | Latitude 7420 | `/sys/class/dmi/id/product_name` |
| BIOS version | **1.50.1** | `/sys/class/dmi/id/bios_version` |
| BIOS date | 2026-04-23 | `/sys/class/dmi/id/bios_date` |
| Service tag | `[REDACTED]` | `/sys/class/dmi/id/product_serial` |
| Firmware mode | **UEFI** (`/sys/firmware/efi` present) | kernel |
| Secure Boot | **Disabled** | `mokutil --sb-state` |

The Latitude 7420 is a 14" Tiger Lake business ultrabook. It exists in both a
clamshell and a 2-in-1 variant; both share this platform ID.

### BIOS currency

BIOS 1.50.1 dated 2026-04-23 is current. `fwupd` reports System Firmware version
`78337` with `Update State: Success`, meaning the last firmware update applied cleanly.

---

## 2. CPU

| Field | Value |
|---|---|
| Model | Intel Core i5-1145G7 @ 2.60 GHz |
| Codename | Tiger Lake-UP3 (family 6, model 140, stepping 1) |
| Topology | 1 socket / 4 cores / 8 threads |
| Frequency range | 400 MHz – 4400 MHz |
| L1d / L1i | 192 KiB / 128 KiB (4 instances each) |
| L2 | 5 MiB (4 instances) |
| L3 | 8 MiB (shared) |
| Virtualization | VT-x, EPT, VPID — **enabled in firmware** |
| Scaling driver | `intel_pstate` (**active** mode) |
| Governor at capture | `powersave` |
| Energy pref (EPP) | `balance_performance` |

### Notable instruction set support

Full **AVX-512** (`f`, `dq`, `bw`, `vl`, `ifma`, `vbmi`, `vbmi2`, `vnni`, `bitalg`,
`vpopcntdq`, `vp2intersect`), plus `sha_ni`, `vaes`, `gfni`, `vpclmulqdq`.
`intel_pt` (Processor Trace) is present. `rdt_a` (Resource Director Technology) is
available for cache allocation.

This is a vPro-class part — hardware AES and SHA acceleration make full-disk
encryption (LUKS) essentially free in CPU terms. **There is no performance argument
against encrypting the Linux install on this machine.**

### Security mitigation status

| Vulnerability | Status |
|---|---|
| Gather Data Sampling | ⚠️ **Vulnerable** |
| Indirect Target Selection | Mitigated (aligned branch/return thunks) |
| Spectre v1 | Mitigated (usercopy/swapgs barriers) |
| Spectre v2 | Mitigated (Enhanced IBRS, PBRSB-eIBRS, BHI SW loop) |
| Spec Store Bypass | Mitigated (disabled via prctl) |
| Meltdown, MDS, L1TF, Retbleed, MMIO stale data, Itlb multihit | Not affected |

**Gather Data Sampling (GDS / "Downfall", CVE-2022-40982) shows as vulnerable.**
The mitigation for this is delivered by **CPU microcode**, not the kernel. On a live
USB the running microcode is whatever the BIOS loaded. Verify after installation:

```bash
grep . /sys/devices/system/cpu/vulnerabilities/gather_data_sampling
sudo apt install intel-microcode      # then reboot and re-check
```

If it still reports vulnerable after `intel-microcode` is installed and the BIOS is
current, the mitigation is present but reporting requires the newer microcode
revision — check `/proc/cpuinfo` microcode field against Intel's advisory.

---

## 3. Memory

| Field | Value |
|---|---|
| Total | 16 GB (15 GiB usable / reported) |
| Type | LPDDR4x, **soldered to the mainboard** |
| Swap at capture | **None configured** (live session) |

The 7420 has no SO-DIMM slots. 16 GB is the permanent ceiling for this unit.
This directly informs the swap sizing decision — see
[03 — Partitioning Plan](03-partitioning-plan.md#swap-sizing).

---

## 4. Storage

| Field | Value |
|---|---|
| Device | `/dev/nvme0n1` |
| Model | KIOXIA KBG40ZNS512G NVMe |
| Controller | KIOXIA BG4 (`1e0f:0001`) — **DRAM-less** |
| Capacity | 512,110,190,592 bytes (476.9 GiB) |
| Interface | PCIe, NVMe 1.3 |
| Endpoint link | PCIe **3.0** x4 (`LnkCap 8GT/s`) — the drive's own ceiling |
| **Slot link** | **PCIe 4.0 x4** (`LnkCap 16GT/s`, root port `00:06.0`, CPU-attached) |
| Firmware | 10410106 |
| Serial | `[REDACTED]` |
| Formatted LBA | **512 bytes** (format 0, `Rel_Perf 3`) |
| Alternative LBA | 4096 bytes (format 1, `Rel_Perf 1` — better) |
| Driver | `nvme` |

### The DRAM-less caveat

The BG4 is a **DRAM-less** controller. It has no onboard DRAM cache and relies on
Host Memory Buffer (HMB) — a slice of system RAM — for its mapping tables. Practical
consequences:

- Sustained random-write performance is well below a DRAM-equipped drive.
- Performance degrades noticeably as the drive fills. **Keeping 15–20% free is not
  optional on this drive** — it is the difference between fast and sluggish.
- This is a strong argument for generous free space in the partitioning plan and for
  enabling periodic TRIM.

> **The slot is faster than the drive.** The link negotiates 8GT/s only because the
> BG4 is a Gen3 part — the root port advertises **16GT/s (PCIe 4.0) x4**. A Gen4
> replacement would run at Gen4. Read the *root port's* `LnkCap`, not the endpoint's,
> when judging a slot:
> ```bash
> sudo lspci -vv -s 00:06.0 | grep -E "LnkCap:|LnkSta:"
> ```
> Replacing this drive is the highest-value hardware change available on a machine
> whose RAM is soldered and whose battery is at 23.6% health. Procedure, drive
> selection criteria and the form-factor caveat:
> **[22 — Drive Migration & M.2 Options](22-drive-migration.md)**.

### Health (SMART, NVMe log 0x02)

| Metric | Value | Reading |
|---|---|---|
| Overall self-assessment | **PASSED** | ✅ |
| Critical warning flags | `0x00` | ✅ none |
| Percentage used (endurance) | **9%** | ✅ ~91% write life remaining |
| Available spare | 100% (threshold 50%) | ✅ |
| Media and data integrity errors | **0** | ✅ |
| Data units read | 28.0 TB | normal |
| Data units written | 27.9 TB | normal for 8.5k hours |
| Power-on hours | 8,490 (~354 days) | |
| Power cycles | 423 | |
| **Unsafe shutdowns** | **26** | ⚠️ see below |
| Error information log entries | 109 | ⚠️ see below |
| Composite temperature | 34 °C idle | ✅ |
| Warning / critical temp | 83 °C / 87 °C | |

**The drive itself is in good shape** — zero integrity errors across 28 TB written is
a clean record, and 9% endurance used after ~1 year of power-on time projects to a
long remaining life.

**But 26 unsafe shutdowns and 109 error-log entries deserve attention.** Unsafe
shutdowns are power losses without a proper flush — forced power-offs, battery
cutouts, or crashes. Given the battery is at 23.6% health (below), sudden power loss
under load is a plausible cause. This is also the most likely origin of the NTFS
corruption documented in [02 — Storage Analysis](02-storage-analysis.md).

### Power states

| State | Max power | Entry latency | Exit latency | Operational |
|---|---|---|---|---|
| 0 | 3.50 W | 1 µs | 1 µs | yes |
| 1 | 2.60 W | 1 µs | 1 µs | yes |
| 2 | 2.20 W | 1 µs | 1 µs | yes |
| 3 | 0.0500 W | 800 µs | 1200 µs | no |
| 4 | 0.0050 W | 3000 µs | 32000 µs | no |

Autonomous Power State Transition (`apsta = 0x1`) is **supported**, so the drive can
manage its own low-power states. Volatile write cache (`vwc = 0x1`) is present.
The deep states (3 and 4) give real idle battery savings and are safe to enable via
ASPM — see [05 — Post-Install Optimization](05-post-install-optimization.md).

---

## 5. Graphics

| Field | Value |
|---|---|
| Device | Intel TigerLake-LP GT2 [Iris Xe Graphics] (`8086:9a49`) |
| Subsystem | Dell (`1028:0a36`) |
| Driver in use | `i915` |
| Alternative driver | `xe` (available in kernel 6.14) |

Iris Xe on Tiger Lake is mature, fully open-source, and needs no configuration.
It supports hardware video acceleration (VA-API) for H.264, HEVC, VP9 and AV1
**decode**. The `xe` driver exists in this kernel but `i915` remains the correct,
stable choice for Tiger Lake — do not switch.

---

## 6. Networking

| Field | Value |
|---|---|
| Device | Intel Wi-Fi 6 AX201 (`8086:a0f0`, rev 20) |
| Driver | `iwlwifi` |
| Interface | `wlp0s20f3` |
| State at capture | UP, IPv4 assigned, DNS via systemd-resolved stub |
| Wired | Intel Ethernet controller present (`00:1f.6`) — no built-in RJ45 port; requires dock/dongle |

The AX201 is a CNVi part — the MAC is in the chipset and only the radio is on the
M.2 module, which means **it cannot be replaced with a non-Intel card**. `iwlwifi`
support is solid. Bluetooth is provided by the same module over USB.

A known `iwlwifi` behaviour to be aware of: aggressive power saving can cause
latency spikes or dropouts on some APs. Mitigation is documented in
[05 — Post-Install Optimization](05-post-install-optimization.md#wi-fi-stability).

---

## 7. Audio

| Field | Value |
|---|---|
| Controller | Intel Tiger Lake-LP Smart Sound Technology (`8086:a0c8`) |
| Driver in use | `snd_hda_intel` |
| Available alternatives | `snd_sof_pci_intel_tgl` (SOF), `snd_soc_avs` |
| SOF modules loaded | yes (`snd_sof_intel_hda_common`, `soundwire_intel`, et al.) |

Both the legacy HDA path and the modern **SOF (Sound Open Firmware)** path are
available. The 7420's speaker array and DMIC array generally behave better under
SOF. If microphone or speaker issues appear post-install, switching to the SOF
driver is the first remedy — see
[05 — Post-Install Optimization](05-post-install-optimization.md#audio).

---

## 8. Security hardware

| Field | Value |
|---|---|
| TPM | **TPM 2.0**, present and active (`/dev/tpm0`, `/dev/tpmrm0`) |
| Secure Boot | **Disabled** |
| CPU security features | Intel SGX-capable platform, `user_shstk` (shadow stack), `ibt` (indirect branch tracking), Intel Boot Guard |

The presence of an active TPM 2.0 means **LUKS auto-unlock via TPM is possible** on
this machine (`systemd-cryptenroll --tpm2-device=auto`), giving full-disk encryption
without typing a passphrase at every boot. This is the recommended configuration for
a portable business laptop and is covered in
[03 — Partitioning Plan](03-partitioning-plan.md).

---

## 9. Power and thermal

### Battery — ⚠️ critical finding

| Field | Value |
|---|---|
| Vendor / model | SMP / DELL TN2GY15 |
| Technology | Lithium-polymer |
| **Design capacity** | **61.8944 Wh** |
| **Current full capacity** | **14.6376 Wh** |
| **Health** | **23.65%** |
| State at capture | Fully charged, on AC |
| Voltage | 15.603 V |
| Reported cycle count | 0 (not exposed by this firmware/EC) |

**The battery has lost over 76% of its original capacity.** A 61.9 Wh design battery
now holds 14.6 Wh — roughly 1–1.5 hours of real-world runtime instead of 8–10.

This is a **hardware** end-of-life condition. No amount of TLP, powertop, or kernel
tuning will meaningfully change it; power tuning multiplies runtime by a percentage,
and 20% more of 1.2 hours is still about 1.4 hours. **The correct fix is a
replacement battery** (Dell part family for the 7420 4-cell 63 Wh: `TN2GY` / `WY9DX`
/ `M42XW`, depending on revision — verify against the service tag before ordering).

It is also very likely the cause of the **26 unsafe shutdowns** on the SSD: a battery
this degraded can sag below cutoff under sudden load even when the gauge reads a
healthy percentage, dropping the machine instantly.

**Charge threshold control is available.** The kernel exposes:
```
/sys/class/power_supply/BAT0/charge_control_start_threshold
/sys/class/power_supply/BAT0/charge_control_end_threshold
```
On a replacement battery, capping charge at 80% will substantially extend its
service life. Configuration is in
[05 — Post-Install Optimization](05-post-install-optimization.md#battery-longevity).

### Thermals at idle

| Sensor | Reading |
|---|---|
| CPU package | 44 °C (high/crit: 100 °C) |
| Cores 0–3 | 41–44 °C |
| NVMe composite | 33.9 °C (high 82.8 °C, crit 86.8 °C) |
| Wi-Fi (`iwlwifi`) | 38 °C |
| Dell SMM zones | 32–44 °C |
| **Fan** | **0 RPM** (max 4800 RPM) |

Idle thermals are healthy and the fan is fully stopped — normal and correct for this
chassis at idle. The `dell_smm` interface is working, which means fan speed and
temperatures are readable, and tools like `i8kutils` can query them.

USB-C PD is negotiated at **15 V / 3 A (45 W)**.

> ⚠️ Note: 45 W is below the Latitude 7420's rated **65 W** adapter. If this is the
> charger in use, the machine will charge slowly and may throttle under combined
> CPU+GPU load while charging. Confirm the adapter rating; a 65 W USB-C PD supply is
> the correct part.

---

## 10. Summary of driver support

| Component | Driver | Status |
|---|---|---|
| CPU / power management | `intel_pstate` | ✅ native, active mode |
| GPU | `i915` | ✅ native |
| NVMe SSD | `nvme` | ✅ native |
| Wi-Fi | `iwlwifi` | ✅ native |
| Audio | `snd_hda_intel` / SOF | ✅ native |
| TPM | `tpm_crb` | ✅ native |
| Thermal / fan | `dell_smm`, `INT3400` | ✅ native |
| Thunderbolt 4 | `thunderbolt` | ✅ native |

**No proprietary drivers are required.** Mint 22.3 with kernel 6.14 supports every
component of this machine out of the box.
