// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title KEYMIND Vault and Agent Grants
/// @notice The immutable creator-fee recipient of the $KMD pool, which runs Programmable's sealed launch-protection
///         hook. Anyone may call the hook fee vault's claimCreator() to push accrued creator fees (ETH) here, and
///         anyone may call distribute().
///
///         Every distribution splits the ETH waiting here in fixed shares:
///           80% Project treasury wallet (team, development, operations and marketing; free to use)
///           20% Agent Grants pool, kept here; it can only leave as a public grant
///
///         Agent Grants: the guardian proposes a grant (id, recipient, amount, hash of the public grant description).
///         The grant waits a 24-hour public review, during which the guardian can cancel it. After the review anyone
///         can execute it. A grant is at most MAX_GRANT_BPS of the pool when proposed, is paid once, and can never
///         pay the treasury, the guardian or this vault.
///
///         The guardian can change the treasury wallet or itself only through a 48-hour public timelock. There is no
///         other way to move ETH out of this contract.
contract KeymindVault {
    uint16 public constant BPS = 10_000;
    uint16 public constant SHARE_TREASURY_BPS = 8_000;
    uint16 public constant SHARE_GRANTS_BPS = 2_000;
    /// @notice A single grant is at most 25% of the Agent Grants pool at the time it is proposed.
    uint16 public constant MAX_GRANT_BPS = 2_500;

    uint32 public constant TIMELOCK = 48 hours;
    uint32 public constant REVIEW_PERIOD = 24 hours;

    struct Grant {
        address recipient;
        uint128 amount;
        uint64 proposedAt;
        bool cancelled;
        bool paid;
        bytes32 descriptionHash;
    }

    address public guardian;
    address public treasury;

    uint256 public grantsPool;
    uint256 public totalDistributed;
    uint256 public totalGrantsPaid;
    uint256 public grantCount;
    mapping(bytes32 grantId => Grant) public grants;

    // ---- timelocked changes
    address public pendingTreasury;
    uint64 public treasuryReadyAt;
    address public pendingGuardian;
    uint64 public guardianReadyAt;

    bool private _locked;

    event Received(address indexed from, uint256 amount);
    event Distributed(uint256 toGrants, uint256 toTreasury);
    event GrantProposed(bytes32 indexed grantId, address indexed recipient, uint256 amount, bytes32 descriptionHash, uint64 payableAt);
    event GrantCancelled(bytes32 indexed grantId);
    event GrantPaid(bytes32 indexed grantId, address indexed recipient, uint256 amount);
    event TreasuryProposed(address next, uint64 readyAt);
    event TreasuryChanged(address previous, address next);
    event GuardianProposed(address next, uint64 readyAt);
    event GuardianChanged(address previous, address next);
    event ProposalCancelled(uint8 kind);

    error ZeroAddress();
    error NotGuardian();
    error BadGrant();
    error GrantExists();
    error UnknownGrant();
    error GrantIsCancelled();
    error GrantAlreadyPaid();
    error GrantTooLarge();
    error RecipientNotAllowed();
    error InReview();
    error InsufficientPool();
    error TooEarly();
    error NothingPending();
    error TransferFailed();
    error Reentrant();

    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(address guardian_, address treasury_) {
        if (guardian_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        treasury = treasury_;
    }

    receive() external payable {
        emit Received(msg.sender, msg.value);
    }

    /// @notice ETH waiting to be split (everything except the Agent Grants pool).
    function pending() public view returns (uint256) {
        return address(this).balance - grantsPool;
    }

    // ================================================================== permissionless
    function distribute() external nonReentrant {
        _distribute();
    }

    /// @notice Pay a grant whose public review is over. Anyone may call it.
    function executeGrant(bytes32 grantId) external nonReentrant {
        Grant storage g = grants[grantId];
        if (g.proposedAt == 0) revert UnknownGrant();
        if (g.cancelled) revert GrantIsCancelled();
        if (g.paid) revert GrantAlreadyPaid();
        if (block.timestamp < uint256(g.proposedAt) + REVIEW_PERIOD) revert InReview();
        if (!_allowedRecipient(g.recipient)) revert RecipientNotAllowed(); // roles may have changed since the proposal
        if (g.amount > grantsPool) revert InsufficientPool();
        g.paid = true;
        grantsPool -= g.amount;
        totalGrantsPaid += g.amount;
        _send(g.recipient, g.amount);
        emit GrantPaid(grantId, g.recipient, g.amount);
    }

    // ================================================================== Agent Grants (guardian)
    /// @notice Propose a grant; its description is published and its hash committed here.
    function proposeGrant(bytes32 grantId, address recipient, uint128 amount, bytes32 descriptionHash) external onlyGuardian {
        if (grantId == bytes32(0) || amount == 0 || descriptionHash == bytes32(0)) revert BadGrant();
        if (recipient == address(0)) revert ZeroAddress();
        if (!_allowedRecipient(recipient)) revert RecipientNotAllowed();
        if (grants[grantId].proposedAt != 0) revert GrantExists();
        if (uint256(amount) > grantsPool * MAX_GRANT_BPS / BPS) revert GrantTooLarge();
        uint64 nowTs = uint64(block.timestamp);
        grants[grantId] = Grant({
            recipient: recipient, amount: amount, proposedAt: nowTs, cancelled: false, paid: false, descriptionHash: descriptionHash
        });
        grantCount += 1;
        emit GrantProposed(grantId, recipient, amount, descriptionHash, nowTs + REVIEW_PERIOD);
    }

    /// @notice Cancel a grant that has not been paid.
    function cancelGrant(bytes32 grantId) external onlyGuardian {
        Grant storage g = grants[grantId];
        if (g.proposedAt == 0) revert UnknownGrant();
        if (g.paid) revert GrantAlreadyPaid();
        if (g.cancelled) revert GrantIsCancelled();
        g.cancelled = true;
        emit GrantCancelled(grantId);
    }

    // ================================================================== guardian (all timelocked)
    function proposeTreasury(address next) external onlyGuardian {
        if (next == address(0)) revert ZeroAddress();
        pendingTreasury = next;
        treasuryReadyAt = uint64(block.timestamp + TIMELOCK);
        emit TreasuryProposed(next, treasuryReadyAt);
    }

    function executeTreasury() external onlyGuardian nonReentrant {
        if (treasuryReadyAt == 0) revert NothingPending();
        if (block.timestamp < treasuryReadyAt) revert TooEarly();
        _distribute(); // fees earned under the old treasury go to it
        emit TreasuryChanged(treasury, pendingTreasury);
        treasury = pendingTreasury;
        pendingTreasury = address(0);
        treasuryReadyAt = 0;
    }

    /// @notice Hand the guardian role to a new wallet, Safe or DAO, or to address(0) to renounce, after the timelock.
    function proposeGuardian(address next) external onlyGuardian {
        pendingGuardian = next;
        guardianReadyAt = uint64(block.timestamp + TIMELOCK);
        emit GuardianProposed(next, guardianReadyAt);
    }

    function executeGuardian() external onlyGuardian {
        if (guardianReadyAt == 0) revert NothingPending();
        if (block.timestamp < guardianReadyAt) revert TooEarly();
        emit GuardianChanged(guardian, pendingGuardian);
        guardian = pendingGuardian;
        pendingGuardian = address(0);
        guardianReadyAt = 0;
    }

    /// @param kind 0 treasury, 1 guardian
    function cancelProposal(uint8 kind) external onlyGuardian {
        if (kind == 0) {
            pendingTreasury = address(0);
            treasuryReadyAt = 0;
        } else {
            pendingGuardian = address(0);
            guardianReadyAt = 0;
        }
        emit ProposalCancelled(kind);
    }

    // ================================================================== internals
    function _distribute() internal {
        uint256 amount = pending();
        if (amount == 0) return;
        uint256 toTreasury = amount * SHARE_TREASURY_BPS / BPS;
        uint256 toGrants = amount - toTreasury;
        // Book the grants share before any ETH leaves, so pending() can never count it again.
        grantsPool += toGrants;
        totalDistributed += amount;
        _send(treasury, toTreasury);
        emit Distributed(toGrants, toTreasury);
    }

    function _allowedRecipient(address r) private view returns (bool) {
        return r != treasury && r != guardian && r != pendingTreasury && r != pendingGuardian && r != address(this);
    }

    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert TransferFailed();
    }
}
