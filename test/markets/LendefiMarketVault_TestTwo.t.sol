// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {MockFlashLoanReceiver} from "../../contracts/mock/MockFlashLoanReceiver.sol";
import {ILendefiMarketVault} from "../../contracts/interfaces/ILendefiMarketVault.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {WETH9} from "../../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {IPROTOCOL} from "../../contracts/interfaces/IProtocol.sol";

contract LendefiMarketVault_TestTwo is BasicDeploy {
    MockFlashLoanReceiver flashReceiver;

    uint256 public initialLiquidity;
    uint8 public baseDecimals;

    event FlashLoan(address indexed user, address indexed receiver, address indexed asset, uint256 amount, uint256 fee);

    function setUp() public {
        // Deploy base contracts and market
        deployMarketsWithUSDC();
        baseDecimals = usdcInstance.decimals();
        initialLiquidity = 1_000_000 * 10 ** baseDecimals; // 1M USDC

        flashReceiver = new MockFlashLoanReceiver();

        // Give flash receiver some USDC for fees
        deal(address(usdcInstance), address(flashReceiver), 1_000_000 * 10 ** baseDecimals);

        // Setup initial liquidity for vault tests
        deal(address(usdcInstance), alice, 1_000_000 * 10 ** baseDecimals);
        vm.startPrank(alice);
        usdcInstance.approve(address(marketCoreInstance), 1_000_000 * 10 ** baseDecimals);
        marketCoreInstance.depositLiquidity(
            1_000_000 * 10 ** baseDecimals, marketVaultInstance.previewDeposit(1_000_000 * 10 ** baseDecimals), 100
        );
        vm.stopPrank();

        // Deploy and setup WETH for integration tests
        wethInstance = new WETH9();
        WETHPriceConsumerV3 wethOracle = new WETHPriceConsumerV3();
        WETHPriceConsumerV3 usdcOracle = new WETHPriceConsumerV3();
        wethOracle.setPrice(int256(2500e8)); // $2500 per ETH
        usdcOracle.setPrice(int256(1e8)); // $1 per USDC

        // Configure USDC in assets module (needed for credit limit calculations)
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(usdcInstance),
            IASSETS.Asset({
                active: 1,
                decimals: 6,
                borrowThreshold: 950, // 95% LTV for stablecoin
                liquidationThreshold: 980, // 98% liquidation for stablecoin
                maxSupplyThreshold: 100_000_000 * 10 ** baseDecimals, // 100M USDC
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.STABLE,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(usdcOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Configure WETH in assets module
        vm.prank(address(timelockInstance));
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

        // Give bob some WETH
        deal(address(wethInstance), bob, 10 ether);
    }

    // ============ Initialization Tests ============

    function test_Initialize() public {
        assertEq(marketVaultInstance.asset(), address(usdcInstance));
        assertEq(marketVaultInstance.name(), "Lendefi Yield Token");
        assertEq(marketVaultInstance.symbol(), "LYTUSDC");
        assertEq(marketVaultInstance.version(), 1);
        assertTrue(marketVaultInstance.hasRole(keccak256("PROTOCOL_ROLE"), address(marketCoreInstance)));
    }

    function test_Revert_InitializeTwice() public {
        vm.expectRevert();
        marketVaultInstance.initialize(
            address(timelockInstance),
            address(marketCoreInstance),
            address(usdcInstance),
            address(ecoInstance),
            address(assetsInstance),
            "Test",
            "TST"
        );
    }

    // ============ ERC4626 Functionality Tests ============

    function test_Deposit() public {
        uint256 amount = 10_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), charlie, amount);

        uint256 sharesBefore = marketVaultInstance.balanceOf(charlie);
        uint256 totalAssetsBefore = marketVaultInstance.totalAssets();
        uint256 previewShares = marketVaultInstance.previewDeposit(amount);

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), amount);

        uint256 shares = marketVaultInstance.deposit(amount, charlie);
        vm.stopPrank();

        assertEq(shares, previewShares);
        assertEq(marketVaultInstance.balanceOf(charlie), sharesBefore + shares);
        assertEq(marketVaultInstance.totalAssets(), totalAssetsBefore + amount);
        assertEq(marketVaultInstance.totalSuppliedLiquidity(), initialLiquidity + amount);
    }

    function test_Mint() public {
        uint256 shares = 10_000 * 10 ** baseDecimals; // Mint shares equal to assets initially
        uint256 assets = marketVaultInstance.previewMint(shares);
        deal(address(usdcInstance), charlie, assets);

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), assets);

        uint256 actualAssets = marketVaultInstance.mint(shares, charlie);
        vm.stopPrank();

        assertEq(actualAssets, assets);
        assertEq(marketVaultInstance.balanceOf(charlie), shares);
    }

    function test_Withdraw() public {
        // First deposit
        uint256 depositAmount = 10_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), charlie, depositAmount);

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), depositAmount);
        uint256 shares = marketVaultInstance.deposit(depositAmount, charlie);

        // Move to next block for MEV protection
        vm.roll(block.number + 1);

        // Then withdraw half
        uint256 withdrawAmount = depositAmount / 2;
        uint256 expectedShares = marketVaultInstance.previewWithdraw(withdrawAmount);

        uint256 burnedShares = marketVaultInstance.withdraw(withdrawAmount, charlie, charlie);
        vm.stopPrank();

        assertEq(burnedShares, expectedShares);
        assertEq(marketVaultInstance.balanceOf(charlie), shares - burnedShares);
        assertEq(usdcInstance.balanceOf(charlie), withdrawAmount);
    }

    function test_Redeem() public {
        // First deposit
        uint256 depositAmount = 10_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), charlie, depositAmount);

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), depositAmount);
        uint256 shares = marketVaultInstance.deposit(depositAmount, charlie);

        // Move to next block for MEV protection
        vm.roll(block.number + 1);

        // Redeem half shares
        uint256 redeemShares = shares / 2;
        uint256 expectedAssets = marketVaultInstance.previewRedeem(redeemShares);

        uint256 assets = marketVaultInstance.redeem(redeemShares, charlie, charlie);
        vm.stopPrank();

        assertEq(assets, expectedAssets);
        assertEq(marketVaultInstance.balanceOf(charlie), shares - redeemShares);
        assertEq(usdcInstance.balanceOf(charlie), assets);
    }

    function test_Revert_Withdraw_ZeroAmount() public {
        vm.prank(charlie);
        vm.expectRevert(LendefiMarketVault.ZeroAmount.selector);
        marketVaultInstance.withdraw(0, charlie, charlie);
    }

    function test_Revert_Redeem_ZeroShares() public {
        vm.prank(charlie);
        vm.expectRevert(LendefiMarketVault.ZeroAmount.selector);
        marketVaultInstance.redeem(0, charlie, charlie);
    }

    // ============ Protocol Integration Tests ============

    function test_Borrow() public {
        uint256 borrowAmount = 5_000 * 10 ** baseDecimals;
        uint256 vaultBalanceBefore = usdcInstance.balanceOf(address(marketVaultInstance));

        vm.prank(address(marketCoreInstance));
        marketVaultInstance.borrow(borrowAmount, bob);

        assertEq(usdcInstance.balanceOf(bob), borrowAmount);
        assertEq(usdcInstance.balanceOf(address(marketVaultInstance)), vaultBalanceBefore - borrowAmount);
        assertEq(marketVaultInstance.totalBorrow(), borrowAmount);
    }

    function test_Revert_Borrow_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("PROTOCOL_ROLE")
            )
        );
        marketVaultInstance.borrow(1000 * 10 ** baseDecimals, alice);
    }

    function test_Revert_Borrow_LowLiquidity() public {
        // Try to borrow more than available
        uint256 borrowAmount = initialLiquidity + 1;

        vm.prank(address(marketCoreInstance));
        vm.expectRevert(LendefiMarketVault.LowLiquidity.selector);
        marketVaultInstance.borrow(borrowAmount, bob);
    }

    function test_Repay() public {
        // First borrow
        uint256 borrowAmount = 5_000 * 10 ** baseDecimals;
        vm.prank(address(marketCoreInstance));
        marketVaultInstance.borrow(borrowAmount, bob);

        // Then repay
        // Give the protocol (marketCore) funds to repay on behalf of bob
        deal(address(usdcInstance), address(marketCoreInstance), borrowAmount);

        vm.startPrank(address(marketCoreInstance));
        usdcInstance.approve(address(marketVaultInstance), borrowAmount);
        marketVaultInstance.repay(borrowAmount, bob); // bob is the borrower
        vm.stopPrank();

        assertEq(marketVaultInstance.totalBorrow(), 0);
    }

    function test_BoostYield() public {
        uint256 boostAmount = 1_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), address(timelockInstance), boostAmount);

        uint256 totalBaseBefore = marketVaultInstance.totalBase();
        uint256 totalAccruedBefore = marketVaultInstance.totalAccruedInterest();

        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), boostAmount);

        vm.expectEmit(true, true, true, true);
        emit LendefiMarketVault.YieldBoosted(alice, boostAmount);

        marketVaultInstance.boostYield(alice, boostAmount);
        vm.stopPrank();

        assertEq(marketVaultInstance.totalBase(), totalBaseBefore + boostAmount);
        assertEq(marketVaultInstance.totalAccruedInterest(), totalAccruedBefore + boostAmount);
    }

    // ============ Flash Loan Tests ============

    function test_FlashLoan() public {
        uint256 loanAmount = 50_000 * 10 ** baseDecimals;
        bytes memory params = "";

        // Get expected fee from protocol config
        (,,,,, uint32 fee) = marketVaultInstance.protocolConfig();
        uint256 expectedFee = (loanAmount * fee) / 10000;

        uint256 vaultBalanceBefore = usdcInstance.balanceOf(address(marketVaultInstance));
        uint256 receiverBalanceBefore = usdcInstance.balanceOf(address(flashReceiver));

        vm.expectEmit(true, true, true, true);
        emit FlashLoan(address(this), address(flashReceiver), address(usdcInstance), loanAmount, expectedFee);

        marketVaultInstance.flashLoan(address(flashReceiver), loanAmount, params);

        // Vault should have gained the fee
        assertEq(usdcInstance.balanceOf(address(marketVaultInstance)), vaultBalanceBefore + expectedFee);
        // Flash receiver should have paid the fee
        assertEq(usdcInstance.balanceOf(address(flashReceiver)), receiverBalanceBefore - expectedFee);
        assertEq(marketVaultInstance.totalBase(), initialLiquidity + expectedFee);
    }

    function test_Revert_FlashLoan_FailedExecution() public {
        flashReceiver.setShouldFail(true);

        vm.expectRevert(LendefiMarketVault.FlashLoanFailed.selector);
        marketVaultInstance.flashLoan(address(flashReceiver), 1000 * 10 ** baseDecimals, "");
    }

    function test_Revert_FlashLoan_InsufficientRepayment() public {
        // Since protocolConfig might not be properly initialized during factory deployment,
        // we need to set it manually
        ILendefiMarketVault.ProtocolConfig memory config =
            ILendefiMarketVault(address(marketVaultInstance)).protocolConfig();

        vm.prank(address(timelockInstance));
        marketVaultInstance.loadProtocolConfig(config);

        flashReceiver.setShouldReturnLessFunds(true);

        vm.expectRevert(LendefiMarketVault.RepaymentFailed.selector);
        marketVaultInstance.flashLoan(address(flashReceiver), 1000 * 10 ** baseDecimals, "");
    }

    function test_Revert_FlashLoan_LowLiquidity() public {
        uint256 loanAmount = initialLiquidity + 1;

        vm.expectRevert(LendefiMarketVault.LowLiquidity.selector);
        marketVaultInstance.flashLoan(address(flashReceiver), loanAmount, "");
    }

    function test_Revert_FlashLoan_ZeroAmount() public {
        vm.expectRevert(LendefiMarketVault.ZeroAmount.selector);
        marketVaultInstance.flashLoan(address(flashReceiver), 0, "");
    }

    function test_Revert_FlashLoan_ZeroAddress() public {
        vm.expectRevert(LendefiMarketVault.ZeroAddress.selector);
        marketVaultInstance.flashLoan(address(0), 1000 * 10 ** baseDecimals, "");
    }

    // ============ Pause Tests ============

    function test_Pause() public {
        vm.prank(address(timelockInstance));
        marketVaultInstance.pause();

        assertTrue(marketVaultInstance.paused());

        // Try to deposit while paused
        deal(address(usdcInstance), charlie, 1000 * 10 ** baseDecimals);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), 1000 * 10 ** baseDecimals);

        vm.expectRevert(PausableUpgradeable.EnforcedPause.selector);
        marketVaultInstance.deposit(1000 * 10 ** baseDecimals, charlie);
        vm.stopPrank();
    }

    function test_Unpause() public {
        vm.startPrank(address(timelockInstance));
        marketVaultInstance.pause();
        assertTrue(marketVaultInstance.paused());

        marketVaultInstance.unpause();
        assertFalse(marketVaultInstance.paused());
        vm.stopPrank();

        // Should be able to deposit again
        deal(address(usdcInstance), charlie, 1000 * 10 ** baseDecimals);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), 1000 * 10 ** baseDecimals);
        marketVaultInstance.deposit(1000 * 10 ** baseDecimals, charlie);
        vm.stopPrank();
    }

    function test_Revert_Pause_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, keccak256("PAUSER_ROLE")
            )
        );
        marketVaultInstance.pause();
    }

    // ============ View Function Tests ============

    function test_Utilization() public {
        assertEq(marketVaultInstance.utilization(), 0);

        // Borrow 50%
        uint256 borrowAmount = initialLiquidity / 2;
        vm.prank(address(marketCoreInstance));
        marketVaultInstance.borrow(borrowAmount, bob);

        assertEq(marketVaultInstance.utilization(), (10 ** baseDecimals) / 2); // 50%

        // Borrow more
        vm.prank(address(marketCoreInstance));
        marketVaultInstance.borrow(borrowAmount / 2, bob);

        assertEq(marketVaultInstance.utilization(), ((10 ** baseDecimals) * 3) / 4); // 75%
    }

    function test_TotalAssets() public {
        uint256 initialAssets = marketVaultInstance.totalAssets();
        assertEq(initialAssets, initialLiquidity);

        // Deposit more
        uint256 depositAmount = 10_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), charlie, depositAmount);
        vm.startPrank(charlie);
        usdcInstance.approve(address(marketVaultInstance), depositAmount);
        marketVaultInstance.deposit(depositAmount, charlie);
        vm.stopPrank();

        assertEq(marketVaultInstance.totalAssets(), initialAssets + depositAmount);

        // Boost yield
        uint256 boostAmount = 1_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), address(timelockInstance), boostAmount);
        vm.startPrank(address(timelockInstance));
        usdcInstance.approve(address(marketVaultInstance), boostAmount);
        marketVaultInstance.boostYield(alice, boostAmount);
        vm.stopPrank();

        assertEq(marketVaultInstance.totalAssets(), initialAssets + depositAmount + boostAmount);
    }

    // ============ Integration with Core Tests ============

    function test_Integration_DepositBorrowRepayWithdraw() public {
        // 1. Charlie supplies liquidity through core
        uint256 supplyAmount = 50_000 * 10 ** baseDecimals;
        deal(address(usdcInstance), charlie, supplyAmount);

        vm.startPrank(charlie);
        usdcInstance.approve(address(marketCoreInstance), supplyAmount);
        uint256 expectedShares = marketVaultInstance.previewDeposit(supplyAmount);
        marketCoreInstance.depositLiquidity(supplyAmount, expectedShares, 100);
        vm.stopPrank();

        uint256 charlieShares = marketVaultInstance.balanceOf(charlie);
        assertEq(charlieShares, expectedShares);

        // 2. Bob creates position and borrows
        uint256 positionId = _createPosition(bob, address(wethInstance), false);
        _supplyCollateral(bob, positionId, address(wethInstance), 2 ether);

        uint256 borrowAmount = 3_000 * 10 ** baseDecimals;
        _borrow(bob, positionId, borrowAmount);

        assertEq(marketVaultInstance.totalBorrow(), borrowAmount);

        // 3. Time passes, Bob repays with interest
        _simulateTimeAndAccrueInterest(30 days);

        uint256 debtWithInterest = marketCoreInstance.calculateDebtWithInterest(bob, positionId);
        assertTrue(debtWithInterest > borrowAmount);

        _repay(bob, positionId, type(uint256).max);

        // 4. Charlie withdraws with profit
        vm.warp(block.timestamp + 1);
        vm.roll(block.number + 1); // Move to next block for MEV protection

        uint256 charlieBalanceBefore = usdcInstance.balanceOf(charlie);
        uint256 withdrawAmount = marketVaultInstance.previewRedeem(charlieShares);

        vm.startPrank(charlie);
        marketVaultInstance.approve(address(marketCoreInstance), charlieShares); // Approve Core to move shares
        marketCoreInstance.redeemLiquidityShares(charlieShares, withdrawAmount, 100);
        vm.stopPrank();

        uint256 profit = usdcInstance.balanceOf(charlie) - charlieBalanceBefore - supplyAmount;
        assertTrue(profit > 0, "Charlie should have earned interest");
    }

    // ============ Helper Functions ============

    function _createPosition(address user, address asset, bool isolated) internal returns (uint256) {
        uint256 positionsBefore = marketCoreInstance.getUserPositionsCount(user);
        vm.prank(user);
        marketCoreInstance.createPosition(asset, isolated);
        return positionsBefore;
    }

    function _supplyCollateral(address user, uint256 positionId, address asset, uint256 amount) internal {
        vm.startPrank(user);
        IERC20(asset).approve(address(marketCoreInstance), amount);
        marketCoreInstance.supplyCollateral(asset, amount, positionId);
        vm.stopPrank();
    }

    function _borrow(address user, uint256 positionId, uint256 amount) internal {
        vm.startPrank(user);
        uint256 creditLimit = marketCoreInstance.calculateCreditLimit(user, positionId);
        marketCoreInstance.borrow(positionId, amount, creditLimit, 100);
        vm.stopPrank();
    }

    function _repay(address user, uint256 positionId, uint256 amount) internal {
        uint256 debt = marketCoreInstance.calculateDebtWithInterest(user, positionId);
        uint256 repayAmount = amount == type(uint256).max ? debt : amount;

        // Ensure user has enough USDC to repay
        deal(address(usdcInstance), user, repayAmount);

        vm.startPrank(user);
        usdcInstance.approve(address(marketCoreInstance), repayAmount);
        marketCoreInstance.repay(positionId, repayAmount, debt, 100);
        vm.stopPrank();
    }

    function _simulateTimeAndAccrueInterest(uint256 timeToWarp) internal {
        vm.warp(block.timestamp + timeToWarp);
        vm.roll(block.number + timeToWarp / 12);
    }
}
