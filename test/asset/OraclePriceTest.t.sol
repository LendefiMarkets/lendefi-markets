// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {RWAPriceConsumerV3} from "../../contracts/mock/RWAOracle.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {StablePriceConsumerV3} from "../../contracts/mock/StableOracle.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";

contract OraclePriceTest is BasicDeploy {
    RWAPriceConsumerV3 internal rwaOracleInstance;
    WETHPriceConsumerV3 internal wethOracleInstance;
    StablePriceConsumerV3 internal stableOracleInstance;
    MockPriceOracle internal mockOracle;

    function setUp() public {
        // Use deployMarketsWithUSDC() instead of deployComplete()
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()

        // Deploy mock tokens
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracleInstance = new WETHPriceConsumerV3();
        rwaOracleInstance = new RWAPriceConsumerV3();
        stableOracleInstance = new StablePriceConsumerV3();
        mockOracle = new MockPriceOracle();

        // Set up mockOracle with default values for testing
        mockOracle.setPrice(1000e8); // Default price
        mockOracle.setTimestamp(block.timestamp); // Current timestamp
        mockOracle.setRoundId(1);
        mockOracle.setAnsweredInRound(1);

        // Set prices
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        rwaOracleInstance.setPrice(1000e8); // $1000 per RWA token
        stableOracleInstance.setPrice(1e8); // $1 per stable token

        vm.startPrank(address(timelockInstance));

        // REGISTER ASSETS WITH ORACLES USING UPDATED STRUCT FORMAT

        // Register WETH asset
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 900,
                liquidationThreshold: 950,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Register mock asset 1
        assetsInstance.updateAssetConfig(
            address(0x1),
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
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(rwaOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Register mock asset 2
        assetsInstance.updateAssetConfig(
            address(0x2),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 950,
                liquidationThreshold: 980,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(stableOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Register mock asset 3
        assetsInstance.updateAssetConfig(
            address(0x3),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 850,
                liquidationThreshold: 900,
                maxSupplyThreshold: 1_000_000e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(mockOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // No need to call setPrimaryOracle separately since it's now done in updateAssetConfig
        // through the primaryOracleType field

        vm.stopPrank();
    }

    // Test 1: Happy Path - Successfully get price
    function test_GetAssetPrice_Success() public {
        uint256 expectedPrice = 2500e6;

        // Test through the Asset module
        uint256 price2 = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price2, expectedPrice, "Oracle module price should match");
    }

    // Test 2: Invalid Price - Oracle returns zero or negative price
    function test_GetAssetPrice_InvalidPrice() public {
        // Set price to zero
        mockOracle.setPrice(0);

        // Expect revert when called through Oracle module
        vm.expectRevert();
        assetsInstance.getAssetPrice(address(0x3));

        // Set price to negative
        mockOracle.setPrice(-100);

        vm.expectRevert();
        assetsInstance.getAssetPrice(address(0x3));
    }

    // Test 6: Edge Case - answeredInRound equal to roundId
    function test_GetAssetPriceOracle_EqualRounds() public {
        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1002e6, block.timestamp - 4 hours, 19);
        // Set roundId equal to answeredInRound
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);

        // Should succeed - use getAssetPriceByType instead of getSingleOraclePrice
        uint256 price = assetsInstance.getAssetPriceByType(address(0x3), IASSETS.OracleType.CHAINLINK);
        assertEq(price, 1000e6, "Should return price when roundId equals answeredInRound");
    }

    // Test 7: Fuzz Test - Different positive prices
    function testFuzz_GetAssetPriceOracle_VariousPrices(int256 testPrice) public {
        // Use only positive prices to avoid expected reverts
        vm.assume(testPrice > 0);

        // Set the test price
        mockOracle.setPrice(testPrice);

        // Get the price from the oracle - use getAssetPriceByType instead of getSingleOraclePrice
        uint256 returnedPrice = assetsInstance.getAssetPriceByType(address(0x3), IASSETS.OracleType.CHAINLINK);

        // Verify the result
        assertEq(returnedPrice, uint256(testPrice) / 1e2, "Should return the exact price set");
    }

    // Test 8: Multiple Oracle Types
    function test_GetAssetPrice_MultipleOracleTypes() public {
        // Check prices by directly getting them through the asset address
        uint256 wethPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(wethPrice, 2500e6, "WETH price should be correct");

        // Check RWA price
        uint256 rwaPrice = assetsInstance.getAssetPrice(address(0x1));
        assertEq(rwaPrice, 1000e6, "RWA price should be correct");

        // Check Stable price
        uint256 stablePrice = assetsInstance.getAssetPrice(address(0x2));
        assertEq(stablePrice, 1e6, "Stable price should be correct");
    }

    // Test 9: Price Changes
    function test_GetAssetPriceOracle_PriceChanges() public {
        // Get initial price
        uint256 initialPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(initialPrice, 2500e6, "Initial price should be correct");

        // Change price
        wethOracleInstance.setPrice(3000e8);

        // Get updated price
        uint256 updatedPrice = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(updatedPrice, 3000e6, "Updated price should reflect the change");
    }

    // Test 10: Integration with Asset Config
    function test_GetAssetPriceOracle_WithAssetConfig() public {
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(wethInstance));
        // Setup asset config with WETH oracle using the new Asset struct
        vm.startPrank(address(timelockInstance));
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
        vm.stopPrank();

        // Use the oracle from asset config
        uint256 price = assetsInstance.getAssetPrice(address(wethInstance));
        assertEq(price, 2500e6, "Should get correct price from asset-configured oracle");
    }

    // Test 11: Oracle price volatility check
    function test_GetAssetPriceOracle_VolatilityDetection() public {
        // Set current round data
        mockOracle.setRoundId(20);
        mockOracle.setAnsweredInRound(20);
        mockOracle.setPrice(1200e8);
        mockOracle.setTimestamp(block.timestamp - 30 minutes); // Fresh timestamp

        // Set previous round data with >20% price difference
        mockOracle.setHistoricalRoundData(19, 1000e8, block.timestamp - 4 hours, 19);

        // This should pass since timestamp is recent (< 1 hour)
        uint256 price = assetsInstance.getAssetPrice(address(0x3));
        assertEq(price, 1200e6);

        // Now set timestamp to be stale for volatility check (>= 1 hour)
        mockOracle.setTimestamp(block.timestamp - 2 hours);

        // Now this should revert due to volatility with stale timestamp
        vm.expectRevert(
            abi.encodeWithSelector(
                IASSETS.OracleInvalidPriceVolatility.selector,
                address(mockOracle),
                1200e8,
                20 // 20% change
            )
        );
        assetsInstance.getAssetPrice(address(0x3));
    }
}
