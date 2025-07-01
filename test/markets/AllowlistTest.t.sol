// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {ILendefiMarketFactory} from "../../contracts/interfaces/ILendefiMarketFactory.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AllowlistTest is BasicDeploy {
    TokenMock public testToken;

    function setUp() public {
        deployMarketsWithUSDC();
        testToken = new TokenMock("Test Token", "TEST");
    }

    function test_AddAllowedBaseAsset() public {
        // Initially test token should not be allowed
        assertFalse(marketFactoryInstance.isBaseAssetAllowed(address(testToken)));

        // Add test token to allowlist
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(testToken));

        // Now it should be allowed
        assertTrue(marketFactoryInstance.isBaseAssetAllowed(address(testToken)));

        // Should be in the list of allowed assets
        address[] memory allowedAssets = marketFactoryInstance.getAllowedBaseAssets();
        bool found = false;
        for (uint256 i = 0; i < allowedAssets.length; i++) {
            if (allowedAssets[i] == address(testToken)) {
                found = true;
                break;
            }
        }
        assertTrue(found, "Test token should be in allowed assets list");
    }

    function test_RemoveAllowedBaseAsset() public {
        // Add test token first
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(testToken));
        assertTrue(marketFactoryInstance.isBaseAssetAllowed(address(testToken)));

        // Remove test token
        vm.prank(gnosisSafe);
        marketFactoryInstance.removeAllowedBaseAsset(address(testToken));

        // Should no longer be allowed
        assertFalse(marketFactoryInstance.isBaseAssetAllowed(address(testToken)));
    }

    function test_CreateMarketWithoutAllowlist_ShouldFail() public {
        // Try to create market without adding token to allowlist
        vm.prank(charlie);
        vm.expectRevert(ILendefiMarketFactory.BaseAssetNotAllowed.selector);
        marketFactoryInstance.createMarket(address(testToken), "Test Market", "TEST");
    }

    function test_CreateMarketWithAllowlist_ShouldSucceed() public {
        // Add token to allowlist
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(testToken));

        // Setup governance tokens for charlie (required for permissionless market creation)
        // Charlie should already have tokens from BasicDeploy, but may have used his approval
        // Reset charlie's token balance and give fresh approval
        deal(address(tokenInstance), charlie, 10000 ether);
        vm.prank(charlie);
        tokenInstance.approve(address(marketFactoryInstance), type(uint256).max); // Give unlimited approval

        // Now market creation should succeed
        vm.prank(charlie);
        marketFactoryInstance.createMarket(address(testToken), "Test Market", "TEST");

        // Verify market was created
        assertTrue(marketFactoryInstance.isMarketActive(charlie, address(testToken)));
    }

    function test_Revert_AddAllowedBaseAsset_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, LendefiConstants.MANAGER_ROLE
            )
        );
        marketFactoryInstance.addAllowedBaseAsset(address(testToken));
    }

    function test_Revert_RemoveAllowedBaseAsset_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, alice, LendefiConstants.MANAGER_ROLE
            )
        );
        marketFactoryInstance.removeAllowedBaseAsset(address(testToken));
    }

    function test_Revert_AddAllowedBaseAsset_ZeroAddress() public {
        vm.prank(gnosisSafe);
        vm.expectRevert(ILendefiMarketFactory.ZeroAddress.selector);
        marketFactoryInstance.addAllowedBaseAsset(address(0));
    }

    function test_USDCIsAlreadyInAllowlist() public {
        // USDC should already be in allowlist from BasicDeploy
        assertTrue(marketFactoryInstance.isBaseAssetAllowed(address(usdcInstance)));
    }

    function test_GetAllowedBaseAssetsCount() public {
        // Initially should have 1 asset (USDC from BasicDeploy)
        uint256 initialCount = marketFactoryInstance.getAllowedBaseAssetsCount();
        assertEq(initialCount, 1);

        // Add test token to allowlist
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(address(testToken));

        // Count should increase to 2
        uint256 newCount = marketFactoryInstance.getAllowedBaseAssetsCount();
        assertEq(newCount, 2);
        assertEq(newCount, initialCount + 1);

        // Remove test token
        vm.prank(gnosisSafe);
        marketFactoryInstance.removeAllowedBaseAsset(address(testToken));

        // Count should return to original
        uint256 finalCount = marketFactoryInstance.getAllowedBaseAssetsCount();
        assertEq(finalCount, initialCount);
        assertEq(finalCount, 1);
    }
}
