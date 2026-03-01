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
