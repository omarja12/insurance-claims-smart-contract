// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ClaimsPool} from "../src/ClaimsPool.sol";

/// Foundry cheatcodes used by the tests (no external test library needed).
interface Vm {
    function prank(address) external;
    function deal(address, uint256) external;
    function warp(uint256) external;
    function expectRevert(bytes4) external;
    function expectRevert(bytes calldata) external;
}

contract Rejecter {
    // A customer contract that refuses ether.
    receive() external payable { revert("no"); }
    function buy(ClaimsPool pool, uint256 coverage) external payable { pool.buyPolicy{value: msg.value}(coverage); }
    function file(ClaimsPool pool, uint256 amount) external returns (uint256) { return pool.fileClaim(amount); }
    function pull(ClaimsPool pool) external { pool.withdraw(); }
}

contract ClaimsPoolTest {
    Vm constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    ClaimsPool pool;
    address constant ALICE = address(0xA11CE);
    address constant BOB = address(0xB0B);
    uint256 constant COVER = 10 ether;
    uint64 constant TERM = 365 days;

    function setUp() public {
        vm.deal(address(this), 100 ether);
        pool = new ClaimsPool{value: 20 ether}(500, TERM);    // 5% premium, one-year cover
        pool.setVerified(ALICE, true);
        vm.deal(ALICE, 10 ether);
        vm.deal(BOB, 10 ether);
    }

    receive() external payable {}

    function _buy(address who, uint256 coverage) internal {
        uint256 premium = pool.premiumFor(coverage);
        vm.prank(who);
        pool.buyPolicy{value: premium}(coverage);
    }

    function _file(address who, uint256 amount) internal returns (uint256 id) {
        vm.prank(who);
        id = pool.fileClaim(amount);
    }

    // --- happy path ---------------------------------------------------------

    function test_FullClaimLifecycle() public {
        _buy(ALICE, COVER);
        require(address(pool).balance == 20.5 ether, "premium credited to reserve");

        uint256 id = _file(ALICE, 4 ether);
        pool.decide(id, true);
        require(pool.withdrawable(ALICE) == 4 ether && pool.owed() == 4 ether, "payout owed");

        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        pool.withdraw();
        require(ALICE.balance == before + 4 ether, "paid");
        require(pool.owed() == 0 && pool.withdrawable(ALICE) == 0, "settled");
        (, uint256 claimed,) = pool.policies(ALICE);
        require(claimed == 4 ether, "cover used");
    }

    function test_RejectedClaimPaysNothing() public {
        _buy(ALICE, COVER);
        uint256 id = _file(ALICE, 3 ether);
        pool.decide(id, false);
        require(pool.withdrawable(ALICE) == 0 && pool.owed() == 0, "nothing owed");
        vm.expectRevert(ClaimsPool.NotPending.selector);
        pool.decide(id, true);
    }

    // --- access and pricing -------------------------------------------------

    function test_UnverifiedCannotBuy() public {
        uint256 premium = pool.premiumFor(COVER);
        vm.prank(BOB);
        vm.expectRevert(ClaimsPool.NotVerified.selector);
        pool.buyPolicy{value: premium}(COVER);
    }

    function test_WrongPremiumReverts() public {
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClaimsPool.WrongPremium.selector, 0.5 ether, 0.4 ether));
        pool.buyPolicy{value: 0.4 ether}(COVER);
    }

    function test_OnlyInsurerDecides() public {
        _buy(ALICE, COVER);
        uint256 id = _file(ALICE, 1 ether);
        vm.prank(ALICE);
        vm.expectRevert(ClaimsPool.NotInsurer.selector);
        pool.decide(id, true);
    }

    function test_CannotStackPolicies() public {
        _buy(ALICE, COVER);
        uint256 premium = pool.premiumFor(COVER);
        vm.prank(ALICE);
        vm.expectRevert(ClaimsPool.PolicyActive.selector);
        pool.buyPolicy{value: premium}(COVER);
    }

    // --- cover limits -------------------------------------------------------

    function test_ClaimAboveCoverReverts() public {
        _buy(ALICE, COVER);
        vm.prank(ALICE);
        vm.expectRevert(abi.encodeWithSelector(ClaimsPool.ExceedsCoverage.selector, COVER, COVER + 1));
        pool.fileClaim(COVER + 1);
    }

    function test_PendingClaimsCannotJointlyExceedCover() public {
        _buy(ALICE, COVER);
        uint256 a = _file(ALICE, 7 ether);
        uint256 b = _file(ALICE, 7 ether);      // each fits alone, not together
        pool.decide(a, true);
        vm.expectRevert(abi.encodeWithSelector(ClaimsPool.ExceedsCoverage.selector, 3 ether, 7 ether));
        pool.decide(b, true);
    }

    function test_ExpiredPolicyCannotClaim() public {
        _buy(ALICE, COVER);
        vm.warp(block.timestamp + TERM);
        vm.prank(ALICE);
        vm.expectRevert(ClaimsPool.NoActivePolicy.selector);
        pool.fileClaim(1 ether);
    }

    // --- solvency -----------------------------------------------------------

    function test_ApprovalNeedsFreeReserve() public {
        pool.withdrawSurplus(20 ether);                       // leave only the premium
        _buy(ALICE, COVER);
        uint256 id = _file(ALICE, 1 ether);
        vm.expectRevert(abi.encodeWithSelector(ClaimsPool.InsufficientReserve.selector, 0.5 ether, 1 ether));
        pool.decide(id, true);
    }

    function test_InsurerCannotTakeOwedMoney() public {
        _buy(ALICE, COVER);
        pool.decide(_file(ALICE, 10 ether), true);
        vm.expectRevert(abi.encodeWithSelector(ClaimsPool.InsufficientReserve.selector, 10.5 ether, 11 ether));
        pool.withdrawSurplus(11 ether);
    }

    function test_FailingReceiverKeepsItsBalance() public {
        Rejecter r = new Rejecter();
        pool.setVerified(address(r), true);
        r.buy{value: pool.premiumFor(1 ether)}(pool, 1 ether);
        pool.decide(r.file(pool, 1 ether), true);
        vm.expectRevert(ClaimsPool.TransferFailed.selector);
        r.pull(pool);
        require(pool.withdrawable(address(r)) == 1 ether && pool.owed() == 1 ether, "state rolled back");
    }

    // --- fuzz ---------------------------------------------------------------

    /// Any sequence of two approved claims stays within cover, and the pool stays solvent.
    function testFuzz_PayoutsWithinCoverAndSolvent(uint256 coverage, uint256 first, uint256 second) public {
        coverage = 1 + coverage % 1_000 ether;               // 1 wei .. 1,000 ether
        first = 1 + first % coverage;                        // 1 .. coverage
        second = second % (2 * coverage);                    // may or may not fit the rest
        vm.deal(address(pool), 2_000 ether);
        vm.deal(ALICE, 100 ether);
        _buy(ALICE, coverage);
        pool.decide(_file(ALICE, first), true);

        uint256 remaining = coverage - first;
        if (second == 0 || second > remaining) {
            vm.prank(ALICE);
            vm.expectRevert(abi.encodeWithSelector(ClaimsPool.ExceedsCoverage.selector, remaining, second));
            pool.fileClaim(second);
        } else {
            pool.decide(_file(ALICE, second), true);
        }
        (, uint256 claimed,) = pool.policies(ALICE);
        require(claimed <= coverage, "cover exceeded");
        require(address(pool).balance >= pool.owed(), "insolvent");
    }
}
