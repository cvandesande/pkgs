#!/usr/bin/env bash
set -euo pipefail

# Build and publish a RockPI/RK3399 Talos installer with the patched kernel
# from this pkgs checkout, and produce an eMMC-flashable RockPi SBC image.
#
# Defaults match the local RockPI PCIe compatibility workflow. Override any of these
# values in the environment, for example:
#
#   CUSTOM_TAG=v1.13.4-rockpi-pcie-perst1 hack/build-rockpi-installer.sh
#
# Optional skips for resuming after a failed later step:
#
#   BUILD_KERNEL=false BUILD_INSTALLER_BASE=false hack/build-rockpi-installer.sh
#
# The eMMC image is written under:
#
#   ${PKGS_DIR}/artifacts/rockpi/${CUSTOM_TAG}/

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKGS_DIR="${PKGS_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
TALOS_DIR="${TALOS_DIR:-/home/cvandesande/github/talos-v1.13.4-rockpi}"

TALOS_TAG="${TALOS_TAG:-v1.13.4}"
CUSTOM_TAG="${CUSTOM_TAG:-v1.13.4-rockpi-pcie-perst1}"

if [[ "${CUSTOM_TAG}" == "${TALOS_TAG}"* ]]; then
  DEFAULT_TAG_SUFFIX="${CUSTOM_TAG#"${TALOS_TAG}"}"
else
  DEFAULT_TAG_SUFFIX="-${CUSTOM_TAG}"
fi

TAG_SUFFIX="${TAG_SUFFIX:-${DEFAULT_TAG_SUFFIX}}"

GITLAB_REGISTRY="${GITLAB_REGISTRY:-registry.gitlab.com}"
GITLAB_USERNAME="${GITLAB_USERNAME:-cvandesande/dockers/talos-rockpi}"
DOCKERHUB_REPO="${DOCKERHUB_REPO:-docker.io/cvandesande/talos}"
DOCKERHUB_INSTALLER="${DOCKERHUB_INSTALLER:-${DOCKERHUB_REPO}:${CUSTOM_TAG}}"

INSTALLER_ARCH="${INSTALLER_ARCH:-arm64}"
KERNEL_PLATFORM="${KERNEL_PLATFORM:-linux/arm64}"
INSTALLER_BASE_PLATFORM="${INSTALLER_BASE_PLATFORM:-linux/arm64}"
IMAGER_PLATFORM="${IMAGER_PLATFORM:-linux/amd64}"
INSTALLER_PLATFORM="${INSTALLER_PLATFORM:-linux/arm64}"
EMMC_IMAGE_PLATFORM="${EMMC_IMAGE_PLATFORM:-linux/arm64}"
PROGRESS="${PROGRESS:-plain}"

BUILD_KERNEL="${BUILD_KERNEL:-true}"
BUILD_INSTALLER_BASE="${BUILD_INSTALLER_BASE:-true}"
BUILD_IMAGER="${BUILD_IMAGER:-true}"
BUILD_INSTALLER="${BUILD_INSTALLER:-true}"
BUILD_EMMC_IMAGE="${BUILD_EMMC_IMAGE:-true}"
RUN_EMMC_IMAGE_TARGET="${RUN_EMMC_IMAGE_TARGET:-${RUN_IMAGE_METAL:-true}}"
EMMC_IMAGE_PROFILE="${EMMC_IMAGE_PROFILE:-rockpi4}"
DECOMPRESS_EMMC_IMAGE="${DECOMPRESS_EMMC_IMAGE:-true}"
COPY_TO_DOCKERHUB="${COPY_TO_DOCKERHUB:-true}"
PATCH_TALOS_MAKEFILE="${PATCH_TALOS_MAKEFILE:-true}"
VERIFY_ROCKPI_BOOTLOADER="${VERIFY_ROCKPI_BOOTLOADER:-true}"
VERIFY_ROCKPI_UBOOT_DTB="${VERIFY_ROCKPI_UBOOT_DTB:-true}"
PATCH_ROCKPI_UBOOT_DTB="${PATCH_ROCKPI_UBOOT_DTB:-false}"
RECOMPRESS_EMMC_IMAGE_AFTER_PATCH="${RECOMPRESS_EMMC_IMAGE_AFTER_PATCH:-true}"

PKG_KERNEL="${PKG_KERNEL:-${GITLAB_REGISTRY}/${GITLAB_USERNAME}/kernel:${CUSTOM_TAG}}"
EMMC_IMAGE_DEST_DIR="${EMMC_IMAGE_DEST_DIR:-${PKGS_DIR}/artifacts/rockpi/${CUSTOM_TAG}}"
EMMC_IMAGE_TARGET="${EMMC_IMAGE_TARGET:-rockpi_4}"
EMMC_OVERLAY_NAME="${EMMC_OVERLAY_NAME:-rockpi4}"
EMMC_OVERLAY_IMAGE="${EMMC_OVERLAY_IMAGE:-docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-pcie1}"
EMMC_IMAGE_BASENAME="${EMMC_IMAGE_BASENAME:-talos-${CUSTOM_TAG}-${EMMC_IMAGE_TARGET}}"
EMMC_IMAGE_DOCKER_USER="${EMMC_IMAGE_DOCKER_USER:-0:0}"

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  local cmd="$1"
  if ! command -v "${cmd}" >/dev/null 2>&1; then
    echo "missing required command: ${cmd}" >&2
    exit 1
  fi
}

bool_enabled() {
  case "${1}" in
    1|true|TRUE|yes|YES|y|Y) return 0 ;;
    0|false|FALSE|no|NO|n|N) return 1 ;;
    *)
      echo "invalid boolean value: ${1}" >&2
      exit 1
      ;;
  esac
}

platform_arch() {
  local platform="$1"

  case "${platform}" in
    linux/*)
      basename "${platform}"
      ;;
    *)
      echo "unsupported platform format for eMMC image: ${platform}" >&2
      exit 1
      ;;
  esac
}

decompress_image() {
  local src="$1"
  local dst="$2"

  case "${src}" in
    *.zst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -f -d -o "${dst}" "${src}"
        return 0
      fi

      if command -v unzstd >/dev/null 2>&1; then
        unzstd -f -c "${src}" >"${dst}"
        return 0
      fi

      echo "missing zstd/unzstd; install zstd or set DECOMPRESS_EMMC_IMAGE=false" >&2
      exit 1
      ;;
    *.xz)
      if command -v xz >/dev/null 2>&1; then
        xz -f -d -c "${src}" >"${dst}"
        return 0
      fi

      if command -v unxz >/dev/null 2>&1; then
        unxz -f -c "${src}" >"${dst}"
        return 0
      fi

      echo "missing xz/unxz; install xz-utils or set DECOMPRESS_EMMC_IMAGE=false" >&2
      exit 1
      ;;
    *)
      echo "unsupported compressed eMMC image format: ${src}" >&2
      exit 1
      ;;
  esac
}

compress_image() {
  local src="$1"
  local dst="$2"
  local tmp="${dst}.tmp"

  case "${dst}" in
    *.zst)
      if command -v zstd >/dev/null 2>&1; then
        zstd -f -T0 -o "${tmp}" "${src}"
        mv -f "${tmp}" "${dst}"
        return 0
      fi

      echo "missing zstd; install zstd or set RECOMPRESS_EMMC_IMAGE_AFTER_PATCH=false" >&2
      exit 1
      ;;
    *.xz)
      if command -v xz >/dev/null 2>&1; then
        xz -T0 -c "${src}" >"${tmp}"
        mv -f "${tmp}" "${dst}"
        return 0
      fi

      echo "missing xz; install xz-utils or set RECOMPRESS_EMMC_IMAGE_AFTER_PATCH=false" >&2
      exit 1
      ;;
    *)
      echo "unsupported compressed eMMC image format: ${dst}" >&2
      exit 1
      ;;
  esac
}

talos_make() {
  (
    cd "${TALOS_DIR}"
    make "$@"
  )
}

find_talos_artifact() {
  local relpath="$1"
  local candidate

  # Preferred path when Talos make runs from TALOS_DIR.
  candidate="${TALOS_DIR}/_out/${relpath}"
  if [[ -s "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  # Compatibility path for older script versions which used `make -C` while
  # Talos' Makefile mounted $(PWD)/_out into the imager container.
  candidate="${PKGS_DIR}/_out/${relpath}"
  if [[ -s "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

find_talos_artifact_in_dir() {
  local dir="$1"
  local relpath="$2"
  local candidate="${dir}/${relpath}"

  if [[ -s "${candidate}" ]]; then
    printf '%s\n' "${candidate}"
    return 0
  fi

  return 1
}

find_emmc_source_image() {
  local arch="$1"
  local target="$2"
  local profile="$3"
  local dir relpath

  # Search by output directory first so a fresh Talos build artifact wins over
  # stale compatibility artifacts left behind under pkgs/_out by older script
  # versions or root/nobody-owned Docker output.
  for dir in "${TALOS_DIR}/_out" "${PKGS_DIR}/_out"; do
    for relpath in \
      "${target}-${arch}.raw.xz" \
      "${target}-${arch}.raw.zst" \
      "${profile}-${arch}.raw.xz" \
      "${profile}-${arch}.raw.zst" \
      "metal-${arch}.raw.xz" \
      "metal-${arch}.raw.zst"; do
      if find_talos_artifact_in_dir "${dir}" "${relpath}"; then
        return 0
      fi
    done
  done

  return 1
}

remove_emmc_source_candidates() {
  local arch="$1"
  local target="$2"
  local profile="$3"
  local relpath dir

  for dir in "${TALOS_DIR}/_out" "${PKGS_DIR}/_out"; do
    for relpath in \
      "${target}-${arch}.raw" \
      "${target}-${arch}.raw.zst" \
      "${target}-${arch}.raw.xz" \
      "${profile}-${arch}.raw" \
      "${profile}-${arch}.raw.zst" \
      "${profile}-${arch}.raw.xz" \
      "metal-${arch}.raw" \
      "metal-${arch}.raw.zst" \
      "metal-${arch}.raw.xz"; do
      rm -f "${dir}/${relpath}" 2>/dev/null || true
    done
  done
}

verify_rockpi_bootloader_image() {
  local raw_image="$1"

  python3 - "${raw_image}" <<'PY'
from pathlib import Path
import struct
import sys

raw = Path(sys.argv[1])
if not raw.is_file() or raw.stat().st_size == 0:
    raise SystemExit(f"missing or empty raw image: {raw}")

with raw.open("rb") as f:
    data = f.read(12 * 1024 * 1024)

if len(data) < 2048 * 512:
    raise SystemExit(f"raw image is too small to validate Rockchip boot area: {raw}")

hdr = data[512:1024]
if hdr[:8] != b"EFI PART":
    raise SystemExit(f"raw image does not have a GPT header at LBA1: {raw}")

part_lba = struct.unpack_from("<Q", hdr, 72)[0]
num_parts = struct.unpack_from("<I", hdr, 80)[0]
entry_size = struct.unpack_from("<I", hdr, 84)[0]

first_lba = None
for idx in range(min(num_parts, 128)):
    off = part_lba * 512 + idx * entry_size
    ent = data[off:off + entry_size]
    if len(ent) < entry_size:
        break
    if any(ent[:16]):
        first_lba = struct.unpack_from("<Q", ent, 32)[0]
        break

if first_lba is None:
    raise SystemExit(f"raw image GPT contains no partitions: {raw}")

# The Rockchip RK3399 SPL/U-Boot blob is written into the gap before the first
# partition, starting around LBA64. The sbc-rockchip rockpi4 overlay also asks
# the Talos imager to skip 20480 LBAs before normal partitions.
boot_gap_start = 64 * 512
boot_gap_end = min(first_lba * 512, len(data))
boot_gap = data[boot_gap_start:boot_gap_end]
nonzero = sum(1 for byte in boot_gap if byte)

if first_lba < 20480:
    raise SystemExit(
        f"RockPi image first partition starts at LBA {first_lba}; expected >= 20480 "
        "so the Rockchip loader has reserved space"
    )

if nonzero == 0:
    raise SystemExit(
        "RockPi image has no non-zero Rockchip bootloader bytes between LBA64 "
        f"and first partition LBA {first_lba}; do not flash it"
    )

print(
    f"RockPi bootloader check passed: first_partition_lba={first_lba}, "
    f"nonzero_boot_gap_bytes={nonzero}"
)
PY
}

ensure_crane() {
  if command -v crane >/dev/null 2>&1; then
    return 0
  fi

  log "crane not found; creating temporary Docker-backed crane wrapper"
  mkdir -p /tmp/talos-build-bin
  cat >/tmp/talos-build-bin/crane <<'EOF'
#!/usr/bin/env sh
set -eu
docker run --rm \
  --user "$(id -u):$(id -g)" \
  -v "$HOME/.docker:/tmp/.docker:ro" \
  -e DOCKER_CONFIG=/tmp/.docker \
  -v "$PWD:$PWD" \
  -w "$PWD" \
  gcr.io/go-containerregistry/crane "$@"
EOF
  chmod +x /tmp/talos-build-bin/crane
  export PATH="/tmp/talos-build-bin:${PATH}"
}

ensure_talos_makefile_image_patches() {
  local makefile="${TALOS_DIR}/Makefile"

  log "Patching Talos Makefile image container invocation if needed"
  python3 - "${makefile}" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

changed = False

auth_needle = "\t\t\t-v $(PWD)/$(ARTIFACTS):/out \\\n"
auth_insert = (
    "\t\t\t-v $(PWD)/$(ARTIFACTS):/out \\\n"
    "\t\t\t-v $$HOME/.docker:/tmp/.docker:ro \\\n"
    "\t\t\t-e DOCKER_CONFIG=/tmp/.docker \\\n"
)

if "-e DOCKER_CONFIG=/tmp/.docker" not in text:
    if auth_needle not in text:
        raise SystemExit(
            "could not find expected image-% docker-run mount block in Talos Makefile"
        )
    text = text.replace(auth_needle, auth_insert, 1)
    changed = True

user_old = "\t\t\t--user $(shell id -u):$(shell id -g) \\\n"
user_new = "\t\t\t$(if $(IMAGE_DOCKER_USER),--user $(IMAGE_DOCKER_USER),--user $(shell id -u):$(shell id -g)) \\\n"

if "IMAGE_DOCKER_USER" not in text:
    if user_old not in text:
        raise SystemExit(
            "could not find expected image-% docker-run user line in Talos Makefile"
        )
    text = text.replace(user_old, user_new, 1)
    changed = True

if changed:
    path.write_text(text)
PY
}

require_cmd docker
require_cmd make
require_cmd git
require_cmd python3
require_cmd sha256sum

if [[ ! -d "${PKGS_DIR}" ]]; then
  echo "PKGS_DIR does not exist: ${PKGS_DIR}" >&2
  exit 1
fi

if [[ ! -f "${PKGS_DIR}/Makefile" ]]; then
  echo "PKGS_DIR does not look like the pkgs repo: ${PKGS_DIR}" >&2
  exit 1
fi

if [[ ! -d "${TALOS_DIR}" || ! -f "${TALOS_DIR}/Makefile" ]]; then
  echo "TALOS_DIR does not look like the Talos checkout: ${TALOS_DIR}" >&2
  exit 1
fi

ensure_crane

log "Build configuration"
cat <<EOF
PKGS_DIR=${PKGS_DIR}
TALOS_DIR=${TALOS_DIR}
TALOS_TAG=${TALOS_TAG}
CUSTOM_TAG=${CUSTOM_TAG}
TAG_SUFFIX=${TAG_SUFFIX}
PKG_KERNEL=${PKG_KERNEL}
GitLab registry/user=${GITLAB_REGISTRY}/${GITLAB_USERNAME}
Docker Hub installer=${DOCKERHUB_INSTALLER}
Build eMMC image=${BUILD_EMMC_IMAGE}
eMMC image target=${EMMC_IMAGE_TARGET}
eMMC image base profile=${EMMC_IMAGE_PROFILE}
eMMC overlay name=${EMMC_OVERLAY_NAME}
eMMC overlay image=${EMMC_OVERLAY_IMAGE}
Run Talos eMMC image target=${RUN_EMMC_IMAGE_TARGET}
eMMC image output=${EMMC_IMAGE_DEST_DIR}
eMMC image Docker user=${EMMC_IMAGE_DOCKER_USER}
Verify RockPi bootloader=${VERIFY_ROCKPI_BOOTLOADER}
Verify RockPi U-Boot DTB=${VERIFY_ROCKPI_UBOOT_DTB}
Patch RockPi U-Boot DTB=${PATCH_ROCKPI_UBOOT_DTB}
Recompress eMMC image after DTB patch=${RECOMPRESS_EMMC_IMAGE_AFTER_PATCH}
EOF

if bool_enabled "${PATCH_TALOS_MAKEFILE}"; then
  ensure_talos_makefile_image_patches
fi

if bool_enabled "${BUILD_KERNEL}"; then
  log "Building and pushing patched kernel package"
  make -C "${PKGS_DIR}" kernel \
    PLATFORM="${KERNEL_PLATFORM}" \
    REGISTRY="${GITLAB_REGISTRY}" \
    USERNAME="${GITLAB_USERNAME}" \
    TAG="${CUSTOM_TAG}" \
    PUSH=true \
    PROGRESS="${PROGRESS}"
else
  log "Skipping kernel package build because BUILD_KERNEL=${BUILD_KERNEL}"
fi

export REGISTRY="${GITLAB_REGISTRY}"
export USERNAME="${GITLAB_USERNAME}"
export TAG="${TALOS_TAG}"
export TAG_SUFFIX
export PKG_KERNEL

if bool_enabled "${BUILD_INSTALLER_BASE}"; then
  log "Building and pushing Talos installer-base"
  talos_make installer-base \
    PLATFORM="${INSTALLER_BASE_PLATFORM}" \
    PUSH=true \
    PROGRESS="${PROGRESS}"
else
  log "Skipping installer-base because BUILD_INSTALLER_BASE=${BUILD_INSTALLER_BASE}"
fi

if bool_enabled "${BUILD_IMAGER}"; then
  log "Building and pushing Talos imager"
  talos_make imager \
    PLATFORM="${IMAGER_PLATFORM}" \
    INSTALLER_ARCH="${INSTALLER_ARCH}" \
    PKG_KERNEL="${PKG_KERNEL}" \
    PUSH=true \
    PROGRESS="${PROGRESS}"
else
  log "Skipping imager because BUILD_IMAGER=${BUILD_IMAGER}"
fi

if bool_enabled "${BUILD_INSTALLER}"; then
  log "Building Talos installer image"
  talos_make installer \
    PLATFORM="${INSTALLER_PLATFORM}" \
    PROGRESS="${PROGRESS}"
else
  log "Skipping installer because BUILD_INSTALLER=${BUILD_INSTALLER}"
fi

GITLAB_INSTALLER=""
GITLAB_INSTALLER_FILE=""
if GITLAB_INSTALLER_FILE="$(find_talos_artifact installer_image)"; then
  GITLAB_INSTALLER="$(cat "${GITLAB_INSTALLER_FILE}")"
fi

if bool_enabled "${COPY_TO_DOCKERHUB}"; then
  if [[ -z "${GITLAB_INSTALLER}" ]]; then
    echo "installer image file not found in ${TALOS_DIR}/_out or ${PKGS_DIR}/_out" >&2
    exit 1
  fi

  log "Copying private GitLab installer to public Docker Hub"
  crane copy "${GITLAB_INSTALLER}" "${DOCKERHUB_INSTALLER}"
else
  log "Skipping Docker Hub copy because COPY_TO_DOCKERHUB=${COPY_TO_DOCKERHUB}"
fi

EMMC_COMPRESSED_IMAGE=""
EMMC_RAW_IMAGE=""

if bool_enabled "${BUILD_EMMC_IMAGE}"; then
  EMMC_ARCH="$(platform_arch "${EMMC_IMAGE_PLATFORM}")"
  EMMC_RAW_IMAGE="${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw"

  if bool_enabled "${RUN_EMMC_IMAGE_TARGET}"; then
    log "Building Talos ${EMMC_IMAGE_TARGET} eMMC image via ${EMMC_IMAGE_PROFILE} + ${EMMC_OVERLAY_NAME} overlay"
    remove_emmc_source_candidates "${EMMC_ARCH}" "${EMMC_IMAGE_TARGET}" "${EMMC_IMAGE_PROFILE}"
    talos_make "image-${EMMC_IMAGE_PROFILE}" \
      PLATFORM="${EMMC_IMAGE_PLATFORM}" \
      IMAGE_DOCKER_USER="${EMMC_IMAGE_DOCKER_USER}" \
      IMAGER_ARGS="--overlay-name ${EMMC_OVERLAY_NAME} --overlay-image ${EMMC_OVERLAY_IMAGE} ${IMAGER_ARGS:-}" \
      PROGRESS="${PROGRESS}"
  else
    log "Skipping Talos image-${EMMC_IMAGE_PROFILE} because RUN_EMMC_IMAGE_TARGET=${RUN_EMMC_IMAGE_TARGET}; using existing artifact"
  fi

  if ! EMMC_SOURCE_COMPRESSED="$(find_emmc_source_image "${EMMC_ARCH}" "${EMMC_IMAGE_TARGET}" "${EMMC_IMAGE_PROFILE}")"; then
    echo "expected eMMC source image not found or empty in ${TALOS_DIR}/_out or ${PKGS_DIR}/_out; tried ${EMMC_IMAGE_TARGET}-${EMMC_ARCH}.raw.{xz,zst}, ${EMMC_IMAGE_PROFILE}-${EMMC_ARCH}.raw.{xz,zst}, and metal-${EMMC_ARCH}.raw.{xz,zst}" >&2
    exit 1
  fi

  log "Using eMMC source image ${EMMC_SOURCE_COMPRESSED}"

  case "${EMMC_SOURCE_COMPRESSED}" in
    *.raw.zst) EMMC_COMPRESSED_IMAGE="${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.zst" ;;
    *.raw.xz) EMMC_COMPRESSED_IMAGE="${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.xz" ;;
    *)
      echo "unsupported eMMC source image name: ${EMMC_SOURCE_COMPRESSED}" >&2
      exit 1
      ;;
  esac

  mkdir -p "${EMMC_IMAGE_DEST_DIR}"
  rm -f \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw" \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.sha256" \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.zst" \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.zst.sha256" \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.xz" \
    "${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw.xz.sha256"

  cp -f "${EMMC_SOURCE_COMPRESSED}" "${EMMC_COMPRESSED_IMAGE}"

  if bool_enabled "${DECOMPRESS_EMMC_IMAGE}"; then
    log "Expanding compressed eMMC image to writable raw image"
    decompress_image "${EMMC_COMPRESSED_IMAGE}" "${EMMC_RAW_IMAGE}"
    chmod u+w "${EMMC_RAW_IMAGE}"

    if bool_enabled "${PATCH_ROCKPI_UBOOT_DTB}"; then
      log "WARNING: post-build binary DTB patching is enabled"
      log "Prefer a source-patched sbc-rockchip overlay; generated U-Boot blobs may include FIT hashes"
      log "Patching RockPi U-Boot-provided DTB inside raw eMMC image"
      python3 "${SCRIPT_DIR}/patch-rockpi-uboot-dtb.py" --require-patch "${EMMC_RAW_IMAGE}"

      if bool_enabled "${RECOMPRESS_EMMC_IMAGE_AFTER_PATCH}"; then
        log "Recompressing patched eMMC raw image"
        compress_image "${EMMC_RAW_IMAGE}" "${EMMC_COMPRESSED_IMAGE}"
      else
        log "Skipping compressed artifact refresh because RECOMPRESS_EMMC_IMAGE_AFTER_PATCH=${RECOMPRESS_EMMC_IMAGE_AFTER_PATCH}"
      fi
    fi

    if bool_enabled "${VERIFY_ROCKPI_UBOOT_DTB}"; then
      log "Verifying RockPi U-Boot-provided DTB PCIe properties"
      python3 "${SCRIPT_DIR}/patch-rockpi-uboot-dtb.py" --verify-only "${EMMC_RAW_IMAGE}"
    fi

    sha256sum "${EMMC_COMPRESSED_IMAGE}" >"${EMMC_COMPRESSED_IMAGE}.sha256"
    sha256sum "${EMMC_RAW_IMAGE}" >"${EMMC_RAW_IMAGE}.sha256"

    if bool_enabled "${VERIFY_ROCKPI_BOOTLOADER}"; then
      log "Verifying RockPi/Rockchip bootloader area in raw eMMC image"
      verify_rockpi_bootloader_image "${EMMC_RAW_IMAGE}"
    fi
  else
    if bool_enabled "${PATCH_ROCKPI_UBOOT_DTB}" || bool_enabled "${VERIFY_ROCKPI_UBOOT_DTB}"; then
      echo "PATCH_ROCKPI_UBOOT_DTB=true or VERIFY_ROCKPI_UBOOT_DTB=true requires DECOMPRESS_EMMC_IMAGE=true so the raw image can be inspected" >&2
      exit 1
    fi

    sha256sum "${EMMC_COMPRESSED_IMAGE}" >"${EMMC_COMPRESSED_IMAGE}.sha256"
    EMMC_RAW_IMAGE=""
    log "Skipping raw eMMC expansion because DECOMPRESS_EMMC_IMAGE=${DECOMPRESS_EMMC_IMAGE}"
  fi
else
  log "Skipping eMMC image because BUILD_EMMC_IMAGE=${BUILD_EMMC_IMAGE}"
fi

log "Done"
cat <<EOF
Private GitLab installer:
  ${GITLAB_INSTALLER}

Public Docker Hub installer:
  ${DOCKERHUB_INSTALLER}

eMMC image artifacts:
  compressed: ${EMMC_COMPRESSED_IMAGE:-not built}
  raw:        ${EMMC_RAW_IMAGE:-not built}
EOF

if [[ -n "${EMMC_RAW_IMAGE}" ]]; then
  cat <<EOF
Flash the raw eMMC image only after verifying the target device with lsblk.
Example, replacing /dev/sdX with the eMMC adapter device:
  sudo dd if="${EMMC_RAW_IMAGE}" of=/dev/sdX bs=4M conv=fsync status=progress
EOF
elif [[ -n "${EMMC_COMPRESSED_IMAGE}" ]]; then
  cat <<EOF
The compressed eMMC image was built, but raw expansion was skipped.
Expand it before flashing, for example:
  case "${EMMC_COMPRESSED_IMAGE}" in
    *.zst) zstd -d -o "${EMMC_COMPRESSED_IMAGE%.zst}" "${EMMC_COMPRESSED_IMAGE}" ;;
    *.xz)  xz -d -c "${EMMC_COMPRESSED_IMAGE}" > "${EMMC_COMPRESSED_IMAGE%.xz}" ;;
  esac
EOF
fi

cat <<EOF
Upgrade command:
  export TALOSCONFIG=/home/cvandesande/dockers/talos/tirnanog/generated/talosconfig
  talosctl -e whiterock -n whiterock upgrade --image ${DOCKERHUB_INSTALLER}

After reboot, collect PCIe status:
  talosctl -e whiterock -n whiterock dmesg | grep -E 'rockchip-pcie|PCIe link|pcie-phy|bus scan'
EOF
