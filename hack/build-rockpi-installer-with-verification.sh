#!/usr/bin/env bash
set -xeuo pipefail

# Build and publish a RockPI/RK3399 Talos installer with the patched kernel
# and matching ZFS system extension from this pkgs checkout, and produce an
# eMMC-flashable RockPi SBC image.
#
# Talos' kernel build generates a module-signing key automatically. Building
# kernel and zfs-pkg in one invocation makes both consume the same cached
# kernel-build stage: the public key is embedded in the kernel and the ZFS
# modules are signed with the matching private key. This is module signing,
# not Secure Boot kernel/EFI signing.
#
# Defaults match the local RockPI PCIe compatibility workflow. Override any of these
# values in the environment, for example:
#
#   CUSTOM_TAG=v1.13.4-rockpi-pcie-min-only0012-1 hack/build-rockpi-installer.sh
#
# Optional skips for resuming after a failed later step:
#
#   BUILD_KERNEL=false BUILD_ZFS_PKG=false BUILD_ZFS_EXTENSION=false \
#     BUILD_INSTALLER_BASE=false hack/build-rockpi-installer.sh
#
# The eMMC image is written under:
#
#   ${PKGS_DIR}/artifacts/rockpi/${CUSTOM_TAG}/

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKGS_DIR="${PKGS_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
TALOS_DIR="${TALOS_DIR:-/home/cvandesande/github/talos-v1.13.4-rockpi}"

TALOS_TAG="${TALOS_TAG:-v1.13.4}"
CUSTOM_TAG="${CUSTOM_TAG:-v1.13.4-rockpi-pcie-min-only0012-1}"

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
BUILD_ZFS_PKG="${BUILD_ZFS_PKG:-true}"
BUILD_ZFS_EXTENSION="${BUILD_ZFS_EXTENSION:-true}"
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
# patch-rockpi-uboot-dtb.py's verify-only mode asserts the legacy 0006-style
# properties (vpcie12v-supply, bus-scan-delay-ms, regulator min/max). The
# default EMMC_OVERLAY_IMAGE (penta-gen2-1) deliberately omits those —
# hardware-confirmed working without them, see
# docs/rockpi-pcie-penta-history.md. Only set this true if deliberately using
# an old overlay image that still bakes those properties into U-Boot source.
VERIFY_ROCKPI_UBOOT_DTB="${VERIFY_ROCKPI_UBOOT_DTB:-false}"
PATCH_ROCKPI_UBOOT_DTB="${PATCH_ROCKPI_UBOOT_DTB:-false}"
RECOMPRESS_EMMC_IMAGE_AFTER_PATCH="${RECOMPRESS_EMMC_IMAGE_AFTER_PATCH:-true}"
VERIFY_ZFS_EXTENSION="${VERIFY_ZFS_EXTENSION:-true}"
VERIFY_ZFS_PKG_EXTENSION_MATCH="${VERIFY_ZFS_PKG_EXTENSION_MATCH:-true}"
VERIFY_CUSTOM_KERNEL_IMAGE="${VERIFY_CUSTOM_KERNEL_IMAGE:-true}"
VERIFY_INSTALLER_KERNEL="${VERIFY_INSTALLER_KERNEL:-true}"
VERIFY_DOCKERHUB_INSTALLER_KERNEL="${VERIFY_DOCKERHUB_INSTALLER_KERNEL:-true}"
VERIFY_EMMC_KERNEL="${VERIFY_EMMC_KERNEL:-true}"

PKG_KERNEL="${PKG_KERNEL:-${GITLAB_REGISTRY}/${GITLAB_USERNAME}/kernel:${CUSTOM_TAG}}"
PKG_ZFS="${PKG_ZFS:-${GITLAB_REGISTRY}/${GITLAB_USERNAME}/zfs-pkg:${CUSTOM_TAG}}"
EXTENSIONS_TAG="${EXTENSIONS_TAG:-${TALOS_TAG}}"
EXTENSIONS_DIR="${EXTENSIONS_DIR:-${PKGS_DIR}/_out/talos-extensions-${EXTENSIONS_TAG}}"
EXTENSIONS_REPOSITORY="${EXTENSIONS_REPOSITORY:-https://github.com/siderolabs/extensions.git}"
ZFS_EXTENSION_REPOSITORY="${ZFS_EXTENSION_REPOSITORY:-${GITLAB_REGISTRY}/${GITLAB_USERNAME}/zfs}"
ZFS_EXTENSION_IMAGE="${ZFS_EXTENSION_IMAGE:-}"
EMMC_IMAGE_DEST_DIR="${EMMC_IMAGE_DEST_DIR:-${PKGS_DIR}/artifacts/rockpi/${CUSTOM_TAG}}"
EMMC_IMAGE_TARGET="${EMMC_IMAGE_TARGET:-rockpi_4}"
EMMC_OVERLAY_NAME="${EMMC_OVERLAY_NAME:-rockpi4}"
EMMC_OVERLAY_IMAGE="${EMMC_OVERLAY_IMAGE:-docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-penta-gen2-1}"
EMMC_IMAGE_BASENAME="${EMMC_IMAGE_BASENAME:-talos-${CUSTOM_TAG}-${EMMC_IMAGE_TARGET}}"
EMMC_IMAGE_DOCKER_USER="${EMMC_IMAGE_DOCKER_USER:-0:0}"
VERIFY_DIR="${VERIFY_DIR:-${PKGS_DIR}/artifacts/rockpi/${CUSTOM_TAG}/verification}"
CUSTOM_KERNEL_VMLINUZ="${CUSTOM_KERNEL_VMLINUZ:-${VERIFY_DIR}/custom-vmlinuz}"


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
    1 | true | TRUE | yes | YES | y | Y) return 0 ;;
    0 | false | FALSE | no | NO | n | N) return 1 ;;
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

# The Rock Pi 4A/RK3399 is arm64-only. IMAGER_PLATFORM is deliberately exempt:
# the imager *tool* container itself runs on the build host (amd64 here) and
# cross-produces arm64 artifacts via --arch, it does not need to match the
# target board architecture.
ROCKPI_TARGET_PLATFORM="${ROCKPI_TARGET_PLATFORM:-linux/arm64}"

assert_rockpi_arm64_platform() {
    local name value
    local mismatched=()

    for name in KERNEL_PLATFORM INSTALLER_BASE_PLATFORM INSTALLER_PLATFORM EMMC_IMAGE_PLATFORM; do
        value="${!name}"
        if [[ "${value}" != "${ROCKPI_TARGET_PLATFORM}" ]]; then
            mismatched+=("${name}=${value}")
        fi
    done

    if [[ "${INSTALLER_ARCH}" != "$(platform_arch "${ROCKPI_TARGET_PLATFORM}")" ]]; then
        mismatched+=("INSTALLER_ARCH=${INSTALLER_ARCH}")
    fi

    if ((${#mismatched[@]} > 0)); then
        echo "Refusing to build: the Rock Pi 4A target is ${ROCKPI_TARGET_PLATFORM}, but found a mismatched platform/arch variable: ${mismatched[*]}" >&2
        echo "If you intentionally want a different target, override ROCKPI_TARGET_PLATFORM too." >&2
        exit 1
    fi
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

ensure_extensions_checkout() {
    local expected_commit actual_commit

    if [[ ! -d "${EXTENSIONS_DIR}/.git" ]]; then
        log "Cloning Talos extensions ${EXTENSIONS_TAG}"
        mkdir -p "$(dirname -- "${EXTENSIONS_DIR}")"
        git clone --depth 1 --branch "${EXTENSIONS_TAG}" \
            "${EXTENSIONS_REPOSITORY}" "${EXTENSIONS_DIR}"
    fi

    if [[ -n "$(git -C "${EXTENSIONS_DIR}" status --porcelain)" ]]; then
        echo "Talos extensions checkout is dirty: ${EXTENSIONS_DIR}" >&2
        echo "Refusing to build an extension from uncommitted source." >&2
        exit 1
    fi

    if ! expected_commit="$(git -C "${EXTENSIONS_DIR}" rev-parse "refs/tags/${EXTENSIONS_TAG}^{commit}" 2>/dev/null)"; then
        echo "Talos extensions checkout does not contain tag ${EXTENSIONS_TAG}: ${EXTENSIONS_DIR}" >&2
        exit 1
    fi

    actual_commit="$(git -C "${EXTENSIONS_DIR}" rev-parse HEAD)"
    if [[ "${actual_commit}" != "${expected_commit}" ]]; then
        echo "Talos extensions checkout is not at ${EXTENSIONS_TAG}: ${EXTENSIONS_DIR}" >&2
        echo "expected ${expected_commit}, got ${actual_commit}" >&2
        exit 1
    fi
}

zfs_extension_version() {
    awk '
    $1 == "ZFS_DRIVER_VERSION:" {
      print $2
      found = 1
      exit
    }
    END {
      if (!found) {
        exit 1
      }
    }
  ' "${EXTENSIONS_DIR}/Pkgfile"
}

verify_zfs_extension_image() {
    local image="$1"
    local platform="$2"

    log "Verifying ZFS extension contains signed kernel modules"
    crane export --platform="${platform}" "${image}" - | python3 -c '
import sys
import tarfile

archive = tarfile.open(fileobj=sys.stdin.buffer, mode="r|*")
modules = []
unsigned = []

for member in archive:
    if not member.isfile() or not member.name.endswith(".ko"):
        continue

    modules.append(member.name)
    extracted = archive.extractfile(member)
    if extracted is None or b"~Module signature appended~" not in extracted.read():
        unsigned.append(member.name)

if not modules:
    raise SystemExit("ZFS extension contains no .ko kernel modules")

if unsigned:
    raise SystemExit("unsigned ZFS modules: " + ", ".join(unsigned))

print(f"ZFS module signature check passed: {len(modules)} signed modules")
'
}

image_digest() {
    local image="$1"
    crane digest "${image}"
}

pinned_image_ref() {
    local image="$1"
    local digest="$2"
    printf '%s@%s\n' "${image%@*}" "${digest}"
}

extract_vmlinuz_from_image() {
    local image="$1"
    local dst="$2"
    local platform="$3"

    mkdir -p "$(dirname -- "${dst}")"
    rm -f "${dst}"

    log "Extracting custom kernel from ${image}"
    crane export --platform="${platform}" "${image}" - | python3 -c '
import sys
import tarfile
from pathlib import Path

out = Path(sys.argv[1])
archive = tarfile.open(fileobj=sys.stdin.buffer, mode="r|*")

for member in archive:
    if not member.isfile():
        continue

    name = member.name.lstrip("./")
    base = name.rsplit("/", 1)[-1]
    if not (base.startswith("vmlinuz") or base.endswith(".linux") or name.endswith("/kernel")):
        continue

    extracted = archive.extractfile(member)
    if extracted is None:
        continue
    data = extracted.read()
    out.write_bytes(data)
    print(f"extracted {member.name} ({len(data)} bytes) to {out}")
    break
else:
    raise SystemExit("no vmlinuz-like file found in image export")

# Drain the rest of the tar stream so the upstream `crane export` process
# does not get SIGPIPE/EPIPE from an early-closed stdin under pipefail.
while sys.stdin.buffer.read(1 << 20):
    pass
' "${dst}"

    test -s "${dst}" || {
        echo "failed to extract custom vmlinuz from ${image}" >&2
        exit 1
    }

    assert_arm64_kernel_image "${dst}"
    sha256sum "${dst}" | tee "${dst}.sha256"
}

assert_arm64_kernel_image() {
    local kernel_image="$1"

    # Talos builds arm64 kernels as a PE32+/EFI-stub image (`file` reports
    # "PE32+ executable for EFI (application), ARM64"). Its PE header Machine
    # field must be IMAGE_FILE_MACHINE_ARM64 (0xaa64). Fall back to the plain
    # Linux arm64 boot image magic 0x644d5241 ("ARM\x64") at offset 0x38 (see
    # Documentation/arm64/booting.rst) in case a non-EFI-stub kernel is ever
    # produced. This catches a misconfigured cross-compile even if the
    # platform/arch variables all claimed arm64.
    python3 - "${kernel_image}" <<'PY'
import struct
import sys
from pathlib import Path

IMAGE_FILE_MACHINE_ARM64 = 0xaa64

path = Path(sys.argv[1])
data = path.read_bytes()[:4096]

if data[:2] == b"MZ" and len(data) >= 0x40:
    e_lfanew = struct.unpack_from("<I", data, 0x3c)[0]
    if (
        len(data) >= e_lfanew + 6
        and data[e_lfanew:e_lfanew + 4] == b"PE\x00\x00"
    ):
        machine = struct.unpack_from("<H", data, e_lfanew + 4)[0]
        if machine == IMAGE_FILE_MACHINE_ARM64:
            print(f"arm64 PE/EFI-stub kernel image machine-type check passed: {path}")
            raise SystemExit(0)
        raise SystemExit(
            f"{path} is a PE/EFI-stub image but its machine type is "
            f"{machine:#06x}, not ARM64 ({IMAGE_FILE_MACHINE_ARM64:#06x})"
        )

if len(data) >= 0x3c and data[0x38:0x3c] == b"ARM\x64":
    print(f"arm64 kernel image magic check passed: {path}")
    raise SystemExit(0)

raise SystemExit(f"{path} does not look like an arm64 Linux kernel image")
PY
}

verify_image_contains_file_sha() {
    local image="$1"
    local expected_file="$2"
    local label="$3"
    local platform="$4"

    test -s "${expected_file}" || {
        echo "expected file is missing or empty: ${expected_file}" >&2
        exit 1
    }

    log "Verifying ${label} contains $(basename -- "${expected_file}") from this build"
    crane export --platform="${platform}" "${image}" - | python3 -c '
import sys
import tarfile
from pathlib import Path

# Talos packages the installed kernel as a UKI-style vmlinuz.efi bundle (kernel
# + initramfs + cmdline), roughly 5x the size of the bare kernel package
# output, so this checks byte-containment rather than a whole-file hash match.
needle = Path(sys.argv[1]).read_bytes()
label = sys.argv[2]
archive = tarfile.open(fileobj=sys.stdin.buffer, mode="r|*")
checked = 0

for member in archive:
    if not member.isfile():
        continue

    name = member.name.lstrip("./")
    base = name.rsplit("/", 1)[-1]

    if not (base.startswith("vmlinuz") or base.endswith(".linux") or name.endswith("/kernel")):
        continue

    extracted = archive.extractfile(member)
    if extracted is None:
        continue

    checked += 1
    if needle in extracted.read():
        print(f"MATCH: {label} contains custom kernel bytes at {member.name}")
        break
else:
    raise SystemExit(
        f"MISMATCH: {label} does not contain the custom kernel bytes from {Path(sys.argv[1]).name}; "
        f"checked {checked} plausible kernel files"
    )

# Drain the rest of the tar stream so the upstream `crane export` process
# does not get SIGPIPE/EPIPE from an early-closed stdin under pipefail.
while sys.stdin.buffer.read(1 << 20):
    pass
' "${expected_file}" "${label}"
}

verify_raw_image_contains_file_bytes() {
    local raw_image="$1"
    local expected_file="$2"
    local label="$3"

    test -s "${raw_image}" || {
        echo "raw image is missing or empty: ${raw_image}" >&2
        exit 1
    }
    test -s "${expected_file}" || {
        echo "expected file is missing or empty: ${expected_file}" >&2
        exit 1
    }

    log "Verifying ${label} raw image contains the custom kernel bytes"
    python3 - "${raw_image}" "${expected_file}" "${label}" <<'PY'
from pathlib import Path
import sys

raw = Path(sys.argv[1])
needle_path = Path(sys.argv[2])
label = sys.argv[3]
needle = needle_path.read_bytes()

if not needle:
    raise SystemExit(f"empty expected file: {needle_path}")

chunk_size = 32 * 1024 * 1024
overlap_size = max(0, len(needle) - 1)
overlap = b""
offset = 0

with raw.open("rb") as f:
    while True:
        chunk = f.read(chunk_size)
        if not chunk:
            break
        haystack = overlap + chunk
        pos = haystack.find(needle)
        if pos != -1:
            absolute = offset - len(overlap) + pos
            print(f"MATCH: {label} contains custom kernel bytes at byte offset {absolute}")
            raise SystemExit(0)
        if overlap_size:
            overlap = haystack[-overlap_size:]
        offset += len(chunk)

raise SystemExit(f"MISMATCH: {label} raw image does not contain custom kernel bytes from {needle_path}")
PY
}

verify_zfs_extension_matches_zfs_pkg() {
    local zfs_pkg_image="$1"
    local extension_image="$2"
    local platform="$3"
    local tmpdir

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' RETURN

    log "Exporting zfs-pkg and ZFS extension for exact module comparison"
    crane export --platform="${platform}" "${zfs_pkg_image}" - >"${tmpdir}/zfs-pkg.tar"
    crane export --platform="${platform}" "${extension_image}" - >"${tmpdir}/zfs-extension.tar"

    python3 - "${tmpdir}/zfs-pkg.tar" "${tmpdir}/zfs-extension.tar" <<'PY'
from pathlib import Path
import hashlib
import sys
import tarfile

pkg_tar = Path(sys.argv[1])
ext_tar = Path(sys.argv[2])
SIGNATURE_MARKER = b"~Module signature appended~"

def collect_modules(path):
    by_hash = {}
    unsigned = []
    with tarfile.open(path, "r:*") as archive:
        for member in archive:
            if not member.isfile() or not member.name.endswith(".ko"):
                continue
            extracted = archive.extractfile(member)
            if extracted is None:
                continue
            data = extracted.read()
            digest = hashlib.sha256(data).hexdigest()
            by_hash.setdefault(digest, []).append(member.name)
            if SIGNATURE_MARKER not in data:
                unsigned.append(member.name)
    return by_hash, unsigned

pkg_hashes, pkg_unsigned = collect_modules(pkg_tar)
ext_hashes, ext_unsigned = collect_modules(ext_tar)

if not pkg_hashes:
    raise SystemExit("zfs-pkg image contains no .ko modules")
if not ext_hashes:
    raise SystemExit("ZFS extension image contains no .ko modules")
if pkg_unsigned:
    raise SystemExit("unsigned modules in zfs-pkg: " + ", ".join(pkg_unsigned))
if ext_unsigned:
    raise SystemExit("unsigned modules in ZFS extension: " + ", ".join(ext_unsigned))

missing = []
matched = 0
for digest, ext_paths in ext_hashes.items():
    if digest in pkg_hashes:
        matched += len(ext_paths)
        continue
    missing.extend(ext_paths)

if missing:
    raise SystemExit(
        "ZFS extension contains module payloads not found byte-for-byte in zfs-pkg: "
        + ", ".join(missing)
    )

print(f"MATCH: {matched} ZFS extension module payload(s) are byte-for-byte from zfs-pkg")
PY

    trap - RETURN
    rm -rf "${tmpdir}"
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
    if command -v crane >/dev/null 2>&1 && crane digest --help >/dev/null 2>&1; then
        return 0
    fi

    log "crane not found, or found a different tool named 'crane' (expected go-containerregistry/crane); creating temporary Docker-backed crane wrapper"
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
require_cmd awk

assert_rockpi_arm64_platform

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

if bool_enabled "${BUILD_KERNEL}" && ! bool_enabled "${BUILD_ZFS_PKG}"; then
    echo "BUILD_KERNEL=true requires BUILD_ZFS_PKG=true so the ZFS modules use the kernel's generated signing key" >&2
    exit 1
fi

if bool_enabled "${BUILD_ZFS_PKG}" && ! bool_enabled "${BUILD_KERNEL}"; then
    echo "BUILD_ZFS_PKG=true requires BUILD_KERNEL=true so the kernel trusts the generated ZFS module signatures" >&2
    exit 1
fi

if bool_enabled "${BUILD_ZFS_EXTENSION}"; then
    ensure_extensions_checkout

    if [[ -z "${ZFS_EXTENSION_IMAGE}" ]]; then
        ZFS_DRIVER_VERSION="$(zfs_extension_version)"
        ZFS_EXTENSION_IMAGE="${ZFS_EXTENSION_REPOSITORY}:${ZFS_DRIVER_VERSION}-${CUSTOM_TAG}"
    fi
elif [[ -z "${ZFS_EXTENSION_IMAGE}" ]]; then
    echo "BUILD_ZFS_EXTENSION=false requires ZFS_EXTENSION_IMAGE to identify the prebuilt extension" >&2
    exit 1
fi

log "Build configuration"
cat <<EOF
PKGS_DIR=${PKGS_DIR}
TALOS_DIR=${TALOS_DIR}
TALOS_TAG=${TALOS_TAG}
CUSTOM_TAG=${CUSTOM_TAG}
TAG_SUFFIX=${TAG_SUFFIX}
PKG_KERNEL=${PKG_KERNEL}
PKG_ZFS=${PKG_ZFS}
Talos extensions tag=${EXTENSIONS_TAG}
Talos extensions checkout=${EXTENSIONS_DIR}
ZFS extension image=${ZFS_EXTENSION_IMAGE}
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
Verify ZFS extension=${VERIFY_ZFS_EXTENSION}
Verify ZFS extension matches zfs-pkg=${VERIFY_ZFS_PKG_EXTENSION_MATCH}
Verify custom kernel image=${VERIFY_CUSTOM_KERNEL_IMAGE}
Verify installer kernel=${VERIFY_INSTALLER_KERNEL}
Verify Docker Hub installer kernel=${VERIFY_DOCKERHUB_INSTALLER_KERNEL}
Verify eMMC raw image kernel=${VERIFY_EMMC_KERNEL}
Verification output=${VERIFY_DIR}
EOF

if bool_enabled "${PATCH_TALOS_MAKEFILE}"; then
    ensure_talos_makefile_image_patches
fi

PKGS_BUILD_TARGETS=()
if bool_enabled "${BUILD_ZFS_PKG}"; then
    PKGS_BUILD_TARGETS+=(zfs-pkg)
fi
if bool_enabled "${BUILD_KERNEL}"; then
    PKGS_BUILD_TARGETS+=(kernel)
fi

# zfs-pkg and kernel must be built together so they share the exact same
# kernel-build stage execution (same ephemeral module-signing key embedded in
# the kernel and used to sign zfs.ko). A synthetic test confirmed bldr/
# BuildKit correctly shares this cache across separate --target= invocations;
# an earlier mismatch in this repo was just stale state from this build's
# history, not a structural caching issue. See HANDOFF.md and
# docs/rockpi-pcie-penta-history.md. PKG_KERNEL_PINNED below additionally
# guards against imager picking up a stale *kernel* (e.g. missing the PCIe
# patch) under a reused tag.
if ((${#PKGS_BUILD_TARGETS[@]} > 0)); then
    log "Building and pushing paired pkgs targets: ${PKGS_BUILD_TARGETS[*]}"
    make -C "${PKGS_DIR}" "${PKGS_BUILD_TARGETS[@]}" \
        PLATFORM="${KERNEL_PLATFORM}" \
        REGISTRY="${GITLAB_REGISTRY}" \
        USERNAME="${GITLAB_USERNAME}" \
        TAG="${CUSTOM_TAG}" \
        PUSH=true \
        PROGRESS="${PROGRESS}"
else
    log "Skipping kernel and ZFS package builds"
fi

# Pin PKG_KERNEL to the digest just pushed, unconditionally. The imager build
# below consumes this, not the mutable PKG_KERNEL tag: if the kernel was
# rebuilt/re-pushed under the same CUSTOM_TAG across runs (e.g. while
# iterating on this script), a mutable-tag FROM resolution risks reusing a
# stale BuildKit cache entry for that tag, baking in a different kernel than
# the one zfs-pkg was just signed against — module signing would then fail
# at runtime with "key was rejected" even though both builds individually
# succeeded. See docs/rockpi-pcie-penta-history.md / HANDOFF.md.
PKG_KERNEL_DIGEST="$(image_digest "${PKG_KERNEL}")"
PKG_KERNEL_PINNED="$(pinned_image_ref "${PKG_KERNEL}" "${PKG_KERNEL_DIGEST}")"

if bool_enabled "${VERIFY_CUSTOM_KERNEL_IMAGE}"; then
    mkdir -p "${VERIFY_DIR}"
    printf '%s\n' "${PKG_KERNEL_PINNED}" | tee "${VERIFY_DIR}/kernel-image.ref"
    extract_vmlinuz_from_image "${PKG_KERNEL_PINNED}" "${CUSTOM_KERNEL_VMLINUZ}" "${KERNEL_PLATFORM}"
fi

if bool_enabled "${BUILD_ZFS_EXTENSION}"; then
    log "Building and pushing Talos ZFS system extension"
    make -C "${EXTENSIONS_DIR}" zfs \
        PLATFORM="${KERNEL_PLATFORM}" \
        REGISTRY="${GITLAB_REGISTRY}" \
        USERNAME="${GITLAB_USERNAME}" \
        TAG="${CUSTOM_TAG}" \
        PKGS_PREFIX="${GITLAB_REGISTRY}/${GITLAB_USERNAME}" \
        PKGS="${CUSTOM_TAG}" \
        PUSH=true \
        PROGRESS="${PROGRESS}"
else
    log "Skipping ZFS extension build because BUILD_ZFS_EXTENSION=${BUILD_ZFS_EXTENSION}"
fi

if bool_enabled "${VERIFY_ZFS_EXTENSION}"; then
    verify_zfs_extension_image "${ZFS_EXTENSION_IMAGE}" "${KERNEL_PLATFORM}"
fi

if bool_enabled "${VERIFY_ZFS_PKG_EXTENSION_MATCH}"; then
    verify_zfs_extension_matches_zfs_pkg "${PKG_ZFS}" "${ZFS_EXTENSION_IMAGE}" "${KERNEL_PLATFORM}"
fi

export REGISTRY="${GITLAB_REGISTRY}"
export USERNAME="${GITLAB_USERNAME}"
export TAG="${TALOS_TAG}"
export TAG_SUFFIX
export PKG_KERNEL="${PKG_KERNEL_PINNED}"

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
        PKG_KERNEL="${PKG_KERNEL_PINNED}" \
        PUSH=true \
        PROGRESS="${PROGRESS}"
else
    log "Skipping imager because BUILD_IMAGER=${BUILD_IMAGER}"
fi

if bool_enabled "${BUILD_INSTALLER}"; then
    log "Building Talos installer image with ZFS extension"
    talos_make installer \
        PLATFORM="${INSTALLER_PLATFORM}" \
        IMAGER_ARGS="--system-extension-image ${ZFS_EXTENSION_IMAGE} ${IMAGER_ARGS:-}" \
        PROGRESS="${PROGRESS}"
else
    log "Skipping installer because BUILD_INSTALLER=${BUILD_INSTALLER}"
fi

GITLAB_INSTALLER=""
GITLAB_INSTALLER_FILE=""
if GITLAB_INSTALLER_FILE="$(find_talos_artifact installer_image)"; then
    GITLAB_INSTALLER="$(cat "${GITLAB_INSTALLER_FILE}")"
fi

if bool_enabled "${VERIFY_INSTALLER_KERNEL}"; then
    if [[ -z "${GITLAB_INSTALLER}" ]]; then
        echo "installer image file not found in ${TALOS_DIR}/_out or ${PKGS_DIR}/_out; cannot verify installer kernel" >&2
        exit 1
    fi
    verify_image_contains_file_sha "${GITLAB_INSTALLER}" "${CUSTOM_KERNEL_VMLINUZ}" "private installer image" "${INSTALLER_PLATFORM}"
fi

if bool_enabled "${COPY_TO_DOCKERHUB}"; then
    if [[ -z "${GITLAB_INSTALLER}" ]]; then
        echo "installer image file not found in ${TALOS_DIR}/_out or ${PKGS_DIR}/_out" >&2
        exit 1
    fi

    log "Copying private GitLab installer to public Docker Hub"
    crane copy "${GITLAB_INSTALLER}" "${DOCKERHUB_INSTALLER}"

    if bool_enabled "${VERIFY_DOCKERHUB_INSTALLER_KERNEL}"; then
        verify_image_contains_file_sha "${DOCKERHUB_INSTALLER}" "${CUSTOM_KERNEL_VMLINUZ}" "Docker Hub installer image" "${INSTALLER_PLATFORM}"
    fi
else
    log "Skipping Docker Hub copy because COPY_TO_DOCKERHUB=${COPY_TO_DOCKERHUB}"
fi

EMMC_COMPRESSED_IMAGE=""
EMMC_RAW_IMAGE=""

if bool_enabled "${BUILD_EMMC_IMAGE}"; then
    EMMC_ARCH="$(platform_arch "${EMMC_IMAGE_PLATFORM}")"
    EMMC_RAW_IMAGE="${EMMC_IMAGE_DEST_DIR}/${EMMC_IMAGE_BASENAME}-${EMMC_ARCH}.raw"

    if bool_enabled "${RUN_EMMC_IMAGE_TARGET}"; then
        log "Building Talos ${EMMC_IMAGE_TARGET} eMMC image with ${EMMC_OVERLAY_NAME} overlay and ZFS extension"
        remove_emmc_source_candidates "${EMMC_ARCH}" "${EMMC_IMAGE_TARGET}" "${EMMC_IMAGE_PROFILE}"
        talos_make "image-${EMMC_IMAGE_PROFILE}" \
            PLATFORM="${EMMC_IMAGE_PLATFORM}" \
            IMAGE_DOCKER_USER="${EMMC_IMAGE_DOCKER_USER}" \
            IMAGER_ARGS="--overlay-name ${EMMC_OVERLAY_NAME} --overlay-image ${EMMC_OVERLAY_IMAGE} --system-extension-image ${ZFS_EXTENSION_IMAGE} ${IMAGER_ARGS:-}" \
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

        if bool_enabled "${VERIFY_EMMC_KERNEL}"; then
            verify_raw_image_contains_file_bytes "${EMMC_RAW_IMAGE}" "${CUSTOM_KERNEL_VMLINUZ}" "eMMC raw image"
        fi
    else
        if bool_enabled "${VERIFY_EMMC_KERNEL}"; then
            echo "VERIFY_EMMC_KERNEL=true requires DECOMPRESS_EMMC_IMAGE=true so the raw image can be inspected" >&2
            exit 1
        fi

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

ZFS system extension:
  ${ZFS_EXTENSION_IMAGE}

Verification artifacts:
  ${VERIFY_DIR}

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

Verify the extension and ZFS modules:
  talosctl -e whiterock -n whiterock get extensions
  talosctl -e whiterock -n whiterock dmesg | grep -Ei 'zfs|module verification|signature'
EOF
