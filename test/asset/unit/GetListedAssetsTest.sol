// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {console2} from "forge-std/console2.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {WETHPriceConsumerV3} from "../../../contracts/mock/WETHOracle.sol";
import {LINKPriceConsumerV3} from "../../../contracts/mock/LINKOracle.sol";
import {StablePriceConsumerV3} from "../../../contracts/mock/StableOracle.sol";
import {TokenMock} from "../../../contracts/mock/TokenMock.sol";
import {LINK} from "../../../contracts/mock/LINK.sol";
import {MockUniswapV3Pool} from "../../../contracts/mock/MockUniswapV3Pool.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

contract GetListedAssetsTest is BasicDeploy {
    WETHPriceConsumerV3 internal wethOracle;
    StablePriceConsumerV3 internal usdcOracle;
    LINKPriceConsumerV3 internal linkOracleInstance;

    // Mock pools
    MockUniswapV3Pool internal wethUsdcPool;
    MockUniswapV3Pool internal usdcDaiPool;
    MockUniswapV3Pool internal linkUsdcPool;

    // Mock tokens
    IERC20 internal daiInstance;
    LINK internal linkInstance;

    function setUp() public {
        // Use deployMarketsWithUSDC() instead of deployComplete()
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()
        vm.warp(block.timestamp + 90 days);

        // Deploy mock tokens (USDC already deployed by deployCompleteWithOracle())
        wethInstance = new WETH9();

        // Create additional mock tokens for testing
        daiInstance = new TokenMock("DAI", "DAI");
        linkInstance = new LINK();

        // Deploy oracles
        wethOracle = new WETHPriceConsumerV3();
        usdcOracle = new StablePriceConsumerV3();
        linkOracleInstance = new LINKPriceConsumerV3();

        // Set prices
        wethOracle.setPrice(2500e8); // $2500 per ETH
        usdcOracle.setPrice(1e8); // $1 per stable
        linkOracleInstance.setPrice(14e8); // $14 Link

        // Setup roles
        vm.prank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(marketCoreInstance));

        // Create mock Uniswap pools
        wethUsdcPool = new MockUniswapV3Pool(address(wethInstance), address(usdcInstance), 3000);
        usdcDaiPool = new MockUniswapV3Pool(address(usdcInstance), address(daiInstance), 500);
        linkUsdcPool = new MockUniswapV3Pool(address(linkInstance), address(usdcInstance), 3000);

        // Configure pools to pass observation checks
        int56[] memory tickCumulatives = new int56[](2);
        tickCumulatives[0] = 0;
        tickCumulatives[1] = 1800 * 600;

        uint160[] memory secondsPerLiquidityCumulatives = new uint160[](2);
        secondsPerLiquidityCumulatives[0] = 1000;
        secondsPerLiquidityCumulatives[1] = 2000;

        wethUsdcPool.setTickCumulatives(tickCumulatives);
        wethUsdcPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        wethUsdcPool.setObserveSuccess(true);

        usdcDaiPool.setTickCumulatives(tickCumulatives);
        usdcDaiPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        usdcDaiPool.setObserveSuccess(true);

        linkUsdcPool.setTickCumulatives(tickCumulatives);
        linkUsdcPool.setSecondsPerLiquidity(secondsPerLiquidityCumulatives);
        linkUsdcPool.setObserveSuccess(true);
    }

    function test_GetListedAssets_AfterAddingAssets() public {
        // Configure WETH as listed asset
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
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure USDC as listed asset - now using proper mock pool
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
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 0}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(usdcDaiPool), twapPeriod: 1800, active: 1})
            })
        );

        vm.stopPrank();

        // Get assets after listing 2 assets
        address[] memory assetsAfterListing = assetsInstance.getListedAssets();

        // Verify array length
        assertEq(assetsAfterListing.length, 2, "Listed assets array should have 2 elements");

        // Verify array contents
        bool foundWeth = false;
        bool foundUsdc = false;

        for (uint256 i = 0; i < assetsAfterListing.length; i++) {
            if (assetsAfterListing[i] == address(wethInstance)) {
                foundWeth = true;
            }
            if (assetsAfterListing[i] == address(usdcInstance)) {
                foundUsdc = true;
            }
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
    }

    function test_GetListedAssets_MultipleAddsAndOrder() public {
        // Add multiple assets
        vm.startPrank(address(timelockInstance));

        // Add WETH
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Add USDC - now with proper pool
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(usdcDaiPool), twapPeriod: 1800, active: 1})
            })
        );

        // Add DAI - with appropriate pool and active chainlink
        assetsInstance.updateAssetConfig(
            address(daiInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 850,
                liquidationThreshold: 900,
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Add LINK - with appropriate pool and active chainlink
        assetsInstance.updateAssetConfig(
            address(linkInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 700,
                liquidationThreshold: 750,
                maxSupplyThreshold: 500_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_B,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(linkOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();

        // Get assets after listing 4 assets
        address[] memory listedAssets = assetsInstance.getListedAssets();

        // Verify array length
        assertEq(listedAssets.length, 4, "Listed assets array should have 4 elements");

        // Verify all assets are included
        bool foundWeth = false;
        bool foundUsdc = false;
        bool foundDai = false;
        bool foundLink = false;

        for (uint256 i = 0; i < listedAssets.length; i++) {
            if (listedAssets[i] == address(wethInstance)) foundWeth = true;
            if (listedAssets[i] == address(usdcInstance)) foundUsdc = true;
            if (listedAssets[i] == address(daiInstance)) foundDai = true;
            if (listedAssets[i] == address(linkInstance)) foundLink = true;
        }

        assertTrue(foundWeth, "WETH should be in listed assets");
        assertTrue(foundUsdc, "USDC should be in listed assets");
        assertTrue(foundDai, "DAI should be in listed assets");
        assertTrue(foundLink, "LINK should be in listed assets");
    }
}
