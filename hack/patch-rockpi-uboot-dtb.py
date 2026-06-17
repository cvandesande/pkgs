#!/usr/bin/env python3
"""Patch or verify Rock Pi 4A PCIe properties in U-Boot embedded FDTs.

The Talos sbc-rockchip RockPi image boots via U-Boot/EFI. On this board the
Linux kernel receives a DTB from U-Boot, so patching the kernel package DTB is
not enough for early PCIe bring-up. This helper scans a raw disk image for FDT
blobs, finds the U-Boot-provided Rock Pi 4A DTB, and applies the same PCIe
device-tree alignment used by the working Armbian 6.1.63 image:

  - /pcie@f8000000: vpcie12v-supply = <&vcc12v_dcin>
  - /pcie@f8000000: bus-scan-delay-ms = <1500>
  - /vcc3v3-pcie-regulator: regulator-min/max-microvolt = <3300000>

Prefer applying these properties at the sbc-rockchip/U-Boot source level. The
patching mode is retained as a last-resort recovery tool, but generated
U-Boot/Rockchip blobs may contain FIT hashes or other integrity metadata, so
post-build binary mutation is not the normal path.

This intentionally implements only the small subset of flattened device tree
inspection/editing needed for this workflow; it has no external dependencies.
"""

from __future__ import annotations

import argparse
import struct
import sys
from dataclasses import dataclass
from pathlib import Path


FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9

ROCKPI4A_MODEL = "Radxa ROCK Pi 4A"
PCIE_NODE = "/pcie@f8000000"
VCC12_NODE_CANDIDATES = ("/dc-12v", "/regulator-dc-12v")
VCC3V3_PCIE_NODE_CANDIDATES = (
    "/vcc3v3-pcie-regulator",
    "/regulator-vcc3v3-pcie",
)


def align4(value: int) -> int:
    return (value + 3) & ~3


def be32(value: int) -> bytes:
    return struct.pack(">I", value)


def read_be32(buf: bytes | bytearray | memoryview, off: int) -> int:
    return struct.unpack_from(">I", buf, off)[0]


def cstring(buf: bytes | bytearray | memoryview, off: int) -> bytes:
    end = buf.find(b"\x00", off)
    if end < 0:
        raise ValueError("unterminated FDT string")
    return bytes(buf[off:end])


@dataclass
class Header:
    magic: int
    totalsize: int
    off_dt_struct: int
    off_dt_strings: int
    off_mem_rsvmap: int
    version: int
    last_comp_version: int
    boot_cpuid_phys: int
    size_dt_strings: int
    size_dt_struct: int

    @classmethod
    def parse(cls, blob: bytes) -> "Header":
        if len(blob) < 40:
            raise ValueError("blob too small for FDT header")
        values = struct.unpack_from(">10I", blob, 0)
        header = cls(*values)
        if header.magic != FDT_MAGIC:
            raise ValueError("not an FDT")
        if header.totalsize > len(blob):
            raise ValueError("truncated FDT")
        return header

    def pack(self) -> bytes:
        return struct.pack(
            ">10I",
            self.magic,
            self.totalsize,
            self.off_dt_struct,
            self.off_dt_strings,
            self.off_mem_rsvmap,
            self.version,
            self.last_comp_version,
            self.boot_cpuid_phys,
            self.size_dt_strings,
            self.size_dt_struct,
        )


@dataclass
class NodeInfo:
    path: str
    end_token_off: int
    prop_insert_off: int
    props: dict[str, tuple[int, int, bytes]]


class Fdt:
    def __init__(self, blob: bytes):
        self.header = Header.parse(blob)
        self.reserve = bytes(blob[self.header.off_mem_rsvmap : self.header.off_dt_struct])
        self.struct = bytearray(
            blob[
                self.header.off_dt_struct : self.header.off_dt_struct
                + self.header.size_dt_struct
            ]
        )
        self.strings = bytearray(
            blob[
                self.header.off_dt_strings : self.header.off_dt_strings
                + self.header.size_dt_strings
            ]
        )
        self.nodes = self._parse_nodes()

    def _string_at(self, off: int) -> str:
        return cstring(self.strings, off).decode("ascii")

    def _parse_nodes(self) -> dict[str, NodeInfo]:
        nodes: dict[str, NodeInfo] = {}
        # stack entries: (path, props, property_insert_offset). The insert
        # offset tracks the end of the initial property block. libfdt expects
        # properties to appear before subnodes; inserting just before END_NODE
        # can hide them from normal libfdt property iteration when a node has
        # children.
        stack: list[tuple[str, dict[str, tuple[int, int, bytes]], int]] = []
        off = 0

        while off < len(self.struct):
            token_off = off
            token = read_be32(self.struct, off)
            off += 4

            if token == FDT_BEGIN_NODE:
                name_bytes = cstring(self.struct, off)
                off = align4(off + len(name_bytes) + 1)
                name = name_bytes.decode("ascii")
                if not stack:
                    path = "/"
                else:
                    parent = stack[-1][0]
                    path = parent.rstrip("/") + "/" + name
                stack.append((path, {}, off))

            elif token == FDT_PROP:
                length = read_be32(self.struct, off)
                nameoff = read_be32(self.struct, off + 4)
                value_off = off + 8
                value = bytes(self.struct[value_off : value_off + length])
                prop_start = token_off
                prop_end = align4(value_off + length)
                off = prop_end
                if not stack:
                    raise ValueError("FDT property outside node")
                path, props, _ = stack[-1]
                props[self._string_at(nameoff)] = (prop_start, prop_end, value)
                stack[-1] = (path, props, prop_end)

            elif token == FDT_END_NODE:
                if not stack:
                    raise ValueError("FDT END_NODE without BEGIN_NODE")
                path, props, prop_insert_off = stack.pop()
                nodes[path] = NodeInfo(
                    path=path,
                    end_token_off=token_off,
                    prop_insert_off=prop_insert_off,
                    props=props,
                )

            elif token == FDT_NOP:
                continue

            elif token == FDT_END:
                break

            else:
                raise ValueError(f"unknown FDT token {token} at structure offset {token_off}")

        return nodes

    def get_prop(self, path: str, prop: str) -> bytes | None:
        node = self.nodes.get(path)
        if not node:
            return None
        entry = node.props.get(prop)
        return entry[2] if entry else None

    def get_u32(self, path: str, prop: str) -> int | None:
        value = self.get_prop(path, prop)
        if value is None or len(value) != 4:
            return None
        return read_be32(value, 0)

    def get_string(self, path: str, prop: str) -> str | None:
        value = self.get_prop(path, prop)
        if value is None:
            return None
        return value.rstrip(b"\x00").decode("ascii", errors="replace")

    def _string_offset(self, name: str) -> int:
        needle = name.encode("ascii") + b"\x00"
        pos = self.strings.find(needle)
        if pos >= 0:
            return pos
        pos = len(self.strings)
        self.strings.extend(needle)
        return pos

    def _prop_record(self, name: str, value: bytes) -> bytes:
        nameoff = self._string_offset(name)
        padded_len = align4(len(value))
        return (
            be32(FDT_PROP)
            + be32(len(value))
            + be32(nameoff)
            + value
            + (b"\x00" * (padded_len - len(value)))
        )

    def add_missing_u32_props(self, path: str, props: dict[str, int]) -> bool:
        node = self.nodes[path]
        records: list[bytes] = []
        changed = False

        for name, value in props.items():
            desired = be32(value)
            current = node.props.get(name)
            if current and current[2] == desired:
                continue
            if current:
                raise ValueError(
                    f"{path}:{name} exists with unexpected value/length; refusing duplicate"
                )
            records.append(self._prop_record(name, desired))
            changed = True

        if records:
            insert = b"".join(records)
            self.struct[node.prop_insert_off:node.prop_insert_off] = insert
            self.nodes = self._parse_nodes()

        return changed

    def to_bytes(self) -> bytes:
        # Pack with the conventional layout: 40-byte header, reserve map,
        # structure block, strings block.
        off_mem_rsvmap = 40
        off_dt_struct = align4(off_mem_rsvmap + len(self.reserve))
        reserve_pad = b"\x00" * (off_dt_struct - (off_mem_rsvmap + len(self.reserve)))
        off_dt_strings = align4(off_dt_struct + len(self.struct))
        struct_pad = b"\x00" * (off_dt_strings - (off_dt_struct + len(self.struct)))
        totalsize = off_dt_strings + len(self.strings)

        header = Header(
            magic=FDT_MAGIC,
            totalsize=totalsize,
            off_dt_struct=off_dt_struct,
            off_dt_strings=off_dt_strings,
            off_mem_rsvmap=off_mem_rsvmap,
            version=self.header.version,
            last_comp_version=self.header.last_comp_version,
            boot_cpuid_phys=self.header.boot_cpuid_phys,
            size_dt_strings=len(self.strings),
            size_dt_struct=len(self.struct),
        )

        return header.pack() + self.reserve + reserve_pad + self.struct + struct_pad + self.strings


def prop_strings(value: bytes | None) -> list[str]:
    if value is None:
        return []
    return [
        part.decode("ascii", errors="replace")
        for part in value.rstrip(b"\x00").split(b"\x00")
        if part
    ]


def find_node_by_string_prop(
    fdt: Fdt,
    prop: str,
    wanted: str,
    candidates: tuple[str, ...] = (),
) -> str | None:
    for path in candidates:
        if wanted in prop_strings(fdt.get_prop(path, prop)):
            return path

    matches = [
        path
        for path in sorted(fdt.nodes)
        if wanted in prop_strings(fdt.get_prop(path, prop))
    ]
    if matches:
        return matches[0]
    return None


def get_phandle(fdt: Fdt, path: str) -> int | None:
    return fdt.get_u32(path, "phandle") or fdt.get_u32(path, "linux,phandle")


def rockpi4a_pcie_nodes(fdt: Fdt) -> tuple[str | None, str | None, str | None]:
    pcie = PCIE_NODE if PCIE_NODE in fdt.nodes else None
    vcc12 = find_node_by_string_prop(
        fdt,
        "regulator-name",
        "vcc12v_dcin",
        VCC12_NODE_CANDIDATES,
    )
    vcc3v3 = find_node_by_string_prop(
        fdt,
        "regulator-name",
        "vcc3v3_pcie",
        VCC3V3_PCIE_NODE_CANDIDATES,
    )
    return pcie, vcc12, vcc3v3


def patch_fdt(blob: bytes) -> tuple[bytes, bool, str]:
    fdt = Fdt(blob)
    model = fdt.get_string("/", "model") or ""

    if model != ROCKPI4A_MODEL:
        return blob, False, f"skip model={model!r}"

    pcie_node, vcc12_node, vcc3v3_node = rockpi4a_pcie_nodes(fdt)
    if pcie_node is None:
        return blob, False, f"skip {ROCKPI4A_MODEL}: missing {PCIE_NODE}"
    if vcc12_node is None:
        return blob, False, f"skip {ROCKPI4A_MODEL}: missing vcc12v_dcin regulator"
    if vcc3v3_node is None:
        return blob, False, f"skip {ROCKPI4A_MODEL}: missing vcc3v3_pcie regulator"

    vcc12_phandle = get_phandle(fdt, vcc12_node)
    if vcc12_phandle is None:
        return blob, False, f"skip Rock Pi 4A: {vcc12_node} lacks phandle"

    changed = False
    changed |= fdt.add_missing_u32_props(
        pcie_node,
        {
            "vpcie12v-supply": vcc12_phandle,
            "bus-scan-delay-ms": 1500,
        },
    )
    changed |= fdt.add_missing_u32_props(
        vcc3v3_node,
        {
            "regulator-min-microvolt": 3300000,
            "regulator-max-microvolt": 3300000,
        },
    )

    if not changed:
        return blob, False, "already patched Rock Pi 4A"

    out = fdt.to_bytes()
    # Parse once more as a sanity check.
    check = Fdt(out)
    expected = {
        (pcie_node, "vpcie12v-supply"): vcc12_phandle,
        (pcie_node, "bus-scan-delay-ms"): 1500,
        (vcc3v3_node, "regulator-min-microvolt"): 3300000,
        (vcc3v3_node, "regulator-max-microvolt"): 3300000,
    }
    for (node, prop), value in expected.items():
        actual = check.get_u32(node, prop)
        if actual != value:
            raise ValueError(f"verification failed for {node}:{prop}: {actual} != {value}")

    return out, True, f"patched Rock Pi 4A vcc12_phandle={vcc12_phandle}"


def verify_fdt(blob: bytes) -> tuple[bool, bool, str]:
    """Return (is_applicable, is_valid, message) for a single FDT blob."""

    fdt = Fdt(blob)
    model = fdt.get_string("/", "model") or ""

    if model != ROCKPI4A_MODEL:
        return False, False, f"skip model={model!r}"

    pcie_node, vcc12_node, vcc3v3_node = rockpi4a_pcie_nodes(fdt)
    if pcie_node is None:
        # U-Boot images can contain small SPL/control FDTs with the board model
        # but without the Linux hand-off PCIe node. Do not count those as
        # failing candidate DTBs.
        return False, False, f"skip Rock Pi 4A without {PCIE_NODE}"

    missing = []
    if vcc12_node is None:
        missing.append("regulator-name=vcc12v_dcin")
    if vcc3v3_node is None:
        missing.append("regulator-name=vcc3v3_pcie")
    if missing:
        return True, False, "Rock Pi 4A missing nodes: " + ", ".join(missing)

    vcc12_phandle = get_phandle(fdt, vcc12_node)
    if vcc12_phandle is None:
        return True, False, f"Rock Pi 4A {vcc12_node} lacks phandle"

    expected = {
        (pcie_node, "vpcie12v-supply"): vcc12_phandle,
        (pcie_node, "bus-scan-delay-ms"): 1500,
        (vcc3v3_node, "regulator-min-microvolt"): 3300000,
        (vcc3v3_node, "regulator-max-microvolt"): 3300000,
    }
    vcc3v3_phandle = get_phandle(fdt, vcc3v3_node)
    if vcc3v3_phandle is not None and fdt.get_u32(pcie_node, "vpcie3v3-supply") is not None:
        expected[(pcie_node, "vpcie3v3-supply")] = vcc3v3_phandle

    failures: list[str] = []
    for (node, prop), value in expected.items():
        actual = fdt.get_u32(node, prop)
        if actual != value:
            failures.append(f"{node}:{prop}={actual!r}, expected {value!r}")

    if failures:
        return True, False, "Rock Pi 4A PCIe DTB verification failed: " + "; ".join(failures)

    return (
        True,
        True,
        f"verified Rock Pi 4A pcie={pcie_node} vcc12={vcc12_node} "
        f"vcc3v3={vcc3v3_node} vcc12_phandle={vcc12_phandle}",
    )


def patch_image(path: Path) -> tuple[int, int]:
    data = bytearray(path.read_bytes())
    magic = be32(FDT_MAGIC)
    patched = 0
    applicable = 0
    scanned = 0
    pos = 0

    while True:
        off = data.find(magic, pos)
        if off < 0:
            break
        pos = off + 4
        if off + 40 > len(data):
            continue
        try:
            totalsize = read_be32(data, off + 4)
            if totalsize <= 40 or off + totalsize > len(data):
                continue
            blob = bytes(data[off : off + totalsize])
            new_blob, changed, message = patch_fdt(blob)
        except Exception as exc:  # keep scanning other magic locations
            print(f"skip FDT at offset {off}: {exc}", file=sys.stderr)
            continue

        scanned += 1
        print(f"FDT at offset {off}: {message}", file=sys.stderr)
        if (
            message.startswith("patched Rock Pi 4A")
            or message.startswith("already patched Rock Pi 4A")
        ):
            applicable += 1
        if not changed:
            continue

        if len(new_blob) < len(blob):
            new_blob = new_blob + (b"\x00" * (len(blob) - len(new_blob)))
        elif len(new_blob) > len(blob):
            # Allow growth only into zero-filled padding before the next payload.
            extra = len(new_blob) - len(blob)
            tail = data[off + len(blob) : off + len(blob) + extra]
            if len(tail) != extra or any(tail):
                raise SystemExit(
                    f"patched FDT at offset {off} grew by {extra} bytes but no zero padding is available"
                )

        data[off : off + len(new_blob)] = new_blob
        patched += 1

    if patched:
        path.write_bytes(data)

    print(f"scanned_fdt={scanned} patched_fdt={patched}", file=sys.stderr)
    return patched, applicable


def verify_image(path: Path) -> tuple[int, int]:
    data = path.read_bytes()
    magic = be32(FDT_MAGIC)
    applicable = 0
    valid = 0
    scanned = 0
    pos = 0

    while True:
        off = data.find(magic, pos)
        if off < 0:
            break
        pos = off + 4
        if off + 40 > len(data):
            continue
        try:
            totalsize = read_be32(data, off + 4)
            if totalsize <= 40 or off + totalsize > len(data):
                continue
            blob = bytes(data[off : off + totalsize])
            is_applicable, is_valid, message = verify_fdt(blob)
        except Exception as exc:  # keep scanning other magic locations
            print(f"skip FDT at offset {off}: {exc}", file=sys.stderr)
            continue

        scanned += 1
        print(f"FDT at offset {off}: {message}", file=sys.stderr)
        if is_applicable:
            applicable += 1
        if is_valid:
            valid += 1

    print(f"scanned_fdt={scanned} applicable_fdt={applicable} verified_fdt={valid}", file=sys.stderr)
    return valid, applicable


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("raw_image", type=Path)
    parser.add_argument("--require-patch", action="store_true")
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()

    if args.verify_only:
        valid, applicable = verify_image(args.raw_image)
        if applicable == 0:
            raise SystemExit("no applicable Rock Pi 4A U-Boot DTB was found")
        if valid == 0:
            raise SystemExit("no Rock Pi 4A U-Boot DTB had the expected PCIe properties")
        return 0

    patched, applicable = patch_image(args.raw_image)
    if args.require_patch and applicable == 0:
        raise SystemExit("no applicable Rock Pi 4A U-Boot DTB was found")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
