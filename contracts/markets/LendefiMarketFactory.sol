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
 * @title Lendefi Market Factory
 * @author alexei@lendefimarkets(dot)com
 * @notice Factory contract for creating and managing LendefiCore + ERC4626 vault pairs for different base assets
 *         with multi-tenant support where each market owner can create isolated markets
 * @dev Creates composable lending markets where each market owner can deploy their own isolated lending market
 *      for any base asset. Uses OpenZeppelin's clone factory pattern for gas-efficient deployment.
 * @custom:security-contact security@lendefimarkets.com
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {LendefiCore} from "./LendefiCore.sol";
import {LendefiAssets} from "./LendefiAssets.sol";
import {LendefiMarketVault} from "./LendefiMarketVault.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {ILendefiMarketFactory} from "../interfaces/ILendefiMarketFactory.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {LendefiConstants} from "./lib/LendefiConstants.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @custom:oz-upgrades
contract LendefiMarketFactory is
    ILendefiMarketFactory,
    Initializable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable
{
    using Clones for address;
    using LendefiConstants for *;
    using EnumerableSet for EnumerableSet.AddressSet;
    using SafeERC20 for IERC20;

    /**
     * @notice Information about a scheduled contract upgrade
     */
    /**
     * @notice Struct to track pending upgrade requests
     * @param implementation Address of the new implementation contract
     * @param scheduledTime Timestamp when the upgrade was scheduled
     * @param exists Whether an upgrade request exists
     */
    struct UpgradeRequest {
        address implementation; // 20 bytes
        uint64 scheduledTime; // 8 bytes
        bool exists; // 1 byte
            // Note: This order matches interface expectations
            // Could be optimized to 29 bytes in single slot, but breaks compatibility
    }

    // ========== STATE VARIABLES ==========

    // ========== SLOT 0: uint256 variables ==========
    /// @notice Version of the factory contract
    uint256 public version;

    // ========== SLOT 1: uint256 variables ==========
    /// @notice Required governance token balance to create markets
    uint256 public requiredGovBalance;

    // ========== SLOT 2: uint256 variables ==========
    /// @notice Fee in governance tokens required for market creation
    uint256 public newMarketFee;

    // ========== SLOT 3: uint256 variables ==========
    /// @notice Maximum number of markets allowed per address
    uint256 public maxMarketsPerAddress;

    // ========== SLOT 4: uint256 variables ==========
    /// @notice Total governance tokens collected from market creation
    uint256 public totalGovTokensCollected;

    // ========== SLOT 5: Implementation addresses (5 addresses = 5 slots) ==========
    /// @notice Implementation contract address for LendefiCore instances
    /// @dev Used as template for cloning new core contracts for each market
    address public coreImplementation;

    /// @notice Implementation contract address for LendefiMarketVault instances
    /// @dev Used as template for cloning new vault contracts for each market
    address public vaultImplementation;

    /// @notice Implementation contract address for user position vault instances
    /// @dev Used by core contracts to create individual user position vaults
    address public positionVaultImplementation;

    /// @notice Implementation contract address for LendefiAssets instances
    /// @dev Used as template for cloning new assets module contracts for each market
    address public assetsModuleImplementation;

    /// @notice Address of the Proof of Reserves feed implementation
    /// @dev Template for creating PoR feeds for each market to track reserves
    address public porFeedImplementation;

    // ========== SLOT 10: Protocol addresses (5 addresses = 5 slots) ==========
    /// @notice Address of the protocol governance token
    /// @dev Used for liquidator threshold requirements and rewards distribution
    address public govToken;

    /// @notice Address of the timelock contract for administrative operations
    /// @dev Has admin privileges across all created markets for governance operations
    address public timelock;

    /// @notice Address of the multisig wallet for administrative operations
    /// @dev Has admin privileges across all created markets for governance operations
    address public multisig;

    /// @notice Address of the ecosystem contract for reward distribution
    /// @dev Handles governance token rewards for liquidity providers
    address public ecosystem;

    /// @notice Network-specific base stablecoin address (USDC on Ethereum, USDT on BSC)
    address public networkStable;

    // ========== SLOT 15: Network addresses (2 addresses = 2 slots) ==========
    /// @notice Network-specific wrapped native token address (WETH on Ethereum, WBNB on BSC)
    address public networkWrappedNative;

    /// @notice Primary DEX pool address for base/wrapped native pair
    address public primaryPool;

    // ========== SLOT 17: Struct (takes full slot) ==========
    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;

    // ========== SLOT 18: Complex storage structures ==========
    /// @notice Set of approved base assets that can be used for market creation
    /// @dev Only assets in this allowlist can be used to create new markets
    /// @dev Ensures only tested and verified assets are supported by the protocol
    EnumerableSet.AddressSet internal allowedBaseAssets;

    // ========== SLOT 19+: Mappings (separate slots each) ==========
    /// @notice Mapping from marketId (keccak256(owner, baseAsset)) to market configuration
    /// @dev Primary storage for markets using hash-based lookup for gas efficiency
    mapping(bytes32 => IPROTOCOL.Market) internal markets;

    /// @notice Mapping to track market IDs for each owner
    /// @dev Key: market owner address, Value: array of market IDs
    mapping(address => bytes32[]) internal ownerMarketIds;

    /// @notice Track number of markets created by each address
    mapping(address => uint256) internal marketsCreatedBy;

    /// @notice Storage gap for future upgrades
    /// @dev Storage gap reduced to account for new variables
    uint256[7] private __gap;

    // ========== MODIFIERS ==========

    /// @notice Ensures the base asset is on the allowlist for market creation
    /// @param baseAsset Address of the base asset to validate
    modifier onlyAllowedBaseAsset(address baseAsset) {
        if (!allowedBaseAssets.contains(baseAsset)) {
            revert BaseAssetNotAllowed();
        }
        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the factory contract with essential protocol addresses
     * @dev Sets up the factory with all required contract addresses and grants admin role to timelock.
     *      This function can only be called once due to the initializer modifier.
     * @param _timelock Address of the timelock contract that will have admin privileges
     * @param _govToken Address of the protocol governance token
     * @param _multisig Address of the Proof of Reserves feed implementation
     * @param _ecosystem Address of the ecosystem contract for rewards
     * @param _networkStable Network-specific base stablecoin address for oracle validation
     * @param _networkWrappedNative Network-specific wrapped native token address for oracle validation
     * @param _primaryPool Network-specific base/wrapped native pool for price reference
     *
     * @custom:requirements
     *   - All address parameters must be non-zero
     *   - Function can only be called once during deployment
     *
     * @custom:state-changes
     *   - Initializes AccessControl and UUPS upgradeable functionality
     *   - Grants DEFAULT_ADMIN_ROLE, UPGRADER_ROLE, and MANAGER_ROLE to the multisig address
     *   - Sets all protocol address state variables
     *
     * @custom:access-control Only callable during contract initialization
     * @custom:error-cases
     *   - ZeroAddress: When any required address parameter is zero
     */
    function initialize(
        address _timelock,
        address _govToken,
        address _multisig,
        address _ecosystem,
        address _networkStable,
        address _networkWrappedNative,
        address _primaryPool
    ) external initializer {
        if (
            _timelock == address(0) || _govToken == address(0) || _multisig == address(0) || _ecosystem == address(0)
                || _networkStable == address(0) || _networkWrappedNative == address(0) || _primaryPool == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __ReentrancyGuard_init();
        __Pausable_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _multisig);
        _grantRole(LendefiConstants.UPGRADER_ROLE, _multisig);
        _grantRole(LendefiConstants.MANAGER_ROLE, _multisig);
        _grantRole(LendefiConstants.PAUSER_ROLE, _multisig);

        govToken = _govToken;
        timelock = _timelock;
        multisig = _multisig;
        ecosystem = _ecosystem;

        // Set network-specific addresses
        networkStable = _networkStable;
        networkWrappedNative = _networkWrappedNative;
        primaryPool = _primaryPool;

        // Initialize permissionless parameters with reasonable defaults
        maxMarketsPerAddress = 21; // Default max 21 markets per address
        requiredGovBalance = 1000 ether; // Default 1000 tokens required balance
        newMarketFee = 100 ether; // Default 100 $LEND tokens required transfer

        version = 1;
    }

    // ========== PAUSE FUNCTIONS ==========

    /**
     * @notice Pauses market creation
     * @dev Prevents new markets from being created while allowing existing operations to continue
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *
     * @custom:state-changes
     *   - Sets contract to paused state
     *
     * @custom:emits Paused event with caller address
     * @custom:access-control Restricted to MANAGER_ROLE
     */
    function pause() external onlyRole(LendefiConstants.MANAGER_ROLE) {
        _pause();
    }

    /**
     * @notice Unpauses market creation
     * @dev Allows market creation to resume after being paused
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - Contract must be currently paused
     *
     * @custom:state-changes
     *   - Sets contract to unpaused state
     *
     * @custom:emits Unpaused event with caller address
     * @custom:access-control Restricted to MANAGER_ROLE
     */
    function unpause() external onlyRole(LendefiConstants.MANAGER_ROLE) {
        _unpause();
    }

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Sets the implementation contract addresses used for cloning new markets
     * @dev Updates the template contracts that will be cloned when creating new markets.
     *      These implementations must be properly initialized and tested before setting.
     * @param _coreImplementation Address of the LendefiCore implementation contract
     * @param _vaultImplementation Address of the LendefiMarketVault implementation contract
     * @param _positionVaultImplementation Address of the position vault implementation contract
     * @param _assetsModuleImplementation Address of the LendefiAssets implementation contract
     * @param _porFeed Address of the LendefiPoRFeed implementation contract
     *
     * @custom:requirements
     *   - All implementation addresses must be non-zero
     *   - Caller must have MANAGER_ROLE
     *
     * @custom:state-changes
     *   - Updates coreImplementation state variable
     *   - Updates vaultImplementation state variable
     *   - Updates positionVaultImplementation state variable
     *   - Updates assetsModuleImplementation state variable
     *   - Updates porFeedImplementation state variable
     *
     * @custom:emits ImplementationsSet event with the new implementation addresses
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When any implementation address is zero
     */
    function setImplementations(
        address _coreImplementation,
        address _vaultImplementation,
        address _positionVaultImplementation,
        address _assetsModuleImplementation,
        address _porFeed
    ) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (
            _coreImplementation == address(0) || _vaultImplementation == address(0)
                || _positionVaultImplementation == address(0) || _assetsModuleImplementation == address(0)
                || _porFeed == address(0)
        ) revert ZeroAddress();

        coreImplementation = _coreImplementation;
        vaultImplementation = _vaultImplementation;
        positionVaultImplementation = _positionVaultImplementation;
        assetsModuleImplementation = _assetsModuleImplementation;
        porFeedImplementation = _porFeed;

        emit ImplementationsSet(_coreImplementation, _vaultImplementation, _positionVaultImplementation);
    }

    /**
     * @notice Adds a base asset to the allowlist for market creation
     * @dev Allows the specified base asset to be used for creating new markets.
     *      Only assets that have been tested and verified should be added to ensure protocol security.
     * @param baseAsset Address of the base asset to add to the allowlist
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - baseAsset must be a valid address (non-zero)
     *   - baseAsset must not already be in the allowlist
     *
     * @custom:state-changes
     *   - Adds baseAsset to the allowedBaseAssets EnumerableSet
     *
     * @custom:emits BaseAssetAdded event with the asset address and admin
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     */
    function addAllowedBaseAsset(address baseAsset)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        returns (bool added)
    {
        if (baseAsset == address(0)) revert ZeroAddress();

        // Validate ERC20 token properties before adding to allowlist
        _validateTokenProperties(baseAsset);

        added = allowedBaseAssets.add(baseAsset);
        if (added) emit BaseAssetAdded(baseAsset, msg.sender);
    }

    /**
     * @notice Removes a base asset from the allowlist for market creation
     * @dev Prevents the specified base asset from being used for creating new markets.
     *      Existing markets with this base asset will continue to operate normally.
     * @param baseAsset Address of the base asset to remove from the allowlist
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - baseAsset must be a valid address (non-zero)
     *   - baseAsset must currently be in the allowlist
     *
     * @custom:state-changes
     *   - Removes baseAsset from the allowedBaseAssets EnumerableSet
     *
     * @custom:emits BaseAssetRemoved event with the asset address and admin
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     */
    function removeAllowedBaseAsset(address baseAsset)
        external
        onlyRole(LendefiConstants.MANAGER_ROLE)
        returns (bool removed)
    {
        if (baseAsset == address(0)) revert ZeroAddress();
        removed = allowedBaseAssets.remove(baseAsset);
        if (removed) emit BaseAssetRemoved(baseAsset, msg.sender);
    }

    /**
     * @notice Updates the maximum markets allowed per address
     * @dev Sets the limit on how many markets a single address can create
     * @param newMax The new maximum number of markets per address
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - newMax must be greater than 0
     *
     * @custom:state-changes
     *   - Updates maxMarketsPerAddress state variable
     *
     * @custom:emits MaxMarketsPerAddressUpdated event with old and new maximum
     * @custom:access-control Restricted to MANAGER_ROLE
     */
    function setMaxMarketsPerAddress(uint256 newMax) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (newMax == 0) revert InvalidZeroValue();
        uint256 oldMax = maxMarketsPerAddress;
        maxMarketsPerAddress = newMax;
        emit MaxMarketsPerAddressUpdated(oldMax, newMax, msg.sender);
    }

    /**
     * @notice Updates the required governance token balance for market creation
     * @dev Sets the minimum balance requirement for creating markets
     * @param newBalance The new required balance amount
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - newBalance must be greater than 0
     *
     * @custom:state-changes
     *   - Updates requiredGovBalance state variable
     *
     * @custom:emits RequiredGovBalanceUpdated event with old and new balance
     * @custom:access-control Restricted to MANAGER_ROLE
     */
    function setRequiredGovBalance(uint256 newBalance) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (newBalance == 0) revert InvalidZeroValue();
        uint256 oldBalance = requiredGovBalance;
        requiredGovBalance = newBalance;
        emit RequiredGovBalanceUpdated(oldBalance, newBalance, msg.sender);
    }

    /**
     * @notice Updates the governance token fee required for market creation
     * @dev Sets the amount of tokens that must be transferred when creating markets
     * @param newAmount The new required transfer amount
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - newAmount must be greater than 0
     *
     * @custom:state-changes
     *   - Updates newMarketFee state variable
     *
     * @custom:emits NewMarketFeeUpdated event with old and new amount
     * @custom:access-control Restricted to MANAGER_ROLE
     */
    function setNewMarketFee(uint256 newAmount) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (newAmount == 0) revert InvalidZeroValue();
        uint256 oldAmount = newMarketFee;
        newMarketFee = newAmount;
        emit NewMarketFeeUpdated(oldAmount, newAmount, msg.sender);
    }

    /**
     * @notice Withdraws collected governance tokens to the multisig address
     * @dev Transfers all collected governance tokens from market creation fees to the multisig wallet.
     *      Uses checks-effects-interactions pattern for security.
     *
     * @custom:requirements
     *   - Caller must have MANAGER_ROLE
     *   - Contract must have governance token balance to withdraw
     *
     * @custom:state-changes
     *   - Transfers all governance tokens from contract to multisig
     *
     * @custom:emits GovTokensWithdrawn event with multisig address and amount
     * @custom:access-control Restricted to MANAGER_ROLE
     * @custom:error-cases
     *   - NoTokensToWithdraw: When contract has zero governance token balance
     */
    function withdrawGovTokens() external nonReentrant onlyRole(LendefiConstants.MANAGER_ROLE) {
        IERC20 govTokenContract = IERC20(govToken);
        uint256 balance = govTokenContract.balanceOf(address(this));
        if (balance == 0) revert NoTokensToWithdraw();
        address cashedMultisig = multisig;

        // Effects: emit event before external interaction
        emit GovTokensWithdrawn(cashedMultisig, balance);

        // Interactions: external call last
        govTokenContract.safeTransfer(cashedMultisig, balance);
    }

    // ========== MARKET MANAGEMENT ==========

    /**
     * @notice Creates a new lending market for the caller and specified base asset
     * @dev Deploys a complete lending market infrastructure including:
     *      1. LendefiCore contract (cloned from implementation)
     *      2. LendefiMarketVault contract (cloned from implementation)
     *      3. Proof of Reserves feed (cloned from implementation)
     *      4. Proper initialization and cross-contract linking
     *
     *      Each market owner can create their own isolated lending markets where each base asset
     *      operates independently with its own liquidity pools and risk parameters.
     *      The caller (msg.sender) becomes the market owner.
     *
     *      PERMISSIONLESS: Anyone can create markets by paying the required fee.
     *
     * @param baseAsset The ERC20 token address that will serve as the base asset for lending
     * @param name The name for the ERC4626 yield token (e.g., "Lendefi USDC Yield Token")
     * @param symbol The symbol for the ERC4626 yield token (e.g., "lendUSDC")
     *
     * @custom:requirements
     *   - baseAsset must be a valid ERC20 token address (non-zero)
     *   - baseAsset must be in the allowed base assets list
     *   - Market for this caller/baseAsset pair must not already exist
     *   - Implementation contracts must be set before calling this function
     *   - Caller must have >= requiredGovBalance governance tokens in balance
     *   - Caller must approve factory to transfer newMarketFee governance tokens
     *   - Caller must not exceed maxMarketsPerAddress limit
     *
     * @custom:state-changes
     *   - Creates new market entry in nested markets mapping
     *   - Adds baseAsset to ownerBaseAssets mapping for the caller
     *   - Adds caller to allMarketOwners array (if first market)
     *   - Adds market info to allMarkets array
     *   - Deploys multiple new contract instances
     *   - Increments marketsCreatedBy[caller]
     *   - Updates totalGovTokensCollected
     *   - Transfers newMarketFee governance tokens from caller to factory
     *
     * @custom:emits
     *   - MarketCreated event with all deployed contract addresses
     *   - MarketCreatedDetailed event with comprehensive market info for indexing
     * @custom:access-control PERMISSIONLESS with governance token requirement
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     *   - BaseAssetNotAllowed: When baseAsset is not in allowlist
     *   - InsufficientGovTokenBalance: When caller balance < requiredGovBalance governance tokens
     *   - MaxMarketsReached: When caller has reached their market limit
     *   - MarketAlreadyExists: When market for this caller/asset pair already exists
     *   - CloneDeploymentFailed: When any contract clone deployment fails
     */
    function createMarket(address baseAsset, string memory name, string memory symbol)
        external
        nonReentrant
        whenNotPaused
        onlyAllowedBaseAsset(baseAsset)
    {
        // Validate string parameters
        _validateStringParameters(name, symbol);

        IERC20 govTokenContract = IERC20(govToken);
        _validateMarketCreation(msg.sender, baseAsset, govTokenContract);

        // Deploy and store market
        _deployAndStoreMarket(msg.sender, baseAsset, name, symbol);

        // Update state before external interactions (checks-effects-interactions pattern)
        uint256 cashedNewMarketFee = newMarketFee;

        marketsCreatedBy[msg.sender]++;
        totalGovTokensCollected += cashedNewMarketFee;

        // Transfer governance tokens from market creator
        govTokenContract.safeTransferFrom(msg.sender, address(this), cashedNewMarketFee);
    }

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @dev Only callable by addresses with LendefiConstants.UPGRADER_ROLE
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (newImplementation == address(0)) revert ZeroAddress();

        uint64 currentTime = uint64(block.timestamp);
        uint64 effectiveTime = currentTime + uint64(LendefiConstants.UPGRADE_TIMELOCK_DURATION);

        pendingUpgrade = UpgradeRequest({implementation: newImplementation, scheduledTime: currentTime, exists: true});

        emit UpgradeScheduled(msg.sender, newImplementation, currentTime, effectiveTime);
    }

    /**
     * @notice Cancels a previously scheduled upgrade
     * @dev Only callable by addresses with LendefiConstants.UPGRADER_ROLE
     */
    function cancelUpgrade() external onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }
        address implementation = pendingUpgrade.implementation;
        delete pendingUpgrade;
        emit UpgradeCancelled(msg.sender, implementation);
    }

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @dev Returns 0 if no upgrade is scheduled or if the timelock has expired
     * @return timeRemaining The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256) {
        return pendingUpgrade.exists
            && block.timestamp < pendingUpgrade.scheduledTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION
            ? pendingUpgrade.scheduledTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION - block.timestamp
            : 0;
    }

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Retrieves complete market information for a given market owner and base asset
     * @dev Returns the full Market struct containing all deployed contract addresses
     *      and configuration data for the specified market.
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to query market information for
     * @return Market configuration struct containing all market data
     *
     * @custom:requirements
     *   - marketOwner must be a valid address (non-zero)
     *   - baseAsset must be a valid address (non-zero)
     *   - Market for the specified marketOwner/baseAsset pair must exist
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:error-cases
     *   - ZeroAddress: When marketOwner or baseAsset is the zero address
     *   - MarketNotFound: When no market exists for the specified owner/asset pair
     */
    function getMarketInfo(address marketOwner, address baseAsset) external view returns (IPROTOCOL.Market memory) {
        if (marketOwner == address(0) || baseAsset == address(0)) {
            revert ZeroAddress();
        }

        bytes32 marketId = keccak256(abi.encodePacked(marketOwner, baseAsset));
        IPROTOCOL.Market memory market = markets[marketId];

        if (market.core == address(0)) {
            revert MarketNotFound();
        }

        return market;
    }

    /**
     * @notice Checks if a market is currently active for the specified owner and base asset
     * @dev Returns the active status flag from the market configuration.
     *      Markets can be deactivated for maintenance or emergency purposes.
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to check
     * @return bool True if the market is active, false if inactive or non-existent
     *
     * @custom:access-control Available to any caller (view function)
     */
    function isMarketActive(address marketOwner, address baseAsset) external view returns (bool) {
        bytes32 marketId = keccak256(abi.encodePacked(marketOwner, baseAsset));
        return markets[marketId].active;
    }

    /**
     * @notice Returns all markets created by a specific owner
     * @dev Retrieves all market configurations for a given market owner
     * @param marketOwner Address of the market owner to query
     * @return Array of Market structs for all markets owned by the specified address
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getOwnerMarkets(address marketOwner) external view returns (IPROTOCOL.Market[] memory) {
        bytes32[] memory marketIds = ownerMarketIds[marketOwner];
        uint256 len = marketIds.length;
        IPROTOCOL.Market[] memory ownerMarkets = new IPROTOCOL.Market[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                ownerMarkets[i] = markets[marketIds[i]];
            }
        }

        return ownerMarkets;
    }

    /**
     * @notice Returns all base assets for which a specific owner has created markets
     * @dev Retrieves the list of base asset addresses for a given market owner
     * @param marketOwner Address of the market owner to query
     * @return Array of base asset addresses
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getOwnerBaseAssets(address marketOwner) external view returns (address[] memory) {
        bytes32[] memory marketIds = ownerMarketIds[marketOwner];
        uint256 len = marketIds.length;
        address[] memory baseAssets = new address[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                baseAssets[i] = markets[marketIds[i]].baseAsset;
            }
        }

        return baseAssets;
    }

    /**
     * @notice Checks if a base asset is allowed for market creation
     * @dev Verifies whether the specified base asset is in the allowlist.
     *      Market owners can only create markets for assets that are in the allowlist.
     * @param baseAsset Address of the base asset to check
     * @return True if the base asset is in the allowlist, false otherwise
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:gas-efficient Uses EnumerableSet's efficient contains() method
     */
    function isBaseAssetAllowed(address baseAsset) external view returns (bool) {
        return allowedBaseAssets.contains(baseAsset);
    }

    /**
     * @notice Returns all allowed base assets
     * @dev Retrieves the complete list of base assets that can be used for market creation.
     *      This function is useful for UI applications to display available options.
     * @return Array of all allowed base asset addresses
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:gas-considerations May be expensive for large allowlists; consider pagination for UI
     */
    function getAllowedBaseAssets() external view returns (address[] memory) {
        return allowedBaseAssets.values();
    }

    /**
     * @notice Returns the number of allowed base assets
     * @dev Provides the count of assets in the allowlist without returning the full array.
     *      Useful for pagination and gas-efficient checks.
     * @return The count of allowed base assets
     *
     * @custom:access-control Available to any caller (view function)
     * @custom:gas-efficient Constant time operation regardless of allowlist size
     */
    function getAllowedBaseAssetsCount() external view returns (uint256) {
        return allowedBaseAssets.length();
    }

    /**
     * @dev Internal function to deploy core and vault contracts
     * @param baseAsset The base asset for the market
     * @param name The name for the market vault token
     * @param symbol The symbol for the market vault token
     * @return coreProxy Address of the deployed core proxy contract
     * @return vaultProxy Address of the deployed vault proxy contract
     * @return assetsModule Address of the deployed assets module
     */
    function _deployContracts(address baseAsset, string memory name, string memory symbol)
        internal
        returns (address coreProxy, address vaultProxy, address assetsModule)
    {
        // Cache storage variables that are used multiple times to avoid multiple SLOAD operations
        address cachedTimelock = timelock; // Used 4 times

        // Clone assets module for this market
        assetsModule = assetsModuleImplementation.clone();
        if (assetsModule == address(0) || assetsModule.code.length == 0) revert CloneDeploymentFailed();

        address core = coreImplementation.clone();
        if (core == address(0) || core.code.length == 0) revert CloneDeploymentFailed();

        // Initialize core contract through proxy
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector, cachedTimelock, msg.sender, govToken, positionVaultImplementation
        );
        coreProxy = address(new TransparentUpgradeableProxy(core, cachedTimelock, initData));

        // Initialize assets module contract through proxy
        bytes memory assetsInitData = abi.encodeWithSelector(
            LendefiAssets.initialize.selector,
            cachedTimelock,
            msg.sender,
            porFeedImplementation,
            coreProxy,
            networkStable,
            networkWrappedNative,
            primaryPool
        );
        assetsModule = address(new TransparentUpgradeableProxy(assetsModule, cachedTimelock, assetsInitData));

        // Create vault contract using minimal proxy pattern
        address baseVault = vaultImplementation.clone();
        if (baseVault == address(0) || baseVault.code.length == 0) revert CloneDeploymentFailed();

        // Initialize vault contract through proxy
        bytes memory vaultData = abi.encodeCall(
            LendefiMarketVault.initialize, (cachedTimelock, coreProxy, baseAsset, ecosystem, assetsModule, name, symbol)
        );
        vaultProxy = address(new TransparentUpgradeableProxy(baseVault, cachedTimelock, vaultData));
    }

    /**
     * @dev Internal function to deploy and store market
     * @param marketOwner Address of the market creator
     * @param baseAsset Address of the base asset
     * @param name Name of the market
     * @param symbol Symbol of the market
     */
    function _deployAndStoreMarket(address marketOwner, address baseAsset, string memory name, string memory symbol)
        internal
    {
        // Deploy core and vault contracts
        (address coreProxy, address vaultProxy, address assetsModule) = _deployContracts(baseAsset, name, symbol);

        // Deploy and initialize PoR feed
        address porFeedClone = _deployPoRFeed(baseAsset);

        // Create and store market configuration
        IPROTOCOL.Market memory marketInfo =
            _storeMarket(marketOwner, baseAsset, coreProxy, vaultProxy, porFeedClone, assetsModule, name, symbol);

        // Initialize the core contract with market information
        LendefiCore(payable(coreProxy)).initializeMarket(marketInfo);

        emit MarketCreated(marketOwner, baseAsset, coreProxy, vaultProxy, name, symbol, porFeedClone);
    }

    /**
     * @dev Internal function to deploy and initialize PoR feed
     * @param baseAsset The base asset for the PoR feed
     * @return porFeedClone Address of the deployed PoR feed clone
     */
    function _deployPoRFeed(address baseAsset) internal returns (address porFeedClone) {
        porFeedClone = porFeedImplementation.clone();
        if (porFeedClone == address(0) || porFeedClone.code.length == 0) {
            revert CloneDeploymentFailed();
        }

        // Cache timelock since it's used twice in the initialize call
        address cachedTimelock = timelock;
        IPoRFeed(porFeedClone).initialize(baseAsset, cachedTimelock, cachedTimelock);
    }

    /**
     * @dev Internal function to store market configuration
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset
     * @param coreProxy Address of the core proxy contract
     * @param vaultProxy Address of the vault proxy contract
     * @param porFeedClone Address of the PoR feed clone
     * @param assetsModule Address of the assets module
     * @param name Name of the market vault token
     * @param symbol Symbol of the market vault token
     */
    function _storeMarket(
        address marketOwner,
        address baseAsset,
        address coreProxy,
        address vaultProxy,
        address porFeedClone,
        address assetsModule,
        string memory name,
        string memory symbol
    ) internal returns (IPROTOCOL.Market memory marketInfo) {
        // Create market configuration struct
        marketInfo = IPROTOCOL.Market({
            core: coreProxy,
            baseVault: vaultProxy,
            baseAsset: baseAsset,
            assetsModule: assetsModule,
            porFeed: porFeedClone,
            decimals: IERC20Metadata(baseAsset).decimals(),
            name: name,
            symbol: symbol,
            createdAt: block.timestamp,
            active: true
        });

        // Compute market ID
        bytes32 marketId = keccak256(abi.encodePacked(marketOwner, baseAsset));

        // Store market using hash-based key
        markets[marketId] = marketInfo;

        // Track market IDs for this owner
        ownerMarketIds[marketOwner].push(marketId);

        // Emit comprehensive event for off-chain indexing
        emit MarketCreatedDetailed(
            marketOwner,
            baseAsset,
            coreProxy,
            vaultProxy,
            assetsModule,
            porFeedClone,
            name,
            symbol,
            uint8(marketInfo.decimals),
            block.timestamp
        );
    }

    // ========== UUPS UPGRADE AUTHORIZATION ==========

    /**
     * @notice Authorizes an upgrade to a new implementation
     * @dev Implements the upgrade verification and authorization logic
     * @param newImplementation Address of new implementation contract
     */
    function _authorizeUpgrade(address newImplementation) internal override onlyRole(LendefiConstants.UPGRADER_ROLE) {
        if (!pendingUpgrade.exists) {
            revert UpgradeNotScheduled();
        }

        if (pendingUpgrade.implementation != newImplementation) {
            revert ImplementationMismatch(pendingUpgrade.implementation, newImplementation);
        }

        uint256 timeElapsed = block.timestamp - pendingUpgrade.scheduledTime;
        if (timeElapsed < LendefiConstants.UPGRADE_TIMELOCK_DURATION) {
            revert UpgradeTimelockActive(LendefiConstants.UPGRADE_TIMELOCK_DURATION - timeElapsed);
        }

        // Clear the scheduled upgrade
        delete pendingUpgrade;

        ++version;
        emit Upgrade(msg.sender, newImplementation);
    }

    /**
     * @dev Internal function to validate ERC20 token properties
     * @param baseAsset Address of the token to validate
     */
    function _validateTokenProperties(address baseAsset) internal view {
        try IERC20Metadata(baseAsset).decimals() returns (uint8 decimals) {
            if (decimals > 18) {
                revert InvalidTokenProperties();
            }
        } catch {
            revert InvalidTokenProperties();
        }
    }

    /**
     * @dev Internal function to validate market creation requirements
     * @param marketOwner Address of the market creator
     * @param baseAsset Address of the base asset
     */
    function _validateMarketCreation(address marketOwner, address baseAsset, IERC20 govTokenContract) internal view {
        if (baseAsset == address(0)) revert ZeroAddress();

        // Cache storage variables to save gas
        uint256 cachedRequiredGovBalance = requiredGovBalance;
        uint256 cachedMaxMarketsPerAddress = maxMarketsPerAddress;

        // Check governance token balance requirement
        if (govTokenContract.balanceOf(marketOwner) < cachedRequiredGovBalance) {
            revert InsufficientGovTokenBalance();
        }

        // Check rate limiting
        if (marketsCreatedBy[marketOwner] >= cachedMaxMarketsPerAddress) {
            revert MaxMarketsReached();
        }

        // Check if market already exists
        bytes32 marketId = keccak256(abi.encodePacked(marketOwner, baseAsset));
        if (markets[marketId].core != address(0)) {
            revert MarketAlreadyExists();
        }
    }

    /**
     * @dev Internal function to validate string parameters
     * @param name The name parameter to validate
     * @param symbol The symbol parameter to validate
     */
    function _validateStringParameters(string memory name, string memory symbol) internal pure {
        if (bytes(name).length == 0 || bytes(name).length > 50) {
            revert InvalidStringParameter();
        }
        if (bytes(symbol).length == 0 || bytes(symbol).length > 10) {
            revert InvalidStringParameter();
        }
    }
}
