// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";

/// @title GoalyPool
/// @notice No-loss prediction markets with a built-in yield engine — no receipt token.
///
///         Players predict by staking a stablecoin **directly** (USDT0 / USDC / USDT); the pool
///         normalises it to USDT0 and supplies it to a Morpho ERC-4626 vault to earn yield. Stakes
///         are **returned in full** at claim (no principal is ever lost); winners additionally split
///         a prize funded by the accrued yield, boosted by the market odds. Claims pay out in the
///         token the winner chooses (USDT0 / USDC / USDT) — deposit USDT, withdraw USDT.
///
///         The Morpho vault is migratable and may hold a different stablecoin than USDT0 (cross-asset
///         backing), swapping through a configurable Uniswap V3 router at the edges. An off-chain
///         WDK agent with MANAGER_ROLE moves the backing to the best risk-adjusted vault.
contract GoalyPool is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    uint256 internal constant BPS = 10_000;

    /// @notice Canonical accounting token (USDT0). Stakes + prizes are denominated in it.
    IERC20 public immutable asset;
    /// @notice Morpho vault the idle stake capital earns in (migratable).
    IERC4626 public yieldVault;
    /// @notice Underlying asset of `yieldVault` — USDT0, or another stablecoin when cross-asset.
    IERC20 public yieldAsset;

    ISwapRouter public swapRouter;
    uint24 public swapFee;
    uint256 public maxSlippageBps;

    uint16 public immutable feeBps;
    /// @notice Odds boost factor in bps (5_000 = 0.5×). Bigger odds → bigger boost.
    uint16 public immutable boostBps;

    /// @notice USDT0 principal currently staked across all open + settled-unclaimed markets.
    uint256 public totalStaked;
    /// @notice USDT0 reserve (harvested yield + top-ups) that funds odds boosts and prizes.
    uint256 public reserve;

    enum Outcome {
        HOME,
        DRAW,
        AWAY
    }

    enum Status {
        NONE,
        OPEN,
        SETTLED
    }

    struct Market {
        uint64 closeTime;
        Status status;
        Outcome result;
        uint256 totalStake;
        uint256 winningStake;
        uint256 prize;
    }

    mapping(bytes32 => Market) public markets;
    mapping(bytes32 => mapping(uint8 => uint256)) public outcomeStake;
    mapping(bytes32 => mapping(address => uint256)) public stakeOf;
    mapping(bytes32 => mapping(address => Outcome)) public pickOf;
    mapping(bytes32 => mapping(address => bool)) public claimed;

    event MarketCreated(bytes32 indexed marketId, uint64 closeTime);
    event PredictionPlaced(
        bytes32 indexed marketId,
        address indexed user,
        Outcome outcome,
        address token,
        uint256 tokenIn,
        uint256 stake
    );
    event MarketSettled(
        bytes32 indexed marketId, Outcome result, uint256 winningStake, uint256 totalStake
    );
    event PrizeFunded(bytes32 indexed marketId, uint256 amount);
    event ReserveFunded(address indexed from, uint256 amount, uint256 reserve);
    event OddsBoostApplied(bytes32 indexed marketId, uint256 winningOddsBps, uint256 boost);
    event YieldHarvested(uint256 amount, uint256 reserve);
    event YieldVaultMigrated(address indexed from, address indexed to, address newAsset);
    event Claimed(
        bytes32 indexed marketId,
        address indexed user,
        address outToken,
        uint256 stakeReturned,
        uint256 prize
    );

    error MarketExists();
    error MarketNotOpen();
    error MarketClosed();
    error AlreadyPredicted();
    error ZeroAmount();
    error ZeroAddress();
    error NotSettled();
    error AlreadyClaimed();
    error NothingStaked();
    error AssetMismatch();

    constructor(
        IERC20 _asset,
        IERC4626 _yieldVault,
        ISwapRouter _swapRouter,
        uint24 _swapFee,
        uint256 _maxSlippageBps,
        uint16 _feeBps,
        uint16 _boostBps
    ) {
        if (_yieldVault.asset() != address(_asset)) revert AssetMismatch();
        if (_feeBps > BPS || _maxSlippageBps > BPS) revert AssetMismatch();
        asset = _asset;
        yieldVault = _yieldVault;
        yieldAsset = _asset;
        swapRouter = _swapRouter;
        swapFee = _swapFee;
        maxSlippageBps = _maxSlippageBps;
        feeBps = _feeBps;
        boostBps = _boostBps;
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(ORACLE_ROLE, msg.sender);
        _grantRole(MANAGER_ROLE, msg.sender);
    }

    // ── Players ──────────────────────────────────────────────────────────────────────────────────

    /// @notice Predict `outcome` on `marketId`, staking `amount` of `token` (USDT0 / USDC / USDT).
    ///         The token is swapped to USDT0 (min `minStake`) and supplied to Morpho; the stake is
    ///         returned in full at claim. One prediction per market per address.
    function placePrediction(
        bytes32 marketId,
        Outcome outcome,
        IERC20 token,
        uint256 amount,
        uint256 minStake
    ) external nonReentrant whenNotPaused returns (uint256 stake) {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        if (block.timestamp >= market.closeTime) revert MarketClosed();
        if (amount == 0) revert ZeroAmount();
        if (stakeOf[marketId][msg.sender] != 0) revert AlreadyPredicted();

        token.safeTransferFrom(msg.sender, address(this), amount);
        stake = address(token) == address(asset)
            ? amount
            : _swapExactIn(token, asset, amount, minStake);
        _deployToYield(stake);

        totalStaked += stake;
        stakeOf[marketId][msg.sender] = stake;
        pickOf[marketId][msg.sender] = outcome;
        outcomeStake[marketId][uint8(outcome)] += stake;
        market.totalStake += stake;
        emit PredictionPlaced(marketId, msg.sender, outcome, address(token), amount, stake);
    }

    /// @notice A winner's prize share in USDT0 (0 for losers / unsettled markets).
    function prizeOf(bytes32 marketId, address user) public view returns (uint256) {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) return 0;
        if (pickOf[marketId][user] != market.result) return 0;
        uint256 stake = stakeOf[marketId][user];
        if (stake == 0 || market.winningStake == 0 || market.prize == 0) return 0;
        uint256 gross = (market.prize * stake) / market.winningStake;
        return gross - (gross * feeBps) / BPS;
    }

    /// @notice Reclaim your stake (always, no-loss) plus your prize (if you won), paid out in
    ///         `outToken` (USDT0 / USDC / USDT). `minOut` guards the payout swap.
    function claim(bytes32 marketId, IERC20 outToken, uint256 minOut)
        external
        nonReentrant
        returns (uint256 stakeReturned, uint256 prize)
    {
        Market storage market = markets[marketId];
        if (market.status != Status.SETTLED) revert NotSettled();
        if (claimed[marketId][msg.sender]) revert AlreadyClaimed();
        stakeReturned = stakeOf[marketId][msg.sender];
        if (stakeReturned == 0) revert NothingStaked();

        claimed[marketId][msg.sender] = true;
        prize = prizeOf(marketId, msg.sender);

        // Principal comes back out of Morpho; the prize is already sitting here as USDT0 (reserve/yield).
        totalStaked -= stakeReturned;
        _redeemFromYield(stakeReturned);
        uint256 usdt0Out = stakeReturned + prize;

        uint256 sent = address(outToken) == address(asset)
            ? usdt0Out
            : _swapExactIn(asset, outToken, usdt0Out, minOut);
        outToken.safeTransfer(msg.sender, sent);
        emit Claimed(marketId, msg.sender, address(outToken), stakeReturned, prize);
    }

    // ── Oracle ───────────────────────────────────────────────────────────────────────────────────

    function createMarket(bytes32 marketId, uint64 closeTime) external onlyRole(ORACLE_ROLE) {
        if (markets[marketId].status != Status.NONE) revert MarketExists();
        markets[marketId] = Market(closeTime, Status.OPEN, Outcome.HOME, 0, 0, 0);
        emit MarketCreated(marketId, closeTime);
    }

    /// @notice Settle a market with its result and the winning outcome's decimal odds (×10_000). An
    ///         odds boost (larger for underdogs) is drawn from the reserve and folded into the prize.
    function settleMarket(bytes32 marketId, Outcome result, uint256 winningOddsBps)
        external
        onlyRole(ORACLE_ROLE)
    {
        Market storage market = markets[marketId];
        if (market.status != Status.OPEN) revert MarketNotOpen();
        market.status = Status.SETTLED;
        market.result = result;
        uint256 winningStake = outcomeStake[marketId][uint8(result)];
        market.winningStake = winningStake;

        uint256 boost = _oddsBoost(winningStake, winningOddsBps);
        if (boost > 0) {
            reserve -= boost;
            market.prize += boost;
            emit OddsBoostApplied(marketId, winningOddsBps, boost);
        }
        emit MarketSettled(marketId, result, winningStake, market.totalStake);
    }

    /// @dev Odds boost = winningStake × (odds − 1) × boostBps, capped by the reserve.
    function _oddsBoost(uint256 winningStake, uint256 winningOddsBps)
        internal
        view
        returns (uint256)
    {
        if (winningStake == 0 || winningOddsBps <= BPS || boostBps == 0) return 0;
        uint256 uncapped = (winningStake * (winningOddsBps - BPS) * boostBps) / (BPS * BPS);
        return uncapped > reserve ? reserve : uncapped;
    }

    /// @notice Fund a market's base prize with USDT0 (e.g. harvested yield).
    function fundPrize(bytes32 marketId, uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        if (markets[marketId].status == Status.NONE) revert MarketNotOpen();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        markets[marketId].prize += amount;
        emit PrizeFunded(marketId, amount);
    }

    /// @notice Top up the odds-boost / prize reserve with USDT0.
    function fundReserve(uint256 amount) external {
        if (amount == 0) revert ZeroAmount();
        asset.safeTransferFrom(msg.sender, address(this), amount);
        reserve += amount;
        emit ReserveFunded(msg.sender, amount, reserve);
    }

    // ── Yield engine ─────────────────────────────────────────────────────────────────────────────

    /// @notice Total value backing staked capital, in yield-asset units (~USD; stablecoins ~1:1).
    function totalAssets() public view returns (uint256) {
        return yieldVault.convertToAssets(yieldVault.balanceOf(address(this)));
    }

    /// @notice Yield accrued above the staked principal (fundable into prizes).
    function accruedYield() public view returns (uint256) {
        uint256 assets = totalAssets();
        return assets > totalStaked ? assets - totalStaked : 0;
    }

    /// @notice Harvest accrued yield out of Morpho into the USDT0 reserve (funds prizes/boosts).
    function harvestYield() external onlyRole(MANAGER_ROLE) nonReentrant returns (uint256 amount) {
        amount = accruedYield();
        if (amount == 0) return 0;
        uint256 got = _redeemFromYield(amount); // yields USDT0 even when cross-asset
        reserve += got;
        emit YieldHarvested(got, reserve);
    }

    // ── Management (WDK agent) ───────────────────────────────────────────────────────────────────

    /// @notice Migrate the backing to `newYieldVault`, swapping the asset if it differs (cross-asset).
    function migrateYieldVault(IERC4626 newYieldVault)
        external
        onlyRole(MANAGER_ROLE)
        nonReentrant
    {
        IERC4626 old = yieldVault;
        IERC20 oldAsset = yieldAsset;
        IERC20 newAsset = IERC20(newYieldVault.asset());

        uint256 held = old.balanceOf(address(this));
        uint256 redeemed = held > 0 ? old.redeem(held, address(this), address(this)) : 0;
        uint256 deployable = redeemed;
        if (address(newAsset) != address(oldAsset) && redeemed > 0) {
            deployable = _swapExactIn(oldAsset, newAsset, redeemed, 0);
        }

        yieldVault = newYieldVault;
        yieldAsset = newAsset;
        if (deployable > 0) {
            newAsset.forceApprove(address(newYieldVault), deployable);
            newYieldVault.deposit(deployable, address(this));
        }
        emit YieldVaultMigrated(address(old), address(newYieldVault), address(newAsset));
    }

    function setSwapConfig(ISwapRouter router, uint24 fee, uint256 maxSlippageBps_)
        external
        onlyRole(MANAGER_ROLE)
    {
        if (address(router) == address(0)) revert ZeroAddress();
        if (maxSlippageBps_ > BPS) revert AssetMismatch();
        swapRouter = router;
        swapFee = fee;
        maxSlippageBps = maxSlippageBps_;
    }

    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ── Internals ────────────────────────────────────────────────────────────────────────────────

    /// @dev Supply `usdt0Amount` of USDT0 to Morpho (swapping into the yield asset if cross-asset).
    function _deployToYield(uint256 usdt0Amount) internal {
        uint256 deployable = address(yieldAsset) == address(asset)
            ? usdt0Amount
            : _swapExactIn(asset, yieldAsset, usdt0Amount, 0);
        yieldAsset.forceApprove(address(yieldVault), deployable);
        yieldVault.deposit(deployable, address(this));
    }

    /// @dev Pull exactly `usdt0Amount` USDT0 back out of Morpho (buying it if cross-asset). Returns
    ///      the USDT0 realised (== usdt0Amount).
    function _redeemFromYield(uint256 usdt0Amount) internal returns (uint256) {
        if (usdt0Amount == 0) return 0;
        if (address(yieldAsset) == address(asset)) {
            yieldVault.withdraw(usdt0Amount, address(this), address(this));
            return usdt0Amount;
        }
        uint256 maxIn = (usdt0Amount * (BPS + maxSlippageBps)) / BPS;
        yieldVault.withdraw(maxIn, address(this), address(this));
        uint256 spent = _swapExactOut(yieldAsset, asset, usdt0Amount, maxIn);
        uint256 leftover = maxIn - spent;
        if (leftover > 0) {
            yieldAsset.forceApprove(address(yieldVault), leftover);
            yieldVault.deposit(leftover, address(this));
        }
        return usdt0Amount;
    }

    function _swapExactIn(IERC20 tokenIn, IERC20 tokenOut, uint256 amountIn, uint256 minOut)
        internal
        returns (uint256 amountOut)
    {
        tokenIn.forceApprove(address(swapRouter), amountIn);
        uint256 floor = (amountIn * (BPS - maxSlippageBps)) / BPS;
        amountOut = swapRouter.exactInputSingle(
            ISwapRouter.ExactInputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountIn: amountIn,
                amountOutMinimum: minOut > floor ? minOut : floor,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function _swapExactOut(IERC20 tokenIn, IERC20 tokenOut, uint256 amountOut, uint256 maxIn)
        internal
        returns (uint256 amountIn)
    {
        tokenIn.forceApprove(address(swapRouter), maxIn);
        amountIn = swapRouter.exactOutputSingle(
            ISwapRouter.ExactOutputSingleParams({
                tokenIn: address(tokenIn),
                tokenOut: address(tokenOut),
                fee: swapFee,
                recipient: address(this),
                deadline: block.timestamp,
                amountOut: amountOut,
                amountInMaximum: maxIn,
                sqrtPriceLimitX96: 0
            })
        );
        tokenIn.forceApprove(address(swapRouter), 0);
    }
}
