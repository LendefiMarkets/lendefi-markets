// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {MockUniswapV3Pool} from "../../contracts/mock/MockUniswapV3Pool.sol";

contract AssetModuleOracleTest is BasicDeploy {
    // Test tokens
    MockRWA internal rwaToken;
    MockRWA internal stableToken;
    uint8 internal decimals;

    // Mock oracles
    MockPriceOracle internal mockOracle1;
    MockPriceOracle internal mockOracle2;
    MockPriceOracle internal mockOracle3;
    WETHPriceConsumerV3 internal wethOracleInstance;
    RWAPriceConsumerV3 internal rwaOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;

    // Events to verify

    event OracleAdded(address indexed asset, address indexed oracle);
    event OracleRemoved(address indexed asset, address indexed oracle);
    event PrimaryOracleSet(address indexed asset, IASSETS.OracleType oracleType);
    event FreshnessThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityThresholdUpdated(uint256 oldValue, uint256 newValue);
    event VolatilityPercentageUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerThresholdUpdated(uint256 oldValue, uint256 newValue);
    event CircuitBreakerTriggered(address indexed asset, uint256 deviationPct, uint256 timestamp);
    event CircuitBreakerReset(address indexed asset);
    event PriceUpdated(address indexed asset, uint256 price, uint256 median, uint256 numOracles);
    event MinimumOraclesUpdated(uint256 oldValue, uint256 newValue);
    event AssetMinimumOraclesUpdated(address indexed asset, uint256 oldValue, uint256 newValue);
    event NotEnoughOraclesWarning(address indexed asset, uint256 required, uint256 actual);

    error NotEnoughOracles(address asset, uint256 required, uint256 actual);
    error LargeDeviation(address asset, uint256 currentPrice, uint256 previousPrice, uint256 percentChange);
    error CircuitBreakerActive(address asset);
    error OracleInvalidPrice(address oracle, int256 price);
    error OracleStalePrice(address oracle, uint80 roundId, uint80 answeredInRound);
    error OracleTimeout(address oracle, uint256 timestamp, uint256 currentTimestamp, uint256 maxAge);
    error OracleNotFound(address asset);
    error OracleInvalidPriceVolatility(address oracle, int256 price, uint256 volatility);

    // Then modify your setUp() function to call this
    function setUp() public {
        // Initial deployment with oracle
        deployMarketsWithUSDC();
        decimals = usdcInstance.decimals();

        // Deploy test tokens
        wethInstance = new WETH9();
        rwaToken = new MockRWA("RWA Token", "RWA");
        stableToken = new MockRWA("USDT", "USDT");

        // Deploy price feeds
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();

        // Deploy mock oracles for more controlled testing
        mockOracle1 = new MockPriceOracle();
        mockOracle2 = new MockPriceOracle();
        mockOracle3 = new MockPriceOracle();

        // Set initial prices
        wethOracleInstance.setPrice(2000e8); // $2000 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per stable token

        mockOracle1.setPrice(2010e8);
        mockOracle1.setTimestamp(block.timestamp);
        mockOracle1.setRoundId(1);
        mockOracle1.setAnsweredInRound(1);

        mockOracle2.setPrice(1990e8);
        mockOracle2.setTimestamp(block.timestamp);
        mockOracle2.setRoundId(1);
        mockOracle2.setAnsweredInRound(1);

        mockOracle3.setPrice(2020e8);
        mockOracle3.setTimestamp(block.timestamp);
        mockOracle3.setRoundId(1);
        mockOracle3.setAnsweredInRound(1);

        // Setup all required assets
        _setupAssets();
    }

    /**
     * @notice Setup assets for oracle testing
     * @dev Called from setUp to register all required assets before oracle operations
     */
    function _setupAssets() internal {
        vm.startPrank(address(timelockInstance));

        // Register WETH asset
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockOracle1), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Register RWA asset
        assetsInstance.updateAssetConfig(
            address(rwaToken), // asset
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80%
                liquidationThreshold: 850, // 85%
                maxSupplyThreshold: 500_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockOracle2), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Register Stable asset
        assetsInstance.updateAssetConfig(
            address(stableToken), // asset
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 950, // 95%
                liquidationThreshold: 980, // 98%
                maxSupplyThreshold: 10_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockOracle3), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();
    }

    // SECTION 2: THRESHOLD MANAGEMENT TESTS
    function test_UpdateFreshnessThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (, uint256 oldVolatility, uint256 oldVolatilityPct, uint256 oldCircuitBreakerPct) =
            assetsInstance.mainOracleConfig();

        // Update freshness threshold
        vm.expectEmit(true, true, true, true);
        emit FreshnessThresholdUpdated(28800, 7200); // Default is 8 hours (28800 seconds) for Ethereum mainnet

        assetsInstance.updateMainOracleConfig(
            7200, // 2 hours
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(14 minutes), // Too small
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(25 hours), // Too large
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        vm.stopPrank();
    }

    function test_UpdateVolatilityThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness,, uint256 oldVolatilityPct, uint256 oldCircuitBreakerPct) =
            assetsInstance.mainOracleConfig();

        // Update volatility threshold
        vm.expectEmit(true, true, true, true);
        emit VolatilityThresholdUpdated(3600, 1800); // Default is 1 hour (3600 seconds)

        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            1800, // 30 minutes
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(4 minutes), // Too small
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(5 hours), // Too large
            uint40(oldVolatilityPct),
            uint40(oldCircuitBreakerPct)
        );

        vm.stopPrank();
    }

    function test_UpdateVolatilityPercentage() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness, uint256 oldVolatility,, uint256 oldCircuitBreakerPct) = assetsInstance.mainOracleConfig();

        // Update volatility percentage
        vm.expectEmit(true, true, true, true);
        emit VolatilityPercentageUpdated(20, 15); // Default is 20%

        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            15, // 15%
            uint40(oldCircuitBreakerPct)
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            4, // Too small
            uint40(oldCircuitBreakerPct)
        );

        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            31, // Too large
            uint40(oldCircuitBreakerPct)
        );

        vm.stopPrank();
    }

    function test_UpdateCircuitBreakerThreshold() public {
        vm.startPrank(address(timelockInstance));

        // Get current config values to preserve
        (uint256 oldFreshness, uint256 oldVolatility, uint256 oldVolatilityPct,) = assetsInstance.mainOracleConfig();

        // Update circuit breaker threshold
        vm.expectEmit(true, true, true, true);
        emit CircuitBreakerThresholdUpdated(50, 35); // Default is 50%

        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            35 // 35%
        );

        // Try values outside valid range (should revert)
        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            24 // Too small
        );

        vm.expectRevert();
        assetsInstance.updateMainOracleConfig(
            uint80(oldFreshness),
            uint80(oldVolatility),
            uint40(oldVolatilityPct),
            71 // Too large
        );

        vm.stopPrank();
    }

    // SECTION 3: PRICE FEED FUNCTIONALITY TESTS

    function test_GetSingleOraclePrice() public {
        vm.startPrank(address(timelockInstance));
        // Get price
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2010e6, "Should return correct price");

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_InvalidPrice() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with invalid price
        mockOracle1.setPrice(0);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        mockOracle1.setPrice(-1);
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_StaleRound() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with stale round
        mockOracle1.setRoundId(10);
        mockOracle1.setAnsweredInRound(5);
        //assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_Timeout() public {
        vm.startPrank(address(timelockInstance));

        // Configure oracle with old timestamp
        mockOracle1.setTimestamp(block.timestamp - 25 hours); // Freshness threshold is 24 hours for Base L2
        //assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price (should revert)
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        vm.stopPrank();
    }

    function test_GetSingleOraclePrice_VolatilityCheck() public {
        vm.startPrank(address(timelockInstance));

        // Setup round history
        mockOracle1.setRoundId(2);
        mockOracle1.setAnsweredInRound(2);
        mockOracle1.setPrice(2400e8); // 20% increase from previous round
        mockOracle1.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold (1 hour)

        // Set previous round data with large price difference
        mockOracle1.setHistoricalRoundData(1, 2000e6, block.timestamp - 3 hours, 1);

        //assetsInstance.addOracle(address(wethInstance), address(mockOracle1), 8, IASSETS.OracleType.CHAINLINK);

        // Try to get price - should revert due to volatility with old timestamp
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(wethInstance));

        // Now set timestamp to be fresh for volatility check
        mockOracle1.setTimestamp(block.timestamp - 30 minutes); // Within volatility threshold

        // This should succeed
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2400e6, "Should allow volatile price if timestamp is fresh");

        vm.stopPrank();
    }

    function test_GetMedianPrice_Single() public {
        vm.startPrank(address(timelockInstance));

        // Get median price (with single oracle, should return that oracle's price)
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2010e6, "Single oracle should return its price"); //price from setUp()

        vm.stopPrank();
    }

    function test_CircuitBreaker_Automated() public {
        // SETUP: Configure mockOracle1 to have high volatility between rounds
        // to trigger circuit breaker for single oracle case
        mockOracle1.setRoundId(2);
        mockOracle1.setAnsweredInRound(2);
        mockOracle1.setPrice(2400e8); // 20% increase from previous round
        mockOracle1.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold (1 hour)

        // Set historical data for round 1 with large price difference
        mockOracle1.setHistoricalRoundData(1, 2000e8, block.timestamp - 3 hours, 1);

        vm.startPrank(address(timelockInstance));

        // 1. TRIGGER PHASE - Use evaluateCircuitBreaker to detect price anomaly
        vm.expectEmit(true, true, true, false);
        emit CircuitBreakerTriggered(address(wethInstance), 20, block.timestamp); // 20% deviation

        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        // Verify circuit breaker was activated and deviation was detected
        assertTrue(triggered, "Circuit breaker should be triggered");
        assertGt(deviation, 0, "Deviation should be reported");
        assertTrue(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be active");

        // Verify price checks now fail
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerActive.selector, address(wethInstance)));
        assetsInstance.getAssetPrice(address(wethInstance));

        // 2. RESET PHASE - Update price to normal range
        mockOracle1.setPrice(2010e8); // Return to normal price
        mockOracle1.setTimestamp(block.timestamp); // Fresh timestamp

        // Now evaluate again to automatically reset circuit breaker
        vm.expectEmit(true, false, false, false);
        emit CircuitBreakerReset(address(wethInstance));

        (bool resetResult,) = assetsInstance.evaluateCircuitBreaker(address(wethInstance));

        // Verify circuit breaker is no longer active
        assertFalse(resetResult, "Circuit breaker should be inactive after reset");
        assertFalse(assetsInstance.circuitBroken(address(wethInstance)), "Circuit breaker should be inactive");

        // Verify price can be retrieved again
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertGt(price, 0, "Should retrieve a valid price after reset");

        vm.stopPrank();
    }

    function test_Integration_MultipleAssets() public {
        vm.startPrank(address(timelockInstance));

        // Check each asset price
        uint256 wethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        uint256 rwaPrice = assetsInstance.getAssetPrice(address(rwaToken));
        uint256 stablePrice = assetsInstance.getAssetPrice(address(stableToken));

        assertEq(wethPrice, 2010e6, "WETH price should be correct");
        assertEq(rwaPrice, 1990e6, "RWA price should be correct");
        assertEq(stablePrice, 2020e6, "Stable price should be correct");

        // Now update one price and verify only that one changes
        mockOracle1.setPrice(2500e8);

        uint256 newWethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        uint256 sameRwaPrice = assetsInstance.getAssetPrice(address(rwaToken));

        assertEq(newWethPrice, 2500e6, "WETH price should be updated");
        assertEq(sameRwaPrice, 1990e6, "RWA price should remain the same");

        vm.stopPrank();
    }

    function test_Integration_OracleSwitch() public {
        vm.startPrank(address(timelockInstance));

        // Get initial price
        uint256 initialPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(initialPrice, 2010e6, "Initial price should be correct"); // price from setup

        // Use MockPriceOracle instead of WETHPriceConsumerV3 for testing timestamp behavior
        MockPriceOracle testOracle = new MockPriceOracle();
        testOracle.setPrice(2200e8); //new price
        testOracle.setTimestamp(block.timestamp);
        testOracle.setRoundId(1);
        testOracle.setAnsweredInRound(1);

        // Use replaceOracle to switch the CHAINLINK oracle
        assetsInstance.updateChainlinkOracle(address(wethInstance), address(testOracle), 1);

        // Should now get price from the new oracle
        uint256 newPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(newPrice, 2200e6, "Should get price from the new oracle");

        vm.stopPrank();
    }

    function test_CircuitBreakerManagement() public {
        // Use mockOracle2 which is already configured for rwaToken in _setupAssets()
        // and has the required setTimestamp method
        mockOracle2.setPrice(1990e8); // $1990 initial price (to match expected value)
        mockOracle2.setTimestamp(block.timestamp);
        mockOracle2.setRoundId(1);
        mockOracle2.setAnsweredInRound(1);

        vm.startPrank(address(timelockInstance));

        // Configure oracle parameters
        assetsInstance.updateMainOracleConfig(
            uint80(28800), // freshness threshold: 8 hours
            uint80(3600), // volatility threshold: 1 hour
            uint40(20), // volatility percentage: 20%
            uint40(50) // circuit breaker threshold: 50%
        );

        // No need to update asset configuration as mockOracle2 is already
        // configured for rwaToken in the _setupAssets() method

        vm.stopPrank();

        // PHASE 1: Verify price works normally
        uint256 initialPrice = assetsInstance.getAssetPrice(address(rwaToken));
        assertEq(initialPrice, 1990e6, "Should return correct price before circuit breaker");
        assertFalse(assetsInstance.circuitBroken(address(rwaToken)), "Circuit breaker should be inactive initially");

        // PHASE 2: Setup conditions that should trigger circuit breaker

        // Set up round 2 with a large price change and old timestamp
        mockOracle2.setPrice(1500e8); // 25% decrease from 1990 to 1500
        mockOracle2.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold (1 hour)
        mockOracle2.setRoundId(2);
        mockOracle2.setAnsweredInRound(2);

        // Set historical data for round 1
        mockOracle2.setHistoricalRoundData(1, 1990e8, block.timestamp - 3 hours, 1);

        // PHASE 3: Call evaluate and verify circuit breaker activates
        vm.expectEmit(true, true, true, false);
        emit CircuitBreakerTriggered(address(rwaToken), 24, block.timestamp);

        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(rwaToken));

        // Verify circuit breaker was activated
        assertTrue(triggered, "Circuit breaker should be triggered");
        assertEq(deviation, 24, "Deviation should be 24%"); // Changed from 25% to 24%
        assertTrue(assetsInstance.circuitBroken(address(rwaToken)), "Circuit breaker should be active");
        // Verify price check now fails
        vm.expectRevert(abi.encodeWithSelector(CircuitBreakerActive.selector, address(rwaToken)));
        assetsInstance.getAssetPrice(address(rwaToken));

        // PHASE 4: Return price to normal and verify circuit breaker resets

        // Return to normal price with fresh timestamp
        mockOracle2.setPrice(2000e8); // Close to original price
        mockOracle2.setTimestamp(block.timestamp); // Fresh timestamp

        // Now evaluate again to automatically reset circuit breaker
        vm.expectEmit(true, false, false, false);
        emit CircuitBreakerReset(address(rwaToken));

        (bool resetResult, uint256 resetDeviation) = assetsInstance.evaluateCircuitBreaker(address(rwaToken));

        // Verify circuit breaker is no longer active
        assertFalse(resetResult, "Circuit breaker should be inactive after reset");
        assertLt(resetDeviation, 5, "Deviation should be small now");
        assertFalse(assetsInstance.circuitBroken(address(rwaToken)), "Circuit breaker should be inactive");

        // Price check should now work
        uint256 price = assetsInstance.getAssetPrice(address(rwaToken));
        assertEq(price, 2000e6, "Should return a valid price after circuit breaker reset");
    }

    function test_GetUniswapPrice() public {
        // Deploy a mock Uniswap pool
        MockUniswapV3Pool uniswapPool = new MockUniswapV3Pool(address(rwaToken), address(usdcInstance), 3000);

        // IMPORTANT: Set up tick values that will produce a price of 1500e6
        int56[] memory tickCumulatives = new int56[](2);
        // At index 0: OLDER timestamp (1800 seconds ago)
        int56 magicNumber = decimals == 6 ? int56(203200) : int56(5000);
        tickCumulatives[0] = 0;
        // At index 1: NEWER timestamp (now)
        tickCumulatives[1] = 1800 * magicNumber; // 7,299,000
        uniswapPool.setTickCumulatives(tickCumulatives); // $1500

        // Set up seconds per liquidity (values don't matter much, just can't be 0)
        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        uniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        uniswapPool.setObserveSuccess(true);

        // Add our new Uniswap oracle through the proper function
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateUniswapOracle(
            address(rwaToken),
            address(uniswapPool),
            1800, // 30 minute TWAP
            1 //active
        );
        vm.stopPrank();

        // DIRECTLY get the price from the oracle - NO TRY/CATCH!
        uint256 price = assetsInstance.getAssetPriceByType(address(rwaToken), IASSETS.OracleType.UNISWAP_V3_TWAP);

        // Log the result
        console2.log("Uniswap Oracle Price:", price);

        // Make sure we got a non-zero price
        assertTrue(price > 1480e6 && price < 1520e6, "Uniswap price should be ~$1500");
    }

    function test_CheckPriceDeviation() public {
        // Deploy a Chainlink oracle (first oracle)
        MockPriceOracle testOracle = new MockPriceOracle();
        testOracle.setPrice(1000e8); // $1000
        testOracle.setTimestamp(block.timestamp);
        testOracle.setRoundId(1);
        testOracle.setAnsweredInRound(1);

        // Deploy a mock Uniswap pool (second oracle)
        MockUniswapV3Pool uniswapPool = new MockUniswapV3Pool(address(rwaToken), address(usdcInstance), 3000);

        // Set tick values to produce a valid price close to $1500
        int56[] memory tickCumulatives = new int56[](2);
        int56 magicNumber = decimals == 6 ? int56(203200) : int56(5000);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 1800 * magicNumber; // Adjusted tick value for ~$1500 price
        uniswapPool.setTickCumulatives(tickCumulatives);

        // Setup liquidity data
        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        uniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        uniswapPool.setObserveSuccess(true);

        vm.startPrank(address(timelockInstance));

        // Set circuit breaker threshold
        assetsInstance.updateMainOracleConfig(
            uint80(28800), // Freshness threshold
            uint80(3600), // Volatility threshold
            uint40(20), // Volatility percentage
            uint40(40) // Circuit breaker threshold (40%)
        );

        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(rwaToken));
        // Update asset configuration to include both Chainlink and Uniswap oracles
        assetsInstance.updateAssetConfig(
            address(rwaToken),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 500_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 2, // Require both oracles
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(uniswapPool), twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();

        // Check prices and deviation
        uint256 chainlinkPrice = assetsInstance.getAssetPriceByType(address(rwaToken), IASSETS.OracleType.CHAINLINK);
        uint256 uniswapPrice = assetsInstance.getAssetPriceByType(address(rwaToken), IASSETS.OracleType.UNISWAP_V3_TWAP);

        console2.log("Chainlink Price:", chainlinkPrice);
        console2.log("Uniswap Price:", uniswapPrice);

        // Check for price deviation
        (bool hasDeviation, uint256 deviationAmount) = assetsInstance.checkPriceDeviation(address(rwaToken));

        console2.log("Has Deviation:", hasDeviation);
        console2.log("Deviation Amount:", deviationAmount);

        // Assertions
        assertTrue(hasDeviation, "Should detect price deviation");
        assertGt(deviationAmount, 40, "Deviation should be at least 40%");
        assertLt(deviationAmount, 60, "Deviation should be at most 60%");
    }

    function test_UniswapZeroDelta() public {
        // Deploy a mock Uniswap pool (second oracle)
        MockUniswapV3Pool uniswapPool = new MockUniswapV3Pool(address(rwaToken), address(usdcInstance), 3000);

        // Setup identical tick cumulatives (zero delta)
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 1000000000;
        tickCumulatives[1] = 1000000000; // Same value, delta = 0
        uniswapPool.setTickCumulatives(tickCumulatives);

        // This should either revert or handle the zero case safely
        vm.expectRevert(); // If it should revert
        assetsInstance.getAssetPriceByType(address(rwaToken), IASSETS.OracleType.UNISWAP_V3_TWAP);
    }
}
