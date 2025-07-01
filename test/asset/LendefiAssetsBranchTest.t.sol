// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {LendefiAssets} from "../../contracts/markets/LendefiAssets.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {MockUniswapV3Pool} from "../../contracts/mock/MockUniswapV3Pool.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {MockWBTC} from "../../contracts/mock/MockWBTC.sol";

contract LendefiAssetsBranchTest is BasicDeploy {
    // Mock contracts
    MockUniswapV3Pool mockUniswapPool;
    MockUniswapV3Pool invalidPool;
    MockPriceOracle mockChainlinkOracle;
    MockWBTC mockWBTC;

    // Test users
    address unauthorizedUser = address(0xBEEF);

    // For upgrade tests, we need a proper UUPS proxy
    LendefiAssets assetsProxyForUpgrades;

    function setUp() public {
        // Deploy base contracts
        usdcInstance = new USDC();
        wethInstance = new WETH9();
        deployMarketsWithUSDC();

        // Deploy a separate assets proxy for upgrade testing
        // The market-based deployment gives us cloned assets modules, but upgrade tests need UUPS proxies
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        // Get network addresses for test
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeCall(
            LendefiAssets.initialize,
            (address(timelockInstance), charlie, address(porFeedImpl), ethereum, networkUSDC, networkWETH, UsdcWethPool)
        );
        address payable assetsProxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", initData));
        assetsProxyForUpgrades = LendefiAssets(assetsProxy);

        // Deploy mock contracts
        mockUniswapPool = new MockUniswapV3Pool(address(wethInstance), address(usdcInstance), 3000);
        invalidPool = new MockUniswapV3Pool(address(0xBBB), address(0xCCC), 3000);
        mockChainlinkOracle = new MockPriceOracle();
        mockWBTC = new MockWBTC();

        // Set up initial asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Set oracle to return valid data by default
        mockChainlinkOracle.setPrice(2500e8); // $2500 price
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(10);
        mockChainlinkOracle.setTimestamp(block.timestamp);

        // Setup historical data for tests that need it
        mockChainlinkOracle.setHistoricalRoundData(9, 2450e8, block.timestamp - 1 hours, 9);
    }

    // ======== 1. Protocol Upgrade Tests ========

    function test_1_1_ScheduleUpgradeWithoutRole() public {
        LendefiAssets newImplementation = new LendefiAssets();

        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, UPGRADER_ROLE
            )
        );
        assetsProxyForUpgrades.scheduleUpgrade(address(newImplementation));
    }

    function test_1_2_CancelUpgradeWithoutRole() public {
        // First schedule an upgrade
        LendefiAssets newImplementation = new LendefiAssets();

        vm.prank(address(timelockInstance));
        assetsProxyForUpgrades.scheduleUpgrade(address(newImplementation));

        // Attempt to cancel without proper role
        vm.prank(unauthorizedUser);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, unauthorizedUser, UPGRADER_ROLE
            )
        );
        assetsProxyForUpgrades.cancelUpgrade();
    }

    function test_1_3_UpgradeWithImplementationMismatch() public {
        // Schedule an upgrade with one implementation
        LendefiAssets scheduledImpl = new LendefiAssets();

        vm.prank(address(timelockInstance));
        assetsProxyForUpgrades.scheduleUpgrade(address(scheduledImpl));

        // Try to upgrade with a different implementation
        LendefiAssets differentImpl = new LendefiAssets();

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.ImplementationMismatch.selector, address(scheduledImpl), address(differentImpl)
            )
        );
        assetsProxyForUpgrades.upgradeToAndCall(address(differentImpl), "");
    }

    // ======== 2. Oracle Management Tests ========

    function test_2_1_UpdateUniswapOracleWithInvalidAsset() public {
        address invalidAsset = address(0xDEAD);

        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.AssetNotListed.selector, invalidAsset));
        assetsInstance.updateUniswapOracle(invalidAsset, address(mockUniswapPool), 1800, 1);
    }

    function test_2_2_UpdateUniswapOracleAssetNotInPool() public {
        // First add the tokenNotInPool as a valid asset
        vm.startPrank(address(timelockInstance));

        address tokenNotInPool = address(0xFFFF);

        // Add the token as a valid asset
        assetsInstance.updateAssetConfig(
            tokenNotInPool,
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Now try to add a Uniswap oracle where token is not in the pool
        vm.expectRevert(
            abi.encodeWithSelector(IASSETS.AssetNotInUniswapPool.selector, tokenNotInPool, address(mockUniswapPool))
        );
        assetsInstance.updateUniswapOracle(tokenNotInPool, address(mockUniswapPool), 1800, 1);
        vm.stopPrank();
    }

    // ======== 3. Configuration Tests ========

    function test_3_1_UpdateOracleConfigInvalidThresholds() public {
        vm.startPrank(address(timelockInstance));

        // Test freshness threshold
        vm.expectRevert(
            abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "freshness", 10 minutes, 15 minutes, 24 hours)
        );
        assetsInstance.updateMainOracleConfig(
            10 minutes, // Too low
            1 hours,
            10,
            50
        );

        // Test volatility threshold
        vm.expectRevert(
            abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "volatility", 3 minutes, 5 minutes, 4 hours)
        );
        assetsInstance.updateMainOracleConfig(
            1 hours,
            3 minutes, // Too low
            10,
            50
        );

        // Test volatility percent
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "volatilityPct", 3, 5, 30));
        assetsInstance.updateMainOracleConfig(
            1 hours,
            1 hours,
            3, // Too low
            50
        );

        // Test circuit breaker threshold
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "circuitBreaker", 20, 25, 70));
        assetsInstance.updateMainOracleConfig(
            1 hours,
            1 hours,
            10,
            20 // Too low
        );

        vm.stopPrank();
    }

    function test_3_2_UpdateTierConfigThresholds() public {
        vm.startPrank(address(timelockInstance));

        // Test jump rate too high
        vm.expectRevert(abi.encodeWithSelector(IASSETS.RateTooHigh.selector, 0.26e6, 0.25e6));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.26e6, // Too high
            0.02e6
        );

        // Test liquidation fee too high
        vm.expectRevert(abi.encodeWithSelector(IASSETS.FeeTooHigh.selector, 0.11e6, 0.1e6));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.08e6,
            0.11e6 // Too high
        );

        vm.stopPrank();
    }

    function test_3_3_UpdateAssetConfigInvalidThresholds() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidLiquidationThreshold.selector, 995));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 800,
                liquidationThreshold: 995, // > 990 (maximum allowed)
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();
    }

    // ======== 4. Oracle Price Tests ========

    function test_4_1_GetAssetPriceByTypeNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidUniswapConfig.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }

    function test_4_2_ChainlinkOracleInvalidPrice() public {
        // Set oracle to return invalid price
        mockChainlinkOracle.setPrice(0); // Zero price (invalid)

        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleInvalidPrice.selector, address(mockChainlinkOracle), 0));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    function test_4_3_ChainlinkOracleStalePrice() public {
        // Set oracle to return stale price
        mockChainlinkOracle.setRoundId(10); // Current round
        mockChainlinkOracle.setAnsweredInRound(5); // Answered in stale round

        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleStalePrice.selector, address(mockChainlinkOracle), 10, 5));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    function test_4_4_ChainlinkOracleTimeout() public {
        // Set oracle to return old price
        uint256 oldTimestamp = block.timestamp - 9 hours; // Freshness threshold is 8 hours for Ethereum mainnet
        mockChainlinkOracle.setTimestamp(oldTimestamp);

        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleTimeout.selector,
                address(mockChainlinkOracle),
                oldTimestamp,
                block.timestamp,
                28800 // 8 hours default freshness for Ethereum mainnet
            )
        );
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);
    }

    function test_4_5_OracleInvalidPriceVolatility() public {
        // Set up oracle configuration first
        vm.prank(address(timelockInstance));
        assetsInstance.updateMainOracleConfig(
            8 hours, // Default freshness
            30 minutes, // Volatility checking period
            20, // 20% max volatility
            50 // Circuit breaker threshold
        );

        // Set current price with timestamp exactly at volatilityThreshold age
        uint256 currentTimestamp = block.timestamp - 30 minutes; // Exactly at volatility threshold
        mockChainlinkOracle.setPrice(1000e8); // Current price
        mockChainlinkOracle.setTimestamp(currentTimestamp);
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(10);

        // Setup historical data for round 9
        uint256 pastTimestamp = currentTimestamp - 1 hours; // Some time before
        mockChainlinkOracle.setHistoricalRoundData(9, 500e8, pastTimestamp, 9);

        // This should now revert with OracleInvalidPriceVolatility
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleInvalidPriceVolatility.selector,
                address(mockChainlinkOracle),
                1000e8, // Current price
                100 // Percentage (100% change from 500 to 1000)
            )
        );
        assetsInstance.getAssetPrice(address(wethInstance));
    }

    function test_4_6_InvalidUniswapConfig() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        // First update with inactive Uniswap configuration
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK, // Keep Chainlink as primary
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockUniswapPool),
                    twapPeriod: 1800,
                    active: 0 // Inactive
                })
            })
        );

        vm.stopPrank();

        // Now when we try to use the Uniswap oracle specifically, it should get InvalidUniswapConfig
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidUniswapConfig.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }

    // ======== 5. Asset Management Tests ========

    function test_5_1_IsAssetAtCapacity() public {
        vm.startPrank(address(timelockInstance));

        // Mock marketCoreInstance.getAssetTVL call
        vm.mockCall(
            address(marketCoreInstance),
            abi.encodeWithSelector(marketCoreInstance.getAssetTVL.selector, address(wethInstance)),
            abi.encode(500_000e18, 1_250_000e8, block.timestamp) // TVL, TVL USD, lastUpdate
        );
        vm.stopPrank();

        // Test not at capacity
        bool atCapacity1 = assetsInstance.isAssetAtCapacity(address(wethInstance), 400_000e18, 500_000e18);
        assertFalse(atCapacity1, "Should not be at capacity with 900,000e18 total");

        // Test at capacity
        bool atCapacity2 = assetsInstance.isAssetAtCapacity(address(wethInstance), 600_000e18, 500_000e18);
        assertTrue(atCapacity2, "Should be at capacity with 1,100,000e18 total");
    }

    function test_5_2_AssetActivationDeactivation() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        // First activate an asset (active = 1)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1, // Active
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify asset is active
        assertTrue(assetsInstance.isAssetValid(address(wethInstance)), "Asset should be active");

        // Now deactivate the asset (active = 0)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 0, // Inactive
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify asset is inactive
        assertFalse(assetsInstance.isAssetValid(address(wethInstance)), "Asset should be inactive");

        vm.stopPrank();
    }

    // ======== 6. Circuit Breaker Tests ========

    function test_6_1_DualOraclePriceDeviation() public {
        vm.startPrank(address(timelockInstance));

        // First set up the oracle configuration
        assetsInstance.updateMainOracleConfig(
            8 hours, // freshnessThreshold
            1 hours, // volatilityThreshold
            20, // volatilityPercentage (20%)
            50 // circuitBreakerThreshold (50%)
        );
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Configure wethInstance with both oracles active
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockUniswapPool),
                    twapPeriod: 900,
                    active: 1 // Both oracles active
                })
            })
        );
        vm.stopPrank();

        // Mock Chainlink to return $2500
        mockChainlinkOracle.setPrice(2500e8);
        mockChainlinkOracle.setTimestamp(block.timestamp);

        // Configure tick cumulatives to simulate $1250 price (50% difference)
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        // -203200 * 900 for half the price of the example
        tickCumulatives[1] = -182880000; // -203200 * 900
        mockUniswapPool.setTickCumulatives(tickCumulatives);

        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        mockUniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        mockUniswapPool.setObserveSuccess(true);

        // Call evaluateCircuitBreaker and verify it triggers due to deviation
        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        assertTrue(triggered, "Circuit breaker should be triggered");
        assertGe(deviation, 50, "Deviation should be at least 50%");

        // Verify circuit breaker is now active
        assertTrue(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be active");
    }

    function test_6_2_CircuitBreakerUnchangedStatus() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // First call, circuit breaker should remain inactive
        (bool triggered1, uint256 deviation1) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        assertFalse(triggered1, "Circuit breaker should not be triggered");
        assertEq(deviation1, 2, "Deviation should be 2% with single oracle"); // Updated to expect 2%
        assertFalse(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should remain inactive");

        // Second call without changing conditions
        // This should hit the return (circuitBroken[asset], deviationPct) line
        (bool triggered2, uint256 deviation2) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        assertFalse(triggered2, "Circuit breaker should still not be triggered");
        assertEq(deviation2, 2, "Deviation should still be 2%"); // Updated to expect 2%
        assertFalse(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should still be inactive");
    }

    // ======== 7. Additional Coverage Tests ========

    // Test 7.1: Fix poolLiquidityLimit test
    function test_7_1_PoolLiquidityLimit() public {
        vm.deal(address(this), 100 ether);
        wethInstance.deposit{value: 100 ether}();
        wethInstance.transfer(address(mockUniswapPool), 100 ether);
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        vm.startPrank(address(timelockInstance));
        // Configure test token with active Uniswap oracle
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle), // Use mockChainlinkOracle instead of address(0)
                    active: 0 // Still inactive
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockUniswapPool),
                    twapPeriod: 900,
                    active: 1 // Uniswap active
                })
            })
        );
        vm.stopPrank();

        // Case 1: Amount is below 3% of pool liquidity
        uint256 smallAmount = 2.99e18; // 2.999% of pool balance
        bool limitReached1 = assetsInstance.poolLiquidityLimit(address(wethInstance), smallAmount);
        assertFalse(limitReached1, "Should not reach limit with amount < 3% of pool liquidity");

        // Case 2: Amount exceeds 3% of pool liquidity
        uint256 largeAmount = 3.01e18; // 3.001% of pool balance
        bool limitReached2 = assetsInstance.poolLiquidityLimit(address(wethInstance), largeAmount);
        assertTrue(limitReached2, "Should reach limit with amount > 3% of pool liquidity");
    }

    // ======== 8. Coverage Gap Tests ========

    function test_8_1_CheckPriceDeviationWithInsufficientOracles() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Configure wethInstance with only one active oracle
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockUniswapPool),
                    twapPeriod: 900,
                    active: 0 // Only Chainlink is active
                })
            })
        );
        vm.stopPrank();

        // Try to check price deviation - should revert because we don't have 2 active oracles
        vm.expectRevert(abi.encodeWithSelector(IASSETS.NotEnoughValidOracles.selector, address(wethInstance), 2, 1));
        assetsInstance.checkPriceDeviation(address(wethInstance));
    }

    function test_8_2_OracleValidationNonActiveUniswaap() public {
        // Deploy a test token for this specific test
        MockWBTC testToken = new MockWBTC();

        vm.startPrank(address(timelockInstance));

        // Configure Uniswap pool for test token
        MockUniswapV3Pool tokenPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));

        // Try to set a token with primary oracle as Uniswap but with inactive Uniswap
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleNotActive.selector, address(testToken), IASSETS.OracleType.UNISWAP_V3_TWAP
            )
        );
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP, // Uniswap as primary
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(mockChainlinkOracle),
                    active: 1 // Chainlink active
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(tokenPool),
                    twapPeriod: 900,
                    active: 0 // But Uniswap INACTIVE
                })
            })
        );
        vm.stopPrank();
    }

    function testRevert_GetAssetPriceByTypeCircuitBreakerActive() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        vm.startPrank(address(timelockInstance));

        // First set up the oracle configuration
        assetsInstance.updateMainOracleConfig(
            8 hours, // freshnessThreshold
            1 hours, // volatilityThreshold
            20, // volatilityPercentage (20%)
            50 // circuitBreakerThreshold (50%)
        );

        // Configure wethInstance with both oracles active
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockChainlinkOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockUniswapPool),
                    twapPeriod: 900,
                    active: 1 // Both oracles active
                })
            })
        );
        vm.stopPrank();

        // Mock Chainlink to return $2500
        mockChainlinkOracle.setPrice(2500e8);
        mockChainlinkOracle.setTimestamp(block.timestamp);
        mockChainlinkOracle.setRoundId(10);
        mockChainlinkOracle.setAnsweredInRound(10);

        // Configure tick cumulatives to simulate $1250 price (50% difference)
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = -182880000; // -203200 * 900
        mockUniswapPool.setTickCumulatives(tickCumulatives);

        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        mockUniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        mockUniswapPool.setObserveSuccess(true);

        // First trigger the circuit breaker
        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));
        assertTrue(triggered, "Circuit breaker should be triggered");
        assertGe(deviation, 50, "Deviation should be at least 50%");
        assertTrue(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be active");

        // Now try to get price by type when circuit breaker is active
        vm.expectRevert(abi.encodeWithSelector(IASSETS.CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.CHAINLINK);

        // Also verify it fails for the other oracle type
        vm.expectRevert(abi.encodeWithSelector(IASSETS.CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPriceByType(address(wethInstance), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }
}
