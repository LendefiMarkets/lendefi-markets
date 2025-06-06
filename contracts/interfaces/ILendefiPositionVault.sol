// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * @title ILendefiPositionVault
 * @notice Interface for the Lendefi position vault that isolates user position collateral
 */
interface ILendefiPositionVault {
    /// @notice Returns the address of the protocol that controls this vault
    function core() external view returns (address);

    /// @notice Returns the address of the vault owner
    function owner() external view returns (address);

    /// @notice Transfers tokens from the vault to the owner
    /// @param token Address of the token to transfer
    /// @param amount Amount to transfer
    function withdrawToken(address token, uint256 amount) external;

    /// @notice Transfers multiple token types to the liquidator during liquidation
    /// @param tokens Array of token addresses to liquidate
    /// @param liquidator Address receiving the tokens
    function liquidate(address[] calldata tokens, address liquidator) external;

    /// @notice Initializes the vault
    /// @param _core Address of the protocol that controls this vault
    /// @param _owner Address of the user who will own the collateral in this vault
    function initialize(address _core, address _owner) external;
}
