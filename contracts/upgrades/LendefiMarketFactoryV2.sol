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
 * @title Lendefi Market Factory V2
 * @author alexei@lendefimarkets(dot)com
 * @notice Factory contract for creating and managing LendefiCore + ERC4626 vault pairs for different base assets
 * @dev Creates composable lending markets where each base asset gets its own isolated lending market
 *      with dedicated core logic and vault implementation. Uses OpenZeppelin's clone factory pattern
 *      for gas-efficient deployment of market instances.
 * @custom:security-contact security@lendefimarkets.com
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */

import {LendefiCore} from "../markets/LendefiCore.sol";
import {LendefiMarketVault} from "../markets/LendefiMarketVault.sol";
import {IPROTOCOL} from "../interfaces/IProtocol.sol";
import {ILendefiMarketFactory} from "../interfaces/ILendefiMarketFactory.sol";
import {IASSETS} from "../interfaces/IASSETS.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoRFeed} from "../interfaces/IPoRFeed.sol";
import {LendefiConstants} from "../markets/lib/LendefiConstants.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {EnumerableSet} from "@openzeppelin/contracts/utils/structs/EnumerableSet.sol";

/// @custom:oz-upgrades-from contracts/markets/LendefiMarketFactory.sol:LendefiMarketFactory
contract LendefiMarketFactoryV2 is ILendefiMarketFactory, Initializable, AccessControlUpgradeable, UUPSUpgradeable {
    using Clones for address;
    using LendefiConstants for *;
    using EnumerableSet for EnumerableSet.AddressSet;

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
        address implementation;
        uint64 scheduledTime;
        bool exists;
    }

    // ========== STATE VARIABLES ==========

    /// @notice Version of the factory contract
    uint256 public version;

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

    /// @notice Network-specific USDC address
    address public networkUSDC;

    /// @notice Network-specific WETH address
    address public networkWETH;

    /// @notice Uniswap pool address for USDC/WETH
    address public usdcWethPool;

    /// @notice Set of approved base assets that can be used for market creation
    /// @dev Only assets in this allowlist can be used to create new markets
    /// @dev Ensures only tested and verified assets are supported by the protocol
    EnumerableSet.AddressSet private allowedBaseAssets;

    /// @notice Nested mapping of market owner to base asset to market configuration
    /// @dev First key: market owner address, Second key: base asset address, Value: Market struct
    mapping(address => mapping(address => IPROTOCOL.Market)) internal markets;

    /// @notice Mapping to track all base assets for each market owner
    /// @dev Key: market owner address, Value: EnumerableSet of base asset addresses they've created markets for
    mapping(address => EnumerableSet.AddressSet) internal ownerBaseAssets;

    /// @notice Set of all market owners who have created markets
    /// @dev Used for enumeration and iteration over all market owners with guaranteed uniqueness
    EnumerableSet.AddressSet internal allMarketOwners;

    /// @notice Array of all market configurations created by this factory
    /// @dev Provides direct access to all market data across all owners
    IPROTOCOL.Market[] internal allMarkets;

    /// @dev Pending upgrade information
    UpgradeRequest public pendingUpgrade;

    /// @notice Storage gap for future upgrades
    /// @dev Storage gap reduced to account for new variables
    uint256[13] private __gap;

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
     * @param _networkUSDC Network-specific USDC address for oracle validation
     * @param _networkWETH Network-specific WETH address for oracle validation
     * @param _usdcWethPool Network-specific USDC/WETH pool for price reference
     *
     * @custom:requirements
     *   - All address parameters must be non-zero
     *   - Function can only be called once during deployment
     *
     * @custom:state-changes
     *   - Initializes AccessControl and UUPS upgradeable functionality
     *   - Grants DEFAULT_ADMIN_ROLE to the timelock address
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
        address _networkUSDC,
        address _networkWETH,
        address _usdcWethPool
    ) external initializer {
        if (
            _timelock == address(0) || _govToken == address(0) || _multisig == address(0) || _ecosystem == address(0)
                || _networkUSDC == address(0) || _networkWETH == address(0) || _usdcWethPool == address(0)
        ) {
            revert ZeroAddress();
        }

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _multisig);
        _grantRole(LendefiConstants.UPGRADER_ROLE, _multisig);
        _grantRole(LendefiConstants.MANAGER_ROLE, _multisig);

        govToken = _govToken;
        timelock = _timelock;
        multisig = _multisig;
        ecosystem = _ecosystem;

        // Set network-specific addresses
        networkUSDC = _networkUSDC;
        networkWETH = _networkWETH;
        usdcWethPool = _usdcWethPool;

        version = 1;
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
     *   - Caller must have DEFAULT_ADMIN_ROLE
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
    function addAllowedBaseAsset(address baseAsset) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (baseAsset == address(0)) revert ZeroAddress();

        bool added = allowedBaseAssets.add(baseAsset);
        if (added) {
            emit BaseAssetAdded(baseAsset, msg.sender);
        }
    }

    /**
     * @notice Removes a base asset from the allowlist for market creation
     * @dev Prevents the specified base asset from being used for creating new markets.
     *      Existing markets with this base asset will continue to operate normally.
     * @param baseAsset Address of the base asset to remove from the allowlist
     *
     * @custom:requirements
     *   - Caller must have DEFAULT_ADMIN_ROLE
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
    function removeAllowedBaseAsset(address baseAsset) external onlyRole(LendefiConstants.MANAGER_ROLE) {
        if (baseAsset == address(0)) revert ZeroAddress();

        bool removed = allowedBaseAssets.remove(baseAsset);
        if (removed) {
            emit BaseAssetRemoved(baseAsset, msg.sender);
        }
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
     * @param baseAsset The ERC20 token address that will serve as the base asset for lending
     * @param name The name for the ERC4626 yield token (e.g., "Lendefi USDC Yield Token")
     * @param symbol The symbol for the ERC4626 yield token (e.g., "lendUSDC")
     *
     * @custom:requirements
     *   - baseAsset must be a valid ERC20 token address (non-zero)
     *   - Market for this caller/baseAsset pair must not already exist
     *   - Implementation contracts must be set before calling this function
     *   - Caller must have MARKET_OWNER_ROLE
     *
     * @custom:state-changes
     *   - Creates new market entry in nested markets mapping
     *   - Adds baseAsset to ownerBaseAssets mapping for the caller
     *   - Adds caller to allMarketOwners array (if first market)
     *   - Adds market info to allMarkets array
     *   - Deploys multiple new contract instances
     *
     * @custom:emits MarketCreated event with all deployed contract addresses
     * @custom:access-control Restricted to MARKET_OWNER_ROLE
     * @custom:error-cases
     *   - ZeroAddress: When baseAsset is the zero address
     *   - MarketAlreadyExists: When market for this caller/asset pair already exists
     *   - CloneDeploymentFailed: When any contract clone deployment fails
     */
    function createMarket(address baseAsset, string memory name, string memory symbol)
        external
        onlyRole(LendefiConstants.MARKET_OWNER_ROLE)
        onlyAllowedBaseAsset(baseAsset)
    {
        address marketOwner = msg.sender;
        if (baseAsset == address(0)) revert ZeroAddress();
        if (markets[marketOwner][baseAsset].core != address(0)) {
            revert MarketAlreadyExists();
        }

        // Deploy core and vault contracts
        (address coreProxy, address vaultProxy, address assetsModule) = _deployContracts(baseAsset, name, symbol);

        // Deploy and initialize PoR feed
        address porFeedClone = _deployPoRFeed(baseAsset);

        // Create and store market configuration
        _storeMarket(marketOwner, baseAsset, coreProxy, vaultProxy, porFeedClone, assetsModule, name, symbol);

        // Initialize the core contract with market information
        LendefiCore(payable(coreProxy)).initializeMarket(markets[marketOwner][baseAsset]);

        // Note: Market owner MANAGER_ROLE must be granted separately by timelock
        // since factory doesn't have DEFAULT_ADMIN_ROLE on the vault

        emit MarketCreated(marketOwner, baseAsset, coreProxy, vaultProxy, name, symbol, porFeedClone);
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
        if (markets[marketOwner][baseAsset].core == address(0)) {
            revert MarketNotFound();
        }

        return markets[marketOwner][baseAsset];
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
        return markets[marketOwner][baseAsset].active;
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
        address[] memory baseAssets = ownerBaseAssets[marketOwner].values();
        uint256 len = baseAssets.length;
        IPROTOCOL.Market[] memory ownerMarkets = new IPROTOCOL.Market[](len);

        unchecked {
            for (uint256 i; i < len; ++i) {
                ownerMarkets[i] = markets[marketOwner][baseAssets[i]];
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
        return ownerBaseAssets[marketOwner].values();
    }

    /**
     * @notice Returns all active markets across all owners
     * @dev Filters through all created markets and returns only those marked as active.
     * @return Array containing Market structs of all active markets
     *
     * @custom:gas-considerations This function iterates through all owners and markets,
     *                            which can be gas-intensive with many markets
     * @custom:access-control Available to any caller (view function)
     */
    function getAllActiveMarkets() external view returns (IPROTOCOL.Market[] memory) {
        // Use allMarkets array which already has all markets
        uint256 totalMarkets = allMarkets.length;
        uint256 activeCount;

        // First pass: count active markets
        unchecked {
            for (uint256 i; i < totalMarkets; ++i) {
                if (allMarkets[i].active) {
                    ++activeCount;
                }
            }
        }

        // Allocate result array
        IPROTOCOL.Market[] memory activeMarkets = new IPROTOCOL.Market[](activeCount);

        // Second pass: populate active markets
        if (activeCount > 0) {
            uint256 index;
            unchecked {
                for (uint256 i; i < totalMarkets; ++i) {
                    if (allMarkets[i].active) {
                        activeMarkets[index++] = allMarkets[i];
                        if (index == activeCount) break; // Early exit when all found
                    }
                }
            }
        }

        return activeMarkets;
    }

    /**
     * @notice Returns the total number of market owners
     * @dev Returns the length of the allMarketOwners set
     * @return Total number of unique market owners
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getMarketOwnersCount() external view returns (uint256) {
        return allMarketOwners.length();
    }

    /**
     * @notice Returns a market owner address by index
     * @dev Retrieves an owner address from the allMarketOwners set
     * @param index The index of the owner to retrieve
     * @return Address of the market owner at the specified index
     *
     * @custom:requirements
     *   - index must be less than allMarketOwners.length()
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getMarketOwnerByIndex(uint256 index) external view returns (address) {
        if (index >= allMarketOwners.length()) revert InvalidIndex();
        return allMarketOwners.at(index);
    }

    /**
     * @notice Returns all market owners as an array
     * @dev Retrieves all unique market owner addresses
     * @return Array of all market owner addresses
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getAllMarketOwners() external view returns (address[] memory) {
        return allMarketOwners.values();
    }

    /**
     * @notice Returns the total number of markets created across all owners
     * @dev Returns the length of the allMarkets array
     * @return Total number of markets created
     *
     * @custom:access-control Available to any caller (view function)
     */
    function getTotalMarketsCount() external view returns (uint256) {
        return allMarkets.length;
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
        // Clone assets module for this market
        assetsModule = assetsModuleImplementation.clone();
        if (assetsModule == address(0) || assetsModule.code.length == 0) revert CloneDeploymentFailed();

        address core = coreImplementation.clone();
        if (core == address(0) || core.code.length == 0) revert CloneDeploymentFailed();

        // Initialize core contract through proxy
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector, timelock, msg.sender, govToken, positionVaultImplementation
        );
        coreProxy = address(new TransparentUpgradeableProxy(core, timelock, initData));

        // Initialize assets module contract through proxy
        bytes memory assetsInitData = abi.encodeWithSelector(
            IASSETS.initialize.selector,
            timelock,
            msg.sender,
            porFeedImplementation,
            coreProxy,
            networkUSDC,
            networkWETH,
            usdcWethPool
        );
        assetsModule = address(new TransparentUpgradeableProxy(assetsModule, timelock, assetsInitData));

        // Create vault contract using minimal proxy pattern
        address baseVault = vaultImplementation.clone();
        if (baseVault == address(0) || baseVault.code.length == 0) revert CloneDeploymentFailed();

        // Initialize vault contract through proxy
        bytes memory vaultData = abi.encodeCall(
            LendefiMarketVault.initialize, (timelock, coreProxy, baseAsset, ecosystem, assetsModule, name, symbol)
        );
        vaultProxy = address(new TransparentUpgradeableProxy(baseVault, timelock, vaultData));
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

        IPoRFeed(porFeedClone).initialize(baseAsset, timelock, timelock);
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
    ) internal {
        // Create market configuration struct
        IPROTOCOL.Market memory marketInfo = IPROTOCOL.Market({
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

        // Store market information in nested mapping
        markets[marketOwner][baseAsset] = marketInfo;

        // Track base assets for this owner
        // This is guaranteed to succeed since we already verified the market doesn't exist
        ownerBaseAssets[marketOwner].add(baseAsset);

        // Track unique market owners (returns false if already exists, which is fine)
        allMarketOwners.add(marketOwner);

        // Add to global markets array
        allMarkets.push(marketInfo);
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
}
