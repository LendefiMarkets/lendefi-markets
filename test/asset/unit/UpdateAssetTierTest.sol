// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract UpdateAssetTierTest is BasicDeploy {
    // Events
    event AssetTierUpdated(address indexed asset, IASSETS.CollateralTier tier);

    MockPriceOracle internal wethOracle;
    MockPriceOracle internal usdcOracle;

    function setUp() public {
        // Use the complete deployment function that includes Oracle module
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()

        // Deploy WETH if not already deployed
        if (address(wethInstance) == address(0)) {
            wethInstance = new WETH9();
        }

        // Set up mock oracles - use MockPriceOracle for more control over test values
        wethOracle = new MockPriceOracle();
        wethOracle.setPrice(2500e8); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        usdcOracle = new MockPriceOracle();
        usdcOracle.setPrice(1e8); // $1 per USDC
        usdcOracle.setTimestamp(block.timestamp);
        usdcOracle.setRoundId(1);
        usdcOracle.setAnsweredInRound(1);

        // Register oracles with Oracle module
        vm.startPrank(address(timelockInstance));

        // Add WETH as CROSS_A initially
        assetsInstance.updateAssetConfig(
            address(wethInstance), // asset
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 900, // 90%
                liquidationThreshold: 950, // 95%
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 10_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    twapPeriod: 1800,
                    active: 0 // Set to inactive to trigger the error
                })
            })
        );

        vm.stopPrank();
    }

    function test_UpdateAssetTier_AccessControl() public {
        // Regular user should not be able to update asset tier
        vm.startPrank(alice);

        // Using OpenZeppelin v5.0 AccessControl error format
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("MANAGER_ROLE")
            )
        );

        // Call to assetsInstance instead of marketCoreInstance
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.ISOLATED);
        vm.stopPrank();

        // Manager should be able to update asset tier
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.ISOLATED);

        // Verify tier was updated
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IASSETS.CollateralTier.ISOLATED));
    }

    function testRevert_UpdateAssetTier_RequireAssetListed() public {
        address unlisted = address(0x123); // Random unlisted address

        vm.startPrank(address(timelockInstance));

        // Using custom error format in LendefiAssets
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, unlisted));
        assetsInstance.updateAssetTier(unlisted, IASSETS.CollateralTier.ISOLATED);
        vm.stopPrank();
    }

    function test_UpdateAssetTier_StateChange_AllTiers() public {
        // Test updating to each possible tier
        vm.startPrank(address(timelockInstance));

        // Update to ISOLATED
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.ISOLATED);
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IASSETS.CollateralTier.ISOLATED));

        // Update to CROSS_A
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.CROSS_A);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IASSETS.CollateralTier.CROSS_A));

        // Update to CROSS_B
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.CROSS_B);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IASSETS.CollateralTier.CROSS_B));

        // Update to STABLE
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.STABLE);
        asset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(asset.tier), uint256(IASSETS.CollateralTier.STABLE));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Update WETH to ISOLATED
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.ISOLATED);
        IASSETS.Asset memory wethAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(IASSETS.CollateralTier.ISOLATED));

        // Update USDC to CROSS_B
        assetsInstance.updateAssetTier(address(usdcInstance), IASSETS.CollateralTier.CROSS_B);
        IASSETS.Asset memory usdcAsset = assetsInstance.getAssetInfo(address(usdcInstance));
        assertEq(uint256(usdcAsset.tier), uint256(IASSETS.CollateralTier.CROSS_B));

        // Ensure updates are independent
        wethAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(wethAsset.tier), uint256(IASSETS.CollateralTier.ISOLATED));

        vm.stopPrank();
    }

    function test_UpdateAssetTier_EventEmission() public {
        // The second parameter needs to be a uint8 representation of the enum
        vm.expectEmit(true, true, false, false);
        emit AssetTierUpdated(address(wethInstance), IASSETS.CollateralTier.ISOLATED);

        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.ISOLATED);
    }

    function test_UpdateAssetTier_NoChangeWhenSameTier() public {
        vm.startPrank(address(timelockInstance));

        // Get initial tier
        IASSETS.Asset memory initialAsset = assetsInstance.getAssetInfo(address(wethInstance));
        IASSETS.CollateralTier initialTier = initialAsset.tier;

        // The second parameter is also indexed in the contract
        vm.expectEmit(true, true, false, false);
        emit AssetTierUpdated(address(wethInstance), initialTier);

        // Update to same tier
        assetsInstance.updateAssetTier(address(wethInstance), initialTier);

        // Verify tier is unchanged
        IASSETS.Asset memory updatedAsset = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(updatedAsset.tier), uint256(initialTier));

        vm.stopPrank();
    }
}
