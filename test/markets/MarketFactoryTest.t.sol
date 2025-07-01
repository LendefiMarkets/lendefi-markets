// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../BasicDeploy.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {LendefiCore} from "../../contracts/markets/LendefiCore.sol";
import {LendefiMarketVault} from "../../contracts/markets/LendefiMarketVault.sol";
import {LendefiPositionVault} from "../../contracts/markets/LendefiPositionVault.sol";
import {LendefiPoRFeed} from "../../contracts/markets/LendefiPoRFeed.sol";
import {LendefiMarketFactory} from "../../contracts/markets/LendefiMarketFactory.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

contract MarketFactoryTest is BasicDeploy {
    TokenMock public baseAsset1;
    TokenMock public baseAsset2;

    function setUp() public {
        // Deploy basic infrastructure first
        deployMarketsWithUSDC();

        // Create additional test assets
        baseAsset1 = new TokenMock("Test Token 1", "TEST1");
        baseAsset2 = new TokenMock("Test Token 2", "TEST2");

        // Add test assets to allowlist (gnosisSafe has MANAGER_ROLE)
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(baseAsset1));
        marketFactoryInstance.addAllowedBaseAsset(address(baseAsset2));
        vm.stopPrank();

        // TGE is already initialized in deployMarketsWithUSDC(), no need to call it again
    }

    function testCreateMarket() public {
        // Setup governance tokens for charlie (required for permissionless market creation)
        vm.prank(guardian);
        tokenInstance.transfer(charlie, 10000 ether); // Transfer 10,000 tokens
        vm.prank(charlie);
        tokenInstance.approve(address(marketFactoryInstance), 100 ether); // Approve the 100 tokens that will be transferred

        // Create market with first test asset
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market 1", "TM1");

        // Verify market creation
        IPROTOCOL.Market memory createdMarket = marketFactoryInstance.getMarketInfo(charlie, address(baseAsset1));
        assertEq(createdMarket.baseAsset, address(baseAsset1));
        assertEq(createdMarket.name, "Test Market 1");
        assertEq(createdMarket.symbol, "TM1");
        assertTrue(createdMarket.active);
        assertEq(createdMarket.decimals, 18);
        assertTrue(createdMarket.createdAt > 0);
        assertTrue(createdMarket.core != address(0));
        assertTrue(createdMarket.baseVault != address(0));

        // Note: getAllActiveMarkets() was removed - testing market existence via direct lookup
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(baseAsset1)), "Market should be active");
    }

    function testCannotCreateMarketWithZeroAddress() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSignature("BaseAssetNotAllowed()"));
        marketFactoryInstance.createMarket(address(0), "Test Market", "TMKT");
    }

    function testCannotCreateDuplicateMarket() public {
        // Setup governance tokens for charlie (required for permissionless market creation)
        vm.prank(guardian);
        tokenInstance.transfer(charlie, 10000 ether); // Transfer 10,000 tokens
        vm.prank(charlie);
        tokenInstance.approve(address(marketFactoryInstance), 200 ether); // Approve for 2 potential market creations

        // Create first market
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");

        // Try to create duplicate
        vm.expectRevert(abi.encodeWithSignature("MarketAlreadyExists()"));
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");
    }

    function testCannotCreateMarketNonAdmin() public {
        // Try to create market as non-admin
        vm.expectRevert();
        marketFactoryInstance.createMarket(address(baseAsset1), "Test Market", "TMKT");
    }

    // Note: getAllActiveMarkets() function was removed

    // ============ ZeroAddress Error Tests ============

    function test_Revert_Initialize_ZeroTimelock() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        // Get network addresses for test
        (address networkUSDT, address networkWBNB, address UsdtWbnbPool) = getNetworkAddresses();

        // Try to deploy proxy with zero timelock in init data
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(0), // zero timelock
            address(tokenInstance),
            address(gnosisSafe),
            address(ecoInstance),
            networkUSDT,
            networkWBNB,
            UsdtWbnbPool
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroGovToken() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        // Get network addresses for test
        (address networkUSDT, address networkWBNB, address UsdtWbnbPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(0),
            address(gnosisSafe),
            address(ecoInstance),
            networkUSDT,
            networkWBNB,
            UsdtWbnbPool
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroEcosystem() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        // Get network addresses for test
        (address networkUSDT, address networkWBNB, address UsdtWbnbPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(tokenInstance),
            address(gnosisSafe),
            address(0),
            networkUSDT,
            networkWBNB,
            UsdtWbnbPool
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }

    function test_Revert_Initialize_ZeroMultisig() public {
        LendefiMarketFactory factoryImpl = new LendefiMarketFactory();

        // Get network addresses for test
        (address networkUSDT, address networkWBNB, address UsdtWbnbPool) = getNetworkAddresses();

        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketFactory.initialize.selector,
            address(timelockInstance),
            address(tokenInstance),
            address(0),
            address(ecoInstance),
            networkUSDT,
            networkWBNB,
            UsdtWbnbPool
        );

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        new ERC1967Proxy(address(factoryImpl), initData);
    }
}
