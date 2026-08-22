# Camera diagnostics — Dell Latitude 7420

- **Captured:** 2026-08-16 20:55:31 EDT
- **Kernel:** 7.0.0-28-generic
- **Device:** `1bcf:2ba0` Integrated_Webcam_FHD
- **Redaction:** ENABLED (safe to commit)
- **Reference:** [docs/23-camera-and-imaging.md](../docs/23-camera-and-imaging.md)

## USB device descriptor

```

Bus 003 Device 003: ID 1bcf:2ba0 Sunplus Innovation Technology Inc. Integrated_Webcam_FHD
Device Descriptor:
  bLength                18
  bDescriptorType         1
  bcdUSB               2.01
  bDeviceClass          239 Miscellaneous Device
  bDeviceSubClass         2 [unknown]
  bDeviceProtocol         1 Interface Association
  bMaxPacketSize0        64
  idVendor           0x1bcf Sunplus Innovation Technology Inc.
  idProduct          0x2ba0 Integrated_Webcam_FHD
  bcdDevice            0.12
  iManufacturer           1 [REDACTED]
  iProduct                2 Integrated_Webcam_FHD
  iSerial                 3 01.00.00
  bNumConfigurations      1
  Configuration Descriptor:
    bLength                 9
    bDescriptorType         2
    wTotalLength       0x044d
    bNumInterfaces          4
    bConfigurationValue     1
    iConfiguration          0 
    bmAttributes         0x80
      (Bus Powered)
    MaxPower              500mA
    Interface Association:
      bLength                 8
      bDescriptorType        11
      bFirstInterface         0
      bInterfaceCount         2
      bFunctionClass         14 Video
      bFunctionSubClass       3 Video Interface Collection
      bFunctionProtocol       0 
      iFunction               4 
    Interface Descriptor:
      bLength                 9
      bDescriptorType         4
      bInterfaceNumber        0
      bAlternateSetting       0
      bNumEndpoints           1
      bInterfaceClass        14 Video
      bInterfaceSubClass      1 Video Control
      bInterfaceProtocol      1 
```

## Interface map (dual-function check)

Expect two Interface Association Descriptors: if 0+1 = RGB, if 2+3 = IR.
```
bFirstInterface         0
bInterfaceCount         2
bFunctionClass         14 Video
bInterfaceNumber        0
bInterfaceSubClass      1 Video Control
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        1
bInterfaceSubClass      2 Video Streaming
bFirstInterface         2
bInterfaceCount         2
bFunctionClass         14 Video
bInterfaceNumber        2
bInterfaceSubClass      1 Video Control
bInterfaceNumber        3
bInterfaceSubClass      2 Video Streaming
bInterfaceNumber        3
bInterfaceSubClass      2 Video Streaming
```

## V4L2 node topology

```
Integrated_Webcam_FHD: Integrat (usb-0000:00:14.0-6):
	/dev/video0
	/dev/video1
	/dev/video2
	/dev/video3
	/dev/media0
	/dev/media1

```

## Per-node capabilities and formats


### /dev/video0

```
	Driver name      : uvcvideo
	Card type        : Integrated_Webcam_FHD: Integrat
	Bus info         : usb-0000:00:14.0-6
	Device Caps      : 0x04200001
	Driver name      : uvcvideo
	Bus info         : usb-0000:00:14.0-6
--- formats ---
	Type: Video Capture
	[0]: 'MJPG' (Motion-JPEG, compressed)
		Size: Discrete 1920x1080
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 1280x960
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 1280x720
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 960x540
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 848x480
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 640x480
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 640x360
			Interval: Discrete 0.033s (30.000 fps)
	[1]: 'YUYV' (YUYV 4:2:2)
		Size: Discrete 1920x1080
			Interval: Discrete 0.200s (5.000 fps)
		Size: Discrete 640x480
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 640x360
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 424x240
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 320x240
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 320x180
			Interval: Discrete 0.033s (30.000 fps)
		Size: Discrete 160x120
			Interval: Discrete 0.033s (30.000 fps)
```

### /dev/video1

```
	Driver name      : uvcvideo
	Card type        : Integrated_Webcam_FHD: Integrat
	Bus info         : usb-0000:00:14.0-6
	Device Caps      : 0x04a00000
	Driver name      : uvcvideo
	Bus info         : usb-0000:00:14.0-6
--- formats ---
	Type: Video Capture
```

### /dev/video2

```
	Driver name      : uvcvideo
	Card type        : Integrated_Webcam_FHD: Integrat
	Bus info         : usb-0000:00:14.0-6
	Device Caps      : 0x04200001
	Driver name      : uvcvideo
	Bus info         : usb-0000:00:14.0-6
--- formats ---
	Type: Video Capture
	[0]: 'GREY' (8-bit Greyscale)
		Size: Discrete 640x360
			Interval: Discrete 0.067s (15.000 fps)
```

### /dev/video3

```
	Driver name      : uvcvideo
	Card type        : Integrated_Webcam_FHD: Integrat
	Bus info         : usb-0000:00:14.0-6
	Device Caps      : 0x04a00000
	Driver name      : uvcvideo
	Bus info         : usb-0000:00:14.0-6
--- formats ---
	Type: Video Capture
```

## Control surface


### /dev/video0

```

User Controls

                     brightness 0x00980900 (int)    : min=-64 max=64 step=1 default=0 value=0 flags=0x00001000
                       contrast 0x00980901 (int)    : min=0 max=95 step=1 default=0 value=0 flags=0x00001000
                     saturation 0x00980902 (int)    : min=0 max=100 step=1 default=64 value=64 flags=0x00001000
                            hue 0x00980903 (int)    : min=-2000 max=2000 step=1 default=0 value=0 flags=0x00001000
        white_balance_automatic 0x0098090c (bool)   : default=1 value=1
                          gamma 0x00980910 (int)    : min=100 max=300 step=1 default=100 value=100 flags=0x00001000
                           gain 0x00980913 (int)    : min=1 max=8 step=1 default=1 value=1 flags=0x00001000
           power_line_frequency 0x00980918 (menu)   : min=0 max=2 default=2 value=2 (60 Hz)
      white_balance_temperature 0x0098091a (int)    : min=2800 max=6500 step=1 default=4600 value=4600 flags=inactive, 0x00001000
                      sharpness 0x0098091b (int)    : min=1 max=7 step=1 default=2 value=2 flags=0x00001000
         backlight_compensation 0x0098091c (int)    : min=0 max=3 step=1 default=3 value=3 flags=0x00001000
   region_of_interest_rectangle 0x00981ae1 (unknown): type=107 value=unsupported payload type flags=has-payload, 0x00001000
  region_of_interest_auto_ctrls 0x00981ae2 (bitmask): max=0x00000001 default=0x00000001 value=1 flags=0x00001000

Camera Controls

                  auto_exposure 0x009a0901 (menu)   : min=0 max=3 default=3 value=3 (Aperture Priority Mode)
         exposure_time_absolute 0x009a0902 (int)    : min=10 max=626 step=1 default=156 value=156 flags=inactive, 0x00001000
     exposure_dynamic_framerate 0x009a0903 (bool)   : default=0 value=1
```

### /dev/video2

```

User Controls

   region_of_interest_rectangle 0x00981ae1 (unknown): type=107 value=unsupported payload type flags=has-payload, 0x00001000
  region_of_interest_auto_ctrls 0x00981ae2 (bitmask): max=0x00000001 default=0x00000001 value=1 flags=0x00001000
```

## Stable device selectors

`by-id` covers only the RGB function. Use `by-path`: `:1.0` = RGB, `:1.2` = IR.
```
--- by-id ---
usb-[REDACTED]_Integrated_Webcam_FHD_01.00.00-video-index0 -> ../../video0
usb-[REDACTED]_Integrated_Webcam_FHD_01.00.00-video-index1 -> ../../video1
--- by-path ---
pci-0000:00:14.0-usb-0:6:1.0-video-index0                  -> ../../video0
pci-0000:00:14.0-usb-0:6:1.0-video-index1                  -> ../../video1
pci-0000:00:14.0-usb-0:6:1.2-video-index0                  -> ../../video2
pci-0000:00:14.0-usb-0:6:1.2-video-index1                  -> ../../video3
pci-0000:00:14.0-usbv2-0:6:1.0-video-index0                -> ../../video0
pci-0000:00:14.0-usbv2-0:6:1.0-video-index1                -> ../../video1
pci-0000:00:14.0-usbv2-0:6:1.2-video-index0                -> ../../video2
pci-0000:00:14.0-usbv2-0:6:1.2-video-index1                -> ../../video3
```

## Access-control model

Access is granted by systemd-logind per-seat ACL, not `video` group membership.
```
crw-rw----+ 1 root video 81, 0 Aug 16 02:39 /dev/video0
crw-rw----+ 1 root video 81, 2 Aug 16 02:39 /dev/video2
--- groups ---
user adm cdrom sudo dip plugdev users lpadmin sambashare nordvpn gamemode
--- acl ---
user::rw-
user:user:rw-
group::rw-
mask::rw-
other::---

```

## Power management

```
control                  auto
runtime_status           active
autosuspend_delay_ms     2000
```

## uvcvideo module parameters

`quirks=4294967295` is the `(unsigned)-1` 'no override' sentinel — not 'all quirks on'.
```
clock            CLOCK_MONOTONIC
hwtimestamps     0
nodrop           1
quirks           4294967295
timeout          5000
trace            0
```

## Dell privacy driver events

Unmapped keycodes here mean privacy events never reach userspace (docs/23 §8).
```
N: Name="Dell Privacy Driver"
P: Phys=
S: Sysfs=/devices/platform/PNP0C14:02/wmi_bus/wmi_bus-PNP0C14:02/[UUID-REDACTED]/input/input28
U: Uniq=
H: Handlers=kbd event17 
B: PROP=0
B: EV=13
B: KEY=1000000000000 4000000000000000 0 0
B: MSC=10
--- kernel messages ---
[   10.009478] input: Dell Privacy Driver as /devices/platform/PNP0C14:02/wmi_bus/wmi_bus-PNP0C14:02/[UUID-REDACTED]/input/input28
[   11.226448] uvcvideo 3-6:1.0: Found UVC 1.50 device Integrated_Webcam_FHD (1bcf:2ba0)
[   11.292634] uvcvideo 3-6:1.2: Found UVC 1.50 device Integrated_Webcam_FHD (1bcf:2ba0)
[   11.316247] usbcore: registered new interface driver uvcvideo
[16183.345231] dell-privacy [UUID-REDACTED]: Unknown key with type 0x0012 and code 0x0000 pressed
[17919.252354] dell-privacy [UUID-REDACTED]: Unknown key with type 0x0012 and code 0x002d pressed
[18030.747066] dell-privacy [UUID-REDACTED]: Unknown key with type 0x0012 and code 0x002d pressed
```

## Exclusive-access check

```
no process holding either node
```

## Sustained throughput (frames discarded)

Declared 1080p rate is 30 fps. A result near 22 fps indicates
`exposure_dynamic_framerate=1` trading framerate for exposure (docs/23 §6.2).
```
exposure_dynamic_framerate = 1
fps= 20
```

---

_Generated by `scripts/camera-diagnostics.sh`. No image data was captured._
