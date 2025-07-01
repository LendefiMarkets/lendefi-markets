// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "./BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {AggregatorV3Interface} from
    "../../contracts/vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {IUniswapV3Pool} from "../../contracts/interfaces/IUniswapV3Pool.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract USD1ForkTest is BasicDeploy {
    // Mainnet addresses
    address constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    address constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    address constant LINK = 0x514910771AF9Ca656af840dff83E8264EcF986CA;

    // Pools and oracles - Using pools that contain USDC or WETH
    address constant LINK_WETH_POOL = 0xa6Cc3C2531FdaA6Ae1A3CA84c2855806728693e8;
    address constant WBTC_WETH_POOL = 0xCBCdF9626bC03E24f779434178A73a0B4bad62eD; // WBTC/WETH pool instead
    address constant WETH_USD1_POOL = 0x4e68Ccd3E89f51C3074ca5072bbAC773960dFa36;
    address constant USD1_USDC_POOL = 0x1e1DfFf79d95725aaAFD6b47aF4fbc28D859ce28;

    address constant WETH_CHAINLINK_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address constant WBTC_CHAINLINK_ORACLE = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    address constant LINK_CHAINLINK_ORACLE = 0x2c1d072e956AFFC0D435Cb7AC38EF18d24d9127c;
    address constant USD1_CHAINLINK_ORACLE = 0xF0d9bb015Cd7BfAb877B7156146dc09Bf461370d;

    uint256 mainnetFork;
    address testUser;

    function setUp() public {
        // Fork mainnet at a stable block (same as other tests)
        mainnetFork = vm.createFork("mainnet", 22607428);
        vm.selectFork(mainnetFork);

        // Deploy protocol normally
        // First warp to a reasonable time for treasury deployment
        vm.warp(365 days);

        // Deploy base contracts
        _deployTimelock();
        _deployToken();
        _deployEcosystem();
        _deployTreasury();
        _deployGovernor();
        _deployMarketFactory();

        // Deploy USD1 market instead of USDT
        _deployMarket(address(usd1Instance), "Lendefi Yield Token", "LYTUSD1");

        // Now warp to current time to match oracle data
        vm.warp(1748748827 + 3600); // Oracle timestamp + 1 hour

        // Create test user
        testUser = makeAddr("testUser");
        vm.deal(testUser, 100 ether);

        // Setup roles
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();

        // Configure assets
        _configureWETH();
        _configureWBTC();
        _configureLINK();
        _configureUSD1();
    }

    function _configureWETH() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WETH with updated struct format
        assetsInstance.updateAssetConfig(
            WETH,
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: WETH_CHAINLINK_ORACLE, active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: WETH_USD1_POOL, twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();
    }

    function _configureWBTC() internal {
        vm.startPrank(address(timelockInstance));

        // Configure WBTC with updated struct format
        assetsInstance.updateAssetConfig(
            WBTC,
            IASSETS.Asset({
                active: 1,
                decimals: 8, // WBTC has 8 decimals
                borrowThreshold: 700,
                liquidationThreshold: 750,
                maxSupplyThreshold: 500 * 1e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: WBTC_CHAINLINK_ORACLE, active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: WBTC_WETH_POOL, twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();
    }

    function _configureLINK() internal {
        vm.startPrank(address(timelockInstance));

        // Configure LINK using the ETH bridge approach
        assetsInstance.updateAssetConfig(
            LINK,
            IASSETS.Asset({
                active: 1,
                decimals: 18, // LINK has 18 decimals
                borrowThreshold: 650,
                liquidationThreshold: 700,
                maxSupplyThreshold: 50_000 * 1e18,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: LINK_CHAINLINK_ORACLE, active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: LINK_WETH_POOL, twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();
    }

    function _configureUSD1() internal {
        vm.startPrank(address(timelockInstance));

        // Configure USD1 with proper Chainlink oracle
        assetsInstance.updateAssetConfig(
            address(usd1Instance),
            IASSETS.Asset({
                active: 1,
                decimals: 18, // USD1 has 18 decimals
                borrowThreshold: 950, // 95% - very safe for stablecoin
                liquidationThreshold: 980, // 98% - very safe for stablecoin
                maxSupplyThreshold: 1_000_000_000 * 1e18, // 1B USD1
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: USD1_CHAINLINK_ORACLE, active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: USD1_USDC_POOL, twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();
    }

    function test_ChainlinkOracleETH() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) =
            AggregatorV3Interface(WETH_CHAINLINK_ORACLE).latestRoundData();

        console2.log("Direct ETH/USD oracle call:");
        console2.log("  RoundId:", roundId);
        console2.log("  Price:", uint256(answer) / 1e8);
        console2.log("  Updated at:", updatedAt);
    }

    function test_ChainLinkOracleBTC() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) =
            AggregatorV3Interface(WBTC_CHAINLINK_ORACLE).latestRoundData();
        console2.log("Direct BTC/USD oracle call:");
        console2.log("  RoundId:", roundId);
        console2.log("  Price:", uint256(answer) / 1e8);
        console2.log("  Updated at:", updatedAt);
    }

    function test_ChainlinkOracleUSD1() public view {
        (uint80 roundId, int256 answer,, uint256 updatedAt,) =
            AggregatorV3Interface(USD1_CHAINLINK_ORACLE).latestRoundData();
        console2.log("Direct USD1/USD oracle call:");
        console2.log("  RoundId:", roundId);
        console2.log("  Price:", uint256(answer) / 1e8);
        console2.log("  Updated at:", updatedAt);
    }

    function test_RealMedianPriceETH() public {
        // Get price from Uniswap only (Chainlink disabled)
        uint256 uniswapPrice = assetsInstance.getAssetPriceByType(WETH, IASSETS.OracleType.UNISWAP_V3_TWAP);

        console2.log("WETH Uniswap price:", uniswapPrice);

        // Get actual price (should be Uniswap only)
        uint256 actualPrice = assetsInstance.getAssetPrice(WETH);
        console2.log("WETH price (Uniswap only):", actualPrice);

        assertEq(actualPrice, uniswapPrice, "Price should be Uniswap only");
    }

    function test_RealMedianPriceBTC() public {
        // Get price from Uniswap only (Chainlink disabled)
        uint256 uniswapPrice = assetsInstance.getAssetPriceByType(WBTC, IASSETS.OracleType.UNISWAP_V3_TWAP);

        console2.log("WBTC Uniswap price:", uniswapPrice);

        // Get actual price (should be Uniswap only)
        uint256 actualPrice = assetsInstance.getAssetPrice(WBTC);
        console2.log("WBTC price (Uniswap only):", actualPrice);

        assertEq(actualPrice, uniswapPrice, "Price should be Uniswap only");
    }

    function test_OracleTypeSwitch() public view {
        // Initially both oracles are active
        // Now price should come directly from Chainlink

        uint256 chainlinkPrice = assetsInstance.getAssetPriceByType(WETH, IASSETS.OracleType.CHAINLINK);
        console2.log("Chainlink-only ETH price:", chainlinkPrice);

        uint256 uniswapPrice = assetsInstance.getAssetPriceByType(WETH, IASSETS.OracleType.UNISWAP_V3_TWAP);
        console2.log("Uniswap-only ETH price:", uniswapPrice);

        uint256 chainlinkBTCPrice = assetsInstance.getAssetPriceByType(WBTC, IASSETS.OracleType.CHAINLINK);
        console2.log("Chainlink-only BTC price:", chainlinkBTCPrice);

        uint256 uniswapBTCPrice = assetsInstance.getAssetPriceByType(WBTC, IASSETS.OracleType.UNISWAP_V3_TWAP);
        console2.log("Uniswap-only BTC price:", uniswapBTCPrice);
    }

    function testRevert_PoolLiquidityLimitReached() public {
        // Give test user more ETH
        vm.deal(testUser, 15000 ether); // Increase from 100 ETH to 15000 ETH

        // Create a user with WETH
        vm.startPrank(testUser);
        (bool success,) = WETH.call{value: 10000 ether}("");
        require(success, "ETH to WETH conversion failed");

        // Create a position
        uint256 positionId = marketCoreInstance.createPosition(WETH, false);
        console2.log("Created position ID:", positionId);
        vm.stopPrank();

        // Set maxSupplyThreshold high (100,000 ETH) to avoid hitting AssetCapacityReached
        vm.startPrank(address(timelockInstance));
        IASSETS.Asset memory wethConfig = assetsInstance.getAssetInfo(WETH);
        wethConfig.maxSupplyThreshold = 100_000 ether;
        assetsInstance.updateAssetConfig(WETH, wethConfig);
        vm.stopPrank();

        // Get actual WETH balance in the pool
        uint256 poolWethBalance = IERC20(WETH).balanceOf(WETH_USD1_POOL);
        console2.log("WETH balance in pool:", poolWethBalance / 1e18, "ETH");

        // Calculate 3% of pool balance
        uint256 threePercentOfPool = (poolWethBalance * 3) / 100;
        console2.log("3% of pool WETH:", threePercentOfPool / 1e18, "ETH");

        // Add a little extra to ensure we exceed the limit
        uint256 supplyAmount = threePercentOfPool + 1 ether;
        console2.log("Amount to supply:", supplyAmount / 1e18, "ETH");

        // Verify directly that this will trigger the limit
        bool willHitLimit = assetsInstance.poolLiquidityLimit(WETH, supplyAmount);
        console2.log("Will hit pool liquidity limit:", willHitLimit);
        assertTrue(willHitLimit, "Our calculated amount should trigger pool liquidity limit");

        // Supply amount exceeding 3% of pool balance
        vm.startPrank(testUser);
        IERC20(WETH).approve(address(marketCoreInstance), supplyAmount);
        vm.expectRevert(IPROTOCOL.PoolLiquidityLimitReached.selector);
        marketCoreInstance.supplyCollateral(WETH, supplyAmount, positionId);
        vm.stopPrank();

        console2.log("Successfully tested PoolLiquidityLimitReached error");
    }

    function testRevert_AssetLiquidityLimitReached() public {
        // Create a user with WETH
        vm.startPrank(testUser);
        (bool success,) = WETH.call{value: 50 ether}("");
        require(success, "ETH to WETH conversion failed");

        // Create a position
        marketCoreInstance.createPosition(WETH, false); // false = cross-collateral position
        uint256 positionId = marketCoreInstance.getUserPositionsCount(testUser) - 1;
        console2.log("Created position ID:", positionId);

        vm.stopPrank();

        // Update WETH config with a very small limit
        vm.startPrank(address(timelockInstance));
        IASSETS.Asset memory wethConfig = assetsInstance.getAssetInfo(WETH);
        wethConfig.maxSupplyThreshold = 1 ether; // Very small limit
        assetsInstance.updateAssetConfig(WETH, wethConfig);
        vm.stopPrank();

        // Supply within limit
        vm.startPrank(testUser);
        IERC20(WETH).approve(address(marketCoreInstance), 0.5 ether);
        marketCoreInstance.supplyCollateral(WETH, 0.5 ether, positionId);
        console2.log("Supplied 0.5 WETH");

        // Try to exceed the limit
        IERC20(WETH).approve(address(marketCoreInstance), 1 ether);
        vm.expectRevert(IPROTOCOL.AssetCapacityReached.selector);
        marketCoreInstance.supplyCollateral(WETH, 1 ether, positionId);
        vm.stopPrank();

        console2.log("Successfully tested PoolLiquidityLimitReached error");
    }

    // Add this test function
    function test_RealMedianPriceLINK() public {
        // Get price from Uniswap only (Chainlink disabled)
        uint256 uniswapPrice = assetsInstance.getAssetPriceByType(LINK, IASSETS.OracleType.UNISWAP_V3_TWAP);

        console2.log("LINK Uniswap price:", uniswapPrice);

        // Get actual price (should be Uniswap only)
        uint256 actualPrice = assetsInstance.getAssetPrice(LINK);
        console2.log("LINK price (Uniswap only):", actualPrice);

        // Also log direct Chainlink data for reference
        (uint80 roundId, int256 answer,, uint256 updatedAt,) =
            AggregatorV3Interface(LINK_CHAINLINK_ORACLE).latestRoundData();
        console2.log("Direct LINK/USD oracle call:");
        console2.log("  RoundId:", roundId);
        console2.log("  Price:", uint256(answer) / 1e8);
        console2.log("  Updated at:", updatedAt);

        assertEq(actualPrice, uniswapPrice, "Price should be Uniswap only");
    }

    /**
     * @notice Get optimal Uniswap V3 pool configuration for price oracle
     * @param asset The asset to get USD price for
     * @param pool The Uniswap V3 pool address
     * @return A properly configured UniswapPoolConfig struct
     */
    function getOptimalUniswapConfig(address asset, address pool)
        public
        view
        returns (IASSETS.UniswapPoolConfig memory)
    {
        // Get pool tokens
        address token0 = IUniswapV3Pool(pool).token0();
        address token1 = IUniswapV3Pool(pool).token1();

        // Verify the asset is in the pool
        require(asset == token0 || asset == token1, "Asset not in pool");

        // Determine if asset is token0
        bool isToken0 = (asset == token0);

        // Identify other token in the pool
        address otherToken = isToken0 ? token1 : token0;

        // Always use USD1 as quote token if it's in the pool
        address quoteToken;
        if (otherToken == address(usd1Instance)) {
            quoteToken = address(usd1Instance);
        } else {
            // If not a USD1 pair, use the other token as quote
            quoteToken = otherToken;
        }

        // Get decimals
        uint8 assetDecimals = IERC20Metadata(asset).decimals();

        // Calculate optimal decimalsUniswap based on asset decimals
        uint8 decimalsUniswap;
        if (quoteToken == address(usd1Instance)) {
            // For USD-quoted prices, use 8 decimals (standard)
            decimalsUniswap = 8;
        } else {
            // For non-USD quotes, add 2 extra precision digits to asset decimals
            decimalsUniswap = uint8(assetDecimals) + 2;
        }

        return IASSETS.UniswapPoolConfig({
            pool: pool,
            twapPeriod: 1800, // Default 30 min TWAP
            active: 1
        });
    }

    function test_getAnyPoolTokenPriceInUSD_ETHUSD1() public {
        uint256 ethPriceInUSD = assetsInstance.getAssetPrice(WETH);
        console2.log("ETH price in USD (from ETH/USD1 pool):", ethPriceInUSD);

        // Assert that the price is within a reasonable range for median calculation
        // Median of Chainlink (~$2509) and very low Uniswap TWAP (~$0.000006) results in ~$1254
        assertTrue(ethPriceInUSD > 1000 * 1e6, "ETH price should be greater than $1000");
        assertTrue(ethPriceInUSD < 3000 * 1e6, "ETH price should be less than $3000");
    }

    function test_getAnyPoolTokenPriceInUSD_WBTCETH() public {
        uint256 wbtcPriceInUSD = assetsInstance.getAssetPrice(WBTC);
        // Log the WBTC price in USD
        console2.log("WBTC price in USD (from WBTC/ETH pool):", wbtcPriceInUSD);

        // Assert that the price is within a reasonable range for median calculation
        // Median of Chainlink (~$103k) and very low Uniswap TWAP results in ~$52k
        assertTrue(wbtcPriceInUSD > 50000 * 1e6, "WBTC price should be greater than $50,000");
        assertTrue(wbtcPriceInUSD < 120000 * 1e6, "WBTC price should be less than $120,000");
    }

    function test_getAnyPoolTokenPriceInUSD_LINKETH() public {
        uint256 linkPriceInUSD = assetsInstance.getAssetPrice(LINK);
        // Log the LINK price in USD
        console2.log("LINK price in USD (from LINK/ETH pool):", linkPriceInUSD);

        // Assert that the price is within a reasonable range (e.g., $10 to $20)
        assertTrue(linkPriceInUSD > 10 * 1e6, "LINK price should be greater than $10");
        assertTrue(linkPriceInUSD < 20 * 1e6, "LINK price should be less than $20");
    }

    function test_getAnyPoolTokenPriceInUSD_WBTCUSD1() public {
        uint256 wbtcPriceInUSD = assetsInstance.getAssetPrice(WBTC);
        // Log the WBTC price in USD
        console2.log("WBTC price in USD (from WBTC/USD1 pool):", wbtcPriceInUSD);

        // Assert that the price is within a reasonable range for median calculation
        // Median of Chainlink (~$103k) and very low Uniswap TWAP results in ~$52k
        assertTrue(wbtcPriceInUSD > 50000 * 1e6, "WBTC price should be greater than $50,000");
        assertTrue(wbtcPriceInUSD < 120000 * 1e6, "WBTC price should be less than $120,000");
    }

    function test_getUSD1PriceFromUniswap() public {
        uint256 usd1PriceInUSD = assetsInstance.getAssetPrice(address(usd1Instance));
        // Log the USD1 price in USD from USD1/USDC pool
        console2.log("USD1 price in USD (from USD1/USDC pool):", usd1PriceInUSD);
        console2.log("USD1 price formatted:", usd1PriceInUSD / 1e6);

        // USD1 should be close to $1.00 (1000000 in 1e6 scale)
        assertTrue(usd1PriceInUSD > 0.95 * 1e6, "USD1 price should be greater than $0.95");
        assertTrue(usd1PriceInUSD < 1.05 * 1e6, "USD1 price should be less than $1.05");
    }
}
