// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../BasicDeploy.sol";
import {IPROTOCOL} from "../../../contracts/interfaces/IProtocol.sol";
import {IASSETS} from "../../../contracts/interfaces/IASSETS.sol";
import {MockRWA} from "../../../contracts/mock/MockRWA.sol";
import {RWAPriceConsumerV3} from "../../../contracts/mock/RWAOracle.sol";
import {MockUniswapV3Pool} from "../../../contracts/mock/MockUniswapV3Pool.sol";

contract UpdateAssetConfigTest is BasicDeploy {
    // Event comes from the assets contract now
    event UpdateAssetConfig(address indexed asset, IASSETS.Asset config);

    MockRWA internal testToken;
    RWAPriceConsumerV3 internal testOracle;

    // Test parameters
    uint8 internal constant ORACLE_DECIMALS = 8;
    uint8 internal constant ASSET_DECIMALS = 18;
    uint8 internal constant ASSET_ACTIVE = 1;
    uint16 internal constant BORROW_THRESHOLD = 800; // 80%
    uint16 internal constant LIQUIDATION_THRESHOLD = 850; // 85%
    uint256 internal constant MAX_SUPPLY = 1_000_000 ether;
    uint256 internal constant ISOLATION_DEBT_CAP = 100_000e6;

    function setUp() public {
        // Use the updated deployment function that includes Oracle setup
        deployMarketsWithUSDC();

        // TGE already initialized in deployMarketsWithUSDC()

        // Deploy test token and oracle for this specific test
        testToken = new MockRWA("Test Token", "TEST");
        testOracle = new RWAPriceConsumerV3();
        testOracle.setPrice(1000e8); // $1000 per token
    }

    // Test 1: Only manager can update asset config
    function testRevert_OnlyManagerCanUpdateAssetConfig() public {
        // Regular user should not be able to call updateAssetConfig

        // Using OpenZeppelin v5.0 AccessControl error format
        vm.expectRevert(
            abi.encodeWithSignature(
                "AccessControlUnauthorizedAccount(address,bytes32)", alice, keccak256("MANAGER_ROLE")
            )
        );
        vm.startPrank(alice);
        // Call should be to assetsInstance with new struct-based format
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );
        vm.stopPrank();

        // Manager (timelock) should be able to update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(0), // No Uniswap pool
                    twapPeriod: 0,
                    active: 0
                })
            })
        );
    }

    // Test 2: Adding a new asset
    function test_AddingNewAsset() public {
        // Initial state - asset should not be listed
        address[] memory initialAssets = assetsInstance.getListedAssets();
        bool initiallyPresent = false;
        for (uint256 i = 0; i < initialAssets.length; i++) {
            if (initialAssets[i] == address(testToken)) {
                initiallyPresent = true;
                break;
            }
        }
        assertFalse(initiallyPresent, "Asset should not be listed initially");

        // Update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Asset should now be listed
        address[] memory updatedAssets = assetsInstance.getListedAssets();
        bool nowPresent = false;
        for (uint256 i = 0; i < updatedAssets.length; i++) {
            if (updatedAssets[i] == address(testToken)) {
                nowPresent = true;
                break;
            }
        }
        assertTrue(nowPresent, "Asset should be listed after update");
    }

    // Test 3: All parameters correctly stored
    function test_AllParametersCorrectlyStored() public {
        // Update asset config
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Get stored asset info
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));

        // Verify all parameters
        assertEq(assetInfo.active, ASSET_ACTIVE, "Active status not stored correctly");
        assertEq(assetInfo.chainlinkConfig.oracleUSD, address(testOracle), "Oracle address not stored correctly");

        assertEq(assetInfo.decimals, ASSET_DECIMALS, "Asset decimals not stored correctly");
        assertEq(assetInfo.borrowThreshold, BORROW_THRESHOLD, "Borrow threshold not stored correctly");
        assertEq(assetInfo.liquidationThreshold, LIQUIDATION_THRESHOLD, "Liquidation threshold not stored correctly");
        assertEq(assetInfo.maxSupplyThreshold, MAX_SUPPLY, "Max supply not stored correctly");
        assertEq(uint8(assetInfo.tier), uint8(IASSETS.CollateralTier.CROSS_A), "Tier not stored correctly");
        assertEq(assetInfo.isolationDebtCap, ISOLATION_DEBT_CAP, "Isolation debt cap not stored correctly");
    }

    // Test 4: Update existing asset
    function test_UpdateExistingAsset() public {
        // First add the asset
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Now update some parameters
        uint8 newActive = 0; // Deactivate
        uint16 newBorrowThreshold = 700; // 70%
        IASSETS.CollateralTier newTier = IASSETS.CollateralTier.ISOLATED;
        uint256 newDebtCap = 50_000e6;

        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(testToken));
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: newActive,
                decimals: ASSET_DECIMALS,
                borrowThreshold: newBorrowThreshold,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: newDebtCap,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: newTier,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify updated parameters
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));

        assertEq(assetInfo.active, newActive, "Active status not updated correctly");
        assertEq(assetInfo.borrowThreshold, newBorrowThreshold, "Borrow threshold not updated correctly");
        assertEq(uint8(assetInfo.tier), uint8(newTier), "Tier not updated correctly");
        assertEq(assetInfo.isolationDebtCap, newDebtCap, "Isolation debt cap not updated correctly");
    }

    // Test 5: Correct event emission
    function test_EventEmission() public {
        IASSETS.Asset memory item = IASSETS.Asset({
            active: ASSET_ACTIVE,
            decimals: ASSET_DECIMALS,
            borrowThreshold: BORROW_THRESHOLD,
            liquidationThreshold: LIQUIDATION_THRESHOLD,
            maxSupplyThreshold: MAX_SUPPLY,
            isolationDebtCap: ISOLATION_DEBT_CAP,
            assetMinimumOracles: 1,
            porFeed: address(0),
            primaryOracleType: IASSETS.OracleType.CHAINLINK,
            tier: IASSETS.CollateralTier.CROSS_A,
            chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
            poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
        });

        vm.expectEmit(true, false, false, false);
        emit UpdateAssetConfig(address(testToken), item);
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(address(testToken), item);
    }

    // Test 6: Effect on collateral management
    function test_EffectOnCollateral() public {
        // First add the asset as active
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Setup user position - these still use marketCoreInstance
        testToken.mint(alice, 10 ether);
        vm.startPrank(alice);
        marketCoreInstance.createPosition(address(testToken), false);
        testToken.approve(address(marketCoreInstance), 10 ether);
        marketCoreInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();

        // Deactivate the asset - now using assetsInstance
        IASSETS.Asset memory asset = assetsInstance.getAssetInfo(address(testToken));
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 0, // Deactivate
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: asset.porFeed,
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Try supplying more collateral - should revert with NotListed error
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(IPROTOCOL.NotListed.selector));
        marketCoreInstance.supplyCollateral(address(testToken), 5 ether, 0);
        vm.stopPrank();
    }

    // Test 7: Validation - Zero Oracle Address
    function testRevert_ZeroOracleAddress() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.ZeroAddressNotAllowed.selector));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(0), active: 1}), // Zero address
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 8: Validation - Invalid Chainlink Active Parameter
    function testRevert_InvalidChainlinkActiveParameter() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "chainlink active", 2));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 2}), // Invalid active value
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 9: Validation - Not Enough Active Oracles
    function testRevert_NotEnoughOracles() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.NotEnoughValidOracles.selector, address(testToken), 2, 1));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 2, // Requires 2 oracles
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}), // Only 1 active
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0}) // Not active
            })
        );
    }

    // Test 10: Validation - Primary Oracle Not Active
    function testRevert_PrimaryOracleNotActive() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(
            abi.encodeWithSelector(IASSETS.OracleNotActive.selector, address(testToken), IASSETS.OracleType.CHAINLINK)
        );

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 0, // No minimum requirement
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK, // Primary is Chainlink
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 0}), // But it's inactive
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 11: Validation - Liquidation Threshold Too High
    function testRevert_LiquidationThresholdTooHigh() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidLiquidationThreshold.selector, 991));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: 991, // Exceeds MAX_LIQUIDATION_THRESHOLD (990)
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 12: Validation - Borrow Threshold Too Close to Liquidation Threshold
    function testRevert_BorrowThresholdTooClose() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidBorrowThreshold.selector, 841));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: 841, // Only 9 less than liquidation threshold (MIN_THRESHOLD_SPREAD is 10)
                liquidationThreshold: 850,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 13: Validation - Invalid Asset Decimals
    function testRevert_InvalidAssetDecimals_Zero() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "assetDecimals", 0));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: 0, // Zero decimals
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    function testRevert_InvalidAssetDecimals_TooHigh() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "assetDecimals", 19));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: 19, // More than 18 decimals
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 14: Validation - Invalid Asset Active Parameter
    function testRevert_InvalidAssetActive() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "active", 2));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 2, // Invalid active value
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 15: Validation - Zero Max Supply Threshold
    function testRevert_ZeroMaxSupply() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "maxSupplyThreshold", 0));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: 0, // Zero max supply
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 16: Validation - Zero Isolation Debt Cap for Isolated Asset
    function testRevert_ZeroIsolationDebtCap() public {
        vm.prank(address(timelockInstance));
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "isolationDebtCap", 0));

        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: 0, // Zero isolation debt cap
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.ISOLATED, // Isolated asset requires non-zero debt cap
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );
    }

    // Test 17: Primary Oracle Type - Uniswap
    function test_PrimaryOracleTypeUniswap() public {
        // Deploy a proper mock Uniswap V3 pool that implements the required interfaces
        MockUniswapV3Pool mockPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);

        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: BORROW_THRESHOLD,
                liquidationThreshold: LIQUIDATION_THRESHOLD,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP, // Primary is Uniswap
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 0}), // Chainlink inactive
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(mockPool),
                    twapPeriod: 900, // 15 minutes
                    active: 1 // Active
                })
            })
        );

        // Verify the primary oracle type
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));
        assertEq(
            uint8(assetInfo.primaryOracleType),
            uint8(IASSETS.OracleType.UNISWAP_V3_TWAP),
            "Primary oracle type not stored correctly"
        );
    }

    // Test 18: Test Valid Edge Case - Exact Minimum Threshold Spread
    function test_ValidEdgeCase_ThresholdSpread() public {
        vm.prank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: ASSET_ACTIVE,
                decimals: ASSET_DECIMALS,
                borrowThreshold: 840, // Exactly 10 less than liquidation threshold
                liquidationThreshold: 850,
                maxSupplyThreshold: MAX_SUPPLY,
                isolationDebtCap: ISOLATION_DEBT_CAP,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Verify the thresholds were accepted
        IASSETS.Asset memory assetInfo = assetsInstance.getAssetInfo(address(testToken));
        assertEq(assetInfo.borrowThreshold, 840, "Borrow threshold not stored correctly");
        assertEq(assetInfo.liquidationThreshold, 850, "Liquidation threshold not stored correctly");
    }

    // ======== 9. ValidatePool Edge Cases ========

    function testRevert_ValidatePoolWithInvalidTwapPeriodTooShort() public {
        // Create a proper Uniswap pool containing the test token
        MockUniswapV3Pool testPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);

        // First add the token to make it a listed asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Now try to set an invalid TWAP period (too short) - minimum is actually 120 seconds (2 minutes)
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "twapPeriod", 119, 900, 1800));
        assetsInstance.updateUniswapOracle(address(testToken), address(testPool), 119, 1);

        vm.stopPrank();
    }

    function testRevert_ValidatePoolWithInvalidTwapPeriodTooLong() public {
        // Create a proper Uniswap pool containing the test token
        MockUniswapV3Pool testPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);

        // First add the token to make it a listed asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Try with an invalid TWAP period (too long)
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidThreshold.selector, "twapPeriod", 1801, 900, 1800));
        assetsInstance.updateUniswapOracle(address(testToken), address(testPool), 1801, 1);

        vm.stopPrank();
    }

    function testRevert_ValidatePoolWithInvalidActiveParameter() public {
        // Create a proper Uniswap pool containing the test token
        MockUniswapV3Pool testPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);

        // First add the token to make it a listed asset
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0),
                primaryOracleType: IASSETS.OracleType.CHAINLINK,
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({oracleUSD: address(testOracle), active: 1}),
                poolConfig: IASSETS.UniswapPoolConfig({pool: address(0), twapPeriod: 0, active: 0})
            })
        );

        // Try with an invalid active parameter (>1)
        vm.expectRevert(abi.encodeWithSelector(IASSETS.InvalidParameter.selector, "active", 2));
        assetsInstance.updateUniswapOracle(address(testToken), address(testPool), 900, 2);

        vm.stopPrank();
    }

    function testRevert_ValidatePoolWithInsufficientOracles() public {
        // Create a proper Uniswap pool containing the test token
        MockUniswapV3Pool testPool = new MockUniswapV3Pool(address(testToken), address(usdcInstance), 3000);

        // First add the token to make it a listed asset with:
        // - Minimum oracles = 1
        // - Chainlink inactive
        // - Uniswap active
        vm.startPrank(address(timelockInstance));
        assetsInstance.updateAssetConfig(
            address(testToken),
            IASSETS.Asset({
                active: 1,
                decimals: 8,
                borrowThreshold: 800,
                liquidationThreshold: 850,
                maxSupplyThreshold: 1_000_000e8,
                isolationDebtCap: 0,
                assetMinimumOracles: 1,
                porFeed: address(0), // Require at least 1 oracle
                primaryOracleType: IASSETS.OracleType.UNISWAP_V3_TWAP, // Uniswap is primary
                tier: IASSETS.CollateralTier.CROSS_A,
                chainlinkConfig: IASSETS.ChainlinkOracleConfig({
                    oracleUSD: address(testOracle),
                    active: 0 // Chainlink inactive
                }),
                poolConfig: IASSETS.UniswapPoolConfig({
                    pool: address(testPool),
                    twapPeriod: 900,
                    active: 1 // Uniswap active
                })
            })
        );

        // Now try to deactivate Uniswap with Chainlink already inactive
        // This should revert because we would have 0 active oracles while minimum is 1
        vm.expectRevert(abi.encodeWithSelector(IASSETS.NotEnoughValidOracles.selector, address(testToken), 1, 0));
        assetsInstance.updateUniswapOracle(address(testToken), address(testPool), 900, 0);

        vm.stopPrank();
    }
}
