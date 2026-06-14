// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title ConfessFi (native-fee edition for Arc Testnet, Chain ID 5042002)
 * @notice Anonymous Web3-native confession board. Wallet = identity.
 *
 *         On Arc, USDC IS the native gas coin (18 decimals). So fees are charged
 *         as native USDC sent with the transaction (msg.value) — exactly like
 *         sending ETH on Ethereum. There is NO ERC-20 approve step.
 *
 * Fees (native USDC, 18 decimals):
 *   - Create Confession : 0.20 USDC
 *   - Upvote / Downvote : 0.10 USDC
 *   - Comment           : 0.05 USDC (max 3 comments per wallet per confession)
 *   - Fact Check Vote   : 0.10 USDC
 *
 * Revenue split for every paid action:
 *   - 70% -> Weekly Prize Pool
 *   - 20% -> Confession Creator (instant earnings, pull-withdraw)
 *   - 10% -> Platform Treasury (pull-withdraw)
 *
 * Ranking score = uniqueUpvotes - uniqueDownvotes - uniqueFakeVotes.
 */
contract ConfessFi is ReentrancyGuard, Ownable {
    // Fees in native USDC base units (18 decimals).
    uint256 public constant CREATE_FEE = 0.20 ether; // 0.20 USDC
    uint256 public constant VOTE_FEE = 0.10 ether;   // 0.10 USDC
    uint256 public constant COMMENT_FEE = 0.05 ether; // 0.05 USDC
    uint256 public constant FACTCHECK_FEE = 0.10 ether; // 0.10 USDC

    uint256 public constant POOL_BPS = 7000;     // 70%
    uint256 public constant CREATOR_BPS = 2000;  // 20%
    uint256 public constant BPS_DENOMINATOR = 10000;

    uint256 public constant MAX_COMMENTS_PER_WALLET = 3;
    uint256 public constant WEEK = 7 days;

    enum Category { Crypto, Relationships, Work, Funny, Economy }

    struct Confession {
        uint256 id;
        address creator;
        string text;
        Category category;
        uint64 createdAt;
        uint64 commentCount;
        uint64 upvotes;
        uint64 downvotes;
        uint64 realVotes;
        uint64 fakeVotes;
        bool hidden;
    }

    struct Comment {
        uint256 confessionId;
        address author;
        string text;
        uint64 createdAt;
    }

    address public treasury;
    uint256 public confessionCount;
    mapping(uint256 => Confession) private _confessions;
    mapping(uint256 => Comment[]) private _comments;
    mapping(uint256 => mapping(address => uint256)) public commentsByWallet;

    mapping(uint256 => mapping(address => bool)) public hasUpvoted;
    mapping(uint256 => mapping(address => bool)) public hasDownvoted;
    mapping(uint256 => mapping(address => bool)) public hasFactChecked;

    uint256 public prizePool;
    uint256 public weekStart;
    uint256 public weekIndex;
    mapping(address => uint256) public earnings;

    event ConfessionCreated(uint256 indexed id, address indexed creator, Category category, string text, uint64 createdAt);
    event Upvoted(uint256 indexed id, address indexed voter, int256 newScore);
    event Downvoted(uint256 indexed id, address indexed voter, int256 newScore);
    event FactChecked(uint256 indexed id, address indexed voter, bool isReal, int256 newScore);
    event Commented(uint256 indexed id, address indexed author, string text, uint64 createdAt);
    event RevenueSplit(uint256 indexed id, address indexed payer, address indexed creator, uint256 toPool, uint256 toCreator, uint256 toTreasury);
    event EarningsWithdrawn(address indexed account, uint256 amount);
    event WeeklyRewardsDistributed(uint256 indexed week, uint256 totalPool, uint256[3] winners, uint256[3] amounts);
    event RewardsRolledOver(uint256 indexed week, uint256 amount);
    event ConfessionVisibilityToggled(uint256 indexed id, bool hidden);
    event TreasuryUpdated(address indexed newTreasury);

    error EmptyText();
    error TextTooLong();
    error InvalidConfession();
    error ConfessionHidden();
    error AlreadyUpvoted();
    error AlreadyDownvoted();
    error AlreadyFactChecked();
    error CommentLimitReached();
    error NothingToWithdraw();
    error WeekNotElapsed();
    error ZeroAddress();
    error WrongFee(uint256 required, uint256 sent);
    error TransferFailed();

    constructor(address _treasury) Ownable(msg.sender) {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        weekStart = block.timestamp;
        weekIndex = 1;
    }

    // ---------------------------------------------------------------------
    // Core actions (payable — fee paid as native USDC via msg.value)
    // ---------------------------------------------------------------------

    function createConfession(string calldata text, Category category)
        external
        payable
        nonReentrant
        returns (uint256 id)
    {
        if (msg.value != CREATE_FEE) revert WrongFee(CREATE_FEE, msg.value);
        bytes memory raw = bytes(text);
        if (raw.length == 0) revert EmptyText();
        if (raw.length > 1000) revert TextTooLong();

        id = ++confessionCount;
        Confession storage c = _confessions[id];
        c.id = id;
        c.creator = msg.sender;
        c.text = text;
        c.category = category;
        c.createdAt = uint64(block.timestamp);

        _split(id, msg.sender, c.creator, msg.value);
        emit ConfessionCreated(id, msg.sender, category, text, c.createdAt);
    }

    function upvote(uint256 id) external payable nonReentrant {
        if (msg.value != VOTE_FEE) revert WrongFee(VOTE_FEE, msg.value);
        Confession storage c = _liveConfession(id);
        if (hasUpvoted[id][msg.sender]) revert AlreadyUpvoted();
        hasUpvoted[id][msg.sender] = true;
        c.upvotes += 1;
        _split(id, msg.sender, c.creator, msg.value);
        emit Upvoted(id, msg.sender, scoreOf(id));
    }

    function downvote(uint256 id) external payable nonReentrant {
        if (msg.value != VOTE_FEE) revert WrongFee(VOTE_FEE, msg.value);
        Confession storage c = _liveConfession(id);
        if (hasDownvoted[id][msg.sender]) revert AlreadyDownvoted();
        hasDownvoted[id][msg.sender] = true;
        c.downvotes += 1;
        _split(id, msg.sender, c.creator, msg.value);
        emit Downvoted(id, msg.sender, scoreOf(id));
    }

    function factCheck(uint256 id, bool isReal) external payable nonReentrant {
        if (msg.value != FACTCHECK_FEE) revert WrongFee(FACTCHECK_FEE, msg.value);
        Confession storage c = _liveConfession(id);
        if (hasFactChecked[id][msg.sender]) revert AlreadyFactChecked();
        hasFactChecked[id][msg.sender] = true;
        if (isReal) c.realVotes += 1; else c.fakeVotes += 1;
        _split(id, msg.sender, c.creator, msg.value);
        emit FactChecked(id, msg.sender, isReal, scoreOf(id));
    }

    function comment(uint256 id, string calldata text) external payable nonReentrant {
        if (msg.value != COMMENT_FEE) revert WrongFee(COMMENT_FEE, msg.value);
        Confession storage c = _liveConfession(id);
        bytes memory raw = bytes(text);
        if (raw.length == 0) revert EmptyText();
        if (raw.length > 500) revert TextTooLong();
        if (commentsByWallet[id][msg.sender] >= MAX_COMMENTS_PER_WALLET) revert CommentLimitReached();

        commentsByWallet[id][msg.sender] += 1;
        c.commentCount += 1;
        _comments[id].push(Comment({confessionId: id, author: msg.sender, text: text, createdAt: uint64(block.timestamp)}));
        _split(id, msg.sender, c.creator, msg.value);
        emit Commented(id, msg.sender, text, uint64(block.timestamp));
    }

    function withdrawEarnings() external nonReentrant {
        uint256 amount = earnings[msg.sender];
        if (amount == 0) revert NothingToWithdraw();
        earnings[msg.sender] = 0;
        (bool ok, ) = payable(msg.sender).call{value: amount}("");
        if (!ok) revert TransferFailed();
        emit EarningsWithdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------------
    // Pool settlement
    // ---------------------------------------------------------------------

    function distributeWeeklyRewards(uint256[] calldata rankedIds) external onlyOwner nonReentrant {
        if (block.timestamp < weekStart + WEEK) revert WeekNotElapsed();
        uint256 currentWeek = weekIndex;
        uint256 pool = prizePool;

        uint256[3] memory winners;
        uint256 found;
        int256 prevScore = type(int256).max;
        for (uint256 i = 0; i < rankedIds.length && found < 3; i++) {
            uint256 cid = rankedIds[i];
            if (cid == 0 || cid > confessionCount) continue;
            Confession storage c = _confessions[cid];
            if (c.hidden) continue;
            int256 s = scoreOf(cid);
            if (s <= 0) continue;
            if (s > prevScore) continue;
            bool dup;
            for (uint256 j = 0; j < found; j++) { if (winners[j] == cid) { dup = true; break; } }
            if (dup) continue;
            winners[found] = cid;
            prevScore = s;
            found++;
        }

        weekStart = block.timestamp;
        weekIndex = currentWeek + 1;

        if (found == 0 || pool == 0) {
            emit RewardsRolledOver(currentWeek, pool);
            return;
        }
        prizePool = 0;

        uint256[3] memory shares;
        if (found == 1) {
            shares[0] = pool;
        } else if (found == 2) {
            shares[0] = (pool * 5000) / 8000;
            shares[1] = pool - shares[0];
        } else {
            shares[0] = (pool * 5000) / BPS_DENOMINATOR;
            shares[1] = (pool * 3000) / BPS_DENOMINATOR;
            shares[2] = pool - shares[0] - shares[1];
        }
        for (uint256 i = 0; i < found; i++) {
            earnings[_confessions[winners[i]].creator] += shares[i];
        }
        emit WeeklyRewardsDistributed(currentWeek, pool, winners, shares);
    }

    // ---------------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------------

    function toggleConfessionVisibility(uint256 id) external onlyOwner {
        Confession storage c = _confessions[id];
        if (c.id == 0) revert InvalidConfession();
        c.hidden = !c.hidden;
        emit ConfessionVisibilityToggled(id, c.hidden);
    }

    function setTreasury(address _treasury) external onlyOwner {
        if (_treasury == address(0)) revert ZeroAddress();
        treasury = _treasury;
        emit TreasuryUpdated(_treasury);
    }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function scoreOf(uint256 id) public view returns (int256) {
        Confession storage c = _confessions[id];
        if (c.id == 0) revert InvalidConfession();
        return int256(uint256(c.upvotes)) - int256(uint256(c.downvotes)) - int256(uint256(c.fakeVotes));
    }

    function getConfession(uint256 id) external view returns (Confession memory) {
        Confession storage c = _confessions[id];
        if (c.id == 0) revert InvalidConfession();
        return c;
    }

    function getComments(uint256 id) external view returns (Comment[] memory) {
        return _comments[id];
    }

    function getConfessionsPaginated(uint256 offset, uint256 limit) external view returns (Confession[] memory page) {
        uint256 total = confessionCount;
        if (offset >= total) return new Confession[](0);
        uint256 end = offset + limit;
        if (end > total) end = total;
        page = new Confession[](end - offset);
        for (uint256 i = offset; i < end; i++) {
            page[i - offset] = _confessions[i + 1];
        }
    }

    function timeUntilSettlement() external view returns (uint256) {
        uint256 settleAt = weekStart + WEEK;
        if (block.timestamp >= settleAt) return 0;
        return settleAt - block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Internal
    // ---------------------------------------------------------------------

    function _liveConfession(uint256 id) internal view returns (Confession storage c) {
        c = _confessions[id];
        if (c.id == 0) revert InvalidConfession();
        if (c.hidden) revert ConfessionHidden();
    }

    /// @dev Split incoming native USDC 70/20/10. Pool + creator + treasury are
    ///      held in-contract and withdrawn with the pull pattern (Arc-safe).
    function _split(uint256 id, address payer, address creator, uint256 amount) internal {
        uint256 toPool = (amount * POOL_BPS) / BPS_DENOMINATOR;
        uint256 toCreator = (amount * CREATOR_BPS) / BPS_DENOMINATOR;
        uint256 toTreasury = amount - toPool - toCreator;
        prizePool += toPool;
        earnings[creator] += toCreator;
        earnings[treasury] += toTreasury;
        emit RevenueSplit(id, payer, creator, toPool, toCreator, toTreasury);
    }
}
