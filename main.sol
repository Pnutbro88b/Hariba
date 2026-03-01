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
