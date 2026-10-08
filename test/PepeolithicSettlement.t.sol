// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Pepeolithic} from "src/Pepeolithic.sol";
import {PepeolithicSetup} from "test/support/PepeolithicSetup.sol";
import {IERC721Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";

/// @dev A local dependency adversary, not a model of live ZTO behavior. It really
/// debits balances before invoking a callback and returning configurable ABI data.
contract PepeolithicSettlementCoin {
    error InsufficientFunds();
    error InsufficientApproval();
    error OuterPaymentReverted();
    error NestedCallFailed(bytes reason);

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    Pepeolithic private target;
    bytes private callbackData;
    uint256 private observedId;
    uint8 private resultMode;
    bool private swallowFailure;
    bool private inside;
    bool public nestedSucceeded;
    bytes public nestedResult;
    uint256 public observedSupply;
    uint256 public observedCursor;
    address public observedOwner;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function arm(Pepeolithic target_, bytes memory data, uint256 id, uint8 mode, bool catchFailure) external {
        target = target_;
        callbackData = data;
        observedId = id;
        resultMode = mode;
        swallowFailure = catchFailure;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (balanceOf[from] < amount) revert InsufficientFunds();
        if (allowance[from][msg.sender] < amount) revert InsufficientApproval();
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        allowance[from][msg.sender] -= amount;
        if (inside) return true; // The nested payment always succeeds.

        observedSupply = target.totalSupply();
        observedCursor = target.nextFree();
        observedOwner = target.ownerOf(observedId);
        if (callbackData.length != 0) {
            inside = true;
            (nestedSucceeded, nestedResult) = address(target).call(callbackData);
            inside = false;
            if (!nestedSucceeded && !swallowFailure) revert NestedCallFailed(nestedResult);
        }

        if (resultMode == 1) return false;
        if (resultMode == 2) revert OuterPaymentReverted();
        if (resultMode == 3) {
            assembly ("memory-safe") { return(0, 0) }
        }
        if (resultMode == 4) {
            // A single 0x01 byte is not an ABI-encoded bool.
            assembly ("memory-safe") {
                mstore(0, 1)
                return(31, 1)
            }
        }
        if (resultMode == 5) {
            // ABI bools permit only 0 or 1, even in a full word.
            assembly ("memory-safe") {
                mstore(0, 2)
                return(0, 32)
            }
        }
        return true;
    }
}

contract PepeolithicSettlementTest is PepeolithicSetup {
    PepeolithicSettlementCoin private settlement;

    function setUp() public {
        vm.chainId(1);
        PepeolithicSettlementCoin implementation = new PepeolithicSettlementCoin();
        vm.etch(COIN, address(implementation).code);
        settlement = PepeolithicSettlementCoin(COIN);
        pepeolithic = _deploy(_config());
        _fundSettlement(_actor(0));
        _fundSettlement(COIN);
    }

    /// forge-config: default.fuzz.runs = 128
    function testFuzzFailedOuterPaymentRollsBackSuccessfulNestedPurchase(uint8 failureSeed, bool leftover) public {
        uint8 mode = uint8(bound(failureSeed, 1, 5));
        uint256 outerId = leftover ? 1 : 215;
        uint256 innerId = leftover ? 2 : 214;
        uint256 price = leftover ? FLOOR : 2 * FLOOR;
        bytes memory callback =
            leftover ? abi.encodeCall(Pepeolithic.buyLeftover, ()) : abi.encodeCall(Pepeolithic.buy, (3, 1));
        _open(leftover);
        settlement.arm(pepeolithic, callback, outerId, mode, false);
        // A nested failure would produce NestedCallFailed, not the expected outer error.
        vm.expectCall(address(pepeolithic), callback);
        _expectFailure(mode);
        _purchase(leftover);
        _assertUnissued(outerId);
        _assertUnissued(innerId);
        _assertUnpaid();
        assertEq(pepeolithic.totalSupply(), 2);
        assertEq(pepeolithic.nextFree(), 1);
        assertEq(pepeolithic.roundSold(3, 1), 0);
        assertEq(pepeolithic.lastLineSale(3, 1), 0);
        assertEq(pepeolithic.openingPrice(3, 2), 2 * FLOOR);

        // Retry the identical nested sequence with a valid true return.
        settlement.arm(pepeolithic, callback, outerId, 0, false);
        assertEq(_purchase(leftover), outerId);
        assertTrue(settlement.nestedSucceeded());
        assertEq(abi.decode(settlement.nestedResult(), (uint256)), innerId);
        assertEq(settlement.observedSupply(), 3, "outer mint is visible at the coin boundary");
        assertEq(settlement.observedOwner(), _actor(0));
        assertEq(pepeolithic.ownerOf(outerId), _actor(0));
        assertEq(pepeolithic.ownerOf(innerId), COIN);
        assertEq(pepeolithic.totalSupply(), 4);
        assertEq(settlement.balanceOf(_actor(0)), FUNDS - price);
        assertEq(settlement.balanceOf(COIN), FUNDS - price);
        assertEq(settlement.balanceOf(DEAD), 2 * price);
        assertEq(settlement.balanceOf(address(pepeolithic)), 0);
        assertEq(settlement.allowance(_actor(0), address(pepeolithic)), FUNDS - price);
        assertEq(settlement.allowance(COIN, address(pepeolithic)), FUNDS - price);
        if (leftover) {
            assertEq(settlement.observedCursor(), 2);
            assertEq(pepeolithic.nextFree(), 3);
        } else {
            assertEq(pepeolithic.roundSold(3, 1), 2);
            assertEq(pepeolithic.lastLineSale(3, 1), price);
            assertEq(pepeolithic.openingPrice(3, 2), 2 * price);
        }
    }

    function testCaughtNestedSoldOutDoesNotUndoPaidOuterPurchase() public {
        vm.warp(START);
        settlement.arm(pepeolithic, abi.encodeCall(Pepeolithic.buy, (1, 1)), 5, 0, true);
        vm.prank(_actor(0));
        assertEq(pepeolithic.buy(1, 1), 5);
        assertFalse(settlement.nestedSucceeded());
        assertEq(settlement.nestedResult(), abi.encodeWithSelector(Pepeolithic.SoldOut.selector));
        assertEq(pepeolithic.ownerOf(5), _actor(0));
        assertEq(pepeolithic.roundSold(1, 1), 1);
        assertEq(pepeolithic.totalSupply(), 3);
        assertEq(settlement.balanceOf(DEAD), FIRST);
        assertEq(settlement.balanceOf(COIN), FUNDS);
        assertEq(pepeolithic.openingPrice(1, 2), 2 * FIRST);
    }

    function testPaymentCallbackCanTransferAlreadyMintedPieceWithoutChangingIssuance() public {
        vm.prank(_actor(0));
        pepeolithic.setApprovalForAll(COIN, true);
        bytes memory callback = abi.encodeCall(pepeolithic.transferFrom, (_actor(0), _actor(1), 5));
        settlement.arm(pepeolithic, callback, 5, 0, false);
        vm.warp(START);
        vm.prank(_actor(0));
        assertEq(pepeolithic.buy(1, 1), 5);
        assertTrue(settlement.nestedSucceeded());
        assertEq(settlement.observedOwner(), _actor(0));
        assertEq(pepeolithic.ownerOf(5), _actor(1));
        assertEq(pepeolithic.balanceOf(_actor(0)), 0);
        assertEq(pepeolithic.balanceOf(_actor(1)), 1);
        assertEq(pepeolithic.totalSupply(), 3);
        assertEq(pepeolithic.roundSold(1, 1), 1);
        assertEq(settlement.balanceOf(DEAD), FIRST);
    }

    function testRejectedPaymentRollsBackNestedTransferAndPreservesOperatorApproval() public {
        vm.prank(_actor(0));
        pepeolithic.setApprovalForAll(COIN, true);
        settlement.arm(pepeolithic, abi.encodeCall(pepeolithic.transferFrom, (_actor(0), _actor(1), 5)), 5, 1, false);
        vm.warp(START);
        vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        vm.prank(_actor(0));
        pepeolithic.buy(1, 1);
        _assertUnissued(5);
        assertEq(pepeolithic.balanceOf(_actor(0)), 0);
        assertEq(pepeolithic.balanceOf(_actor(1)), 0);
        assertEq(pepeolithic.totalSupply(), 2);
        assertEq(pepeolithic.roundSold(1, 1), 0);
        assertTrue(pepeolithic.isApprovedForAll(_actor(0), COIN), "preexisting approval survives rollback");
        _assertUnpaid();
    }

    function testNestedSeatClaimRollsBackWithRejectedSaleAndCanBeRetried() public {
        Config memory p = _config();
        p.root = keccak256(abi.encodePacked(COIN)); // Explicitly local one-leaf fixture.
        pepeolithic = _deploy(p);
        vm.prank(_actor(0));
        settlement.approve(address(pepeolithic), FUNDS);
        vm.prank(COIN);
        settlement.approve(address(pepeolithic), FUNDS);
        bytes memory callback = abi.encodeCall(Pepeolithic.claimSeat, (new bytes32[](0)));
        settlement.arm(pepeolithic, callback, 5, 1, false);
        vm.warp(START);
        vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        vm.prank(_actor(0));
        pepeolithic.buy(1, 1);
        assertFalse(pepeolithic.claimed(COIN));
        assertEq(pepeolithic.nextFree(), 1);
        assertEq(pepeolithic.totalSupply(), 2);
        _assertUnissued(1);
        _assertUnissued(5);
        _assertUnpaid();

        settlement.arm(pepeolithic, callback, 5, 0, false);
        vm.prank(_actor(0));
        pepeolithic.buy(1, 1);
        assertTrue(pepeolithic.claimed(COIN));
        assertEq(pepeolithic.ownerOf(1), COIN);
        assertEq(pepeolithic.ownerOf(5), _actor(0));
        assertEq(pepeolithic.nextFree(), 2);
        assertEq(pepeolithic.totalSupply(), 4);
        assertEq(settlement.balanceOf(DEAD), FIRST, "nested seat is free");
    }

    function testNestedSweepRollsBackWithRejectedSaleIncludingSweepCursor() public {
        vm.warp(START + 86400);
        settlement.arm(pepeolithic, abi.encodeCall(Pepeolithic.sweep, (1, 1)), 110, 1, false);
        vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        vm.prank(_actor(0));
        pepeolithic.buy(2, 1);
        assertEq(pepeolithic.totalSupply(), 2);
        assertEq(pepeolithic.balanceOf(ADMIN), 1);
        _assertUnissued(5);
        _assertUnissued(110);
        _assertUnpaid();
        assertEq(pepeolithic.sweep(1, 1), 1);
        assertEq(pepeolithic.ownerOf(5), ADMIN, "rollback must restore the first sweepable id");
        _assertUnissued(10);
        assertEq(pepeolithic.totalSupply(), 3);
    }

    function testReentryAtLastFreePieceCannotMintPastSeatInventory() public {
        _open(true);
        // No callback while filling the first 334 places in the seat queue.
        uint256 next = 1;
        for (uint256 i; i < 334; ++i) {
            while (_saleId(next)) ++next;
            settlement.arm(pepeolithic, "", next, 0, false);
            assertEq(_purchase(true), next++);
        }
        settlement.arm(pepeolithic, abi.encodeCall(Pepeolithic.buyLeftover, ()), 726, 0, true);
        assertEq(_purchase(true), 726); // Cave 7, round 20, slot 1 is the last seat.
        assertFalse(settlement.nestedSucceeded());
        assertEq(settlement.nestedResult(), abi.encodeWithSelector(Pepeolithic.SoldOut.selector));
        assertEq(pepeolithic.totalSupply(), 337);
        assertEq(pepeolithic.balanceOf(_actor(0)), 335);
        assertEq(settlement.balanceOf(DEAD), 335 * FLOOR);
        assertEq(settlement.balanceOf(COIN), FUNDS);
        vm.expectRevert(Pepeolithic.SoldOut.selector);
        _purchase(true);
        _assertUnissued(731); // Final-round slot 1 is a sale piece, never a seat.
        _assertUnissued(737);
    }

    function _saleId(uint256 id) private pure returns (bool) {
        uint256 c = (id - 1) / 105 + 1;
        uint256 r = (id - 1) % 105 / 5 + 1;
        return (id - 1) % 5 + 1 + _quota(c, r) > 5;
    }

    function _fundSettlement(address buyer) private {
        settlement.mint(buyer, FUNDS);
        vm.prank(buyer);
        settlement.approve(address(pepeolithic), FUNDS);
    }

    function _open(bool leftover) private {
        vm.warp(START + (leftover ? 8 : 2) * 86400);
        if (leftover) pepeolithic.releaseUnclaimed();
    }

    function _purchase(bool leftover) private returns (uint256) {
        vm.prank(_actor(0));
        return leftover ? pepeolithic.buyLeftover() : pepeolithic.buy(3, 1);
    }

    function _expectFailure(uint8 mode) private {
        if (mode == 1) vm.expectRevert(Pepeolithic.PaymentFailed.selector);
        else if (mode == 2) vm.expectRevert(PepeolithicSettlementCoin.OuterPaymentReverted.selector);
        else vm.expectRevert(bytes("")); // Invalid ABI return data produces an empty revert.
    }

    function _assertUnissued(uint256 id) private {
        vm.expectRevert(abi.encodeWithSelector(IERC721Errors.ERC721NonexistentToken.selector, id));
        pepeolithic.ownerOf(id);
    }

    function _assertUnpaid() private view {
        assertEq(settlement.balanceOf(_actor(0)), FUNDS);
        assertEq(settlement.balanceOf(COIN), FUNDS);
        assertEq(settlement.balanceOf(DEAD), 0);
        assertEq(settlement.balanceOf(address(pepeolithic)), 0);
        assertEq(settlement.allowance(_actor(0), address(pepeolithic)), FUNDS);
        assertEq(settlement.allowance(COIN, address(pepeolithic)), FUNDS);
    }
}
