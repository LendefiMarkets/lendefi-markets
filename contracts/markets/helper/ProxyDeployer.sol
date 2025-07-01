// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
import {LendefiPositionVault} from "../LendefiPositionVault.sol";
import {LendefiCore} from "../LendefiCore.sol";
import {LendefiMarketVault} from "../LendefiMarketVault.sol";

contract ProxyDeployer {
    /**
     * @notice Deploys the LendefiMarketVault implementation using ERC1967Proxy pattern
     * @dev Follows the same pattern as deployLendefiCoreUpgrade but for market vault
     * @param baseAsset Address of the base asset for the market
     * @param timelockInstance Address of the timelock contract
     * @param tokenInstance Address of the governance token
     * @param ecosystemInstance Address of the ecosystem contract
     * @param assetsInstance Address of the assets module
     * @param name Name for the vault token
     * @param symbol Symbol for the vault token
     * @return vaultInstance Address of the deployed vault proxy
     */
    function deployMarketVaultProxy(
        address baseAsset,
        address timelockInstance,
        address tokenInstance,
        address ecosystemInstance,
        address assetsInstance,
        string memory name,
        string memory symbol
    ) public returns (address vaultInstance) {
        address positionVaultImpl = address(new LendefiPositionVault());
        address marketCore = deployLendefiCoreProxy(timelockInstance, tokenInstance, assetsInstance, positionVaultImpl);
        // Deploy base contracts first
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketVault.initialize.selector,
            address(timelockInstance), // _timelock
            address(marketCore), // core
            address(baseAsset), // baseAsset
            address(ecosystemInstance), // _ecosystem
            address(assetsInstance), // _assetsModule
            name, // name
            symbol // symbol
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiMarketVault.sol", initData));
        vaultInstance = address(LendefiMarketVault(proxy));
        address vaultImplementation = Upgrades.getImplementationAddress(proxy);
        require(address(vaultInstance) != vaultImplementation);
    }

    /**
     * @notice Deploys the LendefiCore implementation using ERC1967Proxy pattern
     * @dev Follows the same pattern as deployTimelockUpgrade
     */
    /**
     * @dev Deploys a LendefiCore proxy with initialization
     * @param timelockInstance Address of the timelock contract
     * @param tokenInstance Address of the governance token
     * @param assetsInstance Address of the assets module
     * @param positionVaultImpl Address of the position vault implementation
     * @return coreInstance Address of the deployed core proxy
     */
    function deployLendefiCoreProxy(
        address timelockInstance,
        address tokenInstance,
        address assetsInstance,
        address positionVaultImpl
    ) internal returns (address coreInstance) {
        // // Get initialization data from current core
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector,
            address(timelockInstance), // admin
            address(timelockInstance), // marketOwner (using timelock as market owner in this test helper)
            address(tokenInstance), // govToken_
            address(assetsInstance), // assetsModule_
            address(positionVaultImpl) // positionVault
        );
        address proxy = Upgrades.deployTransparentProxy("LendefiCore.sol", address(timelockInstance), initData);

        coreInstance = address(LendefiCore(payable(address(proxy))));
        address coreImplementation = Upgrades.getImplementationAddress(proxy);
        require(address(coreInstance) != coreImplementation);
    }
}
