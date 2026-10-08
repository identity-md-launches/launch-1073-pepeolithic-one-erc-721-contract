// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Pepeolithic} from "../src/Pepeolithic.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

contract MockCoin {
    error InsufficientBalance();
    error InsufficientAllowance();
    error CoinReverted();

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    bool public returnsFalse;
    bool public throws;
    Pepeolithic public callback;
    uint256 public callbackCave;
    uint256 public callbackRound;
    bool public reenter;
    bool public reenterLeftover;
    uint256 public nestedId;
    uint256 public observedSold;
    uint256 public observedSupply;
    address public lastFrom;
    address public lastTo;
    uint256 public lastAmount;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function fail(bool falseResult, bool revertResult) external {
        returnsFalse = falseResult;
        throws = revertResult;
    }

    function arm(Pepeolithic target, uint256 c, uint256 r, bool leftover) external {
        callback = target;
        callbackCave = c;
        callbackRound = r;
        reenter = true;
        reenterLeftover = leftover;
        balanceOf[address(this)] = 1 ether;
        allowance[address(this)][address(target)] = 1 ether;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (throws) revert CoinReverted();
        if (balanceOf[from] < amount) revert InsufficientBalance();
        if (allowance[from][msg.sender] < amount) revert InsufficientAllowance();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        lastFrom = from;
        lastTo = to;
        lastAmount = amount;
        if (reenter) {
            reenter = false;
            observedSupply = callback.totalSupply();
            if (reenterLeftover) {
                nestedId = callback.buyLeftover();
            } else {
                observedSold = callback.roundSold(callbackCave, callbackRound);
                nestedId = callback.buy(callbackCave, callbackRound);
            }
        }
        return !returnsFalse;
    }
}

contract NoReturnCoin {
    fallback() external {}
}

contract NoReceiver {
    // Intentionally no ERC721 receiver implementation.
    function buy(Pepeolithic target, uint256 c, uint256 r) external returns (uint256) {
        MockCoin(target.coin()).approve(address(target), 1 ether);
        return target.buy(c, r);
    }
}

contract PepeolithicTest is Test {
    address internal constant COIN = address(bytes20(hex"D782BDEa4EF02a0bD391eB9089470c8080F0A68E"));
    address internal constant ADMIN = address(bytes20(hex"433c8a73bec1273561e4e2201649de12f20b7d58"));
    address internal constant ADAM = 0x047F606fD5b2BaA5f5C6c4aB8958E45CB6B054B7;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;
    bytes32 internal constant ROOT = 0xbe96ac9140fa07013148f2dd158576ae6cbe2b4a0ce4be64782b37acc9ad0e1b;
    uint256 internal constant START = 1791810000;
    // Short, inexpensive fixtures exercise constructor configurability. Mainnet checks use 1e24/1e22.
    uint256 internal constant FIRST = 0.004 ether;
    uint256 internal constant FLOOR = 0.0004 ether;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    Pepeolithic internal pepeolithic;
    MockCoin internal coin;

    event Bought(uint256 indexed id, address indexed buyer, uint256 price);
    event Claimed(uint256 indexed id, address indexed wallet);
    event Swept(uint256 indexed id);
    event Frozen(uint256 indexed cave, string base);
    event UnclaimedReleased();

    function setUp() public {
        pepeolithic = _deploy(ROOT, 3600, 150, FIRST, FLOOR);
        MockCoin template = new MockCoin();
        vm.etch(COIN, address(template).code);
        coin = MockCoin(COIN);
        _fund(ALICE, pepeolithic);
        _fund(BOB, pepeolithic);
    }

    function _deploy(bytes32 root, uint256 caveLen, uint256 roundLen, uint256 first, uint256 floor)
        internal
        returns (Pepeolithic)
    {
        return new Pepeolithic(
            COIN,
            ADMIN,
            ADAM,
            root,
            START,
            caveLen,
            roundLen,
            first,
            floor,
            bytes32("pepeolithic-base-naij"),
            bytes32("pepeolithic-moss-naij"),
            bytes32("pepeolithic-water-naij"),
            bytes32("pepeolithic-ice-naij"),
            bytes32("pepeolithic-lava-naij"),
            bytes32("pepeolithic-crystal-naij"),
            bytes32("pepeolithic-roots-naij")
        );
    }

    function _fund(address who, Pepeolithic target) internal {
        coin.mint(who, 100 ether);
        vm.prank(who);
        coin.approve(address(target), 100 ether);
    }

    function _buy(uint256 c, uint256 r) internal returns (uint256) {
        vm.prank(ALICE);
        return pepeolithic.buy(c, r);
    }

    function _singleSeat() internal returns (Pepeolithic target) {
        target = _deploy(keccak256(abi.encodePacked(ALICE)), 3600, 150, FIRST, FLOOR);
        _fund(ALICE, target);
    }

    function testConstructorWithoutCoinCodeAndFixedDeployment() public {
        vm.etch(COIN, hex"");
        vm.chainId(1);
        vm.prank(address(0xFAC));
        Pepeolithic target = _deploy(ROOT, 86400, 3600, 1e24, 1e22);
        assertEq(target.name(), "Pepeolithic");
        assertEq(target.symbol(), "PEPEO");
        assertEq(target.coin(), COIN);
        assertEq(target.coinDecimals(), 18);
        assertEq(target.dead(), DEAD);
        assertEq(target.admin(), ADMIN);
        assertEq(target.adam(), ADAM);
        assertEq(target.seatRoot(), ROOT);
        assertEq(target.startTime(), START);
        assertEq(target.caveLength(), 86400);
        assertEq(target.roundLength(), 3600);
        assertEq(target.firstPrice(), 1e24);
        assertEq(target.floorPrice(), 1e22);
        assertEq(target.labels(1), bytes32("pepeolithic-base-naij"));
        assertEq(target.labels(7), bytes32("pepeolithic-roots-naij"));
        assertEq(target.ownerOf(0), ADAM);
        assertEq(target.ownerOf(736), ADMIN);
        assertEq(target.balanceOf(ADMIN), 1);
        assertEq(target.totalSupply(), 2);
        assertLt(address(target).code.length, 9000);
        assertEq(address(target).balance, 0);
    }

    function testRuntimePassesProtectedOpcodeScanAndSizeLimit() public view {
        bytes memory code = address(pepeolithic).code;
        assertGt(code.length, 0);
        assertLt(code.length, 9000);
        for (uint256 i; i < code.length; ++i) {
            uint8 opcode = uint8(code[i]);
            if (opcode >= 0x60 && opcode <= 0x7f) {
                i += opcode - 0x5f;
                continue;
            }
            assertTrue(opcode != 0xf4 && opcode != 0xf2 && opcode != 0xff);
        }
    }

    function testInvalidConfiguration() public {
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, 3149, 150, FIRST, FLOOR);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, 3600, 0, FIRST, FLOOR);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, FIRST, 0);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, FLOOR, FLOOR);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(bytes32(0), 3600, 150, FIRST, FLOOR);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, type(uint256).max, 150, FIRST, FLOOR);
        vm.expectRevert(Pepeolithic.InvalidConfig.selector);
        _deploy(ROOT, 3600, 150, type(uint256).max, type(uint256).max);
    }

    function testEveryPieceAndSaleCount() public view {
        uint256[7] memory expected = [uint256(21), 21, 42, 63, 84, 84, 85];
        uint256 allSales;
        uint256 allFree;
        for (uint256 c = 1; c <= 7; ++c) {
            uint256 sales;
            for (uint256 r = 1; r <= 21; ++r) {
                for (uint256 s = 1; s <= 5; ++s) {
                    uint256 id = (c - 1) * 105 + (r - 1) * 5 + s;
                    (uint256 pc, uint256 pr, uint256 ps) = pepeolithic.piece(id);
                    assertEq(pc, c);
                    assertEq(pr, r);
                    assertEq(ps, s);
                    if (pepeolithic.isSalePiece(id)) ++sales;
                    else ++allFree;
                }
            }
            assertEq(sales, expected[c - 1]);
            allSales += sales;
        }
        assertEq(allSales, 400);
        assertEq(allFree, 335);
        assertFalse(pepeolithic.isSalePiece(0));
        assertFalse(pepeolithic.isSalePiece(736));
        assertEq(pepeolithic.saleCount(7, 21), 5);
    }

    function testWindowsAndInvalidIndices() public {
        for (uint256 c = 1; c <= 7; ++c) {
            assertEq(pepeolithic.caveOpen(c), START + (c - 1) * 3600);
            assertEq(pepeolithic.caveClose(c), START + c * 3600);
            for (uint256 r = 1; r <= 21; ++r) {
                assertEq(pepeolithic.roundOpen(c, r), START + (c - 1) * 3600 + (r - 1) * 150);
            }
        }
        vm.expectRevert(Pepeolithic.InvalidCave.selector);
        pepeolithic.caveOpen(0);
        vm.expectRevert(Pepeolithic.InvalidCave.selector);
        pepeolithic.caveClose(8);
        vm.expectRevert(Pepeolithic.InvalidRound.selector);
        pepeolithic.roundOpen(1, 0);
        vm.expectRevert(Pepeolithic.InvalidRound.selector);
        pepeolithic.openingPrice(1, 22);
        vm.expectRevert(Pepeolithic.InvalidPiece.selector);
        pepeolithic.piece(737);
    }

    function testBuyAndQuoteTimeBoundaries() public {
        vm.warp(START - 1);
        vm.expectRevert(Pepeolithic.NotOpen.selector);
        _buy(1, 1);
        vm.expectRevert(Pepeolithic.NotOpen.selector);
        pepeolithic.priceNow(1, 1);
        vm.warp(START);
        assertEq(pepeolithic.priceNow(1, 1), FIRST);
        vm.expectRevert(Pepeolithic.NotOpen.selector);
        _buy(1, 2);
        assertEq(_buy(1, 1), 5);
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        _buy(1, 1);
        vm.warp(START + 3600 - 1);
        assertEq(pepeolithic.priceNow(1, 2), FLOOR);
        vm.warp(START + 3600);
        vm.expectRevert(Pepeolithic.NotOpen.selector);
        _buy(1, 2);
        vm.expectRevert(Pepeolithic.NotOpen.selector);
        pepeolithic.priceNow(1, 2);
        assertEq(_buy(2, 1), 110);
    }

    function testHalvingSegmentEndsAndInterior() public {
        Pepeolithic target = _deploy(ROOT, 3600, 160, FIRST, FLOOR);
        uint256[9] memory secondsAfter = [uint256(0), 20, 40, 60, 80, 120, 140, 160, 3500];
        uint256[9] memory expected = [uint256(4e15), 3e15, 2e15, 15e14, 1e15, 5e14, FLOOR, FLOOR, FLOOR];
        for (uint256 i; i < secondsAfter.length; ++i) {
            vm.warp(START + secondsAfter[i]);
            assertEq(target.priceNow(1, 1), expected[i]);
        }
    }

    function testFractionalSegmentsWithShortFixture() public {
        vm.warp(START + 30);
        assertEq(pepeolithic.priceNow(1, 1), 24e14);
        vm.warp(START + 75);
        assertEq(pepeolithic.priceNow(1, 1), 1e15);
        vm.warp(START + 112);
        assertEq(pepeolithic.priceNow(1, 1), 506666666666667);
        vm.warp(START + 149);
        assertEq(pepeolithic.priceNow(1, 1), FLOOR);
    }

    function testFuzzHalvingPriceIsBoundedAndMonotone(uint256 elapsed) public {
        elapsed = bound(elapsed, 0, 3598);
        vm.warp(START + elapsed);
        uint256 beforePrice = pepeolithic.priceNow(1, 1);
        vm.warp(START + elapsed + 1);
        uint256 afterPrice = pepeolithic.priceNow(1, 1);
        assertGe(beforePrice, afterPrice);
        assertGe(afterPrice, FLOOR);
        assertLe(beforePrice, FIRST);
        if (elapsed >= 150) assertEq(afterPrice, FLOOR);
    }

    function testLadderDoublesLastLineSaleAndHalvesQuietRounds() public {
        vm.warp(START + 30);
        uint256 paid = pepeolithic.priceNow(1, 1);
        _buy(1, 1);
        assertEq(pepeolithic.lastLineSale(1, 1), paid);
        assertEq(pepeolithic.openingPrice(1, 2), paid * 2);
        assertEq(pepeolithic.openingPrice(1, 3), paid);
        assertEq(pepeolithic.openingPrice(1, 4), paid / 2);
        assertEq(pepeolithic.openingPrice(1, 5), 2 * FLOOR);
        assertEq(pepeolithic.openingPrice(7, 21), 2 * FLOOR);
        vm.warp(START + 150);
        _buy(1, 2);
        assertEq(pepeolithic.openingPrice(1, 3), paid * 4);
    }

    function testLadderFloorBuysIgnoredAndStoredOpeningStable() public {
        vm.warp(pepeolithic.caveOpen(3));
        assertEq(pepeolithic.openingPrice(3, 1), 2 * FLOOR);
        _buy(3, 1);
        assertEq(pepeolithic.openingPrice(3, 2), 4 * FLOOR);
        vm.warp(pepeolithic.roundOpen(3, 2));
        _buy(3, 2);
        uint256 stored = pepeolithic.openingPrice(3, 2);
        assertEq(pepeolithic.priceNow(3, 1), FLOOR);
        _buy(3, 1);
        assertEq(pepeolithic.lastLineSale(3, 1), 2 * FLOOR);
        assertEq(pepeolithic.openingPrice(3, 2), stored);
        vm.warp(pepeolithic.roundOpen(3, 3));
        _buy(3, 2);
        assertEq(pepeolithic.lastLineSale(3, 2), 4 * FLOOR);
        assertEq(pepeolithic.openingPrice(3, 3), 8 * FLOOR);
    }

    function testLastLineSaleReplacesEarlierSaleAndHalfOpeningMinimum() public {
        // Grow the ladder so that the floor and half-opening bounds differ.
        vm.warp(pepeolithic.caveOpen(3));
        for (uint256 r = 1; r <= 4; ++r) {
            vm.warp(pepeolithic.roundOpen(3, r));
            _buy(3, r);
        }
        uint256 opening = pepeolithic.openingPrice(3, 4);
        vm.warp(pepeolithic.roundOpen(3, 4) + 140);
        uint256 latest = pepeolithic.priceNow(3, 4);
        assertGt(latest, FLOOR);
        _buy(3, 4);
        assertEq(pepeolithic.lastLineSale(3, 4), latest);
        assertLt(2 * latest, opening / 2);
        assertEq(pepeolithic.openingPrice(3, 5), opening / 2);
    }

    function testLadderAcrossCavesAndUnboughtRoundNotSnapshot() public {
        vm.warp(pepeolithic.roundOpen(1, 21));
        assertEq(pepeolithic.openingPrice(2, 1), 2 * FLOOR);
        _buy(1, 21);
        assertEq(pepeolithic.openingPrice(2, 1), 4 * FLOOR);
        assertEq(pepeolithic.openingPrice(2, 2), 2 * FLOOR);
        vm.warp(pepeolithic.caveOpen(2));
        _buy(2, 1);
        assertEq(pepeolithic.openingPrice(2, 2), 8 * FLOOR);
    }

    function testQuietFirstBuyAtFloorDoesNotRaiseNextOpening() public {
        vm.warp(START + 150);
        _buy(1, 1);
        assertEq(pepeolithic.lastLineSale(1, 1), 0);
        assertEq(pepeolithic.openingPrice(1, 2), FIRST / 2);
        assertEq(pepeolithic.openingPrice(1, 3), FIRST / 4);
    }

    function testEverySaleSlotBoughtInOrderAndAllSalesExhausted() public {
        uint256 count;
        for (uint256 c = 1; c <= 7; ++c) {
            // Every round is at the floor, so buying out the whole week is affordable.
            vm.warp(pepeolithic.caveClose(c) - 1);
            for (uint256 r = 1; r <= 21; ++r) {
                uint256 amount = pepeolithic.saleCount(c, r);
                for (uint256 j; j < amount; ++j) {
                    uint256 id = _buy(c, r);
                    assertEq(id, (c - 1) * 105 + r * 5 - j);
                    assertEq(pepeolithic.ownerOf(id), ALICE);
                    ++count;
                }
                assertEq(pepeolithic.roundSold(c, r), amount);
                vm.expectRevert(Pepeolithic.SoldOut.selector);
                _buy(c, r);
            }
        }
        assertEq(count, 400);
        assertEq(pepeolithic.totalSupply(), 402);
        assertEq(coin.balanceOf(DEAD), 400 * FLOOR);
        assertEq(coin.balanceOf(address(pepeolithic)), 0);
    }

    function testBuyEventAndDirectBurnPayment() public {
        vm.warp(START);
        uint256 balance = coin.balanceOf(ALICE);
        vm.expectEmit(true, true, false, true, address(pepeolithic));
        emit Bought(5, ALICE, FIRST);
        _buy(1, 1);
        assertEq(coin.lastFrom(), ALICE);
        assertEq(coin.lastTo(), DEAD);
        assertEq(coin.lastAmount(), FIRST);
        assertEq(coin.balanceOf(ALICE), balance - FIRST);
        assertEq(coin.balanceOf(DEAD), FIRST);
        assertEq(coin.balanceOf(address(pepeolithic)), 0);
    }

    function testFalseAndRevertingCoinRollbackEntireBuy() public {
        vm.warp(pepeolithic.caveOpen(3));
        coin.fail(true, false);
        vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        _buy(3, 1);
        assertEq(pepeolithic.totalSupply(), 2);
        assertEq(pepeolithic.roundSold(3, 1), 0);
        assertEq(pepeolithic.lastLineSale(3, 1), 0);
        assertEq(pepeolithic.openingPrice(3, 2), 2 * FLOOR);
        assertEq(coin.balanceOf(DEAD), 0);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 215));
        pepeolithic.ownerOf(215);
        coin.fail(false, true);
        vm.expectRevert(MockCoin.CoinReverted.selector);
        _buy(3, 1);
        coin.fail(false, false);
        assertEq(_buy(3, 1), 215);
    }

    function testMissingBoolOrMissingAllowanceRejectsBuy() public {
        vm.warp(START);
        vm.prank(ALICE);
        coin.approve(address(pepeolithic), FIRST - 1);
        vm.expectRevert(MockCoin.InsufficientAllowance.selector);
        _buy(1, 1);
        NoReturnCoin badCoin = new NoReturnCoin();
        vm.etch(COIN, address(badCoin).code);
        vm.expectRevert();
        _buy(1, 1);
        assertEq(pepeolithic.totalSupply(), 2);
    }

    function testCoinReentrySeesCompletedSaleAndCannotDuplicatePiece() public {
        vm.warp(pepeolithic.caveOpen(3));
        coin.arm(pepeolithic, 3, 1, false);
        uint256 id = _buy(3, 1);
        assertEq(id, 215);
        assertEq(coin.nestedId(), 214);
        assertEq(coin.observedSold(), 1);
        assertEq(coin.observedSupply(), 3);
        assertEq(pepeolithic.ownerOf(id), ALICE);
        assertEq(pepeolithic.ownerOf(214), COIN);
        assertEq(pepeolithic.roundSold(3, 1), 2);
        assertEq(pepeolithic.totalSupply(), 4);
        assertEq(coin.balanceOf(DEAD), 4 * FLOOR);
    }

    function testMintToContractWithoutReceiver() public {
        NoReceiver recipient = new NoReceiver();
        coin.mint(address(recipient), FIRST);
        vm.warp(START);
        assertEq(recipient.buy(pepeolithic, 1, 1), 5);
        assertEq(pepeolithic.ownerOf(5), address(recipient));
    }

    function testClaimProofStartAndDuplicate() public {
        Pepeolithic target = _singleSeat();
        bytes32[] memory proof = new bytes32[](0);
        vm.warp(START - 1);
        vm.expectRevert(Pepeolithic.TooEarly.selector);
        vm.prank(ALICE);
        target.claimSeat(proof);
        vm.warp(START);
        vm.expectRevert(Pepeolithic.InvalidProof.selector);
        vm.prank(BOB);
        target.claimSeat(proof);
        vm.expectEmit(true, true, false, true, address(target));
        emit Claimed(1, ALICE);
        vm.prank(ALICE);
        assertEq(target.claimSeat(proof), 1);
        assertEq(target.ownerOf(1), ALICE);
        assertTrue(target.claimed(ALICE));
        assertEq(coin.balanceOf(DEAD), 0);
        vm.expectRevert(Pepeolithic.AlreadyClaimed.selector);
        vm.prank(ALICE);
        target.claimSeat(proof);
    }

    function _merkleTree() internal pure returns (bytes32[] memory tree) {
        tree = new bytes32[](1024);
        for (uint256 i; i < 512; ++i) {
            tree[512 + i] = keccak256(abi.encodePacked(address(uint160(10000 + i))));
        }
        for (uint256 i = 511; i > 0; --i) {
            bytes32 a = tree[2 * i];
            bytes32 b = tree[2 * i + 1];
            tree[i] = a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
        }
    }

    function _proof(bytes32[] memory tree, uint256 leaf) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](9);
        uint256 index = 512 + leaf;
        for (uint256 depth; depth < 9; ++depth) {
            proof[depth] = tree[index ^ 1];
            index >>= 1;
        }
    }

    function testAll335SeatsInIdOrderAndMerkleExhaustion() public {
        bytes32[] memory tree = _merkleTree();
        Pepeolithic target = _deploy(tree[1], 3600, 150, FIRST, FLOOR);
        vm.warp(START);
        uint256 count;
        uint256 firstSix;
        for (uint256 id = 1; id < 736; ++id) {
            if (target.isSalePiece(id)) continue;
            address who = address(uint160(10000 + count));
            bytes32[] memory proof = _proof(tree, count);
            vm.prank(who);
            assertEq(target.claimSeat(proof), id);
            assertEq(target.ownerOf(id), who);
            if (id <= 630) ++firstSix;
            ++count;
        }
        assertEq(firstSix, 315);
        assertEq(count, 335);
        bytes32[] memory extraProof = _proof(tree, 335);
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        vm.prank(address(10335));
        target.claimSeat(extraProof);
        assertFalse(target.claimed(address(10335)));
        assertEq(target.totalSupply(), 337);
        vm.warp(START + 8 * 3600);
        target.releaseUnclaimed();
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        target.buyLeftover();
    }

    function testReleaseTimingPermissionlessAndClaimStopsOnlyOnRelease() public {
        Pepeolithic target = _singleSeat();
        vm.expectRevert(Pepeolithic.NotReleased.selector);
        target.buyLeftover();
        vm.warp(START + 8 * 3600 - 1);
        vm.expectRevert(Pepeolithic.TooEarly.selector);
        target.releaseUnclaimed();
        vm.warp(START + 8 * 3600);
        vm.prank(ALICE);
        assertEq(target.claimSeat(new bytes32[](0)), 1);
        vm.expectEmit(false, false, false, true, address(target));
        emit UnclaimedReleased();
        vm.prank(BOB);
        target.releaseUnclaimed();
        vm.expectRevert(Pepeolithic.SeatsReleased.selector);
        vm.prank(ALICE);
        target.claimSeat(new bytes32[](0));
        vm.expectRevert(Pepeolithic.AlreadyReleased.selector);
        target.releaseUnclaimed();
        vm.warp(START + 1000 days);
        vm.expectEmit(true, true, false, true, address(target));
        emit Bought(2, ALICE, FLOOR);
        vm.prank(ALICE);
        assertEq(target.buyLeftover(), 2);
        assertEq(coin.balanceOf(DEAD), FLOOR);
    }

    function testLeftoverFailureRollsBackCursorAndReentryUsesNextPiece() public {
        vm.warp(START + 8 * 3600);
        pepeolithic.releaseUnclaimed();
        coin.fail(true, false);
        vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        vm.prank(ALICE);
        pepeolithic.buyLeftover();
        assertEq(pepeolithic.nextFree(), 1);
        assertEq(pepeolithic.totalSupply(), 2);
        coin.fail(false, false);
        coin.arm(pepeolithic, 0, 0, true);
        vm.prank(ALICE);
        assertEq(pepeolithic.buyLeftover(), 1);
        assertEq(coin.nestedId(), 2);
        assertEq(pepeolithic.ownerOf(1), ALICE);
        assertEq(pepeolithic.ownerOf(2), COIN);
        assertEq(coin.balanceOf(DEAD), 2 * FLOOR);
    }

    function testSweepBoundariesPartialBatchesAndEvents() public {
        vm.warp(pepeolithic.caveClose(3) - 1);
        assertEq(_buy(3, 1), 215);
        vm.expectRevert(Pepeolithic.NotClosed.selector);
        pepeolithic.sweep(3, 42);
        vm.warp(pepeolithic.caveClose(3));
        vm.expectRevert(Pepeolithic.InvalidQuantity.selector);
        pepeolithic.sweep(3, 0);
        vm.expectEmit(true, false, false, true, address(pepeolithic));
        emit Swept(214);
        vm.prank(BOB);
        assertEq(pepeolithic.sweep(3, 1), 1);
        assertEq(pepeolithic.ownerOf(214), ADMIN);
        assertEq(pepeolithic.ownerOf(215), ALICE);
        // Transferring a sold piece cannot make it sweepable.
        vm.prank(ALICE);
        pepeolithic.transferFrom(ALICE, BOB, 215);
        assertEq(pepeolithic.sweep(3, 2), 2);
        assertEq(pepeolithic.ownerOf(219), ADMIN);
        assertEq(pepeolithic.ownerOf(220), ADMIN);
        assertEq(pepeolithic.sweep(3, type(uint256).max), 38);
        assertEq(pepeolithic.ownerOf(215), BOB);
        assertEq(pepeolithic.roundSold(3, 1), 1);
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        pepeolithic.sweep(3, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 211));
        pepeolithic.ownerOf(211);
    }

    function testAll737EventuallyMintedExactlyOnce() public {
        Pepeolithic target = _singleSeat();
        vm.warp(START);
        vm.prank(ALICE);
        target.claimSeat(new bytes32[](0));
        vm.prank(ALICE);
        target.buy(1, 1);
        vm.warp(START + 8 * 3600);
        uint256 swept;
        for (uint256 c = 1; c <= 7; ++c) {
            swept += target.sweep(c, 1000);
        }
        assertEq(swept, 399);
        target.releaseUnclaimed();
        uint256 leftovers;
        for (uint256 id = 2; id < 736; ++id) {
            if (target.isSalePiece(id)) continue;
            vm.prank(ALICE);
            assertEq(target.buyLeftover(), id);
            ++leftovers;
        }
        assertEq(leftovers, 334);
        assertEq(target.totalSupply(), 737);
        for (uint256 id; id < 737; ++id) {
            assertTrue(target.ownerOf(id) != address(0));
        }
        for (uint256 c = 1; c <= 7; ++c) {
            vm.expectRevert(Pepeolithic.SoldOut.selector);
            target.sweep(c, 1000);
        }
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        target.buyLeftover();
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 737));
        target.ownerOf(737);
        assertEq(coin.balanceOf(address(target)), 0);
        assertEq(coin.balanceOf(DEAD), FIRST + 334 * FLOOR);
    }

    function testURIsIncludingEndpointsRoundsSlotsAndFrozenCaves() public {
        assertEq(pepeolithic.tokenURI(0), "https://pepeolithic-base-naij.sites.imd.fun/zero.json");
        assertEq(pepeolithic.tokenURI(736), "https://pepeolithic-roots-naij.sites.imd.fun/one.json");
        assertEq(pepeolithic.contractURI(), "https://pepeolithic-base-naij.sites.imd.fun/collection.json");
        vm.warp(START + 8 * 3600);
        pepeolithic.releaseUnclaimed();
        vm.prank(ALICE);
        pepeolithic.buyLeftover();
        for (uint256 c = 1; c <= 7; ++c) {
            pepeolithic.sweep(c, 105);
        }
        assertEq(pepeolithic.tokenURI(1), "https://pepeolithic-base-naij.sites.imd.fun/line-1/01.json");
        assertEq(pepeolithic.tokenURI(5), "https://pepeolithic-base-naij.sites.imd.fun/gathering/01.json");
        assertEq(pepeolithic.tokenURI(50), "https://pepeolithic-base-naij.sites.imd.fun/gathering/10.json");
        assertEq(pepeolithic.tokenURI(214), "https://pepeolithic-water-naij.sites.imd.fun/line-4/01.json");
        assertEq(pepeolithic.tokenURI(318), "https://pepeolithic-ice-naij.sites.imd.fun/line-3/01.json");
        assertEq(pepeolithic.tokenURI(422), "https://pepeolithic-lava-naij.sites.imd.fun/line-2/01.json");
        assertEq(pepeolithic.tokenURI(731), "https://pepeolithic-roots-naij.sites.imd.fun/line-1/21.json");
        vm.prank(ADMIN);
        pepeolithic.freeze(7, "ipfs://seven/");
        assertEq(pepeolithic.tokenURI(736), "ipfs://seven/one.json");
        assertEq(pepeolithic.tokenURI(735), "ipfs://seven/gathering/21.json");
        assertEq(pepeolithic.tokenURI(0), "https://pepeolithic-base-naij.sites.imd.fun/zero.json");
        vm.prank(ADMIN);
        pepeolithic.freeze(1, "ipfs://one/");
        assertEq(pepeolithic.tokenURI(0), "ipfs://one/zero.json");
        assertEq(pepeolithic.tokenURI(1), "ipfs://one/line-1/01.json");
        assertEq(pepeolithic.contractURI(), "ipfs://one/collection.json");
    }

    function testFreezeOnlyAdminOnceAndValidBase() public {
        vm.expectRevert(Pepeolithic.Unauthorized.selector);
        vm.prank(ALICE);
        pepeolithic.freeze(1, "ipfs://cid/");
        vm.startPrank(ADMIN);
        vm.expectRevert(Pepeolithic.InvalidCave.selector);
        pepeolithic.freeze(8, "ipfs://cid/");
        vm.expectRevert(Pepeolithic.InvalidBase.selector);
        pepeolithic.freeze(1, "");
        vm.expectRevert(Pepeolithic.InvalidBase.selector);
        pepeolithic.freeze(1, "ipfs://cid");
        vm.expectEmit(true, false, false, true, address(pepeolithic));
        emit Frozen(1, "ipfs://cid/");
        pepeolithic.freeze(1, "ipfs://cid/");
        assertTrue(pepeolithic.frozen(1));
        vm.expectRevert(Pepeolithic.AlreadyFrozen.selector);
        pepeolithic.freeze(1, "ipfs://different/");
        vm.stopPrank();
    }

    function testERC721TransfersApprovalsAndNoReceiverCallbacks() public {
        vm.warp(START);
        _buy(1, 1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InsufficientApproval.selector, BOB, 5));
        vm.prank(BOB);
        pepeolithic.transferFrom(ALICE, BOB, 5);
        vm.prank(ALICE);
        pepeolithic.approve(BOB, 5);
        assertEq(pepeolithic.getApproved(5), BOB);
        vm.prank(BOB);
        pepeolithic.safeTransferFrom(ALICE, BOB, 5);
        assertEq(pepeolithic.getApproved(5), address(0));
        assertEq(pepeolithic.balanceOf(ALICE), 0);
        assertEq(pepeolithic.balanceOf(BOB), 1);
        vm.prank(BOB);
        pepeolithic.setApprovalForAll(ALICE, true);
        assertTrue(pepeolithic.isApprovedForAll(BOB, ALICE));
        NoReceiver recipient = new NoReceiver();
        vm.expectRevert(Pepeolithic.ContractRecipient.selector);
        vm.prank(ALICE);
        pepeolithic.safeTransferFrom(BOB, address(recipient), 5, hex"1234");
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721InvalidReceiver.selector, address(0)));
        vm.prank(ALICE);
        pepeolithic.transferFrom(BOB, address(0), 5);
        vm.prank(ALICE);
        pepeolithic.transferFrom(BOB, address(recipient), 5);
        assertEq(pepeolithic.ownerOf(5), address(recipient));
        assertEq(pepeolithic.totalSupply(), 3);
    }

    function testInterfacesRoyaltyAndNonexistentURI() public {
        assertTrue(pepeolithic.supportsInterface(0x01ffc9a7));
        assertTrue(pepeolithic.supportsInterface(0x80ac58cd));
        assertTrue(pepeolithic.supportsInterface(0x5b5e139f));
        assertTrue(pepeolithic.supportsInterface(0x2a55205a));
        assertFalse(pepeolithic.supportsInterface(0xffffffff));
        assertFalse(pepeolithic.supportsInterface(0x780e9d63));
        (address receiver, uint256 fee) = pepeolithic.royaltyInfo(736, 123456);
        assertEq(receiver, ADMIN);
        assertEq(fee, 1234);
        (, fee) = pepeolithic.royaltyInfo(0, type(uint256).max);
        assertEq(fee, type(uint256).max / 100);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 1));
        pepeolithic.tokenURI(1);
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, 737));
        pepeolithic.tokenURI(737);
    }
}
