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
| Rock Pi 4 PCIe DT supplies/timing | Armbian adds 12V supply, 3.3V min/max, 1500ms bus-scan delay | `0006` applies the same semantic DT properties | Disabled for current full-eMMC candidate `min-only0012-1` |
| Bus-scan delay | Runs after link-up, before enumeration | `0007` implements it, but failing kernel never reaches it | Confirmed removable in `min-only0012-plus-dt-1` |
| PM reset order | assert `aclk -> pclk -> pm`; deassert `pm -> aclk -> pclk` | `0008` preserves that order despite 6.18 bulk reset conversion | Confirmed removable in `min-no0010-no0009-no0008-1` |
| Core reset order | assert `core -> mgmt -> mgmt-sticky -> pipe`; deassert `mgmt-sticky -> core -> mgmt -> pipe` | `0008` preserves assert order and keeps bulk deassert because reverse bulk order matches 6.1 | Confirmed removable in `min-no0010-no0009-no0008-1` |
| PHY lane de-idle | only the first shared PHY power-on de-idles a lane, after shared PHY reset deassert and PLL-lock address selection | `0009` restores the 6.1 behavior by moving the de-idle write after reset deassert and behind the `pwr_cnt++` early return | Confirmed removable in `min-no0010-no0009-1` |
| PHY TEST_WRITE strobe disable | `PHY_CFG_WR_DISABLE` has the same value as `PHY_CFG_WR_ENABLE`, so the write strobe is not cleared after each PHY config write | `0009` restores that 6.1 behavior | Confirmed removable in `min-no0010-no0009-1` |
| PHY refclk lifecycle | probe gets `refclk`, PHY init prepares/enables it, PHY exit disables/unprepares it | `0010` restores the 6.1 lifecycle instead of 6.18 probe-lifetime `devm_clk_get_enabled()` | Confirmed removable in `min-no0010-1` |
| PERST GPIO initial state | working 6.8 requested RC endpoint/PERST GPIO as `GPIOD_OUT_HIGH` | `0011` restores that state for RK3399 only | Confirmed removable in `min-no0010-no0009-no0008-no0011-1` |
| PERST release timing | working 6.8 enabled Gen1 training, released PERST immediately, then polled link-up | `0012` skips the newer 100 ms pre-release and 100 ms post-release waits for RK3399 only | Confirmed fixed in current stack |

## PHY deltas tested so far

Two PHY behaviors changed after the working 6.1 baseline:

| Commit | Date | Effect |
|---|---:|---|
| [`c3fe7071e196`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=c3fe7071e196e25789ecf90dbc9e8491a98884d7) | 2025-07-22 | Moves the lane de-idle write before the shared PHY power counter so all four RK3399 lanes are enabled through GRF. |
| [`25facbabc3fc`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/?id=25facbabc3fc) | 2025-07-22 | Properly clears the PHY TEST_WRITE strobe after config writes by changing `PHY_CFG_WR_DISABLE` from `1` to `0`. |

`0009` restores the working 6.1 relationship:

```text
if this is not the first shared PHY power-on, return immediately
deassert shared PHY reset
select PLL-lock config address
take the first lane out of idle
```

This does intentionally drop the newer all-lane de-idle behavior for this
compatibility build, because the known-good Rock Pi 4A / SATA card baseline did
not do that.  The resulting `v1.13.4-rockpi-pcie-phy61-strobe1` image booted,
but still failed with `PCIe link training gen1 timeout!`, so these PHY changes
were not sufficient.

## Confirmed 6.8 PERST timing fix

Armbian narrowing moved the useful regression window from "6.1 vs 6.18" to
"6.8.11 works, 6.12.x fails".  The Armbian Rockchip64 PCIe patch stack is
semantically unchanged across that boundary.  The final working change was an
upstream Rockchip host-driver PERST timing delta:

| Path | PERST/link-training behavior |
|---|---|
| Working 6.8 | enable Gen1 link training, release PERST immediately, then poll link-up |
| Failing 6.12+/6.18 | add a 100 ms wait before PERST release and another 100 ms reset-to-config wait before link polling |
| `0012` | restores the 6.8 timing for `rockchip,rk3399-pcie` only; confirmed working in `v1.13.4-rockpi-pcie-perst-timing68-1` |

Confirmed Talos result:

```text
rockchip-pcie f8000000.pcie: wait 1500 ms (from device tree) before bus scan
pci 0000:01:00.0: [197b:0585] type 00 class 0x010601 PCIe Legacy Endpoint
pci 0000:01:00.0: 4.000 Gb/s available PCIe bandwidth, limited by 2.5 GT/s PCIe x2 link
ahci 0000:01:00.0: AHCI vers 0001.0301, 32 command slots, 6 Gbps, SATA mode
ata1: SATA link up 6.0 Gbps
ata3: SATA link up 6.0 Gbps
talosctl get disks: sda and sdb, both Samsung SSD 860, 2.0 TB, transport=sata
```

## Confidence

| Claim / next action | Confidence |
|---|---:|
| The current failure happens before PCI enumeration and before `bus-scan-delay-ms` can matter. | High |
| The live Talos DT now matches the working Armbian PCIe DT semantics. | High |
| Reset-order-only and PERST-order-only were not sufficient, based on booted test images. | High |
| Exact 6.1 RK3399 PHY lane de-idle and TEST_WRITE strobe behavior were not sufficient by themselves. | High |
| Restoring the 6.1 RK3399 PHY refclk lifecycle was not sufficient. | High |
| `0011` initial PERST GPIO state alone was not sufficient. | High |
| `0012` is a real 6.8-working to 6.12-failing upstream timing divergence. | High |
| `0012` fixed this specific SATA card link-up in the current stack. | High |
| `0012` is the decisive final change in the current stack, because `0011` alone failed and adding `0012` worked. | Medium-high |
| Removing `0010` while keeping `0012` still works. | High |
| Removing `0009` while keeping `0012` still works. | High |
| Removing `0008` while keeping `0012` still works. | High |
| Removing `0011` while keeping `0012` still works. | High |
| Removing `0007`/bus-scan-delay support still works. | High |
| Current confirmed kernel-side minimum is `0012` plus the previously active DT patch `0006`. | High |
| Current full-eMMC candidate removes `0006`, leaving only `0012`. | Medium-low |
| Older compatibility patches have not yet been minimized away; do not remove them outside a controlled minimization pass. | High |

## Later performance backlog

After minimization and stability testing, run a separate PCIe Gen2 x2
experiment by changing the RockPi PCIe DT from:

```dts
max-link-speed = <1>;
```

to:

```dts
max-link-speed = <2>;
```

Do not combine this with minimization. The current Gen1 x2 limit is expected
and known-good. Gen2 x2 may be possible; Gen3 x2 is not a realistic RK3399 /
RockPi target even if the SATA endpoint advertises Gen3 capability.
