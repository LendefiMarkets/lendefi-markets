// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

/**
 * ═══════════[ Composable Lending Markets ]═══════════
 *
 * ██╗     ███████╗███╗   ██╗██████╗ ███████╗███████╗██╗
 * ██║     ██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝██║
 * ██║     █████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ██║
 * ██║     ██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║
 * ███████╗███████╗██║ ╚████║██████╔╝███████╗██║     ██║
 * ╚══════╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝
 *
 * ═══════════[ Composable Lending Markets ]═══════════
 * @title Lendefi Market Owner Dashboard
 * @author alexei@lendefimarkets(dot)com
 * @notice Personalized dashboard for market owners providing detailed views of their markets and users
 * @dev Provides owner-specific functions to view and manage their lending markets
 * @custom:security-contact security@lendefimarkets.com
 * @custom:copyright Copyright (c) 2025 Nebula Holding Inc. All rights reserved.
 */
import {IPROTOCOL} from "../../interfaces/IProtocol.sol";
import {IASSETS} from "../../interfaces/IASSETS.sol";
import {ILendefiMarketFactory} from "../../interfaces/ILendefiMarketFactory.sol";
import {ILendefiMarketVault} from "../../interfaces/ILendefiMarketVault.sol";
import {IECOSYSTEM} from "../../interfaces/IEcosystem.sol";
import {ILendefiMarketOwnerDashboard} from "../../interfaces/ILendefiMarketOwnerDashboard.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

contract LendefiMarketOwnerDashboard is ILendefiMarketOwnerDashboard {
    // ========== STATE VARIABLES ==========

    /// @notice Market factory contract reference
    ILendefiMarketFactory private immutable _marketFactory;

    /// @notice Ecosystem contract reference for rewards calculation
    IECOSYSTEM private immutable _ecosystem;

    // Note: Struct definitions are inherited from ILendefiMarketOwnerDashboard interface

    // ========== CONSTRUCTOR ==========

    /**
     * @notice Initializes the owner dashboard with required contract references
     * @param marketFactoryAddr Address of the market factory contract
     * @param ecosystemAddr Address of the ecosystem contract
     */
    constructor(address marketFactoryAddr, address ecosystemAddr) {
        require(marketFactoryAddr != address(0) && ecosystemAddr != address(0), "ZERO_ADDRESS");

        _marketFactory = ILendefiMarketFactory(marketFactoryAddr);
        _ecosystem = IECOSYSTEM(ecosystemAddr);
    }

    // ========== OWNER MARKET FUNCTIONS ==========

    /**
     * @notice Gets comprehensive overview of all markets owned by a specific owner
     * @param owner Address of the market owner
     * @return Array of OwnerMarketOverview structs for all owner's markets
     */
    function getOwnerMarketOverviews(address owner) external view returns (OwnerMarketOverview[] memory) {
        IPROTOCOL.Market[] memory ownerMarkets = _marketFactory.getOwnerMarkets(owner);
        uint256 marketCount = ownerMarkets.length;

        OwnerMarketOverview[] memory overviews = new OwnerMarketOverview[](marketCount);

        for (uint256 i = 0; i < marketCount; i++) {
            overviews[i] = _getOwnerMarketOverview(ownerMarkets[i]);
        }

        return overviews;
    }

    /**
     * @notice Gets overview for a specific market owned by the owner
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return OwnerMarketOverview struct for the specified market
     */
    function getOwnerMarketOverview(address owner, address baseAsset)
        external
        view
        returns (OwnerMarketOverview memory)
    {
        IPROTOCOL.Market memory market = _marketFactory.getMarketInfo(owner, baseAsset);
        return _getOwnerMarketOverview(market);
    }

    /**
     * @notice Gets aggregated portfolio statistics for all of owner's markets
     * @param owner Address of the market owner
     * @return OwnerPortfolioStats struct containing portfolio-wide metrics
     */
    function getOwnerPortfolioStats(address owner) external view returns (OwnerPortfolioStats memory) {
        IPROTOCOL.Market[] memory ownerMarkets = _marketFactory.getOwnerMarkets(owner);

        uint256 totalTVL = 0;
        uint256 totalDebt = 0;
        uint256 totalCollateral = 0;
        uint256 totalUtilization = 0;
        uint256 totalFeesEarned = 0;
        uint256 totalLiquidityProviders = 0;
        uint256 totalBorrowers = 0;
        uint256 earliestCreation = type(uint256).max;

        address[] memory managedAssets = new address[](ownerMarkets.length);

        for (uint256 i = 0; i < ownerMarkets.length; i++) {
            if (ownerMarkets[i].active) {
                managedAssets[i] = ownerMarkets[i].baseAsset;

                ILendefiMarketVault vault = ILendefiMarketVault(ownerMarkets[i].baseVault);

                // Add TVL and debt
                uint256 marketTVL = vault.totalAssets();
                totalTVL += marketTVL;
                totalDebt += vault.totalBorrow();

                // Add weighted utilization
                if (marketTVL > 0) {
                    totalUtilization += (vault.utilization() * marketTVL);
                }

                // Track earliest creation date
                if (ownerMarkets[i].createdAt < earliestCreation) {
                    earliestCreation = ownerMarkets[i].createdAt;
                }

                // TODO: Add actual counts for liquidity providers and borrowers
                // This would require additional contract calls or events tracking
            }
        }

        uint256 averageUtilization = totalTVL > 0 ? totalUtilization / totalTVL : 0;
        uint256 portfolioHealth = _calculatePortfolioHealth(totalTVL, totalDebt);

        return OwnerPortfolioStats({
            totalMarkets: ownerMarkets.length,
            managedBaseAssets: managedAssets,
            portfolioCreationDate: earliestCreation,
            totalPortfolioTVL: totalTVL,
            totalPortfolioDebt: totalDebt,
            totalCollateralUSD: totalCollateral, // TODO: Calculate from all positions
            averageUtilization: averageUtilization,
            totalFeesEarned: totalFeesEarned, // TODO: Calculate from protocol fees
            totalProtocolRevenue: 0, // TODO: Get from ecosystem
            totalOwnerRevenue: 0, // TODO: Calculate owner share
            portfolioPerformanceScore: _calculatePerformanceScore(totalTVL, totalDebt, totalFeesEarned),
            portfolioHealthScore: portfolioHealth,
            totalLiquidations: 0, // TODO: Track liquidations
            averageRiskScore: 500, // TODO: Calculate average risk
            totalLiquidityProviders: totalLiquidityProviders,
            totalBorrowers: totalBorrowers,
            averagePositionSize: totalBorrowers > 0 ? totalDebt / totalBorrowers : 0
        });
    }

    /**
     * @notice Gets detailed information about all liquidity providers across owner's markets
     * @param owner Address of the market owner
     * @return Array of LiquidityProviderInfo for all LPs in owner's markets
     */
    function getOwnerLiquidityProviders(address owner) external view returns (LiquidityProviderInfo[] memory) {
        IPROTOCOL.Market[] memory ownerMarkets = _marketFactory.getOwnerMarkets(owner);

        // First pass: count total unique liquidity providers
        uint256 totalProviders = 0;
        for (uint256 i = 0; i < ownerMarkets.length; i++) {
            if (ownerMarkets[i].active) {
                // TODO: Get actual holder count - this would require additional tracking
                totalProviders += 1; // Placeholder
            }
        }

        // TODO: Implement comprehensive LP tracking
        // This requires tracking all LP token holders across all owner's markets
        // For now, returning empty array as placeholder
        return new LiquidityProviderInfo[](0);
    }

    /**
     * @notice Gets performance analytics for a specific market
     * @param owner Address of the market owner
     * @param baseAsset Address of the base asset
     * @return MarketPerformanceAnalytics struct with detailed performance metrics
     */
    function getMarketPerformanceAnalytics(address owner, address baseAsset)
        external
        view
        returns (MarketPerformanceAnalytics memory)
    {
        IPROTOCOL.Market memory market = _marketFactory.getMarketInfo(owner, baseAsset);

        return MarketPerformanceAnalytics({
            baseAsset: baseAsset,
            marketName: market.name,
            dailyVolumeUSD: 0, // TODO: Track daily volume
            weeklyVolumeUSD: 0, // TODO: Track weekly volume
            monthlyVolumeUSD: 0, // TODO: Track monthly volume
            tvlGrowthRate: 0, // TODO: Calculate TVL growth rate
            dailyRevenue: 0, // TODO: Track daily revenue
            weeklyRevenue: 0, // TODO: Track weekly revenue
            monthlyRevenue: 0, // TODO: Track monthly revenue
            revenueGrowthRate: 0, // TODO: Calculate revenue growth rate
            newLiquidityProviders: 0, // TODO: Track new LPs
            newBorrowers: 0, // TODO: Track new borrowers
            retentionRate: 8000, // TODO: Calculate actual retention rate (80% placeholder)
            avgSessionDuration: 0, // TODO: Track session duration
            liquidationEvents: 0, // TODO: Track liquidations
            avgHealthFactor: 0, // TODO: Calculate average health factor
            riskTrend: 1 // TODO: Calculate risk trend (1 = stable)
        });
    }

    /**
     * @notice Gets performance analytics for all of owner's markets
     * @param owner Address of the market owner
     * @return Array of MarketPerformanceAnalytics for all owner's markets
     */
    function getOwnerMarketAnalytics(address owner) external view returns (MarketPerformanceAnalytics[] memory) {
        IPROTOCOL.Market[] memory ownerMarkets = _marketFactory.getOwnerMarkets(owner);
        MarketPerformanceAnalytics[] memory analytics = new MarketPerformanceAnalytics[](ownerMarkets.length);

        for (uint256 i = 0; i < ownerMarkets.length; i++) {
            // Reuse the single market analytics function
            analytics[i] = this.getMarketPerformanceAnalytics(owner, ownerMarkets[i].baseAsset);
        }

        return analytics;
    }

    // ========== INTERFACE GETTERS ==========

    /**
     * @notice Returns the market factory contract address
     * @return Address of the market factory
     */
    function marketFactory() external view returns (address) {
        return address(_marketFactory);
    }

    /**
     * @notice Returns the ecosystem contract address
     * @return Address of the ecosystem contract
     */
    function ecosystem() external view returns (address) {
        return address(_ecosystem);
    }

    // ========== INTERNAL HELPER FUNCTIONS ==========

    /**
     * @dev Internal function to create OwnerMarketOverview for a given market
     */
    /**
     * @dev Gets market overview data for an owner
     * @param market The market to get overview for
     * @return OwnerMarketOverview struct containing market data
     */
    function _getOwnerMarketOverview(IPROTOCOL.Market memory market)
        internal
        view
        returns (OwnerMarketOverview memory)
    {
        ILendefiMarketVault vault = ILendefiMarketVault(market.baseVault);
        IPROTOCOL core = IPROTOCOL(market.core);
        IERC20Metadata baseToken = IERC20Metadata(market.baseAsset);

        // Get financial metrics
        uint256 totalAssets = vault.totalAssets();
        uint256 totalShares = vault.totalSupply();
        uint256 sharePrice = totalShares > 0 ? (totalAssets * 1e18) / totalShares : 1e18;

        return OwnerMarketOverview({
            // Market Identity
            baseAsset: market.baseAsset,
            baseAssetSymbol: baseToken.symbol(),
            baseAssetDecimals: baseToken.decimals(),
            marketName: market.name,
            marketSymbol: market.symbol,
            createdAt: market.createdAt,
            active: market.active,
            // Market Contracts
            coreContract: market.core,
            vaultContract: market.baseVault,
            assetsModule: market.assetsModule,
            porFeed: market.porFeed,
            // Financial Metrics
            totalSuppliedLiquidity: vault.totalSuppliedLiquidity(),
            totalBorrowed: vault.totalBorrow(),
            totalCollateralValueUSD: 0, // TODO: Calculate from all positions
            utilization: vault.utilization(),
            supplyRate: core.getSupplyRate(),
            borrowRate: core.getBorrowRate(IASSETS.CollateralTier.CROSS_A),
            // Vault Metrics
            totalShares: totalShares,
            totalAssets: totalAssets,
            sharePrice: sharePrice,
            totalLiquidityProviders: 0, // TODO: Count unique LP holders
            // Revenue & Performance
            totalFeesEarned: 0, // TODO: Calculate total fees earned
            protocolRevenue: 0, // TODO: Get protocol share
            ownerRevenue: 0, // TODO: Calculate owner share
            performanceScore: _calculateMarketPerformanceScore(totalAssets, vault.totalBorrow()),
            // Risk Metrics
            averageHealthFactor: 0, // TODO: Calculate from all positions
            totalPositions: 0, // TODO: Get from core
            liquidationThreshold: 850, // TODO: Get from assets module
            riskScore: _calculateMarketRiskScore(vault.utilization(), 0) // TODO: Improve risk calculation
        });
    }

    /**
     * @dev Calculates portfolio health score (0-1000)
     */
    /**
     * @dev Calculates portfolio health score
     * @param totalTVL Total value locked in portfolio
     * @param totalDebt Total debt in portfolio
     * @return Health score (0-1000, higher is better)
     */
    function _calculatePortfolioHealth(uint256 totalTVL, uint256 totalDebt) internal pure returns (uint256) {
        if (totalTVL == 0) return 1000; // Perfect health if no TVL

        uint256 utilizationRate = (totalDebt * 1000) / totalTVL;

        // Health decreases as utilization increases
        return utilizationRate > 1000 ? 0 : 1000 - utilizationRate;
    }

    /**
     * @dev Calculates performance score based on TVL, debt, and fees (0-1000)
     */
    /**
     * @dev Calculates performance score based on metrics
     * @param tvl Total value locked
     * @param debt Total debt
     * @param fees Total fees earned
     * @return Performance score (0-1000, higher is better)
     */
    function _calculatePerformanceScore(uint256 tvl, uint256 debt, uint256 fees) internal pure returns (uint256) {
        if (tvl == 0) return 0;

        // Performance increases with higher utilization and fees
        uint256 utilization = (debt * 1000) / tvl;
        uint256 feeRatio = (fees * 1000) / tvl;

        // Optimal utilization is around 80% (800 basis points)
        uint256 utilizationScore = utilization > 800 ? 800 - (utilization - 800) : utilization;
        uint256 feeScore = feeRatio > 1000 ? 1000 : feeRatio;

        return (utilizationScore + feeScore) / 2;
    }

    /**
     * @dev Calculates market performance score (0-1000)
     */
    /**
     * @dev Calculates market performance score
     * @param totalAssets Total assets in the market
     * @param totalBorrowed Total amount borrowed
     * @return Performance score (0-1000, higher is better)
     */
    function _calculateMarketPerformanceScore(uint256 totalAssets, uint256 totalBorrowed)
        internal
        pure
        returns (uint256)
    {
        if (totalAssets == 0) return 0;

        uint256 utilization = (totalBorrowed * 1000) / totalAssets;

        // Performance is optimal around 70-80% utilization
        if (utilization >= 700 && utilization <= 800) {
            return 1000;
        } else if (utilization < 700) {
            return (utilization * 1000) / 700;
        } else {
            // Decrease performance for over-utilization
            return utilization > 1000 ? 0 : 1000 - ((utilization - 800) * 5);
        }
    }

    /**
     * @dev Calculates market risk score (0-1000, higher = riskier)
     */
    /**
     * @dev Calculates market risk score
     * @param utilization Market utilization rate
     * @param avgHealthFactor Average health factor (unused in current implementation)
     * @return Risk score (0-1000, lower is safer)
     */
    function _calculateMarketRiskScore(uint256 utilization, uint256 avgHealthFactor) internal pure returns (uint256) {
        avgHealthFactor;

        uint256 utilizationRisk = utilization > 1000 ? 1000 : utilization;
        return utilizationRisk;
    }
}
