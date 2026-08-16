# 16 — Thermal & Power Architecture

How power and heat are actually governed on this machine: which limit binds, who
owns the fan, what `platform_profile` really writes, and why the obvious
measurements mislead.

> This is the **concept** document — mechanism and reasoning.
> For measured numbers, applied configuration and procedures, see
> **[17 — Cooling Optimization](17-cooling-optimization.md)**.
> For the review that corrected an earlier version of this model, see
> **[18 — Adversarial Review Log](18-adversarial-review-log.md)**.

Captured on **2026-08-15**, BIOS **1.50.1** (2026-04-23), kernel **7.0.0-28-generic**,
Linux Mint 22.3 Cinnamon, X11.

---

## 1. There are two RAPL interfaces, and the one Linux shows you first is the wrong one

Intel exposes package power limits through **two independent paths**. Both are
visible in sysfs, they disagree, and **the lower one wins**.

| Interface | sysfs path | long_term | short_term |
|---|---|---|---|
| **MSR** (`MSR_PKG_POWER_LIMIT`, 0x610) | `/sys/class/powercap/intel-rapl:0` | **200 W** | 60 W |
| **MMIO** (MCHBAR) | `/sys/class/powercap/intel-rapl-mmio:0` | **30 W** (max 28 W) | **18.75 W** |

Reading `MSR 0x610` gives `0x004381e0001f8640`, which decodes to PL1 = 200 W with
the **lock bit clear**. Taken alone this suggests the CPU is unconstrained and that
a user could raise the limit freely.

That reading is a trap. The platform's real ceiling is set in **MMIO RAPL**, which
the firmware programs and which the MSR view does not reflect. Effective limits on
this machine:

```
sustained (PL1)  ≈ 28–30 W
burst    (PL2)   ≈ 18.75 W short-term window
```

**Consequence for tuning:** there is no MSR write that raises the ceiling, because
the MSR is not what is enforcing it. Tools that "unlock" PL1 by writing 0x610 will
appear to succeed and change nothing.

### 1.1 Why "18.7 W" is a misleading number

An early measurement pass on this machine recorded ~18.7 W under an all-core load
and concluded it was *the* sustained cap. It is not — it is the **short-term
(PL2) limit**, 18.75 W, being observed inside its averaging window.

Two facts make this easy to get wrong:

- `constraint_0_time_window_us = 31981568` → **PL1 averages over ~32 seconds.**
  Any sampling window shorter than that, or starting inside it, mixes burst power
  into what looks like a steady-state figure.
- The machine reaches thermal equilibrium slowly, so a 40–80 s test looks stable
  while still settling.

**Rule for this hardware:** soak for **5 minutes**, then sample only the final
**2 minutes**. Anything shorter measures the transient, not the limit.

---

## 2. The machine is power-limited, not thermally limited

This is the single most useful fact about the 7420's thermal behaviour.

| Signal | Value | Meaning |
|---|---|---|
| `core_throttle_count` | **0** | Never thermally throttled |
| `package_throttle_count` | **0** | Never thermally throttled |
| `tcc_offset_degree_celsius` | 2 | Effective trip ≈ **98 °C** |
| Peak observed package temp | **66 °C** | ~32 °C of unused headroom |
| `throttle_reason_thermal` | 0 | Not thermally clamped |

The CPU and iGPU share one package budget, and that budget is exhausted long before
temperature becomes relevant. Under an all-core burn the part settles at 60–66 °C
against a ~98 °C trip.

**Implication:** cooling improvements on this chassis do **not** buy performance —
nothing is being lost to heat. They buy **component longevity**, which is a
different and entirely legitimate goal. Do not expect frames from a fan curve.

---

## 3. Who owns the fan

The fan is controlled by the **embedded controller**. Linux can observe it and
cannot drive it.

```
/sys/class/hwmon/hwmonN/           (name = dell_smm)
  fan1_input     RO   current RPM
  fan1_max       RO   4800
  fan1_target    RO   4800
  pwm1           RW*  reads 255; writes are silently ignored
  pwm1_enable    RW*  accepts ONLY 1; values 0, 2 and 3 are rejected with EINVAL
```

`pwm1_enable` rejecting `2` (automatic) is the **BIOS refusing**, not a driver
limitation. `i8kutils` drives the same SMM path and fails identically. Module
parameters do not help: `force`/`ignore_dmi` only bypass DMI matching, and
`restricted` only gates `CAP_SYS_ADMIN` — neither unlocks EC arbitration.

The `dell-smm-fan1` cooling device (`cur_state=2 max_state=2`) is a **readout** of
the EC's current fan level, not a latched command. Writing `cur_state` does not
take. No thermal zone binds it.

**The only real airflow lever is `platform_profile`.** See §4.

---

## 4. `platform_profile` is a BIOS token, not a runtime setting

Writing `/sys/firmware/acpi/platform_profile` goes through the `dell_pc` driver and
sets a **persistent BIOS NVRAM token**. The same value is visible through the
firmware-attributes interface:

```
/sys/class/firmware-attributes/dell-wmi-sysman/attributes/ThermalManagement/
  current_value    Cool
  default_value    Optimized
  possible_values  Optimized;Cool;Quiet;UltraPerformance;
```

Mapping between the two namespaces:

| `platform_profile` | BIOS `ThermalManagement` | Character |
|---|---|---|
| `cool` | `Cool` | Lower power target, moderate fan |
| `quiet` | `Quiet` | Lower power target, **slower** fan |
| `balanced` | `Optimized` | Firmware default |
| `performance` | `UltraPerformance` | Highest fan speed observed |

**Because it is a BIOS token, it persists across reboot and resume on its own.**
A systemd unit to re-assert it is redundant unless a reboot demonstrates otherwise.

> **Note on `current_value`:** readable only as root. An unprivileged `cat` returns
> empty, which can be mistaken for "unsupported".

### 4.1 The tradeoff `cool` actually makes

`cool` and `quiet` reach similar package power by different means: `cool` keeps the
fan working, `quiet` slows it. For a longevity goal these are **opposite**
choices despite similar wattage — the wattage similarity is a coincidence, not
equivalence.

`cool` also has a cost that is easy to miss: **the fan never stops.** At idle
(load < 0.5, package 37–47 °C) the fan holds ~4300 RPM, roughly 89% of its 4800 RPM
maximum, indefinitely. That is continuous bearing wear and accelerated dust
ingestion — a longevity cost incurred to reduce a thermal stress that measurement
says is not occurring.

---

## 5. What the thermal zones actually measure

| Zone | Meaning | Trip points |
|---|---|---|
| `TCPU` | CPU package proxy | 103–127 °C |
| `TSKN` | **Skin / chassis** — user-contact temperature | 60 °C |
| `TMEM` | Memory area | 60 °C |
| `NGFF` | M.2 / SSD area | 60 °C |
| `x86_pkg_temp` | Package (coretemp) | — |
| `iwlwifi_1` | Wi-Fi module | — |

`TSKN` at 60 °C is a **comfort/safety** trip, not a component-protection trip. The
EC will spin the fan to protect skin temperature even when silicon is cool, which
is part of why fan speed correlates poorly with package temperature on this chassis.

The components with the least thermal headroom reporting are the ones that matter
most for longevity: the **DRAM-less KIOXIA BG4 NVMe** (`temp1_max` 82.85 °C,
`temp1_crit` 86.85 °C) and the battery — neither of which appears in the CPU
throttle path at all.

---

## 6. `thermald` is running in fallback mode

`thermald` is active with `--adaptive`, but:

```
/sys/class/thermal/thermal_zone0/uuids/current_uuid   (empty)
journal: "Unable to find a zone for TSSD"
journal: "sensor id 12 : No temp sysfs for reading raw temp"
```

No adaptive DPTF policy is loaded. It is running generic fallback logic and
contributing little on this platform. It is not harmful; do not expect it to be
doing meaningful work either.

---

## 7. The compositor is part of the thermal system

Not obvious, and easy to miss when reasoning about heat.

On X11 with Cinnamon/muffin, the schema default is:

```
org.cinnamon.muffin unredirect-fullscreen-windows = false
```

With unredirect **off**, a fullscreen game is **composited every frame** — an extra
full-resolution blit on an 80 EU iGPU that shares LPDDR4x bandwidth with the CPU,
plus a hard lock to the compositor's vblank cadence.

That is GPU work, and GPU work is heat drawn from the same package budget. Setting
it `true` reduces both frame latency **and** thermal load, which makes it one of
the few changes that serves performance and longevity simultaneously.

---

## 8. Measurement pitfalls specific to this platform

Recorded because each one produced a wrong conclusion during the 2026-08-15 session.

| Pitfall | Why it misleads | Correct approach |
|---|---|---|
| Sampling < 32 s | PL1 tau is ~32 s; burst is averaged in | 5 min soak, sample last 2 min |
| Reading MSR 0x610 | Not the binding constraint | Read `intel-rapl-mmio:0` |
| `ps -eo pcpu` | Lifetime average, not instantaneous | `top -b -n 2` and use the 2nd sample |
| `gt_act_freq_mhz` | Instantaneous RPSTAT snapshot; reads **0** in RC6 | `GFX%rc6` / `GFX%C0`, or i915 PMU |
| `cur_state` on the fan cdev | A readout, not a control | Accept EC ownership |
| turbostat column position | Column order varies by flags | Parse by **column name** |
| Uncontrolled background load | Steam idles at ~34% CPU | Quiesce, or record load with every sample |

### 8.1 The metric that settles GPU saturation

Never read during the original session, and the one that would have answered it:

```bash
grep . /sys/class/drm/card1/gt/gt0/throttle_reason_*
```

`throttle_reason_pl1`, `pl2`, `pl4`, `vr_tdc` reading `1` during gameplay means the
GPU is genuinely power-clamped. All read `0` at idle on this machine.

Per-process engine utilisation, no extra packages required:

```bash
pid=$(pgrep -f AoEDE_s.exe)
grep -l drm-engine-render /proc/$pid/fdinfo/*
# sample drm-engine-render twice N seconds apart:
#   (Δns / N_ns) × 100 = render engine utilisation %
```

---

## 9. Summary of the corrected model

1. Sustained package power is limited to **~28–30 W** by **MMIO** RAPL; the 60 W
   MSR PL2 and 200 W MSR PL1 are not what binds.
2. Short-term bursts are limited to **18.75 W**, and PL1 averages over **32 s** —
   short tests measure this, not the sustained limit.
3. Nothing on this machine thermally throttles. Both throttle counters are **0**
   with ~32 °C of headroom.
4. The fan is **EC-owned**; `platform_profile` is the only lever, and it writes a
   **persistent BIOS token**.
5. Cooling changes buy **component longevity**, not performance.
6. The largest single consumer of avoidable GPU work was the **compositor**, not
   anything in the power subsystem.

---

## References

- [01 — Hardware Inventory](01-hardware-inventory.md) — component profile, battery health
- [05 — Post-Install Optimization](05-post-install-optimization.md) — TLP, thermal, SSD tuning
- [07 — Findings & Risk Register](07-findings-and-risks.md) — [F-01](07-findings-and-risks.md#f-01) battery at 23.6% health
- [17 — Cooling Optimization](17-cooling-optimization.md) — measurements, applied config, procedures
- [18 — Adversarial Review Log](18-adversarial-review-log.md) — review findings and alternate recommendations
