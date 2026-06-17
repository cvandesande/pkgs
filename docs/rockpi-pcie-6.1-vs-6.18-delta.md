# Rock Pi 4 PCIe: working Armbian 6.1 vs Talos 6.18 delta

This is the evidence log for the Rock Pi 4A PCIe/SATA link-training issue.
The intent is to stop treating the working 6.1 kernel as a vague reference and
instead tie each Talos patch to an observed delta.

## Known-good baseline

Working image:

```text
Armbian_23.11.1_Rockpi-4a_bookworm_current_6.1.63.img.xz
```

Image metadata extracted from `/etc/armbian-release` and Debian package status:

| Item | Value |
|---|---|
| Board | `rockpi-4a` |
| Armbian version | `23.11.1` |
| Armbian build commit | [`014eb55b5b891c86e4bb7865c4a6aaafe41b52c6`](https://github.com/armbian/build/commit/014eb55b5b891c86e4bb7865c4a6aaafe41b52c6) |
| Kernel package | `linux-image-current-rockchip64` |
| Kernel version | `6.1.63-current-rockchip64` |
| Stable kernel source commit | [`69e434a1cb2146a70062d89d507b6132fa38bfe1`](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/commit/?id=69e434a1cb2146a70062d89d507b6132fa38bfe1) |
| U-Boot package | `linux-u-boot-rockpi-4a-current` |
| U-Boot version | `2022.07`, revision `e092e3250270a1016c877da7bdd9384f14b1321e` |

Armbian PCIe-related patches from that exact build commit:

| Patch | Effect |
|---|---|
| `board-rockpi4-0003-arm64-dts-pcie.patch` | Adds `vpcie12v-supply`, sets `vcc3v3_pcie` min/max to 3.3V, and adds `bus-scan-delay-ms = <1500>` to Rock Pi 4 PCIe DT. |
| `rk3399-rp64-pcie-Reimplement-rockchip-PCIe-bus-scan-delay.patch` | Adds Rockchip host support for delaying PCI enumeration after link-up. This does **not** affect link training itself. |

## Boot-log comparison

Working Armbian reaches link-up and then waits before enumeration:

```text
rockchip-pcie f8000000.pcie: host bridge /pcie@f8000000 ranges:
rockchip-pcie f8000000.pcie: wait 1500 ms (from device tree) before bus scan
rockchip-pcie f8000000.pcie: PCI host bridge to bus 0000:00
ahci 0000:01:00.0: AHCI ... 5 ports 6 Gbps ...
```

Failing Talos 6.18 reaches the controller but fails before the Armbian-style
bus-scan delay can run:

```text
Linux version 6.18.34-talos ... Wed Jun 17 16:30:19 UTC 2026
rockchip-pcie f8000000.pcie: host bridge /pcie@f8000000 ranges:
rockchip-pcie f8000000.pcie: PCIe link training gen1 timeout!
rockchip-pcie f8000000.pcie: probe with driver rockchip-pcie failed with error -110
```

Conclusion: `bus-scan-delay-ms` is real and present, but it is not the current
failure point. The failure is before PCI enumeration.

## Device-tree comparison

The current Talos live FDT is semantically aligned with the working Armbian DT
for the PCIe node:

| Property | Working Armbian 6.1 | Talos 6.18 live FDT | Meaning |
|---|---:|---:|---|
| `status` | `okay` | `okay` | PCIe controller enabled |
| `num-lanes` | `4` | `4` | x4 RK3399 PCIe |
| `max-link-speed` | `1` | `1` | force Gen1 |
| `bus-scan-delay-ms` | `1500` | `1500` | post-link enumeration delay |
| `vpcie12v-supply` | present | present | 12V supply phandle present |
| `vpcie3v3-supply` | present | present | 3.3V PCIe regulator phandle present |
| `vcc3v3_pcie` min/max | `3300000` | `3300000` | 3.3V fixed regulator constrained |
| PCIe PHY node | `okay` | `okay` | RK3399 PCIe PHY enabled |

Phandle numeric values differ, but that is normal and not meaningful by itself.

## Scoped PCIe init deltas

| Area | Working 6.1 behavior | Current 6.18 behavior after our patches | Status |
|---|---|---|---|
| Rock Pi 4 PCIe DT supplies/timing | Armbian adds 12V supply, 3.3V min/max, 1500ms bus-scan delay | `0006` applies the same semantic DT properties | Aligned |
| Bus-scan delay | Runs after link-up, before enumeration | `0007` implements it, but failing kernel never reaches it | Aligned but not causal |
| PM reset order | assert `aclk -> pclk -> pm`; deassert `pm -> aclk -> pclk` | `0008` preserves that order despite 6.18 bulk reset conversion | Aligned |
| Core reset order | assert `core -> mgmt -> mgmt-sticky -> pipe`; deassert `mgmt-sticky -> core -> mgmt -> pipe` | `0008` preserves assert order and keeps bulk deassert because reverse bulk order matches 6.1 | Aligned |
| PHY lane de-idle | first lane de-idled after shared PHY reset deassert | 6.18 de-idles lanes before shared reset deassert; an earlier local patch tried changing this but did not fix the link | De-prioritized; unproven patch removed |
| PERST#/LTSSM timing | enable Gen1 training immediately before PERST# release | upstream 6.18 enables Gen1 training, waits 100ms with endpoint still in reset, then releases PERST# | **Current top candidate** |

## Upstream commits behind the top remaining delta

The PERST# behavior changed after the working 6.1 baseline:

| Commit | Date | Effect |
|---|---:|---|
| [`c47f90be4c89`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c47f90be4c89d14051d43f0c88eafddf67c834ea) | 2024-07-09 | Adds `msleep(PCIE_T_PVPERL_MS)` before PERST# deassert, but leaves link training enabled before that sleep. |
| [`70a7bfb1e515`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=70a7bfb1e515b03e54491254a4375cdfb9515227) | 2024-07-09 | Adds the 100ms post-PERST# reset-to-config wait. |
| [`bbc6a829ad3f`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=bbc6a829ad3f054181d24a56944f944002e68898) | 2025-06-25 | Renames the post-reset wait macro to `PCIE_RESET_CONFIG_WAIT_MS`; behavior remains 100ms. |

The patch now in this repo keeps the spec waits but moves the T_PVPERL wait
before link-training enable:

```text
wait T_PVPERL while PERST# remains asserted
enable Gen1 link training
deassert PERST#
wait PCIE_RESET_CONFIG_WAIT_MS before config/poll path continues
```

This restores the working 6.1 relationship that link training is enabled
immediately before endpoint reset is released, while preserving the upstream
timing intent.

## Confidence

| Claim / next action | Confidence |
|---|---:|
| The current failure happens before PCI enumeration and before `bus-scan-delay-ms` can matter. | High |
| The live Talos DT now matches the working Armbian PCIe DT semantics. | High |
| Reset-order-only and PHY-lane-idle-only were not sufficient, based on booted test images. | High |
| PERST#/LTSSM ordering is the highest-value next kernel rebuild candidate. | Medium |
| The new PERST#/LTSSM patch will fix this specific SATA card link-up. | Medium-low until tested |
