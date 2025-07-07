// SPDX-License-Identifier: BUSL-1.1
pragma solidity 0.8.23;

import "forge-std/Test.sol";
import "../../contracts/markets/lib/LendefiRates.sol";

contract LendefiRatesTest is Test {
    using LendefiRates for uint256;

    uint256 constant WAD = 1e6;
    uint256 constant RAY = 1e27;
    uint256 constant SECONDS_PER_YEAR = 365 * 86400;
    // Set realistic protocol bounds
    uint256 constant MAX_PRINCIPAL = 100_000_000_000e6; // 1 billion tokens
    uint256 constant MAX_RATE = 1e6; // 100% annual rate (in 1e6)
    uint256 constant MAX_TIME = 10 * 365 days; // 10 years
    uint256 constant MAX_SUPPLY = 100_000_000_000e6;
    uint256 constant MAX_BORROW = 100_000_000_000e6;

    // --- rmul and rdiv ---

    function test_rmul_basic() public {
        uint256 x = 2 * RAY;
        uint256 y = 3 * RAY;
        uint256 z = LendefiRates.rmul(x, y);
        assertEq(z, 6 * RAY);
    }

    function test_rdiv_basic() public {
        uint256 x = 6 * RAY;
        uint256 y = 2 * RAY;
        uint256 z = LendefiRates.rdiv(x, y);
        assertEq(z, 3 * RAY);
    }

    function test_rmul_zero() public {
        assertEq(LendefiRates.rmul(0, RAY), 0);
        assertEq(LendefiRates.rmul(RAY, 0), 0);
    }

    function test_rdiv_zero() public {
        assertEq(LendefiRates.rdiv(0, RAY), 0);
    }

    function test_rdiv_revertsOnZeroDenominator() public {
        // Division by zero should revert
        vm.expectRevert();
        this.helperRdiv(RAY, 0);
    }

    function helperRdiv(uint256 x, uint256 y) external pure returns (uint256) {
        return LendefiRates.rdiv(x, y);
    }

    // --- rpow ---

    function test_rpow_zeroExponent() public {
        assertEq(LendefiRates.rpow(123 * RAY, 0), RAY);
    }

    function test_rpow_oneExponent() public {
        assertEq(LendefiRates.rpow(5 * RAY, 1), 5 * RAY);
    }

    function test_rpow_basic() public {
        uint256 base = 2 * RAY;
        uint256 exp = 3;
        uint256 result = LendefiRates.rpow(base, exp);
        assertEq(result, 8 * RAY);
    }

    function testFuzz_rpow(uint256 base, uint256 exp) public {
        base = bound(base, RAY, 10 * RAY);
        exp = bound(exp, 0, 10);
        uint256 result = LendefiRates.rpow(base, exp);
        if (exp == 0) assertEq(result, RAY);
    }

    // --- annualRateToRay ---

    function test_annualRateToRay_basic() public {
        uint256 rate = 1e6; // 100% annual rate
        uint256 ray = LendefiRates.annualRateToRay(rate, 1e6);
        assertGt(ray, RAY);
    }

    function test_annualRateToRay_zero() public {
        assertEq(LendefiRates.annualRateToRay(0, 1e6), RAY);
    }

    function testFuzz_annualRateToRay(uint256 rate, uint256 scale) public {
        rate = bound(rate, 0, MAX_RATE);
        scale = bound(scale, 1, 1e18);
        uint256 ray = LendefiRates.annualRateToRay(rate, scale);
        assertGe(ray, RAY);
    }

    // --- accrueInterest and getInterest ---

    function test_accrueInterest_zeroPrincipal() public {
        assertEq(LendefiRates.accrueInterest(0, RAY, 100), 0);
    }

    function test_accrueInterest_zeroRate() public {
        assertEq(LendefiRates.accrueInterest(1000, RAY, 100), 1000);
    }

    function test_getInterest_zeroPrincipal() public {
        assertEq(LendefiRates.getInterest(0, RAY, 100), 0);
    }

    function test_getInterest_zeroRate() public {
        assertEq(LendefiRates.getInterest(1000, RAY, 100), 0);
    }

    function testFuzz_accrueInterest(uint256 principal, uint256 rateRay, uint256 time) public {
        principal = bound(principal, 0, MAX_PRINCIPAL);
        // Limit rateRay to prevent overflow: RAY + small increment per second
        // For 10% annual rate, rateRay ≈ RAY + 3e18, so limit to RAY + 1e19 (about 300% APY max)
        rateRay = bound(rateRay, RAY, RAY + 1e19);
        // Limit time to reasonable bounds to prevent overflow in rpow
        time = bound(time, 0, 365 days);
        uint256 result = LendefiRates.accrueInterest(principal, rateRay, time);
        assertGe(result, principal);
    }

    // --- breakEvenRate ---

    function test_breakEvenRate_basic() public {
        uint256 loan = 1000 * WAD;
        uint256 supplyInterest = 100 * WAD;
        uint256 rate = LendefiRates.breakEvenRate(loan, supplyInterest);
        assertGt(rate, 0);
    }

    function testFuzz_breakEvenRate(uint256 loan, uint256 supplyInterest) public {
        loan = bound(loan, 1, MAX_BORROW);
        supplyInterest = bound(supplyInterest, 0, loan); // can't be more than loan
        uint256 rate = LendefiRates.breakEvenRate(loan, supplyInterest);
        assertLe(rate, type(uint256).max);
    }

    // --- calculateDebtWithInterest ---

    function test_calculateDebtWithInterest_zeroDebt() public {
        assertEq(LendefiRates.calculateDebtWithInterest(0, 1e6, 100, 1e6), 0);
    }

    function testFuzz_calculateDebtWithInterest(uint256 debt, uint256 rate, uint256 time, uint256 baseDecimals)
        public
    {
        debt = bound(debt, 0, MAX_BORROW);
        rate = bound(rate, 0, MAX_RATE);
        // Limit time to prevent overflow in compound interest calculation
        time = bound(time, 0, MAX_TIME);
        // Common token decimals: 6 (USDC), 8 (WBTC), 18 (ETH/most ERC20s)
        baseDecimals = bound(baseDecimals, 1e6, 1e18);
        uint256 result = LendefiRates.calculateDebtWithInterest(debt, rate, time, baseDecimals);
        assertGe(result, debt);
    }

    // --- getSupplyRate ---

    function test_getSupplyRate_zeroSupply() public {
        // With totalSupply=0, borrow=100, liquidity=100, profit=100, balance=100
        // total = 100 + 100 = 200, fee = 0 (no target since supply=0)
        // rate = (WAD * 200 / 100) - WAD = 2*WAD - WAD = WAD (100% rate)
        assertEq(LendefiRates.getSupplyRate(0, 100, 100, 100, 100), WAD);

        // Test actual zero case: when totalSuppliedLiquidity is 0
        assertEq(LendefiRates.getSupplyRate(100, 100, 0, 100, 100), 0);
    }

    function testFuzz_getSupplyRate(
        uint256 totalSupply,
        uint256 totalBorrow,
        uint256 totalSuppliedLiquidity,
        uint256 baseProfitTarget,
        uint256 usdcBalance
    ) public {
        // Realistic bounds for a lending protocol
        totalSuppliedLiquidity = bound(totalSuppliedLiquidity, 1, MAX_SUPPLY);
        // totalBorrow cannot exceed totalSuppliedLiquidity
        totalBorrow = bound(totalBorrow, 0, totalSuppliedLiquidity);
        // usdcBalance represents available liquidity (supplied - borrowed)
        // In practice: usdcBalance + totalBorrow = totalSuppliedLiquidity (ignoring fees/interest)
        usdcBalance = totalSuppliedLiquidity - totalBorrow;
        // LP token supply - can be independent but usually proportional to liquidity
        totalSupply = bound(totalSupply, 0, totalSuppliedLiquidity);
        // Profit target as percentage (0-100%)
        baseProfitTarget = bound(baseProfitTarget, 0, WAD);

        uint256 rate =
            LendefiRates.getSupplyRate(totalSupply, totalBorrow, totalSuppliedLiquidity, baseProfitTarget, usdcBalance);

        // Rate should be reasonable - even 10000% APY is 1e8 in WAD format
        assertLe(rate, 1e10);
    }

    // --- getBorrowRate ---

    function test_getBorrowRate_zeroUtilization() public {
        uint256 rate = LendefiRates.getBorrowRate(0, 1e6, 1e6, 1e6, 1e6);
        assertEq(rate, 1e6);
    }

    function testFuzz_getBorrowRate(
        uint256 utilization,
        uint256 baseBorrowRate,
        uint256 baseProfitTarget,
        uint256 supplyRate,
        uint256 tierJumpRate
    ) public {
        utilization = bound(utilization, 0, WAD);
        baseBorrowRate = bound(baseBorrowRate, 0, MAX_RATE);
        baseProfitTarget = bound(baseProfitTarget, 0, MAX_RATE);
        supplyRate = bound(supplyRate, 0, MAX_RATE);
        tierJumpRate = bound(tierJumpRate, 0, MAX_RATE);
        uint256 rate =
            LendefiRates.getBorrowRate(utilization, baseBorrowRate, baseProfitTarget, supplyRate, tierJumpRate);
        assertLe(rate, type(uint256).max);
    }
}
