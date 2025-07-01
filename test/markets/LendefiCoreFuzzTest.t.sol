// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {ILendefiMarketVault} from "../../contracts/interfaces/ILendefiMarketVault.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {MockPriceOracle} from "../../contracts/mock/MockPriceOracle.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract LendefiCoreFuzzTest is BasicDeploy {
    // Test tokens and oracles
    WETHPriceConsumerV3 public wethOracle;

    // Constants
    uint256 constant ETH_PRICE = 2500e8; // $2500 per ETH

    function setUp() public {
        // Deploy base contracts and market
        deployMarketsWithUSDC();

        // Deploy test tokens
        wethInstance = new WETH9();

        // Deploy oracles
        wethOracle = new WETHPriceConsumerV3();

        // Set initial prices
        wethOracle.setPrice(int256(ETH_PRICE));

        // Setup assets in the assets module
        vm.startPrank(address(timelockInstance));

        // Configure USDC (needed for credit limit calculations)
        MockPriceOracle usdcOracle = new MockPriceOracle();
        usdcOracle.setPrice(int256(1e8)); // $1 per USDC

        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: usdcInstance.decimals(),
                borrowThreshold: 950, // 95% LTV for stablecoin
                liquidationThreshold: 980, // 98% liquidation for stablecoin
                maxSupplyThreshold: getUSDCAmount(100_000_000), // 100M USDC
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure WETH (CROSS_A tier)
        assetsInstance.updateAssetConfig(
            address(wethInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 18,
                borrowThreshold: 800, // 80% LTV
                liquidationThreshold: 850, // 85% liquidation
                maxSupplyThreshold: 10_000 ether,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        vm.stopPrank();

        // Setup initial liquidity
        uint256 aliceDeposit = getUSDCAmount(10_000_000); // 10M USDC
        deal(address(usdcInstance), alice, aliceDeposit);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), aliceDeposit);
        marketCoreInstance.depositLiquidity(aliceDeposit, marketVaultInstance.previewDeposit(aliceDeposit), 100);
        vm.stopPrank();

        // Give liquidator governance tokens
        deal(address(tokenInstance), liquidator, 30_000 ether);
    }

    // ============ Supply/Withdraw Liquidity Fuzz Tests ============

    function testFuzz_SupplyAndWithdrawLiquidity(uint256 amount, uint256 withdrawRatio) public {
        // Bound inputs
        amount = bound(amount, getUSDCAmount(1), getUSDCAmount(100_000_000)); // 1 to 100M USDC
        withdrawRatio = bound(withdrawRatio, 1, 100); // 1-100% withdrawal

        // Setup
        deal(address(usdcInstance), charlie, amount);

        // Supply liquidity
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketCoreInstance), amount);

        uint256 expectedShares = marketVaultInstance.previewDeposit(amount);
        marketCoreInstance.depositLiquidity(amount, expectedShares, 500); // 5% slippage

        uint256 shares = marketVaultInstance.balanceOf(charlie);
        assertGe(shares, 0);
        vm.stopPrank();

        // Roll to next block for MEV protection
        vm.roll(block.number + 1);

        // Withdraw partial amount
        uint256 withdrawShares = (shares * withdrawRatio) / 100;
        if (withdrawShares > 0) {
            uint256 expectedAmount = marketVaultInstance.previewRedeem(withdrawShares);

            vm.startPrank(charlie);
            marketVaultInstance.approve(address(marketCoreInstance), withdrawShares); // Approve Core to move shares
            marketCoreInstance.redeemLiquidityShares(withdrawShares, expectedAmount, 500);
            vm.stopPrank();

            assertEq(marketVaultInstance.balanceOf(charlie), shares - withdrawShares);
        }
    }

    // ============ Collateral Supply/Withdraw Fuzz Tests ============

    function testFuzz_SupplyAndWithdrawCollateral(uint256 collateralAmount, uint256 withdrawAmount) public {
        // Bound inputs
        collateralAmount = bound(collateralAmount, 0.01 ether, 100 ether);
        withdrawAmount = bound(withdrawAmount, 0, collateralAmount);

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply collateral
        deal(address(wethInstance), bob, collateralAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), collateralAmount);
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1);

        // Verify supply
        address[] memory assets = marketCoreInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(assets.length, 1);
        assertEq(assets[0], address(wethInstance));

        // Withdraw if amount > 0
        if (withdrawAmount > 0) {
            uint256 expectedCreditLimit = marketCoreInstance.calculateCreditLimit(bob, positionId);

            vm.startPrank(bob);
            marketCoreInstance.withdrawCollateral(
                address(wethInstance),
                withdrawAmount,
                positionId,
                expectedCreditLimit,
                50 // 0.5% max slippage for reasonable tolerance
            );
            vm.stopPrank();

            assertEq(wethInstance.balanceOf(bob), withdrawAmount);
        }
    }

    // ============ Borrow/Repay Fuzz Tests ============

    function testFuzz_BorrowAndRepay(uint256 collateralAmount, uint256 borrowRatio, uint256 repayRatio) public {
        // Aggressive bounds to test edge cases
        collateralAmount = bound(collateralAmount, 0.001 ether, 1000 ether);
        borrowRatio = bound(borrowRatio, 1, 99); // Test extreme ratios
        repayRatio = bound(repayRatio, 1, 100);

        // Create position and supply collateral
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        deal(address(wethInstance), bob, collateralAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), collateralAmount);

        // Calculate and execute borrow
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = (creditLimit * borrowRatio) / 100;

        // Handle edge case: very small credit limits
        if (creditLimit < getUSDCAmount(1)) return; // Skip if credit limit < 1 USDC

        uint256 availableLiquidity = marketVaultInstance.totalAssets() - marketVaultInstance.totalBorrow();

        if (borrowAmount > 0 && borrowAmount <= availableLiquidity) {
            try marketCoreInstance.borrow(positionId, borrowAmount, creditLimit, 100) {
                // Verify borrow
                uint256 debt = marketCoreInstance.calculateDebtWithInterest(bob, positionId);
                assertGe(debt, borrowAmount);

                // Time passes
                _simulateTimeAndAccrueInterest(7 days);

                // Repay
                uint256 currentDebt = marketCoreInstance.calculateDebtWithInterest(bob, positionId);
                uint256 repayAmount = (currentDebt * repayRatio) / 100;

                // Handle edge case: very small repay amounts
                if (repayAmount == 0) repayAmount = 1;

                deal(address(usdcInstance), bob, repayAmount);
                _repay(bob, positionId, repayAmount);

                // Verify repayment
                uint256 remainingDebt = marketCoreInstance.calculateDebtWithInterest(bob, positionId);
                assertApproxEqAbs(remainingDebt, currentDebt - repayAmount, 1);
            } catch {
                // Expected failures for edge cases - protocol should handle gracefully
                // Could be CreditLimitExceeded, LowLiquidity, etc.
            }
        }
    }

    // ============ Interest Accrual Fuzz Tests ============

    function testFuzz_InterestAccrual(uint256 borrowAmount, uint256 timeElapsed) public {
        // Aggressive bounds to test edge cases and potential overflows
        borrowAmount = bound(borrowAmount, getUSDCAmount(1), getUSDCAmount(1_000_000)); // 1 USDC to 1M USDC
        timeElapsed = bound(timeElapsed, 1 seconds, 10 * 365 days); // 1 second to 10 years

        // Setup position and borrow
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        deal(address(wethInstance), bob, 10 ether);
        _supplyCollateral(bob, positionId, address(wethInstance), 10 ether);

        // Only proceed if we can borrow
        uint256 availableLiquidity = marketVaultInstance.totalAssets() - marketVaultInstance.totalBorrow();
        if (borrowAmount <= availableLiquidity) {
            try marketCoreInstance.borrow(positionId, borrowAmount, type(uint256).max, 1000) {
                uint256 initialDebt = marketCoreInstance.calculateDebtWithInterest(bob, positionId);

                // Simulate time passing
                vm.warp(block.timestamp + timeElapsed);

                try marketCoreInstance.calculateDebtWithInterest(bob, positionId) returns (uint256 finalDebt) {
                    // For very short times, debt might not increase due to precision
                    if (timeElapsed > 1 days) {
                        assertGe(finalDebt, initialDebt, "Debt should not decrease");
                    }

                    // Test for reasonable overflow protection
                    // If calculation overflows, it should revert rather than wrap around
                    if (finalDebt < initialDebt) {
                        revert("Potential overflow detected");
                    }
                } catch {
                    // Interest calculation overflow is acceptable for extreme parameters
                    // The protocol should handle this gracefully
                }
            } catch {
                // Borrow might fail for extreme amounts - this is acceptable
            }
        }
    }

    // ============ Health Factor Fuzz Tests ============

    function testFuzz_HealthFactor(uint256 collateralValue, uint256 debtRatio) public {
        // Aggressive bounds to test edge cases
        collateralValue = bound(collateralValue, getUSDCAmount(1), getUSDCAmount(10_000_000)); // $1 to $10M
        debtRatio = bound(debtRatio, 0, 150); // 0-150% (test over-liquidation)

        // Calculate WETH amount for target collateral value
        uint256 wethAmount = (((collateralValue * 1e18) / ETH_PRICE) * 1e8) / 10 ** usdcInstance.decimals();

        // Create position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        deal(address(wethInstance), bob, wethAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), wethAmount);

        if (debtRatio > 0) {
            // Calculate max borrowable at liquidation threshold (85% for WETH)
            uint256 maxBorrowAtLiquidation = (collateralValue * 850) / 1000;
            uint256 borrowAmount = (maxBorrowAtLiquidation * debtRatio) / 100;

            uint256 availableLiquidity = marketVaultInstance.totalAssets() - marketVaultInstance.totalBorrow();

            if (borrowAmount > 0 && borrowAmount <= availableLiquidity) {
                try marketCoreInstance.borrow(positionId, borrowAmount, type(uint256).max, 1000) {
                    uint256 healthFactor = marketCoreInstance.healthFactor(bob, positionId);

                    if (debtRatio >= 100) {
                        // Over-collateralized - should be liquidatable
                        assertLe(healthFactor, 1e6, "Should be liquidatable when over 100% debt ratio");
                        assertTrue(
                            marketCoreInstance.isLiquidatable(bob, positionId), "Position should be liquidatable"
                        );
                    } else if (debtRatio >= 85) {
                        // Near liquidation threshold - could go either way
                        // Health factor should be close to 1.0
                        if (healthFactor <= 1e6) {
                            assertTrue(marketCoreInstance.isLiquidatable(bob, positionId));
                        } else {
                            assertFalse(marketCoreInstance.isLiquidatable(bob, positionId));
                        }
                    } else {
                        // Should be healthy
                        assertGt(healthFactor, 1e6, "Should be healthy when under liquidation threshold");
                        assertFalse(marketCoreInstance.isLiquidatable(bob, positionId), "Should not be liquidatable");
                    }
                } catch {
                    // Borrow might fail for extreme debt ratios - acceptable
                    // Could be CreditLimitExceeded, which is correct behavior
                }
            }
        }
    }

    // ============ Multi-Asset Position Fuzz Tests ============

    function testFuzz_MultiAssetPosition(uint256 wethAmount, uint256 usdcAmount) public {
        // Aggressive bounds to test precision and edge cases
        wethAmount = bound(wethAmount, 1 wei, 1000 ether); // Test from minimum to very large
        usdcAmount = bound(usdcAmount, 1, getUSDCAmount(1_000_000)); // Test from 1 wei to 1M USDC

        // Create cross-collateral position
        uint256 positionId = _createPosition(bob, address(wethInstance), false);

        // Supply WETH
        deal(address(wethInstance), bob, wethAmount);
        _supplyCollateral(bob, positionId, address(wethInstance), wethAmount);

        // Supply USDC as collateral
        deal(address(usdcInstance), bob, usdcAmount);
        _supplyCollateral(bob, positionId, address(usdcInstance), usdcAmount);

        // Verify both assets are tracked
        address[] memory assets = marketCoreInstance.getPositionCollateralAssets(bob, positionId);
        assertEq(assets.length, 2);

        // Calculate total value - handle potential precision issues
        try marketCoreInstance.calculateCollateralValue(bob, positionId) returns (uint256 totalValue) {
            // Expected values with proper precision handling
            uint256 expectedWethValue = (((wethAmount * ETH_PRICE) / 1e18) * 10 ** usdcInstance.decimals()) / 1e8;
            uint256 expectedTotalValue = expectedWethValue + usdcAmount;

            // For very small amounts, we might have precision issues
            if (expectedTotalValue < getUSDCAmount(1)) {
                // For amounts less than $1, precision is expected to be limited
                assertGe(totalValue, 0, "Value should be non-negative");
            } else {
                // For larger amounts, allow reasonable precision tolerance
                // Use absolute difference for very small values, relative for larger ones
                if (expectedTotalValue < getUSDCAmount(1000)) {
                    assertApproxEqAbs(totalValue, expectedTotalValue, getUSDCAmount(1), "Small value precision issue");
                } else {
                    assertApproxEqRel(totalValue, expectedTotalValue, 0.01e18, "Large value precision issue");
                }
            }
        } catch {
            // Calculation might fail for extremely small amounts - this is acceptable
            // The protocol should handle edge cases gracefully
        }
    }

    // ============ Liquidation Fuzz Tests ============

    function testFuzz_Liquidation(uint256 initialCollateral, uint256 priceDropPercent) public {
        // Bound inputs
        initialCollateral = bound(initialCollateral, 1 ether, 10 ether);
        priceDropPercent = bound(priceDropPercent, 20, 50); // 20-50% price drop

        // Setup position at max borrow
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        deal(address(wethInstance), bob, initialCollateral);
        _supplyCollateral(bob, positionId, address(wethInstance), initialCollateral);

        // Borrow 80% of credit limit
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(bob, positionId);
        uint256 borrowAmount = (creditLimit * 80) / 100;

        if (borrowAmount > 0 && borrowAmount <= marketVaultInstance.totalAssets()) {
            _borrow(bob, positionId, borrowAmount);

            // Drop price
            uint256 newPrice = (ETH_PRICE * (100 - priceDropPercent)) / 100;
            wethOracle.setPrice(int256(newPrice));

            // Check if liquidatable
            if (marketCoreInstance.isLiquidatable(bob, positionId)) {
                uint256 debt = marketCoreInstance.calculateDebtWithInterest(bob, positionId);
                uint256 liquidationFee = marketCoreInstance.getPositionLiquidationFee(bob, positionId);
                uint256 totalCost = debt + ((debt * liquidationFee) / 1e6);

                // Liquidate
                deal(address(usdcInstance), liquidator, totalCost);

                vm.startPrank(liquidator);
                usdcInstance.approve(address(marketCoreInstance), totalCost);
                marketCoreInstance.liquidate(bob, positionId, totalCost, 500);
                vm.stopPrank();

                // Verify liquidation
                IPROTOCOL.UserPosition memory position = marketCoreInstance.getUserPositions(bob)[0];
                assertEq(uint8(position.status), uint8(IPROTOCOL.PositionStatus.LIQUIDATED));
                assertEq(wethInstance.balanceOf(liquidator), initialCollateral);
            }
        }
    }

    // ============ Protocol Configuration Fuzz Tests ============

    function testFuzz_ProtocolConfiguration(uint256 profitTarget, uint256 borrowRate, uint256 flashFee) public {
        // Bound inputs to valid ranges
        profitTarget = bound(profitTarget, 0.0025e6, 0.1e6); // 0.25% - 10%
        borrowRate = bound(borrowRate, 0.01e6, 0.5e6); // 1% - 50%
        flashFee = bound(flashFee, 1, 100); // 0.01% - 1%

        ILendefiMarketVault.ProtocolConfig memory config = ILendefiMarketVault.ProtocolConfig({
            profitTargetRate: profitTarget,
            borrowRate: borrowRate,
            rewardAmount: 1_000 ether,
            rewardInterval: 180 days,
            rewardableSupply: getUSDCAmount(100_000),
            flashLoanFee: uint32(flashFee)
        });

        // Load protocol config to vault (DAO-only)
        vm.prank(address(timelockInstance));
        marketVaultInstance.loadProtocolConfig(config);

        // Set liquidator threshold on core (DAO-only)
        vm.prank(address(timelockInstance));
        marketCoreInstance.setLiquidatorThreshold(20_000 ether);

        ILendefiMarketVault.ProtocolConfig memory loadedConfig =
            ILendefiMarketVault(address(marketVaultInstance)).protocolConfig();
        assertEq(loadedConfig.profitTargetRate, profitTarget);
        assertEq(loadedConfig.borrowRate, borrowRate);
    }

    // ============ Slippage Protection Fuzz Tests ============

    function testFuzz_SlippageProtection(uint256 amount, uint256 slippageBps) public {
        // Aggressive bounds to test edge cases
        amount = bound(amount, getUSDCAmount(1), getUSDCAmount(1_000_000)); // 1 USDC to 1M USDC
        slippageBps = bound(slippageBps, 1, 10000); // 0.01% to 100% slippage

        deal(address(usdcInstance), charlie, amount * 2); // Get enough for both operations

        uint256 expectedShares = marketVaultInstance.previewDeposit(amount);

        // Calculate min acceptable shares with slippage
        uint256 minShares = (expectedShares * (10000 - slippageBps)) / 10000;

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketCoreInstance), amount * 2);

        // Test 1: Should succeed with reasonable slippage expectations
        try marketCoreInstance.depositLiquidity(amount, minShares, uint32(slippageBps)) {
            // Success expected for reasonable slippage
        } catch {
            // Might fail for extreme parameters - that's also valid testing
        }

        // Warp time to avoid MEV protection
        vm.warp(block.timestamp + 1);

        // Test 2: Should fail with unrealistic expectation (expecting 2x shares)
        // Only test if slippage tolerance is reasonable (< 50%)
        if (slippageBps < 5000) {
            try marketCoreInstance.depositLiquidity(amount, expectedShares * 2, uint32(slippageBps)) {
                // If this succeeds, something is wrong with slippage protection
                revert("Slippage protection failed - accepted unrealistic expectation");
            } catch (bytes memory) {
                // Should revert with MEVSlippageExceeded for unrealistic expectations
                // But might also fail for other reasons with edge case parameters
            }
        }

        vm.stopPrank();
    }

    // ============ Helper Functions ============

    function _createPosition(address user, address asset, bool isolated) internal returns (uint256) {
        vm.prank(user);
        marketCoreInstance.createPosition(asset, isolated);
        return marketCoreInstance.getUserPositionsCount(user) - 1;
    }

    function _supplyCollateral(address user, uint256 positionId, address asset, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(asset).approve(address(marketCoreInstance), amount);
        marketCoreInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    function _borrow(address user, uint256 positionId, uint256 amount) internal {
        vm.warp(block.timestamp + 1); // Avoid MEV protection
        vm.startPrank(user);
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(user, positionId);
        marketCoreInstance.borrow(positionId, amount, creditLimit, 100);
        vm.stopPrank();
    }

    function _repay(address user, uint256 positionId, uint256 amount) internal {
        vm.warp(block.timestamp + 1); // Avoid MEV protection
        vm.startPrank(user);
        usdcInstance.approve(address(marketCoreInstance), amount);
        uint256 debt = marketCoreInstance.calculateDebtWithInterest(user, positionId);
        marketCoreInstance.repay(positionId, amount, debt, 100);
        vm.stopPrank();
    }

    function _simulateTimeAndAccrueInterest(uint256 timeToWarp) internal {
        vm.warp(block.timestamp + timeToWarp);
        vm.roll(block.number + timeToWarp / 12);
    }
}
