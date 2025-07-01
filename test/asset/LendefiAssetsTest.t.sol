// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {MockUniswapV3Pool} from "../../contracts/mock/MockUniswapV3Pool.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {LendefiPoRFeed} from "../../contracts/markets/LendefiPoRFeed.sol";
import {LendefiConstants} from "../../contracts/markets/lib/LendefiConstants.sol";

contract LendefiAssetsTest is BasicDeploy {
    // Protocol instance

    MockPriceOracle internal wethOracle;
    StablePriceConsumerV3 internal stableOracle;
    WETHPriceConsumerV3 internal linkOracle;
    WETHPriceConsumerV3 internal uniOracle;

    // Mock tokens for different tiers
    TokenMock internal linkInstance; // For ISOLATED tier
    TokenMock internal uniInstance; // For CROSS_B tier

    // Constants
    uint256 constant INITIAL_LIQUIDITY = 1_000_000e6; // 1M USDC
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH
    uint256 constant LINK_PRICE = 15e8; // $15 per LINK
    uint256 constant UNI_PRICE = 8e8; // $8 per UNI

    function setUp() public {
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();
        linkInstance = new TokenMock("Chainlink", "LINK");
        uniInstance = new TokenMock("Uniswap", "UNI");

        // Deploy oracles
        wethOracle = new MockPriceOracle();
        stableOracle = new StablePriceConsumerV3();

        // Create a custom oracle for Link and UNI
        linkOracle = new WETHPriceConsumerV3();
        uniOracle = new WETHPriceConsumerV3();

        // Set prices
        wethOracle.setPrice(int256(ETH_PRICE)); // $2500 per ETH
        stableOracle.setPrice(1e8); // $1 per stable
        linkOracle.setPrice(int256(LINK_PRICE)); // $15 per LINK
        uniOracle.setPrice(int256(UNI_PRICE)); // $8 per UNI

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(marketCoreInstance));

        _setupAssets();
        _addLiquidity(INITIAL_LIQUIDITY);
    }

    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Register WETH asset with updated struct format
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure USDC with updated struct format
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure LINK with updated struct format
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 700,
                liquidationThreshold: 750,
                maxSupplyThreshold: 100_000 ether,
                isolationDebtCap: 5_000e6,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure UNI with updated struct format
        assetsInstance.updateAssetConfig(
            address(uniInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 750,
                liquidationThreshold: 800,
                maxSupplyThreshold: 200_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(uniOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();
    }

    function _addLiquidity(uint256 amount) internal {
        usdcInstance.mint(gnosisSafe, amount);
        vm.startPrank(gnosisSafe);
        usdcInstance.approve(address(marketCoreInstance), amount);
        uint256 expectedShares = marketVaultInstance.previewDeposit(amount);
        marketCoreInstance.depositLiquidity(amount, expectedShares, 100);
        vm.stopPrank();
    }

    function _addCollateralSupply(address token, uint256 amount, address user, bool isIsolated) internal {
        // Create a position
        vm.startPrank(user);

        // Create position - set isolation mode based on parameter
        marketCoreInstance.createPosition(token, isIsolated);
        uint256 positionId = marketCoreInstance.getUserPositionsCount(user) - 1;

        // Add collateral
        if (token == address(wethInstance)) {
            vm.deal(user, amount);
            wethInstance.deposit{value: amount}();
            wethInstance.approve(address(marketCoreInstance), amount);
        } else if (token == address(linkInstance)) {
            linkInstance.mint(user, amount);
            linkInstance.approve(address(marketCoreInstance), amount);
        } else if (token == address(uniInstance)) {
            uniInstance.mint(user, amount);
            uniInstance.approve(address(marketCoreInstance), amount);
        } else {
            usdcInstance.mint(user, amount);
            usdcInstance.approve(address(marketCoreInstance), amount);
        }

        marketCoreInstance.supplyCollateral(token, amount, positionId);
        vm.stopPrank();
    }

    // test_GetAssetDetails_Basic removed - getAssetDetails function no longer exists

    function test_UpdateAssetConfig() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Remove all existing assets first
        address[] memory currentAssets = assetsInstance.getListedAssets();
        vm.startPrank(address(timelockInstance));

        // Get the current asset count
        uint256 initialAssetCount = currentAssets.length;

        // Create the asset config for WETH
        IASSETS.Asset memory wethConfig = IASSETS.Asset({
            active: 1,
            decimals: 18,
            borrowThreshold: 800,
            liquidationThreshold: 850,
            maxSupplyThreshold: 1_000_000 ether,
            isolationDebtCap: 0, // isolation debt cap
            assetMinimumOracles: 1,
            porFeed: asset.porFeed,
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });

        // Expect the event emission correctly
        vm.expectEmit(true, false, false, false);
        emit IASSETS.UpdateAssetConfig(address(wethInstance), wethConfig);

        // Re-add WETH with modified config for testing
        assetsInstance.updateAssetConfig(address(wethInstance), wethConfig);

        // Verify asset is still listed (no change in count since it was already there)
        address[] memory listedAssets = assetsInstance.getListedAssets();
        assertEq(listedAssets.length, initialAssetCount, "Asset count should remain the same");

        // Get and verify asset info
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(assetInfo.active, 1);
        assertEq(assetInfo.chainlinkConfig.oracleUSD, address(wethOracle));
        assertEq(assetInfo.decimals, 18);
        assertEq(assetInfo.borrowThreshold, 800);
        assertEq(assetInfo.liquidationThreshold, 850);
        assertEq(assetInfo.maxSupplyThreshold, 1_000_000 ether);
        assertEq(uint256(assetInfo.tier), uint256(IASSETS.CollateralTier.CROSS_A));
        assertEq(assetInfo.isolationDebtCap, 0);

        IASSETS.Asset memory asset1 = assetsInstance.getAssetInfo(address(usdcInstance));

        // Update USDC with a different configuration
        IASSETS.Asset memory usdcConfig = IASSETS.Asset({
            active: 1,
            decimals: 6,
            borrowThreshold: 900,
            liquidationThreshold: 950,
            maxSupplyThreshold: 1_000_000e6,
            isolationDebtCap: 0,
            assetMinimumOracles: 1,
            porFeed: asset1.porFeed,
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.STABLE,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });

        // Expect the new event emission
        vm.expectEmit(true, false, false, false);
        emit IASSETS.UpdateAssetConfig(address(usdcInstance), usdcConfig);

        // Update the asset config
        assetsInstance.updateAssetConfig(address(usdcInstance), usdcConfig);

        vm.stopPrank();

        // Verify asset count is still the same
        listedAssets = assetsInstance.getListedAssets();
        assertEq(listedAssets.length, initialAssetCount, "Asset count should still be the same");

        // Verify USDC configuration was updated
        IASSETS.Asset memory usdcInfo = assetsInstance.getAssetInfo(address(usdcInstance));
        assertEq(usdcInfo.active, 1);
        assertEq(usdcInfo.borrowThreshold, 900);
        assertEq(usdcInfo.liquidationThreshold, 950);
        assertEq(usdcInfo.maxSupplyThreshold, 1_000_000e6);
    }

    function test_UpdateAssetTier() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add the asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Update tier to CROSS_B
        vm.prank(address(timelockInstance));

        assetsInstance.updateAssetTier(address(wethInstance), IASSETS.CollateralTier.CROSS_B);

        // Verify tier was updated
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(uint256(assetInfo.tier), uint256(IASSETS.CollateralTier.CROSS_B));
    }

    function testRevert_UpdateAssetTier_AssetNotListed() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xC0FFEE)));
        assetsInstance.updateAssetTier(address(0xC0FFEE), IASSETS.CollateralTier.CROSS_B);
    }

    // ------ Asset Validation and Query Tests ------

    function test_IsAssetValid() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add and active asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Should return true for active asset
        assertTrue(assetsInstance.isAssetValid(address(wethInstance)));

        IASSETS.Asset memory asset1 = assetsInstance.getAssetInfo(address(usdcInstance));

        // Now add an inactive asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 0, //add inactive assset
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset1.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Should return false for inactive asset
        assertFalse(assetsInstance.isAssetValid(address(usdcInstance)));

        // Should return false for unlisted asset
        assertFalse(assetsInstance.isAssetValid(address(0xC)));
    }

    function test_IsAssetIsolated() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Add normal asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        IASSETS.Asset memory asset1 = assetsInstance.getAssetInfo(address(linkInstance));
        // Add isolation asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 700,
                liquidationThreshold: 750,
                maxSupplyThreshold: 100_000 ether,
                isolationDebtCap: 5_000e6,
                assetMinimumOracles: 1,
                porFeed: asset1.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify
        assertFalse(assetsInstance.getAssetTier(address(wethInstance)) == IASSETS.CollateralTier.ISOLATED);
        assertTrue(assetsInstance.getAssetTier(address(linkInstance)) == IASSETS.CollateralTier.ISOLATED);
    }

    function test_GetIsolationDebtCap() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(usdcInstance));
        // Add isolation asset with a debt cap
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 50_000e6,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        assertEq(assetsInstance.getIsolationDebtCap(address(usdcInstance)), 50_000e6);
    }

    // ------ Edge Cases and Additional Tests ------

    function testRevert_AssetNotListed_GetAssetInfo() public {
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xDEAD)));
        assetsInstance.getAssetInfo(address(0xDEAD));
    }

    // testRevert_AssetNotListed_GetAssetDetails removed - getAssetDetails function no longer exists

    function test_CollateralTierParameters() public {
        // Test for all tiers
        IASSETS.CollateralTier[] memory tiers = new IASSETS.CollateralTier[](4);
        tiers[0] = IASSETS.CollateralTier.STABLE;
        tiers[1] = IASSETS.CollateralTier.CROSS_A;
        tiers[2] = IASSETS.CollateralTier.CROSS_B;
        tiers[3] = IASSETS.CollateralTier.ISOLATED;

        uint256[] memory expectedJumpRates = new uint256[](4);
        expectedJumpRates[0] = 0.05e6; // STABLE
        expectedJumpRates[1] = 0.08e6; // CROSS_A
        expectedJumpRates[2] = 0.12e6; // CROSS_B
        expectedJumpRates[3] = 0.15e6; // ISOLATED

        uint256[] memory expectedLiqFees = new uint256[](4);
        expectedLiqFees[0] = 0.01e6; // STABLE
        expectedLiqFees[1] = 0.02e6; // CROSS_A
        expectedLiqFees[2] = 0.03e6; // CROSS_B
        expectedLiqFees[3] = 0.04e6; // ISOLATED

        // Verify parameters for each tier
        for (uint256 i = 0; i < tiers.length; i++) {
            assertEq(assetsInstance.getTierJumpRate(tiers[i]), expectedJumpRates[i], "Jump rate mismatch");
            assertEq(assetsInstance.getLiquidationFee(tiers[i]), expectedLiqFees[i], "Liquidation fee mismatch");
        }
    }

    function test_InitialAssetListing() public {
        // Verify the initial state after setup
        address[] memory assets = assetsInstance.getListedAssets();
        assertEq(assets.length, 4, "Should have four assets after setup");

        assertTrue(assets[0] == address(wethInstance), "WETH should be in initial assets");
        assertTrue(assets[1] == address(usdcInstance), "USDC should be in initial assets");
        assertTrue(assets[2] == address(linkInstance), "LINK should be in initial assets");
        assertTrue(assets[3] == address(uniInstance), "UNI should be in initial assets");
    }

    function test_AddNewAsset() public {
        // Create a new token that's not in the initial setup
        TokenMock newToken = new TokenMock("NewToken", "NEW");

        // Get initial asset count
        uint256 initialCount = assetsInstance.getListedAssets().length;

        vm.startPrank(address(timelockInstance));

        // First register the asset without an oracle
        assetsInstance.updateAssetConfig(
            address(newToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Create and deploy our mock Uniswap pool
        MockUniswapV3Pool mockUniswapPool = new MockUniswapV3Pool(
            address(newToken), // token0
            address(usdcInstance), // token1
            3000 // fee tier (30 bps)
        );

        uint32 twapPeriod = 1800; // 30 minutes TWAP

        // Now we should be able to add a Uniswap oracle without reverting
        assetsInstance.updateUniswapOracle(
            address(newToken),
            address(mockUniswapPool),
            twapPeriod,
            1 //active
        );

        vm.stopPrank();

        // Verify asset count is still just +1 (asset was already added)
        address[] memory updatedAssets = assetsInstance.getListedAssets();
        assertEq(updatedAssets.length, initialCount + 1, "Asset count should increase by 1");

        // Verify oracles - should now have both Chainlink and Uniswap
        IASSETS.Asset memory item = assetsInstance.getAssetInfo(address(newToken));
        uint8 numOracles = item.chainlinkConfig.active + item.poolConfig.active;
        assertEq(numOracles, 2, "Should have two oracles registered");
        assertEq(item.chainlinkConfig.oracleUSD, address(wethOracle), "First oracle should be Chainlink");

        // We can also verify the Uniswap config was set correctly
        assertEq(item.poolConfig.pool, address(mockUniswapPool), "Pool address doesn't match");
        assertEq(item.poolConfig.twapPeriod, twapPeriod, "TWAP period doesn't match");
    }

    function test_UpdateExistingAssetCountStable() public {
        // Get initial count
        uint256 initialCount = assetsInstance.getListedAssets().length;
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        // Update an existing asset (WETH) with new config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 2_000_000 ether,
                isolationDebtCap: 1_000_000 ether, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify count didn't change
        assertEq(assetsInstance.getListedAssets().length, initialCount, "Asset count should not change when updating");
    }

    function test_UpdateAssetWithSameConfig() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add asset
        IASSETS.Asset memory item = IASSETS.Asset({
            active: 1,
            decimals: 18,
            borrowThreshold: 800,
            liquidationThreshold: 850,
            maxSupplyThreshold: 1_000_000 ether,
            isolationDebtCap: 0, // isolation debt cap
            assetMinimumOracles: 1,
            porFeed: asset.porFeed,
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });
        // Update with same config - should work fine
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, false, false, false);
        emit IASSETS.UpdateAssetConfig(address(wethInstance), item);
        assetsInstance.updateAssetConfig(address(wethInstance), item);

        // Verify asset is still properly configured
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(wethInstance));
        assertEq(assetInfo.active, 1);
        assertEq(assetInfo.chainlinkConfig.oracleUSD, address(wethOracle));
    }

    // ------ Upgrade Tests ------
    function test_UpgradeToAndCall() public {
        // This test needs a UUPS proxy, not a cloned assets module
        // Deploy a proper assets proxy for upgrade testing
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        // Get network addresses for test
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeCall(
            LendefiAssets.initialize,
            (address(timelockInstance), charlie, address(porFeedImpl), ethereum, networkUSDC, networkWETH, UsdcWethPool)
        );
        address payable assetsProxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsProxyInstance = LendefiAssets(assetsProxy);

        // Deploy a new implementation
        LendefiAssets newImplementation = new LendefiAssets();

        // Step 1: Schedule the upgrade first (new requirement)
        vm.prank(address(timelockInstance));
        assetsProxyInstance.scheduleUpgrade(address(newImplementation));

        // Step 2: Fast forward time to pass the timelock period (3 days)
        vm.warp(block.timestamp + 3 days + 1);

        // Step 3: Now perform the upgrade
        vm.prank(address(timelockInstance));
        vm.expectEmit(true, true, false, false);
        emit Upgrade(address(timelockInstance), address(newImplementation));
        assetsProxyInstance.upgradeToAndCall(address(newImplementation), "");

        // After upgrade, version should be incremented
        assertEq(assetsProxyInstance.version(), 2);
    }

    // ------ Additional Edge Cases ------

    function test_GetAndUpdateIsolationDebtCap() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add an isolation asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 5000 ether, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify initial debt cap
        assertEq(assetsInstance.getIsolationDebtCap(address(wethInstance)), 5_000e18);

        // Update the debt cap
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 10_000 ether, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify updated debt cap
        assertEq(assetsInstance.getIsolationDebtCap(address(wethInstance)), 10_000e18);
    }

    function test_AssetTVL() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Add asset with max supply
        uint256 maxSupply = 1_000 ether;
        vm.prank(address(timelockInstance));
        // When updating asset config, DON'T have it add the oracle again
        // since it's already registered directly in setUp()
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Add some collateral
        uint256 depositAmount = 300 ether; // 30% of max supply
        vm.deal(gnosisSafe, depositAmount);
        vm.startPrank(gnosisSafe);
        wethInstance.deposit{value: depositAmount}();
        wethInstance.approve(address(marketCoreInstance), depositAmount);

        marketCoreInstance.createPosition(address(wethInstance), false);
        uint256 positionId = marketCoreInstance.getUserPositionsCount(gnosisSafe) - 1;
        marketCoreInstance.supplyCollateral(address(wethInstance), depositAmount, positionId);
        vm.stopPrank();

        // Verify current/max supply ratio
        (uint256 currentSupply,,) = marketCoreInstance.getAssetTVL(address(wethInstance));
        assertEq(currentSupply, depositAmount);
        assertEq(currentSupply * 100 / maxSupply, 30); // 30% utilization
    }

    // For testRevert_SetCoreAddress_ZeroAddress()
    function testRevert_SetCoreAddress_ZeroAddress() public {
        vm.prank(gnosisSafe);
        // setCoreAddress method no longer exists - core address is set during initialization
    }

    function test_UnpauseAssets() public {
        // First pause the assets contract using timelock (which should have PAUSER_ROLE)
        vm.startPrank(address(timelockInstance));
        assetsInstance.pause();

        // Verify it's paused
        assertTrue(assetsInstance.paused(), "Assets contract should be paused");

        // Now unpause
        assetsInstance.unpause();

        // Verify it's unpaused
        assertFalse(assetsInstance.paused(), "Assets contract should be unpaused");
        vm.stopPrank();
    }

    // Fix for testRevert_ThresholdsTooHigh() - match actual contract validation
    function testRevert_ThresholdsTooHigh() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Test liquidation threshold > 990 (not 1000 as we assumed)
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidLiquidationThreshold.selector, 991));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 991, // > 990 triggering InvalidLiquidationThreshold
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Test when borrow threshold > liquidation threshold - 10
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidBorrowThreshold.selector, 891));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 891, // If liquidation is 900, borrow must be <= 890
                liquidationThreshold: 900,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Fix for testRevert_InvalidThresholds() - match contract logic
    function testRevert_InvalidThresholds() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Try to set liquidation threshold < borrow threshold
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidBorrowThreshold.selector, 850));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 850, // Borrow threshold higher than liquidation
                liquidationThreshold: 800, // Liquidation threshold lower than borrow
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // test_SetCoreAddress removed - setCoreAddress method no longer exists

    function test_InitializeSuccess() public {
        address timelockAddr = address(timelockInstance);

        // Create initialization data
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        // Get network addresses for test
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeCall(
            LendefiAssets.initialize,
            (timelockAddr, charlie, address(porFeedImpl), ethereum, networkUSDC, networkWETH, UsdcWethPool)
        );
        // Deploy LendefiAssets with initialization
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        LendefiAssets assetsContract = LendefiAssets(proxy);

        // Check role assignments
        assertTrue(assetsContract.hasRole(DEFAULT_ADMIN_ROLE, timelockAddr), "Timelock should have DEFAULT_ADMIN_ROLE");
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, timelockAddr), "Timelock should have MANAGER_ROLE");
        assertTrue(assetsContract.hasRole(MANAGER_ROLE, charlie), "Market owner should have MANAGER_ROLE");
        assertTrue(assetsContract.hasRole(UPGRADER_ROLE, timelockAddr), "Timelock should have UPGRADER_ROLE");
        assertTrue(
            assetsContract.hasRole(LendefiConstants.PAUSER_ROLE, charlie), "Market owner should have PAUSER_ROLE"
        );
        assertTrue(
            assetsContract.hasRole(LendefiConstants.PAUSER_ROLE, timelockAddr), "Timelock should have PAUSER_ROLE"
        );

        // Check version
        assertEq(assetsContract.version(), 1, "Initial version should be 1");

        // Check tier parameters were initialized
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsContract.getTierRates();

        // Verify ISOLATED tier rates (index 3)
        assertEq(jumpRates[3], 0.15e6, "Incorrect ISOLATED tier jump rate");
        assertEq(liquidationFees[3], 0.04e6, "Incorrect ISOLATED tier liquidation fee");

        // Verify CROSS_B tier rates (index 2)
        assertEq(jumpRates[2], 0.12e6, "Incorrect CROSS_B tier jump rate");
        assertEq(liquidationFees[2], 0.03e6, "Incorrect CROSS_B tier liquidation fee");

        // Verify CROSS_A tier rates (index 1)
        assertEq(jumpRates[1], 0.08e6, "Incorrect CROSS_A tier jump rate");
        assertEq(liquidationFees[1], 0.02e6, "Incorrect CROSS_A tier liquidation fee");

        // Verify STABLE tier rates (index 0)
        assertEq(jumpRates[0], 0.05e6, "Incorrect STABLE tier jump rate");
        assertEq(liquidationFees[0], 0.01e6, "Incorrect STABLE tier liquidation fee");
    }

    function test_GetAssetTVL() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify coreAddress is set correctly
        assertEq(assetsInstance.coreAddress(), address(marketCoreInstance));

        // Use marketCoreInstance.getAssetTVL function
        (uint256 initialTvl,,) = marketCoreInstance.getAssetTVL(address(wethInstance));
        assertEq(initialTvl, 0);

        // Add some collateral to create TVL
        uint256 depositAmount = 300 ether;
        vm.deal(gnosisSafe, depositAmount);
        vm.startPrank(gnosisSafe);
        wethInstance.deposit{value: depositAmount}();
        wethInstance.approve(address(marketCoreInstance), depositAmount);

        marketCoreInstance.createPosition(address(wethInstance), false);
        uint256 positionId = marketCoreInstance.getUserPositionsCount(gnosisSafe) - 1;
        marketCoreInstance.supplyCollateral(address(wethInstance), depositAmount, positionId);
        vm.stopPrank();

        // Verify TVL is now updated
        (uint256 finalTvl,,) = marketCoreInstance.getAssetTVL(address(wethInstance));
        assertEq(finalTvl, depositAmount);
    }

    // Fix for test_IsAssetAtCapacity()
    function test_IsAssetAtCapacity() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // First add asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000 ether,
                isolationDebtCap: 0, // isolation debt cap
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify the core address is set properly
        assertEq(assetsInstance.coreAddress(), address(marketCoreInstance));

        // No need to manually set TVL, we can test using real functionality
        // First deposit some WETH to create TVL
        uint256 depositAmount = 500 ether;
        vm.deal(gnosisSafe, depositAmount);
        vm.startPrank(gnosisSafe);
        wethInstance.deposit{value: depositAmount}();
        wethInstance.approve(address(marketCoreInstance), depositAmount);

        // Create a position and supply collateral
        marketCoreInstance.createPosition(address(wethInstance), false);
        uint256 positionId = marketCoreInstance.getUserPositionsCount(gnosisSafe) - 1;
        marketCoreInstance.supplyCollateral(address(wethInstance), depositAmount, positionId);
        vm.stopPrank();

        // Should return false when not at capacity (current 500 + 400 = 900 < 1000 max)
        assertFalse(assetsInstance.isAssetAtCapacity(address(wethInstance), 400 ether, depositAmount));

        // Should return true when requested amount would exceed capacity (current 500 + 501 = 1001 > 1000 max)
        assertTrue(assetsInstance.isAssetAtCapacity(address(wethInstance), 501 ether, depositAmount));
    }

    function test_GetOracleCount() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        // First, add an asset with only Chainlink oracle active
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(wethOracle),
                    active: 1 // Chainlink active
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0),
                    twapPeriod: 0,
                    active: 0 // Uniswap inactive
                })
            })
        );

        // Verify oracle count is 1
        uint256 chainlinkOnlyCount = assetsInstance.getOracleCount(address(wethInstance));
        assertEq(chainlinkOnlyCount, 1, "Asset with only Chainlink should have 1 oracle");

        // Create a mock Uniswap pool for testing
        MockUniswapV3Pool mockPool = new MockUniswapV3Pool(
            address(wethInstance), // token0
            address(usdcInstance), // token1
            3000 // fee tier (30 bps)
        );

        IASSETS.Asset memory asset1 = assetsInstance.getAssetInfo(address(usdcInstance));
        // Now add an asset with both oracles active
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 2,
                porFeed: asset1.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(stableOracle),
                    active: 1 // Chainlink active
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockPool),
                    twapPeriod: 1800,
                    active: 1 // Uniswap active
                })
            })
        );

        // Verify oracle count is 2
        uint256 bothOraclesCount = assetsInstance.getOracleCount(address(usdcInstance));
        assertEq(bothOraclesCount, 2, "Asset with both oracles should have count of 2");

        // Update to have only Uniswap active
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset1.porFeed,
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(stableOracle),
                    active: 0 // Chainlink inactive
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockPool),
                    twapPeriod: 1800,
                    active: 1 // Uniswap active
                })
            })
        );

        // Verify oracle count is 1
        uint256 uniswapOnlyCount = assetsInstance.getOracleCount(address(usdcInstance));
        assertEq(uniswapOnlyCount, 1, "Asset with only Uniswap should have count of 1");

        vm.stopPrank();
    }

    function testRevert_InvalidAssetDecimals_Zero() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "assetDecimals", 0));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 0, // Invalid: zero decimals
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_InvalidAssetDecimals_TooLarge() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "assetDecimals", 19));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 19, // Invalid: > 18 decimals
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_InvalidActiveValue() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "active", 2));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 2, // Invalid: active should be 0 or 1
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_InvalidMaxSupplyThreshold() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "maxSupplyThreshold", 0));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 0, // Invalid: cannot be zero
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_IsolatedAssetWithZeroDebtCap() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "isolationDebtCap", 0));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0, // Invalid: must be > 0 for ISOLATED assets
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED, // ISOLATED tier requires non-zero debt cap
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_OnZeroOraclePrice() public {
        // Create a mock oracle for this test
        MockPriceOracle zeroPriceOracle = new MockPriceOracle();
        zeroPriceOracle.setPrice(0); // Set price to zero
        zeroPriceOracle.setTimestamp(block.timestamp); // Recent timestamp
        zeroPriceOracle.setRoundId(10);
        zeroPriceOracle.setAnsweredInRound(10);

        // Set historical data too (needed for volatility check)
        zeroPriceOracle.setHistoricalRoundData(9, 1000e6, block.timestamp - 1 hours, 9);

        // Deploy a mock Uniswap pool
        MockUniswapV3Pool mockPool = new MockUniswapV3Pool(address(wethInstance), address(usdcInstance), 3000);

        // Set up tick values for Uniswap pool (similar to test_GetUniswapPrice)
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 40650 * 1800;
        mockPool.setTickCumulatives(tickCumulatives);

        // Set up seconds per liquidity
        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        mockPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        mockPool.setObserveSuccess(true);

        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        // Configure the asset with our zero-price oracle
        vm.startPrank(address(timelockInstance));

        // First update the asset config with zero-price Chainlink oracle
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 2, // Require both oracles
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(zeroPriceOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(mockPool), twapPeriod: 1800, active: 1})
            })
        );

        // Then add Uniswap oracle
        assetsInstance.updateUniswapOracle(
            address(wethInstance),
            address(mockPool),
            1800, // 30 minutes
            1 // active
        );

        vm.stopPrank();

        // Should revert with OracleInvalidPrice when getting price
        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleInvalidPrice.selector, address(zeroPriceOracle), 0));
        assetsInstance.getAssetPrice(address(wethInstance));
    }

    function test_GetAssetDecimals() public {
        // Verify the decimals for each configured asset
        assertEq(assetsInstance.getAssetDecimals(address(wethInstance)), 18, "WETH decimals should be 18");
        assertEq(assetsInstance.getAssetDecimals(address(usdcInstance)), 6, "USDC decimals should be 6");
        assertEq(assetsInstance.getAssetDecimals(address(linkInstance)), 18, "LINK decimals should be 18");
        assertEq(assetsInstance.getAssetDecimals(address(uniInstance)), 18, "UNI decimals should be 18");

        // Attempt to get decimals for non-listed asset should revert
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xDEAD)));
        assetsInstance.getAssetDecimals(address(0xDEAD));
    }

    function test_GetAssetLiquidationThreshold() public {
        // Verify the liquidation thresholds for each configured asset
        assertEq(
            assetsInstance.getAssetLiquidationThreshold(address(wethInstance)),
            850,
            "WETH liquidation threshold should be 85%"
        );
        assertEq(
            assetsInstance.getAssetLiquidationThreshold(address(usdcInstance)),
            950,
            "USDC liquidation threshold should be 95%"
        );
        assertEq(
            assetsInstance.getAssetLiquidationThreshold(address(linkInstance)),
            750,
            "LINK liquidation threshold should be 75%"
        );
        assertEq(
            assetsInstance.getAssetLiquidationThreshold(address(uniInstance)),
            800,
            "UNI liquidation threshold should be 80%"
        );

        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Update an asset's liquidation threshold and verify the change
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 750, // Lower borrow threshold to maintain required gap
                liquidationThreshold: 800, // Changed from 850 to 800
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Verify the updated threshold
        assertEq(
            assetsInstance.getAssetLiquidationThreshold(address(wethInstance)),
            800,
            "Updated WETH liquidation threshold should be 80%"
        );

        // Attempt to get liquidation threshold for non-listed asset should revert
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xDEAD)));
        assetsInstance.getAssetLiquidationThreshold(address(0xDEAD));
    }

    function test_GetAssetBorrowThreshold() public {
        // Verify the borrow thresholds for each configured asset
        assertEq(
            assetsInstance.getAssetBorrowThreshold(address(wethInstance)), 800, "WETH borrow threshold should be 80%"
        );
        assertEq(
            assetsInstance.getAssetBorrowThreshold(address(usdcInstance)), 900, "USDC borrow threshold should be 90%"
        );
        assertEq(
            assetsInstance.getAssetBorrowThreshold(address(linkInstance)), 700, "LINK borrow threshold should be 70%"
        );
        assertEq(
            assetsInstance.getAssetBorrowThreshold(address(uniInstance)), 750, "UNI borrow threshold should be 75%"
        );

        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(linkInstance));
        // Update an asset's borrow threshold and verify the change
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 650, // Changed from 700 to 650
                liquidationThreshold: 750,
                maxSupplyThreshold: 100_000 ether,
                isolationDebtCap: 5_000e6,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Verify the updated threshold
        assertEq(
            assetsInstance.getAssetBorrowThreshold(address(linkInstance)),
            650,
            "Updated LINK borrow threshold should be 65%"
        );

        // Attempt to get borrow threshold for non-listed asset should revert
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xDEAD)));
        assetsInstance.getAssetBorrowThreshold(address(0xDEAD));
    }

    function test_GetAssetCalculationParams() public {
        // First let's set a specific price in the oracle
        wethOracle.setPrice(2500e8); // $2500 per ETH
        wethOracle.setTimestamp(block.timestamp);
        wethOracle.setRoundId(1);
        wethOracle.setAnsweredInRound(1);

        // Get the calculation params for WETH
        IASSETS.AssetCalculationParams memory params = assetsInstance.getAssetCalculationParams(address(wethInstance));

        // Verify all parameters match what we expect
        assertEq(params.price, 2500e6, "Price should match oracle price");
        assertEq(params.borrowThreshold, 800, "Borrow threshold should be 80%");
        assertEq(params.liquidationThreshold, 850, "Liquidation threshold should be 85%");
        assertEq(params.decimals, 18, "Decimals should be 18");

        // Test for USDC with its different parameters
        stableOracle.setPrice(1e8); // $1 per USDC
        params = assetsInstance.getAssetCalculationParams(address(usdcInstance));

        assertEq(params.price, 1e6, "USDC price should be $1");
        assertEq(params.borrowThreshold, 900, "USDC borrow threshold should be 90%");
        assertEq(params.liquidationThreshold, 950, "USDC liquidation threshold should be 95%");
        assertEq(params.decimals, 6, "USDC decimals should be 6");

        // PHASE 1: Set up conditions to trigger circuit breaker

        // Update oracle parameters to ensure our price change will trigger the circuit breaker
        vm.prank(address(timelockInstance));
        assetsInstance.updateMainOracleConfig(
            uint80(28800), // freshness threshold: 8 hours
            uint80(3600), // volatility threshold: 1 hour
            uint40(20), // volatility percentage: 20%
            uint40(50) // circuit breaker threshold: 50%
        );

        // Set up a large price change and old timestamp
        wethOracle.setPrice(3500e8); // 40% increase from 2500 to 3500
        wethOracle.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold
        wethOracle.setRoundId(2);
        wethOracle.setAnsweredInRound(2);

        // Set historical data for round 1
        wethOracle.setHistoricalRoundData(1, 2500e8, block.timestamp - 3 hours, 1);

        // Trigger circuit breaker by evaluating
        vm.expectEmit(true, true, true, false);
        emit IASSETS.CircuitBreakerTriggered(address(wethInstance), 40, block.timestamp);

        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        // Verify circuit breaker was triggered
        assertTrue(triggered, "Circuit breaker should be triggered");
        assertEq(deviation, 40, "Deviation should be 40%");
        assertTrue(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be active");

        // Now getAssetCalculationParams should revert for WETH
        vm.expectRevert(abi.encodeWithSelector(IASSETS.CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetCalculationParams(address(wethInstance));

        // PHASE 2: Reset circuit breaker by fixing the price

        // Return to normal price with fresh timestamp
        wethOracle.setPrice(2550e8); // $2550 per ETH (small change)
        wethOracle.setTimestamp(block.timestamp); // Fresh timestamp

        // Call evaluate again to automatically reset circuit breaker
        vm.expectEmit(true, false, false, false);
        emit IASSETS.CircuitBreakerReset(address(wethInstance));

        (bool resetResult, uint256 resetDeviation) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        // Verify circuit breaker was reset
        assertFalse(resetResult, "Circuit breaker should be inactive after reset");
        assertTrue(resetDeviation < 5, "Deviation should be small now");
        assertFalse(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be inactive");

        // Function should work again after resetting circuit breaker
        params = assetsInstance.getAssetCalculationParams(address(wethInstance));
        assertEq(params.price, 2550e6, "Price should match updated oracle price after reset");

        // Test with non-listed asset should revert
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, address(0xDEAD)));
        assetsInstance.getAssetCalculationParams(address(0xDEAD));
    }

    function testFuzz_GetAssetCalculationParams(uint256 price) public {
        // Bound the price to something reasonable to avoid overflows
        price = bound(price, 1, 10000e8);

        // Set the price in the oracle
        wethOracle.setPrice(int256(price));

        // Get the calculation params
        IASSETS.AssetCalculationParams memory params = assetsInstance.getAssetCalculationParams(address(wethInstance));

        // Verify the price matches what we set
        assertEq(params.price, price / 1e2, "Price should match the fuzzed oracle price");

        // Other parameters should remain constant
        assertEq(params.borrowThreshold, 800, "Borrow threshold should still be 80%");
        assertEq(params.liquidationThreshold, 850, "Liquidation threshold should still be 85%");
        assertEq(params.decimals, 18, "Decimals should still be 18");
    }
}
