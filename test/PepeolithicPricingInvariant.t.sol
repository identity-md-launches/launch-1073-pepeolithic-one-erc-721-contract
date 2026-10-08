// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepeolithic} from "src/Pepeolithic.sol";
import {MockCoin} from "test/Pepeolithic.t.sol";
import {PepeolithicSetup} from "test/support/PepeolithicSetup.sol";

/// @dev Interpolate a weighted average of adjacent knots, rounding the price up.
/// This uses neither the implementation's subtraction/mulDiv nor any contract quote.
/// Inputs are bounded by the mainnet ladder or uint96 fuzz fixtures: products fit uint256.
library PepeolithicPriceOracle {
    function price(uint256 opening, uint256 floor, uint256 duration, uint256 elapsed) internal pure returns (uint256) {
        if (elapsed >= duration) return floor;
        uint256 divisor = 1;
        uint256 knots;
        while (opening / divisor > floor) {
            divisor *= 2;
            ++knots;
        }
        uint256 segment = elapsed * knots / duration;
        uint256 progress = elapsed * knots - segment * duration;
        uint256 high = opening / (2 ** segment);
        uint256 low = opening / (2 ** (segment + 1));
        uint256 numerator = high * (duration - progress) + low * progress;
        uint256 rounded = (numerator + duration - 1) / duration;
        return rounded < floor ? floor : rounded;
    }
}

/// @dev A forward recurrence is deliberately separate from Pepeolithic's backward
/// search and quiet-round bit shifts. Only successful calls update model state.
contract PepeolithicPricingHandler is PepeolithicSetup {
    uint256[147] private saved;
    uint256[147] private lastLine;
    uint256[147] private sold;
    uint256[8] private spending;
    uint256[8] private purchases;
    uint256 public successfulBuys;
    uint256 public lineBuys;
    uint256 public floorBuys;
    uint256 public failedBuys;
    uint256 public paid;
    uint256 private probeIndex;

    event Bought(uint256 indexed id, address indexed buyer, uint256 price);

    constructor(Pepeolithic target, MockCoin mock) {
        pepeolithic = target;
        coin = mock;
    }

    function advance(uint256 secondsSeed, uint8 mode) public {
        uint256 now_ = vm.getBlockTimestamp();
        uint256 next;
        if (mode % 3 == 0) next = now_ + bound(secondsSeed, 0, 7200);
        else if (mode % 3 == 1) next = START + ((now_ - START) / 3600 + 1) * 3600;
        else next = START + ((now_ - START) / 86400 + 1) * 86400;
        uint256 lastSecond = START + 7 * 86400 - 1;
        vm.warp(next > lastSecond ? lastSecond : next);
    }

    function buyCurrent(uint256 actorSeed, uint8 failureSeed) public {
        (uint256 c, uint256 latest) = _current();
        _purchase(c, latest, actorSeed % 8, failureSeed % 8);
    }

    function buyOlder(uint256 actorSeed, uint256 roundSeed, uint8 failureSeed) public {
        (uint256 c, uint256 latest) = _current();
        _purchase(c, bound(roundSeed, 1, latest), actorSeed % 8, failureSeed % 8);
    }

    function probe(uint256 roundSeed) public {
        probeIndex = bound(roundSeed, 0, 146);
        checkRound(probeIndex);
    }

    function _purchase(uint256 c, uint256 r, uint256 actorIndex, uint256 failure) private {
        uint256 index = (c - 1) * 21 + r - 1;
        uint256 opening = modelOpening(index);
        uint256 elapsed = vm.getBlockTimestamp() - (START + (c - 1) * 86400 + (r - 1) * 3600);
        uint256 expectedPrice = PepeolithicPriceOracle.price(opening, FLOOR, 3600, elapsed);
        assertEq(pepeolithic.priceNow(c, r), expectedPrice, "independent line quote");
        address buyer = _actor(actorIndex);
        // 0..4 succeed; 5 returns false, 6 reverts, 7 has allowance short by one wei.
        uint256 allowance = failure == 7 ? expectedPrice - 1 : expectedPrice;
        vm.prank(buyer);
        coin.approve(address(pepeolithic), allowance);
        coin.fail(failure == 5, failure == 6);
        bytes4 error;
        if (sold[index] == _quota(c, r)) error = Pepeolithic.SoldOut.selector;
        else if (failure == 5) error = Pepeolithic.PaymentFailed.selector;
        else if (failure == 6) error = MockCoin.CoinReverted.selector;
        else if (failure == 7) error = MockCoin.InsufficientAllowance.selector;

        if (error != bytes4(0)) {
            vm.expectRevert(error);
            vm.prank(buyer);
            pepeolithic.buy(c, r);
            ++failedBuys;
            assertEq(coin.allowance(buyer, address(pepeolithic)), allowance, "failed buy preserves approval");
        } else {
            uint256 expectedId = (c - 1) * 105 + r * 5 - sold[index];
            vm.expectEmit(true, true, false, true, address(pepeolithic));
            emit Bought(expectedId, buyer, expectedPrice);
            vm.prank(buyer);
            assertEq(pepeolithic.buy(c, r), expectedId);
            assertEq(pepeolithic.ownerOf(expectedId), buyer);
            assertEq(coin.allowance(buyer, address(pepeolithic)), 0, "charge consumes exact approval");
            saved[index] = opening;
            if (expectedPrice > FLOOR) {
                lastLine[index] = expectedPrice;
                ++lineBuys;
            } else {
                ++floorBuys;
            }
            ++sold[index];
            ++successfulBuys;
            ++purchases[actorIndex];
            spending[actorIndex] += expectedPrice;
            paid += expectedPrice;
        }
        coin.fail(false, false);
        checkRound(index);
        if (index < 146) checkRound(index + 1);
    }

    function modelOpening(uint256 index) public view returns (uint256 opening) {
        opening = FIRST;
        for (uint256 i; i <= index; ++i) {
            if (saved[i] != 0) opening = saved[i];
            if (i == index) return opening;
            uint256 next = opening / 2;
            if (2 * lastLine[i] > next) next = 2 * lastLine[i];
            opening = next < 2 * FLOOR ? 2 * FLOOR : next;
        }
    }

    function checkRound(uint256 index) public view {
        uint256 c = index / 21 + 1;
        uint256 r = index % 21 + 1;
        assertEq(pepeolithic.openingPrice(c, r), modelOpening(index), "forward ladder oracle");
        assertEq(pepeolithic.lastLineSale(c, r), lastLine[index], "only successful above-floor buys move ladder");
        assertEq(pepeolithic.roundSold(c, r), sold[index], "failed buys cannot consume slots");
    }

    function checkState() public view {
        (uint256 c, uint256 r) = _current();
        uint256 current = (c - 1) * 21 + r - 1;
        checkRound(current);
        if (current < 146) checkRound(current + 1);
        checkRound(probeIndex);
        checkRound(146); // Include long runs of quiet rounds after every operation.
        assertEq(pepeolithic.totalSupply(), 2 + successfulBuys);
        assertEq(successfulBuys, lineBuys + floorBuys);
        assertEq(coin.balanceOf(DEAD), paid, "burn total comes from independent prices");
        assertEq(coin.balanceOf(address(pepeolithic)), 0);
        assertEq(coin.balanceOf(ADMIN), 0);
        for (uint256 i; i < 8; ++i) {
            assertEq(coin.balanceOf(_actor(i)), FUNDS - spending[i]);
            assertEq(pepeolithic.balanceOf(_actor(i)), purchases[i]);
        }
    }

    function _current() private view returns (uint256 c, uint256 r) {
        uint256 elapsed = vm.getBlockTimestamp() - START;
        c = elapsed / 86400 + 1;
        r = elapsed % 86400 / 3600 + 1;
        if (r > 21) r = 21;
    }
}

contract PepeolithicPricingInvariantTest is PepeolithicSetup {
    PepeolithicPricingHandler private handler;

    function setUp() public {
        vm.chainId(1);
        _installCoin();
        pepeolithic = _deploy(_config());
        for (uint256 i; i < 8; ++i) {
            _fund(_actor(i), pepeolithic, FUNDS);
        }
        handler = new PepeolithicPricingHandler(pepeolithic, coin);
        vm.warp(START);
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = handler.advance.selector;
        selectors[1] = handler.buyCurrent.selector;
        selectors[2] = handler.buyOlder.selector;
        selectors[3] = handler.probe.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 96
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_ladderAndBurnsMatchIndependentModel() public view {
        handler.checkState();
    }

    function afterInvariant() public view {
        for (uint256 index; index < 147; ++index) {
            handler.checkRound(index);
        }
    }

    function testPricingHandlerExercisesSuccessfulAndRejectedLineAndFloorBuys() public {
        handler.buyCurrent(0, 5);
        handler.buyCurrent(0, 6);
        handler.buyCurrent(0, 7);
        handler.buyCurrent(0, 0);
        handler.buyCurrent(1, 0); // Sold out.
        handler.advance(0, 1); // Next round's opening.
        handler.buyCurrent(1, 0);
        handler.advance(0, 2); // Next cave, including a quiet round-21 predecessor.
        handler.buyCurrent(2, 0);
        handler.advance(0, 2); // Cave 3 has multiple sale slots in each round.
        handler.buyCurrent(3, 0);
        handler.advance(1800, 0);
        handler.buyCurrent(4, 0); // Replaces the last line sale at a lower price.
        handler.advance(0, 1);
        handler.buyCurrent(5, 0);
        handler.advance(0, 1);
        handler.buyOlder(6, 2, 0); // Floor purchase cannot erase the last line sale.
        handler.probe(146);
        handler.checkState();
        assertEq(handler.lineBuys(), 6);
        assertEq(handler.floorBuys(), 1);
        assertEq(handler.failedBuys(), 4);
        afterInvariant();
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzzCurveMatchesWeightedKnotOracle(
        uint96 firstSeed,
        uint96 floorSeed,
        uint32 timeSeed,
        uint32 lengthSeed
    ) public {
        Config memory p = _config();
        p.floor = bound(floorSeed, 1, type(uint96).max / 2);
        p.first = bound(firstSeed, 2 * p.floor, type(uint96).max);
        p.roundLength = bound(lengthSeed, 1, 86400);
        p.caveLength = 21 * p.roundLength;
        Pepeolithic target = _deploy(p);
        uint256 elapsed = bound(timeSeed, 0, p.roundLength);
        vm.warp(START + elapsed);
        assertEq(
            target.priceNow(1, 1),
            PepeolithicPriceOracle.price(p.first, p.floor, p.roundLength, elapsed),
            "rational knot interpolation including integer rounding and floor clamp"
        );
    }

    function testMainnetFloorStartsBeforeRoundEndsAndDoesNotRecordALineSale() public {
        vm.warp(START + 1800);
        assertEq(pepeolithic.priceNow(1, 1), 93750e18);
        vm.warp(START + 3455);
        assertGt(pepeolithic.priceNow(1, 1), FLOOR);
        vm.warp(START + 3456);
        assertEq(pepeolithic.priceNow(1, 1), FLOOR);
        vm.prank(_actor(0));
        assertEq(pepeolithic.buy(1, 1), 5);
        assertEq(pepeolithic.lastLineSale(1, 1), 0);
        assertEq(pepeolithic.openingPrice(1, 2), FIRST / 2);
        assertEq(coin.balanceOf(DEAD), FLOOR);
    }
}
