// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;
/**
 * @title Governance Token Interface
 * @custom:security-contact security@lendefimarkets.com
 */

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";

interface ILENDEFI is IERC20, IERC20Metadata {
    /**
     * @dev TGE Event.
     * @param amount of initial supply
     */
    event TGE(uint256 amount);

    /**
     * @dev BridgeMint Event.
     * @param src sender address
     * @param to beneficiary address
     * @param amount to bridge
     */
    event BridgeMint(address indexed src, address indexed to, uint256 amount);

    /// @dev event emitted on UUPS upgrades
    /// @param src sender address
    /// @param implementation new implementation address
    event Upgrade(address indexed src, address indexed implementation);

    /// @dev event emitted when max bridge amount is updated
    /// @param src sender address
    /// @param oldMax old maximum bridge amount
    /// @param newMax new maximum bridge amount
    event MaxBridgeUpdated(address indexed src, uint256 oldMax, uint256 newMax);

    /// @dev event emitted when active chains count is updated
    /// @param src sender address
    /// @param oldCount old active chains count
    /// @param newCount new active chains count
    event ActiveChainsUpdated(address indexed src, uint32 oldCount, uint32 newCount);

    /// @dev event emitted when upgrade is scheduled
    /// @param src sender address
    /// @param implementation implementation address
    /// @param scheduledTime when upgrade was scheduled
    /// @param effectiveTime when upgrade can be executed
    event UpgradeScheduled(
        address indexed src, address indexed implementation, uint64 scheduledTime, uint64 effectiveTime
    );

    /// @dev event emitted when upgrade is cancelled
    /// @param src sender address
    /// @param implementation implementation address that was cancelled
    event UpgradeCancelled(address indexed src, address indexed implementation);

    /// @dev event emitted when bridge role is assigned
    /// @param src sender address
    /// @param bridge bridge address that received the role
    event BridgeRoleAssigned(address indexed src, address indexed bridge);

    /// @dev event emitted when CCIP admin is transferred
    /// @param oldAdmin old CCIP admin address
    /// @param newAdmin new CCIP admin address
    event CCIPAdminTransferred(address indexed oldAdmin, address indexed newAdmin);

    /**
     * @dev UUPS deploy proxy initializer.
     * @param guardian address
     * @param timelock address
     */
    function initializeUUPS(address guardian, address timelock) external;

    /**
     * @dev Performs TGE.
     * @param ecosystem contract address
     * @param treasury contract address
     * Emits a {TGE} event.
     */
    function initializeTGE(address ecosystem, address treasury) external;

    /**
     * @dev ERC20 pause contract.
     */
    function pause() external;

    /**
     * @dev ERC20 unpause contract.
     */
    function unpause() external;

    /**
     * @dev ERC20 Burn.
     * @param amount of tokens to burn
     * Emits a {Burn} event.
     */
    function burn(uint256 amount) external;

    /**
     * @dev ERC20 burn from.
     * @param account address
     * @param amount of tokens to burn from
     * Emits a {Burn} event.
     */
    function burnFrom(address account, uint256 amount) external;

    /**
     * @dev Facilitates Bridge BnM functionality.
     * @param to beneficiary address
     * @param amount to bridge
     */
    function mint(address to, uint256 amount) external;

    /**
     * @dev Getter for the Initial supply.
     * @return initial supply at TGE
     */
    function initialSupply() external view returns (uint256);

    /**
     * @dev Getter for the maximum amount alowed to pass through bridge in a single transaction.
     * @return maximum bridge transaction size
     */
    function maxBridge() external view returns (uint256);

    /**
     * @dev Getter for the UUPS version, incremented with every upgrade.
     * @return version number (1,2,3)
     */
    function version() external view returns (uint32);

    /**
     * @dev Updates the maximum allowed bridge amount per transaction
     * @param newMaxBridge New maximum bridge amount
     */
    function updateMaxBridgeAmount(uint256 newMaxBridge) external;

    /**
     * @dev Updates the number of active chains in the ecosystem
     * @param newActiveChains New active chains count
     */
    function updateActiveChains(uint32 newActiveChains) external;

    /**
     * @dev Schedules an upgrade to a new implementation
     * @param newImplementation Address of the new implementation
     */
    function scheduleUpgrade(address newImplementation) external;

    /**
     * @dev Cancels a previously scheduled upgrade
     */
    function cancelUpgrade() external;

    /**
     * @dev Grants both mint and burn roles to burnAndMinter
     * @param burnAndMinter Address to grant bridge role to
     */
    function grantMintAndBurnRoles(address burnAndMinter) external;

    /**
     * @dev Transfers the CCIPAdmin role to a new address
     * @param newAdmin The address to transfer the CCIPAdmin role to
     */
    function setCCIPAdmin(address newAdmin) external;

    /**
     * @dev Returns the current CCIPAdmin
     * @return The current CCIP admin address
     */
    function getCCIPAdmin() external view returns (address);

    /**
     * @dev Returns the remaining time before a scheduled upgrade can be executed
     * @return The time remaining in seconds, or 0 if no upgrade is scheduled or timelock has passed
     */
    function upgradeTimelockRemaining() external view returns (uint256);

    /**
     * @dev Getter for the TGE initialization status
     * @return TGE initialization count
     */
    function tge() external view returns (uint32);

    /**
     * @dev Getter for the number of active chains
     * @return Number of active chains in the ecosystem
     */
    function activeChains() external view returns (uint32);
}
