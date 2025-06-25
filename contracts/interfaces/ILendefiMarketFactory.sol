// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import {IPROTOCOL} from "./IProtocol.sol";

/**
 * @title ILendefiMarketFactory
 * @notice Interface for the Lendefi Market Factory contract
 * @dev Factory interface for creating and managing LendefiCore + ERC4626 vault pairs
 *      with multi-tenant support where each market owner can create isolated markets
 * @custom:security-contact security@lendefimarkets.com
 */
interface ILendefiMarketFactory {
    // ========== EVENTS ==========

    /**
     * @notice Emitted when a new lending market is successfully created
     * @param marketOwner The address that owns this market instance
     * @param baseAsset The base asset address for the new market
     * @param core The deployed LendefiCore contract address for this market
     * @param baseVault The deployed LendefiMarketVault contract address for this market
     * @param name The name of the ERC20 yield token for this market
     * @param symbol The symbol of the ERC20 yield token for this market
     * @param porFeed The deployed Proof of Reserves feed address for this market
     */
    event MarketCreated(
        address indexed marketOwner,
        address indexed baseAsset,
        address core,
        address baseVault,
        string name,
        string symbol,
        address porFeed
    );

    /**
     * @notice Emitted when market information is updated
     * @param marketOwner The address that owns the market being updated
     * @param baseAsset The base asset address of the updated market
     * @param marketInfo The updated market configuration data
     */
    event MarketUpdated(address indexed marketOwner, address indexed baseAsset, IPROTOCOL.Market marketInfo);

    /**
     * @notice Emitted when a market is removed or deactivated
     * @param marketOwner The address that owns the market being removed
     * @param baseAsset The base asset address of the removed market
     */
    event MarketRemoved(address indexed marketOwner, address indexed baseAsset);

    /**
     * @notice Emitted when implementation contracts are updated by admin
     * @param coreImplementation The new core implementation contract address
     * @param vaultImplementation The new vault implementation contract address
     * @param positionVaultImplementation The new position vault implementation contract address
     */
    event ImplementationsSet(
        address indexed coreImplementation,
        address indexed vaultImplementation,
        address indexed positionVaultImplementation
    );

    /**
     * @notice Emitted when implementation contract is upgraded
     * @param admin Address of the admin who performed the upgrade
     * @param implementation Address of the new implementation
     */
    event Upgrade(address indexed admin, address indexed implementation);

    /**
     * @notice Emitted when an upgrade is scheduled
     * @param scheduler The address scheduling the upgrade
     * @param implementation The new implementation contract address
     * @param scheduledTime The timestamp when the upgrade was scheduled
     * @param effectiveTime The timestamp when the upgrade can be executed
     */
    event UpgradeScheduled(
        address indexed scheduler, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /**
     * @notice Emitted when a scheduled upgrade is cancelled
     * @param canceller The address that cancelled the upgrade
     * @param implementation The implementation address that was cancelled
     */
    event UpgradeCancelled(address indexed canceller, address indexed implementation);

    /**
     * @notice Emitted when a base asset is added to the allowlist
     * @param baseAsset The base asset address that was added
     * @param admin The address that performed the addition
     */
    event BaseAssetAdded(address indexed baseAsset, address indexed admin);

    /**
     * @notice Emitted when a base asset is removed from the allowlist
     * @param baseAsset The base asset address that was removed
     * @param admin The address that performed the removal
     */
    event BaseAssetRemoved(address indexed baseAsset, address indexed admin);

    // ========== ERRORS ==========

    /// @notice Thrown when attempting to create a market for an owner/asset pair that already exists
    error MarketAlreadyExists();

    /// @notice Thrown when a required address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when trying to access a market that doesn't exist
    error MarketNotFound();

    /// @notice Thrown when clone deployment fails during market creation
    error CloneDeploymentFailed();

    /// @notice Thrown when an invalid contract address is provided
    error InvalidContract();

    /// @notice Thrown when attempting to execute an upgrade before timelock expires
    /// @param timeRemaining The time remaining until the upgrade can be executed
    error UpgradeTimelockActive(uint256 timeRemaining);

    /// @notice Thrown when attempting to execute an upgrade that wasn't scheduled
    error UpgradeNotScheduled();

    /// @notice Thrown when implementation address doesn't match scheduled upgrade
    /// @param scheduledImpl The address that was scheduled for upgrade
    /// @param attemptedImpl The address that was attempted to be used
    error ImplementationMismatch(address scheduledImpl, address attemptedImpl);

    /// @notice Thrown when attempting to create a market with a base asset that is not on the allowlist
    error BaseAssetNotAllowed();

    /// @notice Thrown when an invalid index is provided for array access
    error InvalidIndex();

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the factory contract with essential protocol addresses
     * @param _timelock Address of the timelock contract that will have admin privileges
     * @param _govToken Address of the protocol governance token
     * @param _multisig Address of the multisig wallet
     * @param _ecosystem Address of the ecosystem contract for rewards
     * @param _networkUSDC Network-specific USDC address for oracle validation
     * @param _networkWETH Network-specific WETH address for oracle validation
     * @param _UsdcWethPool Network-specific USDC/WETH pool for price reference
     */
    function initialize(
        address _timelock,
        address _govToken,
        address _multisig,
        address _ecosystem,
        address _networkUSDC,
        address _networkWETH,
        address _UsdcWethPool
    ) external;

    // ========== ADMIN FUNCTIONS ==========

    /**
     * @notice Sets the implementation contract addresses used for cloning new markets
     * @param _coreImplementation Address of the LendefiCore implementation contract
     * @param _vaultImplementation Address of the LendefiMarketVault implementation contract
     * @param _positionVaultImplementation Address of the position vault implementation contract
     * @param _assetsModuleImplementation Address of the assets module implementation contract
     * @param _PoRFeed Address of the Proof of Reserves feed implementation contract
     */
    function setImplementations(
        address _coreImplementation,
        address _vaultImplementation,
        address _positionVaultImplementation,
        address _assetsModuleImplementation,
        address _PoRFeed
    ) external;

    /**
     * @notice Adds a base asset to the allowlist for market creation
     * @param baseAsset Address of the base asset to add to the allowlist
     */
    function addAllowedBaseAsset(address baseAsset) external;

    /**
     * @notice Removes a base asset from the allowlist for market creation
     * @param baseAsset Address of the base asset to remove from the allowlist
     */
    function removeAllowedBaseAsset(address baseAsset) external;

    // ========== MARKET MANAGEMENT ==========

    /**
     * @notice Creates a new lending market for the caller and specified base asset
     * @param baseAsset The ERC20 token address that will serve as the base asset for lending
     * @param name The name for the ERC4626 yield token
     * @param symbol The symbol for the ERC4626 yield token
     */
    function createMarket(address baseAsset, string memory name, string memory symbol) external;

    /**
     * @notice Schedules an upgrade to a new implementation with timelock
     * @param newImplementation Address of the new implementation contract
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @notice Cancels a previously scheduled upgrade
     */
    function cancelUpgrade() external;

    // ========== VIEW FUNCTIONS ==========

    /**
     * @notice Returns the current version of the factory contract
     * @return The version number
     */
    function version() external view returns (uint256);

    /**
     * @notice Returns the core implementation address
     * @return The address of the core implementation
     */
    function coreImplementation() external view returns (address);

    /**
     * @notice Returns the vault implementation address
     * @return The address of the vault implementation
     */
    function vaultImplementation() external view returns (address);

    /**
     * @notice Returns the position vault implementation address
     * @return The address of the position vault implementation
     */
    function positionVaultImplementation() external view returns (address);

    /**
     * @notice Returns the assets module implementation address
     * @return The address of the assets module implementation
     */
    function assetsModuleImplementation() external view returns (address);

    /**
     * @notice Returns the PoR feed implementation address
     * @return The address of the PoR feed implementation
     */
    function porFeedImplementation() external view returns (address);

    /**
     * @notice Returns the governance token address
     * @return The address of the governance token
     */
    function govToken() external view returns (address);

    /**
     * @notice Returns the timelock address
     * @return The address of the timelock
     */
    function timelock() external view returns (address);

    /**
     * @notice Returns the multisig address
     * @return The address of the multisig
     */
    function multisig() external view returns (address);

    /**
     * @notice Returns the ecosystem address
     * @return The address of the ecosystem contract
     */
    function ecosystem() external view returns (address);

    /**
     * @notice Retrieves complete market information for a given market owner and base asset
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to query market information for
     * @return Market configuration struct containing all market data
     */
    function getMarketInfo(address marketOwner, address baseAsset) external view returns (IPROTOCOL.Market memory);

    /**
     * @notice Checks if a market is currently active for the specified owner and base asset
     * @param marketOwner Address of the market owner
     * @param baseAsset Address of the base asset to check
     * @return bool True if the market is active, false if inactive or non-existent
     */
    function isMarketActive(address marketOwner, address baseAsset) external view returns (bool);

    /**
     * @notice Returns all markets created by a specific owner
     * @param marketOwner Address of the market owner to query
     * @return Array of Market structs for all markets owned by the specified address
     */
    function getOwnerMarkets(address marketOwner) external view returns (IPROTOCOL.Market[] memory);

    /**
     * @notice Returns all base assets for which a specific owner has created markets
     * @param marketOwner Address of the market owner to query
     * @return Array of base asset addresses
     */
    function getOwnerBaseAssets(address marketOwner) external view returns (address[] memory);

    /**
     * @notice Returns all active markets across all owners
     * @return Array containing Market structs of all active markets
     */
    function getAllActiveMarkets() external view returns (IPROTOCOL.Market[] memory);

    /**
     * @notice Returns the total number of market owners
     * @return Total number of unique market owners
     */
    function getMarketOwnersCount() external view returns (uint256);

    /**
     * @notice Returns a market owner address by index
     * @param index The index of the owner to retrieve
     * @return Address of the market owner at the specified index
     */
    function getMarketOwnerByIndex(uint256 index) external view returns (address);

    /**
     * @notice Returns the total number of markets created across all owners
     * @return Total number of markets created
     */
    function getTotalMarketsCount() external view returns (uint256);

    /**
     * @notice Returns the remaining time before a scheduled upgrade can be executed
     * @return timeRemaining The time remaining in seconds
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @notice Returns information about a pending upgrade
     * @return implementation The address of the pending implementation
     * @return scheduledTime The timestamp when the upgrade was scheduled
     * @return exists Whether an upgrade is pending
     */
    function pendingUpgrade() external view returns (address implementation, uint64 scheduledTime, bool exists);

    /**
     * @notice Returns all market owners as an array
     * @return Array of all market owner addresses
     */
    function getAllMarketOwners() external view returns (address[] memory);

    /**
     * @notice Checks if a base asset is allowed for market creation
     * @param baseAsset Address of the base asset to check
     * @return True if the base asset is in the allowlist, false otherwise
     */
    function isBaseAssetAllowed(address baseAsset) external view returns (bool);

    /**
     * @notice Returns all allowed base assets
     * @return Array of all allowed base asset addresses
     */
    function getAllowedBaseAssets() external view returns (address[] memory);

    /**
     * @notice Returns the number of allowed base assets
     * @return The count of allowed base assets
     */
    function getAllowedBaseAssetsCount() external view returns (uint256);
}
