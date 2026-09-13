// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "../interfaces/IERC20.sol";
import {IExchangeRouter, IPriceOracle, IBankNote} from "../interfaces/IBank.sol";
import {IFuguiBankView} from "../interfaces/IFuguiBankView.sol";
import {Roles} from "../lib/Roles.sol";
import {ReentrancyGuard} from "../lib/ReentrancyGuard.sol";
import {FullMath} from "../lib/FullMath.sol";

/// @title FuguiBank — 富贵钱庄
/// @notice The 落袋金库 ("pocket-your-gains vault") of FUGUI Finance on Robinhood Chain.
///
///  Two modes per position:
///   - MODE_LUCKY (落袋为安): deposit a meme coin ($FUGUI); every time the meme price
///     rises `stepBps` above the watermark, swap `sellBps` of the remaining meme into
///     the chosen Stock Token. "炒 meme，攒英伟达."
///   - MODE_BOLD (富贵险中求): deposit a Stock Token; every time the meme dips
///     `stepBps` below the watermark, spend `sellBps` of the remaining stock to buy
///     the dip — reverse DCA.
///
///  Every position mints a BankNote (银票) NFT as its receipt. `harvest` is
///  permissionless (keeper-friendly, pays a tip); prices come from `IPriceOracle`
///  (StaticOracle on testnet, TwapOracle on mainnet); swaps route through
///  `IExchangeRouter`.
contract FuguiBank is IFuguiBankView, Roles, ReentrancyGuard {
    // ------------------------------------------------------------------ constants
    uint8 public constant MODE_LUCKY = 0; // 落袋为安: meme -> stock on pump
    uint8 public constant MODE_BOLD = 1; // 富贵险中求: stock -> meme on dip
    uint32 public constant BPS = 10_000;
    uint32 public constant MIN_STEP_BPS = 100; // 1%
    uint32 public constant MAX_STEP_BPS = 5_000; // 50%
    uint32 public constant MIN_SELL_BPS = 100;
    uint32 public constant MAX_SELL_BPS = 5_000;
    bytes32 public constant ROLE_GUARDIAN = keccak256("GUARDIAN");

    // ---------------------------------------------------------------------- deps
    IPriceOracle public oracle;
    IExchangeRouter public router;
    IBankNote public note;
    address public treasury;

    // ---------------------------------------------------------------------- fees
    uint32 public performanceFeeBps = 500; // 5% of each harvest output
    uint32 public keeperTipBps = 100; // 1% of each harvest output, to keeper
    uint32 public slippageBps = 300; // 3% buffer applied to oracle quote for minOut
    mapping(address => uint256) public pendingFees; // token -> accrued fees

    // --------------------------------------------------------------------- state
    Position[] internal _positions;
    mapping(address => uint256[]) internal _positionsOfOwner;
    mapping(address => bool) public memeAllowed;
    mapping(address => bool) public stockAllowed;
    address[] public memeList;
    address[] public stockList;
    /// @dev token -> number of open positions referencing it (guards rescue()).
    mapping(address => uint256) public openInterestCount;
    bool public paused;

    // --------------------------------------------------------------------- events
    event PositionOpened(
        uint256 indexed positionId,
        address indexed owner,
        address indexed meme,
        address stock,
        uint8 mode,
        uint256 srcAmount,
        uint32 stepBps,
        uint32 sellBps,
        uint256 watermark
    );
    event Harvested(
        uint256 indexed positionId,
        address indexed keeper,
        uint256 srcSwapped,
        uint256 amountOut,
        uint256 feeAmount,
        uint256 keeperTip,
        uint256 price,
        uint256 newWatermark
    );
    event Claimed(uint256 indexed positionId, address indexed to, address indexed token, uint256 amount);
    event PositionClosed(uint256 indexed positionId, address indexed owner, bool keptNote);
    event ConfigUpdated(uint256 indexed positionId, uint32 stepBps, uint32 sellBps);
    event FeesUpdated(uint32 performanceFeeBps, uint32 keeperTipBps, uint32 slippageBps, address treasury);
    event FeesCollected(address indexed token, address indexed treasury, uint256 amount);
    event OracleUpdated(address oracle);
    event RouterUpdated(address router);
    event NoteUpdated(address note);
    event TokenSupportUpdated(uint8 indexed kind, address indexed token, bool supported);
    event PausedSet(bool paused);
    event Rescued(address indexed token, address indexed treasury, uint256 amount);

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error ZeroAmount();
    error BadMode();
    error TokenNotSupported(address token);
    error StepOutOfBounds();
    error SellOutOfBounds();
    error FeesTooHigh();
    error SlippageTooHigh();
    error NotPositionOwner();
    error PositionAlreadyClosed();
    error NoStepReached();
    error NotEnoughSrc();
    error TransferFailed();
    error NothingToClaim();
    error NothingToCollect();
    error PausedError();
    error OpenInterestExists(address token);

    modifier whenNotPaused() {
        if (paused) revert PausedError();
        _;
    }

    constructor(address oracle_, address router_, address note_, address treasury_) {
        if (oracle_ == address(0) || router_ == address(0) || note_ == address(0) || treasury_ == address(0)) {
            revert ZeroAddress();
        }
        oracle = IPriceOracle(oracle_);
        router = IExchangeRouter(router_);
        note = IBankNote(note_);
        treasury = treasury_;
        _grantRole(ROLE_GUARDIAN, msg.sender);
    }

    // ------------------------------------------------------------------- actions

    /// @notice Open a position and mint its BankNote receipt.
    /// @param mode MODE_LUCKY (deposit meme) or MODE_BOLD (deposit stock).
    /// @param meme Meme token (e.g. $FUGUI), must be whitelisted.
    /// @param stock Stock Token (e.g. tNVDA), must be whitelisted.
    /// @param srcAmount Amount of the source token to deposit.
    /// @param stepBps Price move (bp of watermark) that triggers a harvest (100..5000).
    /// @param sellBps Fraction (bp) of srcRemaining swapped per harvest (100..5000).
    function openPosition(
        uint8 mode,
        address meme,
        address stock,
        uint256 srcAmount,
        uint32 stepBps,
        uint32 sellBps
    ) external nonReentrant whenNotPaused returns (uint256 positionId) {
        if (mode > MODE_BOLD) revert BadMode();
        if (meme == stock) revert BadMode();
        if (!memeAllowed[meme]) revert TokenNotSupported(meme);
        if (!stockAllowed[stock]) revert TokenNotSupported(stock);
        if (srcAmount == 0) revert ZeroAmount();
        if (stepBps < MIN_STEP_BPS || stepBps > MAX_STEP_BPS) revert StepOutOfBounds();
        if (sellBps < MIN_SELL_BPS || sellBps > MAX_SELL_BPS) revert SellOutOfBounds();

        uint256 watermark = _priceOf(meme, stock);
        address srcToken = mode == MODE_LUCKY ? meme : stock;
        _pull(srcToken, msg.sender, srcAmount);

        _positions.push();
        positionId = _positions.length - 1;
        Position storage p = _positions[positionId];
        p.owner = msg.sender;
        p.meme = meme;
        p.stock = stock;
        p.mode = mode;
        p.srcRemaining = srcAmount;
        p.stepBps = stepBps;
        p.sellBps = sellBps;
        p.watermark = watermark;
        p.lastHarvestAt = uint64(block.timestamp);

        _positionsOfOwner[msg.sender].push(positionId);
        openInterestCount[meme] += 1;
        openInterestCount[stock] += 1;

        note.mint(msg.sender, positionId);

        emit PositionOpened(positionId, msg.sender, meme, stock, mode, srcAmount, stepBps, sellBps, watermark);
    }

    /// @notice Execute one step of the laddered take-profit / buy-the-dip.
    /// @dev Permissionless: anyone (keeper bots) can call and earns `keeperTipBps`.
    function harvest(uint256 positionId)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        if (p.closed) revert PositionAlreadyClosed();
        uint256 srcRemaining = p.srcRemaining;
        if (srcRemaining == 0) revert NotEnoughSrc();

        uint256 price = _priceOf(p.meme, p.stock);
        if (p.mode == MODE_LUCKY) {
            // meme must rise: price (meme per stock) up means meme gained value
            if (price < FullMath.mulDiv(p.watermark, BPS + p.stepBps, BPS)) revert NoStepReached();
        } else {
            // meme must dip: price (meme per stock) down means meme cheaper
            if (price > FullMath.mulDiv(p.watermark, BPS - p.stepBps, BPS)) revert NoStepReached();
        }

        uint256 swapAmt = FullMath.mulDiv(srcRemaining, p.sellBps, BPS);
        if (swapAmt == 0) revert NotEnoughSrc();

        (address tokenIn, address tokenOut) =
            p.mode == MODE_LUCKY ? (p.meme, p.stock) : (p.stock, p.meme);
        uint256 expectedOut = oracle.consult(tokenIn, swapAmt, tokenOut);
        uint256 minOut = FullMath.mulDiv(expectedOut, BPS - slippageBps, BPS);

        if (!IERC20(tokenIn).approve(address(router), swapAmt)) revert TransferFailed();
        amountOut = router.swap(tokenIn, tokenOut, swapAmt, minOut, address(this));

        p.srcRemaining = srcRemaining - swapAmt;
        p.harvestedOut += amountOut;
        p.harvestCount += 1;
        p.lastHarvestAt = uint64(block.timestamp);
        p.watermark = price;

        uint256 fee = FullMath.mulDiv(amountOut, performanceFeeBps, BPS);
        uint256 tip = FullMath.mulDiv(amountOut, keeperTipBps, BPS);
        if (fee > 0) pendingFees[tokenOut] += fee;
        if (tip > 0) _push(tokenOut, msg.sender, tip);
        p.dstAccrued += amountOut - fee - tip;

        emit Harvested(positionId, msg.sender, swapAmt, amountOut, fee, tip, price, p.watermark);
    }

    /// @notice Claim accumulated output (Stock Token for mode 0 / meme for mode 1).
    function claim(uint256 positionId) external nonReentrant returns (address token, uint256 amount) {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.closed) revert PositionAlreadyClosed();
        amount = p.dstAccrued;
        if (amount == 0) revert NothingToClaim();

        token = p.mode == MODE_LUCKY ? p.stock : p.meme;
        p.dstAccrued = 0;
        _push(token, msg.sender, amount);
        emit Claimed(positionId, msg.sender, token, amount);
    }

    /// @notice Close a position and return all remaining funds.
    /// @param keepNote Keep the BankNote as a redeemed souvenir instead of burning it.
    function closePosition(uint256 positionId, bool keepNote)
        external
        nonReentrant
        returns (uint256 srcReturned, uint256 dstReturned)
    {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.closed) revert PositionAlreadyClosed();

        srcReturned = p.srcRemaining;
        dstReturned = p.dstAccrued;
        address srcToken = p.mode == MODE_LUCKY ? p.meme : p.stock;
        address dstToken = p.mode == MODE_LUCKY ? p.stock : p.meme;

        p.closed = true;
        p.srcRemaining = 0;
        p.dstAccrued = 0;
        openInterestCount[p.meme] -= 1;
        openInterestCount[p.stock] -= 1;

        if (srcReturned > 0) _push(srcToken, msg.sender, srcReturned);
        if (dstReturned > 0) _push(dstToken, msg.sender, dstReturned);
        if (!keepNote) note.burn(positionId);

        emit PositionClosed(positionId, msg.sender, keepNote);
    }

    /// @notice Tune the ladder of an open position.
    function updateConfig(uint256 positionId, uint32 stepBps, uint32 sellBps) external {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        if (p.owner != msg.sender) revert NotPositionOwner();
        if (p.closed) revert PositionAlreadyClosed();
        if (stepBps < MIN_STEP_BPS || stepBps > MAX_STEP_BPS) revert StepOutOfBounds();
        if (sellBps < MIN_SELL_BPS || sellBps > MAX_SELL_BPS) revert SellOutOfBounds();
        p.stepBps = stepBps;
        p.sellBps = sellBps;
        emit ConfigUpdated(positionId, stepBps, sellBps);
    }

    // --------------------------------------------------------------------- admin

    function setFeeConfig(uint32 performanceBps, uint32 keeperBps, uint32 slippage, address treasury_)
        external
        onlyAdmin
    {
        if (performanceBps + keeperBps > 2_000) revert FeesTooHigh();
        if (slippage > 2_000) revert SlippageTooHigh();
        if (treasury_ == address(0)) revert ZeroAddress();
        performanceFeeBps = performanceBps;
        keeperTipBps = keeperBps;
        slippageBps = slippage;
        treasury = treasury_;
        emit FeesUpdated(performanceBps, keeperBps, slippage, treasury_);
    }

    function setOracle(address oracle_) external onlyAdmin {
        if (oracle_ == address(0)) revert ZeroAddress();
        oracle = IPriceOracle(oracle_);
        emit OracleUpdated(oracle_);
    }

    function setRouter(address router_) external onlyAdmin {
        if (router_ == address(0)) revert ZeroAddress();
        router = IExchangeRouter(router_);
        emit RouterUpdated(router_);
    }

    function setNote(address note_) external onlyAdmin {
        if (note_ == address(0)) revert ZeroAddress();
        note = IBankNote(note_);
        emit NoteUpdated(note_);
    }

    /// @param kind 0 = meme whitelist, 1 = stock whitelist.
    function setTokenSupport(uint8 kind, address token, bool supported) external onlyAdmin {
        if (token == address(0)) revert ZeroAddress();
        if (kind == 0) {
            memeAllowed[token] = supported;
            if (supported && !_inList(memeList, token)) memeList.push(token);
        } else {
            stockAllowed[token] = supported;
            if (supported && !_inList(stockList, token)) stockList.push(token);
        }
        emit TokenSupportUpdated(kind, token, supported);
    }

    function setPaused(bool paused_) external onlyRole(ROLE_GUARDIAN) {
        paused = paused_;
        emit PausedSet(paused_);
    }

    function collectFees(address token) external nonReentrant {
        uint256 amount = pendingFees[token];
        if (amount == 0) revert NothingToCollect();
        pendingFees[token] = 0;
        _push(token, treasury, amount);
        emit FeesCollected(token, treasury, amount);
    }

    /// @notice Rescue mis-sent tokens/ETH. Blocked for tokens with open positions.
    function rescue(address token) external onlyAdmin nonReentrant {
        if (token != address(0) && openInterestCount[token] > 0) revert OpenInterestExists(token);
        uint256 amount;
        if (token == address(0)) {
            amount = address(this).balance;
            (bool ok,) = treasury.call{value: amount}("");
            if (!ok) revert TransferFailed();
        } else {
            amount = IERC20(token).balanceOf(address(this));
            _push(token, treasury, amount);
        }
        emit Rescued(token, treasury, amount);
    }

    // --------------------------------------------------------------------- views

    function positionsCount() external view returns (uint256) {
        return _positions.length;
    }

    function positionsOf(address owner) external view returns (uint256[] memory) {
        return _positionsOfOwner[owner];
    }

    function getPosition(uint256 positionId) external view returns (Position memory) {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        return _positions[positionId];
    }

    /// @notice Keeper helper: has the position reached its next trigger?
    function stepStatus(uint256 positionId)
        external
        view
        returns (bool reached, uint256 price, uint256 target)
    {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        price = _priceOf(p.meme, p.stock);
        if (p.mode == MODE_LUCKY) {
            target = FullMath.mulDiv(p.watermark, BPS + p.stepBps, BPS);
            reached = price >= target;
        } else {
            target = FullMath.mulDiv(p.watermark, BPS - p.stepBps, BPS);
            reached = price <= target;
        }
    }

    /// @notice Front-end helper: what the next harvest would swap.
    function previewHarvest(uint256 positionId)
        external
        view
        returns (bool triggered, uint256 srcSwap, uint256 minOut)
    {
        if (positionId >= _positions.length) revert BadPositionId(positionId);
        Position storage p = _positions[positionId];
        (bool reached,,) = this.stepStatus(positionId);
        triggered = reached && !p.closed && p.srcRemaining > 0;
        srcSwap = FullMath.mulDiv(p.srcRemaining, p.sellBps, BPS);
        if (triggered) {
            (address tokenIn, address tokenOut) =
                p.mode == MODE_LUCKY ? (p.meme, p.stock) : (p.stock, p.meme);
            uint256 expectedOut = oracle.consult(tokenIn, srcSwap, tokenOut);
            minOut = FullMath.mulDiv(expectedOut, BPS - slippageBps, BPS);
        }
    }

    // ------------------------------------------------------------------ internals

    /// @dev Price of 1e18 stock, quoted in the meme token (1e18 scale).
    function _priceOf(address meme, address stock) internal view returns (uint256) {
        return oracle.consult(stock, 1e18, meme);
    }

    function _pull(address token, address from, uint256 amount) internal {
        if (!IERC20(token).transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _push(address token, address to, uint256 amount) internal {
        if (!IERC20(token).transfer(to, amount)) revert TransferFailed();
    }

    function _inList(address[] storage list, address token) private view returns (bool) {
        for (uint256 i = 0; i < list.length; i++) {
            if (list[i] == token) return true;
        }
        return false;
    }

    error BadPositionId(uint256 positionId);
}
