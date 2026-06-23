# pkgs

![Dependency Diagram](/deps.svg)

This repository produces a set of packages that can be used to build a rootfs suitable for creating custom Linux distributions.
The packages are published as a container image, and can be "installed" by simply copying the contents to your rootfs.
For example, using Docker, we can do the following:

```docker
FROM scratch
COPY --from=<registry>/<organization>/<pkg>:<tag> / /
```

## RockPI custom Talos installer with patched kernel

These commands build the patched `kernel` package from this repository, push it
to GitLab Container Registry, then build a Talos `v1.13.4` arm64 installer image
which embeds that kernel.

Shortcut script for the current RockPI PCIe compatibility build:

```sh
cd /home/cvandesande/github/pkgs
CUSTOM_TAG=v1.13.4-rockpi-pcie-min-only0012-1 hack/build-rockpi-installer.sh
```

Confirmed working on the RockPi 4A / JMicron SATA setup:
`v1.13.4-rockpi-pcie-perst-timing68-1` trains the RK3399 PCIe link,
enumerates the AHCI controller, and exposes the SATA disks to Talos.

Current minimization candidate:
`v1.13.4-rockpi-pcie-min-only0012-1` disables the previous DT alignment patch
(`0006`), bus-scan-delay driver patch (`0007`), PHY restoration patches
(`0009` and `0010`), the RK3399 reset sequencing patch (`0008`), and the PERST
initial-state patch (`0011`), while keeping only the PERST timing patch
(`0012`) from the confirmed stack.

Current RockPI PCIe/SATA compatibility patch set:

- Current minimization candidate disables the previous RockPi/RK3399 PCIe DT
  and driver behavior/reset/PERST-initial-state patches:
  - `0006`: RockPi PCIe DT alignment (`vcc3v3_pcie` min/max voltage,
    `vpcie12v-supply`, and `bus-scan-delay-ms`);
  - `0007`: `bus-scan-delay-ms` driver support;
  - `0008`: RK3399 reset sequencing;
  - `0009`: lane de-idle order and TEST_WRITE strobe behavior;
  - `0010`: reference-clock lifecycle.
  - `0011`: initial PERST GPIO state.
- Restore the working 6.8 RK3399 PERST/link-training timing: enable Gen1
  training, release PERST immediately, then poll link-up without the newer
  100 ms pre-release and 100 ms post-release waits.
- Do not include extra link-training logging, endpoint power retries, or
  runtime tuning knobs. The goal is an upstream-shaped patch stack with only
  board/driver compatibility changes.

See [`docs/rockpi-pcie-6.1-vs-6.18-delta.md`](docs/rockpi-pcie-6.1-vs-6.18-delta.md)
for the exact working Armbian provenance, live Talos DT comparison, and scoped
PCIe init delta table.

> **Important:** if the RockPI cannot see the PCIe SATA controller while booted
> into the installer environment, an installer container alone is not enough: the
> boot media also needs the patched kernel. The build script now produces a
> patched RockPi SBC image that can be flashed to eMMC. A generic arm64
> `image-metal` artifact is not sufficient for bare RockPi eMMC boot because it
> does not include the Rockchip SPL/U-Boot loader in the pre-partition boot
> area.

The examples use the GitLab path shown by the local Docker login on this
machine. Change `USERNAME` if you want a different GitLab project/image path.

### 0. Prerequisites

- Docker with `buildx`
- `git`
- `make`
- Docker login for `registry.gitlab.com`
- `crane`, used by the Talos Makefile to push the final installer image

If `crane` is not installed, this temporary wrapper uses the official crane
container and your existing Docker credentials:

```sh
mkdir -p /tmp/talos-build-bin
cat >/tmp/talos-build-bin/crane <<'EOF'
#!/usr/bin/env sh
set -eu
docker run --rm \
  -v "$HOME/.docker:/root/.docker:ro" \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  gcr.io/go-containerregistry/crane "$@"
EOF
chmod +x /tmp/talos-build-bin/crane
export PATH="/tmp/talos-build-bin:$PATH"
```

### 1. Build and push the patched kernel package

Run this from this `pkgs` repository:

```sh
cd /home/cvandesande/github/pkgs

export REGISTRY=registry.gitlab.com
export USERNAME=cvandesande/dockers/talos-rockpi
export CUSTOM_TAG=v1.13.4-rockpi-pcie-min-only0012-1

make kernel \
  PLATFORM=linux/arm64 \
  REGISTRY="${REGISTRY}" \
  USERNAME="${USERNAME}" \
  TAG="${CUSTOM_TAG}" \
  PUSH=true \
  PROGRESS=plain
```

This pushes:

```text
registry.gitlab.com/cvandesande/dockers/talos-rockpi/kernel:v1.13.4-rockpi-pcie-min-only0012-1
```

### 2. Clone Talos v1.13.4

```sh
cd /home/cvandesande/github
git clone --branch v1.13.4 --depth 1 https://github.com/siderolabs/talos.git talos-v1.13.4-rockpi
cd talos-v1.13.4-rockpi
```

### 3. Configure the Talos build to use the patched kernel

```sh
export REGISTRY=registry.gitlab.com
export USERNAME=cvandesande/dockers/talos-rockpi
export CUSTOM_TAG=v1.13.4-rockpi-pcie-min-only0012-1

# Keep the Talos version as v1.13.4, but tag pushed images with the custom suffix.
export TAG=v1.13.4
export TAG_SUFFIX=-rockpi-pcie-min-only0012-1

export PKG_KERNEL="${REGISTRY}/${USERNAME}/kernel:${CUSTOM_TAG}"
```

### 4. Build and push installer support images

Build the arm64 installer base image:

```sh
make installer-base \
  PLATFORM=linux/arm64 \
  PUSH=true \
  PROGRESS=plain
```

Build and push an amd64 `imager` image which contains arm64 install artifacts.
This is intentional: this machine can build arm64 with BuildKit/QEMU, but normal
`docker run --platform linux/arm64 ...` may fail without binfmt configured. The
amd64 imager can still generate arm64 Talos artifacts.

```sh
make imager \
  PLATFORM=linux/amd64 \
  INSTALLER_ARCH=arm64 \
  PKG_KERNEL="${PKG_KERNEL}" \
  PUSH=true \
  PROGRESS=plain
```

### 5. Build and push the custom arm64 installer image

```sh
make installer \
  PLATFORM=linux/arm64 \
  PROGRESS=plain

cat _out/installer_image
```

The expected installer image is:

```text
registry.gitlab.com/cvandesande/dockers/talos-rockpi/installer:v1.13.4-rockpi-pcie-min-only0012-1
```

Use that image in Talos machine config:

```yaml
machine:
  install:
    image: registry.gitlab.com/cvandesande/dockers/talos-rockpi/installer:v1.13.4-rockpi-pcie-min-only0012-1
```

### 6. Build patched eMMC boot media

The shortcut script also builds Talos `image-rockpi4` with the pinned
`sbc-rockchip` `rockpi4` overlay, copies the compressed Rockchip/RockPi SBC
artifact into this repo, expands it to a writable raw image for flashing, and
verifies that the Rockchip bootloader area is populated before recommending the
artifact.

The RockPi boot path gets its early DTB from the `sbc-rockchip` U-Boot overlay,
not only from the kernel package. The current workflow therefore uses a
source-patched Talos `sbc-rockchip` overlay image instead of mutating the
generated raw image:

```text
docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-pcie1
```

That overlay is built from the Sidero `sbc-rockchip` source with the Rock Pi 4
U-Boot DTS carrying the Armbian-parity PCIe properties. This stays aligned with
what Talos already does: the Talos imager still writes the overlay-provided
`u-boot-rockchip.bin`; we only change how that overlay is built.

If you change the overlay source, rebuild and push it first:

```sh
cd /home/cvandesande/github/sbc-rockchip
make target-sbc-rockchip \
  PLATFORM=linux/amd64 \
  PROGRESS=plain \
  TARGET_ARGS='--tag=docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-pcie1 --push=true'
```

```sh
cd /home/cvandesande/github/pkgs
CUSTOM_TAG=v1.13.4-rockpi-pcie-min-only0012-1 hack/build-rockpi-installer.sh

ls -lh artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-1/
```

Expected local artifacts:

```text
artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-1/talos-v1.13.4-rockpi-pcie-min-only0012-1-rockpi_4-arm64.raw.xz
# or, depending on Talos/overlay output format:
artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-1/talos-v1.13.4-rockpi-pcie-min-only0012-1-rockpi_4-arm64.raw.zst

artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-1/talos-v1.13.4-rockpi-pcie-min-only0012-1-rockpi_4-arm64.raw
```

The `.raw` file is the eMMC-flashable image. The script should print a line like
this before you flash it:

```text
RockPi bootloader check passed: first_partition_lba=22528, nonzero_boot_gap_bytes=...
```

The script also verifies the U-Boot-provided Rock Pi 4A DTB embedded in the raw
image. This is required because this boot path hands Linux a DTB from U-Boot/EFI;
patching only the kernel package DTB is not enough. The expected verification log
is:

```text
Verifying RockPi U-Boot-provided DTB PCIe properties
FDT at offset ...: verified Rock Pi 4A vcc12_phandle=...
```

The verified Armbian-parity PCIe properties are:

```text
/pcie@f8000000: vpcie12v-supply = <&vcc12v_dcin>
/pcie@f8000000: bus-scan-delay-ms = <1500>
/vcc3v3-pcie-regulator: regulator-min-microvolt = <3300000>
/vcc3v3-pcie-regulator: regulator-max-microvolt = <3300000>
```

Flash it only after verifying the target device path:

```sh
lsblk
sudo dd if=artifacts/rockpi/v1.13.4-rockpi-pcie-min-only0012-1/talos-v1.13.4-rockpi-pcie-min-only0012-1-rockpi_4-arm64.raw \
  of=/dev/sdX \
  bs=4M \
  conv=fsync \
  status=progress
```

Do **not** blindly copy/paste the `dd` command against an unknown `/dev/sdX`.

Useful script switches:

```sh
# Resume after the installer was already built and pushed, and only build the
# eMMC image:
BUILD_KERNEL=false \
BUILD_INSTALLER_BASE=false \
BUILD_IMAGER=false \
BUILD_INSTALLER=false \
COPY_TO_DOCKERHUB=false \
hack/build-rockpi-installer.sh

# If image-rockpi4 already succeeded but the script failed while
# finding/copying the artifact, reuse the existing compressed artifact:
BUILD_KERNEL=false \
BUILD_INSTALLER_BASE=false \
BUILD_IMAGER=false \
BUILD_INSTALLER=false \
COPY_TO_DOCKERHUB=false \
RUN_EMMC_IMAGE_TARGET=false \
hack/build-rockpi-installer.sh

# Build/push installer but skip the eMMC image:
BUILD_EMMC_IMAGE=false hack/build-rockpi-installer.sh

# Keep only the compressed .raw.zst/.raw.xz artifact:
DECOMPRESS_EMMC_IMAGE=false hack/build-rockpi-installer.sh

# Disable the Rockchip bootloader sanity check only if you are intentionally
# building a non-RockPi image:
VERIFY_ROCKPI_BOOTLOADER=false hack/build-rockpi-installer.sh

# Disable the embedded U-Boot DTB verifier only if you are intentionally
# building a non-RockPi image:
VERIFY_ROCKPI_UBOOT_DTB=false hack/build-rockpi-installer.sh

# Avoid post-build binary DTB patching. It is disabled by default because
# changing a generated U-Boot/Rockchip blob can invalidate FIT/hash metadata;
# the normal path is to source-patch the sbc-rockchip/U-Boot overlay.
PATCH_ROCKPI_UBOOT_DTB=true hack/build-rockpi-installer.sh

# The eMMC image step runs the Talos imager container as root by default to
# avoid Docker bind-mount permission problems while creating the raw image.
# Override this if your Docker setup can write the large raw image as your UID:
EMMC_IMAGE_DOCKER_USER="$(id -u):$(id -g)" hack/build-rockpi-installer.sh

# Override the SBC target if needed. The Rock Pi 4A uses rockpi_4.
EMMC_IMAGE_TARGET=rockpi_4 hack/build-rockpi-installer.sh

# Override the Talos image profile/overlay pair. The tested Rock Pi 4A defaults
# are EMMC_IMAGE_PROFILE=rockpi4, EMMC_OVERLAY_NAME=rockpi4, and the custom
# source-patched EMMC_OVERLAY_IMAGE shown above.
EMMC_IMAGE_PROFILE=rockpi4 \
EMMC_OVERLAY_NAME=rockpi4 \
EMMC_OVERLAY_IMAGE=docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-pcie1 \
hack/build-rockpi-installer.sh
```

### Suggested approach and confidence

- **Recommended:** push only the custom `kernel`, `installer-base`, `imager`, and
  `installer` images. Confidence: **high**.
- **Recommended for this host:** keep the imager `linux/amd64` and set
  `INSTALLER_ARCH=arm64`. Confidence: **medium-high** because it avoids normal
  Docker arm64 runtime issues.
- **Do not run `make push` for Talos unless you need every Talos image.** It is
  much slower and builds/pushes unrelated artifacts. Confidence: **high**.
- Hardware outcome confidence is **medium** until the RockPI is tested, because
  PCIe SATA detection can also depend on device-tree, power/reset timing, or
  controller-specific behavior.

## Resources

- https://gcc.gnu.org/onlinedocs/gccint/Configure-Terms.html
- https://wiki.osdev.org/Target_Triplet
