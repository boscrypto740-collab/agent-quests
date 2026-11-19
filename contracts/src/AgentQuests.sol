// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title AgentQuests — daily on-chain quests for Agent ID (.ai) holders on BNB Chain
/// @notice Independent hackathon entry for the Agent ID Hackathon (Binance Wallet x BNB Chain).
///         Not affiliated with Binance or SPACE ID.
/// @dev Gas-only engagement layer: NO payable functions, NO token, NO fees, NO owner
///      withdrawals. The owner can only manage the quest list and pause in an emergency.
///
///      Agent ID gating uses the SPACE ID Agent ID registry (`balanceOf > 0`), the same
///      on-chain pattern used by UNITS, Coracle and Oathbots. The registry is soulbound
///      (transfers revert), so an Agent ID cannot be borrowed to farm quests.
///
///      XP ECONOMY (documented, no monetary value):
///        - Daily check-in: 10 XP + streak bonus 2 XP per full 7-day streak, capped at +10
///          (so 10 XP at streak 1-6, 12 XP at streak 7-13, ..., max 20 XP at streak 35+).
///        - Attest: giver +5 XP, receiver +2 XP.
///        - Weekly quests (see constructor): Q1 +50 XP, Q2 +50 XP, Q3 +100 XP.
///      LEVEL: level = floor(sqrt(xp / 100)) + 1. Level 1 at 0 XP, 2 at 100 XP,
///      3 at 400 XP, 4 at 900 XP, 11 at 10_000 XP.
///
///      TIME: a "day" is a UTC day (block.timestamp / 1 days). A "week" is a Unix week
///      (block.timestamp / 1 weeks), starting Thursday 00:00 UTC. Quest progress and
///      claims reset every Unix week.
interface IAgentIdRegistry {
    function balanceOf(address account) external view returns (uint256);
}

contract AgentQuests {
    // ------------------------------------------------------------------------
    // Constants
    // ------------------------------------------------------------------------

    /// @notice SPACE ID Agent ID registry on BNB Smart Chain (chain id 56).
    address public constant AGENT_ID_REGISTRY = 0x60B9262456dE011F7d15a54CdD8c48bAaa8B022F;

    uint32 public constant XP_CHECKIN_BASE = 10;
    uint32 public constant STREAK_BONUS_PER_WEEK = 2;
    uint32 public constant STREAK_BONUS_CAP = 10;
    uint32 public constant XP_ATTEST_GIVER = 5;
    uint32 public constant XP_ATTEST_RECEIVER = 2;

    uint8 public constant MAX_ATTESTS_PER_DAY = 3;
    uint32 public constant ATTEST_COOLDOWN_DAYS = 7;
    uint256 public constant MAX_REASON_BYTES = 140;

    // Quest kinds
    uint8 public constant KIND_CHECKINS_IN_WEEK = 1;
    uint8 public constant KIND_DISTINCT_ATTESTS_IN_WEEK = 2;
    uint8 public constant KIND_STREAK_AT_LEAST = 3;

    // ------------------------------------------------------------------------
    // Types
    // ------------------------------------------------------------------------

    /// @dev Packed into a single storage slot (5 x uint32 = 160 bits).
    struct User {
        uint32 streak;
        uint32 totalCheckIns;
        uint32 lastCheckInDay;
        uint32 xp;
        uint32 attestationsReceived;
    }

    struct Quest {
        uint8 kind;
        uint32 threshold;
        uint32 xpReward;
        bool active;
    }

    // ------------------------------------------------------------------------
    // Storage
    // ------------------------------------------------------------------------

    address public owner;
    bool public paused;

    mapping(address => User) public users;
    mapping(address => mapping(uint32 => uint8)) public checkInsInWeek;
    mapping(address => mapping(uint32 => uint8)) public distinctAttestsInWeek;
    mapping(address => mapping(uint32 => mapping(address => bool))) public attestedInWeek;
    mapping(address => mapping(uint32 => uint8)) public attestsPerDay;
    mapping(address => mapping(address => uint32)) public lastAttestDay;
    mapping(address => mapping(uint32 => mapping(uint8 => bool))) public questClaimed;
    Quest[] public quests;

    // ------------------------------------------------------------------------
    // Events
    // ------------------------------------------------------------------------

    event CheckedIn(address indexed user, uint32 indexed day, uint32 streak, uint32 xpEarned);
    event Attested(address indexed from, address indexed to, string reason);
    event QuestClaimed(address indexed user, uint8 indexed questId, uint32 indexed week, uint32 xpEarned);
    event LevelUp(address indexed user, uint32 newLevel);
    event QuestAdded(uint8 indexed questId, uint8 kind, uint32 threshold, uint32 xpReward);
    event QuestActiveSet(uint8 indexed questId, bool active);
    event PausedSet(bool paused);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // ------------------------------------------------------------------------
    // Errors
    // ------------------------------------------------------------------------

    error NoAgentId();
    error AlreadyCheckedIn();
    error SelfAttest();
    error AttestLimitReached();
    error AttestCooldown();
    error ReasonTooLong();
    error QuestNotFound();
    error QuestInactive();
    error QuestNotCompleted();
    error QuestAlreadyClaimed();
    error InvalidQuest();
    error NotOwner();
    error Paused();
    error ZeroAddress();

    // ------------------------------------------------------------------------
    // Modifiers
    // ------------------------------------------------------------------------

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier whenNotPaused() {
        if (paused) revert Paused();
        _;
    }

    modifier onlyAgentId() {
        if (!_hasAgentId(msg.sender)) revert NoAgentId();
        _;
    }

    // ------------------------------------------------------------------------
    // Constructor
    // ------------------------------------------------------------------------

    /// @notice Deploy with an explicit owner.
    /// @dev `owner` is NOT `msg.sender`: this contract is deployed via the
    ///      Arachnid CREATE2 factory (0x4e59b44847b379578588920cA78FbF26c0B4956C),
    ///      where the factory — not the deployer — is `msg.sender` inside the
    ///      constructor. Taking `initialOwner` as a parameter keeps the real
    ///      owner in control (same fix as AVSC v3 after v2 locked ownership
    ///      to the factory).
    constructor(address initialOwner) {
        if (initialOwner == address(0)) revert ZeroAddress();
        owner = initialOwner;
        // Q1: check in 5 days within the current week — 50 XP.
        quests.push(Quest({kind: KIND_CHECKINS_IN_WEEK, threshold: 5, xpReward: 50, active: true}));
        // Q2: attest 3 different agents within the current week — 50 XP.
        quests.push(Quest({kind: KIND_DISTINCT_ATTESTS_IN_WEEK, threshold: 3, xpReward: 50, active: true}));
        // Q3: reach a 7-day check-in streak — 100 XP.
        quests.push(Quest({kind: KIND_STREAK_AT_LEAST, threshold: 7, xpReward: 100, active: true}));
    }

    // ------------------------------------------------------------------------
    // Core actions
    // ------------------------------------------------------------------------

    /// @notice Check in for the current UTC day. Builds (or resets) the streak.
    function checkIn() external onlyAgentId whenNotPaused {
        uint32 day = _currentDay();
        uint32 week = _currentWeek();
        User storage u = users[msg.sender];

        if (u.lastCheckInDay == day) revert AlreadyCheckedIn();
        if (u.lastCheckInDay + 1 == day) {
            u.streak += 1;
        } else {
            u.streak = 1;
        }
        u.lastCheckInDay = day;
        u.totalCheckIns += 1;
        checkInsInWeek[msg.sender][week] += 1;

        uint32 bonus = STREAK_BONUS_PER_WEEK * (u.streak / 7);
        if (bonus > STREAK_BONUS_CAP) bonus = STREAK_BONUS_CAP;
        uint32 xpEarned = XP_CHECKIN_BASE + bonus;
        _addXp(msg.sender, xpEarned);

        emit CheckedIn(msg.sender, day, u.streak, xpEarned);
    }

    /// @notice Vouch for another Agent ID holder. Builds the agent trust graph.
    /// @param agent The Agent ID holder to attest. Must hold an Agent ID.
    /// @param reason Short note (max 140 bytes) explaining the attestation.
    function attest(address agent, string calldata reason) external onlyAgentId whenNotPaused {
        if (agent == msg.sender) revert SelfAttest();
        if (!_hasAgentId(agent)) revert NoAgentId();
        if (bytes(reason).length > MAX_REASON_BYTES) revert ReasonTooLong();

        uint32 day = _currentDay();
        if (attestsPerDay[msg.sender][day] >= MAX_ATTESTS_PER_DAY) revert AttestLimitReached();
        uint32 lastDay = lastAttestDay[msg.sender][agent];
        if (lastDay != 0 && day < lastDay + ATTEST_COOLDOWN_DAYS) revert AttestCooldown();

        attestsPerDay[msg.sender][day] += 1;
        lastAttestDay[msg.sender][agent] = day;
        users[agent].attestationsReceived += 1;

        uint32 week = _currentWeek();
        if (!attestedInWeek[msg.sender][week][agent]) {
            attestedInWeek[msg.sender][week][agent] = true;
            distinctAttestsInWeek[msg.sender][week] += 1;
        }

        _addXp(msg.sender, XP_ATTEST_GIVER);
        _addXp(agent, XP_ATTEST_RECEIVER);

        emit Attested(msg.sender, agent, reason);
    }

    /// @notice Claim a completed weekly quest for bonus XP. One claim per quest per week.
    function claimQuest(uint8 questId) external onlyAgentId whenNotPaused {
        if (questId >= quests.length) revert QuestNotFound();
        Quest storage q = quests[questId];
        if (!q.active) revert QuestInactive();

        uint32 week = _currentWeek();
        if (questClaimed[msg.sender][week][questId]) revert QuestAlreadyClaimed();
        if (!_questCompleted(msg.sender, q, week)) revert QuestNotCompleted();

        questClaimed[msg.sender][week][questId] = true;
        _addXp(msg.sender, q.xpReward);

        emit QuestClaimed(msg.sender, questId, week, q.xpReward);
    }

    // ------------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------------

    /// @notice Full profile of a user. Level is derived from XP, not stored.
    function profile(address user)
        external
        view
        returns (
            uint32 streak,
            uint32 totalCheckIns,
            uint32 xp,
            uint32 level,
            uint32 attestationsReceived,
            uint32 lastCheckInDay
        )
    {
        User storage u = users[user];
        return (
            u.streak,
            u.totalCheckIns,
            u.xp,
            levelOf(u.xp),
            u.attestationsReceived,
            u.lastCheckInDay
        );
    }

    /// @notice Level derived from XP: floor(sqrt(xp / 100)) + 1.
    function levelOf(uint32 xp) public pure returns (uint32) {
        return _sqrt(xp / 100) + 1;
    }

    /// @notice Whether `user` can claim `questId` right now (ignores Agent ID holding).
    function canClaim(address user, uint8 questId) external view returns (bool) {
        if (questId >= quests.length) return false;
        Quest storage q = quests[questId];
        if (!q.active) return false;
        uint32 week = _currentWeek();
        if (questClaimed[user][week][questId]) return false;
        return _questCompleted(user, q, week);
    }

    function questCount() external view returns (uint256) {
        return quests.length;
    }

    function getQuest(uint8 questId)
        external
        view
        returns (uint8 kind, uint32 threshold, uint32 xpReward, bool active)
    {
        if (questId >= quests.length) revert QuestNotFound();
        Quest storage q = quests[questId];
        return (q.kind, q.threshold, q.xpReward, q.active);
    }

    /// @notice The .ai handle of an address, read from the registry (empty if none).
    /// @dev Provided as a convenience for frontends; the contract itself never
    ///      depends on name resolution. Kept as a thin passthrough.
    function handleOf(address user) external view returns (string memory) {
        return IAgentIdRegistryExtended(AGENT_ID_REGISTRY).handleOf(user);
    }

    // ------------------------------------------------------------------------
    // Owner administration (no funds involved — the contract never holds value)
    // ------------------------------------------------------------------------

    function addQuest(uint8 kind, uint32 threshold, uint32 xpReward) external onlyOwner {
        if (
            kind != KIND_CHECKINS_IN_WEEK && kind != KIND_DISTINCT_ATTESTS_IN_WEEK
                && kind != KIND_STREAK_AT_LEAST
        ) revert InvalidQuest();
        if (threshold == 0) revert InvalidQuest();
        quests.push(Quest({kind: kind, threshold: threshold, xpReward: xpReward, active: true}));
        emit QuestAdded(uint8(quests.length - 1), kind, threshold, xpReward);
    }

    function setQuestActive(uint8 questId, bool active) external onlyOwner {
        if (questId >= quests.length) revert QuestNotFound();
        quests[questId].active = active;
        emit QuestActiveSet(questId, active);
    }

    function setPaused(bool p) external onlyOwner {
        paused = p;
        emit PausedSet(p);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // ------------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------------

    function _hasAgentId(address account) internal view returns (bool) {
        return IAgentIdRegistry(AGENT_ID_REGISTRY).balanceOf(account) > 0;
    }

    function _currentDay() internal view returns (uint32) {
        // casting to 'uint32' is safe because block.timestamp / 1 days will not
        // exceed 2^32 for ~11 million years
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(block.timestamp / 1 days);
    }

    function _currentWeek() internal view returns (uint32) {
        // casting to 'uint32' is safe because block.timestamp / 1 weeks will not
        // exceed 2^32 for ~81 million years
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint32(block.timestamp / 1 weeks);
    }

    function _questCompleted(address user, Quest storage q, uint32 week) internal view returns (bool) {
        if (q.kind == KIND_CHECKINS_IN_WEEK) {
            return checkInsInWeek[user][week] >= q.threshold;
        } else if (q.kind == KIND_DISTINCT_ATTESTS_IN_WEEK) {
            return distinctAttestsInWeek[user][week] >= q.threshold;
        } else if (q.kind == KIND_STREAK_AT_LEAST) {
            return users[user].streak >= q.threshold;
        }
        return false;
    }

    function _addXp(address user, uint32 amount) internal {
        User storage u = users[user];
        uint32 oldLevel = levelOf(u.xp);
        u.xp += amount;
        uint32 newLevel = levelOf(u.xp);
        if (newLevel > oldLevel) emit LevelUp(user, newLevel);
    }

    /// @dev Integer square root (Babylonian method). Returns floor(sqrt(x)).
    function _sqrt(uint32 x) internal pure returns (uint32) {
        if (x == 0) return 0;
        uint32 z = (x + 1) / 2;
        uint32 y = x;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
        return y;
    }
}

/// @dev Extended registry interface — only used by the `handleOf` view helper.
///      The core gating logic uses only `balanceOf` (see IAgentIdRegistry).
interface IAgentIdRegistryExtended {
    function handleOf(address account) external view returns (string memory);
}
