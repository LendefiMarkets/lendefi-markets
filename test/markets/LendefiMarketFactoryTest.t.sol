// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LendefiCore} from "../../contracts/markets/LendefiCore.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {ILendefiMarketFactory} from "../../contracts/interfaces/ILendefiMarketFactory.sol";
import {LendefiPositionVault} from "../../contracts/markets/LendefiPositionVault.sol";
import {WETH9} from "../../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {WETHPriceConsumerV3} from "../../contracts/mock/WETHOracle.sol";
import {LendefiConstants} from "../../contracts/markets/lib/LendefiConstants.sol";

contract LendefiMarketFactoryTest is BasicDeploy {
    // Additional test tokens
    TokenMock public daiToken;
    TokenMock public usdtToken;

    // Events
    event MarketCreated(
        address indexed baseAsset,
        address indexed core,
        address indexed baseVault,
        string name,
        string symbol,
        address porFeed
    );

    function setUp() public {
        // Deploy base contracts and market
        deployMarketsWithUSDC();

        // TGE is already initialized in deployMarketsWithUSDC(), no need to call it again

        // Deploy additional tokens for multi-market tests
        daiToken = new TokenMock("DAI Stablecoin", "DAI");
        usdtToken = new TokenMock("Tether USD", "USDT");

        // Set decimals for USDT (6 decimals like real USDT)
        vm.mockCall(address(usdtToken), abi.encodeWithSelector(IERC20Metadata.decimals.selector), abi.encode(6));

        // Deploy and setup WETH for integration tests
        wethInstance = new WETH9();
    }

    // ============ Helper Functions ============

    function addAssetToAllowlist(address asset) internal {
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(asset);
    }

    function addMultipleAssetsToAllowlist() internal {
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(daiToken));
        marketFactoryInstance.addAllowedBaseAsset(address(usdtToken));
        vm.stopPrank();
    }

    function setupGovTokensForUser(address user) internal {
        // Transfer governance tokens from guardian to user (guardian received DEPLOYER_SHARE during TGE)
        vm.prank(guardian);
        tokenInstance.transfer(user, 10000 ether); // Transfer 10,000 tokens (more than the 1000 required)

        // User approves factory to spend governance tokens (enough for multiple markets)
        vm.prank(user);
        tokenInstance.approve(address(marketFactoryInstance), 1000 ether); // Approve enough for 10 markets (100 each)
    }

    // ============ Factory Initialization Tests ============

    function test_FactoryInitialize() public {
        assertTrue(marketFactoryInstance.assetsModuleImplementation() != address(0));
        assertEq(marketFactoryInstance.govToken(), address(tokenInstance));
        assertEq(marketFactoryInstance.timelock(), address(timelockInstance));
        assertTrue(marketFactoryInstance.hasRole(DEFAULT_ADMIN_ROLE, gnosisSafe));
    }

    function test_Revert_FactoryInitializeTwice() public {
        // Get network addresses for test
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        vm.expectRevert();
        marketFactoryInstance.initialize(
            address(timelockInstance),
            address(tokenInstance),
            address(0),
            address(ecoInstance),
            networkUSDC,
            networkWETH,
            UsdcWethPool
        );
    }

    function test_Revert_FactoryInitializeZeroAddress() public {
        LendefiMarketFactory newFactory = new LendefiMarketFactory();

        // Get network addresses for test
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        // The factory uses InvalidInitialization when admin is zero
        vm.expectRevert();
        newFactory.initialize(
            address(0), address(tokenInstance), address(0), address(ecoInstance), networkUSDC, networkWETH, UsdcWethPool
        );
    }

    // ============ Implementation Management Tests ============

    function test_SetImplementations() public {
        LendefiCore newCoreImpl = new LendefiCore();
        LendefiMarketVault newVaultImpl = new LendefiMarketVault();
        LendefiPositionVault posVaultImpl = new LendefiPositionVault();
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        vm.expectEmit(true, true, true, true);
        emit ILendefiMarketFactory.ImplementationsSet(
            address(newCoreImpl), address(newVaultImpl), address(posVaultImpl)
        );

        vm.prank(gnosisSafe);
        marketFactoryInstance.setImplementations(
            address(newCoreImpl),
            address(newVaultImpl),
            address(posVaultImpl),
            address(assetsInstance),
            address(porFeedImpl)
        );

        assertEq(marketFactoryInstance.coreImplementation(), address(newCoreImpl));
        assertEq(marketFactoryInstance.vaultImplementation(), address(newVaultImpl));
        assertEq(marketFactoryInstance.positionVaultImplementation(), address(posVaultImpl));
    }

    function test_Revert_SetImplementations_Unauthorized() public {
        LendefiCore newCoreImpl = new LendefiCore();
        LendefiPositionVault posVaultImpl = new LendefiPositionVault();
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, LendefiConstants.MANAGER_ROLE
            )
        );
        marketFactoryInstance.setImplementations(
            address(newCoreImpl), address(0), address(posVaultImpl), address(assetsInstance), address(porFeedImpl)
        );
    }

    // ============ Market Creation Tests ============

    function test_CreateMarket_USDC() public {
        // USDC market is already created in setup - charlie is the owner
        IPROTOCOL.Market memory market = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));

        assertEq(market.baseAsset, address(usdcInstance));
        assertEq(market.name, "Lendefi Yield Token"); // This is the name used in deployMarketsWithUSDC
        assertEq(market.symbol, "LYTUSDC"); // This is the symbol used in deployMarketsWithUSDC
        assertEq(market.decimals, IERC20Metadata(address(usdcInstance)).decimals());
        assertTrue(market.active);
        assertTrue(market.core != address(0));
        assertTrue(market.baseVault != address(0));
        assertTrue(market.createdAt > 0);
    }

    function test_CreateMarket_DAI() public {
        addAssetToAllowlist(address(daiToken));

        // Setup governance tokens for charlie (required for permissionless market creation)
        setupGovTokensForUser(charlie);

        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        // Verify market was created
        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));
        assertEq(createdMarket.baseAsset, address(daiToken));
        assertEq(createdMarket.name, "Lendefi DAI Market");
        assertTrue(createdMarket.core != address(0));
        assertTrue(createdMarket.baseVault != address(0));

        // Verify core and vault are properly initialized
        LendefiCore daiCore = LendefiCore(createdMarket.core);
        LendefiMarketVault daiVault = LendefiMarketVault(createdMarket.baseVault);

        assertEq(daiCore.baseAsset(), address(daiToken));

        assertEq(daiVault.asset(), address(daiToken));
        assertEq(daiVault.name(), "Lendefi DAI Market");
        assertEq(daiVault.symbol(), "lfDAI");
    }

    function test_CreateMarket_USDT_6Decimals() public {
        addAssetToAllowlist(address(usdtToken));

        // Setup governance tokens for charlie (required for permissionless market creation)
        setupGovTokensForUser(charlie);

        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");

        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdtToken));
        LendefiCore usdtCore = LendefiCore(createdMarket.core);

        // Verify WAD is correctly set for 6 decimal token
        assertEq(usdtCore.baseDecimals(), 10 ** 6); // USDT has 6 decimals
    }

    function test_Revert_CreateMarket_Duplicate() public {
        // Try to create another USDC market (charlie already has a USDC market from BasicDeploy)
        // Setup governance tokens for charlie first
        setupGovTokensForUser(charlie);

        vm.prank(charlie);
        vm.expectRevert(ILendefiMarketFactory.MarketAlreadyExists.selector);
        marketFactoryInstance.createMarket(address(usdcInstance), "Duplicate Market", "DUP");
    }

    function test_Revert_CreateMarket_ZeroAsset() public {
        // Setup governance tokens for charlie first
        setupGovTokensForUser(charlie);

        vm.prank(charlie);
        vm.expectRevert(ILendefiMarketFactory.BaseAssetNotAllowed.selector);
        marketFactoryInstance.createMarket(address(0), "Bad Market", "BAD");
    }

    function test_Revert_CreateMarket_InsufficientGovTokens() public {
        addAssetToAllowlist(address(daiToken));
        vm.prank(alice);
        vm.expectRevert(ILendefiMarketFactory.InsufficientGovTokenBalance.selector);
        marketFactoryInstance.createMarket(address(daiToken), "Insufficient Tokens Market", "INSUF");
    }

    // ============ Market Query Tests ============

    function test_GetMarketInfo() public {
        addMultipleAssetsToAllowlist();
        IPROTOCOL.Market memory market = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));

        assertEq(market.baseAsset, address(usdcInstance));
        assertEq(market.core, address(marketCoreInstance));
        assertEq(market.baseVault, address(marketVaultInstance));
        assertTrue(market.active);
    }

    function test_Revert_GetMarketInfo_NotFound() public {
        vm.expectRevert(ILendefiMarketFactory.MarketNotFound.selector);
        marketFactoryInstance.getMarketInfo(charlie, address(daiToken));
    }

    function test_Revert_GetMarketInfo_ZeroAddress() public {
        vm.expectRevert(ILendefiMarketFactory.ZeroAddress.selector);
        marketFactoryInstance.getMarketInfo(charlie, address(0));
    }

    function test_IsMarketActive() public {
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(usdcInstance)));
        assertFalse(marketFactoryInstance.isMarketActive(charlie, address(daiToken)));
    }

    // Note: getAllActiveMarkets() function was removed in favor of owner-specific queries

    function test_EachMarketHasOwnAssetsModule() public {
        addMultipleAssetsToAllowlist();

        // Setup governance tokens for charlie (required for permissionless market creation)
        setupGovTokensForUser(charlie);

        // Create DAI market as Charlie
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        // Create USDT market as Charlie
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");

        // Get the assets modules for each market from the market structs
        IPROTOCOL.Market memory usdcMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdcInstance));
        IPROTOCOL.Market memory daiMarket = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));
        IPROTOCOL.Market memory usdtMarket = marketFactoryInstance.getMarketInfo(charlie, address(usdtToken));

        address usdcAssetsModule = usdcMarket.assetsModule;
        address daiAssetsModule = daiMarket.assetsModule;
        address usdtAssetsModule = usdtMarket.assetsModule;

        // Verify each market has its own unique assets module
        assertTrue(usdcAssetsModule != address(0), "USDC assets module should exist");
        assertTrue(daiAssetsModule != address(0), "DAI assets module should exist");
        assertTrue(usdtAssetsModule != address(0), "USDT assets module should exist");

        // Verify all assets modules are different
        assertTrue(usdcAssetsModule != daiAssetsModule, "USDC and DAI should have different assets modules");
        assertTrue(usdcAssetsModule != usdtAssetsModule, "USDC and USDT should have different assets modules");
        assertTrue(daiAssetsModule != usdtAssetsModule, "DAI and USDT should have different assets modules");

        // Verify they are clones of the implementation
        assertTrue(
            usdcAssetsModule != marketFactoryInstance.assetsModuleImplementation(),
            "Should be a clone, not the implementation"
        );
        assertTrue(
            daiAssetsModule != marketFactoryInstance.assetsModuleImplementation(),
            "Should be a clone, not the implementation"
        );
        assertTrue(
            usdtAssetsModule != marketFactoryInstance.assetsModuleImplementation(),
            "Should be a clone, not the implementation"
        );
    }

    // ============ Upgrade Tests ============

    function testRevert_FactoryUpgrade() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        // Upgrade should only work from timelock
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, LendefiConstants.UPGRADER_ROLE
            )
        );
        vm.prank(alice);
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");

        // Upgrade from timelock
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");
    }

    function test_CancelUpgrade() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        // Schedule an upgrade first
        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Verify upgrade is scheduled
        (address impl,, bool exists) = marketFactoryInstance.pendingUpgrade();
        assertTrue(exists, "Upgrade should be scheduled");
        assertEq(impl, address(newImpl), "Implementation should match");

        // Cancel the upgrade
        vm.prank(gnosisSafe);
        vm.expectEmit(true, true, false, true);
        emit ILendefiMarketFactory.UpgradeCancelled(gnosisSafe, address(newImpl));
        marketFactoryInstance.cancelUpgrade();

        // Verify upgrade is cancelled
        (address implAfter,, bool existsAfter) = marketFactoryInstance.pendingUpgrade();
        assertFalse(existsAfter, "Upgrade should be cancelled");
        assertEq(implAfter, address(0), "Implementation should be cleared");
    }

    function test_Revert_CancelUpgrade_NotScheduled() public {
        // Try to cancel when no upgrade is scheduled
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("UpgradeNotScheduled()"));
        marketFactoryInstance.cancelUpgrade();
    }

    function test_Revert_CancelUpgrade_Unauthorized() public {
        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Try to cancel from unauthorized account
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, LendefiConstants.UPGRADER_ROLE
            )
        );
        vm.prank(alice);
        marketFactoryInstance.cancelUpgrade();
    }

    function test_UpgradeTimelockRemaining() public {
        // No upgrade scheduled - should return 0
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 when no upgrade scheduled");

        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();
        uint256 scheduleTime = block.timestamp;

        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Should return the full timelock duration immediately after scheduling
        uint256 expectedRemaining = LendefiConstants.UPGRADE_TIMELOCK_DURATION;
        assertEq(
            marketFactoryInstance.upgradeTimelockRemaining(), expectedRemaining, "Should return full timelock duration"
        );

        // Fast forward 1 day
        vm.warp(block.timestamp + 1 days);
        expectedRemaining = LendefiConstants.UPGRADE_TIMELOCK_DURATION - 1 days;
        assertEq(
            marketFactoryInstance.upgradeTimelockRemaining(),
            expectedRemaining,
            "Should return remaining time after 1 day"
        );

        // Fast forward 2 more days (total 3 days = full timelock period)
        vm.warp(scheduleTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION);
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 when timelock expires");

        // Fast forward past expiration
        vm.warp(scheduleTime + LendefiConstants.UPGRADE_TIMELOCK_DURATION + 1 hours);
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 after timelock expires");
    }

    function test_UpgradeTimelockRemaining_AfterCancel() public {
        // Deploy new implementation and schedule upgrade
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Verify timelock is active
        assertGt(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should have remaining time");

        // Cancel the upgrade
        vm.prank(gnosisSafe);
        marketFactoryInstance.cancelUpgrade();

        // Should return 0 after cancellation
        assertEq(marketFactoryInstance.upgradeTimelockRemaining(), 0, "Should return 0 after cancellation");
    }

    function test_Revert_SetImplementations_ZeroAddress() public {
        // Test zero core implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0), address(0x1), address(0x2), address(0x3), address(0x4));

        // Test zero vault implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0x1), address(0), address(0x2), address(0x3), address(0x4));

        // Test zero position vault implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        marketFactoryInstance.setImplementations(address(0x1), address(0x2), address(0), address(0x3), address(0x4));
    }

    function test_Revert_AuthorizeUpgrade_ImplementationMismatch() public {
        // Deploy two different implementations
        LendefiMarketFactory newImpl1 = new LendefiMarketFactory();
        LendefiMarketFactory newImpl2 = new LendefiMarketFactory();

        // Schedule upgrade with first implementation
        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl1));

        // Fast forward past timelock
        vm.warp(block.timestamp + LendefiConstants.UPGRADE_TIMELOCK_DURATION + 1);

        // Try to upgrade with different implementation
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSignature("ImplementationMismatch(address,address)", address(newImpl1), address(newImpl2))
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl2), "");
    }

    function test_Revert_AuthorizeUpgrade_TimelockActive() public {
        // Deploy new implementation
        LendefiMarketFactory newImpl = new LendefiMarketFactory();

        // Schedule upgrade
        vm.prank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(address(newImpl));

        // Try to upgrade immediately (before timelock expires)
        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSignature("UpgradeTimelockActive(uint256)", LendefiConstants.UPGRADE_TIMELOCK_DURATION)
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");

        // Fast forward 1 day (still within timelock)
        vm.warp(block.timestamp + 1 days);

        vm.prank(gnosisSafe);
        vm.expectRevert(
            abi.encodeWithSignature(
                "UpgradeTimelockActive(uint256)", LendefiConstants.UPGRADE_TIMELOCK_DURATION - 1 days
            )
        );
        marketFactoryInstance.upgradeToAndCall(address(newImpl), "");
    }

    // ============ Multi-Tenant Functions Tests ============

    function test_IsMarketActive_MultiTenant() public {
        addMultipleAssetsToAllowlist();
        // Test with charlie's existing USDC market
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(usdcInstance)));

        // Test with non-existent market
        assertFalse(marketFactoryInstance.isMarketActive(charlie, address(daiToken)));
        assertFalse(marketFactoryInstance.isMarketActive(alice, address(usdcInstance)));

        // Setup governance tokens for charlie
        setupGovTokensForUser(charlie);

        // Create DAI market for charlie
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");

        // Now charlie should have active DAI market
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(daiToken)));

        // But alice still shouldn't have any markets
        assertFalse(marketFactoryInstance.isMarketActive(alice, address(daiToken)));
    }

    function test_GetOwnerMarkets() public {
        addMultipleAssetsToAllowlist();

        // Initially charlie should have 1 market (USDC from BasicDeploy)
        IPROTOCOL.Market[] memory charlieMarkets = marketFactoryInstance.getOwnerMarkets(charlie);
        assertEq(charlieMarkets.length, 1);
        assertEq(charlieMarkets[0].baseAsset, address(usdcInstance));
        assertEq(charlieMarkets[0].name, "Lendefi Yield Token");

        // Alice should have no markets
        IPROTOCOL.Market[] memory aliceMarkets = marketFactoryInstance.getOwnerMarkets(alice);
        assertEq(aliceMarkets.length, 0);

        // Setup governance tokens for charlie
        setupGovTokensForUser(charlie);

        // Create additional markets for charlie
        vm.startPrank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");
        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");
        vm.stopPrank();

        // Charlie should now have 3 markets
        charlieMarkets = marketFactoryInstance.getOwnerMarkets(charlie);
        assertEq(charlieMarkets.length, 3);

        // Verify all markets belong to charlie
        assertEq(charlieMarkets[0].baseAsset, address(usdcInstance));
        assertEq(charlieMarkets[1].baseAsset, address(daiToken));
        assertEq(charlieMarkets[2].baseAsset, address(usdtToken));

        // Setup governance tokens for alice to create a market
        setupGovTokensForUser(alice);

        vm.prank(alice);
        marketFactoryInstance.createMarket(address(daiToken), "Alice DAI Market", "aDAI");

        // Alice should now have 1 market
        aliceMarkets = marketFactoryInstance.getOwnerMarkets(alice);
        assertEq(aliceMarkets.length, 1);
        assertEq(aliceMarkets[0].baseAsset, address(daiToken));
        assertEq(aliceMarkets[0].name, "Alice DAI Market");

        // Charlie should still have 3 markets (unchanged)
        charlieMarkets = marketFactoryInstance.getOwnerMarkets(charlie);
        assertEq(charlieMarkets.length, 3);
    }

    function test_GetOwnerBaseAssets() public {
        addMultipleAssetsToAllowlist();
        // Initially charlie should have 1 base asset (USDC)
        address[] memory charlieAssets = marketFactoryInstance.getOwnerBaseAssets(charlie);
        assertEq(charlieAssets.length, 1);
        assertEq(charlieAssets[0], address(usdcInstance));

        // Alice should have no base assets
        address[] memory aliceAssets = marketFactoryInstance.getOwnerBaseAssets(alice);
        assertEq(aliceAssets.length, 0);

        // Setup governance tokens for charlie
        setupGovTokensForUser(charlie);

        // Create additional markets for charlie
        vm.startPrank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Lendefi DAI Market", "lfDAI");
        marketFactoryInstance.createMarket(address(usdtToken), "Lendefi USDT Market", "lfUSDT");
        vm.stopPrank();

        // Charlie should now have 3 base assets
        charlieAssets = marketFactoryInstance.getOwnerBaseAssets(charlie);
        assertEq(charlieAssets.length, 3);
        assertEq(charlieAssets[0], address(usdcInstance));
        assertEq(charlieAssets[1], address(daiToken));
        assertEq(charlieAssets[2], address(usdtToken));
    }

    function test_GetMarketOwnersCount() public {
        addMultipleAssetsToAllowlist();
        // Initially should have 1 owner (charlie from BasicDeploy)
        // Note: getMarketOwnersCount() function was removed

        // Setup governance tokens for alice to create a market
        setupGovTokensForUser(alice);

        vm.prank(alice);
        marketFactoryInstance.createMarket(address(daiToken), "Alice DAI Market", "aDAI");

        // Should now have 2 owners
        // Note: getMarketOwnersCount() function was removed

        // Setup governance tokens for bob to create a market
        setupGovTokensForUser(bob);

        vm.prank(bob);
        marketFactoryInstance.createMarket(address(usdtToken), "Bob USDT Market", "bUSDT");

        // Should now have 3 owners
        // Note: getMarketOwnersCount() function was removed
    }

    // Note: getMarketOwnerByIndex() function was removed

    // Note: getTotalMarketsCount() function was removed

    function test_MultiTenant_MarketIsolation() public {
        addMultipleAssetsToAllowlist();
        // Setup governance tokens for alice
        setupGovTokensForUser(alice);
        // Setup governance tokens for charlie too
        setupGovTokensForUser(charlie);

        // Both charlie and alice create DAI markets
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(daiToken), "Charlie DAI Market", "cDAI");

        vm.prank(alice);
        marketFactoryInstance.createMarket(address(daiToken), "Alice DAI Market", "aDAI");

        // Verify markets are isolated
        IPROTOCOL.Market memory charlieDAI = marketFactoryInstance.getMarketInfo(charlie, address(daiToken));
        IPROTOCOL.Market memory aliceDAI = marketFactoryInstance.getMarketInfo(alice, address(daiToken));

        assertEq(charlieDAI.name, "Charlie DAI Market");
        assertEq(charlieDAI.symbol, "cDAI");
        assertEq(aliceDAI.name, "Alice DAI Market");
        assertEq(aliceDAI.symbol, "aDAI");

        // Verify they have different core and vault addresses
        assertTrue(charlieDAI.core != aliceDAI.core);
        assertTrue(charlieDAI.baseVault != aliceDAI.baseVault);

        // Verify market active status is isolated
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(daiToken)));
        assertTrue(marketFactoryInstance.isMarketActive(alice, address(daiToken)));

        // Verify owner markets are isolated
        IPROTOCOL.Market[] memory charlieMarkets = marketFactoryInstance.getOwnerMarkets(charlie);
        IPROTOCOL.Market[] memory aliceMarkets = marketFactoryInstance.getOwnerMarkets(alice);

        assertEq(charlieMarkets.length, 2); // USDC + DAI
        assertEq(aliceMarkets.length, 1); // DAI only
    }

    // Note: getAllActiveMarkets() function was removed in favor of owner-specific queries

    // ============ Additional Coverage Tests ============
}
