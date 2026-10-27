// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import "forge-std/Test.sol";
import {KeymindVault} from "../src/KeymindVault.sol";

contract Reenterer {
    KeymindVault public vault;
    bytes32 public grantId;

    function set(KeymindVault v, bytes32 id) external {
        vault = v;
        grantId = id;
    }

    receive() external payable {
        if (address(vault) == address(0)) return;
        if (grantId == bytes32(0)) vault.distribute(); // re-entry must hit the guard
        else vault.executeGrant(grantId);
    }
}

contract KeymindVaultTest is Test {
    KeymindVault vault;
    address guardian = makeAddr("kmd-guardian");
    address treasury = makeAddr("kmd-treasury");
    address builder = makeAddr("kmd-builder");
    address anyone = makeAddr("kmd-anyone");

    bytes32 constant GRANT = keccak256("KMD-GRANT-0001");
    bytes32 constant DESC = keccak256("TypeScript SDK: identity and messaging");

    function setUp() public {
        vm.warp(1_800_000_000);
        vault = new KeymindVault(guardian, treasury);
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        (bool ok,) = address(vault).call{value: amount}("");
        assertTrue(ok);
    }

    function _propose(bytes32 id, address to, uint128 amount) internal {
        vm.prank(guardian);
        vault.proposeGrant(id, to, amount, DESC);
    }

    function test_split80_20() public {
        _fund(1 ether);
        vault.distribute();
        assertEq(treasury.balance, 0.8 ether, "project treasury");
        assertEq(vault.grantsPool(), 0.2 ether, "grants kept");
        assertEq(address(vault).balance, 0.2 ether);
        assertEq(vault.pending(), 0);
        assertEq(vault.totalDistributed(), 1 ether);
    }

    function test_anyoneCanDistribute_repeatedSafely() public {
        _fund(1 ether);
        vm.prank(anyone);
        vault.distribute();
        vm.prank(anyone);
        vault.distribute(); // nothing pending: no-op
        assertEq(vault.grantsPool(), 0.2 ether);
        _fund(1 ether);
        vault.distribute();
        assertEq(vault.grantsPool(), 0.4 ether);
        assertEq(treasury.balance, 1.6 ether);
    }

    function test_grantLifecycle_reviewThenAnyoneExecutes() public {
        _fund(10 ether);
        vault.distribute(); // 2 ETH in the grants pool
        _propose(GRANT, builder, 0.5 ether); // exactly 25%
        (address to, uint128 amount, uint64 at, bool cancelled, bool paid, bytes32 desc) = vault.grants(GRANT);
        assertEq(to, builder);
        assertEq(amount, 0.5 ether);
        assertEq(at, block.timestamp);
        assertFalse(cancelled);
        assertFalse(paid);
        assertEq(desc, DESC);
        vm.prank(anyone);
        vm.expectRevert(KeymindVault.InReview.selector);
        vault.executeGrant(GRANT);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(anyone);
        vault.executeGrant(GRANT);
        assertEq(builder.balance, 0.5 ether);
        assertEq(vault.grantsPool(), 1.5 ether);
        assertEq(vault.totalGrantsPaid(), 0.5 ether);
        vm.expectRevert(KeymindVault.GrantAlreadyPaid.selector);
        vault.executeGrant(GRANT);
    }

    function test_proposeRules() public {
        _fund(10 ether);
        vault.distribute();
        vm.prank(anyone);
        vm.expectRevert(KeymindVault.NotGuardian.selector);
        vault.proposeGrant(GRANT, builder, 1, DESC);
        vm.startPrank(guardian);
        vm.expectRevert(KeymindVault.BadGrant.selector);
        vault.proposeGrant(bytes32(0), builder, 1, DESC);
        vm.expectRevert(KeymindVault.BadGrant.selector);
        vault.proposeGrant(GRANT, builder, 0, DESC);
        vm.expectRevert(KeymindVault.BadGrant.selector);
        vault.proposeGrant(GRANT, builder, 1, bytes32(0));
        vm.expectRevert(KeymindVault.ZeroAddress.selector);
        vault.proposeGrant(GRANT, address(0), 1, DESC);
        vm.expectRevert(KeymindVault.GrantTooLarge.selector);
        vault.proposeGrant(GRANT, builder, 0.5 ether + 1, DESC);
        vault.proposeGrant(GRANT, builder, 0.1 ether, DESC);
        vm.expectRevert(KeymindVault.GrantExists.selector);
        vault.proposeGrant(GRANT, builder, 0.1 ether, DESC);
        vm.stopPrank();
        assertEq(vault.grantCount(), 1);
    }

    function test_grantsNeverPayTreasuryGuardianOrVault() public {
        _fund(10 ether);
        vault.distribute();
        vm.startPrank(guardian);
        vm.expectRevert(KeymindVault.RecipientNotAllowed.selector);
        vault.proposeGrant(GRANT, treasury, 0.1 ether, DESC);
        vm.expectRevert(KeymindVault.RecipientNotAllowed.selector);
        vault.proposeGrant(GRANT, guardian, 0.1 ether, DESC);
        vm.expectRevert(KeymindVault.RecipientNotAllowed.selector);
        vault.proposeGrant(GRANT, address(vault), 0.1 ether, DESC);
        vm.stopPrank();
    }

    function test_recipientBecomingTreasuryCannotBePaid() public {
        _fund(10 ether);
        vault.distribute();
        _propose(GRANT, builder, 0.1 ether);
        vm.prank(guardian);
        vault.proposeTreasury(builder); // pending treasury is already excluded
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(KeymindVault.RecipientNotAllowed.selector);
        vault.executeGrant(GRANT);
        vm.prank(guardian);
        vault.cancelProposal(0);
        vault.executeGrant(GRANT);
        assertEq(builder.balance, 0.1 ether);
    }

    function test_cancelDuringReview() public {
        _fund(10 ether);
        vault.distribute();
        _propose(GRANT, builder, 0.1 ether);
        vm.prank(anyone);
        vm.expectRevert(KeymindVault.NotGuardian.selector);
        vault.cancelGrant(GRANT);
        vm.prank(guardian);
        vault.cancelGrant(GRANT);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(KeymindVault.GrantIsCancelled.selector);
        vault.executeGrant(GRANT);
        vm.prank(guardian);
        vm.expectRevert(KeymindVault.GrantIsCancelled.selector);
        vault.cancelGrant(GRANT);
        assertEq(vault.grantsPool(), 2 ether);
    }

    function test_cannotCancelAfterPayment_unknownGrant() public {
        _fund(10 ether);
        vault.distribute();
        _propose(GRANT, builder, 0.1 ether);
        vm.warp(block.timestamp + 24 hours);
        vault.executeGrant(GRANT);
        vm.startPrank(guardian);
        vm.expectRevert(KeymindVault.GrantAlreadyPaid.selector);
        vault.cancelGrant(GRANT);
        vm.expectRevert(KeymindVault.UnknownGrant.selector);
        vault.cancelGrant(keccak256("nope"));
        vm.stopPrank();
        vm.expectRevert(KeymindVault.UnknownGrant.selector);
        vault.executeGrant(keccak256("nope"));
    }

    function test_grantsCannotOverdrawPool() public {
        _fund(10 ether);
        vault.distribute(); // pool 2 ETH
        bytes32[5] memory ids;
        for (uint256 i; i < 5; ++i) {
            ids[i] = keccak256(abi.encode("grant", i));
            _propose(ids[i], builder, 0.5 ether); // each 25% of the pool when proposed
        }
        vm.warp(block.timestamp + 24 hours);
        for (uint256 i; i < 4; ++i) vault.executeGrant(ids[i]);
        assertEq(vault.grantsPool(), 0);
        vm.expectRevert(KeymindVault.InsufficientPool.selector);
        vault.executeGrant(ids[4]);
        assertEq(address(vault).balance, 0);
    }

    function test_grantsPoolCannotLeaveAnyOtherWay() public {
        _fund(2 ether);
        vault.distribute();
        uint256 pool = vault.grantsPool();
        vault.distribute(); // distribute never touches the pool
        assertEq(address(vault).balance, pool);
        assertEq(vault.pending(), 0);
    }

    function test_treasuryTimelock_oldFeesToOldTreasury() public {
        address next = makeAddr("kmd-new-treasury");
        vm.prank(guardian);
        vm.expectRevert(KeymindVault.ZeroAddress.selector);
        vault.proposeTreasury(address(0));
        vm.prank(guardian);
        vault.proposeTreasury(next);
        _fund(1 ether); // earned before the change
        vm.prank(guardian);
        vm.expectRevert(KeymindVault.TooEarly.selector);
        vault.executeTreasury();
        vm.warp(block.timestamp + 48 hours);
        vm.prank(guardian);
        vault.executeTreasury();
        assertEq(treasury.balance, 0.8 ether, "old treasury got the old fees");
        assertEq(vault.treasury(), next);
        _fund(1 ether);
        vault.distribute();
        assertEq(next.balance, 0.8 ether, "new fees go to the new treasury");
    }

    function test_guardianTimelocked_andCancellable() public {
        address dao = makeAddr("kmd-dao");
        vm.startPrank(guardian);
        vault.proposeGuardian(dao);
        vm.expectRevert(KeymindVault.TooEarly.selector);
        vault.executeGuardian();
        vault.cancelProposal(1);
        vm.warp(block.timestamp + 48 hours);
        vm.expectRevert(KeymindVault.NothingPending.selector);
        vault.executeGuardian();
        vault.proposeGuardian(dao);
        vm.warp(block.timestamp + 48 hours);
        vault.executeGuardian();
        vm.stopPrank();
        assertEq(vault.guardian(), dao);
        vm.prank(guardian);
        vm.expectRevert(KeymindVault.NotGuardian.selector);
        vault.proposeTreasury(dao);
    }

    function test_reentrantTreasuryCannotDoubleDistribute() public {
        Reenterer r = new Reenterer();
        KeymindVault v = new KeymindVault(guardian, address(r));
        r.set(v, bytes32(0));
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(v).call{value: 1 ether}("");
        assertTrue(ok);
        vm.expectRevert(KeymindVault.TransferFailed.selector);
        v.distribute();
    }

    function test_reentrantGranteeCannotDoubleCollect() public {
        Reenterer r = new Reenterer();
        _fund(10 ether);
        vault.distribute();
        _propose(GRANT, address(r), 0.1 ether);
        r.set(vault, GRANT);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(KeymindVault.TransferFailed.selector);
        vault.executeGrant(GRANT);
        assertEq(vault.grantsPool(), 2 ether);
    }

    function test_zeroAddressesRejected() public {
        vm.expectRevert(KeymindVault.ZeroAddress.selector);
        new KeymindVault(address(0), treasury);
        vm.expectRevert(KeymindVault.ZeroAddress.selector);
        new KeymindVault(guardian, address(0));
    }

    function testFuzz_splitAlwaysAddsUp(uint96 amount) public {
        vm.assume(amount > 0);
        _fund(amount);
        vault.distribute();
        assertEq(treasury.balance + vault.grantsPool(), amount);
        assertEq(address(vault).balance, vault.grantsPool());
    }

    function testFuzz_grantNeverAboveQuarterOfPool(uint96 funded, uint128 asked) public {
        vm.assume(funded > 0);
        _fund(funded);
        vault.distribute();
        uint256 cap = vault.grantsPool() * 2500 / 10_000;
        vm.prank(guardian);
        if (asked == 0) vm.expectRevert(KeymindVault.BadGrant.selector);
        else if (asked > cap) vm.expectRevert(KeymindVault.GrantTooLarge.selector);
        vault.proposeGrant(GRANT, builder, asked, DESC);
    }
}
