// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "../src/AgentQuests.sol";

/// @notice Minimal mock of the SPACE ID Agent ID registry.
/// @dev In tests this contract's bytecode is etched at the real registry address
///      with `vm.etch`, so AgentQuests (which hardcodes the registry address)
///      talks to the mock. Only `balanceOf` and `handleOf` are needed.
contract MockAgentIdRegistry {
    mapping(address => uint256) public balances;
    mapping(address => string) public handles;

    function setBalance(address who, uint256 bal) external {
        balances[who] = bal;
    }

    function setHandle(address who, string calldata h) external {
        handles[who] = h;
    }

    function balanceOf(address who) external view returns (uint256) {
        return balances[who];
    }

    function handleOf(address who) external view returns (string memory) {
        return handles[who];
    }
}

contract AgentQuestsTest is Test {
    AgentQuests public quests;
    MockAgentIdRegistry public registry;

    address constant REGISTRY_ADDR = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");
    address public carol = makeAddr("carol");
    address public dave = makeAddr("dave"); // no Agent ID
    address public erin = makeAddr("erin");

    /// 2026-11-19T00:00:00Z (Thursday) — exactly a Unix week boundary, so test
    /// days 0..6 all fall in the same week.
    uint256 public constant T0 = 1795046400;

    function setUp() public {
        MockAgentIdRegistry mock = new MockAgentIdRegistry();
        vm.etch(REGISTRY_ADDR, address(mock).code);
        registry = MockAgentIdRegistry(REGISTRY_ADDR);

        registry.setBalance(alice, 1);
        registry.setBalance(bob, 1);
        registry.setBalance(carol, 1);
        registry.setBalance(erin, 1);
        registry.setBalance(dave, 0);
        registry.setHandle(alice, "alice");

        quests = new AgentQuests(address(this));
        vm.warp(T0);
    }

    // ------------------------------------------------------------------------
    // Constructor: explicit owner (factory deploys make msg.sender the factory)
    // ------------------------------------------------------------------------

    function test_Constructor_SetsOwner() public view {
        assertEq(quests.owner(), address(this));
    }

    function test_Constructor_RevertWhen_ZeroOwner() public {
        vm.expectRevert(AgentQuests.ZeroAddress.selector);
        new AgentQuests(address(0));
    }

    // ------------------------------------------------------------------------
    // Gating: no Agent ID, no actions
    // ------------------------------------------------------------------------

    function test_RevertWhen_NoAgentId() public {
        vm.startPrank(dave);
        vm.expectRevert(AgentQuests.NoAgentId.selector);
        quests.checkIn();
        vm.expectRevert(AgentQuests.NoAgentId.selector);
        quests.attest(bob, "hi");
        vm.expectRevert(AgentQuests.NoAgentId.selector);
        quests.claimQuest(0);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------------
    // checkIn: streaks, XP, same-day revert
    // ------------------------------------------------------------------------

    function test_CheckIn_FirstTime() public {
        vm.prank(alice);
        quests.checkIn();
        (uint32 streak, uint32 total, uint32 xp, uint32 level, uint32 recv, uint32 lastDay) =
            quests.profile(alice);
        assertEq(streak, 1);
        assertEq(total, 1);
        assertEq(xp, 10);
        assertEq(level, 1);
        assertEq(recv, 0);
        assertEq(lastDay, uint32(T0 / 1 days));
    }

    function test_CheckIn_SameDayReverts() public {
        vm.prank(alice);
        quests.checkIn();
        vm.prank(alice);
        vm.expectRevert(AgentQuests.AlreadyCheckedIn.selector);
        quests.checkIn();
    }

    function test_CheckIn_NextDayStreak() public {
        vm.prank(alice);
        quests.checkIn();
        vm.warp(T0 + 1 days);
        vm.prank(alice);
        quests.checkIn();
        (uint32 streak,, uint32 xp,,,) = _profileTuple(alice);
        assertEq(streak, 2);
        assertEq(xp, 20);
    }

    function test_CheckIn_StreakBonusAt7() public {
        // 7 consecutive daily check-ins: 6 x 10 XP + 12 XP on day 7 (bonus +2).
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(T0 + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        (uint32 streak,, uint32 xp,,,) = _profileTuple(alice);
        assertEq(streak, 7);
        assertEq(xp, 72);
    }

    function test_CheckIn_MissedDayResetsStreak() public {
        vm.prank(alice);
        quests.checkIn();
        vm.warp(T0 + 1 days);
        vm.prank(alice);
        quests.checkIn();
        // Skip a day: next check-in is 2 days later.
        vm.warp(T0 + 3 days);
        vm.prank(alice);
        quests.checkIn();
        (uint32 streak, uint32 total, uint32 xp,,,) = _profileTuple(alice);
        assertEq(streak, 1);
        assertEq(total, 3);
        assertEq(xp, 30);
    }

    function test_CheckIn_EmitsEvent() public {
        uint32 day = uint32(T0 / 1 days);
        vm.expectEmit(true, true, false, true);
        emit AgentQuests.CheckedIn(alice, day, 1, 10);
        vm.prank(alice);
        quests.checkIn();
    }

    // ------------------------------------------------------------------------
    // attest
    // ------------------------------------------------------------------------

    function test_Attest_Basic() public {
        vm.prank(alice);
        quests.attest(bob, "solid agent");
        (,, uint32 xpAlice,,,) = _profileTuple(alice);
        (,, uint32 xpBob,, uint32 recvBob,) = _profileTuple(bob);
        assertEq(xpAlice, 5);
        assertEq(xpBob, 2);
        assertEq(recvBob, 1);
    }

    function test_Attest_SelfReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentQuests.SelfAttest.selector);
        quests.attest(alice, "me");
    }

    function test_Attest_TargetWithoutAgentIdReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentQuests.NoAgentId.selector);
        quests.attest(dave, "no id");
    }

    function test_Attest_DailyLimit3() public {
        vm.startPrank(alice);
        quests.attest(bob, "1");
        quests.attest(carol, "2");
        quests.attest(erin, "3");
        // 4th attest the same day reverts even to a fresh target.
        address frank = makeAddr("frank");
        registry.setBalance(frank, 1);
        vm.expectRevert(AgentQuests.AttestLimitReached.selector);
        quests.attest(frank, "4");
        vm.stopPrank();
    }

    function test_Attest_Cooldown7Days() public {
        vm.prank(alice);
        quests.attest(bob, "day 0");
        // Day 6: still cooling down.
        vm.warp(T0 + 6 days);
        vm.prank(alice);
        vm.expectRevert(AgentQuests.AttestCooldown.selector);
        quests.attest(bob, "day 6");
        // Day 7: cooldown over.
        vm.warp(T0 + 7 days);
        vm.prank(alice);
        quests.attest(bob, "day 7");
        (, , , , uint32 recv,) = _profileTuple(bob);
        assertEq(recv, 2);
    }

    function test_Attest_ReasonTooLongReverts() public {
        string memory longReason = new string(141);
        vm.prank(alice);
        vm.expectRevert(AgentQuests.ReasonTooLong.selector);
        quests.attest(bob, longReason);
    }

    function test_Attest_Reason140Ok() public {
        string memory reason = new string(140);
        vm.prank(alice);
        quests.attest(bob, reason);
        (, , , , uint32 recv,) = _profileTuple(bob);
        assertEq(recv, 1);
    }

    function test_Attest_EmitsEvent() public {
        vm.expectEmit(true, true, false, true);
        emit AgentQuests.Attested(alice, bob, "solid agent");
        vm.prank(alice);
        quests.attest(bob, "solid agent");
    }

    // ------------------------------------------------------------------------
    // claimQuest
    // ------------------------------------------------------------------------

    function test_ClaimQuest_NotCompletedReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentQuests.QuestNotCompleted.selector);
        quests.claimQuest(0);
    }

    function test_ClaimQuest_NotFoundReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentQuests.QuestNotFound.selector);
        quests.claimQuest(99);
    }

    function test_ClaimQuest_Checkins5() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(T0 + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        assertTrue(quests.canClaim(alice, 0));
        vm.prank(alice);
        quests.claimQuest(0);
        (,, uint32 xp,,,) = _profileTuple(alice);
        assertEq(xp, 50 + 50); // 5 check-ins x 10 XP + 50 XP quest bonus
        // Second claim in the same week reverts.
        vm.prank(alice);
        vm.expectRevert(AgentQuests.QuestAlreadyClaimed.selector);
        quests.claimQuest(0);
    }

    function test_ClaimQuest_Attests3() public {
        vm.startPrank(alice);
        quests.attest(bob, "1");
        quests.attest(carol, "2");
        quests.attest(erin, "3");
        assertTrue(quests.canClaim(alice, 1));
        quests.claimQuest(1);
        vm.stopPrank();
        (,, uint32 xp,,,) = _profileTuple(alice);
        assertEq(xp, 15 + 50); // 3 attests x 5 XP + 50 XP quest bonus
    }

    function test_ClaimQuest_Streak7() public {
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(T0 + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        assertTrue(quests.canClaim(alice, 2));
        vm.prank(alice);
        quests.claimQuest(2);
        (,, uint32 xp,,,) = _profileTuple(alice);
        assertEq(xp, 72 + 100); // 7 check-ins (72 XP) + 100 XP quest bonus
    }

    function test_ClaimQuest_NextWeekAgain() public {
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(T0 + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        vm.prank(alice);
        quests.claimQuest(0);
        // Next week: 5 more check-ins, claim again.
        for (uint256 i = 0; i < 5; i++) {
            vm.warp(T0 + 7 days + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        assertTrue(quests.canClaim(alice, 0));
        vm.prank(alice);
        quests.claimQuest(0);
        (,, uint32 xp,,,) = _profileTuple(alice);
        // Week 1: 50 check-in + 50 quest. Week 2: streak reset (days 5-6 missed),
        // so 5 check-ins x 10 XP = 50 + 50 quest.
        assertEq(xp, 100 + 50 + 50);
    }

    // ------------------------------------------------------------------------
    // XP / level math
    // ------------------------------------------------------------------------

    function test_LevelMath() public view {
        assertEq(quests.levelOf(0), 1);
        assertEq(quests.levelOf(99), 1);
        assertEq(quests.levelOf(100), 2);
        assertEq(quests.levelOf(399), 2);
        assertEq(quests.levelOf(400), 3);
        assertEq(quests.levelOf(900), 4);
        assertEq(quests.levelOf(10000), 11);
        assertEq(quests.levelOf(1000000), 101);
    }

    function test_LevelUpOnQuestClaim() public {
        // 7 check-ins = 72 XP (level 1). Claim Q1 (+50) -> 122 XP (level 2).
        for (uint256 i = 0; i < 7; i++) {
            vm.warp(T0 + i * 1 days);
            vm.prank(alice);
            quests.checkIn();
        }
        vm.expectEmit(true, false, false, true);
        emit AgentQuests.LevelUp(alice, 2);
        vm.prank(alice);
        quests.claimQuest(0);
        (,,, uint32 level,,) = _profileTuple(alice);
        assertEq(level, 2);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    function test_ProfileView() public {
        vm.prank(alice);
        quests.checkIn();
        vm.prank(bob);
        quests.attest(alice, "great");
        (uint32 streak, uint32 total, uint32 xp, uint32 level, uint32 recv, uint32 lastDay) =
            quests.profile(alice);
        assertEq(streak, 1);
        assertEq(total, 1);
        assertEq(xp, 12); // 10 check-in + 2 received attest
        assertEq(level, 1);
        assertEq(recv, 1);
        assertEq(lastDay, uint32(T0 / 1 days));
    }

    function test_HandleOfPassthrough() public view {
        assertEq(quests.handleOf(alice), "alice");
        assertEq(quests.handleOf(bob), "");
    }

    function test_GetQuestAndCount() public view {
        assertEq(quests.questCount(), 3);
        (uint8 kind, uint32 threshold, uint32 xpReward, bool active) = quests.getQuest(0);
        assertEq(kind, 1);
        assertEq(threshold, 5);
        assertEq(xpReward, 50);
        assertTrue(active);
        (kind, threshold, xpReward, active) = quests.getQuest(2);
        assertEq(kind, 3);
        assertEq(threshold, 7);
        assertEq(xpReward, 100);
        assertTrue(active);
    }

    function test_CanClaimFalseCases() public view {
        assertFalse(quests.canClaim(alice, 99)); // not found
        assertFalse(quests.canClaim(alice, 0)); // not completed
    }

    // ------------------------------------------------------------------------
    // Owner administration
    // ------------------------------------------------------------------------

    function test_Owner_AddQuest() public {
        quests.addQuest(1, 2, 25);
        assertEq(quests.questCount(), 4);
        (uint8 kind, uint32 threshold, uint32 xpReward, bool active) = quests.getQuest(3);
        assertEq(kind, 1);
        assertEq(threshold, 2);
        assertEq(xpReward, 25);
        assertTrue(active);
    }

    function test_Owner_AddQuestInvalidReverts() public {
        vm.expectRevert(AgentQuests.InvalidQuest.selector);
        quests.addQuest(9, 2, 25);
        vm.expectRevert(AgentQuests.InvalidQuest.selector);
        quests.addQuest(1, 0, 25);
    }

    function test_Owner_NonOwnerReverts() public {
        vm.prank(alice);
        vm.expectRevert(AgentQuests.NotOwner.selector);
        quests.addQuest(1, 2, 25);
        vm.prank(alice);
        vm.expectRevert(AgentQuests.NotOwner.selector);
        quests.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(AgentQuests.NotOwner.selector);
        quests.transferOwnership(alice);
    }

    function test_Owner_DeactivateQuest() public {
        quests.setQuestActive(0, false);
        assertFalse(quests.canClaim(alice, 0));
        vm.prank(alice);
        vm.expectRevert(AgentQuests.QuestInactive.selector);
        quests.claimQuest(0);
    }

    function test_PausedBlocksActions() public {
        quests.setPaused(true);
        vm.prank(alice);
        vm.expectRevert(AgentQuests.Paused.selector);
        quests.checkIn();
        vm.prank(alice);
        vm.expectRevert(AgentQuests.Paused.selector);
        quests.attest(bob, "hi");
        vm.prank(alice);
        vm.expectRevert(AgentQuests.Paused.selector);
        quests.claimQuest(0);
        // Unpause restores.
        quests.setPaused(false);
        vm.prank(alice);
        quests.checkIn();
    }

    function test_Owner_Transfer() public {
        quests.transferOwnership(alice);
        assertEq(quests.owner(), alice);
        vm.prank(alice);
        quests.setPaused(true);
        assertTrue(quests.paused());
    }

    // ------------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------------

    function _profileTuple(address user)
        internal
        view
        returns (uint32 streak, uint32 total, uint32 xp, uint32 level, uint32 recv, uint32 lastDay)
    {
        (streak, total, xp, level, recv, lastDay) = quests.profile(user);
    }
}
