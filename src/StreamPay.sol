// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title StreamPay -  Real-time USDC Streaming on Arc
/// @notice USDC flows continuously per second from sender to recipient.
///         Recipient can withdraw earned amount anytime.
///         Sender can cancel and get unearned USDC back.
/// @dev    Uses USDC ERC-20 interface exclusively (6 decimals).
///         Arc testnet USDC: 0x3600000000000000000000000000000000000000
///         Never mix with native 18-decimal balance.
contract StreamPay {

    // ─── Constants ────────────────────────────────────────────────────────────

    /// @dev Arc testnet USDC ERC-20 -  6 decimals
    address public constant USDC = 0x3600000000000000000000000000000000000000;

    uint256 public constant MIN_DURATION = 60;        // 1 minute minimum
    uint256 public constant MAX_DURATION = 365 days;  // 1 year maximum
    uint256 public constant MIN_AMOUNT   = 1_000_000; // 1 USDC minimum

    // ─── Enums ───────────────────────────────────────────────────────────────

    enum StreamStatus { Active, Cancelled, Completed }

    // ─── Structs ─────────────────────────────────────────────────────────────

    struct Stream {
        uint256 id;
        address sender;
        address recipient;
        uint256 deposit;          // total USDC deposited (6 decimals)
        uint256 ratePerSecond;    // USDC per second (6 decimals, scaled ×1e18 for precision)
        uint256 startTime;        // unix timestamp stream started
        uint256 stopTime;         // unix timestamp stream ends
        uint256 withdrawn;        // amount already withdrawn by recipient (6 decimals)
        string  description;      // optional label e.g. "Monthly salary - Ahmad"
        StreamStatus status;
    }

    // ─── State ────────────────────────────────────────────────────────────────

    uint256 private _nextStreamId = 1;
    uint256 private _totalStreamed;         // cumulative USDC that has flowed
    uint256 private _activeStreamCount;

    mapping(uint256 => Stream)       private _streams;
    mapping(address => uint256[])    private _senderStreams;
    mapping(address => uint256[])    private _recipientStreams;

    // ─── Events ───────────────────────────────────────────────────────────────

    event StreamCreated(
        uint256 indexed streamId,
        address indexed sender,
        address indexed recipient,
        uint256 deposit,
        uint256 startTime,
        uint256 stopTime,
        string  description
    );
    event Withdrawn(uint256 indexed streamId, address indexed recipient, uint256 amount);
    event StreamCancelled(uint256 indexed streamId, uint256 senderRefund, uint256 recipientAmount);
    event StreamCompleted(uint256 indexed streamId);
    event ToppedUp(uint256 indexed streamId, uint256 addedAmount, uint256 newStopTime);

    // ─── Modifiers ────────────────────────────────────────────────────────────

    modifier streamExists(uint256 streamId) {
        require(_streams[streamId].id != 0, "StreamPay: stream does not exist");
        _;
    }

    modifier onlyActive(uint256 streamId) {
        require(_streams[streamId].status == StreamStatus.Active, "StreamPay: stream not active");
        _;
    }

    // ─── Core: Create Stream ──────────────────────────────────────────────────

    function createStream(
        address recipient,
        uint256 deposit,
        uint256 duration,
        string calldata description
    ) external returns (uint256 streamId) {
        require(recipient != address(0),  "StreamPay: zero recipient");
        require(recipient != msg.sender,  "StreamPay: cannot stream to self");
        require(deposit >= MIN_AMOUNT,    "StreamPay: deposit below minimum");
        require(duration >= MIN_DURATION, "StreamPay: duration too short");
        require(duration <= MAX_DURATION, "StreamPay: duration too long");

        uint256 ratePerSecond = (deposit * 1e18) / duration;
        require(ratePerSecond > 0, "StreamPay: rate rounds to zero");

        bool ok = IERC20(USDC).transferFrom(msg.sender, address(this), deposit);
        require(ok, "StreamPay: USDC transfer failed - did you approve?");

        streamId = _nextStreamId++;
        _storeStream(streamId, msg.sender, recipient, deposit, ratePerSecond, duration, description);

        _senderStreams[msg.sender].push(streamId);
        _recipientStreams[recipient].push(streamId);
        _activeStreamCount++;

        emit StreamCreated(streamId, msg.sender, recipient, deposit, block.timestamp, block.timestamp + duration, description);
    }

    function _storeStream(
        uint256 streamId,
        address sender,
        address recipient,
        uint256 deposit,
        uint256 ratePerSecond,
        uint256 duration,
        string calldata description
    ) internal {
        uint256 start = block.timestamp;
        _streams[streamId] = Stream({
            id:            streamId,
            sender:        sender,
            recipient:     recipient,
            deposit:       deposit,
            ratePerSecond: ratePerSecond,
            startTime:     start,
            stopTime:      start + duration,
            withdrawn:     0,
            description:   description,
            status:        StreamStatus.Active
        });
    }

    // ─── Core: Withdraw ───────────────────────────────────────────────────────

    /// @notice Recipient withdraws all earned USDC so far.
    ///         Can be called multiple times -  only unwithdran earned amount is sent.
    /// @param streamId The stream to withdraw from
    function withdraw(uint256 streamId)
        external
        streamExists(streamId)
        onlyActive(streamId)
    {
        Stream storage s = _streams[streamId];
        require(msg.sender == s.recipient, "StreamPay: not recipient");

        uint256 amount = _withdrawable(s);
        require(amount > 0, "StreamPay: nothing to withdraw");

        s.withdrawn += amount;
        _totalStreamed += amount;

        // Check if stream is now fully paid out
        if (s.withdrawn >= s.deposit || block.timestamp >= s.stopTime) {
            s.status = StreamStatus.Completed;
            _activeStreamCount--;
            emit StreamCompleted(streamId);
        }

        bool ok = IERC20(USDC).transfer(s.recipient, amount);
        require(ok, "StreamPay: USDC withdrawal failed");

        emit Withdrawn(streamId, s.recipient, amount);
    }

    // ─── Core: Cancel ─────────────────────────────────────────────────────────

    /// @notice Sender cancels the stream.
    ///         Recipient gets earned amount up to now.
    ///         Sender gets remaining unearned USDC back.
    /// @param streamId The stream to cancel
    function cancel(uint256 streamId)
        external
        streamExists(streamId)
        onlyActive(streamId)
    {
        Stream storage s = _streams[streamId];
        require(msg.sender == s.sender, "StreamPay: not sender");

        uint256 recipientAmount = _withdrawable(s);
        uint256 senderRefund    = s.deposit - s.withdrawn - recipientAmount;

        s.status = StreamStatus.Cancelled;
        _activeStreamCount--;
        _totalStreamed += recipientAmount;

        // Send earned amount to recipient
        if (recipientAmount > 0) {
            bool ok1 = IERC20(USDC).transfer(s.recipient, recipientAmount);
            require(ok1, "StreamPay: recipient transfer failed");
        }

        // Refund remaining to sender
        if (senderRefund > 0) {
            bool ok2 = IERC20(USDC).transfer(s.sender, senderRefund);
            require(ok2, "StreamPay: sender refund failed");
        }

        emit StreamCancelled(streamId, senderRefund, recipientAmount);
    }

    // ─── Core: Top Up ─────────────────────────────────────────────────────────

    /// @notice Sender adds more USDC to extend the stream duration.
    /// @param streamId   The stream to top up
    /// @param addAmount  Additional USDC to deposit (6 decimals)
    function topUp(uint256 streamId, uint256 addAmount)
        external
        streamExists(streamId)
        onlyActive(streamId)
    {
        Stream storage s = _streams[streamId];
        require(msg.sender == s.sender, "StreamPay: not sender");
        require(addAmount >= MIN_AMOUNT,  "StreamPay: top-up below minimum");

        bool ok = IERC20(USDC).transferFrom(msg.sender, address(this), addAmount);
        require(ok, "StreamPay: USDC transfer failed");

        // Extend stop time proportionally
        uint256 extraSeconds = (addAmount * 1e18) / s.ratePerSecond;
        s.deposit   += addAmount;
        s.stopTime  += extraSeconds;

        emit ToppedUp(streamId, addAmount, s.stopTime);
    }

    // ─── View: Withdrawable ───────────────────────────────────────────────────

    /// @notice How much USDC the recipient can withdraw right now
    function withdrawable(uint256 streamId)
        external
        view
        streamExists(streamId)
        returns (uint256)
    {
        Stream storage s = _streams[streamId];
        if (s.status != StreamStatus.Active) return 0;
        return _withdrawable(s);
    }

    /// @notice Streaming progress as a percentage (0–100)
    function streamProgress(uint256 streamId)
        external
        view
        streamExists(streamId)
        returns (uint256 pct)
    {
        Stream storage s = _streams[streamId];
        if (block.timestamp <= s.startTime) return 0;
        if (block.timestamp >= s.stopTime)  return 100;
        pct = ((block.timestamp - s.startTime) * 100) / (s.stopTime - s.startTime);
    }

    // ─── View: Getters ────────────────────────────────────────────────────────

    function getStream(uint256 streamId)
        external
        view
        streamExists(streamId)
        returns (Stream memory)
    {
        return _streams[streamId];
    }

    function getSenderStreams(address sender)
        external
        view
        returns (uint256[] memory)
    {
        return _senderStreams[sender];
    }

    function getRecipientStreams(address recipient)
        external
        view
        returns (uint256[] memory)
    {
        return _recipientStreams[recipient];
    }

    function totalStreams()        external view returns (uint256) { return _nextStreamId - 1; }
    function totalStreamed()       external view returns (uint256) { return _totalStreamed; }
    function activeStreamCount()   external view returns (uint256) { return _activeStreamCount; }

    // ─── Internal ─────────────────────────────────────────────────────────────

    function _withdrawable(Stream storage s) internal view returns (uint256) {
        uint256 elapsed  = block.timestamp >= s.stopTime
            ? s.stopTime - s.startTime
            : block.timestamp - s.startTime;

        // earned = ratePerSecond (scaled) * elapsed / 1e18 -  descale back to 6 decimals
        uint256 earned   = (s.ratePerSecond * elapsed) / 1e18;

        // cap at deposit
        if (earned > s.deposit) earned = s.deposit;

        return earned > s.withdrawn ? earned - s.withdrawn : 0;
    }
}

// ─── Minimal ERC-20 Interface ─────────────────────────────────────────────────

interface IERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
}
