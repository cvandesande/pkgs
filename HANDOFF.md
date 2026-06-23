# HANDOFF: Rock Pi 4A / RK3399 Talos — ZFS module signing

Last updated: 2026-06-23

Full PCIe/SATA fix and Penta HAT history (all resolved, hardware-confirmed) is
archived in [`docs/rockpi-pcie-penta-history.md`](docs/rockpi-pcie-penta-history.md).
This file only tracks the current active work: building a Talos installer
with the patched kernel **and** a correctly signed ZFS kernel module.

## Established baseline (resolved, see archive for detail)

- PCIe/SATA link-training fix: kernel patch `0012` only, hardware-confirmed.
- Penta HAT (I2C7 OLED + PWM1 fan) + PCIe Gen2 x2: hardware-confirmed,
  combined into U-Boot/SBC overlay image
  `docker.io/cvandesande/talos:sbc-rockchip-v0.2.0-rockpi-penta-gen2-1`, now
  the **default** `EMMC_OVERLAY_IMAGE` in both build scripts.
- Penta controller running as a Kubernetes DaemonSet/Deployment on `whiterock`
  (`rockpi-penta-controller/`), fan + OLED confirmed live; button handling
  still deliberately disabled (see archive's "Still open" section).

## Immediate status: ZFS module signing

Goal: produce a Rock Pi 4A installer with the patched kernel (`0012`) and a
ZFS kernel module/extension signed against that exact kernel's module-signing
key, so it actually loads at runtime (Talos requires matching signatures).

A first attempt booted successfully but appeared to run the *stock* Talos
kernel rather than the patched one. Root-caused and fixed three bugs in
`hack/build-rockpi-installer.sh` and
`hack/build-rockpi-installer-with-verification.sh` (the latter independently
verifies kernel/module signing and byte-identity at every stage — use it):

1. **`crane` PATH shadowing**: `~/.local/bin/crane` resolves to a different,
   unrelated tool (Michael Sauter's container `crane`), not
   `go-containerregistry/crane` the scripts need. `ensure_crane()` now checks
   `crane digest --help` actually works, not just that something named
   `crane` exists, before falling back to its Docker-wrapper.
2. **Broken-pipe abort under `pipefail`**: the verification helpers piped
   `crane export | python3 -c ...` and exited early (`SystemExit(0)`) right
   after finding the target file, leaving the rest of the tar stream unread —
   this SIGPIPEs the upstream `crane export` and aborts the whole build even
   though the check had already succeeded. Fixed to drain remaining stdin
   before exiting.
3. **`crane export` picking the wrong platform**: building arm64 images on an
   x86_64 host, `crane export` against a multi-arch image *index* (e.g. the
   installer) defaulted to the host's amd64 child, which doesn't exist
   (arm64-only), erroring `no child with platform linux/amd64`. All
   `crane export`/`crane digest` calls against indexed images now pass
   `--platform=linux/arm64` explicitly.

Also added a defense-in-depth arm64 architecture guard (`assert_rockpi_arm64_platform`
in both scripts, called right after `require_cmd` checks) that hard-errors if
`KERNEL_PLATFORM`/`INSTALLER_BASE_PLATFORM`/`INSTALLER_PLATFORM`/`EMMC_IMAGE_PLATFORM`/
`INSTALLER_ARCH` don't resolve to `linux/arm64`/`arm64` — `IMAGER_PLATFORM` is
deliberately exempt (the imager *tool* container runs on the amd64 build host
and cross-produces arm64 artifacts). The verification script also byte-checks
the extracted kernel itself is arm64 (`assert_arm64_kernel_image`): Talos
builds arm64 kernels as a PE32+/EFI-stub image, so this parses the PE header's
Machine field (expect `0xaa64`), falling back to the raw Linux arm64 boot
image magic at offset `0x38`.

The signing mechanism itself (traced through `kernel/build/pkg.yaml`,
`zfs/pkg.yaml`, and the Talos extensions repo's `zfs/pkg.yaml`) is correct:
the kernel build auto-generates an ephemeral signing keypair (no
`certs/signing_key.pem` checked in, only the `x509.genkey` template);
`zfs-pkg`'s Dockerfile stage depends on `stage: kernel-build` directly (same
BuildKit stage, not a separate pull), so it signs `zfs.ko` with that same
ephemeral key; the ZFS system extension just copies the already-signed `.ko`
out of `zfs-pkg` by exact tag, no recompilation. This only holds if `kernel`
and `zfs-pkg` are built together in one invocation without `--no-cache` (the
scripts already enforce this) so BuildKit reuses the cached stage rather than
generating two different ephemeral keys.

A 4th bug surfaced running the actual golden-tag build (`CUSTOM_TAG=v1.13.4-rockpi-zfs`,
confirmed unused on both registries before the run): `verify_image_contains_file_sha`
matched filenames like `vmlinuz`/`vmlinuz-*` but Talos names the installed
kernel `usr/install/<arch>/vmlinuz.efi`, so it found 0 candidates and reported
a MISMATCH. Worse, even after widening the filename match
(`base.startswith("vmlinuz")`), the file is **not** byte-identical to the bare
kernel package output — Talos packages it as a UKI-style bundle (kernel +
initramfs + cmdline) roughly 5x the bare kernel's size (confirmed: stock
upstream `ghcr.io/siderolabs/installer:v1.13.4`'s arm64 `vmlinuz.efi` is also
~99MB vs our ~20MB bare kernel). Manually confirmed our custom kernel's exact
bytes **are** present as a contiguous substring (at byte offset 743936) inside
our installer's `vmlinuz.efi` — the correct kernel was embedded all along;
only the verification check's methodology was wrong. Fixed
`verify_image_contains_file_sha` to do substring containment instead of
whole-file SHA256 equality, and confirmed the fixed check now reports `MATCH`
against the real pushed installer image. This was a verification-script bug,
not a build/staleness bug — the original "stock kernel" symptom that started
this whole investigation has not recurred with this golden-tag build.

A 5th bug surfaced on the next run, past the kernel-byte-match fix, at the
eMMC image stage: `VERIFY_ROCKPI_UBOOT_DTB` defaulted `true`, but
`patch-rockpi-uboot-dtb.py --verify-only` asserts the *legacy* `0006`-style
properties (`vpcie12v-supply`, `bus-scan-delay-ms`, regulator min/max). The
new default overlay (`penta-gen2-1`, switched earlier this session) is the
clean image that deliberately **omits** those — hardware-confirmed working
without them. This verify step was paired with the *old* default overlay
(which baked those properties into U-Boot source) and was never updated when
the overlay default changed. Flipped `VERIFY_ROCKPI_UBOOT_DTB` to default
`false` in both scripts (matching `PATCH_ROCKPI_UBOOT_DTB`, already `false`)
with a comment explaining why. Only set it `true` if deliberately using an
old overlay image that still bakes those properties in.

## Bug 6 (the real root cause) — found after first full build + flash

The `v1.13.4-rockpi-zfs` golden-tag image built clean, flashed, and **booted
the correct custom kernel** (`Linux version 6.18.34-talos`), but ZFS still
wouldn't load:

```text
Loaded X.509 cert 'Sidero Labs, Inc.: Build time throw-away kernel key: 437d2543aca7b1cfbc23da105ced03a50dda4006'
...
Loading of module with unavailable key is rejected
controller failed ... error loading module "zfs": load zfs failed: key was rejected by service
```

Diagnosed directly against the running board and the pushed registry images
(not guesswork): extracted `zfs.ko` from the pushed `zfs-pkg` image, parsed
its module-signature trailer (PKCS#7, `id_type=2`), and dumped the
`SignerInfo` — it's signed by issuer `O=Sidero Labs, Inc., CN=Build time
throw-away kernel key`, serial `0x3F50C691BA526FD7802890B1646469F670775098`.
That CN is just the shared template in `kernel/build/certs/x509.genkey` (every
ephemeral build uses it), so it doesn't by itself prove a mismatch — but the
serial not matching the booted kernel's trusted cert, combined with the
mechanism below, confirms it: **the installer's kernel and the
zfs-pkg-signed module came from two different ephemeral signing keys.**

Root cause: both scripts compute `PKG_KERNEL_PINNED` (the kernel image pinned
to the exact digest just pushed) but then **never actually used it** — `make
imager PKG_KERNEL=...` was passed the plain mutable tag, not the pinned
digest. `Dockerfile:191`'s `FROM --platform=arm64 ${PKG_KERNEL}` resolves that
mutable tag through BuildKit's image-source cache. If the kernel was
rebuilt/re-pushed under the same `CUSTOM_TAG` across runs (exactly what
happened across this session's several fix-and-retry cycles), that resolution
can return a *different* cached kernel digest than the one `zfs-pkg` was just
signed against in the same invocation — both builds individually succeed,
but the kernel's embedded trusted cert and the module's signing key no longer
match. This is precisely the "stock kernel"/tag-caching suspicion from the
very start of this investigation, just one layer deeper than originally
diagnosed (not the *whole* installer being stale — specifically the kernel
sub-stage's tag resolution within the imager Dockerfile).

Fixed in both scripts: digest-pinning now happens unconditionally right after
the kernel/zfs-pkg push (not just when `VERIFY_CUSTOM_KERNEL_IMAGE=true`), and
`PKG_KERNEL_PINNED` — not the mutable tag — is what's actually passed to
`talos_make imager` and exported as `PKG_KERNEL` for any other consumer.

Rebuilding with bug-6's fix did **not** fix it — same `key was rejected`
error, same digests as before. Diagnosed further, directly: extracted
`zfs.ko` from the new `zfs-pkg` push and re-checked its PKCS#7 signer — the
serial (`0x3F50C691...`) was byte-identical to the *previous* build's, and
the `kernel` image digest (`sha256:4bc49a86...`) was also byte-identical to
every prior build this session. Both are individually perfectly
reproducible; they're just reproducible at two different, permanently
mismatched values. That rules out tag staleness as the (sole) cause — it
means `kernel` and `zfs-pkg` have never actually shared a `kernel-build`
execution at all, each instead reusing its own long-lived (and mutually
inconsistent) historical BuildKit cache entry, going back to whichever was
the first time each was independently built (possibly in unrelated past
sessions).

## Bug 7 — `kernel`/`zfs-pkg` never actually shared a `kernel-build` cache hit

This repo's package builds use Siderolabs' custom `bldr` BuildKit frontend
(`Pkgfile`'s `# syntax = ghcr.io/siderolabs/bldr:...` — not a plain
Dockerfile), so ordinary Dockerfile multi-stage caching assumptions don't
directly apply. Cloned `siderolabs/bldr` (pinned `v0.5.6`) to read its solver
and LLB-conversion code directly:

- `internal/pkg/solver/packages.go`'s `Resolve(target)` trims the package
  graph to just that target's dependency tree — `kernel` and `zfs-pkg` are
  each resolved independently, via two separate `docker buildx build
  --target=...` invocations (one per Makefile target).
- `internal/pkg/convert/node.go` showed no non-determinism in the LLB it
  emits for a given stage (no random salts/IDs); `CacheIDNamespace` only
  affects package-manager cache *mounts*, not the stage's own output caching.
  In principle two separate invocations referencing the same `kernel-build`
  pkg.yaml content should resolve to the same LLB digest and cache-hit.
- But `kernel/build/pkg.yaml`'s `kernel-build` step runs `openssl req -x509`
  to generate the module-signing keypair with **real randomness** — there is
  no way for two genuinely separate executions to produce the same key
  bytes. The only way two invocations end up with the same key is a literal
  BuildKit cache hit reusing one's exact prior output, never re-executing.
  Confirmed both `kernel` and `zfs-pkg` are each perfectly cache-stable
  individually (same digest/signer across every rebuild this session,
  including the embedded kernel build timestamp staying pinned to a date
  days before this session even started) — meaning each has been hitting a
  long-lived cache entry from whenever it was *first* built, and rebuilding
  them "together" today never forced reconciliation between those two
  already-existing, already-divergent entries.
- `bldr` only exposes a whole-build `--no-cache` boolean
  (`internal/pkg/pkgfile/build.go`'s `keyNoCache`) — no per-stage
  `--no-cache-filter` equivalent (that's a Dockerfile-frontend-specific
  feature `bldr` doesn't implement).
- The root Makefile's generic `$(TARGETS):` pattern rule (used by plain
  `make kernel ...`) **silently drops** any `TARGET_ARGS` the caller passes —
  it hardcodes `TARGET_ARGS="--tag=... --push=$(PUSH)"`, discarding the
  caller's value entirely. So `make kernel TARGET_ARGS=--no-cache` would
  silently do nothing. Confirmed the supported way to inject `--no-cache` is
  to call `docker-%`/`local-%` directly with the full `TARGET_ARGS` yourself
  — the Makefile's own `reproducibility-test-local-%` target does exactly
  this (build once normally, build again with `TARGET_ARGS="--no-cache"`).

Initially fixed in both scripts by forcing `kernel` to build first with
`--no-cache` (bypassing the generic `$(TARGETS)` Makefile wrapper, which
silently drops any `TARGET_ARGS` the caller passes), then `zfs-pkg`
immediately after with normal caching, expecting it to cache-hit that fresh
result. **This approach was superseded — see "Actual resolution" below** —
but the diagnostic work (bldr source reading, confirming `TARGET_ARGS`
clobbering) remains accurate and is kept for reference in case the signing
question ever needs to be revisited (e.g. if a future Talos version compiles
in `CONFIG_MODULE_SIG_FORCE`).

## Actual resolution — `module.sig_enforce=0` override

While the bug-7 fix was rebuilding, the user pointed at
[siderolabs/talos#11675](https://github.com/siderolabs/talos/issues/11675)
("add support for custom user-provided module signing keys", closed). The
maintainer's closing comment explains Talos' actual design: implementing
`CONFIG_SYSTEM_EXTRA_CERTIFICATE` (a way to insert a trusted cert into a
prebuilt kernel without recompiling) turned out to need `System.map` symbol
offsets and, on arm64, unpacking/repacking the zboot-compressed PE32+ image —
too fragile. Instead, "the idea is to not set `CONFIG_MODULE_SIG_FORCE` and
have `module.sig_enforce` set in talos images, providing the user a way to
disable signature verification for user brought modules."

Confirmed both halves of this in our own sources:

- `kernel/build/config-arm64`: `CONFIG_MODULE_SIG=y`,
  `# CONFIG_MODULE_SIG_FORCE is not set`, `# CONFIG_SYSTEM_EXTRA_CERTIFICATE
  is not set` — matches exactly.
- Talos source (`pkg/machinery/kernel/kernel.go`): `DefaultArgs()` adds
  `module.sig_enforce=1` (gated by
  `quirks.SupportsDisablingModuleSignatureVerification()`, referencing
  https://github.com/siderolabs/talos/issues/11989). `pkg/imager/imager.go`
  applies `kernel.DefaultArgs(q)` *first*, then
  `i.prof.Customization.ExtraKernelArgs` — with the literal comment "first
  defaults, then extra kernel args to allow extra kernel args to override
  defaults". The CLI flag is `--extra-kernel-arg` (confirmed on both the
  `imager` and `installer` commands).

So Talos already has a first-class, intended escape hatch for exactly this
scenario — no need to chase exact signing-key alignment between two separate
`bldr`/BuildKit invocations at all. Both scripts now set
`ZFS_EXTRA_KERNEL_ARGS="--extra-kernel-arg=module.sig_enforce=0"` by default
and thread it into both `IMAGER_ARGS` construction sites (installer build and
eMMC image build). **Bug 7's forced-`--no-cache` kernel-first ordering was
reverted** — `kernel` and `zfs-pkg` are built together normally again, full
caching restored, since an exact key match is no longer required. The bug-6
digest-pinning fix (`PKG_KERNEL_PINNED`) was kept regardless — it's still
useful for guarding against imager picking up a stale *kernel* (e.g. missing
the PCIe patch) under a reused tag, independent of the ZFS signing question.

This does mean module signature verification is fully disabled on this board
— an accepted tradeoff for a personal single-board homelab build, not a
public/multi-tenant trust boundary. **This override turned out to be
ineffective — see Bug 8.**

## Bug 8 — `module.sig_enforce=0` is a no-op; `bool_enable_only` latches one-way

Rebuilt and flashed with the override in place. Same exact failure:
`Loading of module with unavailable key is rejected`. `/proc/cmdline` showed
**both** flags present: `module.sig_enforce=1 module.sig_enforce=0` — the
override was appended correctly, exactly as `pkg/imager/imager.go` intends.
It just doesn't work, because of how this specific kernel parameter is typed.
Confirmed directly from a local kernel source tree
(`kernel/module/signing.c`):

```c
static bool sig_enforce = IS_ENABLED(CONFIG_MODULE_SIG_FORCE);
module_param(sig_enforce, bool_enable_only, 0644);
```

`bool_enable_only` is a one-way latch: it only accepts being set to `true`; a
later attempt to set it `false` is silently ignored at the kernel's cmdline
parameter-parsing level. This is deliberate kernel hardening (so cmdline
injection can't downgrade security by appending `=0`). Talos's "extra kernel
args override defaults" mechanism (`AppendAll` — just literal cmdline
concatenation, not a key-aware merge) works fine for ordinary parameters, but
can never work for `sig_enforce` once Talos's own `DefaultArgs()` has already
set it `=1`. The user correctly pushed back here: production Talos clearly
*does* ship correctly-signed ZFS support via the documented "build kernel +
module together" procedure, so the issue had to be something specific to our
setup, not a fundamental impossibility — this `bool_enable_only` finding
doesn't change that; it just closes off the override as a workaround.

**Removed the override from both scripts** (`ZFS_EXTRA_KERNEL_ARGS` and its
two `IMAGER_ARGS` insertion points) — it never worked and shouldn't linger as
dead/misleading config.

## Cheap test proves `bldr` cache-sharing works; real divergence is pre-existing

Before reaching for a Talos-source patch, tested the actual mechanism in
isolation instead of guessing: built two throwaway packages
(`test-consumer-a`/`-b`) both depending on a shared stage containing
`openssl rand -hex 16` (real non-determinism, like the kernel's signing key).
Built them as two separate `--target=` invocations exactly like
`kernel`/`zfs-pkg` are. Result: the shared stage showed `CACHED` on the
second invocation, and the random output was byte-identical — `bldr`/
BuildKit's cross-invocation cache sharing for a shared non-deterministic
stage works correctly. The earlier "structural bldr limitation" framing in
Bug 7 was wrong.

Ran a one-time clean remediation instead: a disposable `docker-kernel
--no-cache` pass (no push, just forces one genuinely fresh `kernel-build`
execution — confirmed real via `ps aux`, ~100+ min of actual `CC` compiler
output) followed immediately by the normal combined `zfs-pkg`+`kernel`
build/push. **Did not fix it** — kernel digest and zfs.ko signer came back
byte-identical to every previous build, despite the fresh compile definitely
producing new random key bytes. So `--no-cache` forces recomputation for
*that* build, but doesn't make the result available to a *subsequent*
build's normal cache lookup if an older entry already exists for the same
key.

Inspected the actual BuildKit cache directly (`docker buildx du --builder
mybuilder --verbose`): **three separate 15.87GB `kernel-build:finalize
/src -> /src` entries**, each `Usage count: 1` (never reused by any other
build, ever), two dated `2026-06-20` — from *before this session's ZFS work
even started*. This is conclusive: `kernel-build`'s cache has never been
shared across separate `kernel`/`zfs-pkg` `--target=` invocations in this
repo, for reasons predating this investigation entirely.

Tried hard to isolate the specific cause cheaply before giving up on the
caching approach: re-ran the synthetic test with the extra sibling
`image:` dependency that `zfs/pkg.yaml` has and `kernel/pkg.yaml` doesn't
(no difference — still shared correctly); tried matching the exact
no-output-flag asymmetry between the real `docker-kernel` warm-up call and
the real `--tag/--push` call (no difference — still shared correctly); tried
a fast `--build-arg=KERNEL_TARGET=help` variant of the *real*
`kernel/build`+`kernel/kernel` pkg.yaml chain to test without paying for a
full compile (failed for an unrelated reason — that branch of
`kernel/build/pkg.yaml`'s `finalize` doesn't export `/src`, which
`kernel/kernel/pkg.yaml`'s install step requires unconditionally). Ran out of
cheap options for isolating the exact mechanism within reasonable time.

## Final resolution — pinned static signing key

Given the caching investigation came up empty despite genuine effort, and
disabling enforcement was proven ineffective (Bug 8), pivoted to the option
originally declined in favor of investigating caching: generated a **fixed**
signing keypair and committed it as a real build input, so the kernel no
longer auto-generates a random one at all — sidesteps the cross-invocation
cache-sharing question entirely, regardless of its still-unexplained root
cause.

```sh
cd kernel/build/certs
openssl req -new -nodes -utf8 -sha256 -days 36500 -batch \
  -x509 -config x509.genkey \
  -outform PEM -out signing_key.pem -keyout signing_key.pem
```

This is the exact command the kernel's own `certs/Makefile` would run
automatically if `certs/signing_key.pem` didn't exist — not a new mechanism,
just supplying the input ourselves instead of leaving it to chance. Since
`CONFIG_MODULE_SIG_KEY="certs/signing_key.pem"` and `kernel/build/pkg.yaml`'s
prepare step does `cp -v /pkg/certs/* certs/` before building, this file
just needs to exist in `kernel/build/certs/` — no script changes required.
The new file is currently **untracked** (`kernel/build/certs/signing_key.pem`,
mode `0600`) — not committed, since that's a private key and committing it
is the user's call, not something to do silently. Note this is a private key
checked into a homelab repo with a private GitLab registry — acceptable
here since it only satisfies `module.sig_enforce=1` on owned hardware, not a
real trust boundary, but worth keeping in mind if this repo's visibility ever
changes.

This is not the same problem as
[siderolabs/talos#11675](https://github.com/siderolabs/talos/issues/11675)
(closed, unimplemented) — that issue is about inserting a cert into an
**already-built, stock** kernel without recompiling, which needs `System.map`
symbol offsets and, on arm64, unpacking/repacking the zboot-compressed PE32+
image. We compile our own kernel from source already; providing a fixed
signing key before compilation is the standard, documented Linux mechanism
(`Documentation/admin-guide/module-signing.rst`), not exposed to that
fragility.

### Bug 9 — `certs/signing_key.pem` is a literal sentinel filename, not just a default

First attempt placed the static key at exactly `kernel/build/certs/signing_key.pem`
(matching `CONFIG_MODULE_SIG_KEY`'s existing value) and rebuilt. **The kernel
regenerated it anyway** — build log showed `GENKEY certs/signing_key.pem`
despite our file being copied in first. Checked the real kernel source
(`certs/Makefile`) directly:

```make
ifeq ($(CONFIG_MODULE_SIG_KEY),certs/signing_key.pem)
...
$(obj)/signing_key.pem: $(obj)/x509.genkey FORCE
	$(call if_changed,gen_key)
endif
```

The path `certs/signing_key.pem` is a literal **sentinel value**, not just a
default file location — kbuild treats that exact `CONFIG_MODULE_SIG_KEY`
value as "no key supplied, auto-generate one," and the `FORCE` prerequisite
makes the generate rule unconditional, regardless of whether a file already
exists there. The documented way to supply your own key is to point
`CONFIG_MODULE_SIG_KEY` at a **different** path entirely.

Fixed: renamed the key to `kernel/build/certs/static-signing-key.pem` and
changed `CONFIG_MODULE_SIG_KEY` in both `kernel/build/config-arm64` and
`kernel/build/config-amd64` (kept consistent even though amd64 isn't used for
RockPi) to `"certs/static-signing-key.pem"`. No `pkg.yaml` changes needed —
`cp -v /pkg/certs/* certs/` already copies everything in the directory
regardless of filename.

**Confirmed working.** Rebuilt `kernel`+`zfs-pkg` for `v1.13.4-rockpi-zfs`
(real recompile, cert input changed) and directly compared `zfs.ko`'s PKCS7
`issuerAndSerialNumber` against `kernel/build/certs/static-signing-key.pem`'s
own serial:

```text
local cert serial:    7E3483300FE5A10A0400CA9E8BD0B7A6D8609D2A
zfs.ko signer serial: 0x7E3483300FE5A10A0400CA9E8BD0B7A6D8609D2A
```

Byte-identical. This is no longer dependent on cache-sharing luck — both
`kernel` and `zfs-pkg` copy the same fixed file by construction, so the match
is guaranteed regardless of caching behavior between separate `bldr`/BuildKit
invocations (whose cross-invocation sharing for `kernel-build` remains
unexplained — see Bug 7 — but no longer matters for correctness).

This took multiple full kernel recompiles to land on (cache-warm attempt,
wrong-sentinel-filename attempt, then this corrected one) — each a genuine
~1.5-2 hour `make -j$(nproc) && make modules && make dtbs` for full arm64
with all modules, not wasted/duplicated within any single run (verified no
repeated `CC` lines or step resets in the build logs), just inherently slow
on this hardware.

## Next step

Run the full pipeline:

```sh
CUSTOM_TAG=v1.13.4-rockpi-zfs \
hack/build-rockpi-installer-with-verification.sh
```

This now has all nine fixes (crane detection, broken-pipe drain,
cross-platform `crane export`, arm64 architecture guard, DTB-verify default
off, kernel-digest pinning for imager, and the pinned static signing key)
plus the penta-gen2 overlay default and no `module.sig_enforce` override
(removed as ineffective — see Bug 8). `kernel`/`zfs-pkg` are already built
and pushed under this tag with confirmed-matching signing — use
`BUILD_KERNEL=false BUILD_ZFS_PKG=false` to skip rebuilding them, or let it
rebuild normally (should cache-hit since nothing changed since the last
push).

After flashing, confirm with `talosctl ... get extensions` and `dmesg | grep
-Ei 'zfs|module verification|signature'` per "Useful diagnostics" below — the
"key was rejected" lines should be gone entirely, and `lsmod`/`zfs` commands
should work. Only then treat this tag as the reusable known-good ZFS-enabled
image.

## Ready to flash — image built, all checks passed

Ran the full pipeline (`BUILD_KERNEL=false BUILD_ZFS_PKG=false`, reusing the
confirmed-matching `kernel`/`zfs-pkg` from the static-key rebuild). Every
verification step passed cleanly, no mismatches:

- ZFS module signature check passed: 2 signed modules (`spl.ko`, `zfs.ko`)
- ZFS extension matches `zfs-pkg` byte-for-byte
- Private installer, Docker Hub installer, and the eMMC raw image all
  contain the exact custom kernel bytes
- RockPi bootloader area check passed

Artifacts:

```text
Private GitLab installer:
  registry.gitlab.com/cvandesande/dockers/talos-rockpi/installer:v1.13.4-rockpi-zfs
Public Docker Hub installer:
  docker.io/cvandesande/talos:v1.13.4-rockpi-zfs
ZFS system extension:
  registry.gitlab.com/cvandesande/dockers/talos-rockpi/zfs:2.4.2-v1.13.4-rockpi-zfs
eMMC raw image:
  artifacts/rockpi/v1.13.4-rockpi-zfs/talos-v1.13.4-rockpi-zfs-rockpi_4-arm64.raw
eMMC compressed:
  artifacts/rockpi/v1.13.4-rockpi-zfs/talos-v1.13.4-rockpi-zfs-rockpi_4-arm64.raw.xz
```

Flash (user's own call, not run automatically):

```sh
sudo dd if="artifacts/rockpi/v1.13.4-rockpi-zfs/talos-v1.13.4-rockpi-zfs-rockpi_4-arm64.raw" of=/dev/sdX bs=4M conv=fsync status=progress
```

Or upgrade an already-running node:

```sh
export TALOSCONFIG=/home/cvandesande/dockers/talos/tirnanog/generated/talosconfig
talosctl -e whiterock -n whiterock upgrade --image docker.io/cvandesande/talos:v1.13.4-rockpi-zfs
```

After boot, verify with `talosctl ... get extensions` and `dmesg | grep -Ei
'zfs|module verification|signature'` — no "key was rejected" lines expected.

## Current repository state

```text
/home/cvandesande/github/pkgs
branch: rockpi4-pcie-reset-1.13.4
```

Active kernel patch directory contains unrelated patches `0001`-`0005` plus
PCIe patch `0012`. ZFS build wiring already exists: `zfs/pkg.yaml`, `zfs-pkg`
in root `Makefile`'s `TARGETS`, Talos extensions checked out at
`_out/talos-extensions-v1.13.4/`.

The repository is intentionally dirty. Important untracked/generated paths:
`artifacts/`, `staging/`, `kernel/build/patches.disabled/`,
`kernel/build/patches/0012-...patch`, `docs/rockpi-pcie-penta-history.md`
(new). Do not restore, remove, or commit unrelated changes (including the
pre-existing deletion of `docs/nginx-cve-minimal-build-analysis.md`) without
checking with the user. Do not commit `artifacts/` unless explicitly
requested.

SBC repo (`/home/cvandesande/github/sbc-rockchip`) has uncommitted changes
making the Rock Pi U-Boot package apply patches; old Armbian-parity DT patch
preserved under `patches.disabled/clean-no0006/`; active `patches/` has no
`.patch` files.

## Safety and rollback

- Do not use userspace `/dev/mem`, `devmem`, or raw MMIO reads on the live
  board. A previous attempt hung/crashed it and required a power cycle.
- Use a full eMMC flash for U-Boot DTB changes.
- Keep one variable per hardware test.
- Do not remove kernel patch `0012` unless deliberately proving the PCIe
  regression returns.
- Known-good recovery tags: `v1.13.4-rockpi-pcie-perst-timing68-1` and the
  minimised tags in the archive's "Confirmed working history" table.

## Useful diagnostics

```sh
export TALOSCONFIG=/home/cvandesande/dockers/talos/tirnanog/generated/talosconfig

talosctl -e whiterock -n whiterock read /proc/version
talosctl -e whiterock -n whiterock read /proc/cmdline
talosctl -e whiterock -n whiterock get disks
talosctl -e whiterock -n whiterock get extensions
talosctl -e whiterock -n whiterock dmesg |
  grep -Ei 'Linux version|rockchip-pcie|pci 0000:01:00.0|ahci|ata[0-9]: SATA link|fallback|zfs|module verification|signature'
```

Upgrade command:

```sh
talosctl -e whiterock -n whiterock upgrade --image docker.io/cvandesande/talos:<CUSTOM_TAG>
```

Persistent Armbian baseline diagnostics (PCIe kernel narrowing, archival):
`artifacts/diagnostics/rockpi-armbian-pcie-baseline*.tar.gz`.

## Future Talos kernel upgrades (routine, unrelated to ZFS work)

For each Talos release: read the exact `PKGS` revision pinned by that Talos
tag, check out that exact `siderolabs/pkgs` revision, add only the RK3399
PERST patch, build/push the ARM64 `kernel` package, copy its `/boot/vmlinuz`
over the matching official Talos installer's `/usr/install/arm64/vmlinuz`,
upgrade with `talosctl`, verify PCIe plus both SATA disks. Guide/Dockerfile:
`/home/cvandesande/dockers/talos/build/`. This shortcut is safe because it
changes built-in code only. The full `hack/build-rockpi-installer*.sh`
workflow (used now) is for fresh-eMMC/raw image generation, bootloader/DTB
changes, or — as now — adding a new signed kernel module/extension.
