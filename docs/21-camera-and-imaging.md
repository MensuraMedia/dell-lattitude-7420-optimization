# 21 — Camera & Imaging Subsystem

Full characterisation of the integrated webcam: dual-sensor topology, V4L2 node
mapping, format matrix, control surface, measured throughput, access-control model,
and the Dell privacy hardware path.

> **Related:** [01 — Hardware Inventory](01-hardware-inventory.md) ·
> [05 — Post-Install Optimization](05-post-install-optimization.md) ·
> [07 — Findings & Risks](07-findings-and-risks.md)

Captured **2026-08-16**. BIOS 1.50.1, kernel 7.0.0-28-generic, Linux Mint 22.3.
All measurements taken on the installed system (not a live session).

> **Method note:** functional testing captured two single frames to verify the
> pipeline end to end. Only technical properties were measured (dimensions, pixel
> format, luminance statistics); **no image content was inspected**, and both frames
> were `shred`-deleted immediately. Throughput tests wrote to `/dev/null` and stored
> nothing. One V4L2 control was changed for an A/B test and **restored to its
> as-found value** — see §6.2.

---

## 1. Hardware identification

| Property | Value | Source |
|---|---|---|
| Module | **Integrated_Webcam_FHD** | USB iProduct |
| USB ID | **`1bcf:2ba0`** | Sunplus Innovation Technology Inc. |
| Bus location | `usb-0000:00:14.0-6` (bus 3, port 6) | sysfs |
| USB version | 2.01, full 480 Mb/s | device descriptor |
| Device class | 239 / 2 / 1 — Miscellaneous, **Interface Association** | device descriptor |
| UVC version | **1.50** | VideoControl header |
| Clock frequency | 48.000 MHz | VideoControl header |
| Firmware / iSerial | `01.00.00` | USB iSerial |
| Module serial | `[REDACTED]` | USB iManufacturer |
| Max bus power | 500 mA | configuration descriptor |
| Driver | `uvcvideo` | kernel |

> ⚠️ The USB **iManufacturer** string on this module is not a vendor name — it is a
> unit-unique 20-character serial. It is redacted here per repository policy, and it
> leaks into `/dev/v4l/by-id/` paths. See §11 F-C4.

---

## 2. Topology — this is a dual-sensor camera

The device advertises **4 interfaces grouped into 2 Interface Association
Descriptors**, i.e. two independent UVC functions behind one USB device:

| IAD | Interfaces | Function | Sensor |
|---|---|---|---|
| 1 | 0 (VideoControl) + 1 (VideoStreaming) | Colour imaging | **RGB** |
| 2 | 2 (VideoControl) + 3 (VideoStreaming) | Infrared imaging | **IR (mono)** |

```
usb 3-6  Integrated_Webcam_FHD (1bcf:2ba0)
├── IAD 1  ── if 0 VideoControl ─┬─ if 1 VideoStreaming  → /dev/video0  (RGB   MJPG/YUYV)
│                                └───────────────────────→ /dev/video1  (metadata UVCH)
└── IAD 2  ── if 2 VideoControl ─┬─ if 3 VideoStreaming  → /dev/video2  (IR    GREY)
                                 └───────────────────────→ /dev/video3  (metadata UVCH)
```

Both functions were confirmed present at probe time:

```
uvcvideo 3-6:1.0: Found UVC 1.50 device Integrated_Webcam_FHD (1bcf:2ba0)
uvcvideo 3-6:1.2: Found UVC 1.50 device Integrated_Webcam_FHD (1bcf:2ba0)
```

The IR sensor is the **Windows Hello face-authentication** camera. It is fully
functional under Linux — it is simply unused by default, because nothing in a stock
Mint install consumes an IR stream.

---

## 3. Node mapping and the stable-selector problem

| Node | Function | Type | Formats |
|---|---|---|---|
| `/dev/video0` | RGB | Video Capture | `MJPG`, `YUYV` |
| `/dev/video1` | RGB | **Metadata only** (`UVCH`) | — |
| `/dev/video2` | **IR** | Video Capture | `GREY` |
| `/dev/video3` | IR | **Metadata only** (`UVCH`) | — |

Two traps here, both worth knowing before debugging a "my webcam is broken" report:

**3.1 — Half the nodes cannot produce video at all.** `video1` and `video3` are
`V4L2_CAP_META_CAPTURE` (caps `0x04a00000`), carrying UVC payload-header metadata.
Software that naively opens "the next `/dev/video*`" will open a metadata node and
fail with no useful error.

**3.2 — All four nodes report the same name, and `index` restarts per function:**

```
video0: index=0   video1: index=1   video2: index=0   video3: index=1
     name = "Integrated_Webcam_FHD: Integrat"   (identical on all four)
```

So neither card name nor `index` distinguishes RGB from IR. An application that picks
by name can land on the IR sensor and show a greyscale 640×360 image.

**`by-id` does not solve it either** — udev derives it from the USB device serial,
which both functions share, so only the first function gets symlinks:

```
/dev/v4l/by-id/usb-[REDACTED]_Integrated_Webcam_FHD_01.00.00-video-index0 -> video0
/dev/v4l/by-id/usb-[REDACTED]_Integrated_Webcam_FHD_01.00.00-video-index1 -> video1
                                                        (no entries for video2/video3)
```

> ✅ **Use `by-path`. It is the only stable selector that separates the two sensors**,
> because it encodes the USB interface number (`:1.0` = RGB, `:1.2` = IR):
>
> ```
> RGB : /dev/v4l/by-path/pci-0000:00:14.0-usb-0:6:1.0-video-index0
> IR  : /dev/v4l/by-path/pci-0000:00:14.0-usb-0:6:1.2-video-index0
> ```
>
> These survive reboots and node renumbering. Hard-coded `/dev/video0` does not.

---

## 4. Format and resolution matrix

### 4.1 RGB — `/dev/video0`

| Format | Resolution | Rate |
|---|---|---|
| **MJPG** | **1920×1080** | 30 fps |
| MJPG | 1280×960 / 1280×720 / 960×540 / 848×480 / 640×480 / 640×360 | 30 fps |
| YUYV | 1920×1080 | **5 fps only** |
| YUYV | 640×480 / 640×360 / 424×240 / 320×240 / 320×180 / 160×120 | 30 fps |

> ⚠️ **Uncompressed 1080p is capped at 5 fps** — that is a USB 2.0 bandwidth limit,
> not a defect. 1920×1080×2 bytes×30 fps ≈ 1.24 Gb/s, far beyond 480 Mb/s. Any
> application requesting 1080p **must** negotiate MJPG to get 30 fps.

### 4.2 IR — `/dev/video2`

| Format | Resolution | Rate |
|---|---|---|
| `GREY` (8-bit greyscale) | 640×360 | 15 fps |

Single mode only. Adequate for face recognition; not a general-purpose capture path.

---

## 5. Control surface

The two sensors expose **very different** control sets.

**RGB** — full UVC processing unit: `brightness` (−64…64), `contrast` (0…95),
`saturation` (0…100), `hue` (±2000), `gamma` (100…300), `gain` (1…8), `sharpness`
(1…7), `backlight_compensation` (0…3), `white_balance_automatic`,
`white_balance_temperature` (2800…6500 K, inactive while auto WB is on),
`power_line_frequency` (**60 Hz**), plus camera controls `auto_exposure`
(Aperture Priority), `exposure_time_absolute` (10…626), `exposure_dynamic_framerate`.

**IR** — only `region_of_interest_rectangle` and `region_of_interest_auto_ctrls`.
No brightness, no exposure, no gain. Exposure is firmware-governed, which is why the
IR sensor cannot be tuned for general imaging use.

> `power_line_frequency` defaults to **60 Hz**. On a 50 Hz mains grid this causes
> visible flicker banding under artificial light; set it to 1 (50 Hz) if relevant.

---

## 6. Measured performance

### 6.1 Concurrency

RGB (1280×720 MJPG) and IR (640×360 GREY) were streamed **simultaneously** for 4 s.
Both returned rc=0. The two functions have independent bandwidth allocations, so
face-auth and video conferencing can coexist. Nothing held the camera open during
testing (`fuser` clean).

### 6.2 The framerate defect — `exposure_dynamic_framerate`

Sustained 1920×1080 MJPG capture measured **~22–23 fps against a declared 30 fps** — a
25% shortfall. Root cause identified and confirmed by controlled A/B:

| `exposure_dynamic_framerate` | Measured 1080p fps |
|---|---|
| `1` — **as found** | **22** |
| `0` | **30** |

UVC "dynamic framerate" lets the sensor *lengthen exposure by dropping frames* in low
light. The control's **UVC default is `0`, but this unit reports `1` at runtime** —
so the camera silently trades framerate for brightness, and the darker the room, the
worse the video call.

```bash
# 30 fps, fixed — costs brightness in dim rooms
v4l2-ctl -d /dev/video0 -c exposure_dynamic_framerate=0
```

This is **not persistent** across replug or reboot (the camera USB-autosuspends and
resets its controls). To make it stick, a udev rule is required:

```
# /etc/udev/rules.d/90-webcam-fixed-framerate.rules
ACTION=="add", SUBSYSTEM=="video4linux", KERNELS=="3-6", ATTRS{idVendor}=="1bcf", \
  ATTRS{idProduct}=="2ba0", ENV{ID_V4L_CAPABILITIES}==":capture:", \
  RUN+="/usr/bin/v4l2-ctl -d $devnode -c exposure_dynamic_framerate=0"
```

> ⚠️ **Not yet applied.** Recorded as an option, not a change. It is a genuine
> tradeoff: fixing the framerate makes dim-room video darker and noisier. Prefer
> per-application control if your conferencing client offers it.

### 6.3 Benign decoder warning

`ffmpeg` emits `unable to decode APP fields: Invalid data found when processing input`
on every MJPG frame. This is a **cosmetic** complaint about non-standard JPEG APP
markers in this Sunplus firmware. Frames decode correctly and capture succeeds. It is
not a fault and needs no action.

---

## 7. Access control — ACL, not group membership

```
crw-rw----+ 1 root video 81, 0  /dev/video0        ← note the trailing '+' (ACL present)
user::rw-   user:user:rw-   group::rw-   mask::rw-   other::---
```

The owning group is `video`, but **the operator account is not a member of `video`**:

```
user adm cdrom sudo dip plugdev users lpadmin sambashare nordvpn gamemode
```

Camera access works because **systemd-logind grants a per-seat ACL** to the user
holding the active local session. This is the modern, correct model — it is strictly
better than adding the user to `video`, because access is revoked when the session
ends rather than granted permanently.

> ⚠️ **Consequence:** the camera is **unavailable to non-seat sessions** — SSH logins,
> `cron`/`systemd` services, and most containers. If a headless capture service is
> ever needed it will fail with `EACCES`, and the correct fix is a targeted udev rule
> or `systemd-run --machine`, **not** `usermod -aG video`, which would silently widen
> access to every session on the box.

---

## 8. Dell privacy hardware — driver gap

The chassis exposes a Dell privacy control through WMI GUID
`6932965F-1671-4CEB-B988-D3AB0A901919`, bound by the in-tree `dell-privacy` driver as
input device `Dell Privacy Driver` (`event17`).

Its declared key capability decodes to exactly two keycodes:

| Bit | Keycode | Meaning |
|---|---|---|
| 190 | `KEY_F20` | mic-mute (Dell convention) — **mapped** |
| 240 | `KEY_UNKNOWN` | catch-all — **unmapped** |

**The driver does not recognise the events this firmware actually emits.** Three
presses were logged, all rejected:

```
dell-privacy …: Unknown key with type 0x0012 and code 0x0000 pressed
dell-privacy …: Unknown key with type 0x0012 and code 0x002d pressed
dell-privacy …: Unknown key with type 0x0012 and code 0x002d pressed
```

Type `0x0012` with code `0x002d` is not in the driver's `sparse_keymap`, so it
degrades to `KEY_UNKNOWN` and **no userspace event is delivered**. The desktop
therefore shows no camera-privacy indicator and cannot react to the hardware control.

> **Impact is limited, and this matters:** on this platform the privacy cut is
> enforced **in hardware/EC**, not by the OS. The kernel's failure to map the keycode
> means the *notification* is lost, **not** the protection. Do not infer from a silent
> desktop that privacy is off.
>
> **Unresolved:** whether this unit has an electronic-only cut or a physical
> SafeShutter could not be determined from software, and the two are
> indistinguishable from the host. Requires visual inspection of the bezel.

---

## 9. Power management

| Property | Value |
|---|---|
| `power/control` | `auto` |
| `power/runtime_status` | **`suspended`** when idle |
| `power/autosuspend_delay_ms` | 2000 |

USB runtime autosuspend is active and working — the camera draws no power 2 s after
last use. This is already optimal; **no change recommended.**

`uvcvideo` module parameters are all at defaults (`nodrop=1`, `timeout=5000`,
`clock=CLOCK_MONOTONIC`, `hwtimestamps=0`).

> `quirks=4294967295` is `(unsigned)-1`, the "**no override — use the built-in
> per-device quirk table**" sentinel. It does **not** mean every quirk is enabled.
> This is a common misreading of `/sys/module/uvcvideo/parameters/quirks`.

---

## 10. Functional verification

| Test | Result |
|---|---|
| RGB single frame, 1920×1080 MJPG | ✅ decoded, `1920x1080 rgb24` |
| IR single frame, 640×360 GREY | ✅ decoded, `640x360 gray` |
| RGB sustained 1080p stream | ✅ 22 fps as-found / 30 fps tuned |
| Concurrent RGB + IR | ✅ both rc=0 |
| Exclusive-access conflict | ✅ none — no process holding either node |

Luminance statistics of the two verification frames:

| Frame | YMIN | YAVG | YMAX |
|---|---|---|---|
| RGB | 26 | 27.8 | 31 |
| IR | 24 | 24.1 | 28 |

Both frames are near-uniform dark **but carry a non-zero sensor noise floor**
(YMIN 26 / 24, not 0). That distinction is the whole point of the measurement: a
driver-injected or shuttered black frame reads a flat 0. A real, illuminated-but-dark
readout does not. **The sensors are live and the pipeline is intact end to end.**

> The dark content itself is **not diagnostic** — it is equally consistent with an
> engaged privacy shutter, a covered lens, or an unlit room, and those cannot be
> distinguished from software (§8). Confirm visually before treating it as a fault.

---

## 11. Findings

| ID | Sev | Finding |
|---|---|---|
| **F-C1** | 🟠 | `exposure_dynamic_framerate=1` costs **25% of framerate** at 1080p (22 vs 30 fps). Reproducible A/B in §6.2. Not persistent; needs a udev rule to fix permanently. |
| **F-C2** | 🟠 | **Node identity is ambiguous.** 4 nodes, identical names, `index` restarts per function, and `by-id` covers only the RGB function. Apps selecting by name/index can bind the IR sensor or a metadata node. Use `by-path` (§3). |
| **F-C3** | 🟡 | **`dell-privacy` does not map this firmware's keycodes** (type `0x0012`, code `0x002d`). Privacy events never reach userspace; no desktop indicator. Protection is unaffected — only notification is lost (§8). |
| **F-C4** | 🟡 | The camera's **unit serial leaks into `/dev/v4l/by-id/` paths** via the USB iManufacturer field, and `collect-diagnostics.sh` would **not** redact it — its patterns match `Serial:`/`sn:`-prefixed forms and bare MACs/UUIDs, not a bare alphanumeric embedded in a device path. See §12. |
| **F-C5** | 🔵 | IR sensor is fully functional and **entirely unused**. Available for `howdy` face authentication (not installed). |
| **F-C6** | 🔵 | YUYV 1080p is limited to 5 fps by USB 2.0 bandwidth. Expected, not a defect — but applications must select MJPG for 1080p30. |
| **F-C7** | 🔵 | `power_line_frequency` defaults to 60 Hz; wrong for 50 Hz grids. |

Nothing in this subsystem is broken. F-C1 and F-C2 are the two findings with
practical impact on day-to-day use.

---

## 12. Redaction gap in the diagnostics collector

`scripts/collect-diagnostics.sh` redacts serial numbers matched by prefix
(`Serial Number:`, `sn:`, `Serial:`), MAC addresses and UUIDs. The webcam serial
appears with **no prefix at all**, embedded in a path:

```
/dev/v4l/by-id/usb-XXXXXXXXXXXXXXXXXXXX_Integrated_Webcam_FHD_01.00.00-video-index0
                   └─ 20-char unit serial, bare, no prefix
```

None of the existing patterns match this. Any future diagnostics run that captures
`/dev/v4l/by-id/` or `lsusb -v` output would publish the serial to this public
repository.

`scripts/camera-diagnostics.sh` (added alongside this document) redacts the USB
iManufacturer/`by-id` form by default. Folding an equivalent rule into
`collect-diagnostics.sh` is recommended.

---

## 13. Reproduction

```bash
sudo apt-get install -y v4l-utils          # not present by default on Mint 22.3
./scripts/camera-diagnostics.sh            # redacted by default, safe to commit
```

Manual equivalents:

```bash
v4l2-ctl --list-devices                    # node topology
v4l2-ctl -d /dev/video0 --list-formats-ext # format matrix
v4l2-ctl -d /dev/video0 --list-ctrls       # control surface
ls -l /dev/v4l/by-path/                    # stable selectors
getfacl -p /dev/video0                     # access model
dmesg | grep -iE 'uvc|privacy'             # probe + privacy events

# throughput A/B (stores nothing)
ffmpeg -f v4l2 -input_format mjpeg -video_size 1920x1080 -framerate 30 \
       -i /dev/video0 -t 5 -f null -
```

> All commands above are read-only except the `v4l2-ctl -c` control writes in §6.2,
> which are volatile and cleared by USB autosuspend or replug.
