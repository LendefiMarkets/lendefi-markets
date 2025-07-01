// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {MockPriceOracle} from "../../../contracts/mock/MockPriceOracle.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract UpdateTierConfigTest is BasicDeploy {
    // Add this to your contract's state variables
    MockPriceOracle internal wethOracleInstance;
    MockPriceOracle internal usdcOracleInstance;

    event TierParametersUpdated(IASSETS.CollateralTier indexed tier, uint256 jumpRate, uint256 liquidationFee);

    // Default parameter values
    uint256 constant DEFAULT_BORROW_RATE = 0.08e6; // 8%
    uint256 constant DEFAULT_LIQUIDATION_FEE = 0.08e6; // 8% - Renamed from DEFAULT_LIQUIDATION_BONUS

    // New parameter values
    uint256 constant NEW_BORROW_RATE = 0.1e6; // 10%
    uint256 constant NEW_LIQUIDATION_FEE = 0.09e6; // 9% - Changed from 0.12e6 to be under max

    // Max allowed values
    uint256 constant MAX_BORROW_RATE = 0.25e6; // 25%
    uint256 constant MAX_LIQUIDATION_FEE = 0.1e6; // 10% - Changed from 0.2e6

    function setUp() public {
        // Create the mock oracles first
        wethOracleInstance = new MockPriceOracle();
        wethOracleInstance.setPrice(2500e8); // $2500 per ETH
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setRoundId(1);
        wethOracleInstance.setAnsweredInRound(1);

        usdcOracleInstance = new MockPriceOracle();
        usdcOracleInstance.setPrice(1e8); // $1 per USDC
        usdcOracleInstance.setTimestamp(block.timestamp);
        usdcOracleInstance.setRoundId(1);
        usdcOracleInstance.setAnsweredInRound(1);

        // Deploy all contracts including the Oracle module
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()

        // Deploy WETH (already have usdcInstance from deployCompleteWithOracle)
        wethInstance = new WETH9();

        // Register the oracles with the Oracle module
        vm.startPrank(address(timelockInstance));

        // Configure USDC asset (base asset for the market)
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 900, // 90%
                liquidationThreshold: 950, // 95%
                maxSupplyThreshold: 1_000_000e6,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure WETH asset (collateral asset)
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
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(wethOracleInstance), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Update oracle timestamps to be current after any time warping
        wethOracleInstance.setTimestamp(block.timestamp);
        usdcOracleInstance.setTimestamp(block.timestamp);

        vm.stopPrank();
    }

    // Test 1: Only manager can update tier parameters
    function testRevert_OnlyManagerCanupdateTierConfig() public {
        // Regular user should not be able to update tier parameters
        vm.startPrank(alice);

        // Using OpenZeppelin v5.0 AccessControl error format
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, alice, MANAGER_ROLE)
        );

        // Call should be to assetsInstance now
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
        vm.stopPrank();

        // Manager (timelock) should be able to update tier parameters
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
    }

    // Test 2: Correctly updates tier parameters
    function test_CorrectlyUpdatesTierParameters() public {
        // Update CROSS_A tier parameters
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);

        // Get updated parameters
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsInstance.getTierRates();

        // CROSS_A is at index 1 in the arrays based on GetTierRatesTest
        assertEq(jumpRates[1], NEW_BORROW_RATE, "CROSS_A borrow rate not updated correctly");
        assertEq(liquidationFees[1], NEW_LIQUIDATION_FEE, "CROSS_A liquidation fee not updated correctly");
    }

    // Test 3: Updates for each tier independently
    function test_UpdatesEachTierIndependently() public {
        // Update all four tiers with different values
        vm.startPrank(address(timelockInstance));

        // Update ISOLATED tier - index 3
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.ISOLATED,
            0.15e6, // 15%
            0.09e6 // 9%
        );

        // Update CROSS_A tier - index 1
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_A,
            0.08e6, // 8%
            0.08e6 // 8%
        );

        // Update CROSS_B tier - index 2
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.CROSS_B,
            0.12e6, // 12%
            0.1e6 // 10%
        );

        // Update STABLE tier - index 0
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            0.05e6, // 5%
            0.05e6 // 5%
        );
        vm.stopPrank();

        // Get updated parameters for all tiers
        (uint256[4] memory jumpRates, uint256[4] memory liquidationFees) = assetsInstance.getTierRates();

        // Verify each tier was updated correctly - note the correct indexing order:
        // [3] = ISOLATED, [2] = CROSS_B, [1] = CROSS_A, [0] = STABLE
        assertEq(jumpRates[3], 0.15e6, "ISOLATED borrow rate not correct");
        assertEq(jumpRates[2], 0.12e6, "CROSS_B borrow rate not correct");
        assertEq(jumpRates[1], 0.08e6, "CROSS_A borrow rate not correct");
        assertEq(jumpRates[0], 0.05e6, "STABLE borrow rate not correct");

        assertEq(liquidationFees[3], 0.09e6, "ISOLATED liquidation fee not correct");
        assertEq(liquidationFees[2], 0.1e6, "CROSS_B liquidation fee not correct");
        assertEq(liquidationFees[1], 0.08e6, "CROSS_A liquidation fee not correct");
        assertEq(liquidationFees[0], 0.05e6, "STABLE liquidation fee not correct");
    }

    // Test 4: Validates borrow rate maximum
    function testRevert_ValidatesBorrowRateMaximum() public {
        // Should revert if borrow rate is too high
        vm.prank(address(timelockInstance));

        // Use custom error format for rate validation errors
        vm.expectRevert(abi.encodeWithSelector(IASSETS.RateTooHigh.selector, MAX_BORROW_RATE + 1, MAX_BORROW_RATE));

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            MAX_BORROW_RATE + 1, // Just above max
            MAX_LIQUIDATION_FEE // Valid fee
        );

        // Should succeed with maximum value
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            MAX_BORROW_RATE, // Exactly max
            MAX_LIQUIDATION_FEE // Valid fee
        );
    }

    // Test 5: Validates liquidation fee maximum
    function testRevert_ValidatesLiquidationFeeMaximum() public {
        // Should revert if liquidation fee is too high
        vm.prank(address(timelockInstance));

        // Use custom error format for fee validation errors
        vm.expectRevert(
            abi.encodeWithSelector(IASSETS.FeeTooHigh.selector, MAX_LIQUIDATION_FEE + 1, MAX_LIQUIDATION_FEE)
        );

        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            MAX_BORROW_RATE, // Valid rate
            MAX_LIQUIDATION_FEE + 1 // Just above max
        );

        // Should succeed with maximum value
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(
            IASSETS.CollateralTier.STABLE,
            MAX_BORROW_RATE, // Valid rate
            MAX_LIQUIDATION_FEE // Exactly max
        );
    }

    // Test 6: Correct event emission
    function test_EventEmission() public {
        // Event is emitted from assetsInstance
        vm.expectEmit(true, true, true, true);
        emit TierParametersUpdated(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);

        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);
    }

    // Test 7: Effect on borrow rate calculation
    function test_EffectOnBorrowRateCalculation() public {
        // STEP 1: Setup initial protocol liquidity
        usdcInstance.mint(alice, 100_000e6);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), 100_000e6);
        uint256 expectedShares = marketVaultInstance.previewDeposit(100_000e6);
        marketCoreInstance.depositLiquidity(100_000e6, expectedShares, 100);
        vm.stopPrank();

        // STEP 2: Ensure oracle is up-to-date before any operations
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setPrice(2500e8);
        wethOracleInstance.setRoundId(1);
        wethOracleInstance.setAnsweredInRound(1);

        // STEP 3: Setup a position with collateral
        vm.deal(bob, 50 ether);
        vm.startPrank(bob);
        wethInstance.deposit{value: 50 ether}();
        wethInstance.approve(address(marketCoreInstance), 50 ether);

        // Create position and supply collateral
        marketCoreInstance.createPosition(address(wethInstance), false);
        marketCoreInstance.supplyCollateral(address(wethInstance), 20 ether, 0);
        vm.warp(block.timestamp + 10);
        vm.roll(block.number + 1);

        // STEP 4: Update oracle again before borrowing
        // This is critical - we need fresh oracle data for any price-dependent operation
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setPrice(2500e8);
        wethOracleInstance.setRoundId(2);
        wethOracleInstance.setAnsweredInRound(2);

        // STEP 5: Borrow to create protocol utilization
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(bob, 0);
        marketCoreInstance.borrow(0, 40_000e6, creditLimit, 100);
        vm.stopPrank();

        // STEP 6: Verify non-zero utilization
        uint256 utilization = marketVaultInstance.utilization();
        assertTrue(utilization > 0, "Test should have non-zero utilization");

        // STEP 7: Record initial borrow rate
        // First update oracle again
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setPrice(2500e8);
        wethOracleInstance.setRoundId(3);
        wethOracleInstance.setAnsweredInRound(3);

        uint256 initialBorrowRate = marketCoreInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        // STEP 8: Update tier config to double the borrow rate
        uint256 doubleBorrowRate = DEFAULT_BORROW_RATE * 2;
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, doubleBorrowRate, NEW_LIQUIDATION_FEE);

        // STEP 9: Update oracle again before final rate check
        wethOracleInstance.setTimestamp(block.timestamp);
        wethOracleInstance.setPrice(2500e8);
        wethOracleInstance.setRoundId(4);
        wethOracleInstance.setAnsweredInRound(4);

        // STEP 10: Get updated borrow rate and assert it increased
        uint256 newBorrowRate = marketCoreInstance.getBorrowRate(IASSETS.CollateralTier.CROSS_A);

        // Log the values to help debugging
        console2.log("Initial borrow rate:", initialBorrowRate);
        console2.log("New borrow rate:", newBorrowRate);
        console2.log("Current utilization:", utilization);

        // STEP 11: Verify the borrow rate increased due to the config change
        assertGt(newBorrowRate, initialBorrowRate, "New borrow rate should be higher after parameter update");
    }

    // Test 8: Updating parameters for a tier doesn't affect others
    function test_UpdateDoesNotAffectOtherTiers() public {
        // Get initial rates for all tiers
        (uint256[4] memory initialJumpRates, uint256[4] memory initialLiquidationFees) = assetsInstance.getTierRates();

        // Update only CROSS_A tier (index 1)
        vm.prank(address(timelockInstance));
        assetsInstance.updateTierConfig(IASSETS.CollateralTier.CROSS_A, NEW_BORROW_RATE, NEW_LIQUIDATION_FEE);

        // Get updated rates
        (uint256[4] memory updatedJumpRates, uint256[4] memory updatedLiquidationFees) = assetsInstance.getTierRates();

        // Check that only CROSS_A changed (index 1)
        assertEq(updatedJumpRates[3], initialJumpRates[3], "ISOLATED borrow rate should not change");
        assertEq(updatedJumpRates[2], initialJumpRates[2], "CROSS_B borrow rate should not change");
        assertEq(updatedJumpRates[0], initialJumpRates[0], "STABLE borrow rate should not change");

        assertEq(updatedLiquidationFees[3], initialLiquidationFees[3], "ISOLATED liquidation fee should not change");
        assertEq(updatedLiquidationFees[2], initialLiquidationFees[2], "CROSS_B liquidation fee should not change");
        assertEq(updatedLiquidationFees[0], initialLiquidationFees[0], "STABLE liquidation fee should not change");

        // But CROSS_A should change
        assertEq(updatedJumpRates[1], NEW_BORROW_RATE, "CROSS_A borrow rate should change");
        assertEq(updatedLiquidationFees[1], NEW_LIQUIDATION_FEE, "CROSS_A liquidation fee should change");
    }
}
