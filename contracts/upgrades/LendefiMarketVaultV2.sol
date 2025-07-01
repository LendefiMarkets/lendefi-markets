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
 * @title LendefiMarketVault
 * @author alexei@lendefimarkets(dot)com
 * @notice ERC-4626 compliant vault that tokenizes base assets for the Lendefi lending protocol
 * @dev This contract serves as the liquidity management layer for Lendefi markets, implementing:
 *      - ERC4626 standard for tokenized vault shares representing liquidity positions
 *      - Flash loan functionality with configurable fees
 *      - Automated Proof of Reserves updates via Chainlink Automation
 *      - MEV protection for liquidity operations
 *      - Time-based reward distribution for liquidity providers
 *      - Protocol-controlled borrowing and repayment functions
 *
 *      The vault handles all base currency operations while LendefiCore manages
 *      collateral assets and lending calculations. This separation allows for
 *      clean ERC4626 compliance and modular protocol architecture.
 * @custom:security-contact security@lendefimarkets.com
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {ILendefiMarketVault} from "../interfaces/ILendefiMarketVault.sol";
import {IECOSYSTEM} from "../interfaces/IEcosystem.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {IERC20, SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC4626Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/extensions/ERC4626Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {LendefiConstants} from "../markets/lib/LendefiConstants.sol";
import {LendefiRates} from "../markets/lib/LendefiRates.sol";
import {LendefiPoRFeed} from "../markets/LendefiPoRFeed.sol";
import {IFlashLoanReceiver} from "../interfaces/IFlashLoanReceiver.sol";
import {AutomationCompatibleInterface} from
    "../vendor/@chainlink/contracts/src/v0.8/automation/AutomationCompatible.sol";

/// @custom:oz-upgrades-from LendefiMarketVault
contract LendefiMarketVaultV2 is
    Initializable,
    ERC4626Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    AutomationCompatibleInterface
{
    using SafeERC20 for IERC20;
    using LendefiRates for *;
    using LendefiConstants for *;
    using EnumerableMap for EnumerableMap.AddressToUintMap;

    // ========== STATE VARIABLES ==========

    /// @notice Decimal multiplier for the base asset (10^decimals)
    /// @dev Used for precise calculations and rate computations across the protocol
    uint256 public baseDecimals;

    /// @notice Total amount of base asset supplied by liquidity providers
    /// @dev Tracks the cumulative deposits from all LPs, used for utilization calculations
    uint256 public totalSuppliedLiquidity;

    /// @notice Total interest accrued from borrowers and flash loan fees
    /// @dev Represents protocol revenue that increases vault share value over time
    uint256 public totalAccruedInterest;

    /// @notice Total base asset currently held in the vault
    /// @dev Includes supplied liquidity, accrued interest, and flash loan fees
    uint256 public totalBase;

    /// @notice Total amount currently borrowed by protocol users
    /// @dev Tracks outstanding debt that reduces available liquidity for withdrawals
    uint256 public totalBorrow;

    /// @notice Counter tracking the number of automated upkeep operations performed
    /// @dev Used for monitoring and debugging Chainlink Automation integration
    uint256 public counter;

    /// @notice Time interval between automated Proof of Reserves updates
    /// @dev Default is 12 hours, determines frequency of PoR feed updates
    uint256 public interval;

    /// @notice Timestamp of the last automated upkeep execution
    /// @dev Used by Chainlink Automation to determine when next update is needed
    uint256 public lastTimeStamp;

    /// @notice Contract version number for upgrade tracking
    /// @dev Incremented with each contract upgrade via UUPS pattern
    uint32 public version;

    /// @notice Address of the Proof of Reserves feed for this market
    /// @dev Provides real-time reserve data for transparency and monitoring
    address public porFeed;

    /// @notice Address of the LendefiCore contract managing this market
    /// @dev Core contract handles collateral management and lending logic
    address public lendefiCore;

    /// @notice Address of the ecosystem contract managing governance rewards
    /// @dev Handles distribution of governance tokens to liquidity providers
    address public ecosystem;

    /// @notice Address of the assets module contract for asset management
    /// @dev Used for accessing asset tier information and jump rates
    address public assetsModule;

    /// @notice Address of the timelock contract with protocol governance
    /// @dev Receives protocol fees when they are collected
    address public timelock;

    /// @notice Cached protocol configuration to avoid repeated external calls
    /// @dev Contains interest rates, fees, and reward parameters
    ILendefiMarketVault.ProtocolConfig public protocolConfig;

    /// @notice Mapping of borrower addresses to their outstanding debt amounts
    /// @dev Tracks individual borrower positions for repayment calculations
    mapping(address => uint256) public borrowerDebt;

    /// @notice Tracks the last block when liquidity operations were performed by each user
    /// @dev Used for MEV protection and reward eligibility calculations
    /// @dev Key: User address, Value: Block number of last operation
    mapping(address => uint256) internal liquidityOperationBlock;
    /// @notice Storage gap for future upgrades
    /// @dev Reserves storage slots for upgradeable contract pattern
    uint256[10] private __gap;
    // ========== EVENTS ==========

    /// @notice Emitted when the vault is successfully initialized
    /// @param admin Address that performed the initialization
    event Initialized(address indexed admin);

    /// @notice Emitted when a user supplies liquidity to the vault
    /// @param user Address of the liquidity provider
    /// @param amount Amount of base asset supplied
    event SupplyLiquidity(address indexed user, uint256 amount);

    /// @notice Emitted when yield is boosted through liquidation proceeds
    /// @param user Address of the user whose liquidation generated the yield boost
    /// @param amount Amount of yield added to the vault
    event YieldBoosted(address indexed user, uint256 amount);

    /// @notice Emitted when shares are exchanged for base assets or vice versa
    /// @param user Address performing the exchange
    /// @param shares Number of shares involved in the exchange
    /// @param amount Amount of base asset involved in the exchange
    event Exchange(address indexed user, uint256 shares, uint256 amount);

    /// @notice Emitted when a flash loan is successfully executed
    /// @param user Address that initiated the flash loan
    /// @param receiver Address that received the flash loan funds
    /// @param asset Address of the asset that was flash loaned
    /// @param amount Amount of asset flash loaned
    /// @param fee Fee charged for the flash loan
    event FlashLoan(address indexed user, address indexed receiver, address indexed asset, uint256 amount, uint256 fee);

    /// @notice Emitted when the protocol configuration is updated
    /// @param config The new protocol configuration
    event ProtocolConfigUpdated(ILendefiMarketVault.ProtocolConfig config);

    /// @notice Emitted when market parameters are updated by market owner
    /// @param borrowRate The new borrow rate
    /// @param flashLoanFee The new flash loan fee
    event MarketParametersUpdated(uint256 borrowRate, uint32 flashLoanFee);

    /// @notice Emitted when governance rewards are claimed by a liquidity provider
    /// @param user Address of the user claiming rewards
    /// @param amount Amount of governance tokens rewarded
    event Reward(address indexed user, uint256 amount);

    /// @notice Emitted when the protocol becomes undercollateralized
    /// @param timestamp Block timestamp when the alert was triggered
    /// @param tvl Total value locked in the protocol at the time of alert
    /// @param totalSupply Total supply of vault shares at the time of alert
    event CollateralizationAlert(uint256 timestamp, uint256 tvl, uint256 totalSupply);

    /// @notice Emitted when protocol fees are collected through share dilution
    /// @param recipient Address that received the fee shares (timelock)
    /// @param feeShares Number of shares minted as protocol fees
    event ProtocolFeesCollected(address indexed recipient, uint256 feeShares);

    // ========== ERRORS ==========

    /// @notice Thrown when a required address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when attempting operations in the same block (MEV protection)
    error MEVSameBlockOperation();

    /// @notice Thrown when an operation is attempted with zero amount
    error ZeroAmount();

    /// @notice Thrown when insufficient liquidity is available for the requested operation
    error LowLiquidity();

    /// @notice Thrown when a flash loan execution fails
    error FlashLoanFailed();

    /// @notice Thrown when flash loan repayment is insufficient
    error RepaymentFailed();

    /// @notice Thrown when an invalid fee parameter is provided
    error InvalidFee();

    /// @notice Thrown when profit target rate is invalid
    error InvalidProfitTarget();

    /// @notice Thrown when borrow rate is invalid
    error InvalidBorrowRate();

    /// @notice Thrown when reward amount is invalid
    error InvalidRewardAmount();

    /// @notice Thrown when interval is invalid
    error InvalidInterval();

    /// @notice Thrown when supply amount is invalid
    error InvalidSupplyAmount();

    /// @notice Validates that an amount parameter is greater than zero
    /// @param amount The amount to validate
    modifier validAmount(uint256 amount) {
        if (amount == 0) revert ZeroAmount();
        _;
    }

    /// @notice Validates that an address parameter is not the zero address
    /// @param addr The address to validate
    modifier validAddress(address addr) {
        if (addr == address(0)) revert ZeroAddress();
        _;
    }

    /// @notice Prevents MEV attacks by ensuring no same-block operations for a user
    /// @param user The user address to check for MEV protection
    modifier noMEV(address user) {
        uint256 lastOperationBlock = liquidityOperationBlock[user];
        uint256 currentBlock = block.number;
        if (lastOperationBlock >= currentBlock) revert MEVSameBlockOperation();
        liquidityOperationBlock[user] = currentBlock;
        _;
    }

    // ========== CONSTRUCTOR ==========

    /// @notice Disables initializers to prevent implementation contract initialization
    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the vault with essential parameters and sets up integrations
     * @dev Performs comprehensive setup including:
     *      - ERC4626 vault initialization with base asset
     *      - Access control role assignments
     *      - Chainlink Automation configuration
     *      - Proof of Reserves feed deployment and setup
     *      - Protocol configuration caching
     *
     *      This function can only be called once during proxy deployment.
     * @param _timelock Address of the timelock contract with admin privileges
     * @param core Address of the LendefiCore contract for this market
     * @param baseAsset Address of the ERC20 token used as the base asset
     * @param _ecosystem Address of the ecosystem contract for reward distribution
     * @param _assetsModule Address of the assets module contract for asset management
     * @param _name Name for the ERC20 vault token (e.g., "Lendefi USDC Vault")
     * @param _symbol Symbol for the ERC20 vault token (e.g., "lendUSDC")
     *
     * @custom:requirements
     *   - All address parameters must be non-zero
     *   - baseAsset must be a valid ERC20 token with decimals() function
     *   - Function can only be called once during deployment
     *
     * @custom:state-changes
     *   - Initializes all OpenZeppelin upgradeable contracts
     *   - Sets baseDecimals based on the base asset's decimals
     *   - Configures Chainlink Automation with 12-hour intervals
     *   - Deploys and initializes a new LendefiPoRFeed contract
     *   - Grants necessary roles to timelock and core contracts
     *   - Caches initial protocol configuration
     *
     * @custom:emits Initialized event with the initializer's address
     * @custom:access-control Only callable during contract initialization
     * @custom:error-cases
     *   - ZeroAddress: When any required address parameter is zero
     */
    function initialize(
        address _timelock,
        address core,
        address baseAsset,
        address _ecosystem,
        address _assetsModule,
        string memory _name,
        string memory _symbol
    ) external initializer {
        if (baseAsset == address(0)) revert ZeroAddress();
        if (_timelock == address(0)) revert ZeroAddress();
        if (core == address(0)) revert ZeroAddress();
        if (_ecosystem == address(0)) revert ZeroAddress();
        if (_assetsModule == address(0)) revert ZeroAddress();

        baseDecimals = 10 ** IERC20Metadata(baseAsset).decimals();
        lendefiCore = core;
        ecosystem = _ecosystem;
        assetsModule = _assetsModule;
        timelock = _timelock;
        version = 1;
        interval = 12 hours;
        lastTimeStamp = block.timestamp;
        porFeed = address(new LendefiPoRFeed());
        IPoRFeed(porFeed).initialize(baseAsset, address(this), _timelock);

        __ERC4626_init(IERC20(baseAsset));
        __ERC20_init(_name, _symbol);
        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _timelock);
        _grantRole(LendefiConstants.PAUSER_ROLE, _timelock);
        _grantRole(LendefiConstants.PROTOCOL_ROLE, core);
        _grantRole(LendefiConstants.UPGRADER_ROLE, _timelock);
        _grantRole(LendefiConstants.MANAGER_ROLE, _timelock);

        // Initialize default protocol configuration
        protocolConfig = ILendefiMarketVault.ProtocolConfig({
            profitTargetRate: 0.0025e6, // 0.25%
            borrowRate: 0.06e6, // 6%
            rewardAmount: 2_000 ether, // 2,000 governance tokens
            rewardInterval: 180 * 24 * 60 * 5, // 180 days in blocks
            rewardableSupply: 100_000 * baseDecimals, // 100,000 base asset units
            flashLoanFee: 9 // 9 basis points (0.09%)
        });

        emit Initialized(msg.sender);
    }

    // ========== CONFIGURATION FUNCTIONS ==========

    /**
     * @notice Updates the protocol configuration (DAO-only)
     * @dev Allows DAO to update all protocol parameters including rates and rewards
     * @param config The new protocol configuration
     * @custom:access-control Restricted to DEFAULT_ADMIN_ROLE
     * @custom:events Emits a ProtocolConfigUpdated event
     * @custom:error-cases
     *   - InvalidProfitTarget: Thrown when profit target rate is below minimum
     *   - InvalidBorrowRate: Thrown when borrow rate is below minimum
     *   - InvalidRewardAmount: Thrown when reward amount exceeds maximum
     *   - InvalidInterval: Thrown when interval is below minimum
     *   - InvalidSupplyAmount: Thrown when supply amount is below minimum
     *   - InvalidFee: Thrown when flash loan fee is invalid
     */
    function loadProtocolConfig(ILendefiMarketVault.ProtocolConfig calldata config)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        // Validate all parameters
        if (config.profitTargetRate < 0.0025e6) revert InvalidProfitTarget();
        if (config.borrowRate < 0.01e6) revert InvalidBorrowRate();
        if (config.rewardAmount > 10_000 ether) revert InvalidRewardAmount();
        if (config.rewardInterval < 90 * 24 * 60 * 5) revert InvalidInterval(); // 90 days in blocks
        if (config.rewardableSupply < 20_000 * baseDecimals) revert InvalidSupplyAmount();
        if (config.flashLoanFee > 100 || config.flashLoanFee < 1) revert InvalidFee();

        // Update the protocol config
        protocolConfig = config;

        // Emit event for protocol config update
        emit ProtocolConfigUpdated(config);
    }

    /**
     * @notice Updates market-specific parameters (Market Owner only)
     * @dev Allows market owners to adjust borrowRate and flashLoanFee
     * @param borrowRate The new base borrow rate in 1e6 format
     * @param flashLoanFee The new flash loan fee in basis points (max 100 = 1%)
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:events Emits a MarketParametersUpdated event
     * @custom:error-cases
     *   - InvalidBorrowRate: Thrown when borrow rate is below minimum
     *   - InvalidFee: Thrown when flash loan fee is invalid
     */
    function updateMarketParameters(uint256 borrowRate, uint32 flashLoanFee)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
    {
        // Validate parameters
        if (borrowRate < 0.01e6) revert InvalidBorrowRate();
        if (flashLoanFee > 100 || flashLoanFee < 1) revert InvalidFee();

        // Update the protocol config
        protocolConfig.borrowRate = borrowRate;
        protocolConfig.flashLoanFee = flashLoanFee;

        // Emit event for market parameter updates
        emit MarketParametersUpdated(borrowRate, flashLoanFee);
    }

    // ========== FLASH LOAN FUNCTIONS ==========

    /**
     * @notice Executes a flash loan by temporarily lending assets without collateral
     * @dev Implements the flash loan pattern where:
     *      1. Assets are transferred to the receiver
     *      2. Receiver executes arbitrary logic via callback
     *      3. Assets plus fee must be returned in the same transaction
     *
     *      The flash loan enables capital-efficient arbitrage, liquidations,
     *      and other advanced DeFi strategies without requiring upfront capital.
     * @param receiver Address of the contract that will receive the flash loan
     * @param amount Amount of base asset to flash loan
     * @param params Arbitrary data passed to the receiver's callback function
     *
     * @custom:requirements
     *   - amount must be greater than zero
     *   - receiver must be a valid contract address implementing IFlashLoanReceiver
     *   - Sufficient liquidity must be available in the vault
     *   - Contract must not be paused
     *
     * @custom:state-changes
     *   - Temporarily reduces vault balance during execution
     *   - Increases totalBase by the flash loan fee
     *   - No permanent state changes if properly repaid
     *
     * @custom:emits FlashLoan event with loan details
     * @custom:access-control Available to any caller when not paused
     * @custom:error-cases
     *   - ZeroAmount: When amount is zero
     *   - ZeroAddress: When receiver is zero address
     *   - LowLiquidity: When insufficient funds available
     *   - FlashLoanFailed: When receiver callback returns false
     *   - RepaymentFailed: When insufficient funds returned
     *
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:fee Flash loan fee is calculated as (amount * flashLoanFee) / 10000
     */
    function flashLoan(address receiver, uint256 amount, bytes calldata params)
        external
        validAmount(amount)
        validAddress(receiver)
        nonReentrant
        whenNotPaused
    {
        // Cache asset address to avoid multiple external calls
        address cachedAsset = asset();
        IERC20 baseAssetInstance = IERC20(cachedAsset);
        uint256 initialBalance = baseAssetInstance.balanceOf(address(this));
        if (amount > initialBalance) revert LowLiquidity();

        // Calculate fee and record initial balance
        uint256 fee = Math.mulDiv(amount, protocolConfig.flashLoanFee, 10000, Math.Rounding.Floor);
        uint256 requiredBalance = initialBalance + fee;
        totalBase += fee;

        // Transfer flash loan amount
        baseAssetInstance.safeTransfer(receiver, amount);

        // Execute flash loan operation using cached asset address
        bool success = IFlashLoanReceiver(receiver).executeOperation(cachedAsset, amount, fee, msg.sender, params);

        // Verify both the return value AND the actual balance
        if (!success) revert FlashLoanFailed(); // Flash loan failed (incorrect return value)

        uint256 currentBalance = baseAssetInstance.balanceOf(address(this));
        if (currentBalance < requiredBalance) revert RepaymentFailed(); // Repay failed (insufficient funds returned)

        // Update protocol state only after all verifications succeed using cached asset address
        emit FlashLoan(msg.sender, receiver, cachedAsset, amount, fee);
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Pauses all vault operations in case of emergency
     * @dev Prevents all user-facing functions from executing while allowing
     *      admin functions to continue. Used for emergency response or maintenance.
     *
     * @custom:access-control Restricted to PAUSER_ROLE
     * @custom:state-changes Sets the contract to paused state
     */
    function pause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _pause();
    }

    /**
     * @notice Resumes normal vault operations after being paused
     * @dev Re-enables all user-facing functions that were disabled during pause.
     *      Should only be called after resolving the issue that caused the pause.
     *
     * @custom:access-control Restricted to PAUSER_ROLE
     * @custom:state-changes Removes the paused state from the contract
     */
    function unpause() external onlyRole(LendefiConstants.PAUSER_ROLE) {
        _unpause();
    }

    /**
     * @notice Performs automated Proof of Reserve updates via Chainlink Automation
     * @dev This function is called by Chainlink Automation nodes at regular intervals to:
     *      1. Update the timestamp tracking for interval management
     *      2. Increment the counter for monitoring automation performance
     *      3. Check the protocol's collateralization status
     *      4. Update the PoR feed with current Total Value Locked (TVL)
     *      5. Emit alerts if the protocol becomes undercollateralized
     *
     *      The automation ensures continuous transparency and monitoring of protocol health
     *      without requiring manual intervention.
     *
     * @custom:requirements
     *   - Sufficient time must have passed since last update (checked by interval)
     *   - Function is typically called by Chainlink Automation nodes
     *
     * @custom:state-changes
     *   - Updates lastTimeStamp to current block timestamp
     *   - Increments counter for tracking automation calls
     *   - Updates the PoR feed with current TVL data
     *
     * @param performData Encoded data from checkUpkeep (unused)
     * @custom:emits CollateralizationAlert when protocol becomes undercollateralized
     * @custom:automation Part of Chainlink's AutomationCompatibleInterface
     * @custom:interval Updates occur based on the interval state variable (default 12 hours)
     */
    function performUpkeep(bytes calldata performData) external override {
        // performData is unused as this implementation doesn't require input data
        uint256 currentTimestamp = block.timestamp;
        if ((currentTimestamp - lastTimeStamp) > interval) {
            lastTimeStamp = currentTimestamp;
            counter += 1;

            // Use the stored TVL value instead of parameter
            (bool collateralized, uint256 tvl) = IPROTOCOL(lendefiCore).isCollateralized();

            // Update the reserves on the feed
            IPoRFeed(porFeed).updateReserves(tvl);
            if (!collateralized) {
                performData;
                emit CollateralizationAlert(currentTimestamp, tvl, totalSupply());
            }
        }
    }

    /**
     * @notice Boosts vault yield by adding liquidation proceeds or other revenue
     * @dev Increases the vault's total assets and accrued interest, which benefits
     *      all shareholders by increasing the value of their shares. This function
     *      is typically called when liquidations generate profit for the protocol.
     * @param user Address of the user whose position generated the yield boost
     * @param amount Amount of base asset to add to the vault's yield
     *
     * @custom:requirements
     *   - amount must be greater than zero
     *   - Caller must have MANAGER_ROLE
     *   - Contract must not be paused
     *   - Caller must have approved this contract to spend the tokens
     *
     * @custom:state-changes
     *   - Increases totalBase by the specified amount
     *   - Increases totalAccruedInterest by the specified amount
     *   - Transfers tokens from caller to this contract
     *
     * @custom:emits YieldBoosted event with user and amount details
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:reentrancy Protected by nonReentrant modifier
     */
    function boostYield(address user, uint256 amount)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        whenNotPaused
        nonReentrant
    {
        totalBase += amount;
        totalAccruedInterest += amount;
        emit YieldBoosted(user, amount);
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Claims accumulated governance token rewards for eligible liquidity providers
     * @dev Calculates and distributes time-based rewards to users who have provided
     *      liquidity for a sufficient duration and amount. The reward system incentivizes
     *      long-term liquidity provision and protocol participation.
     *
     *      Reward eligibility is based on:
     *      - Time since last liquidity operation (must exceed rewardInterval)
     *      - Minimum liquidity provided (must exceed rewardableSupply)
     * @return finalReward The amount of governance tokens awarded to the caller
     *
     * @custom:requirements
     *   - Caller must be eligible for rewards (checked by isRewardable)
     *   - Contract must not be paused
     *   - Sufficient time must have passed since last reward claim
     *   - Caller must have provided minimum required liquidity
     *
     * @custom:state-changes
     *   - Resets liquidityOperationBlock[msg.sender] to current block
     *   - Triggers reward distribution through ecosystem contract
     *
     * @custom:emits Reward event with the caller's address and reward amount
     * @custom:access-control Available to any eligible caller when not paused
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:rewards Reward amount is capped by maxReward from ecosystem contract
     */
    function claimReward() external nonReentrant whenNotPaused returns (uint256 finalReward) {
        if (isRewardable(msg.sender)) {
            // Use cached protocol config
            ILendefiMarketVault.ProtocolConfig memory config = protocolConfig;

            // Cache ecosystem contract to avoid multiple storage reads
            IECOSYSTEM cachedEcosystem = IECOSYSTEM(ecosystem);

            // Calculate reward amount based on blocks elapsed
            uint256 lastOperationBlock = liquidityOperationBlock[msg.sender];
            uint256 currentBlock = block.number;
            uint256 blocksElapsed = currentBlock - lastOperationBlock;
            uint256 reward = Math.mulDiv(config.rewardAmount, blocksElapsed, config.rewardInterval, Math.Rounding.Floor);

            // Apply maximum reward cap using cached ecosystem reference
            uint256 maxReward = cachedEcosystem.maxReward();
            finalReward = reward > maxReward ? maxReward : reward;

            // Reset block number for next reward period
            liquidityOperationBlock[msg.sender] = currentBlock;

            // Emit event and issue reward using cached ecosystem reference
            emit Reward(msg.sender, finalReward);
            cachedEcosystem.reward(msg.sender, finalReward);
        }
    }

    /**
     * @notice Determines if automated upkeep should be performed by Chainlink nodes
     * @dev This view function is called by Chainlink Automation infrastructure to
     *      determine whether performUpkeep should be executed. The upkeep is needed
     *      when sufficient time has elapsed since the last Proof of Reserves update.
     * @param checkData Encoded data to determine if upkeep is needed (unused)
     * @return upkeepNeeded Boolean indicating whether performUpkeep should be called
     * @return performData Encoded data to pass to performUpkeep (returns empty bytes)
     *
     * @custom:automation Part of Chainlink's AutomationCompatibleInterface
     * @custom:interval Uses the contract's interval variable to determine timing
     * @custom:gas-efficient View function with minimal gas consumption for frequent calls
     */
    function checkUpkeep(bytes calldata checkData)
        external
        view
        override
        returns (bool upkeepNeeded, bytes memory performData)
    {
        // checkData is unused as this implementation doesn't require input data
        checkData;
        upkeepNeeded = (block.timestamp - lastTimeStamp) > interval;
        performData = "0x00";
    }

    /**
     * @notice Deposits base assets into the vault and mints shares to the receiver
     * @dev Implements ERC4626 deposit functionality with additional features:
     *      - MEV protection via same-block operation prevention
     *      - Protocol state tracking for liquidity management
     *      - Integration with reward eligibility tracking
     * @param amount Amount of base asset to deposit
     * @param receiver Address that will receive the minted vault shares
     * @return shares Number of vault shares minted to the receiver
     *
     * @custom:requirements
     *   - amount must be greater than zero
     *   - receiver must be a valid address (non-zero)
     *   - Contract must not be paused
     *   - Caller must have approved this contract to spend the tokens
     *   - No operations in the same block for MEV protection
     *
     * @custom:state-changes
     *   - Updates liquidityOperationBlock[receiver] to current block
     *   - Increases totalBase and totalSuppliedLiquidity by amount
     *   - Mints vault shares to receiver according to ERC4626 calculation
     *
     * @custom:access-control Available to any caller when not paused
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:mev-protection Prevents same-block operations for the receiver
     */
    function deposit(uint256 amount, address receiver)
        public
        override
        validAmount(amount)
        validAddress(receiver)
        whenNotPaused
        nonReentrant
        noMEV(receiver)
        returns (uint256)
    {
        uint256 shares = super.deposit(amount, receiver);
        totalBase += amount;
        totalSuppliedLiquidity += amount;
        return shares;
    }

    /**
     * @notice Mints a specific number of vault shares to the receiver
     * @dev Implements ERC4626 mint functionality with additional protocol features.
     *      Calculates the required asset amount to mint the specified shares.
     * @param shares Number of vault shares to mint
     * @param receiver Address that will receive the minted vault shares
     * @return amount Amount of base asset required to mint the shares
     *
     * @custom:requirements
     *   - shares must be greater than zero
     *   - receiver must be a valid address (non-zero)
     *   - Contract must not be paused
     *   - Caller must have sufficient approved tokens for the calculated amount
     *   - No operations in the same block for MEV protection
     *
     * @custom:state-changes
     *   - Updates liquidityOperationBlock[receiver] to current block
     *   - Increases totalBase and totalSuppliedLiquidity by calculated amount
     *   - Mints specified shares to receiver
     *
     * @custom:access-control Available to any caller when not paused
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:mev-protection Prevents same-block operations for the receiver
     */
    function mint(uint256 shares, address receiver)
        public
        override
        validAmount(shares)
        validAddress(receiver)
        whenNotPaused
        nonReentrant
        noMEV(receiver)
        returns (uint256)
    {
        uint256 amount = super.mint(shares, receiver);
        totalBase += amount;
        totalSuppliedLiquidity += amount;
        return amount;
    }

    /**
     * @notice Withdraws a specific amount of base assets from the vault
     * @dev Implements ERC4626 withdraw functionality with protocol-specific features.
     *      Burns the necessary shares to withdraw the specified asset amount.
     * @param amount Amount of base asset to withdraw
     * @param receiver Address that will receive the withdrawn assets
     * @param owner Address that owns the shares being burned
     * @return shares Number of shares burned to complete the withdrawal
     *
     * @custom:requirements
     *   - amount must be greater than zero
     *   - receiver and owner must be valid addresses (non-zero)
     *   - Contract must not be paused
     *   - Owner must have sufficient shares for the withdrawal
     *   - If caller is not owner, must have sufficient allowance
     *   - No operations in the same block for MEV protection
     *
     * @custom:state-changes
     *   - Updates liquidityOperationBlock[owner] to current block
     *   - Decreases totalBase and totalSuppliedLiquidity by amount
     *   - Burns calculated shares from owner's balance
     *
     * @custom:access-control Available to any caller when not paused
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:mev-protection Prevents same-block operations for the owner
     */
    function withdraw(uint256 amount, address receiver, address owner)
        public
        override
        validAddress(receiver)
        validAddress(owner)
        validAmount(amount)
        whenNotPaused
        nonReentrant
        noMEV(owner)
        returns (uint256)
    {
        // Calculate and collect fees before withdrawal
        uint256 fee = _calculateVirtualFeeShares();
        uint256 totalSharesBeforeWithdraw = totalSupply();

        uint256 shares = super.withdraw(amount, receiver, owner);
        uint256 baseAmount = Math.mulDiv(shares, totalSuppliedLiquidity, totalSharesBeforeWithdraw, Math.Rounding.Floor);
        totalBase -= amount;
        totalSuppliedLiquidity -= baseAmount;

        if (fee > 0) {
            address cachedTimelock = timelock;
            _mint(cachedTimelock, fee);
            emit ProtocolFeesCollected(cachedTimelock, fee);
        }

        return shares;
    }

    /**
     * @notice Redeems vault shares for base assets
     * @dev Implements ERC4626 redeem functionality with protocol-specific features.
     *      Burns the specified shares and transfers corresponding assets to receiver.
     * @param shares Number of vault shares to redeem
     * @param receiver Address that will receive the redeemed assets
     * @param owner Address that owns the shares being redeemed
     * @return amount Amount of base asset transferred to receiver
     *
     * @custom:requirements
     *   - shares must be greater than zero
     *   - receiver and owner must be valid addresses (non-zero)
     *   - Contract must not be paused
     *   - Owner must have sufficient shares for redemption
     *   - If caller is not owner, must have sufficient allowance
     *   - No operations in the same block for MEV protection
     *
     * @custom:state-changes
     *   - Updates liquidityOperationBlock[owner] to current block
     *   - Decreases totalBase and totalSuppliedLiquidity by calculated amount
     *   - Burns specified shares from owner's balance
     *
     * @custom:access-control Available to any caller when not paused
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:mev-protection Prevents same-block operations for the owner
     */
    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        validAmount(shares)
        validAddress(receiver)
        validAddress(owner)
        whenNotPaused
        nonReentrant
        noMEV(owner)
        returns (uint256)
    {
        // Calculate and collect fees before redemption
        uint256 fee = _calculateVirtualFeeShares();
        uint256 totalSharesBeforeRedeem = totalSupply();

        uint256 amount = super.redeem(shares, receiver, owner);

        totalBase -= amount;
        // Calculate proportional reduction in supplied liquidity
        uint256 baseAmount = Math.mulDiv(totalSuppliedLiquidity, shares, totalSharesBeforeRedeem, Math.Rounding.Floor);
        totalSuppliedLiquidity -= baseAmount;

        if (fee > 0) {
            address cachedTimelock = timelock;
            _mint(cachedTimelock, fee);
            emit ProtocolFeesCollected(cachedTimelock, fee);
        }

        return amount;
    }

    /**
     * @notice Allows the protocol to borrow assets from the vault's liquidity
     * @dev This function is exclusively used by the LendefiCore contract to
     *      facilitate lending operations. It manages the vault's available
     *      liquidity and tracks individual borrower debt positions.
     * @param amount Amount of base asset to borrow from the vault
     * @param receiver Address that will receive the borrowed assets
     *
     * @custom:requirements
     *   - Caller must have PROTOCOL_ROLE (typically LendefiCore)
     *   - Contract must not be paused
     *   - Sufficient liquidity must be available (totalBorrow + amount <= totalSuppliedLiquidity)
     *
     * @custom:state-changes
     *   - Increases totalBorrow by the borrowed amount
     *   - Increases borrowerDebt[receiver] to track individual debt
     *   - Transfers borrowed assets to the receiver
     *
     * @custom:access-control Restricted to PROTOCOL_ROLE
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:error-cases
     *   - LowLiquidity: When insufficient funds available for borrowing
     */
    function borrow(uint256 amount, address receiver)
        public
        onlyRole(LendefiConstants.PROTOCOL_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 newTotalBorrow = totalBorrow + amount;
        if (newTotalBorrow > totalSuppliedLiquidity) {
            revert LowLiquidity();
        }
        totalBorrow = newTotalBorrow;

        borrowerDebt[receiver] += amount; // Track by actual borrower
        IERC20(asset()).safeTransfer(receiver, amount);
    }

    /**
     * @notice Processes debt repayment from protocol borrowers
     * @dev This function is exclusively used by the LendefiCore contract to
     *      handle loan repayments. It properly accounts for principal and interest
     *      portions of the repayment and updates vault state accordingly.
     * @param amount Total amount being repaid (principal + interest)
     * @param sender Address of the borrower making the repayment
     *
     * @custom:requirements
     *   - Caller must have PROTOCOL_ROLE (typically LendefiCore)
     *   - Contract must not be paused
     *   - Caller must have approved this contract to transfer the repayment amount
     *
     * @custom:state-changes
     *   - Decreases totalBorrow by the principal portion repaid
     *   - Decreases borrowerDebt[sender] by the principal portion
     *   - Increases totalBase by the full repayment amount
     *   - Increases totalAccruedInterest by any interest portion
     *
     * @custom:access-control Restricted to PROTOCOL_ROLE
     * @custom:reentrancy Protected by nonReentrant modifier
     * @custom:accounting Separates principal repayment from interest payments
     */
    function repay(uint256 amount, address sender)
        public
        onlyRole(LendefiConstants.PROTOCOL_ROLE)
        whenNotPaused
        nonReentrant
    {
        uint256 debt = borrowerDebt[sender];
        uint256 principalRepaid = amount > debt ? debt : amount;
        uint256 interestPaid = amount > debt ? amount - debt : 0;

        totalBorrow -= principalRepaid;
        borrowerDebt[sender] -= principalRepaid;

        totalAccruedInterest += interestPaid;
        totalBase += interestPaid;

        // Cache asset address to avoid external call
        IERC20(asset()).safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Returns the total amount of base assets managed by the vault
     * @dev Overrides ERC4626 totalAssets to return the vault tracked total.
     *      This includes supplied liquidity, accrued interest, and fees.
     * @return The total amount of base assets in the vault
     */
    function totalAssets() public view override returns (uint256) {
        return totalBase;
    }

    /**
     * @notice Calculates the current utilization rate of the vault's liquidity
     * @dev Utilization rate indicates what percentage of the supplied liquidity is currently
     *      borrowed. Returned value is normalized to 1e6 (e.g., 0.5e6 = 50% utilization).
     * @return u The protocol's current utilization rate normalized to 1e6
     *
     * @custom:formula u = (1e6 × totalBorrow) ÷ totalSuppliedLiquidity
     * @custom:gas-optimization Caches storage reads to minimize SLOAD operations
     * @custom:edge-cases Returns 0 when no liquidity supplied or no borrowing activity
     */
    function utilization() public view returns (uint256 u) {
        // Cache storage reads to avoid multiple SLOADs
        uint256 cachedSupply = totalSuppliedLiquidity;
        uint256 cachedBorrow = totalBorrow;

        if (cachedSupply == 0 || cachedBorrow == 0) {
            return 0;
        }

        return Math.mulDiv(1e6, cachedBorrow, cachedSupply, Math.Rounding.Floor);
    }

    /**
     * @notice Determines if a user is eligible to claim governance token rewards
     * @dev Evaluates reward eligibility based on multiple criteria:
     *      - User must have performed at least one liquidity operation
     *      - Sufficient time must have elapsed since last operation (>= rewardInterval)
     *      - User must have supplied minimum required liquidity (>= rewardableSupply)
     *      - Rewards must be enabled in the protocol configuration
     * @param user Address of the user to check for reward eligibility
     * @return bool True if the user is eligible to claim rewards, false otherwise
     *
     * @custom:requirements
     *   - Uses cached protocol config to avoid external calls
     *   - Calculates user's effective liquidity based on their share balance
     *
     * @custom:eligibility-criteria
     *   - Time criterion: block.number - lastOperationBlock >= rewardInterval
     *   - Amount criterion: user's base asset equivalent >= rewardableSupply
     *   - System criterion: rewardAmount > 0 (rewards must be enabled)
     */
    function isRewardable(address user) public view returns (bool) {
        uint256 lastBlock = liquidityOperationBlock[user];
        if (lastBlock == 0) return false; // Never had liquidity operation

        ILendefiMarketVault.ProtocolConfig memory config = protocolConfig;
        if (config.rewardAmount == 0) return false; // Rewards disabled
        uint256 baseAmount = previewRedeem(balanceOf(user));

        return block.number - lastBlock >= config.rewardInterval && baseAmount >= config.rewardableSupply;
    }

    /**
     * @notice Calculates the current supply interest rate for liquidity providers
     * @dev Uses ERC4626's previewRedeem to calculate the current value of shares.
     *      This automatically accounts for commission through virtual fee shares.
     * @return The current annual supply interest rate in parts per million (1e6 = 100%)
     */
    function getSupplyRate() public view returns (uint256) {
        if (totalSupply() == 0) return 0;

        // Calculate the current value of 1 share unit (using baseDecimals precision)
        uint256 shareValue = previewRedeem(baseDecimals);
        uint256 rateInBaseDecimals = shareValue <= baseDecimals ? 0 : shareValue - baseDecimals;

        // Convert to 1e6 format for consistent rate display across all chains
        return Math.mulDiv(rateInBaseDecimals, 1e6, baseDecimals, Math.Rounding.Floor);
    }

    /**
     * @notice Calculates the current borrow interest rate for a specific collateral tier
     * @dev Based on utilization, base rate, supply rate, and tier-specific jump rate
     * @param tier The collateral tier to calculate the borrow rate for
     * @return The current annual borrow interest rate in 1e6 format
     */
    function getBorrowRate(IASSETS.CollateralTier tier) public view returns (uint256) {
        ILendefiMarketVault.ProtocolConfig memory config = protocolConfig;
        return LendefiRates.getBorrowRate(
            utilization(),
            config.borrowRate,
            config.profitTargetRate,
            getSupplyRate(),
            IASSETS(assetsModule).getTierJumpRate(tier)
        );
    }

    // ========== INTERNAL FUNCTIONS ==========
    /**
     * @notice Authorizes contract upgrades through the UUPS proxy pattern
     * @dev Internal function called by the UUPS upgrade mechanism to verify
     *      that the caller has permission to upgrade the contract implementation.
     *      Also increments the version number for tracking purposes.
     *
     * @param newImplementation Address of the new implementation (unused in authorization)
     * @custom:access-control Restricted to UPGRADER_ROLE
     * @custom:state-changes Increments version number with each upgrade
     * @custom:upgrade-safety Ensures only authorized parties can upgrade the vault
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();
        version++;
    }

    /**
     * @dev Calculates the virtual fee shares that would be minted if fees were collected now.
     * This represents the protocol's earned but uncollected commission.
     * @return virtualShares Number of shares representing uncollected protocol fees
     */
    function _calculateVirtualFeeShares() internal view returns (uint256) {
        if (totalSupply() == 0) return 0;
        uint256 target =
            Math.mulDiv(totalSuppliedLiquidity, protocolConfig.profitTargetRate, baseDecimals, Math.Rounding.Floor);

        if (totalBase >= totalSuppliedLiquidity + target) {
            return target;
        }
        return 0;
    }

    /**
     * @dev Internal conversion function (from assets to shares) with support for rounding direction.
     * Modified to account for protocol commission by adjusting the total supply calculation.
     * @param assets Amount of assets to convert to shares
     * @param rounding Rounding direction for the conversion
     * @return shares Equivalent number of shares for the given assets
     */
    function _convertToShares(uint256 assets, Math.Rounding rounding)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 virtualSupply = supply + _calculateVirtualFeeShares();

        return Math.mulDiv(assets, virtualSupply + 10 ** _decimalsOffset(), totalAssets() + 1, rounding);
    }

    /**
     * @dev Internal conversion function (from shares to assets) with support for rounding direction.
     * Modified to account for protocol commission by adjusting the total supply calculation.
     * @param shares Number of shares to convert to assets
     * @param rounding Rounding direction for the conversion
     * @return assets Equivalent amount of assets for the given shares
     */
    function _convertToAssets(uint256 shares, Math.Rounding rounding)
        internal
        view
        virtual
        override
        returns (uint256)
    {
        uint256 supply = totalSupply();
        uint256 virtualSupply = supply + _calculateVirtualFeeShares();

        return Math.mulDiv(shares, totalAssets() + 1, virtualSupply + 10 ** _decimalsOffset(), rounding);
    }
}
