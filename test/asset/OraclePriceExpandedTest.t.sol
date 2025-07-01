// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockRWA} from "../../contracts/mock/MockRWA.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {MockUniswapV3Pool} from "../../contracts/mock/MockUniswapV3Pool.sol";

contract OraclePriceExpandedTest is BasicDeploy {
    // Oracle instances
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    MockPriceOracle internal mockOracle;
    MockPriceOracle internal mockOracle2;

    // Test tokens
    MockRWA internal testAsset;
    uint8 internal decimals;

    // Uniswap mock
    MockUniswapV3Pool internal mockUniswapPool;

    event CircuitBreakerTriggered(address indexed asset, uint256 deviationPct, uint256 timestamp);
    event CircuitBreakerReset(address indexed asset);

    function setUp() public {
        deployMarketsWithUSDC();
        decimals = usdcInstance.decimals();

        // TGE already initialized in deployMarketsWithUSDC()

        // Deploy mock tokens
        wethInstance = new WETH9();
        testAsset = new MockRWA("Test Asset", "TST");

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        mockOracle = new MockPriceOracle();
        mockOracle2 = new MockPriceOracle();

        // Configure oracle price data
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        mockOracle.setPrice(1000e8); // $1000 for test asset
        mockOracle.setTimestamp(block.timestamp);
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Deploy and configure Uniswap pool mock
        mockUniswapPool = new MockUniswapV3Pool(address(usdcInstance), address(testAsset), 3000);

        // Set up tick cumulatives for TWAP - price increasing over time
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0; // At time T-30min
        tickCumulatives[1] = 1800 * 600; // At current time, tick of 600 for 1800 seconds
        mockUniswapPool.setTickCumulatives(tickCumulatives);

        // Set up seconds per liquidity
        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        mockUniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);

        // Make sure observations succeed
        mockUniswapPool.setObserveSuccess(true);

        // Register assets with oracles
        vm.startPrank(address(timelockInstance));

        // Configure WETH with Chainlink oracle using the new Asset struct format
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
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure test asset with Chainlink oracle using the new Asset struct format
        assetsInstance.updateAssetConfig(
            address(testAsset),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 2, // Require 2 oracles for median calculation
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(mockUniswapPool), twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();
    }

    // Test 1: Get price from a single oracle
    function test_GetPrice() public {
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2500e6, "WETH price should be 2500 USD");
    }

    // Test 3: Test invalid price (zero or negative)
    function test_GetAssetPrice_InvalidPrice() public {
        // Set price to zero
        mockOracle.setPrice(0);

        // Try to get price directly from oracle
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(testAsset));

        // Set price to negative
        mockOracle.setPrice(-100);

        // Try to get price directly from oracle
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(testAsset));
    }

    // Test 4: Test stale price (answeredInRound < roundId)
    function test_GetAssetPriceOracle_StalePrice() public {
        // Set round ID higher than answeredInRound
        mockOracle.setRoundId(10);
        mockOracle.setAnsweredInRound(5);

        // Try to get price directly from oracle
        vm.expectRevert(abi.encodeWithSelector(IASSETS.OracleStalePrice.selector, address(mockOracle), 10, 5));
        assetsInstance.getAssetPrice(address(testAsset));
    }

    // Test 5: Test timeout (timestamp too old)
    function test_GetAssetPriceOracle_Timeout() public {
        // Set timestamp to 25 hours ago (beyond the 24 hour freshness threshold for Base L2)
        mockOracle.setTimestamp(block.timestamp - 25 hours);

        // Try to get price directly from oracle
        vm.expectRevert();
        assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);

        // Instead, verify we can reset the Chainlink oracle and get its price
        mockOracle.setTimestamp(block.timestamp); // Fix the timestamp
        uint256 price = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(price, 1000e6, "Oracle should return correct price after timestamp fixed");
    }

    // Test 6: Replace an oracle
    function test_ReplaceOracle() public {
        vm.startPrank(address(timelockInstance));

        // Create a new oracle
        MockPriceOracle newOracle = new MockPriceOracle();
        newOracle.setPrice(1200e8);
        newOracle.setTimestamp(block.timestamp);
        newOracle.setRoundId(1);
        newOracle.setAnsweredInRound(1);

        IASSETS.Asset memory item = assetsInstance.getAssetInfo(address(testAsset));
        item.chainlinkConfig = IASSETS.ChainlinkOracleConfig({
            oracleUSD: address(newOracle), //new oracle
            active: 1
        });
        // Disable the Uniswap oracle so we only use the new Chainlink oracle
        item.poolConfig.active = 0;
        item.assetMinimumOracles = 1;

        // Replace the Chainlink oracle
        assetsInstance.updateAssetConfig(address(testAsset), item);
        // Verify the oracle was replaced
        address oracleAddress = assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(oracleAddress, address(newOracle), "Oracle should be replaced");

        // Verify the price directly from the new oracle (avoid median calculation)
        uint256 oraclePrice = assetsInstance.getAssetPrice(address(testAsset));
        assertEq(oraclePrice, 1200e6, "New oracle price should be 1200e6");

        // Verify by using getAssetPriceByType instead of getAssetPrice (which uses median)
        uint256 assetPrice = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(assetPrice, 1200e6, "Asset price by type should match new oracle price");

        vm.stopPrank();
    }

    function test_DeleteUniswapOracle() public {
        vm.startPrank(address(timelockInstance));

        IASSETS.Asset memory item = assetsInstance.getAssetInfo(address(testAsset));
        item.poolConfig = IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0});
        item.assetMinimumOracles = 1;
        // Delete the Uniswap oracle
        assetsInstance.updateAssetConfig(address(testAsset), item);
        // Verify the oracle was replaced
        address oracleAddress = assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.UNISWAP_V3_TWAP);
        assertEq(oracleAddress, address(0), "Oracle should be deleted");

        // Verify the price directly from the new oracle (avoid median calculation)
        uint256 oraclePrice = assetsInstance.getAssetPrice(address(testAsset));
        assertEq(oraclePrice, 1000e6, "New oracle price should be 1000e6");

        // Verify by using getAssetPriceByType instead of getAssetPrice (which uses median)
        uint256 assetPrice = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(assetPrice, 1000e6, "Asset price by type should match new oracle price");

        vm.stopPrank();
    }

    // Test 7: Get oracle by type
    function test_GetOracleByType() public {
        // Get Chainlink oracle
        address chainlinkOracle = assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(chainlinkOracle, address(mockOracle), "Should return the correct Chainlink oracle");

        // Get Uniswap oracle address
        address uniswapOracle = assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.UNISWAP_V3_TWAP);
        assertTrue(uniswapOracle != address(0), "Should have a Uniswap oracle address");
    }

    // Test 8: Trying to add duplicate oracle type should revert
    function test_UpdateUniswapOracle() public {
        vm.startPrank(address(timelockInstance));

        // Deploy a new mock Uniswap pool for testing
        MockUniswapV3Pool newPool = new MockUniswapV3Pool(address(usdcInstance), address(testAsset), 3000);
        newPool.setObserveSuccess(true);

        // Update Uniswap oracle configuration
        assetsInstance.updateUniswapOracle(
            address(testAsset),
            address(newPool),
            1800, // 30 minute TWAP
            1 // Set as active
        );

        // Verify that the oracle was updated correctly
        address updatedUniswapOracle =
            assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.UNISWAP_V3_TWAP);
        assertEq(updatedUniswapOracle, address(newPool), "Uniswap oracle should be updated to new pool");

        // Get the updated asset config and verify pool config was updated
        IASSETS.Asset memory assetAfter = assetsInstance.getAssetInfo(address(testAsset));
        assertEq(assetAfter.poolConfig.pool, address(newPool), "Pool address should be updated");

        assertEq(assetAfter.poolConfig.twapPeriod, 1800, "TWAP period should be updated");

        assertEq(assetAfter.poolConfig.active, 1, "Oracle should be active");

        // The Chainlink oracle should remain unchanged throughout
        address chainlinkOracle = assetsInstance.getOracleByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(chainlinkOracle, address(mockOracle), "Chainlink oracle should remain unchanged");

        vm.stopPrank();
    }

    // Test 9: Oracle circuit breaker
    function test_CircuitBreaker() public {
        // SETUP: Configure mockOracle to have high volatility between rounds
        // to trigger circuit breaker for single oracle case
        mockOracle.setRoundId(2); // Set current round to 2
        mockOracle.setAnsweredInRound(2);
        mockOracle.setPrice(2400e8); // $2400 price - this is the CURRENT price
        mockOracle.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold

        // Set historical data for round 1 (this is the PREVIOUS round)
        mockOracle.setHistoricalRoundData(1, 2000e8, block.timestamp - 3 hours, 1);

        vm.startPrank(address(timelockInstance));

        // Configure the test asset to only use Chainlink oracle (disabling Uniswap)
        IASSETS.Asset memory assetConfig = assetsInstance.getAssetInfo(address(testAsset));
        assetConfig.poolConfig.active = 0; // Disable Uniswap oracle
        assetConfig.assetMinimumOracles = 1; // Only require 1 oracle now
        assetsInstance.updateAssetConfig(address(testAsset), assetConfig);

        // Configure oracle parameters
        assetsInstance.updateMainOracleConfig(
            uint80(28800), // freshness threshold: 8 hours
            uint80(3600), // volatility threshold: 1 hour
            uint40(20), // volatility percentage: 20%
            uint40(50) // circuit breaker threshold: 50%
        );

        // 1. TRIGGER PHASE - Use evaluateCircuitBreaker to detect price anomaly
        vm.expectEmit(true, true, true, false);
        emit CircuitBreakerTriggered(address(testAsset), 20, block.timestamp); // 20% deviation

        (bool triggered, uint256 deviation) = assetsInstance.evaluateCircuitBreaker(address(testAsset));

        // Verify circuit breaker was activated and deviation was detected
        assertTrue(triggered, "Circuit breaker should be triggered");
        assertEq(deviation, 20, "Deviation should be 20%");
        assertTrue(assetsInstance.circuitBroken(address(testAsset)), "Circuit breaker should be active");

        // Verify price checks now fail
        vm.expectRevert(abi.encodeWithSelector(IASSETS.CircuitBreakerActive.selector, address(testAsset)));
        assetsInstance.getAssetPrice(address(testAsset));

        // 2. RESET PHASE - Update price to normal range
        mockOracle.setPrice(2050e8); // Return to normal price
        mockOracle.setTimestamp(block.timestamp); // Fresh timestamp

        // Now evaluate again to automatically reset circuit breaker
        vm.expectEmit(true, false, false, false);
        emit CircuitBreakerReset(address(testAsset));

        (bool resetResult,) = assetsInstance.evaluateCircuitBreaker(address(testAsset));

        // Verify circuit breaker is no longer active
        assertFalse(resetResult, "Circuit breaker should be inactive after reset");
        assertFalse(assetsInstance.circuitBroken(address(testAsset)), "Circuit breaker should be inactive");

        // Verify price can be retrieved again
        uint256 price = assetsInstance.getAssetPrice(address(testAsset));
        assertGt(price, 0, "Should retrieve a valid price after reset");

        vm.stopPrank();
    }

    // Test 10: Test volatility check
    function test_VolatilityCheck() public {
        // Set up previous round data with a much lower price
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);
        mockOracle.setPrice(1200e8);

        // Set historical data with >20% price change
        mockOracle.setHistoricalRoundData(19, 700e6, block.timestamp - 4 hours, 19);

        // Set timestamp to be recent
        mockOracle.setTimestamp(block.timestamp - 30 minutes);

        // Should still work because timestamp is recent
        uint256 price = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(price, 1200e6, "Price should be returned when timestamp is recent");

        // Now make the timestamp old
        mockOracle.setTimestamp(block.timestamp - 2 hours);

        // Now should fail volatility check
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(mockOracle));
    }

    // Test 11: Uniswap pool failure
    function testRevert_UniswapPoolFailure() public {
        // Make the Uniswap pool fail
        mockUniswapPool.setObserveSuccess(false);

        // Should still get price from Chainlink oracle
        vm.expectRevert("MockUniswapV3Pool: Observation failed");
        assetsInstance.getAssetPrice(address(testAsset));
    }

    function setupWorkingOracles() internal {
        // Ensure CHAINLINK oracle is working
        mockOracle.setPrice(1000e8);
        mockOracle.setTimestamp(block.timestamp);
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Set explicit tick values that will convert to a reasonable price
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 1800 * 600; // 30 minutes * tick 600
        mockUniswapPool.setTickCumulatives(tickCumulatives);

        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;
        mockUniswapPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        mockUniswapPool.setObserveSuccess(true);
    }

    // Test 15: Test median price calculation with both oracles
    function test_GetMedianPrice() public {
        // Set up Chainlink oracle price
        mockOracle.setPrice(1000e8); // $1000
        mockOracle.setTimestamp(block.timestamp);
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Set up Uniswap oracle with a mock pool
        MockUniswapV3Pool newPool = new MockUniswapV3Pool(address(usdcInstance), address(testAsset), 3000);

        // Configure tick cumulatives for a predictable price
        int56[] memory tickCumulatives = new int56[](2);
        int56 magicNumber = decimals == 6 ? int56(203200) : int56(5000);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 1800 * magicNumber; // 203200, Simulate a higher tick value ~$1500
        newPool.setTickCumulatives(tickCumulatives);

        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1800;
        secondsPerLiquidityCumulatives[1] = 1800;
        newPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        newPool.setObserveSuccess(true);

        // Update the Uniswap oracle for the test asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateUniswapOracle(
            address(testAsset),
            address(newPool),
            1800, // 30-minute TWAP
            1 // Active
        );
        vm.stopPrank();

        // Verify the Chainlink price
        uint256 chainlinkPrice = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(chainlinkPrice, 1000e6, "Chainlink price should be $1000");

        // Verify the Uniswap price
        uint256 uniswapPrice =
            assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.UNISWAP_V3_TWAP);
        assertTrue(uniswapPrice > 0, "Uniswap price should be greater than 0");
        console2.log("Uniswap price:", uniswapPrice);

        // Calculate the median price
        uint256 medianPrice = assetsInstance.getAssetPrice(address(testAsset));
        console2.log("Median price:", medianPrice);

        // Assert the median price is within the expected range
        assertTrue(medianPrice >= 1200e6 && medianPrice <= 1300e6, "Median price should be in a reasonable range");
    }

    // Test 16: Test circuit breaker with price deviation
    function test_MedianPriceWithDeviation() public {
        // Make sure Chainlink oracle works properly first
        mockOracle.setPrice(1000e8);
        mockOracle.setTimestamp(block.timestamp);
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Get price directly from the Chainlink oracle to verify it's working
        uint256 price = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(price, 1000e6, "Price should be available initially");

        // Configure oracle parameters to ensure circuit breaker can be triggered
        vm.prank(address(timelockInstance));
        assetsInstance.updateMainOracleConfig(
            uint80(28800), // freshness threshold: 8 hours
            uint80(3600), // volatility threshold: 1 hour
            uint40(20), // volatility percentage: 20%
            uint40(50) // circuit breaker threshold: 50%
        );

        // PHASE 1: Create conditions that would trigger a volatility error

        // Set up with a large price change and old timestamp
        mockOracle.setPrice(1500e8); // 50% increase from 1000 to 1500
        mockOracle.setTimestamp(block.timestamp - 2 hours); // Older than volatility threshold
        mockOracle.setRoundId(2);
        mockOracle.setAnsweredInRound(2);

        // Set historical data for round 1
        mockOracle.setHistoricalRoundData(1, 1000e8, block.timestamp - 3 hours, 1);

        // Expect direct price call to revert with OracleInvalidPriceVolatility
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleInvalidPriceVolatility.selector, address(mockOracle), int256(1500e8), 50
            )
        );
        assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);

        // Circuit breaker evaluation should also revert with same error
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleInvalidPriceVolatility.selector, address(mockOracle), int256(1500e8), 50
            )
        );
        assetsInstance.evaluateCircuitBreaker(address(testAsset));

        // PHASE 2: Reset conditions to normal prices

        // Return to normal price with fresh timestamp
        mockOracle.setPrice(1050e8); // Close to original price
        mockOracle.setTimestamp(block.timestamp); // Fresh timestamp

        // Now price calls should work
        uint256 resetPrice = assetsInstance.getAssetPriceByType(address(testAsset), IASSETS.OracleType.CHAINLINK);
        assertEq(resetPrice, 1050e6, "Should return price after volatility is gone");

        // Circuit breaker should not be active
        assertFalse(assetsInstance.circuitBroken(address(testAsset)), "Circuit breaker should be inactive");
    }
}
