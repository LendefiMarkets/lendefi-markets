// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;
/**
 * ═══════════[ Composable Lending Markets ]═══════════
 *
 * ██╗     ███████╗███╗   ██╗██████╗ ███████╗███████╗██╗
 * ██║     ██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝██║
 * ██║     █████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ██║
 * ██║     ██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║
 * ███████╗███████╗██║ ╚████║██████╔╝███████╗██║     ██║
 * ╚══════╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝
 *
 * ═══════════[ Composable Lending Markets ]═══════════
 *
 * @title Lendefi Protocol Core
 * @notice Core lending protocol focused on collateral management and lending calculations
 * @author alexei@lendefimarkets(dot)com
 * @dev Asset-agnostic core - base currency tokenization handled by ERC4626 wrappers
 * @dev Implements a secure and upgradeable collateralized lending protocol with Yield Token
 * @custom:security-contact security@lendefimarkets.com
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {LendefiRates} from "./lib/LendefiRates.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {ILendefiPositionVault} from "../interfaces/ILendefiPositionVault.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {ILendefiMarketVault} from "../interfaces/ILendefiMarketVault.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @custom:oz-upgrades
contract LendefiCore is
    IPROTOCOL,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using Clones for address;
    using SafeERC20 for IERC20;
    using LendefiRates for *;
    using LendefiConstants for *;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // ========== ENUMS ==========
    // Enums are now defined in IPROTOCOL interface to avoid duplication

    // ========== STRUCTS ==========
    // Structs are now defined in IPROTOCOL interface to avoid duplication

    // ========== STATE VARIABLES ==========

    /// @notice Address of the governance token contract
    address public govToken;

    /// @notice Address of the base asset for this market (e.g., USDC)
    address public baseAsset;

    /// @notice Address of the market factory that deployed this instance
    address public marketFactory;

    /// @notice Address of the cloneable vault implementation for user positions
    address public cVault;

    /// @notice Total interest accrued by all borrowers across all positions
    uint256 public totalAccruedBorrowerInterest;

    /// @notice Decimals precision of the base asset (e.g., 1e6 for USDC)
    uint256 public baseDecimals;

    /// @notice Market configuration including core addresses and parameters
    Market internal marketInfo;

    /// @notice Minimum governance tokens required to perform liquidations
    uint256 public liquidatorThreshold;

    /// @notice Interface to the assets module for collateral management and oracles
    IASSETS internal assetsModule;

    /// @notice Interface to the market vault for liquidity management
    ILendefiMarketVault internal baseVault;

    ///////////////////////////////////////////////////////
    // -------------------Mappings ----------------------//
    ///////////////////////////////////////////////////////
    /// @notice Total value locked per asset in USD
    /// @dev EnumerableMap for efficient iteration over all tracked assets
    // EnumerableMap.AddressToUintMap internal assetTVLinUSD;

    /// @notice Total value locked per asset with tracking data
    /// @dev Maps asset address to AssetTracking struct containing tvl, tvlUSD, and lastUpdate
    mapping(address => AssetTracking) internal assetTVL;

    /// @notice User positions storage
    /// @dev Maps user address to array of their positions
    mapping(address => UserPosition[]) internal positions;

    /// @notice Collateral tracking for each position
    /// @dev Maps user => positionId => EnumerableMap of (asset => amount)
    mapping(address => mapping(uint256 => EnumerableMap.AddressToUintMap)) internal positionCollateral;

    /// @notice Storage gap for future upgrades
    /// @dev Reserves storage slots for upgradeable contract pattern
    uint256[10] private __gap;

    // ========== EVENTS AND ERRORS ==========
    // Events and errors are defined in IPROTOCOL interface

    // ========== MODIFIERS ==========

    /// @notice Ensures a position exists for the given user
    /// @param user Address of the position owner
    /// @param positionId Index of the position in user's position array
    modifier validPosition(address user, uint256 positionId) {
        if (positionId >= positions[user].length) revert InvalidPosition();
        _;
    }

    /// @notice Ensures a position exists and is in ACTIVE status
    /// @param user Address of the position owner
    /// @param positionId Index of the position in user's position array
    modifier activePosition(address user, uint256 positionId) {
        if (positionId >= positions[user].length) revert InvalidPosition();
        if (positions[user][positionId].status != PositionStatus.ACTIVE) {
            revert InactivePosition();
        }
        _;
    }

    /// @notice Ensures an asset is whitelisted and active in the protocol
    /// @param asset Address of the asset to validate
    modifier validAsset(address asset) {
        if (!assetsModule.isAssetValid(asset)) revert NotListed();
        _;
    }

    /// @notice Ensures an amount is non-zero
    /// @param amount The amount to validate
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    // ========== CONSTRUCTOR ==========
    /// @notice Disables initializers to prevent implementation contract initialization
    /// @dev Required for UUPS upgradeable pattern security
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========
    /// @notice Initializes the core contract with essential protocol components
    /// @dev Can only be called once during deployment by the factory contract
    /// @param admin Address to receive all administrative roles
    /// @param marketOwner Address of the market owner who will have management privileges
    /// @param govToken_ Address of the governance token contract
    /// @param positionVault Address of the cloneable vault implementation
    function initialize(address admin, address marketOwner, address govToken_, address positionVault)
        external
        initializer
    {
        if (admin == address(0)) revert ZeroAddressNotAllowed();
        if (marketOwner == address(0)) revert ZeroAddressNotAllowed();
        if (govToken_ == address(0)) revert ZeroAddressNotAllowed();
        if (positionVault == address(0)) revert ZeroAddressNotAllowed();

        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(LendefiConstants.PAUSER_ROLE, admin);
        _grantRole(LendefiConstants.PAUSER_ROLE, marketOwner);
        _grantRole(LendefiConstants.UPGRADER_ROLE, admin);

        marketFactory = msg.sender;
        govToken = govToken_;
        cVault = positionVault;
    }

    /**
     * @notice Initializes the market with the provided market info
     * @dev This function handles the initialization of the market, which includes:
     *      1. Validating the market info
     *      2. Setting the market info in the market struct
     *      3. Setting the base asset in the baseAsset struct
     *      4. Setting the base vault in the baseVault struct
     *      5. Setting the baseDecimals value based on the asset decimals
     *      6. Emitting the initialized event
     *
     * The function ensures that the market is initialized successfully and emits the appropriate events.
     *
     * @param _marketInfo Market info to be initialized
     *
     * @custom:requirements
     *   - Market info must be valid
     *   - Base asset must be valid
     *   - Base vault must be valid
     *
     * @custom:state-changes
     *   - Sets the market info in the market struct
     *   - Sets the base asset in the baseAsset struct
     *   - Sets the base vault in the baseVault struct
     *   - Sets the baseDecimals value based on the asset decimals
     *
     * @custom:emits
     *   - Initialized(baseAsset)
     */
    function initializeMarket(Market calldata _marketInfo) external {
        if (msg.sender != marketFactory) revert Unauthorized();

        if (_marketInfo.baseAsset == address(0)) revert ZeroAddressNotAllowed();
        if (_marketInfo.porFeed == address(0)) revert ZeroAddressNotAllowed();
        if (_marketInfo.baseVault == address(0)) revert ZeroAddressNotAllowed();
        if (_marketInfo.core != address(this)) revert ZeroAddressNotAllowed();
        if (_marketInfo.assetsModule == address(0)) revert ZeroAddressNotAllowed();

        marketInfo = _marketInfo;
        baseAsset = marketInfo.baseAsset;
        baseVault = ILendefiMarketVault(marketInfo.baseVault);
        assetsModule = IASSETS(marketInfo.assetsModule);
        uint8 assetDecimals = IERC20Metadata(baseAsset).decimals();
        baseDecimals = 10 ** assetDecimals;

        // Initialize liquidator threshold
        liquidatorThreshold = 20_000 ether; // 20,000 governance tokens

        emit Initialized(marketInfo.baseAsset);
    }

    /**
     * @notice Updates the liquidator threshold (DAO-only)
     * @dev Sets the minimum governance tokens required to perform liquidations
     * @param threshold The new liquidator threshold
     * @custom:access-control Restricted to DEFAULT_ADMIN_ROLE
     * @custom:events Emits a LiquidatorThresholdUpdated event
     * @custom:error-cases
     *   - InvalidLiquidatorThreshold: Thrown when threshold is below minimum
     */
    function setLiquidatorThreshold(uint256 threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (threshold < 10 ether) revert InvalidLiquidatorThreshold();

        liquidatorThreshold = threshold;

        emit LiquidatorThresholdUpdated(threshold);
    }

    /**
     * @notice Supplies liquidity to the protocol
     * @dev This function handles the supply of liquidity to the protocol, which includes:
     *      1. Validating the amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Transferring tokens from user to this contract
     *      4. Approving vault to spend tokens
     *      5. Previewing the deposit amount
     *      6. Slippage protection on shares received
     *      7. Updating the liquidity accrue time index
     *      8. Emitting the supply liquidity event
     *      9. Depositing the liquidity into the base vault
     *
     * The function ensures that the liquidity is supplied successfully and emits the appropriate events.
     *
     * @param amount Amount of base asset to supply
     * @param expectedShares Expected shares to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Amount must be valid
     *   - Expected shares must be valid
     *   - Max slippage must be valid
     *
     * @custom:state-changes
     *   - Updates the liquidity accrue time index
     *   - Deposits the liquidity into the base vault
     *
     * @custom:emits
     *   - DepositLiquidity(msg.sender, amount)
     */
    function depositLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        // Cache state variables to avoid multiple SLOADs
        address cachedBaseAsset = baseAsset;
        ILendefiMarketVault cachedBaseVault = baseVault;

        // Transfer tokens from user to this contract
        IERC20(cachedBaseAsset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve vault to spend tokens
        IERC20(cachedBaseAsset).forceApprove(address(cachedBaseVault), amount);

        emit DepositLiquidity(msg.sender, amount);
        uint256 sharesOut = cachedBaseVault.deposit(amount, msg.sender);
        _validateSlippage(sharesOut, expectedShares, maxSlippageBps);
    }

    /**
     * @notice Mints shares for the LP
     * @dev This function handles the minting of shares for the user, which includes:
     *      1. Validating the shares amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on base asset received
     *      4. Updating the liquidity accrue time index
     *      5. Minting shares from the vault
     *
     * @param shares Amount of shares to mint
     * @param expectedAmount Expected amount of base asset to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function mintShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps)
        external
        validAmount(shares)
        nonReentrant
        whenNotPaused
    {
        address cachedBaseAsset = baseAsset;
        ILendefiMarketVault cachedBaseVault = baseVault;
        // Calculate required assets for minting shares
        uint256 assets = cachedBaseVault.previewMint(shares);

        // Transfer tokens from user to this contract
        IERC20(cachedBaseAsset).safeTransferFrom(msg.sender, address(this), assets);

        // Approve vault to spend tokens
        IERC20(cachedBaseAsset).forceApprove(address(cachedBaseVault), assets);

        // Mint shares from vault
        uint256 actualAmount = cachedBaseVault.mint(shares, msg.sender);
        _validateSlippage(actualAmount, expectedAmount, maxSlippageBps);
        emit MintShares(msg.sender, shares);
    }

    /**
     * @notice Redeems shares for base asset from the protocol
     * @dev This function handles the redemption of shares from the protocol, which includes:
     *      1. Validating the shares amount and expected value
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on base asset received
     *      4. Updating the liquidity accrue time index
     *      5. Redeeming from the vault
     *
     * @param shares Amount of shares to redeem
     * @param expectedAmount Expected amount of base asset to receive
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function redeemLiquidityShares(uint256 shares, uint256 expectedAmount, uint32 maxSlippageBps)
        external
        validAmount(shares)
        nonReentrant
        whenNotPaused
    {
        // Withdraw from vault - tokens go directly to user
        uint256 actualAmount = baseVault.redeem(shares, msg.sender, msg.sender);
        // Slippage protection on base asset received
        _validateSlippage(actualAmount, expectedAmount, maxSlippageBps);
        emit RedeemShares(msg.sender, shares, actualAmount);
    }

    /**
     * @notice Withdraws a specific amount of base asset from the protocol
     * @dev This function handles the withdrawal of a specific amount of base asset from the protocol, which includes:
     *      1. Validating the amount and expected shares
     *      2. Preventing MEV attacks via liquidity accrue time index
     *      3. Slippage protection on shares burned
     *      4. Updating the liquidity accrue time index
     *      5. Withdrawing from the vault
     *
     * @param amount Amount of base asset to withdraw
     * @param expectedShares Expected number of shares to burn
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function withdrawLiquidity(uint256 amount, uint256 expectedShares, uint32 maxSlippageBps)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        // Withdraw from vault - tokens go directly to user
        uint256 actualShares = baseVault.withdraw(amount, msg.sender, msg.sender);
        _validateSlippage(actualShares, expectedShares, maxSlippageBps);
        emit WithdrawLiquidity(msg.sender, amount);
    }

    // ========== POSITION MANAGEMENT ==========
    /**
     * @notice Creates a new position for the user
     * @dev This function handles the creation of a new position, which includes:
     *      1. Validating the asset and position limit
     *      2. Creating a new position in the positions array
     *      3. Creating a new vault for the position
     *      4. Setting the position status to ACTIVE
     *      5. Emitting the position created event
     *
     * The function ensures that the position is created successfully and emits the appropriate events.
     *
     * @param asset Address of the asset to be used in the position
     * @param isIsolated Boolean indicating whether the position is isolated
     * @return positionId The unique identifier for the newly created position
     *
     * @custom:requirements
     *   - Asset must be valid
     *   - User must not exceed the maximum position limit
     *
     * @custom:state-changes
     *   - Creates a new position in the positions array
     *   - Creates a new vault for the position
     *   - Sets the position status to ACTIVE
     *
     * @custom:emits
     *   - PositionCreated(msg.sender, positionId, isIsolated)
     */
    function createPosition(address asset, bool isIsolated)
        external
        validAsset(asset)
        nonReentrant
        whenNotPaused
        returns (uint256 positionId)
    {
        if (positions[msg.sender].length >= 1000) {
            revert MaxPositionLimitReached();
        } // Max position limit
        UserPosition storage newPosition = positions[msg.sender].push();
        positionId = positions[msg.sender].length - 1;

        address vault = Clones.clone(cVault);
        // Verify clone was successful
        if (vault == address(0)) revert CloneDeploymentFailed();
        if (vault.code.length == 0) revert CloneDeploymentFailed();
        ILendefiPositionVault(vault).initialize(address(this), msg.sender);

        newPosition.vault = vault;
        newPosition.isIsolated = isIsolated;
        newPosition.status = PositionStatus.ACTIVE;

        if (isIsolated) {
            EnumerableMap.AddressToUintMap storage collaterals =
                positionCollateral[msg.sender][positions[msg.sender].length - 1];
            collaterals.set(asset, 0); // Register the asset with zero initial amount
        }

        emit VaultCreated(msg.sender, positionId, vault);
        emit PositionCreated(msg.sender, positionId, isIsolated);
    }

    /**
     * @notice Exits a position by repaying the debt and withdrawing all collateral
     * @dev This function handles the complete exit of a position, which includes:
     *      1. Repaying the debt via _processRepay (validation and state updates)
     *      2. Setting the position status to CLOSED
     *      3. Transferring the assets from the protocol to the caller
     *      4. Emitting the position closed event
     *
     * The function ensures that the position is repaid in full and all collateral is withdrawn.
     *
     * @param positionId ID of the position to exit
     * @param expectedDebt Expected debt amount before repayment
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the repayment amount
     *   - Position must remain sufficiently collateralized after repayment
     *
     * @custom:state-changes
     *   - Sets position.status to CLOSED
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - PositionClosed(msg.sender, positionId)
     */
    function exitPosition(uint256 positionId, uint256 expectedDebt, uint32 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        uint256 actualAmount = _processRepay(positionId, type(uint256).max, position, expectedDebt, maxSlippageBps);
        position.status = PositionStatus.CLOSED;
        if (actualAmount > 0) {
            // Transfer from user to core
            IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), actualAmount);
            // Approve vault to pull tokens
            IERC20(baseAsset).forceApprove(address(baseVault), actualAmount);
            // Repay to vault
            baseVault.repay(actualAmount, msg.sender);
        }

        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];
        address vault = positions[msg.sender][positionId].vault;

        // Cache vault reference only to reduce stack depth
        ILendefiPositionVault cachedVault = ILendefiPositionVault(vault);

        // Process all assets before clearing the mapping
        uint256 length = collaterals.length();
        for (uint256 i = 0; i < length; i++) {
            (address asset, uint256 amount) = collaterals.at(i);

            if (amount > 0) {
                uint256 newTVL = assetTVL[asset].tvl - amount;
                assetTVL[asset] = AssetTracking({
                    tvl: newTVL,
                    tvlUSD: assetsModule.updateAssetPoRFeed(asset, newTVL),
                    lastUpdate: block.timestamp
                });
                emit TVLUpdated(asset, newTVL);
                emit WithdrawCollateral(msg.sender, positionId, asset, amount);
                cachedVault.withdrawToken(asset, amount);
            }
        }

        // Clear all entries at once
        collaterals.clear();
        emit PositionClosed(msg.sender, positionId);
    }

    /**
     * @notice Supplies collateral assets to a position
     * @dev This function handles adding collateral to an existing position, which includes:
     *      1. Processing the deposit via _processDeposit (validation and state updates)
     *      2. Emitting the supply event
     *      3. Transferring the assets from the caller to the protocol
     *
     * The collateral can be used to either open new borrowing capacity or
     * strengthen the collateralization ratio of an existing debt position.
     *
     * For isolated positions, only the initial asset type can be supplied.
     * For cross-collateral positions, multiple asset types can be added
     * (up to a maximum of 20 different assets per position).
     *
     * @param asset Address of the collateral asset to supply
     * @param amount Amount of the asset to supply as collateral
     * @param positionId ID of the position to receive the collateral
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Asset must be whitelisted in the protocol
     *   - Asset must not be at its global capacity limit
     *   - For isolated positions: asset must match the position's initial asset
     *   - For isolated assets: position must be in isolation mode
     *   - Position must have fewer than 20 different asset types (if adding a new asset type)
     *
     * @custom:state-changes
     *   - Increases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Adds asset to positionCollateralAssets[msg.sender][positionId] if not already present
     *   - Updates protocol-wide TVL for the asset
     *   - Transfers asset tokens from msg.sender to the contract
     *
     * @custom:emits
     *   - SupplyCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - NotListed: Thrown when asset is not whitelisted
     *   - AssetCapacityReached: Thrown when asset has reached global capacity limit
     *   - IsolatedAssetViolation: Thrown when supplying isolated-tier asset to a cross position
     *   - InvalidAssetForIsolation: Thrown when supplying an asset that doesn't match the isolated position's asset
     *   - MaximumAssetsReached: Thrown when position already has 20 different asset types
     */
    function supplyCollateral(address asset, uint256 amount, uint256 positionId)
        external
        validAmount(amount)
        nonReentrant
        whenNotPaused
    {
        _processDeposit(asset, amount, positionId);
        address vault = positions[msg.sender][positionId].vault;
        emit SupplyCollateral(msg.sender, positionId, asset, amount);
        IERC20(asset).safeTransferFrom(msg.sender, vault, amount);
    }

    /**
     * @notice Withdraws collateral assets from a position
     * @dev This function handles removing collateral from an existing position, which includes:
     *      1. MEV protection via position timestamp checking
     *      2. Processing the withdrawal via _processWithdrawal (validation and state updates)
     *      3. Slippage protection on collateral value changes
     *      4. Emitting the withdrawal event
     *      5. Transferring the assets from the protocol to the caller
     *
     * The function ensures that the position remains sufficiently collateralized
     * after the withdrawal by checking that the remaining credit limit exceeds
     * the outstanding debt.
     *
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw
     * @param positionId ID of the position from which to withdraw
     * @param expectedCreditLimit Expected credit limit after withdrawal for slippage protection
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - No same-block operations allowed (MEV protection)
     *   - For isolated positions: asset must match the position's initial asset
     *   - Current balance must be greater than or equal to the withdrawal amount
     *   - Position must remain sufficiently collateralized after withdrawal
     *   - Credit limit after withdrawal must not deviate beyond slippage tolerance
     *
     * @custom:state-changes
     *   - Updates position.lastInterestAccrual to current block timestamp
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - WithdrawCollateral(msg.sender, positionId, asset, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - MEVSameBlockOperation: Thrown when attempting multiple operations in same block
     *   - InvalidAssetForIsolation: Thrown when withdrawing an asset that doesn't match the isolated position's asset
     *   - LowBalance: Thrown when not enough collateral balance to withdraw
     *   - CreditLimitExceeded: Thrown when withdrawal would leave position undercollateralized
     *   - MEVSlippageExceeded: Thrown when credit limit deviates beyond slippage tolerance
     */
    function withdrawCollateral(
        address asset,
        uint256 amount,
        uint256 positionId,
        uint256 expectedCreditLimit,
        uint32 maxSlippageBps
    ) external validAmount(amount) activePosition(msg.sender, positionId) nonReentrant whenNotPaused {
        UserPosition storage position = positions[msg.sender][positionId];

        // MEV protection: prevent same-block operations
        if (position.lastInterestAccrual >= block.timestamp) {
            revert MEVSameBlockOperation();
        }
        position.lastInterestAccrual = block.timestamp;
        // Slippage protection on credit limit
        uint256 creditLimit = calculateCreditLimit(msg.sender, positionId);
        _validateSlippage(creditLimit, expectedCreditLimit, maxSlippageBps);

        _processWithdrawal(asset, amount, positionId);

        // Transfer from vault to user
        address vault = position.vault;
        ILendefiPositionVault(vault).withdrawToken(asset, amount);
        emit WithdrawCollateral(msg.sender, positionId, asset, amount);
    }

    /**
     * @notice Borrows assets from the protocol
     * @dev This function handles the borrowing of assets from the protocol, which includes:
     *      1. Validating the amount and expected credit limit
     *      2. Preventing MEV attacks via last interest accrual
     *      3. Calculating the current debt with interest
     *      4. Slippage protection on debt amount
     *      5. Updating the last interest accrual
     *      6. Emitting the borrow event
     *      7. Transferring the assets from the protocol to the caller
     *
     * The function ensures that the assets are borrowed successfully and emits the appropriate events.
     *
     * @param positionId ID of the position to borrow from
     * @param amount Amount of assets to borrow
     * @param expectedCreditLimit Expected credit limit before borrowing
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Amount must be valid
     *   - Expected credit limit must be valid
     *   - Max slippage must be valid
     *
     * @custom:state-changes
     *   - Updates the last interest accrual
     *   - Transfers assets from the protocol to msg.sender
     *
     * @custom:emits
     *   - Borrow(msg.sender, positionId, amount)
     */
    function borrow(uint256 positionId, uint256 amount, uint256 expectedCreditLimit, uint32 maxSlippageBps)
        external
        validAmount(amount)
        activePosition(msg.sender, positionId)
        nonReentrant
        whenNotPaused
    {
        _processBorrow(msg.sender, positionId, amount, expectedCreditLimit, maxSlippageBps);
        emit Borrow(msg.sender, positionId, amount);
        baseVault.borrow(amount, msg.sender);
    }

    // ========== REPAYMENT FUNCTIONS ==========
    /**
     * @notice Repays a borrow position
     * @dev This function handles repaying a borrow position, which includes:
     *      1. Processing the repayment via _processRepay (validation and state updates)
     *      2. Emitting the repayment event
     *      3. Transferring the assets from the caller to the protocol
     *
     * The function ensures that the position remains sufficiently collateralized
     * after the repayment by checking that the remaining credit limit exceeds
     * the outstanding debt.
     *
     * @param positionId ID of the position to repay
     * @param amount Amount of the asset to repay
     * @param expectedDebt Expected debt amount before repayment
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the repayment amount
     *   - Position must remain sufficiently collateralized after repayment
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - Repay(msg.sender, positionId, amount)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - ZeroAmount: Thrown when amount is zero
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - LowBalance: Thrown when not enough collateral balance to repay
     *   - CreditLimitExceeded: Thrown when repayment would leave position undercollateralized
     */
    function repay(uint256 positionId, uint256 amount, uint256 expectedDebt, uint32 maxSlippageBps)
        external
        nonReentrant
        whenNotPaused
    {
        UserPosition storage position = positions[msg.sender][positionId];
        uint256 actualAmount = _processRepay(positionId, amount, position, expectedDebt, maxSlippageBps);
        if (actualAmount > 0) {
            // Transfer from user to core
            IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), actualAmount);
            // Approve vault to pull tokens
            IERC20(baseAsset).forceApprove(address(baseVault), actualAmount);
            // Repay to vault
            baseVault.repay(actualAmount, msg.sender);
        }
    }

    /**
     * @dev Liquidates a borrow position
     * @param user Address of the user
     * @param positionId ID of the position to liquidate
     * @param expectedCost Expected liquidation cost
     * @param maxSlippageBps Maximum slippage percentage allowed
     *
     * @custom:requirements
     *   - Protocol must not be paused
     *   - Position must exist and be in ACTIVE status
     *   - Current balance must be greater than or equal to the liquidation cost
     *   - Position must remain sufficiently collateralized after liquidation
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Updates protocol-wide TVL for the asset
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Transfers asset tokens from the contract to msg.sender
     *
     * @custom:emits
     *   - Liquidated(msg.sender, positionId)
     *
     * @custom:access-control Available to position owners when protocol is not paused
     * @custom:error-cases
     *   - NotEnoughGovernanceTokens: Thrown when caller doesn't have enough governance tokens
     *   - NotLiquidatable: Thrown when position's health factor is above 1.0
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     */
    function liquidate(address user, uint256 positionId, uint256 expectedCost, uint32 maxSlippageBps)
        external
        activePosition(user, positionId)
        nonReentrant
        whenNotPaused
    {
        if (IERC20(govToken).balanceOf(msg.sender) < liquidatorThreshold) {
            revert NotEnoughGovernanceTokens();
        }
        if (!isLiquidatable(user, positionId)) revert NotLiquidatable();

        uint256 totalCost = _processLiquidation(user, positionId, expectedCost, maxSlippageBps);

        // Transfer liquidation payment from liquidator
        IERC20(baseAsset).safeTransferFrom(msg.sender, address(this), totalCost);
        // Repay the debt
        IERC20(baseAsset).forceApprove(address(baseVault), totalCost);
        baseVault.repay(totalCost, user);
    }

    /**
     * @notice Gets the total amount of debt currently outstanding in the protocol
     * @dev Tracks total debt including accrued interest
     * @return The total amount of debt outstanding
     */
    function totalBorrow() external view returns (uint256) {
        return baseVault.totalBorrow();
    }

    /**
     * @notice Calculates the current debt including accrued interest for a position
     * @dev Uses the appropriate interest rate based on the position's collateral tier
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate debt for
     * @return The total debt amount including principal and accrued interest
     */
    function calculateDebtWithInterest(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        UserPosition storage position = positions[user][positionId];
        if (position.debtAmount == 0) return 0;

        IASSETS.CollateralTier tier = getPositionTier(user, positionId);
        uint256 borrowRate = getBorrowRate(tier);
        uint256 timeElapsed = block.timestamp - position.lastInterestAccrual;

        return LendefiRates.calculateDebtWithInterest(position.debtAmount, borrowRate, timeElapsed, baseDecimals);
    }

    /**
     * @notice Calculates the credit limit for a position
     * @dev Uses the appropriate interest rate based on the position's collateral tier
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate credit limit for
     * @return The credit limit for the position
     */
    function calculateCreditLimit(address user, uint256 positionId) public view returns (uint256) {
        (, uint256 liqLevel,) = calculateLimits(user, positionId);
        return liqLevel;
    }

    /**
     * @notice Calculates the total USD value of all collateral in a position
     * @dev Uses oracle prices to convert collateral amounts to USD value
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate value for
     * @return value - The total USD value of all collateral assets in the position
     */
    function calculateCollateralValue(address user, uint256 positionId) public view returns (uint256 value) {
        (,, value) = calculateLimits(user, positionId);
    }

    /**
     * @notice Calculates the health factor of a position
     * @dev Health factor is the ratio of weighted collateral to debt, below 1.0 is liquidatable
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate health for
     * @return The position's health factor in baseDecimals format (1.0 = 1e6)
     * @custom:error-cases
     *   - InvalidPosition: Thrown when position doesn't exist
     */
    function healthFactor(address user, uint256 positionId) public view returns (uint256) {
        uint256 debt = calculateDebtWithInterest(user, positionId);
        if (debt == 0) return type(uint256).max;
        (, uint256 liqLevel,) = calculateLimits(user, positionId);
        return Math.mulDiv(liqLevel, baseDecimals, debt, Math.Rounding.Floor);
    }

    /**
     * @notice Calculates the credit limit, liquidation level, and collateral value for a position
     * @dev Uses oracle prices to convert collateral amounts to USD value
     * @param user Address of the position owner
     * @param positionId ID of the position to calculate limits for
     * @return credit - The maximum amount of USDC that can be borrowed against the position
     * @return liqLevel - The collateral value level where liquidation will occur
     * @return value - The total USD value of all collateral assets in the position
     */
    function calculateLimits(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256 credit, uint256 liqLevel, uint256 value)
    {
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[user][positionId];
        uint256 len = collaterals.length();

        // Early exit for empty positions
        if (len == 0) return (0, 0, 0);

        // Cache base asset params to avoid repeated calls
        IASSETS.AssetCalculationParams memory paramsBase = assetsModule.getAssetCalculationParams(baseAsset);

        for (uint256 i; i < len; i++) {
            (address asset, uint256 amount) = collaterals.at(i);
            if (amount == 0) continue;

            IASSETS.AssetCalculationParams memory params = assetsModule.getAssetCalculationParams(asset);

            // Use Math.mulDiv for maximum precision without overflow
            // First calculate the base value conversion
            uint256 assetValueInbaseDecimals =
                Math.mulDiv(amount * params.price, baseDecimals, paramsBase.price * (10 ** params.decimals));

            value += assetValueInbaseDecimals;

            // Calculate credit with full precision using mulDiv
            credit += Math.mulDiv(assetValueInbaseDecimals, params.borrowThreshold, 1000);

            // Calculate liquidation level with full precision using mulDiv
            liqLevel += Math.mulDiv(assetValueInbaseDecimals, params.liquidationThreshold, 1000);
        }
    }

    /**
     * @notice Gets the number of positions owned by a user
     * @dev Includes all positions regardless of status (active, closed, liquidated)
     * @param user Address of the user to query
     * @return The number of positions created by the user
     */
    function getUserPositionsCount(address user) public view returns (uint256) {
        return positions[user].length;
    }

    /**
     * @notice Gets all positions owned by a user
     * @dev Returns the full array of position structs for the user
     * @param user Address of the user to query
     * @return Array of UserPosition structs for all the user's positions
     */
    function getUserPositions(address user) public view returns (UserPosition[] memory) {
        return positions[user];
    }

    /**
     * @notice Gets a specific position for a user
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return The user position data
     */
    function getUserPosition(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (UserPosition memory)
    {
        return positions[user][positionId];
    }

    /**
     * @notice Gets the liquidation fee percentage for a position
     * @dev Based on the highest risk tier among the position's collateral assets
     * @param user Address of the position owner
     * @param positionId ID of the position to query
     * @return The liquidation fee percentage in baseDecimals format (e.g., 0.05e6 = 5%)
     */
    function getPositionLiquidationFee(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        IASSETS.CollateralTier tier = getPositionTier(user, positionId);
        return assetsModule.getLiquidationFee(tier);
    }

    /**
     * @notice Determines the collateral tier of a position
     * @dev For cross-collateral positions, returns the highest risk tier among assets
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return tier The position's collateral tier (STABLE, CROSS_A, CROSS_B, or ISOLATED)
     */
    function getPositionTier(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (IASSETS.CollateralTier tier)
    {
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[user][positionId];
        uint256 len = collaterals.length();
        tier = IASSETS.CollateralTier.STABLE;

        for (uint256 i; i < len; i++) {
            (address asset, uint256 amount) = collaterals.at(i);

            if (amount > 0) {
                IASSETS.CollateralTier assetTier = assetsModule.getAssetTier(asset);
                if (uint8(assetTier) > uint8(tier)) {
                    tier = assetTier;
                }
            }
        }
    }

    /**
     * @notice Returns the market information
     * @return The market configuration struct
     */
    function market() public view returns (Market memory) {
        return marketInfo;
    }

    /**
     * @notice Returns the collateral assets for a specific position
     * @param user The address of the position owner
     * @param positionId The ID of the position
     * @return An array of collateral assets
     */
    function getPositionCollateralAssets(address user, uint256 positionId)
        public
        view
        validPosition(user, positionId)
        returns (address[] memory)
    {
        return positionCollateral[user][positionId].keys();
    }

    /**
     * @notice Gets the collateral amount for a specific asset in a position
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param asset Address of the collateral asset
     * @return The amount of the specified asset in the position
     */
    function getCollateralAmount(address user, uint256 positionId, address asset)
        public
        view
        validPosition(user, positionId)
        returns (uint256)
    {
        (bool exists, uint256 amount) = positionCollateral[user][positionId].tryGet(asset);
        return exists ? amount : 0;
    }

    /**
     * @notice Gets the asset tracking data for a specific asset
     * @param asset Address of the asset to query
     * @return tvl Total value locked in native token units
     * @return tvlUSD Total value locked in USD
     * @return lastUpdate Timestamp of last update
     */
    function getAssetTVL(address asset) public view returns (uint256 tvl, uint256 tvlUSD, uint256 lastUpdate) {
        AssetTracking memory tracking = assetTVL[asset];
        return (tracking.tvl, tracking.tvlUSD, tracking.lastUpdate);
    }

    /**
     * @notice Calculates the current supply interest rate for liquidity providers
     * @dev Based on utilization, protocol fees, and available liquidity
     * @return The current annual supply interest rate in baseDecimals format
     */
    function getSupplyRate() public view returns (uint256) {
        return baseVault.getSupplyRate();
    }

    /**
     * @notice Calculates the current borrow interest rate for a specific collateral tier
     * @dev Based on utilization, base rate, supply rate, and tier-specific jump rate
     * @param tier The collateral tier to calculate the borrow rate for
     * @return The current annual borrow interest rate in baseDecimals format
     */
    function getBorrowRate(IASSETS.CollateralTier tier) public view returns (uint256) {
        return baseVault.getBorrowRate(tier);
    }

    /**
     * @notice Determines if a position is eligible for liquidation
     * @dev Checks if health factor is below 1.0, indicating undercollateralization
     * @param user Address of the position owner
     * @param positionId ID of the position to check
     * @return True if the position can be liquidated, false otherwise
     */
    function isLiquidatable(address user, uint256 positionId)
        public
        view
        activePosition(user, positionId)
        returns (bool)
    {
        if (positions[user][positionId].debtAmount == 0) return false;
        // Use the health factor which properly accounts for liquidation thresholds
        // Health factor < 1.0 means position is undercollateralized based on liquidation parameters
        uint256 healthFactorValue = healthFactor(user, positionId);

        // Compare against baseDecimals (1.0 in fixed-point representation)
        return healthFactorValue < baseDecimals;
    }

    /**
     * @notice Checks if the protocol is solvent based on total asset value and borrow amount
     * @dev Ensures that the total asset value exceeds the total borrow amount
     * @return isProtocolSolvent True if the protocol is solvent, false otherwise
     * @return totalAssetValue Total value of all assets in the protocol (base asset + collateral)
     */
    function isCollateralized() public view returns (bool isProtocolSolvent, uint256 totalAssetValue) {
        uint256 totalBorrowAmount = baseVault.totalBorrow();

        // Start with base vault assets minus borrowed amount
        totalAssetValue = baseVault.totalAssets() - totalBorrowAmount;

        // Iterate through all listed assets to get their USD values
        address[] memory listedAssets = assetsModule.getListedAssets();
        uint256 len = listedAssets.length;
        for (uint256 i = 0; i < len; i++) {
            (, uint256 tvlUSD,) = getAssetTVL(listedAssets[i]);
            totalAssetValue += tvlUSD;
        }

        return (totalAssetValue >= totalBorrowAmount, totalAssetValue);
    }

    // ========== INTERNAL FUNCTIONS ==========

    /**
     * @notice Processes liquidation logic
     * @dev Internal function to handle liquidation to avoid stack too deep
     * @param user Address of the position owner
     * @param positionId ID of the position to liquidate
     * @param expectedCost Expected liquidation cost
     * @param maxSlippageBps Maximum slippage percentage allowed
     * @return totalCost Total cost of liquidation including fees
     */
    function _processLiquidation(address user, uint256 positionId, uint256 expectedCost, uint32 maxSlippageBps)
        internal
        returns (uint256 totalCost)
    {
        UserPosition storage position = positions[user][positionId];

        // Cache vault address before position is modified
        address cachedVault = position.vault;

        // Accrue interest for this position
        uint256 debtWithInterest;
        uint256 cachedDebtAmount = position.debtAmount;
        if (cachedDebtAmount > 0) {
            debtWithInterest = calculateDebtWithInterest(user, positionId);
            uint256 accruedInterest = debtWithInterest - cachedDebtAmount;

            if (accruedInterest > 0) {
                totalAccruedBorrowerInterest += accruedInterest;
                position.lastInterestAccrual = block.timestamp;
                emit InterestAccrued(user, positionId, accruedInterest);
            }
        }

        uint256 liquidationFee = getPositionLiquidationFee(user, positionId);
        uint256 fee = Math.mulDiv(debtWithInterest, liquidationFee, baseDecimals, Math.Rounding.Floor);
        totalCost = debtWithInterest + fee;

        // Slippage protection on total liquidation cost
        _validateSlippage(totalCost, expectedCost, maxSlippageBps);

        // Clear position debt
        position.debtAmount = 0;
        position.status = PositionStatus.LIQUIDATED;

        // Get collateral assets before clearing
        address[] memory collateralAssets = getPositionCollateralAssets(user, positionId);

        // Transfer all assets from vault to liquidator using cached vault address
        ILendefiPositionVault(cachedVault).liquidate(collateralAssets, msg.sender);
        // Clear all collateral assets
        positionCollateral[user][positionId].clear();

        emit Liquidated(user, positionId, msg.sender);
    }

    /**
     * @notice Processes collateral deposit operations with validation and state updates
     * @dev Internal function that handles the core logic for adding collateral to a position,
     *      enforcing protocol rules about isolation mode, asset capacity limits, and asset counts.
     *      This function is called by both supplyCollateral and interpositionalTransfer.
     *
     * The function performs several validations to ensure the deposit complies with
     * protocol rules:
     * 1. Verifies the asset hasn't reached its global capacity limit
     * 2. Enforces isolation mode rules (isolated assets can't be added to cross positions)
     * 3. Ensures isolated positions only contain a single asset type
     * 4. Limits positions to a maximum of 20 different asset types
     *
     * @param asset Address of the collateral asset to deposit
     * @param amount Amount of the asset to deposit (in the asset's native units)
     * @param positionId ID of the position to receive the collateral
     *
     * @custom:requirements
     *   - Asset must be whitelisted in the protocol (validated by validAsset modifier)
     *   - Position must exist and be in ACTIVE status (validated by activePosition modifier)
     *   - Asset must not be at its global capacity limit
     *   - For isolated assets: position must not be a cross-collateral position
     *   - For isolated positions: asset must match the position's initial asset (if any exists)
     *   - Position must have fewer than 20 different asset types (if adding a new asset type)
     *
     * @custom:state-changes
     *   - Adds asset to positionCollateralAssets[msg.sender][positionId] if not already present
     *   - Increases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - Increases global assetTVL[asset] by amount
     *
     * @custom:emits
     *   - TVLUpdated(asset, newTVL)
     *
     * @custom:error-cases
     *   - NotListed: Thrown when asset is not whitelisted
     *   - InvalidPosition: Thrown when position doesn't exist
     *   - InactivePosition: Thrown when position is not in ACTIVE status
     *   - AssetCapacityReached: Thrown when asset has reached its global capacity limit
     *   - IsolatedAssetViolation: Thrown when supplying isolated-tier asset to a cross position
     *   - InvalidAssetForIsolation: Thrown when asset doesn't match isolated position's asset
     *   - MaximumAssetsReached: Thrown when position already has 20 different asset types
     */
    function _processDeposit(address asset, uint256 amount, uint256 positionId)
        internal
        validAsset(asset)
        activePosition(msg.sender, positionId)
    {
        uint256 tvl = assetTVL[asset].tvl;
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];

        // Early capacity check using direct access
        if (assetsModule.isAssetAtCapacity(asset, amount, tvl)) {
            revert AssetCapacityReached();
        }

        // Handle isolation checks in one block
        if (
            assetsModule.getAssetTier(asset) == IASSETS.CollateralTier.ISOLATED
                && !positions[msg.sender][positionId].isIsolated
        ) {
            revert IsolatedAssetViolation();
        }

        // Check asset isolation for isolated positions
        if (positions[msg.sender][positionId].isIsolated && collaterals.length() > 0) {
            (address firstAsset,) = collaterals.at(0);
            if (asset != firstAsset) revert InvalidAssetForIsolation();
        }

        // Process collateral with capacity check
        (bool exists, uint256 currentAmount) = collaterals.tryGet(asset);
        if (!exists && collaterals.length() >= 20) {
            revert MaximumAssetsReached();
        }

        uint256 newAmount = exists ? currentAmount + amount : amount;
        if (assetsModule.poolLiquidityLimit(asset, newAmount)) {
            revert PoolLiquidityLimitReached();
        }

        // Update collateral
        collaterals.set(asset, newAmount);

        // Update TVL in single operation
        uint256 newTVL = tvl + amount;
        assetTVL[asset] = AssetTracking({
            tvl: newTVL,
            tvlUSD: assetsModule.updateAssetPoRFeed(asset, newTVL),
            lastUpdate: block.timestamp
        });

        emit TVLUpdated(asset, newTVL);
    }

    /**
     * @notice Processes a collateral withdrawal operation with validation and state updates
     * @dev Internal function that handles the core logic for removing collateral from a position,
     *      enforcing position solvency and validating withdrawal amounts.
     *      This function is called by both withdrawCollateral and interpositionalTransfer.
     *
     * The function performs several validations to ensure the withdrawal complies with
     * protocol rules:
     * 1. For isolated positions, verifies the asset matches the position's designated asset
     * 2. Checks that the position has sufficient balance of the asset
     * 3. Updates the position's collateral tracking based on withdrawal amount
     * 4. Ensures the position remains sufficiently collateralized after withdrawal
     *
     * @param asset Address of the collateral asset to withdraw
     * @param amount Amount of the asset to withdraw (in the asset's native units)
     * @param positionId ID of the position to withdraw from
     *
     * @custom:requirements
     *   - Position must exist and be in ACTIVE status (validated by activePosition modifier)
     *   - For isolated positions: asset must match the position's designated asset
     *   - Position must have sufficient balance of the specified asset
     *   - After withdrawal, position must maintain sufficient collateral for any outstanding debt
     *
     * @custom:state-changes
     *   - Decreases positionCollateralAmounts[msg.sender][positionId][asset] by amount
     *   - For non-isolated positions: Removes asset entirely if balance becomes zero
     *   - Decreases global assetTVL[asset] by amount
     *
     * @custom:emits
     *   - TVLUpdated(asset, newTVL)
     *
     * @custom:error-cases
     *   - InvalidAssetForIsolation: Thrown when trying to withdraw an asset that doesn't match the isolated position's asset
     *   - LowBalance: Thrown when position doesn't have sufficient balance of the asset
     *   - CreditLimitExceeded: Thrown when withdrawal would leave position undercollateralized
     */
    function _processWithdrawal(address asset, uint256 amount, uint256 positionId) internal {
        EnumerableMap.AddressToUintMap storage collaterals = positionCollateral[msg.sender][positionId];

        // Check balance and update collateral in one operation
        (bool exists, uint256 currentAmount) = collaterals.tryGet(asset);
        if (!exists || currentAmount < amount) revert LowBalance();

        uint256 newAmount = currentAmount - amount;
        if (newAmount == 0 && !positions[msg.sender][positionId].isIsolated) {
            collaterals.remove(asset);
        } else {
            collaterals.set(asset, newAmount);
        }

        // Update TVL and verify collateralization
        uint256 newTVL = assetTVL[asset].tvl - amount;
        assetTVL[asset] = AssetTracking({
            tvl: newTVL,
            tvlUSD: assetsModule.updateAssetPoRFeed(asset, newTVL),
            lastUpdate: block.timestamp
        });

        // Verify collateralization after withdrawal
        if (calculateCreditLimit(msg.sender, positionId) < positions[msg.sender][positionId].debtAmount) {
            revert CreditLimitExceeded();
        }

        emit TVLUpdated(asset, newTVL);
    }

    /**
     * @notice Processes a repayment for a specific position
     * @dev Internal function used to handle repayment of debt for a position
     * @param positionId ID of the position to repay
     * @param proposedAmount Amount of debt to repay (proposed)
     * @param position Storage reference to the position
     * @param expectedDebt Expected debt amount for slippage protection
     * @param maxSlippageBps Maximum slippage percentage allowed
     * @return actualAmount Actual amount repaid (capped at total debt)
     */
    function _processRepay(
        uint256 positionId,
        uint256 proposedAmount,
        UserPosition storage position,
        uint256 expectedDebt,
        uint32 maxSlippageBps
    ) internal activePosition(msg.sender, positionId) validAmount(proposedAmount) returns (uint256 actualAmount) {
        uint256 cachedDebtAmount = position.debtAmount;
        if (cachedDebtAmount > 0) {
            // Accrue interest for this position
            uint256 balance = calculateDebtWithInterest(msg.sender, positionId);
            uint256 accruedInterest = balance - cachedDebtAmount;

            if (accruedInterest > 0) {
                totalAccruedBorrowerInterest += accruedInterest;
                position.debtAmount = balance;
                position.lastInterestAccrual = block.timestamp;
                emit InterestAccrued(msg.sender, positionId, accruedInterest);
            }

            _validateSlippage(balance, expectedDebt, maxSlippageBps);

            // Determine actual repayment amount (capped at total debt)
            actualAmount = proposedAmount > balance ? balance : proposedAmount;

            // Update position state
            position.debtAmount = balance - actualAmount;
            position.lastInterestAccrual = block.timestamp;

            // Emit repay event
            emit Repay(msg.sender, positionId, actualAmount);
        }
    }

    /**
     * @notice Processes borrow logic
     * @dev Internal function to handle borrowing to avoid stack too deep
     * @param user Address of the borrower
     * @param positionId ID of the position
     * @param amount Amount to borrow
     * @param expectedCreditLimit Expected credit limit
     * @param maxSlippageBps Maximum slippage percentage allowed
     */
    function _processBorrow(
        address user,
        uint256 positionId,
        uint256 amount,
        uint256 expectedCreditLimit,
        uint32 maxSlippageBps
    ) internal {
        UserPosition storage position = positions[user][positionId];
        // Accrue interest for this position
        uint256 currentDebt;
        uint256 accruedInterest;
        uint256 cachedDebtAmount = positions[user][positionId].debtAmount;
        if (cachedDebtAmount > 0) {
            currentDebt = calculateDebtWithInterest(user, positionId);
            accruedInterest = currentDebt - cachedDebtAmount;

            if (accruedInterest > 0) {
                totalAccruedBorrowerInterest += accruedInterest;
                position.debtAmount = currentDebt;
                position.lastInterestAccrual = block.timestamp;
                emit InterestAccrued(user, positionId, accruedInterest);
            }
        }

        // Check protocol liquidity from vault
        uint256 availableLiquidity = baseVault.totalAssets() - baseVault.totalBorrow();
        if (accruedInterest + amount > availableLiquidity) {
            revert LowLiquidity();
        }

        // Check isolation debt cap if position is isolated
        if (position.isIsolated) {
            _checkIsolationDebtCap(user, positionId, currentDebt + amount);
        }

        // Check credit limit
        uint256 creditLimit = calculateCreditLimit(user, positionId);
        _validateSlippage(creditLimit, expectedCreditLimit, maxSlippageBps);
        if (currentDebt + amount > creditLimit) revert CreditLimitExceeded();

        // Update position state
        position.debtAmount = currentDebt + amount;
        position.lastInterestAccrual = block.timestamp;
    }

    /**
     * @notice Checks isolation debt cap for a position
     * @dev Internal function to avoid stack too deep errors
     * @param user Address of the position owner
     * @param positionId ID of the position
     * @param newDebt The new total debt amount
     */
    function _checkIsolationDebtCap(address user, uint256 positionId, uint256 newDebt) internal view {
        (address posAsset,) = positionCollateral[user][positionId].at(0);
        uint256 isolationDebtCap = assetsModule.getIsolationDebtCap(posAsset);
        if (newDebt > isolationDebtCap) revert IsolationDebtCapExceeded();
    }

    /**
     * @notice Internal function to validate slippage protection
     * @dev Uses efficient absolute difference calculation to avoid division
     * @param actualAmount The actual amount being processed
     * @param expectedAmount The expected amount from the user
     * @param maxSlippageBps Maximum allowed slippage in basis points
     */
    function _validateSlippage(uint256 actualAmount, uint256 expectedAmount, uint32 maxSlippageBps)
        internal
        pure
        validAmount(actualAmount)
        validAmount(expectedAmount)
        validAmount(maxSlippageBps)
    {
        uint256 deviation =
            actualAmount > expectedAmount ? actualAmount - expectedAmount : expectedAmount - actualAmount;
        if (deviation * 10000 > expectedAmount * maxSlippageBps) {
            revert MEVSlippageExceeded();
        }
    }
}
