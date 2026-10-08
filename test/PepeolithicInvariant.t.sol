// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepeolithic} from "src/Pepeolithic.sol";
import {MockCoin} from "test/Pepeolithic.t.sol";
import {PepeolithicSetup} from "test/support/PepeolithicSetup.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Ghost inventory is constructed from the brief, never from isSalePiece/saleCount/ownerOf.
contract PepeolithicLifecycleHandler is PepeolithicSetup {
    uint256[][8] private saleIds;
    uint256[] private freeIds;
    uint256[] private mintedIds;
    mapping(uint256 => address) private owners;
    mapping(address => uint256) private balances;
    mapping(address => uint256) private spent;
    mapping(uint256 => mapping(uint256 => uint256)) private sold;
    bool[8] private seatsClaimed;
    bool[8] private cavesFrozen;
    bool private released;
    uint256 private freeTaken;
    uint256 private paid;
    uint256 private purchases;
    uint256 private leftovers;
    uint256 private claims;
    uint256 private swept;

    constructor(Pepeolithic target, MockCoin mock) {
        pepeolithic = target;
        coin = mock;
        _record(0, ADAM);
        _record(736, ADMIN);
        uint256 id = 1;
        for (uint256 c = 1; c <= 7; ++c) {
            for (uint256 r = 1; r <= 21; ++r) {
                for (uint256 slot = 1; slot <= 5; ++slot) {
                    if (slot + _quota(c, r) > 5) saleIds[c].push(id);
                    else freeIds.push(id);
                    ++id;
                }
            }
        }
        assertEq(freeIds.length, 335);
    }

    function advanceTime(uint256 secondsSeed) public {
        uint256 next = block.timestamp + bound(secondsSeed, 0, 172800);
        vm.warp(next > START + 10 * 86400 ? START + 10 * 86400 : next);
    }

    function buy(uint256 actorSeed, uint256 caveSeed, uint256 roundSeed, bool activeCave, bool rejectPayment) public {
        address buyer = _actor(actorSeed % 8);
        uint256 c = bound(caveSeed, 1, 7);
        uint256 r = bound(roundSeed, 1, 21);
        if (activeCave && block.timestamp >= START && block.timestamp < START + 7 * 86400) {
            c = (block.timestamp - START) / 86400 + 1;
            uint256 latest = (block.timestamp - START - (c - 1) * 86400) / 3600 + 1;
            r = bound(roundSeed, 1, latest > 21 ? 21 : latest);
        }
        bytes4 error;
        uint256 opens = START + (c - 1) * 86400 + (r - 1) * 3600;
        if (block.timestamp < opens || block.timestamp >= START + c * 86400) error = Pepeolithic.NotOpen.selector;
        else if (sold[c][r] == _quota(c, r)) error = Pepeolithic.SoldOut.selector;
        else if (rejectPayment) error = Pepeolithic.PaymentFailed.selector;

        uint256 lineBefore = pepeolithic.lastLineSale(c, r);
        uint256 openingBefore = pepeolithic.openingPrice(c, r);
        coin.fail(rejectPayment, false);
        if (error != bytes4(0)) {
            vm.expectRevert(error);
            vm.prank(buyer);
            pepeolithic.buy(c, r);
            assertEq(pepeolithic.roundSold(c, r), sold[c][r]);
            assertEq(pepeolithic.lastLineSale(c, r), lineBefore);
            assertEq(pepeolithic.openingPrice(c, r), openingBefore);
        } else {
            uint256 quote = pepeolithic.priceNow(c, r);
            uint256 expectedId = (c - 1) * 105 + r * 5 - sold[c][r];
            vm.prank(buyer);
            uint256 id = pepeolithic.buy(c, r);
            assertEq(id, expectedId, "sale must take descending slots");
            _record(id, buyer);
            ++sold[c][r];
            ++purchases;
            _charge(buyer, quote);
            assertEq(pepeolithic.roundSold(c, r), sold[c][r]);
            assertEq(pepeolithic.openingPrice(c, r), openingBefore);
            assertEq(pepeolithic.lastLineSale(c, r), quote > FLOOR ? quote : lineBefore);
        }
        coin.fail(false, false);
    }

    function claim(uint256 actorSeed, bool corruptProof) public {
        uint256 actorIndex = actorSeed % 8;
        address who = _actor(actorIndex);
        bytes32[] memory proof = _seatProof(actorIndex);
        if (corruptProof) proof[0] = bytes32(uint256(proof[0]) ^ 1);
        bytes4 error;
        if (block.timestamp < START) error = Pepeolithic.TooEarly.selector;
        else if (released) error = Pepeolithic.SeatsReleased.selector;
        else if (seatsClaimed[actorIndex]) error = Pepeolithic.AlreadyClaimed.selector;
        else if (corruptProof) error = Pepeolithic.InvalidProof.selector;
        if (error != bytes4(0)) {
            vm.expectRevert(error);
            vm.prank(who);
            pepeolithic.claimSeat(proof);
        } else {
            vm.prank(who);
            uint256 id = pepeolithic.claimSeat(proof);
            assertEq(id, freeIds[freeTaken], "claim skips all sale slots");
            ++freeTaken;
            ++claims;
            seatsClaimed[actorIndex] = true;
            _record(id, who);
        }
        assertEq(pepeolithic.claimed(who), seatsClaimed[actorIndex]);
    }

    function release(uint256 actorSeed) public {
        bytes4 error;
        if (block.timestamp < START + 8 * 86400) error = Pepeolithic.TooEarly.selector;
        else if (released) error = Pepeolithic.AlreadyReleased.selector;
        if (error != bytes4(0)) vm.expectRevert(error);
        vm.prank(_actor(actorSeed % 8));
        pepeolithic.releaseUnclaimed();
        if (error == bytes4(0)) released = true;
    }

    function buyLeftover(uint256 actorSeed, bool rejectPayment) public {
        address buyer = _actor(actorSeed % 8);
        bytes4 error;
        if (!released) error = Pepeolithic.NotReleased.selector;
        else if (freeTaken == 335) error = Pepeolithic.SoldOut.selector;
        else if (rejectPayment) error = Pepeolithic.PaymentFailed.selector;
        uint256 cursorBefore = pepeolithic.nextFree();
        coin.fail(rejectPayment, false);
        if (error != bytes4(0)) {
            vm.expectRevert(error);
            vm.prank(buyer);
            pepeolithic.buyLeftover();
            assertEq(pepeolithic.nextFree(), cursorBefore, "failed payment cannot consume a seat");
        } else {
            vm.prank(buyer);
            uint256 id = pepeolithic.buyLeftover();
            assertEq(id, freeIds[freeTaken], "claims and leftovers share one queue");
            ++freeTaken;
            ++leftovers;
            _record(id, buyer);
            _charge(buyer, FLOOR);
        }
        coin.fail(false, false);
    }

    function sweep(uint256 caveSeed, uint256 quantitySeed, uint256 actorSeed) public {
        uint256 c = bound(caveSeed, 1, 7);
        uint256 quantity = quantitySeed == type(uint256).max ? quantitySeed : bound(quantitySeed, 0, 110);
        uint256[] memory expected = new uint256[](saleIds[c].length);
        uint256 count;
        for (uint256 i; i < saleIds[c].length && count < quantity; ++i) {
            uint256 id = saleIds[c][i];
            if (owners[id] == address(0)) expected[count++] = id;
        }
        bytes4 error;
        if (block.timestamp < START + c * 86400) error = Pepeolithic.NotClosed.selector;
        else if (quantity == 0) error = Pepeolithic.InvalidQuantity.selector;
        else if (count == 0) error = Pepeolithic.SoldOut.selector;
        if (error != bytes4(0)) {
            vm.expectRevert(error);
            vm.prank(_actor(actorSeed % 8));
            pepeolithic.sweep(c, quantity);
        } else {
            vm.recordLogs();
            vm.prank(_actor(actorSeed % 8));
            assertEq(pepeolithic.sweep(c, quantity), count, "sweep batch count");
            Vm.Log[] memory logs = vm.getRecordedLogs();
            uint256 eventIndex;
            for (uint256 i; i < logs.length; ++i) {
                if (logs[i].emitter == address(pepeolithic) && logs[i].topics[0] == keccak256("Swept(uint256)")) {
                    assertLt(eventIndex, count);
                    assertEq(uint256(logs[i].topics[1]), expected[eventIndex++], "sweep events in ID order");
                }
            }
            assertEq(eventIndex, count);
            for (uint256 i; i < count; ++i) {
                _record(expected[i], ADMIN);
            }
            swept += count;
        }
    }

    function transfer(uint256 idSeed, uint256 recipientSeed) public {
        uint256 id = mintedIds[idSeed % mintedIds.length];
        address from = owners[id];
        address to = recipientSeed % 9 == 8 ? ADMIN : _actor(recipientSeed % 8);
        vm.prank(from);
        pepeolithic.transferFrom(from, to, id);
        --balances[from];
        ++balances[to];
        owners[id] = to;
        assertEq(pepeolithic.ownerOf(id), to);
    }

    function freeze(uint256 caveSeed, bool asAdmin, bool invalidBase) public {
        uint256 c = bound(caveSeed, 1, 7);
        bytes4 error;
        if (!asAdmin) error = Pepeolithic.Unauthorized.selector;
        else if (cavesFrozen[c]) error = Pepeolithic.AlreadyFrozen.selector;
        else if (invalidBase) error = Pepeolithic.InvalidBase.selector;
        if (error != bytes4(0)) vm.expectRevert(error);
        vm.prank(asAdmin ? ADMIN : _actor(0));
        pepeolithic.freeze(c, invalidBase ? "ipfs://invalid" : "ipfs://permanent/");
        if (error == bytes4(0)) cavesFrozen[c] = true;
    }

    function checkAccounting() public view {
        assertEq(pepeolithic.totalSupply(), 2 + purchases + claims + leftovers + swept);
        assertEq(pepeolithic.totalSupply(), mintedIds.length);
        assertLe(mintedIds.length, 737);
        assertLe(purchases + swept, 400);
        assertEq(claims + leftovers, freeTaken);
        assertLe(freeTaken, 335);
        assertEq(coin.balanceOf(DEAD), paid, "every charge reaches dead");
        assertEq(coin.balanceOf(address(pepeolithic)), 0, "no custody in any normal call sequence");
        assertEq(address(pepeolithic).balance, 0);
        assertEq(coin.balanceOf(ADMIN), 0, "admin receives NFTs, never payments");
        uint256 totalBalances = pepeolithic.balanceOf(ADMIN) + pepeolithic.balanceOf(ADAM);
        assertEq(pepeolithic.balanceOf(ADMIN), balances[ADMIN]);
        assertEq(pepeolithic.balanceOf(ADAM), balances[ADAM]);
        for (uint256 i; i < 8; ++i) {
            address who = _actor(i);
            assertEq(pepeolithic.balanceOf(who), balances[who]);
            assertEq(coin.balanceOf(who), FUNDS - spent[who]);
            assertEq(pepeolithic.claimed(who), seatsClaimed[i]);
            totalBalances += pepeolithic.balanceOf(who);
        }
        assertEq(totalBalances, mintedIds.length, "NFT balances conserve supply");
        assertEq(pepeolithic.unclaimedReleased(), released);
        for (uint256 c = 1; c <= 7; ++c) {
            assertEq(pepeolithic.frozen(c), cavesFrozen[c]);
            if (cavesFrozen[c]) assertEq(pepeolithic.frozenBase(c), "ipfs://permanent/");
        }
    }

    /// @dev Exercise liveness after every random sequence, including sequences with failed operations.
    function finish() public {
        if (vm.getBlockTimestamp() < START + 8 * 86400) vm.warp(START + 8 * 86400);
        for (uint256 c = 1; c <= 7; ++c) {
            sweep(c, type(uint256).max, c);
        }
        if (!released) release(0);
        while (freeTaken < 335) buyLeftover(freeTaken % 8, false);
        checkAccounting();
        assertEq(pepeolithic.totalSupply(), 737, "all remaining inventory stays reachable");
        for (uint256 id; id <= 736; ++id) {
            assertEq(pepeolithic.ownerOf(id), owners[id]);
        }
        for (uint256 c = 1; c <= 7; ++c) {
            for (uint256 r = 1; r <= 21; ++r) {
                assertEq(pepeolithic.roundSold(c, r), sold[c][r]);
            }
            sweep(c, type(uint256).max, 0);
        }
        buyLeftover(0, false);
        claim(0, false);
        checkAccounting();
    }

    function _record(uint256 id, address who) private {
        assertLe(id, 736);
        assertEq(owners[id], address(0), "piece cannot be minted twice");
        assertEq(pepeolithic.ownerOf(id), who, "piece must reach expected recipient");
        owners[id] = who;
        ++balances[who];
        mintedIds.push(id);
    }

    function _charge(address buyer, uint256 amount) private {
        paid += amount;
        spent[buyer] += amount;
        assertEq(coin.lastFrom(), buyer);
        assertEq(coin.lastTo(), DEAD);
        assertEq(coin.lastAmount(), amount);
    }
}

contract PepeolithicInvariantTest is PepeolithicSetup {
    PepeolithicLifecycleHandler internal handler;

    function setUp() public {
        _installCoin();
        Config memory p = _config();
        p.root = _seatTree()[1];
        pepeolithic = _deploy(p);
        for (uint256 i; i < 8; ++i) {
            _fund(_actor(i), pepeolithic, FUNDS);
        }
        handler = new PepeolithicLifecycleHandler(pepeolithic, coin);
        vm.warp(START - 1);
        bytes4[] memory selectors = new bytes4[](8);
        selectors[0] = handler.advanceTime.selector;
        selectors[1] = handler.buy.selector;
        selectors[2] = handler.claim.selector;
        selectors[3] = handler.release.selector;
        selectors[4] = handler.buyLeftover.selector;
        selectors[5] = handler.sweep.selector;
        selectors[6] = handler.transfer.selector;
        selectors[7] = handler.freeze.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
    }

    /// forge-config: default.invariant.runs = 256
    /// forge-config: default.invariant.depth = 128
    /// forge-config: default.invariant.fail-on-revert = true
    function invariant_supplyPaymentAndPermanentTransitions() public view {
        handler.checkAccounting();
    }

    function afterInvariant() public {
        handler.finish();
    }

    function testHandlerExercisesEveryTransition() public {
        handler.claim(0, false); // Too early.
        handler.advanceTime(1);
        handler.claim(0, true);
        handler.claim(0, false);
        handler.claim(0, false); // Duplicate.
        handler.buy(1, 1, 1, false, true);
        handler.buy(1, 1, 1, false, false);
        handler.transfer(2, 3);
        handler.freeze(1, false, false);
        handler.freeze(1, true, true);
        handler.freeze(1, true, false);
        handler.freeze(1, true, false);
        handler.sweep(1, 1, 4); // Not closed.
        handler.release(0); // Too early.
        handler.advanceTime(86400);
        handler.sweep(1, 0, 4);
        handler.sweep(1, 1, 4);
        handler.checkAccounting();
        handler.advanceTime(172800);
        handler.advanceTime(172800);
        handler.advanceTime(172800);
        handler.advanceTime(86400);
        handler.release(5);
        handler.buyLeftover(6, true);
        handler.buyLeftover(6, false);
        handler.claim(1, false);
        handler.finish();
    }
}
