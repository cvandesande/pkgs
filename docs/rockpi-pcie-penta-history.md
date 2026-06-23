# Archive: Rock Pi 4A PCIe/SATA fix and Penta HAT history

This is the detailed historical record for the PCIe/SATA link-training fix and
the Penta HAT + PCIe Gen2 enablement work. All of it is resolved and
hardware-confirmed; it is kept here for reference instead of in HANDOFF.md so
that file can stay short. See HANDOFF.md for current/active work.

## Penta HAT + PCIe Gen2 combined test image

At the user's request, the Penta HAT enablement and PCIe Gen2 change were
combined into one test image.

Published SBC image:

```text
docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-penta-gen2-1
sha256:47b21bdaa8953e065da040e2f639b0d9942da648a74d35b4a752aa8acdde60a5
```

Raw eMMC artifacts:

```text
artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-penta-gen2-1/
  talos-v1.13.4-rockpi-pcie-min-only0012-penta-gen2-1-rockpi_4-arm64.raw
  talos-v1.13.4-rockpi-pcie-min-only0012-penta-gen2-1-rockpi_4-arm64.raw.xz
```

Checksums:

```text
raw:    db2c405b3cf9290fcbeb85a8f5f9dfbfbe5a00cb465d71f85f67bd2c9fa4fca6
raw.xz: e43ca887d114ac60befcc8f7b8a3cecb46fffb91d3e7e6bb99d7bc716cbf7cec
```

The XZ stream and generated checksum files pass. The raw image passed the
Rockchip boot-area check. Direct inspection of its embedded Rock Pi 4A DTB
confirmed:

```text
max-link-speed = <2>
i2c7 status = okay
pwm1 status = okay
vpcie12v-supply absent
bus-scan-delay-ms absent
vcc3v3_pcie min/max voltage constraints absent
```

The active U-Boot source patch is:

```text
/home/cvandesande/github/sbc-rockchip/
  artifacts/rockpi4/u-boot/patches/
  0001-rockpi4-enable-penta-hat-and-pcie-gen2.patch
```

This image requires a full eMMC flash and has now been hardware-confirmed.

Live confirmation:

```text
PCIe current_link_speed: 5.0 GT/s PCIe
PCIe current_link_width: 2
PCIe bandwidth message: 8.000 Gb/s available, 5.0 GT/s PCIe x2
JMB585 [197b:0585] enumerated
AHCI initialized in 6 Gbps SATA mode
ata1 and ata3 linked at 6.0 Gbps
sda and sdb are both present
/dev/i2c-7 exists
/sys/class/i2c-dev/i2c-7 exists
/proc/device-tree/i2c@ff160000/status = okay
/proc/device-tree/pwm@ff420010/status = okay
/sys/class/pwm contains pwmchip0 and pwmchip1, each with one channel
```

No PCIe timeout or error `-110` was observed. This confirms the combined DT
configuration and PCIe Gen2 x2 operation. The Penta hardware interfaces are
available to userspace.

`sbc-rockchip-v0.2.0-rockpi-penta-gen2-1` is the current default
`EMMC_OVERLAY_IMAGE` in `hack/build-rockpi-installer.sh` and
`hack/build-rockpi-installer-with-verification.sh`.

## Penta controller container

The controller is containerized, published, and deployed:

```text
docker.io/cvandesande/rockpi-penta:0.2.2-talos-py3.14-trixie-2
sha256:5dc464e8e75222b95fb37c0cea0f6c82574efc85cce859db1fa8eb5d7d2a6b0d
```

Source and manifest:

```text
rockpi-penta-controller/
rockpi-penta-controller/kubernetes/deployment.yaml
```

The image supports `linux/amd64` and `linux/arm64`. It uses the requested
official `python:3.14-trixie` base, which resolved on 2026-06-20 to Python
3.14.6 and OCI index:

```text
sha256:cac80dc03dafb0e9ffc5d390ada6c2e8f6323a275bb89c1d132fedf7a195e054
```

Live deployment:

```text
namespace: kube-system
deployment: rockpi-penta
node: whiterock
ready replicas: 1/1
corrected image restarts: 0
button actions: disabled
```

Talos runtime logs confirm:

```text
using PWM controller /host/sys/class/pwm/pwmchip0
using OLED at /dev/i2c-7 address 0x3c
temperature=52.2C fan=100% raw_duty=0.000
```

Host PWM state:

```text
period: 40000 ns
duty_cycle: 30000
enable: 1
```

The live fan curve was adjusted to:

```text
below 50 C: off
50-59 C: 25%
60-69 C: 50%
70-79 C: 75%
80 C+: 100%
hysteresis: 3 C
```

At 52.2 C the controller reported `fan=25% raw_duty=0.750`; the host PWM
reported period `40000`, duty cycle `30000`, enabled. The replacement pod was
ready with zero restarts.

The initial `-1` and `-2` images used Python-based liveness probes that could
exceed the probe timeout under the RK3399 CPU limit. The deployed `-3` image
uses a lightweight shell heartbeat check and remained healthy.

The adaptation removes the Debian package's systemd, `/boot` mutation, shell
commands, and reboot/poweroff actions. It uses direct I2C, modern `gpiod`,
runtime PWM discovery by `/pwm@ff420010`, and mounted Talos `/proc`/`/sys`
metrics.

### Still open (lower priority, parked while ZFS work is active)

1. Visually confirm the OLED pages and fan response over a temperature cycle.
2. Leave the controller running long enough to establish stability.
3. Only then set `ENABLE_BUTTON=true` and test its actions.
4. Reduce privileges and host mounts where practical.

If PCIe fails or is unstable, keep the Penta changes and change only:

```dts
max-link-speed = <1>;
```

The clean only-`0012` Gen1 image (next section) remains the known-good
rollback.

## Critical U-Boot DTB discovery

The previous custom `sbc-rockchip` image source-patched U-Boot with the same
DT properties as kernel patch `0006`:

```text
/home/cvandesande/github/sbc-rockchip/
  artifacts/rockpi4/u-boot/patches/
  0001-rockpi4-add-pcie-supply-and-scan-delay.patch
```

That old U-Boot patch added:

```dts
regulator-min-microvolt = <3300000>;
regulator-max-microvolt = <3300000>;
vpcie12v-supply = <&vcc12v_dcin>;
bus-scan-delay-ms = <1500>;
```

The build script defaults to `EMMC_OVERLAY_IMAGE=sbc-rockchip-v0.2.0-rockpi-penta-gen2-1`
now (previously `sbc-rockchip-v0.2.0-rockpi-pcie1`, the old/dirty image
carrying these properties).

For the clean image, the old patch was moved out of the active patch directory
to:

```text
/home/cvandesande/github/sbc-rockchip/
  artifacts/rockpi4/u-boot/patches.disabled/clean-no0006/
```

The active Rock Pi patch directory contains only `.gitkeep`. Inspection of the
Rock Pi U-Boot binary pulled back from Docker Hub found one applicable Rock Pi
4A DTB and confirmed:

```text
vpcie12v-supply absent
bus-scan-delay-ms absent
vcc3v3_pcie regulator-min-microvolt absent
vcc3v3_pcie regulator-max-microvolt absent
vpcie3v3-supply still present
max-link-speed = <1>
i2c7 status = disabled
pwm1 status = disabled
```

This proves the published SBC image is genuinely clean of the old
`0006` additions. It does not yet prove that the hardware works without them;
that requires the full eMMC test (done — see below).

## Confirmed working history

### Original fixed stack

Confirmed working:

```text
v1.13.4-rockpi-pcie-perst-timing68-1
```

Kernel:

```text
Linux 6.18.34-talos
```

Observed:

```text
pci 0000:01:00.0: [197b:0585]
2.5 GT/s PCIe x2
AHCI attached
ata1 and ata3 at SATA 6.0 Gbps
sda and sdb present
```

### Controlled minimisation results

| Removed | Confirmed tag | Result |
|---|---|---|
| `0010` PHY refclk lifecycle | `v1.13.4-rockpi-pcie-min-no0010-1` | Works |
| `0009` PHY behavior | `v1.13.4-rockpi-pcie-min-no0010-no0009-1` | Works |
| `0008` reset sequencing | `v1.13.4-rockpi-pcie-min-no0010-no0009-no0008-1` | Works |
| `0011` initial PERST GPIO state | `v1.13.4-rockpi-pcie-min-no0010-no0009-no0008-no0011-1` | Works |
| `0007` bus-scan-delay consumer | `v1.13.4-rockpi-pcie-min-only0012-plus-dt-1` | Works |

The last hardware-confirmed image had kernel patches `0006` and `0012`, while
its U-Boot DTB also carried the `0006` properties.

### Genuinely clean candidate (current PCIe baseline)

```text
v1.13.4-rockpi-pcie-min-only0012-clean-no0006-1
```

Active PCIe-related kernel patch:

```text
0012-PCI-rockchip-restore-RK3399-6.8-PERST-timing.patch
```

Hardware-confirmed after full eMMC flash:

```text
Linux 6.18.34-talos
rockchip-pcie f8000000.pcie: no vpcie12v regulator found
rockchip-pcie f8000000.pcie: PCI host bridge to bus 0000:00
pci 0000:01:00.0: [197b:0585] type 00 class 0x010601
2.5 GT/s PCIe x2
ahci 0000:01:00.0: AHCI vers 0001.0301, 32 command slots, 6 Gbps, SATA mode
ata1: SATA link up 6.0 Gbps
ata3: SATA link up 6.0 Gbps
sda 2.0 TB sata Samsung SSD 860
sdb 2.0 TB sata Samsung SSD 860
```

No PCIe link-training timeout or error `-110` was present. Kernel patch
`0006` and its equivalent U-Boot DT additions are confirmed unnecessary on
this hardware.

## Why `0012` works

Armbian kernel narrowing established:

```text
6.1.63  works
6.6.63  works
6.8.11  works
6.11.0  failed to boot and was not useful diagnostically
6.12.x  fails with PCIe Gen1 link-training timeout / error -110
6.18.x  fails similarly without the fix
```

The decisive upstream behavior change is PERST timing:

Working 6.8-style RK3399 sequence:

```text
enable Gen1 link training
release PERST immediately
poll for link-up
```

Failing newer sequence:

```text
enable Gen1 link training
wait 100 ms
release PERST
wait another 100 ms
poll for link-up
```

Patch `0012` skips the two newer waits for RK3399 only. Non-RK3399 controllers
retain current upstream behavior.

Confidence that `0012` is the decisive link-training fix: **high**.

## Persistent staged post-minimisation work

Prepared files are safely stored outside `/tmp`:

```text
staging/post-minimisation/rockpi-penta-gen2-overlay-deliverable/
staging/post-minimisation/rockpi-penta-gen2-overlay-deliverable.tar.gz
```

Archive SHA256:

```text
ae2b7188612381bc8cf0484acfbad8845e4311e2af3ba6f52244736116b94d46
```

Contents include:

- clean-no`0006` control instructions;
- a U-Boot source patch enabling Penta I2C7 and PWM1 plus PCIe Gen2;
- a standalone DTB verifier;
- a reference DTB compiled from pristine U-Boot 2026.01.

The staged combined patch was validated by:

1. applying it to pristine U-Boot 2026.01;
2. compiling `rk3399-rock-pi-4b.dtb`;
3. confirming:
   - `/i2c@ff160000` is enabled;
   - `/pwm@ff420010` is enabled;
   - `/pcie@f8000000/max-link-speed = <2>`;
   - old `0006` properties are absent.

## Penta HAT and Gen2 work after minimisation

The Radxa package inspected was:

```text
rockpi-penta 0.2.2
```

It is mostly Python and controls:

- SSD1306 OLED via I2C7;
- fan via PWM1;
- OLED reset via GPIO4_D2;
- button via GPIO chip/line access;
- CPU temperature via thermal sysfs.

The Talos kernel already enables the required I2C, GPIO character-device,
Rockchip PWM, and thermal drivers. I2C7 and PWM1 are disabled in the base DT and
must be enabled in the U-Boot-provided DTB.

### Recommended controlled order (executed)

The staged combined Penta+Gen2 patch was deliberately split for diagnostic
clarity:

1. **Penta Gen1 image** — enable I2C7, enable PWM1, leave `max-link-speed = <1>`;
   verify SATA, I2C, and PWM.
2. **Penta Gen2 image** — change only `max-link-speed = <2>`; verify link
   speed, width, SATA disks, reboots, and sustained I/O.

Both stages passed; the combined Penta+Gen2 image is the current overlay
default (see above).

Expected Gen2 result (as originally assessed, before hardware confirmation):

```text
5.0 GT/s PCIe x2
```

The Rockchip driver trains at Gen1 first, then requests Gen2. If Gen2
retraining fails it should fall back to Gen1, but disk presence and stability
must still be checked.

Gen2 confidence at the time: **medium**. (Superseded — see Confirmed working
history and Confidence summary below; Gen2 x2 is now hardware-confirmed.)

### Kubernetes controller plan (executed)

1. build an ARM64 Python container forked from `rockpi-penta`;
2. deploy one replica pinned to `whiterock`;
3. initially grant privileged access to I2C, GPIO, PWM sysfs, and thermal
   sysfs;
4. implement fan control first, then OLED, then button handling;
5. replace container-local uptime/IP/disk reporting with node-aware data;
6. remove or redesign direct `reboot`/`poweroff` actions;
7. reduce privileges where practical.

Do not install the `.deb` directly on Talos. Its installer assumes Debian,
systemd, `/boot` mutation, and `u-boot-update`.

## Confidence summary

- PCIe link-training issue is solved by `0012`: **high**.
- Kernel patches `0007` through `0011` are removable: **high**, hardware
  confirmed.
- Kernel copy of `0006` is redundant: **high**, hardware-confirmed.
- Published U-Boot image is genuinely free of the `0006` additions: **high**,
  independently inspected after pulling it from Docker Hub.
- Hardware works without the `0006` DT properties: **high**,
  hardware-confirmed.
- Penta HAT can be managed from a Kubernetes Python container: **high**.
- Gen2 x2 will be stable on this board/card combination: **medium**.
- Combined Penta+Gen2 raw image contains the intended DTB: **high**,
  independently inspected.
- Combined Penta+Gen2 image works on hardware: **high**, confirmed at Gen2 x2
  with both SATA disks and the Penta I2C/PWM interfaces present.
