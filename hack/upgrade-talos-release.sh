#!/usr/bin/env bash
set -euo pipefail

# Carry the RockPi customizations (PCIe patches, ZFS static signing-key
# config, build scripts, docs) forward onto a new Talos release's pinned
# pkgs revision, without ever rebasing or cherry-picking this repo's commit
# history and without re-cloning the Talos source tree each time.
#
# Usage:
#   hack/upgrade-talos-release.sh <talos-tag>
#
# Example:
#   hack/upgrade-talos-release.sh v1.13.6
#
# What it does:
#   1. Ensures a single persistent Talos source checkout exists at
#      TALOS_DIR (clones it if missing, otherwise fetches + checks out the
#      requested tag in place).
#   2. Reads that tag's pinned siderolabs/pkgs revision straight out of the
#      Talos source tree.
#   3. Fetches that exact revision from the pkgs upstream remote and creates
#      a new branch from it (no merge/rebase/cherry-pick against history).
#   4. Re-applies the RockPi overlay on top: copies this repo's own patch
#      files, hack/ scripts and docs verbatim from the branch this script
#      was run from; idempotently edits CONFIG_MODULE_SIG_KEY in both kernel
#      configs; appends (or refreshes) the marker-delimited RockPi section
#      in kernel/build/patches/README.md without touching upstream's rows;
#      idempotently appends the .gitignore block for the private signing
#      key.
#   5. Downloads the new revision's pinned kernel tarball and dry-run
#      verifies every active RockPi patch still applies before committing
#      to anything.
#   6. Commits the result as a single commit and prints the build command
#      to run next (does not build or push anything itself).
#
# Override any of these in the environment:
#   TALOS_DIR        - persistent Talos source checkout (default below)
#   PKGS_DIR         - this repo's root (default: parent of this script)
#   UPSTREAM_REMOTE  - pkgs git remote to pull the pinned revision from
#   TALOS_REPO_URL   - used only if TALOS_DIR doesn't exist yet
#   BRANCH_PREFIX    - new branch name is "${BRANCH_PREFIX}<version>"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PKGS_DIR="${PKGS_DIR:-$(cd -- "${SCRIPT_DIR}/.." && pwd)}"
TALOS_DIR="${TALOS_DIR:-${HOME}/github/talos-rockpi}"
TALOS_REPO_URL="${TALOS_REPO_URL:-https://github.com/siderolabs/talos.git}"
UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-upstream}"
BRANCH_PREFIX="${BRANCH_PREFIX:-rockpi4-pcie-reset-}"

log() {
    printf '\n==> %s\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

require_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

[[ $# -eq 1 ]] || die "usage: $0 <talos-tag> (e.g. v1.13.6)"
TALOS_TAG="$1"
TALOS_VERSION="${TALOS_TAG#v}"
NEW_BRANCH="${BRANCH_PREFIX}${TALOS_VERSION}"

require_cmd git
require_cmd python3
require_cmd curl
require_cmd patch

[[ -f "${PKGS_DIR}/Pkgfile" ]] || die "PKGS_DIR does not look like the pkgs repo: ${PKGS_DIR}"

cd "${PKGS_DIR}"
ORIGIN_BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "${ORIGIN_BRANCH}" != "HEAD" ]] || die "currently in detached HEAD; check out the branch with the RockPi overlay first"
git diff --quiet || die "pkgs repo has unstaged changes; commit or stash first"
git diff --cached --quiet || die "pkgs repo has staged changes; commit or stash first"

if git rev-parse -q --verify "refs/heads/${NEW_BRANCH}" >/dev/null; then
    die "branch ${NEW_BRANCH} already exists; check it out directly or delete it before re-running"
fi

# --- 1. Talos source checkout: reuse if present, clone if missing ---
log "Ensuring Talos checkout at ${TALOS_DIR} (tag ${TALOS_TAG})"
if [[ -d "${TALOS_DIR}/.git" ]]; then
    git -C "${TALOS_DIR}" fetch --tags origin
else
    mkdir -p "$(dirname -- "${TALOS_DIR}")"
    git clone "${TALOS_REPO_URL}" "${TALOS_DIR}"
fi
git -C "${TALOS_DIR}" checkout --detach "${TALOS_TAG}"

# --- 2. Read the pinned pkgs revision out of the Talos tree ---
log "Resolving pinned pkgs revision for ${TALOS_TAG}"
PKGS_DESCRIBE="$(
    git -C "${TALOS_DIR}" show "${TALOS_TAG}:pkg/machinery/gendata/data/pkgs" \
        | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-g[0-9a-f]+' | head -1
)"
[[ -n "${PKGS_DESCRIBE}" ]] || die "could not find a pinned pkgs revision (vX.Y.Z-N-gSHA) in ${TALOS_TAG}:pkg/machinery/gendata/data/pkgs"
PKGS_SHA="${PKGS_DESCRIBE##*-g}"
log "Pinned pkgs revision: ${PKGS_DESCRIBE} (${PKGS_SHA})"

# --- 3. Fetch that exact revision and branch from it, no merge/rebase ---
log "Fetching ${PKGS_SHA} from ${UPSTREAM_REMOTE} and creating ${NEW_BRANCH}"
git fetch "${UPSTREAM_REMOTE}" "${PKGS_SHA}" 2>/dev/null || git fetch "${UPSTREAM_REMOTE}"
git rev-parse -q --verify "${PKGS_SHA}^{commit}" >/dev/null || die "pkgs revision ${PKGS_SHA} not available after fetching ${UPSTREAM_REMOTE}"
git checkout -b "${NEW_BRANCH}" "${PKGS_SHA}"

cleanup_on_failure() {
    local exit_code=$?
    if [[ ${exit_code} -ne 0 ]]; then
        echo "Left branch ${NEW_BRANCH} checked out for inspection after failure (exit ${exit_code})." >&2
        echo "Run: git checkout ${ORIGIN_BRANCH} && git branch -D ${NEW_BRANCH}  to discard it." >&2
    fi
}
trap cleanup_on_failure EXIT

# --- 4. Re-apply the RockPi overlay on top of the new base ---
log "Carrying forward RockPi-specific files from ${ORIGIN_BRANCH}"

copy_from_origin() {
    local path="$1"
    mkdir -p "$(dirname -- "${path}")"
    git show "${ORIGIN_BRANCH}:${path}" > "${path}"
    git add "${path}"
}

VERBATIM_FILES=(
    hack/build-rockpi-installer.sh
    hack/build-rockpi-installer-with-verification.sh
    hack/patch-rockpi-uboot-dtb.py
    hack/upgrade-talos-release.sh
    codebook.toml
)
for f in "${VERBATIM_FILES[@]}"; do
    copy_from_origin "${f}"
done

# Optional docs: carry forward whatever rockpi-*.md files exist on the
# origin branch, if any.
while IFS= read -r doc; do
    [[ -n "${doc}" ]] || continue
    copy_from_origin "${doc}"
done < <(git ls-tree -r --name-only "${ORIGIN_BRANCH}" -- docs | grep -E '^docs/rockpi-.*\.md$' || true)

ACTIVE_ROCKPI_PATCH="kernel/build/patches/0012-PCI-rockchip-restore-RK3399-6.8-PERST-timing.patch"
copy_from_origin "${ACTIVE_ROCKPI_PATCH}"

chmod +x hack/build-rockpi-installer.sh hack/build-rockpi-installer-with-verification.sh hack/upgrade-talos-release.sh

# --- Idempotent CONFIG_MODULE_SIG_KEY edit on both kernel configs ---
log "Pointing CONFIG_MODULE_SIG_KEY at the static signing key"
for cfg in kernel/build/config-arm64 kernel/build/config-amd64; do
    python3 - "${cfg}" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text()
old = 'CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"'
new = 'CONFIG_MODULE_SIG_KEY="certs/static-signing-key.pem"'
if new in text:
    pass
elif old in text:
    path.write_text(text.replace(old, new, 1))
else:
    raise SystemExit(f"could not find CONFIG_MODULE_SIG_KEY default in {path}")
PY
    git add "${cfg}"
done

# --- Idempotent .gitignore block for the private signing key ---
log "Ensuring .gitignore covers the private signing key"
if ! grep -q "static-signing-key.pem" .gitignore 2>/dev/null; then
    {
        echo ""
        echo "# Private kernel module-signing key (intentionally not committed - this repo"
        echo "# is public). See HANDOFF.md \"Final resolution - pinned static signing key\"."
        echo "kernel/build/certs/static-signing-key.pem"
        echo "hack/__pycache__/"
    } >> .gitignore
fi
git add .gitignore

# --- Refresh the marker-delimited RockPi section in patches/README.md ---
log "Refreshing RockPi section of kernel/build/patches/README.md"
ROCKPI_README_SECTION="$(git show "${ORIGIN_BRANCH}:kernel/build/patches/README.md" | sed -n '/BEGIN ROCKPI CUSTOM PATCHES/,/END ROCKPI CUSTOM PATCHES/p')"
[[ -n "${ROCKPI_README_SECTION}" ]] || die "origin branch's patches/README.md has no BEGIN/END ROCKPI CUSTOM PATCHES markers; add them once by hand, then re-run"

python3 - "kernel/build/patches/README.md" <<PY
import re
from pathlib import Path

path = Path("kernel/build/patches/README.md")
text = path.read_text()
section = """${ROCKPI_README_SECTION}
"""

pattern = re.compile(
    r"<!-- BEGIN ROCKPI CUSTOM PATCHES.*?<!-- END ROCKPI CUSTOM PATCHES -->\n?",
    re.DOTALL,
)
if pattern.search(text):
    text = pattern.sub(section, text)
else:
    if not text.endswith("\n"):
        text += "\n"
    text += section
path.write_text(text)
PY
git add kernel/build/patches/README.md

# --- 5. Dry-run verify every active RockPi patch against the pinned kernel ---
log "Downloading pinned kernel source to verify active RockPi patches apply"
LINUX_VERSION="$(awk -v key="linux_version:" '$1 == key { print $2; exit }' Pkgfile)"
LINUX_SHA256="$(awk -v key="linux_sha256:" '$1 == key { print $2; exit }' Pkgfile)"
[[ -n "${LINUX_VERSION}" && -n "${LINUX_SHA256}" ]] || die "could not read linux_version/linux_sha256 from Pkgfile"

VERIFY_DIR="$(mktemp -d)"
trap 'rm -rf "${VERIFY_DIR}"; cleanup_on_failure' EXIT

MAJOR="$(echo "${LINUX_VERSION}" | sed -E 's/^([0-9]+)\..*/\1/')"
TARBALL="linux-${LINUX_VERSION}.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/v${MAJOR}.x/${TARBALL}"
log "Fetching ${URL}"
curl -fsSL -o "${VERIFY_DIR}/${TARBALL}" "${URL}"
echo "${LINUX_SHA256}  ${VERIFY_DIR}/${TARBALL}" | sha256sum -c -

log "Extracting kernel source for dry-run patch verification"
tar -C "${VERIFY_DIR}" -xf "${VERIFY_DIR}/${TARBALL}"
KERNEL_SRC="${VERIFY_DIR}/linux-${LINUX_VERSION}"

FAILED=0
for patch_file in kernel/build/patches/*.patch; do
    [[ -e "${patch_file}" ]] || continue
    if patch -p1 --dry-run -d "${KERNEL_SRC}" < "${patch_file}" >/dev/null 2>&1; then
        echo "  OK   ${patch_file}"
    else
        echo "  FAIL ${patch_file}" >&2
        FAILED=1
    fi
done
[[ "${FAILED}" -eq 0 ]] || die "one or more active patches no longer apply cleanly to linux-${LINUX_VERSION}; resolve before committing"

# --- 6. Commit ---
log "Committing overlay onto ${NEW_BRANCH}"
git commit -m "rockpi: carry overlay forward to Talos ${TALOS_TAG} (pkgs ${PKGS_DESCRIBE})"

trap - EXIT
rm -rf "${VERIFY_DIR}"

log "Done. New branch: ${NEW_BRANCH}"
cat <<EOF

Next step - build and push (this will take ~1.5-2h for the kernel compile):

  TALOS_TAG=${TALOS_TAG} \\
  TALOS_DIR=${TALOS_DIR} \\
  CUSTOM_TAG=v${TALOS_VERSION}-rockpi-zfs \\
  hack/build-rockpi-installer-with-verification.sh

Nothing has been built, pushed, flashed, or upgraded by this script.
EOF
