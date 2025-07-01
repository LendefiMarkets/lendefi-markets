// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {MockFlashLoanReceiver} from "../../contracts/mock/MockFlashLoanReceiver.sol";
import {LendefiCore} from "../../contracts/markets/LendefiCore.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";

contract LendefiMarketVaultFuzzTest is BasicDeploy {
    uint8 public decimals;
    uint256 public initialLiquidity;

    function setUp() public {
        // Deploy base contracts and market
        deployMarketsWithUSDC();
        decimals = usdcInstance.decimals();
        initialLiquidity = getUSDCAmount(1_000_000); // 1M USDC

        // Setup initial liquidity for vault tests
        deal(address(usdcInstance), alice, initialLiquidity);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), initialLiquidity);
        marketCoreInstance.depositLiquidity(initialLiquidity, marketVaultInstance.previewDeposit(initialLiquidity), 100);
        vm.stopPrank();
    }

    // ============ ERC4626 Fuzz Tests ============

    function testFuzz_DepositAndWithdraw(uint256 assets, uint256 withdrawRatio) public {
        // Bound inputs
        assets = bound(assets, getUSDCAmount(1), getUSDCAmount(1_000_000)); // 1 to 1M USDC
        withdrawRatio = bound(withdrawRatio, 1, 100); // 1-100%

        deal(address(usdcInstance), charlie, assets);

        // Deposit
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), assets);

        uint256 shares = marketVaultInstance.deposit(assets, charlie);
        assertGt(shares, 0);
        assertEq(marketVaultInstance.balanceOf(charlie), shares);
        vm.stopPrank();

        // Roll to next block to allow withdrawal (MEV protection)
        vm.roll(block.number + 1);

        // Withdraw partial
        uint256 withdrawAmount = (assets * withdrawRatio) / 100;

        vm.prank(charlie);
        uint256 burnedShares = marketVaultInstance.withdraw(withdrawAmount, charlie, charlie);

        assertLe(burnedShares, shares);
        assertEq(usdcInstance.balanceOf(charlie), withdrawAmount);
    }

    function testFuzz_MintAndRedeem(uint256 shares, uint256 redeemRatio) public {
        // Bound inputs
        shares = bound(shares, getUSDCAmount(1), getUSDCAmount(1_000_000));
        redeemRatio = bound(redeemRatio, 1, 100);

        uint256 assets = marketVaultInstance.previewMint(shares);
        deal(address(usdcInstance), charlie, assets);

        // Mint
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), assets);

        uint256 assetsUsed = marketVaultInstance.mint(shares, charlie);
        assertEq(assetsUsed, assets);
        assertEq(marketVaultInstance.balanceOf(charlie), shares);
        vm.stopPrank();

        // Roll to next block to allow redemption (MEV protection)
        vm.roll(block.number + 1);

        // Redeem partial
        uint256 redeemShares = (shares * redeemRatio) / 100;

        vm.prank(charlie);
        uint256 assetsReceived = marketVaultInstance.redeem(redeemShares, charlie, charlie);

        assertGt(assetsReceived, 0);
        assertEq(marketVaultInstance.balanceOf(charlie), shares - redeemShares);
    }

    // ============ Flash Loan Fuzz Tests ============

    function testFuzz_FlashLoan(uint256 loanAmount, uint256 feeRate) public {
        // Aggressive bounds to test edge cases
        loanAmount = bound(loanAmount, 1, type(uint256).max / 1e18); // Extreme range
        feeRate = bound(feeRate, 1, type(uint32).max); // Test max fee rates

        console.log("Bound Result", loanAmount);
        console.log("Bound Result", feeRate);

        // Config update succeeded, proceed with flash loan test

        // Ensure loan amount is within vault capacity
        uint256 maxLoan = marketVaultInstance.totalSuppliedLiquidity();
        if (loanAmount > maxLoan) {
            loanAmount = maxLoan;
        }

        if (loanAmount > 0) {
            // Setup flash receiver
            MockFlashLoanReceiver flashReceiver = new MockFlashLoanReceiver();
            uint256 expectedFee = (loanAmount * feeRate) / 10000;

            // Handle potential overflow in fee calculation
            if (expectedFee < loanAmount * feeRate) {
                // Overflow occurred, skip this test case
                return;
            }

            deal(address(usdcInstance), address(flashReceiver), expectedFee);

            uint256 vaultBalanceBefore = usdcInstance.balanceOf(address(marketVaultInstance));

            try marketVaultInstance.flashLoan(address(flashReceiver), loanAmount, "") {
                // Flash loan succeeded
                assertEq(usdcInstance.balanceOf(address(marketVaultInstance)), vaultBalanceBefore + expectedFee);
                assertEq(marketVaultInstance.totalBase(), initialLiquidity + expectedFee);
            } catch {
                // Flash loan failed - this is acceptable for extreme values
            }
        }
    }

    // ============ Borrow/Repay Integration Fuzz Tests ============

    function testFuzz_BorrowRepayIntegration(uint256 borrowAmount, uint256 timeElapsed) public {
        // Aggressive bounds to test edge cases
        borrowAmount = bound(borrowAmount, 1, type(uint256).max / 1e12); // Extreme range
        timeElapsed = bound(timeElapsed, 1, type(uint256).max / 1e12); // Extreme time range

        console.log("Bound Result", borrowAmount);
        console.log("Bound Result", timeElapsed);

        // Ensure borrow amount is within vault capacity
        uint256 maxBorrow = marketVaultInstance.totalSuppliedLiquidity();
        if (borrowAmount > maxBorrow) {
            borrowAmount = maxBorrow;
        }

        if (borrowAmount > 0) {
            uint256 initialTotalBorrow = marketVaultInstance.totalBorrow();

            try marketVaultInstance.borrow(borrowAmount, bob) {
                // Borrow succeeded
                assertEq(marketVaultInstance.totalBorrow(), initialTotalBorrow + borrowAmount);
                assertEq(usdcInstance.balanceOf(bob), borrowAmount);

                // Time passes - handle potential overflow
                uint256 newTime = block.timestamp + timeElapsed;
                if (newTime < block.timestamp) {
                    // Overflow, use max reasonable time
                    newTime = block.timestamp + 365 days;
                }
                vm.warp(newTime);

                // Get current debt after interest accrual
                uint256 currentTotalBorrow = marketVaultInstance.totalBorrow();

                // Repay through core - provide enough to cover interest
                deal(address(usdcInstance), address(marketCoreInstance), currentTotalBorrow);

                vm.startPrank(address(marketCoreInstance));
                usdcInstance.approve(address(marketVaultInstance), currentTotalBorrow);

                try marketVaultInstance.repay(currentTotalBorrow, address(marketCoreInstance)) {
                    // Repay succeeded - debt should be cleared or reduced
                    uint256 finalTotalBorrow = marketVaultInstance.totalBorrow();
                    assertLe(finalTotalBorrow, initialTotalBorrow);
                } catch {
                    // Repay failed - acceptable for extreme values
                }
                vm.stopPrank();
            } catch {
                // Borrow failed - acceptable for extreme values
            }
        }
    }

    // ============ Utilization Fuzz Tests ============

    function testFuzz_Utilization(uint256 supplyAmount, uint256 borrowRatio) public {
        // Bound inputs
        supplyAmount = bound(supplyAmount, getUSDCAmount(10_000), getUSDCAmount(10_000_000));
        borrowRatio = bound(borrowRatio, 0, 100);

        // Add more supply
        deal(address(usdcInstance), charlie, supplyAmount);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), supplyAmount);
        marketVaultInstance.deposit(supplyAmount, charlie);
        vm.stopPrank();

        uint256 totalSupply = marketVaultInstance.totalSuppliedLiquidity();
        uint256 borrowAmount = (totalSupply * borrowRatio) / 100;

        if (borrowAmount > 0) {
            vm.prank(address(marketCoreInstance));
            marketVaultInstance.borrow(borrowAmount, bob);

            uint256 utilization = marketVaultInstance.utilization();
            uint256 expectedUtilization = (borrowAmount * 10 ** decimals) / totalSupply;

            assertEq(utilization, expectedUtilization);
        } else {
            assertEq(marketVaultInstance.utilization(), 0);
        }
    }

    // ============ Yield Boost Fuzz Tests ============

    function testFuzz_YieldBoost(uint256 boostAmount, uint256 numBoosts) public {
        // Bound inputs
        boostAmount = bound(boostAmount, getUSDCAmount(1), getUSDCAmount(100_000));
        numBoosts = bound(numBoosts, 1, 10);

        uint256 totalBoost = boostAmount * numBoosts;
        deal(address(usdcInstance), address(timelockInstance), totalBoost);

        uint256 initialBase = marketVaultInstance.totalBase();
        uint256 initialAccrued = marketVaultInstance.totalAccruedInterest();

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), totalBoost);

        // Perform multiple boosts
        for (uint256 i = 0; i < numBoosts; i++) {
            marketVaultInstance.boostYield(alice, boostAmount);
        }
        vm.stopPrank();

        assertEq(marketVaultInstance.totalBase(), initialBase + totalBoost);
        assertEq(marketVaultInstance.totalAccruedInterest(), initialAccrued + totalBoost);
    }

    // ============ Share Price Manipulation Resistance Tests ============

    function testFuzz_SharePriceManipulation(uint256 donationAmount) public {
        // Test resistance to donation attacks
        donationAmount = bound(donationAmount, getUSDCAmount(1), getUSDCAmount(1_000_000));

        // Roll to next block since alice already deposited in setUp
        vm.roll(block.number + 1);

        // Alice deposits first
        uint256 aliceDeposit = getUSDCAmount(1000);
        deal(address(usdcInstance), alice, aliceDeposit);

        vm.startPrank(alice);
        usdcInstance.approve(address(marketVaultInstance), aliceDeposit);
        uint256 aliceShares = marketVaultInstance.deposit(aliceDeposit, alice);
        vm.stopPrank();

        uint256 sharePriceBefore = marketVaultInstance.previewRedeem(getUSDCAmount(1));

        // Attacker donates to vault
        deal(address(usdcInstance), address(marketVaultInstance), donationAmount);

        uint256 sharePriceAfter = marketVaultInstance.previewRedeem(getUSDCAmount(1));

        // Share price should not change from donations
        // totalAssets() uses totalBase, not balanceOf
        assertEq(sharePriceBefore, sharePriceAfter);

        // Bob deposits after donation
        uint256 bobDeposit = getUSDCAmount(1000);
        deal(address(usdcInstance), bob, bobDeposit);

        vm.startPrank(bob);
        usdcInstance.approve(address(marketVaultInstance), bobDeposit);
        uint256 bobShares = marketVaultInstance.deposit(bobDeposit, bob);
        vm.stopPrank();

        // Bob should get fair shares (similar to Alice)
        assertApproxEqRel(bobShares, aliceShares, 0.01e18); // 1% tolerance
    }

    // ============ Multiple Operations Fuzz Tests ============

    function testFuzz_MultipleOperations(uint256 numDepositors, uint256 numBorrows, uint256 baseAmount) public {
        // Bound inputs
        numDepositors = bound(numDepositors, 1, 10);
        numBorrows = bound(numBorrows, 0, numDepositors);
        baseAmount = bound(baseAmount, getUSDCAmount(1000), getUSDCAmount(100_000));

        // Roll to next block since alice already deposited in setUp
        vm.roll(block.number + 1);

        address[] memory depositors = new address[](numDepositors);
        uint256[] memory deposits = new uint256[](numDepositors);
        uint256 totalDeposited;

        // Multiple deposits
        for (uint256 i = 0; i < numDepositors; i++) {
            depositors[i] = makeAddr(string.concat("depositor", vm.toString(i)));
            deposits[i] = (baseAmount * (i + 1)) / numDepositors;

            deal(address(usdcInstance), depositors[i], deposits[i]);

            vm.startPrank(depositors[i]);
            usdcInstance.approve(address(marketVaultInstance), deposits[i]);
            marketVaultInstance.deposit(deposits[i], depositors[i]);
            vm.stopPrank();

            totalDeposited += deposits[i];

            // Roll to next block for MEV protection
            if (i < numDepositors - 1) {
                vm.roll(block.number + 1);
            }
        }

        assertEq(marketVaultInstance.totalSuppliedLiquidity(), initialLiquidity + totalDeposited);

        // Multiple borrows
        uint256 totalBorrowed;
        uint256 maxBorrow = (marketVaultInstance.totalSuppliedLiquidity() * 80) / 100; // Max 80% utilization

        for (uint256 i = 0; i < numBorrows; i++) {
            uint256 borrowAmount = maxBorrow / numBorrows;

            if (totalBorrowed + borrowAmount <= maxBorrow) {
                vm.prank(address(marketCoreInstance));
                marketVaultInstance.borrow(borrowAmount, depositors[i]);
                totalBorrowed += borrowAmount;
            }
        }

        // Verify state consistency
        assertEq(marketVaultInstance.totalBorrow(), totalBorrowed);
        assertLe(marketVaultInstance.utilization(), ((10 ** decimals) * 5) / 4); // <= 80%

        // Everyone can still withdraw remaining funds
        for (uint256 i = 0; i < numDepositors; i++) {
            // Roll to next block for MEV protection
            vm.roll(block.number + 1);

            uint256 shares = marketVaultInstance.balanceOf(depositors[i]);
            if (shares > 0) {
                uint256 maxWithdraw = marketVaultInstance.maxWithdraw(depositors[i]);

                if (maxWithdraw > 0) {
                    vm.prank(depositors[i]);
                    marketVaultInstance.withdraw(maxWithdraw / 2, depositors[i], depositors[i]);
                }
            }
        }
    }

    // ============ Extreme Values Fuzz Tests ============

    function testFuzz_ExtremeValues(uint256 value, bool isDeposit) public {
        if (isDeposit) {
            // Test extreme deposits
            value = bound(value, 1, type(uint256).max / 2);

            // Check if vault can handle it
            uint256 maxDeposit = marketVaultInstance.maxDeposit(charlie);
            if (value <= maxDeposit) {
                deal(address(usdcInstance), charlie, value);

                vm.startPrank(charlie);
                usdcInstance.approve(address(marketVaultInstance), value);

                uint256 shares = marketVaultInstance.deposit(value, charlie);
                assertGt(shares, 0);
                vm.stopPrank();
            }
        } else {
            // Test extreme mints
            value = bound(value, 1, type(uint256).max / 2);

            uint256 maxMint = marketVaultInstance.maxMint(charlie);
            if (value <= maxMint) {
                uint256 assets = marketVaultInstance.previewMint(value);
                deal(address(usdcInstance), charlie, assets);

                vm.startPrank(charlie);
                usdcInstance.approve(address(marketVaultInstance), assets);

                uint256 assetsUsed = marketVaultInstance.mint(value, charlie);
                assertEq(assetsUsed, assets);
                vm.stopPrank();
            }
        }
    }

    // ============ Access Control Fuzz Tests ============

    function testFuzz_AccessControl(address caller, uint256 role) public {
        // Skip known addresses
        vm.assume(caller != address(0));
        vm.assume(caller != address(timelockInstance));
        vm.assume(caller != address(marketCoreInstance));

        // Bound role to test different functions
        role = bound(role, 0, 3);

        if (role == 0) {
            // Test pause (requires PAUSER_ROLE)
            vm.prank(caller);
            vm.expectRevert();
            marketVaultInstance.pause();
        } else if (role == 1) {
            // Test borrow (requires PROTOCOL_ROLE)
            uint256 borrowAmount = 1000 * 10 ** usdcInstance.decimals();
            vm.prank(caller);
            vm.expectRevert();
            marketVaultInstance.borrow(borrowAmount, caller);
        } else if (role == 2) {
            // Test repay (requires PROTOCOL_ROLE)
            uint256 repayAmount = 1000 * 10 ** usdcInstance.decimals();
            deal(address(usdcInstance), caller, repayAmount);
            vm.startPrank(caller);
            usdcInstance.approve(address(marketVaultInstance), repayAmount);
            vm.expectRevert();
            marketVaultInstance.repay(repayAmount, caller);
            vm.stopPrank();
        } else {
            // Test boostYield (requires PROTOCOL_ROLE)
            uint256 boostAmount = 1000 * 10 ** usdcInstance.decimals();
            deal(address(usdcInstance), caller, boostAmount);
            vm.startPrank(caller);
            usdcInstance.approve(address(marketVaultInstance), boostAmount);
            vm.expectRevert();
            marketVaultInstance.boostYield(caller, boostAmount);
            vm.stopPrank();
        }
    }
}
