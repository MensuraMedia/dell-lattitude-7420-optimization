# 20 — Fan & Cooling Hardware

Fan identification, measured capability, health assessment, replaceability, and
the full set of logical and physical cooling options for the Latitude 7420.

> **Mechanism:** [16 — Thermal & Power Architecture](16-thermal-and-power-architecture.md)
> **Measurements & config:** [17 — Cooling Optimization](17-cooling-optimization.md)
> **Runbook:** [19 — Gaming & Cooling Runbook](19-gaming-cooling-runbook.md)

Captured **2026-08-15**. BIOS 1.50.1, kernel 7.0.0-28-generic.

---

## 1. Hardware identification

| Property | Value | Source |
|---|---|---|
| Cooling devices | **1** (single fan) | `hwmon`, DMI type 27 |
| Description | **Processor Fan** | DMI type 27 |
| **Nominal speed** | **4800 rpm** | **DMI type 27 — Dell's own spec** |
| Status | OK | DMI type 27 |
| Driver | `dell_smm_hwmon` → `dell_smm-virtual-0` | sysfs |
| Sensor node | `fan1_input` / `fan1_max` / `fan1_min` | `/sys/class/hwmon/hwmon*/` |
| System board P/N | **0KND83** rev A00 | DMI type 2 |
| System SKU | 0A36 | DMI type 1 |
| Temperature probes | CPU, SKIN, DIMM | DMI type 28 |

> ⚠️ **The hwmon index is not stable across boots.** Observed moving `hwmon6` →
> `hwmon5` after a reboot. Always resolve by name:
> ```bash
> for h in /sys/class/hwmon/hwmon*; do
>   [ "$(cat $h/name)" = dell_smm ] && echo "$h"
> done
> ```

There is **one** fan. Some 7420 configurations are marketed as dual-heatpipe, but
this chassis exposes a single cooling device with a single tachometer.

---

## 2. Measured capability

### 2.1 Speed range by ACPI platform profile

8-thread `sha256sum /dev/zero` burn, turbostat parsed **by column name**.

| Profile | BIOS token | Idle RPM | Load RPM | Pkg W | Pkg °C | NVMe °C |
|---|---|---|---|---|---|---|
| `quiet` | Quiet | 2753–3513 | 4024 | 11.18 | 55 | 37.9 |
| `cool` | Cool | 4292 | 4288 | **7.96** | 47 | 36.9 |
| `balanced` | Optimized | 4292 | 4306 | 14.35 | 62 | 39.9 |
| **`performance`** | **UltraPerformance** | **4714** | **4697** | 13.44 | 61 | 40.9 |

**`performance` is the maximum-airflow setting available.** It is also the only
profile that raises idle RPM above the ~4292 plateau.

> **`cool` is a power-limiting profile, not a cooling profile.** It reaches 47 °C
> by cutting package power to 7.96 W — 41% below `performance`. During gameplay
> that starved the iGPU: `throttle_reason_pl1` was asserted in **13 of 20 samples**
> while the GPU requested 1300 MHz and delivered 0–650 MHz.

### 2.2 Maximum speed test

Sustained 180 s full load on `performance`:

```
sample @20s   4714 RPM   58 °C
sample @60s   4692 RPM   61 °C
sample @100s  4720 RPM   61 °C
sample @140s  4703 RPM   62 °C
sample @180s  4703 RPM   61 °C

PEAK OBSERVED  4731 RPM
DMI NOMINAL    4800 rpm
             = 98.6% of manufacturer spec
```

---

## 3. Fan health assessment

### 3.1 Method

Four independent tests. Reproduce with `scripts/aggressive-cooling.sh` or the
standalone health script.

| # | Test | What it detects | Healthy |
|---|---|---|---|
| 1 | **Ceiling** | Peak RPM vs DMI nominal | ≥95% |
| 2 | **Stability** | RPM variance at max — bearing wear, obstruction | <2% |
| 3 | **Ramp** | Time from low idle to 95% under sudden load | see caveat |
| 4 | **Effectiveness** | °C per watt — fin-stack dust, paste condition | <75 °C at load |

### 3.2 Results — 2026-08-15

```
[PASS] ceiling       4731 RPM = 98.6% of 4800 nominal
[PASS] stability     std dev 11.3 RPM = 0.24% of mean
                     min/max 4686 / 4731 — 45 RPM spread over 45 samples
[----] ramp          23s from 2753 RPM to 95% of max
[PASS] effectiveness 60 °C at 13.44 W sustained
                     thermal resistance ~2.60 °C/W
```

**Verdict: the fan is mechanically healthy. No replacement indicated.**

- **98.6% of spec.** A fan with worn bearings, a dust-loaded impeller, or a
  failing motor cannot reach nominal. This one essentially does.
- **0.24% variance is the decisive number.** Bearing wear manifests as speed
  hunting — several percent variance and a wide min/max spread. 45 RPM of spread
  at 4700 RPM is a mechanically sound motor.
- **Effectiveness rules out the heatsink.** A choked fin stack or pumped-out paste
  produces the classic *good RPM, bad temperature* signature. Not present.

> **On the ramp figure:** the 23 s measurement spans a `quiet`→`performance`
> profile switch, so it captures **EC ramp policy plus motor inertia**, not motor
> response alone. There is no published Dell spec for this transition. Treat it as
> a baseline to compare against later, not a pass/fail.

### 3.3 Interpreting future results

| Ceiling | Stability | Effectiveness | Diagnosis |
|---|---|---|---|
| ≥95% | <2% | Good | Healthy — no action |
| ≥95% | <2% | **Poor** | **Fin stack dust or dried paste** — clean/repaste, not a fan fault |
| **<90%** | **>3%** | Poor | **Bearing wear / obstruction** — replace the fan |
| <90% | <2% | Good | EC policy limiting, or wrong profile — check `platform_profile` first |
| Erratic | Very high | Varies | Failing tachometer or intermittent connector seating |

---

## 4. Airflow architecture

```
                    LATITUDE 7420 — THERMAL PATH (single fan, rear-left exhaust)

     ┌────────────────────────────────────────────────────────────────┐
     │  DISPLAY (eDP)                                                 │
     ├────────────────────────────────────────────────────────────────┤
     │                        K E Y B O A R D                         │
     │  ← TSKN probe sits under here: 60 °C trip is a COMFORT limit,  │
     │    not a component limit. The EC will spin the fan to protect  │
     │    skin temperature even when silicon is cool.                 │
     ├────────────────────────────────────────────────────────────────┤
     │                                                                │
     │   [BATTERY]              ┌──────────┐                          │
     │   23.6% health           │ i5-1145G7│  ← die: CPU + Iris Xe    │
     │   heat-sensitive         │  + iGPU  │    ONE package, ONE      │
     │   (see F-01)             └────┬─────┘    shared power budget   │
     │                               │                                │
     │                          ╔════╧════╗                           │
     │                          ║  VAPOR  ║  heat spreader / heatpipe │
     │                          ║ CHAMBER ║  (no telemetry)           │
     │                          ╚════╤════╝                           │
     │   [NVMe BG4]                  │                                │
     │   DRAM-less                ┌──┴───┐                            │
     │   82.8 °C limit            │ FIN  │ ← dust accumulates HERE    │
     │   NO throttle telemetry    │ STACK│   first, and invisibly     │
     │                            └──┬───┘                            │
     │   [DRAM soldered]             │                                │
     │   TMEM 60 °C trip        ┌────┴────┐                           │
     │                          │  FAN 1  │ 0–4800 rpm, EC-controlled │
     │                          │ blower  │ pwm1 writes IGNORED       │
     │                          └────┬────┘                           │
     └───────────────────────────────┼────────────────────────────────┘
                                     ↓
                            EXHAUST (rear-left hinge)

     INTAKE: bottom panel vents ── obstruct these and everything above degrades
```

**Consequences of this layout:**

- CPU and iGPU share **one die, one heatsink, one power budget**. Cooling them is
  not separable, and neither is starving them.
- The **NVMe, DRAM, VRM and battery** sit in the same thermal envelope with **no
  throttle telemetry**. The CPU throttle counters being `0` says nothing about
  their condition — which is the entire case for maximising airflow.
- **Intake is on the bottom panel.** Soft surfaces are the single most common
  cause of thermal degradation on this chassis and cost nothing to avoid.

---

## 5. Replaceability

### 5.1 Difficulty

| Aspect | Rating | Note |
|---|---|---|
| Access | ★★☆☆☆ Easy | Single bottom panel, captive Phillips screws |
| Fan removal | ★★☆☆☆ Easy | 2–3 screws + one ZIF connector |
| Repaste (requires heatsink removal) | ★★★☆☆ Moderate | Spring screws in a numbered sequence |
| Risk | Low–moderate | Battery must be disconnected first |
| Time | 20–40 min | Longer with a repaste |

### 5.2 Sourcing

Dell publishes exact parts per machine. **Look them up by service tag rather than
trusting any number quoted here:**

- Dell Parts lookup, service tag **`GV48XD3`** → *Parts & Accessories*
- *Latitude 7420 Service Manual* → **Removing the system fan** / **Removing the heat sink**
- System board P/N **0KND83** rev A00 (from DMI) confirms the board revision when
  cross-checking fan compatibility

> ⚠️ **Do not order from a generic "7420 fan" listing.** The 7420 shipped in
> clamshell and 2-in-1 variants with different thermal assemblies, and UMA vs
> discrete configurations differ. Verify against the service tag.

Recommended spares to hold if you plan on long service life:
1. System fan assembly (the wear part — bearings are consumable)
2. Thermal paste (a quality non-conductive compound)
3. Bottom-panel gasket/foam if disturbed during service

### 5.3 When to actually replace

Given this fan tests at 98.6% of nominal with 0.24% variance, **replacement now
would be premature**. Re-run the health assessment:

- Every 6–12 months
- After any audible change (ticking, grinding, whine)
- If temperatures rise at equal load and RPM
- If ceiling drops below ~90% of nominal, or variance exceeds ~3%

---

## 6. Logical (software) cooling options

Everything achievable without opening the machine. Verified on this system.

| # | Option | Effect | Status |
|---|---|---|---|
| 1 | `platform_profile=performance` | **Max airflow** — 4697 RPM sustained vs 4292 | ✅ Available |
| 2 | Compositor unredirect | Removes a full-screen blit per frame — less GPU work, less heat | ✅ Applied |
| 3 | Frame cap (`fps_limit` in MangoHud) | Directly removes GPU work; strongest heat lever for gaming | ⏳ Available |
| 4 | `thermald` | Active, but running **fallback** — no adaptive DPTF policy loaded | ⚠️ Limited |
| 5 | Reduce background load | Steam idles ~34% CPU; maintenance timers fire mid-session | ⏳ See [19 §11](19-gaming-cooling-runbook.md) |
| 6 | Lower in-game settings | Population caps and AI count drive CPU heat on RTS titles | ⏳ Available |
| 7 | `pwm1` direct fan control | **NOT POSSIBLE** — see below | ❌ Blocked |
| 8 | `i8kutils` | Same SMM path as `dell_smm_hwmon`; fails identically | ❌ Blocked |
| 9 | Undervolting | Tiger Lake mailbox removed post-Plundervolt (CVE-2019-11157) | ❌ Blocked |

### 6.1 Why direct fan control is impossible — recorded with evidence

```
pwm1_enable = 0  → REJECTED (EINVAL)
pwm1_enable = 1  → accepted   (the ONLY accepted value)
pwm1_enable = 2  → REJECTED (EINVAL)
pwm1_enable = 3  → REJECTED (EINVAL)
pwm1 write 255   → before=255, after=255   (silently ignored)
```

The rejection comes from **firmware, not the driver**. The `dell-smm-fan1` cooling
device (`cur_state=2 max_state=2`) is a *readout* of the EC's fan level, not a
command channel — writes to `cur_state` do not take, and no thermal zone binds it.

`platform_profile=performance` is therefore the **maximum fan setting obtainable
in software** on this machine.

---

## 7. Physical cooling options

Ordered by benefit-per-risk.

### 7.1 Do these

| # | Intervention | Benefit | Risk | Note |
|---|---|---|---|---|
| 1 | **Keep bottom intake clear** | High | None | Hard surface only; never fabric or lap |
| 2 | **Elevate the rear ~15–20 mm** | Moderate–high | None | Widens the intake gap; a passive stand suffices |
| 3 | **Fin-stack clean** | High if dusty | Low | Compressed air, **hold the fan blade** — free-spinning generates back-EMF into the motor driver |
| 4 | **Repaste** | High on a 5-year-old unit | Moderate | Factory paste pumps out over years; see §5.1 |
| 5 | **Active cooling pad** | Moderate | None | Only helps if it aligns with the bottom intake |

```
        SIDE VIEW — REAR ELEVATION (free, no disassembly, no risk)

   BEFORE:  ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔        AFTER:      ▁▁▁▁▔▔▔▔▔▔▔▔▔▔▔
            ██████████████████                    ████████████████
            ▲▲▲  intake starved                  ╱  ▲▲▲▲▲  free
   ═════════════════════════════        ═══════╱══════════════════
     desk surface ~2 mm gap               ~15–20 mm gap, laminar intake
```

### 7.2 Consider carefully

| # | Intervention | Benefit | Risk | Verdict |
|---|---|---|---|---|
| 6 | **Thermal pads on NVMe** | Low–moderate | Moderate | NVMe already at 37–41 °C vs 82.8 °C limit — little to gain |
| 7 | **Liquid metal on the die** | Moderate | **High** | Aluminium fin stacks are attacked by gallium; pump-out and short risk. **Not recommended on a laptop you rely on** |
| 8 | **Bottom panel drilling / mesh** | Low | **High** | Breaks EMI shielding and structural rigidity, voids warranty, and the intake is not the bottleneck |
| 9 | **Fan swap for a higher-RPM unit** | Low | High | The EC drives the tach loop; a non-OEM fan may be misread or fault. And this fan is already at 98.6% of spec |

### 7.3 Do not

- **Blocking the exhaust** to "keep heat in" — self-evident, but the rear hinge
  vent is easily obstructed by a raised desk lip or a cable run.
- **Removing the bottom panel for "better airflow."** The chassis is designed for
  directed flow across the fin stack; an open panel destroys that path and
  short-circuits the intake.

---

## 8. What the evidence actually supports

For this specific machine, on 2026-08-15:

1. **The fan is healthy** — 98.6% of nominal, 0.24% variance. Not the problem.
2. **`performance` is the max-airflow profile** and delivers ~400 RPM more than
   any other, at both idle and load.
3. **`cool` should not be mistaken for a cooling profile.** It cuts power 41% and
   demonstrably starves the iGPU.
4. **Software fan control is impossible.** Firmware-blocked, recorded with evidence.
5. **The highest-value physical action is a repaste plus fin clean** on a chassis
   this age, followed by rear elevation, which is free.
6. **The battery at 23.6% health remains the dominant hardware risk** — see
   [F-01](07-findings-and-risks.md#f-01). It is a heat source, a heat *victim*,
   and the documented cause of prior unsafe shutdowns.

---

## 9. Reproducing these measurements

```bash
# full thermal report
./scripts/aggressive-cooling.sh status

# prove max airflow is genuinely active
./scripts/aggressive-cooling.sh verify

# continuous watchdog with excursion logging
./scripts/aggressive-cooling.sh monitor

# apply / remove the max-airflow profile
./scripts/aggressive-cooling.sh on
./scripts/aggressive-cooling.sh off
```

Fan health assessment (ceiling, stability, ramp, effectiveness) — re-run every
6–12 months and compare against §3.2.
