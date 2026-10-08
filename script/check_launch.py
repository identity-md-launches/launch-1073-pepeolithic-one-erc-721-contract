#!/usr/bin/env python3
"""Offline deployment-handoff checks. Run forge build first. Never broadcasts."""

import hashlib
import json
import re
from pathlib import Path


def check():
    root = Path(__file__).resolve().parents[1]
    # Formatting may change; executable logic may differ only in collection identity.
    source = (root / "src/Pepeolithic.sol").read_text()
    normalized = source.replace("Pepeolithic", "Ochre").replace('"PEPEO"', '"OCHRE"')
    digest = hashlib.sha256(re.sub(r"\s+", "", normalized).encode()).hexdigest()
    assert digest == "2d4e3ee8a4fa5b0ed1c5706369b8c27ef89970a6ef0a5bc5de9a8aa60c5d446e", "Pinned source mismatch"
    manifest = json.loads((root / "launch.json").read_text())
    assert set(manifest) == {"kind", "contracts", "notes"}
    assert manifest["kind"] == "evm_contracts"
    assert len(manifest["contracts"]) == 1
    entry = manifest["contracts"][0]
    assert set(entry) == {"contract", "constructorArgs"}
    assert entry["contract"] == "Pepeolithic"
    args = entry["constructorArgs"]
    assert len(args) == 16, "Manifest permits at most sixteen static arguments"
    artifact = json.loads((root / "out/Pepeolithic.sol/Pepeolithic.json").read_text())
    constructor = next(item for item in artifact["abi"] if item["type"] == "constructor")
    assert constructor["stateMutability"] == "nonpayable"
    assert [item["type"] for item in constructor["inputs"]] == (
        ["address"] * 3 + ["bytes32"] + ["uint256"] * 5 + ["bytes32"] * 7
    )
    assert args[:9] == [
        "0xd782bdea4ef02a0bd391eb9089470c8080f0a68e",
        "0x433c8a73bec1273561e4e2201649de12f20b7d58",
        "0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7",
        "0xbe96ac9140fa07013148f2dd158576ae6cbe2b4a0ce4be64782b37acc9ad0e1b",
        "1791810000", "86400", "3600", "1000000000000000000000000", "10000000000000000000000",
    ]
    labels = [f"pepeolithic-{suffix}-naij" for suffix in ["base", "moss", "water", "ice", "lava", "crystal", "roots"]]
    for value, label in zip(args[9:], labels):
        assert value == "0x" + label.encode("ascii").hex().ljust(64, "0")
        assert bytes.fromhex(value[2:]).rstrip(b"\0").decode("ascii") == label

    code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(code) < 9000, f"Runtime is {len(code)} bytes"
    index = 0
    while index < len(code):
        opcode = code[index]
        assert opcode not in (0xF4, 0xF2, 0xFF), f"Forbidden opcode at byte {index}"
        index += 1 + (opcode - 0x5F if 0x60 <= opcode <= 0x7F else 0)
    assert not artifact["deployedBytecode"].get("linkReferences"), "Unlinked dependency"
    assert not artifact["bytecode"].get("linkReferences"), "Unlinked constructor dependency"
    print(f"Pepeolithic: 16 static arguments, 7 verified labels, {len(code)} runtime bytes; launch checks pass.")


if __name__ == "__main__":
    check()
