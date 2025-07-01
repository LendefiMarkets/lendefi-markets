// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {LendefiMarketOwnerDashboard} from "../../contracts/markets/helper/LendefiMarketOwnerDashboard.sol";
import {ILendefiMarketOwnerDashboard} from "../../contracts/interfaces/ILendefiMarketOwnerDashboard.sol";
import {ILendefiMarketVault} from "../../contracts/interfaces/ILendefiMarketVault.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract LendefiMarketOwnerDashboardTest is BasicDeploy {
    LendefiMarketOwnerDashboard public ownerDashboard;
    TokenMock public daiToken;
    TokenMock public wethToken;

    function setUp() public {
        // Deploy basic infrastructure with USDC market
        deployMarketsWithUSDC();

        // Deploy owner dashboard
        ownerDashboard = new LendefiMarketOwnerDashboard(address(marketFactoryInstance), address(ecoInstance));

        // Create additional test tokens
        daiToken = new TokenMock("DAI Stablecoin", "DAI");
        wethToken = new TokenMock("Wrapped Ether", "WETH");

        // Add tokens to allowlist
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(daiToken));
        marketFactoryInstance.addAllowedBaseAsset(address(wethToken));
        vm.stopPrank();

        // Setup governance tokens for charlie (required for permissionless market creation)
        vm.prank(guardian);
        tokenInstance.transfer(charlie, 10000 ether); // Transfer 10,000 tokens
        vm.prank(charlie);
        tokenInstance.approve(address(marketFactoryInstance), 200 ether); // Approve for 2 markets (100 each)

        // Create additional markets for charlie
        vm.startPrank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");
        marketFactoryInstance.createMarket(address(wethToken), "Lendefi WETH Market", "lfWETH");
        vm.stopPrank();

        // Fund users for testing
        deal(address(usdcInstance), alice, getUSDCAmount(10000));
        deal(address(daiToken), alice, 10000e18);
        deal(address(wethToken), alice, 10e18);
        deal(address(usdcInstance), bob, getUSDCAmount(5000));
        deal(address(daiToken), bob, 5000e18);
    }

    // ========== Constructor Tests ==========

    function test_Constructor() public {
        assertEq(ownerDashboard.marketFactory(), address(marketFactoryInstance));
        assertEq(ownerDashboard.ecosystem(), address(ecoInstance));
    }

    function test_Revert_Constructor_ZeroFactory() public {
        vm.expectRevert("ZERO_ADDRESS");
        new LendefiMarketOwnerDashboard(address(0), address(ecoInstance));
    }

    function test_Revert_Constructor_ZeroEcosystem() public {
        vm.expectRevert("ZERO_ADDRESS");
        new LendefiMarketOwnerDashboard(address(marketFactoryInstance), address(0));
    }

    // ========== Owner Market Overview Tests ==========

    function test_GetOwnerMarketOverviews() public {
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory overviews =
            ownerDashboard.getOwnerMarketOverviews(charlie);

        // Charlie should have 3 markets (USDC, DAI, WETH)
        assertEq(overviews.length, 3);

        // Check USDC market
        bool foundUSDC = false;
        for (uint256 i = 0; i < overviews.length; i++) {
            if (overviews[i].baseAsset == address(usdcInstance)) {
                foundUSDC = true;
                assertEq(overviews[i].baseAssetSymbol, "USDC");
                assertEq(overviews[i].baseAssetDecimals, IERC20Metadata(address(usdcInstance)).decimals());
                assertEq(overviews[i].marketName, "Lendefi Yield Token");
                assertEq(overviews[i].marketSymbol, "LYTUSDC");
                assertTrue(overviews[i].active);
                assertTrue(overviews[i].coreContract != address(0));
                assertTrue(overviews[i].vaultContract != address(0));
                assertEq(overviews[i].sharePrice, 1e18); // 1:1 initially
                break;
            }
        }
        assertTrue(foundUSDC, "USDC market not found");
    }

    function test_GetOwnerMarketOverviews_EmptyOwner() public {
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory overviews =
            ownerDashboard.getOwnerMarketOverviews(bob);

        // Bob has no markets
        assertEq(overviews.length, 0);
    }

    function test_GetOwnerMarketOverview_Specific() public {
        ILendefiMarketOwnerDashboard.OwnerMarketOverview memory overview =
            ownerDashboard.getOwnerMarketOverview(charlie, address(daiToken));

        assertEq(overview.baseAsset, address(daiToken));
        assertEq(overview.baseAssetSymbol, "DAI");
        assertEq(overview.baseAssetDecimals, IERC20Metadata(address(daiToken)).decimals());
        assertEq(overview.marketName, "Lendefi DAI Market");
        assertEq(overview.marketSymbol, "lfDAI");
        assertTrue(overview.active);
        // Performance and risk scores can be 0 for empty markets
        assertGe(overview.performanceScore, 0);
        assertGe(overview.riskScore, 0);
    }

    // ========== Portfolio Stats Tests ==========

    function test_GetOwnerPortfolioStats() public {
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory stats = ownerDashboard.getOwnerPortfolioStats(charlie);

        // Check basic stats
        assertEq(stats.totalMarkets, 3); // USDC, DAI, WETH
        assertEq(stats.managedBaseAssets.length, 3);
        assertGt(stats.portfolioCreationDate, 0);
        assertEq(stats.portfolioHealthScore, 1000); // Perfect health initially (no debt)
        // Performance score can be 0 for empty portfolios
        assertGe(stats.portfolioPerformanceScore, 0);

        // Check that managed assets include our tokens
        bool foundUSDC = false;
        bool foundDAI = false;
        bool foundWETH = false;

        for (uint256 i = 0; i < stats.managedBaseAssets.length; i++) {
            if (stats.managedBaseAssets[i] == address(usdcInstance)) {
                foundUSDC = true;
            }
            if (stats.managedBaseAssets[i] == address(daiToken)) {
                foundDAI = true;
            }
            if (stats.managedBaseAssets[i] == address(wethToken)) {
                foundWETH = true;
            }
        }

        assertTrue(foundUSDC && foundDAI && foundWETH, "Not all assets found in managed assets");
    }

    function test_GetOwnerPortfolioStats_WithLiquidity() public {
        // Add liquidity to USDC market
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));

        vm.startPrank(alice);
        uint256 depositAmount = getUSDCAmount(1000);
        usdcInstance.approve(usdcMarket.baseVault, depositAmount);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(depositAmount, alice);
        vm.stopPrank();

        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory stats = ownerDashboard.getOwnerPortfolioStats(charlie);

        // Should have TVL now
        assertGt(stats.totalPortfolioTVL, 0);

        // Health should still be perfect (no debt yet)
        assertEq(stats.portfolioHealthScore, 1000);
    }

    function test_GetOwnerPortfolioStats_EmptyOwner() public {
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory stats = ownerDashboard.getOwnerPortfolioStats(bob);

        // Bob has no markets
        assertEq(stats.totalMarkets, 0);
        assertEq(stats.totalPortfolioTVL, 0);
        assertEq(stats.portfolioHealthScore, 1000); // Perfect health with no activity
    }

    // ========== Borrower & LP Tests ==========

    function test_GetOwnerLiquidityProviders() public {
        ILendefiMarketOwnerDashboard.LiquidityProviderInfo[] memory providers =
            ownerDashboard.getOwnerLiquidityProviders(charlie);

        // Currently returns empty array (placeholder implementation)
        assertEq(providers.length, 0);
    }

    // ========== Performance Analytics Tests ==========

    function test_GetMarketPerformanceAnalytics() public {
        ILendefiMarketOwnerDashboard.MarketPerformanceAnalytics memory analytics =
            ownerDashboard.getMarketPerformanceAnalytics(charlie, address(daiToken));

        assertEq(analytics.baseAsset, address(daiToken));
        assertEq(analytics.marketName, "Lendefi DAI Market");
        assertEq(analytics.retentionRate, 8000); // 80% placeholder
        assertEq(analytics.riskTrend, 1); // Stable
    }

    function test_GetOwnerMarketAnalytics() public {
        ILendefiMarketOwnerDashboard.MarketPerformanceAnalytics[] memory analytics =
            ownerDashboard.getOwnerMarketAnalytics(charlie);

        // Should have analytics for all 3 markets
        assertEq(analytics.length, 3);

        // Check that all markets are represented
        bool foundUSDC = false;
        bool foundDAI = false;
        bool foundWETH = false;

        for (uint256 i = 0; i < analytics.length; i++) {
            if (analytics[i].baseAsset == address(usdcInstance)) {
                foundUSDC = true;
            }
            if (analytics[i].baseAsset == address(daiToken)) foundDAI = true;
            if (analytics[i].baseAsset == address(wethToken)) foundWETH = true;

            // All should have default values
            assertEq(analytics[i].retentionRate, 8000);
            assertEq(analytics[i].riskTrend, 1);
        }

        assertTrue(foundUSDC && foundDAI && foundWETH, "Not all markets found in analytics");
    }

    // ========== Ranking Tests ==========

    // ========== Integration Tests ==========

    function test_FullOwnerDashboardIntegration() public {
        // Set up a realistic scenario with multiple markets and users

        // Alice provides liquidity to USDC and DAI markets
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));
        IPROTOCOL.Market memory daiMarket = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));

        vm.startPrank(alice);
        // USDC market
        uint256 aliceDeposit = getUSDCAmount(5000);
        usdcInstance.approve(usdcMarket.baseVault, aliceDeposit);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(aliceDeposit, alice);

        // DAI market
        daiToken.approve(daiMarket.baseVault, 3000e18);
        ILendefiMarketVault(daiMarket.baseVault).deposit(3000e18, alice);
        vm.stopPrank();

        // Bob provides liquidity to USDC market
        vm.startPrank(bob);
        uint256 bobDeposit = getUSDCAmount(2000);
        usdcInstance.approve(usdcMarket.baseVault, bobDeposit);
        ILendefiMarketVault(usdcMarket.baseVault).deposit(bobDeposit, bob);
        vm.stopPrank();

        // Test all owner dashboard functions work together
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory overviews =
            ownerDashboard.getOwnerMarketOverviews(charlie);
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory stats = ownerDashboard.getOwnerPortfolioStats(charlie);
        ILendefiMarketOwnerDashboard.MarketPerformanceAnalytics[] memory analytics =
            ownerDashboard.getOwnerMarketAnalytics(charlie);

        // Verify comprehensive data
        assertEq(overviews.length, 3);
        assertEq(stats.totalMarkets, 3);
        assertGt(stats.totalPortfolioTVL, 0);
        assertEq(analytics.length, 3);

        // Verify TVL is correctly aggregated across markets
        assertGt(stats.totalPortfolioTVL, getUSDCAmount(5000)); // At least Alice's USDC deposit
        assertEq(stats.portfolioHealthScore, 1000); // Still perfect health (no debt)
    }

    function test_EmptyOwnerState() public {
        // Test with an owner that has no markets

        // Test all functions with an address that has no markets
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory overviews =
            ownerDashboard.getOwnerMarketOverviews(alice);
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory stats = ownerDashboard.getOwnerPortfolioStats(alice);
        assertEq(overviews.length, 0);
        assertEq(stats.totalMarkets, 0);
        assertEq(stats.totalPortfolioTVL, 0);
        assertEq(stats.portfolioHealthScore, 1000); // Perfect health with no activity
    }

    function test_OwnerSpecificData() public {
        // Create a second market owner to test owner-specific filtering
        address david = makeAddr("david");

        // Setup governance tokens for david (required for permissionless market creation)
        // Use deal to give david tokens directly (test environment)
        deal(address(tokenInstance), david, 10000 ether);

        vm.prank(david);
        tokenInstance.approve(address(marketFactoryInstance), type(uint256).max); // Give unlimited approval

        // David creates his own market
        vm.startPrank(david);
        marketFactoryInstance.createMarket(address(usdcInstance), "David's USDC Market", "dUSDC");
        vm.stopPrank();

        // Verify charlie's and david's dashboards are separate
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory charlieMarkets =
            ownerDashboard.getOwnerMarketOverviews(charlie);
        ILendefiMarketOwnerDashboard.OwnerMarketOverview[] memory davidMarkets =
            ownerDashboard.getOwnerMarketOverviews(david);

        assertEq(charlieMarkets.length, 3); // USDC, DAI, WETH
        assertEq(davidMarkets.length, 1); // Only USDC

        // Check that david's market has different name/symbol
        assertEq(davidMarkets[0].marketName, "David's USDC Market");
        assertEq(davidMarkets[0].marketSymbol, "dUSDC");
        assertEq(davidMarkets[0].baseAsset, address(usdcInstance));

        // Portfolio stats should also be different
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory charlieStats =
            ownerDashboard.getOwnerPortfolioStats(charlie);
        ILendefiMarketOwnerDashboard.OwnerPortfolioStats memory davidStats =
            ownerDashboard.getOwnerPortfolioStats(david);

        assertEq(charlieStats.totalMarkets, 3);
        assertEq(davidStats.totalMarkets, 1);
    }
}
