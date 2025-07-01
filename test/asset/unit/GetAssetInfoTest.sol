// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";

contract GetAssetInfoTest is BasicDeploy {
    // Oracle instances
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    WETHPriceConsumerV3 internal linkOracleInstance;
    WETHPriceConsumerV3 internal uniOracleInstance;

    function setUp() public {
        // Use deployMarketsWithUSDC() instead of deployComplete()
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()
        vm.warp(block.timestamp + 90 days);

        // Deploy WETH (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        stableOracleInstance.setPrice(1e8); // $1 per stable

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(marketCoreInstance));

        _setupAssets();
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH as CROSS_A tier
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% borrow threshold
                liquidationThreshold: 850, // 85% liquidation threshold
                maxSupplyThreshold: 1_000_000 ether, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        // Configure USDC as STABLE tier
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6, // USDC decimals
                borrowThreshold: 900, // 90% borrow threshold
                liquidationThreshold: 950, // 95% liquidation threshold
                maxSupplyThreshold: 1_000_000e6, // Supply limit
                isolationDebtCap: 0,
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        vm.stopPrank();
    }

    function test_GetAssetInfo_WETH() public {
        // UPDATED: Use assetsInstance for getAssetInfo
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 1, "WETH should be active");
        assertEq(asset.chainlinkConfig.oracleUSD, address(wethOracleInstance), "Oracle address mismatch");
        assertEq(asset.decimals, 18, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 800, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 850, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000 ether, "Supply limit mismatch");
        // UPDATED: Use IASSETS.CollateralTier instead of IPROTOCOL.CollateralTier
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.CROSS_A), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for non-isolated assets");
    }

    function test_GetAssetInfo_USDC() public {
        // UPDATED: Use assetsInstance for getAssetInfo
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(usdcInstance));

        assertEq(asset.active, 1, "USDC should be active");
        assertEq(asset.chainlinkConfig.oracleUSD, address(stableOracleInstance), "Oracle address mismatch");

        assertEq(asset.decimals, 6, "Asset decimals mismatch");
        assertEq(asset.borrowThreshold, 900, "Borrow threshold mismatch");
        assertEq(asset.liquidationThreshold, 950, "Liquidation threshold mismatch");
        assertEq(asset.maxSupplyThreshold, 1_000_000e6, "Supply limit mismatch");
        // UPDATED: Use IASSETS.CollateralTier instead of IPROTOCOL.CollateralTier
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.STABLE), "Tier mismatch");
        assertEq(asset.isolationDebtCap, 0, "Isolation debt cap should be 0 for STABLE assets");
    }

    function test_GetAssetInfo_Unlisted() public {
        // Using an address that's not configured as an asset
        address randomAddress = address(0x123);

        // UPDATED: Use assetsInstance and expect revert for unlisted asset
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, randomAddress));
        assetsInstance.getAssetInfo(randomAddress);
    }

    function test_GetAssetInfo_AfterUpdate() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        // UPDATED: Update WETH configuration using struct-based approach
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 0, // Set to inactive
                decimals: 18, // Asset decimals
                borrowThreshold: 750, // Change borrow threshold
                liquidationThreshold: 800, // Change liquidation threshold
                maxSupplyThreshold: 500_000 ether, // Lower supply limit
                isolationDebtCap: 1_000_000e6, // Add isolation debt cap
                assetMinimumOracles: 1, // Need at least 1 oracle
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B, // Change tier
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );

        vm.stopPrank();

        // Use assetsInstance for getAssetInfo
        asset = assetsInstance.getAssetInfo(address(wethInstance));

        assertEq(asset.active, 0, "WETH should be inactive after update");
        assertEq(asset.borrowThreshold, 750, "Borrow threshold should be updated");
        assertEq(asset.liquidationThreshold, 800, "Liquidation threshold should be updated");
        assertEq(asset.maxSupplyThreshold, 500_000 ether, "Supply limit should be updated");
        assertEq(uint8(asset.tier), uint8(IASSETS.CollateralTier.CROSS_B), "Tier should be updated");
        assertEq(asset.isolationDebtCap, 1_000_000e6, "Isolation debt cap should be updated");
    }
}
