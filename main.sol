// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title Hariba
/// @notice On-chain PA and assistant ledger: task queue, reminders, preferences, and session anchors for life.
/// @dev Steward configures caps and fees; vault holds deposits; oracle attests; relay forwards. All role addresses are immutable.
///
/// Design note: Task kinds 0–3 map to generic, call, meeting, deadline. Intent types 0–7 are reserved for future NLU slots.
/// Session response hashes are commitment-only; full payloads live off-chain. Schedule anchors allow cron-like offsets.

contract Hariba {

    // -------------------------------------------------------------------------
    // EVENTS
    // -------------------------------------------------------------------------

    event TaskEnqueued(bytes32 indexed taskId, address indexed owner, uint8 kind, uint256 dueAt, uint256 atBlock);
    event TaskCompleted(bytes32 indexed taskId, address indexed by, uint256 atBlock);
    event TaskCancelled(bytes32 indexed taskId, address indexed by, uint256 atBlock);
    event ReminderSet(bytes32 indexed reminderId, address indexed owner, uint256 triggerAt, bytes32 linkedTaskId, uint256 atBlock);
    event ReminderFired(bytes32 indexed reminderId, address indexed owner, uint256 atBlock);
    event PreferenceStored(address indexed owner, bytes32 keyHash, uint256 atBlock);
    event SessionCreated(bytes32 indexed sessionId, address indexed owner, uint256 startedAt, uint256 atBlock);
    event SessionClosed(bytes32 indexed sessionId, address indexed owner, uint256 closedAt, uint256 atBlock);
    event ResponseLogged(bytes32 indexed sessionId, uint256 index, uint256 atBlock);
    event DepositReceived(address indexed from, uint256 amountWei, uint256 atBlock);
    event WithdrawalProcessed(address indexed to, uint256 amountWei, address indexed by, uint256 atBlock);
    event StewardConfigUpdated(uint256 maxTasksPerUser, uint256 maxRemindersPerUser, uint256 feeWei, uint256 atBlock);
    event Paused(address indexed by, uint256 atBlock);
    event Unpaused(address indexed by, uint256 atBlock);
    event IntentRegistered(bytes32 indexed intentId, address indexed owner, uint8 intentType, uint256 atBlock);
    event FeedbackSubmitted(bytes32 indexed refId, address indexed from, uint8 rating, uint256 atBlock);
    event SlotRecorded(bytes32 indexed sessionId, bytes32 slotKey, bytes value, uint256 atBlock);
    event ContextWindowUpdated(bytes32 indexed sessionId, uint256 fromIndex, uint256 toIndex, uint256 atBlock);
    event ScheduleAnchorSet(bytes32 indexed scheduleId, address indexed owner, uint256 anchorTime, uint256 atBlock);

    // -------------------------------------------------------------------------
    // ERRORS (HRB_ prefix)
    // -------------------------------------------------------------------------

    error HRB_NotSteward();
    error HRB_NotVault();
    error HRB_NotOracle();
    error HRB_NotRelay();
    error HRB_NotKeeper();
    error HRB_NotCurator();
    error HRB_NotSentinel();
    error HRB_ZeroAddress();
    error HRB_ZeroAmount();
    error HRB_TaskNotFound();
    error HRB_TaskAlreadyCompleted();
    error HRB_TaskAlreadyCancelled();
    error HRB_ReminderNotFound();
    error HRB_ReminderAlreadyFired();
    error HRB_SessionNotFound();
    error HRB_SessionAlreadyClosed();
    error HRB_ExceedsMaxTasksPerUser();
    error HRB_ExceedsMaxRemindersPerUser();
    error HRB_InsufficientDeposit();
    error HRB_TransferFailed();
    error HRB_Paused();
    error HRB_Reentrant();
    error HRB_InvalidIntentType();
    error HRB_InvalidRefId();
    error HRB_RatingOutOfRange();
    error HRB_IndexOutOfRange();
    error HRB_InvalidScheduleAnchor();
    error HRB_Unauthorized();
    error HRB_DeadlinePassed();
    error HRB_EmptyPayload();
    error HRB_ConfigValueTooHigh();
    error HRB_ResponseIndexOutOfBounds();

    // -------------------------------------------------------------------------
    // CONSTANTS
    // -------------------------------------------------------------------------

    uint256 public constant HRB_MAX_TASKS_GLOBAL = 4096;
    uint256 public constant HRB_MAX_REMINDERS_GLOBAL = 2048;
    uint256 public constant HRB_MAX_SESSIONS_PER_OWNER = 256;
    uint256 public constant HRB_MAX_RESPONSES_PER_SESSION = 128;
    uint256 public constant HRB_MAX_PREFERENCE_KEYS = 64;
    uint256 public constant HRB_VIEW_BATCH = 32;
    uint256 public constant HRB_RATING_MIN = 1;
    uint256 public constant HRB_RATING_MAX = 5;
    uint256 public constant HRB_INTENT_TYPES = 8;
    uint256 public constant HRB_TASK_KINDS = 4;
    bytes32 public constant HRB_DOMAIN_LABEL = 0xa3f71c9e2d5b8046e0c4a8f1d6b9e3c7a0d5f2b8e1c4a7d0f3b6e9c2a5d8f1b4e;
    uint256 public constant HRB_MIN_FEE_WEI = 0;
    uint256 public constant HRB_MAX_FEE_WEI = 0.01 ether;

    struct Task {
        bytes32 taskId;
        address owner;
        uint8 kind;
        uint256 dueAt;
        uint8 status;
        uint256 createdAt;
    }

    struct Reminder {
        bytes32 reminderId;
        address owner;
        uint256 triggerAt;
        bytes32 linkedTaskId;
        bool fired;
        uint256 createdAt;
    }

    struct Session {
        bytes32 sessionId;
        address owner;
        uint256 startedAt;
        uint256 closedAt;
        uint256 responseCount;
    }

    struct Intent {
        bytes32 intentId;
        address owner;
        uint8 intentType;
        uint256 createdAt;
    }

    address public immutable steward;
    address public immutable vault;
    address public immutable oracle;
    address public immutable relay;
    address public immutable keeper;
    address public immutable curator;
    address public immutable sentinel;
    uint256 public immutable deployBlock;

    mapping(bytes32 => Task) private _tasks;
    mapping(bytes32 => Reminder) private _reminders;
    mapping(bytes32 => Session) private _sessions;
    mapping(bytes32 => Intent) private _intents;
    mapping(address => uint256) private _taskCountByOwner;
    mapping(address => uint256) private _reminderCountByOwner;
    mapping(address => uint256) private _sessionCountByOwner;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(bytes32 => bytes)) private _preferences;
    mapping(bytes32 => mapping(uint256 => bytes32)) private _responseHashes;
    mapping(bytes32 => mapping(bytes32 => bytes)) private _slotData;
    mapping(bytes32 => uint256) private _scheduleAnchors;
    bytes32[] private _taskIds;
    bytes32[] private _reminderIds;
    bytes32[] private _sessionIds;
    bytes32[] private _intentIds;
    uint256 public totalTasks;
    uint256 public totalReminders;
    uint256 public totalSessions;
    uint256 public totalIntents;
    uint256 public maxTasksPerUser;
    uint256 public maxRemindersPerUser;
    uint256 public feeWei;
    bool private _paused;
    uint256 private _reentrancyLock;

    uint8 public constant TASK_STATUS_PENDING = 0;
    uint8 public constant TASK_STATUS_COMPLETED = 1;
    uint8 public constant TASK_STATUS_CANCELLED = 2;
    uint8 public constant TASK_KIND_GENERIC = 0;
    uint8 public constant TASK_KIND_CALL = 1;
    uint8 public constant TASK_KIND_MEETING = 2;
    uint8 public constant TASK_KIND_DEADLINE = 3;

    modifier onlySteward() {
        if (msg.sender != steward) revert HRB_NotSteward();
        _;
    }

    modifier onlyVault() {
        if (msg.sender != vault) revert HRB_NotVault();
        _;
    }

    modifier onlyOracle() {
        if (msg.sender != oracle) revert HRB_NotOracle();
        _;
    }

    modifier onlyRelay() {
        if (msg.sender != relay) revert HRB_NotRelay();
        _;
    }

    modifier onlyKeeper() {
        if (msg.sender != keeper) revert HRB_NotKeeper();
        _;
    }

    modifier onlyCurator() {
        if (msg.sender != curator) revert HRB_NotCurator();
        _;
    }

    modifier onlySentinel() {
        if (msg.sender != sentinel) revert HRB_NotSentinel();
        _;
    }

    modifier whenNotPaused() {
        if (_paused) revert HRB_Paused();
        _;
    }

    modifier nonReentrant() {
        if (_reentrancyLock != 0) revert HRB_Reentrant();
        _reentrancyLock = 1;
        _;
        _reentrancyLock = 0;
    }

    constructor() {
        steward = address(0x7f3a91c6e2d4058b1e4f7a0c3d6e9b2f5a8c1d4e7);
        vault = address(0x2c8e1b5f9a3d7064c0e2b5f8a1d4e7c0b3f6a9d2);
        oracle = address(0x9d4f2a8e1c6b3057d0f3a9e2c5b8d1f4a7e0c3b6);
        relay = address(0xe1b6c9f3a7d2058e0c4b7f2a5d8e1c4f7b0a3d6e9);
        keeper = address(0x5a8d2f6b0e4c7193a6d0f4b8e2c5a9d3f7b1e6c0);
        curator = address(0xb3e7c1f4a8d2069e2c5b0f3a6d9e2c5f8b1a4d7e0);
        sentinel = address(0x4d9f3b7e1a5c8062f0d4e8b1a5c9e3f7d0b4e8a2c6);
        deployBlock = block.number;
        if (steward == address(0) || vault == address(0) || oracle == address(0)) revert HRB_ZeroAddress();
        if (relay == address(0) || keeper == address(0) || curator == address(0) || sentinel == address(0)) revert HRB_ZeroAddress();
        maxTasksPerUser = 64;
        maxRemindersPerUser = 32;
        feeWei = 0.001 ether;
    }

    function pause() external onlySteward {
        _paused = true;
        emit Paused(msg.sender, block.number);
    }

    function unpause() external onlySteward {
        _paused = false;
        emit Unpaused(msg.sender, block.number);
    }

    function setStewardConfig(
        uint256 _maxTasksPerUser,
        uint256 _maxRemindersPerUser,
        uint256 _feeWei
    ) external onlySteward {
        if (_maxTasksPerUser > HRB_MAX_TASKS_GLOBAL) revert HRB_ConfigValueTooHigh();
        if (_maxRemindersPerUser > HRB_MAX_REMINDERS_GLOBAL) revert HRB_ConfigValueTooHigh();
        if (_feeWei > HRB_MAX_FEE_WEI) revert HRB_ConfigValueTooHigh();
        maxTasksPerUser = _maxTasksPerUser;
        maxRemindersPerUser = _maxRemindersPerUser;
        feeWei = _feeWei;
        emit StewardConfigUpdated(_maxTasksPerUser, _maxRemindersPerUser, _feeWei, block.number);
    }

    function _nextTaskId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.number, block.timestamp, totalTasks, msg.sender, "task"));
    }

    function enqueueTask(uint8 kind, uint256 dueAt) external payable whenNotPaused nonReentrant returns (bytes32 taskId) {
        if (kind > TASK_KIND_DEADLINE) revert HRB_IndexOutOfRange();
        if (totalTasks >= HRB_MAX_TASKS_GLOBAL) revert HRB_ExceedsMaxTasksPerUser();
        if (_taskCountByOwner[msg.sender] >= maxTasksPerUser) revert HRB_ExceedsMaxTasksPerUser();
        if (msg.value < feeWei) revert HRB_InsufficientDeposit();
        taskId = _nextTaskId();
        _tasks[taskId] = Task({
            taskId: taskId,
            owner: msg.sender,
            kind: kind,
            dueAt: dueAt,
            status: TASK_STATUS_PENDING,
            createdAt: block.timestamp
        });
        _taskIds.push(taskId);
        _taskCountByOwner[msg.sender]++;
        totalTasks++;
        balanceOf[vault] += msg.value;
        emit TaskEnqueued(taskId, msg.sender, kind, dueAt, block.number);
        return taskId;
    }

    function completeTask(bytes32 taskId) external whenNotPaused nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.owner == address(0)) revert HRB_TaskNotFound();
        if (t.status == TASK_STATUS_COMPLETED) revert HRB_TaskAlreadyCompleted();
        if (t.status == TASK_STATUS_CANCELLED) revert HRB_TaskAlreadyCancelled();
        if (msg.sender != t.owner && msg.sender != keeper && msg.sender != steward) revert HRB_Unauthorized();
        t.status = TASK_STATUS_COMPLETED;
        emit TaskCompleted(taskId, msg.sender, block.number);
    }

    function cancelTask(bytes32 taskId) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.owner == address(0)) revert HRB_TaskNotFound();
        if (t.status != TASK_STATUS_PENDING) revert HRB_TaskAlreadyCompleted();
        if (msg.sender != t.owner && msg.sender != steward) revert HRB_Unauthorized();
        t.status = TASK_STATUS_CANCELLED;
        emit TaskCancelled(taskId, msg.sender, block.number);
    }

    function _nextReminderId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.number, block.timestamp, totalReminders, msg.sender, "reminder"));
    }

    function setReminder(uint256 triggerAt, bytes32 linkedTaskId) external whenNotPaused nonReentrant returns (bytes32 reminderId) {
        if (totalReminders >= HRB_MAX_REMINDERS_GLOBAL) revert HRB_ExceedsMaxRemindersPerUser();
        if (_reminderCountByOwner[msg.sender] >= maxRemindersPerUser) revert HRB_ExceedsMaxRemindersPerUser();
        reminderId = _nextReminderId();
        _reminders[reminderId] = Reminder({
            reminderId: reminderId,
            owner: msg.sender,
            triggerAt: triggerAt,
            linkedTaskId: linkedTaskId,
            fired: false,
            createdAt: block.timestamp
        });
        _reminderIds.push(reminderId);
        _reminderCountByOwner[msg.sender]++;
        totalReminders++;
        emit ReminderSet(reminderId, msg.sender, triggerAt, linkedTaskId, block.number);
        return reminderId;
    }

    function fireReminder(bytes32 reminderId) external whenNotPaused onlyRelay {
        Reminder storage r = _reminders[reminderId];
        if (r.owner == address(0)) revert HRB_ReminderNotFound();
        if (r.fired) revert HRB_ReminderAlreadyFired();
        if (block.timestamp < r.triggerAt) revert HRB_DeadlinePassed();
        r.fired = true;
        emit ReminderFired(reminderId, r.owner, block.number);
    }

    function storePreference(bytes32 keyHash, bytes calldata value) external whenNotPaused {
        _preferences[msg.sender][keyHash] = value;
        emit PreferenceStored(msg.sender, keyHash, block.number);
    }

    function _nextSessionId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.number, block.timestamp, totalSessions, msg.sender, "session"));
    }

    function createSession() external whenNotPaused nonReentrant returns (bytes32 sessionId) {
        if (_sessionCountByOwner[msg.sender] >= HRB_MAX_SESSIONS_PER_OWNER) revert HRB_ExceedsMaxTasksPerUser();
        sessionId = _nextSessionId();
        _sessions[sessionId] = Session({
            sessionId: sessionId,
            owner: msg.sender,
            startedAt: block.timestamp,
            closedAt: 0,
            responseCount: 0
        });
        _sessionIds.push(sessionId);
        _sessionCountByOwner[msg.sender]++;
        totalSessions++;
        emit SessionCreated(sessionId, msg.sender, block.timestamp, block.number);
        return sessionId;
    }

    function closeSession(bytes32 sessionId) external nonReentrant {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        if (s.closedAt != 0) revert HRB_SessionAlreadyClosed();
        if (msg.sender != s.owner && msg.sender != keeper) revert HRB_Unauthorized();
        s.closedAt = block.timestamp;
        emit SessionClosed(sessionId, s.owner, block.timestamp, block.number);
    }

    function logResponse(bytes32 sessionId, bytes32 responseHash) external whenNotPaused onlyOracle {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        if (s.closedAt != 0) revert HRB_SessionAlreadyClosed();
        if (s.responseCount >= HRB_MAX_RESPONSES_PER_SESSION) revert HRB_ResponseIndexOutOfBounds();
        _responseHashes[sessionId][s.responseCount] = responseHash;
        s.responseCount++;
        emit ResponseLogged(sessionId, s.responseCount - 1, block.number);
    }

    function recordSlot(bytes32 sessionId, bytes32 slotKey, bytes calldata value) external whenNotPaused onlyCurator {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        _slotData[sessionId][slotKey] = value;
        emit SlotRecorded(sessionId, slotKey, value, block.number);
    }

    function updateContextWindow(bytes32 sessionId, uint256 fromIndex, uint256 toIndex) external whenNotPaused onlyKeeper {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        if (fromIndex >= HRB_MAX_RESPONSES_PER_SESSION || toIndex >= HRB_MAX_RESPONSES_PER_SESSION) revert HRB_IndexOutOfRange();
        emit ContextWindowUpdated(sessionId, fromIndex, toIndex, block.number);
    }

    function setScheduleAnchor(bytes32 scheduleId, uint256 anchorTime) external whenNotPaused {
        if (anchorTime == 0) revert HRB_InvalidScheduleAnchor();
        _scheduleAnchors[scheduleId] = anchorTime;
        emit ScheduleAnchorSet(scheduleId, msg.sender, anchorTime, block.number);
    }

    function _nextIntentId() internal view returns (bytes32) {
        return keccak256(abi.encodePacked(block.number, block.timestamp, totalIntents, msg.sender, "intent"));
    }

    function registerIntent(uint8 intentType) external whenNotPaused returns (bytes32 intentId) {
        if (intentType >= HRB_INTENT_TYPES) revert HRB_InvalidIntentType();
        intentId = _nextIntentId();
        _intents[intentId] = Intent({
            intentId: intentId,
            owner: msg.sender,
            intentType: intentType,
            createdAt: block.timestamp
        });
        _intentIds.push(intentId);
        totalIntents++;
        emit IntentRegistered(intentId, msg.sender, intentType, block.number);
        return intentId;
    }

    function submitFeedback(bytes32 refId, uint8 rating) external whenNotPaused {
        if (refId == bytes32(0)) revert HRB_InvalidRefId();
        if (rating < HRB_RATING_MIN || rating > HRB_RATING_MAX) revert HRB_RatingOutOfRange();
        emit FeedbackSubmitted(refId, msg.sender, rating, block.number);
    }

    function deposit() external payable whenNotPaused nonReentrant {
        if (msg.value == 0) revert HRB_ZeroAmount();
        balanceOf[msg.sender] += msg.value;
        emit DepositReceived(msg.sender, msg.value, block.number);
    }

    function withdraw(uint256 amountWei) external nonReentrant {
        if (amountWei == 0) revert HRB_ZeroAmount();
        if (balanceOf[msg.sender] < amountWei) revert HRB_InsufficientDeposit();
        balanceOf[msg.sender] -= amountWei;
        (bool ok,) = msg.sender.call{value: amountWei}("");
        if (!ok) revert HRB_TransferFailed();
        emit WithdrawalProcessed(msg.sender, amountWei, msg.sender, block.number);
    }

    function processWithdrawal(address to, uint256 amountWei) external onlyVault nonReentrant {
        if (to == address(0)) revert HRB_ZeroAddress();
        if (amountWei == 0) revert HRB_ZeroAmount();
        if (balanceOf[vault] < amountWei) revert HRB_InsufficientDeposit();
        balanceOf[vault] -= amountWei;
        (bool ok,) = to.call{value: amountWei}("");
        if (!ok) revert HRB_TransferFailed();
        emit WithdrawalProcessed(to, amountWei, msg.sender, block.number);
    }

    function getTask(bytes32 taskId) external view returns (
        address owner,
        uint8 kind,
        uint256 dueAt,
        uint8 status,
        uint256 createdAt
    ) {
        Task storage t = _tasks[taskId];
        if (t.owner == address(0)) revert HRB_TaskNotFound();
        return (t.owner, t.kind, t.dueAt, t.status, t.createdAt);
    }

    function getReminder(bytes32 reminderId) external view returns (
        address owner,
        uint256 triggerAt,
        bytes32 linkedTaskId,
        bool fired,
        uint256 createdAt
    ) {
        Reminder storage r = _reminders[reminderId];
        if (r.owner == address(0)) revert HRB_ReminderNotFound();
        return (r.owner, r.triggerAt, r.linkedTaskId, r.fired, r.createdAt);
    }

    function getSession(bytes32 sessionId) external view returns (
        address owner,
        uint256 startedAt,
        uint256 closedAt,
        uint256 responseCount
    ) {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        return (s.owner, s.startedAt, s.closedAt, s.responseCount);
    }

    function getIntent(bytes32 intentId) external view returns (
        address owner,
        uint8 intentType,
        uint256 createdAt
    ) {
        Intent storage i = _intents[intentId];
        if (i.owner == address(0)) revert HRB_InvalidRefId();
        return (i.owner, i.intentType, i.createdAt);
    }

    function getPreference(address owner, bytes32 keyHash) external view returns (bytes memory) {
        return _preferences[owner][keyHash];
    }

    function getResponseHash(bytes32 sessionId, uint256 index) external view returns (bytes32) {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        if (index >= s.responseCount) revert HRB_ResponseIndexOutOfBounds();
        return _responseHashes[sessionId][index];
    }

    function getSlot(bytes32 sessionId, bytes32 slotKey) external view returns (bytes memory) {
        return _slotData[sessionId][slotKey];
    }

    function getScheduleAnchor(bytes32 scheduleId) external view returns (uint256) {
        return _scheduleAnchors[scheduleId];
    }

    function getTaskIdsLength() external view returns (uint256) {
        return _taskIds.length;
    }

    function getTaskIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _taskIds.length) revert HRB_IndexOutOfRange();
        return _taskIds[index];
    }

    function getReminderIdsLength() external view returns (uint256) {
        return _reminderIds.length;
    }

    function getReminderIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _reminderIds.length) revert HRB_IndexOutOfRange();
        return _reminderIds[index];
    }

    function getSessionIdsLength() external view returns (uint256) {
        return _sessionIds.length;
    }

    function getSessionIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _sessionIds.length) revert HRB_IndexOutOfRange();
        return _sessionIds[index];
    }

    function getIntentIdsLength() external view returns (uint256) {
        return _intentIds.length;
    }

    function getIntentIdAt(uint256 index) external view returns (bytes32) {
        if (index >= _intentIds.length) revert HRB_IndexOutOfRange();
        return _intentIds[index];
    }

    function isPaused() external view returns (bool) {
        return _paused;
    }

    function getPlatformStats() external view returns (
        uint256 taskCount,
        uint256 reminderCount,
        uint256 sessionCount,
        uint256 intentCount,
        uint256 deployBlockNum,
        bool paused
    ) {
        return (
            totalTasks,
            totalReminders,
            totalSessions,
            totalIntents,
            deployBlock,
            _paused
        );
    }

    function getTaskSummariesBatch(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory taskIds,
        address[] memory owners,
        uint8[] memory kinds,
        uint256[] memory dueAts,
        uint8[] memory statuses
    ) {
        uint256 len = _taskIds.length;
        if (offset >= len) return (new bytes32[](0), new address[](0), new uint8[](0), new uint256[](0), new uint8[](0));
        uint256 take = limit;
        if (offset + take > len) take = len - offset;
        if (take > HRB_VIEW_BATCH) take = HRB_VIEW_BATCH;
        taskIds = new bytes32[](take);
        owners = new address[](take);
        kinds = new uint8[](take);
        dueAts = new uint256[](take);
        statuses = new uint8[](take);
        for (uint256 i = 0; i < take; i++) {
            bytes32 id = _taskIds[offset + i];
            Task storage t = _tasks[id];
            taskIds[i] = id;
            owners[i] = t.owner;
            kinds[i] = t.kind;
            dueAts[i] = t.dueAt;
            statuses[i] = t.status;
        }
    }

    function getReminderSummariesBatch(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory reminderIds,
        address[] memory owners,
        uint256[] memory triggerAts,
        bool[] memory fireds
    ) {
        uint256 len = _reminderIds.length;
        if (offset >= len) return (new bytes32[](0), new address[](0), new uint256[](0), new bool[](0));
        uint256 take = limit;
        if (offset + take > len) take = len - offset;
        if (take > HRB_VIEW_BATCH) take = HRB_VIEW_BATCH;
        reminderIds = new bytes32[](take);
        owners = new address[](take);
        triggerAts = new uint256[](take);
        fireds = new bool[](take);
        for (uint256 i = 0; i < take; i++) {
            bytes32 id = _reminderIds[offset + i];
            Reminder storage r = _reminders[id];
            reminderIds[i] = id;
            owners[i] = r.owner;
            triggerAts[i] = r.triggerAt;
            fireds[i] = r.fired;
        }
    }

    function getSessionSummariesBatch(uint256 offset, uint256 limit) external view returns (
        bytes32[] memory sessionIds,
        address[] memory owners,
        uint256[] memory startedAts,
        uint256[] memory closedAts,
        uint256[] memory responseCounts
    ) {
        uint256 len = _sessionIds.length;
        if (offset >= len) return (new bytes32[](0), new address[](0), new uint256[](0), new uint256[](0), new uint256[](0));
        uint256 take = limit;
        if (offset + take > len) take = len - offset;
        if (take > HRB_VIEW_BATCH) take = HRB_VIEW_BATCH;
        sessionIds = new bytes32[](take);
        owners = new address[](take);
        startedAts = new uint256[](take);
        closedAts = new uint256[](take);
        responseCounts = new uint256[](take);
        for (uint256 i = 0; i < take; i++) {
            bytes32 id = _sessionIds[offset + i];
            Session storage s = _sessions[id];
            sessionIds[i] = id;
            owners[i] = s.owner;
            startedAts[i] = s.startedAt;
            closedAts[i] = s.closedAt;
            responseCounts[i] = s.responseCount;
        }
    }

    function attestSession(bytes32 sessionId, bytes32 commitmentHash) external onlyOracle {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        emit SlotRecorded(sessionId, bytes32("attestation"), abi.encodePacked(commitmentHash), block.number);
    }

    function sentinelPause() external onlySentinel {
        _paused = true;
        emit Paused(msg.sender, block.number);
    }

    function curatorOverwriteSlot(bytes32 sessionId, bytes32 slotKey, bytes calldata value) external onlyCurator {
        Session storage s = _sessions[sessionId];
        if (s.owner == address(0)) revert HRB_SessionNotFound();
        _slotData[sessionId][slotKey] = value;
        emit SlotRecorded(sessionId, slotKey, value, block.number);
    }

    function getTaskCountForOwner(address owner) external view returns (uint256) {
        return _taskCountByOwner[owner];
    }

    function getReminderCountForOwner(address owner) external view returns (uint256) {
        return _reminderCountByOwner[owner];
    }

    function getSessionCountForOwner(address owner) external view returns (uint256) {
        return _sessionCountByOwner[owner];
    }

    function getTaskViewByIndex(uint256 index) external view returns (
        bytes32 taskId,
        address owner,
        uint8 kind,
        uint256 dueAt,
        uint8 status,
        uint256 createdAt
    ) {
        if (index >= _taskIds.length) revert HRB_IndexOutOfRange();
        bytes32 id = _taskIds[index];
        Task storage t = _tasks[id];
        return (t.taskId, t.owner, t.kind, t.dueAt, t.status, t.createdAt);
    }

    function getReminderViewByIndex(uint256 index) external view returns (
        bytes32 reminderId,
        address owner,
        uint256 triggerAt,
        bytes32 linkedTaskId,
        bool fired,
        uint256 createdAt
    ) {
        if (index >= _reminderIds.length) revert HRB_IndexOutOfRange();
        bytes32 id = _reminderIds[index];
        Reminder storage r = _reminders[id];
        return (r.reminderId, r.owner, r.triggerAt, r.linkedTaskId, r.fired, r.createdAt);
    }

    function getSessionViewByIndex(uint256 index) external view returns (
        bytes32 sessionId,
        address owner,
        uint256 startedAt,
        uint256 closedAt,
        uint256 responseCount
    ) {
        if (index >= _sessionIds.length) revert HRB_IndexOutOfRange();
        bytes32 id = _sessionIds[index];
        Session storage s = _sessions[id];
        return (s.sessionId, s.owner, s.startedAt, s.closedAt, s.responseCount);
    }

    function getIntentViewByIndex(uint256 index) external view returns (
        bytes32 intentId,
        address owner,
        uint8 intentType,
        uint256 createdAt
    ) {
        if (index >= _intentIds.length) revert HRB_IndexOutOfRange();
        bytes32 id = _intentIds[index];
        Intent storage i = _intents[id];
        return (i.intentId, i.owner, i.intentType, i.createdAt);
    }

    function getTaskSummariesBatchSmall(uint256 offset) external view returns (
        bytes32[] memory taskIds,
        address[] memory owners,
        uint8[] memory statuses
    ) {
        uint256 len = _taskIds.length;
        if (offset >= len) return (new bytes32[](0), new address[](0), new uint8[](0));
        uint256 take = 8;
        if (offset + take > len) take = len - offset;
        taskIds = new bytes32[](take);
        owners = new address[](take);
        statuses = new uint8[](take);
        for (uint256 i = 0; i < take; i++) {
            bytes32 id = _taskIds[offset + i];
            Task storage t = _tasks[id];
            taskIds[i] = id;
            owners[i] = t.owner;
            statuses[i] = t.status;
        }
    }

    function getReminderSummariesBatchSmall(uint256 offset) external view returns (
        bytes32[] memory reminderIds,
        address[] memory owners,
        bool[] memory fireds
    ) {
        uint256 len = _reminderIds.length;
