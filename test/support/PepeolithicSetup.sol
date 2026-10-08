// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pepeolithic} from "src/Pepeolithic.sol";
import {MockCoin} from "test/Pepeolithic.t.sol";

/// @dev Reuses the accepted payment mock; no fork, environment changes or storage writes to Pepeolithic.
abstract contract PepeolithicSetup is Test {
    address internal constant COIN = address(bytes20(hex"D782BDEa4EF02a0bD391eB9089470c8080F0A68E"));
    address internal constant ADMIN = address(bytes20(hex"433c8a73bec1273561e4e2201649de12f20b7d58"));
    address internal constant ADAM = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ROOT = 0xbe96ac9140fa07013148f2dd158576ae6cbe2b4a0ce4be64782b37acc9ad0e1b;
    uint256 internal constant START = 1791810000;
    uint256 internal constant FIRST = 1e24;
    uint256 internal constant FLOOR = 1e22;
    uint256 internal constant FUNDS = 1 << 250;

    struct Config {
        address coin;
        address admin;
        address adam;
        bytes32 root;
        uint256 start;
        uint256 caveLength;
        uint256 roundLength;
        uint256 first;
        uint256 floor;
        bytes32[7] labels;
    }

    Pepeolithic internal pepeolithic;
    MockCoin internal coin;

    function _config() internal pure returns (Config memory p) {
        p = Config({
            coin: COIN,
            admin: ADMIN,
            adam: ADAM,
            root: ROOT,
            start: START,
            caveLength: 86400,
            roundLength: 3600,
            first: FIRST,
            floor: FLOOR,
            labels: [
                bytes32("pepeolithic-base-naij"),
                bytes32("pepeolithic-moss-naij"),
                bytes32("pepeolithic-water-naij"),
                bytes32("pepeolithic-ice-naij"),
                bytes32("pepeolithic-lava-naij"),
                bytes32("pepeolithic-crystal-naij"),
                bytes32("pepeolithic-roots-naij")
            ]
        });
    }

    function _deploy(Config memory p) internal returns (Pepeolithic) {
        return new Pepeolithic(
            p.coin,
            p.admin,
            p.adam,
            p.root,
            p.start,
            p.caveLength,
            p.roundLength,
            p.first,
            p.floor,
            p.labels[0],
            p.labels[1],
            p.labels[2],
            p.labels[3],
            p.labels[4],
            p.labels[5],
            p.labels[6]
        );
    }

    function _installCoin() internal {
        MockCoin implementation = new MockCoin();
        vm.etch(COIN, address(implementation).code);
        coin = MockCoin(COIN);
    }

    function _actor(uint256 index) internal pure returns (address) {
        return address(uint160(0x1000 + index));
    }

    function _fund(address who, Pepeolithic target, uint256 amount) internal {
        coin.mint(who, amount);
        vm.prank(who);
        coin.approve(address(target), amount);
    }

    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }

    function _seatTree() internal pure returns (bytes32[16] memory tree) {
        for (uint256 i; i < 8; ++i) {
            tree[8 + i] = keccak256(abi.encodePacked(_actor(i)));
        }
        for (uint256 i = 7; i > 0; --i) {
            tree[i] = _pair(tree[2 * i], tree[2 * i + 1]);
        }
    }

    function _seatProof(uint256 index) internal pure returns (bytes32[] memory proof) {
        bytes32[16] memory tree = _seatTree();
        proof = new bytes32[](3);
        uint256 node = 8 + index;
        for (uint256 i; i < 3; ++i) {
            proof[i] = tree[node ^ 1];
            node /= 2;
        }
    }

    // The allocation oracle comes from the assignment's table, not Pepeolithic's sale helpers.
    function _quota(uint256 c, uint256 r) internal pure returns (uint256) {
        uint256[7] memory quotas = [uint256(1), 1, 2, 3, 4, 4, 4];
        return c == 7 && r == 21 ? 5 : quotas[c - 1];
    }
}
