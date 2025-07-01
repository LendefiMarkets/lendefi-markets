// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "forge-std/Test.sol"; // solhint-disable-line
import {USDC} from "../contracts/mock/USDC.sol";
import {IASSETS} from "../contracts/interfaces/IASSETS.sol";
import {IPROTOCOL} from "../contracts/interfaces/IProtocol.sol";
import {WETH9} from "../contracts/vendor/canonical-weth/contracts/WETH9.sol";
import {ITREASURY} from "../contracts/interfaces/ITreasury.sol";
import {IECOSYSTEM} from "../contracts/interfaces/IEcosystem.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {WETHPriceConsumerV3} from "../contracts/mock/WETHOracle.sol";
import {Treasury} from "../contracts/ecosystem/Treasury.sol";
import {TreasuryV2} from "../contracts/upgrades/TreasuryV2.sol";
import {Ecosystem} from "../contracts/ecosystem/Ecosystem.sol";
import {EcosystemV2} from "../contracts/upgrades/EcosystemV2.sol";
import {GovernanceToken} from "../contracts/ecosystem/GovernanceToken.sol";
import {GovernanceTokenV2} from "../contracts/upgrades/GovernanceTokenV2.sol";
import {LendefiGovernor} from "../contracts/ecosystem/LendefiGovernor.sol";
import {LendefiGovernorV2} from "../contracts/upgrades/LendefiGovernorV2.sol";
import {InvestmentManager} from "../contracts/ecosystem/InvestmentManager.sol";
import {InvestmentManagerV2} from "../contracts/upgrades/InvestmentManagerV2.sol";
import {Upgrades, Options} from "openzeppelin-foundry-upgrades/Upgrades.sol";
import {DefenderOptions} from "openzeppelin-foundry-upgrades/Options.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {TimelockV2} from "../contracts/upgrades/TimelockV2.sol";
import {TeamManager} from "../contracts/ecosystem/TeamManager.sol";
import {TeamManagerV2} from "../contracts/upgrades/TeamManagerV2.sol";
import {LendefiAssets} from "../contracts/markets/LendefiAssets.sol";
import {LendefiAssetsV2} from "../contracts/upgrades/LendefiAssetsV2.sol";
import {LendefiPoRFeed} from "../contracts/markets/LendefiPoRFeed.sol";
import {TimelockControllerUpgradeable} from
    "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts/proxy/transparent/TransparentUpgradeableProxy.sol";
// Markets Layer imports
import {LendefiMarketFactory} from "../contracts/markets/LendefiMarketFactory.sol";
import {LendefiMarketFactoryV2} from "../contracts/upgrades/LendefiMarketFactoryV2.sol";
import {LendefiCore} from "../contracts/markets/LendefiCore.sol";
import {LendefiCoreV2} from "../contracts/upgrades/LendefiCoreV2.sol";
import {LendefiMarketVault} from "../contracts/markets/LendefiMarketVault.sol";
import {LendefiMarketVaultV2} from "../contracts/upgrades/LendefiMarketVaultV2.sol";
import {LendefiPositionVault} from "../contracts/markets/LendefiPositionVault.sol";
import {LendefiPoRFeed} from "../contracts/markets/LendefiPoRFeed.sol";
import {LendefiConstants} from "../contracts/markets/lib/LendefiConstants.sol";

contract BasicDeploy is Test {
    event Upgrade(address indexed src, address indexed implementation);

    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant CIRCUIT_BREAKER_ROLE = keccak256("CIRCUIT_BREAKER_ROLE");
    bytes32 internal constant ALLOCATOR_ROLE = keccak256("ALLOCATOR_ROLE");
    bytes32 internal constant PROPOSER_ROLE = keccak256("PROPOSER_ROLE");
    bytes32 internal constant EXECUTOR_ROLE = keccak256("EXECUTOR_ROLE");
    bytes32 internal constant CANCELLER_ROLE = keccak256("CANCELLER_ROLE");
    bytes32 internal constant REWARDER_ROLE = keccak256("REWARDER_ROLE");
    bytes32 internal constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 internal constant MANAGER_ROLE = keccak256("MANAGER_ROLE");
    bytes32 internal constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 internal constant PROTOCOL_ROLE = keccak256("PROTOCOL_ROLE");
    bytes32 internal constant BURNER_ROLE = keccak256("BURNER_ROLE");
    bytes32 internal constant BRIDGE_ROLE = keccak256("BRIDGE_ROLE");
    bytes32 internal constant CORE_ROLE = keccak256("CORE_ROLE");
    bytes32 internal constant DAO_ROLE = keccak256("DAO_ROLE");

    uint256 constant INIT_BALANCE_USDC = 100_000_000e6;
    uint256 constant INITIAL_SUPPLY = 50_000_000 ether;
    address constant ethereum = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    address constant usdcWhale = 0x0A59649758aa4d66E25f08Dd01271e891fe52199;
    address constant gnosisSafe = address(0x9999987);
    address constant bridge = address(0x9999988);
    address constant partner = address(0x9999989);
    address constant guardian = address(0x9999990);
    address constant alice = address(0x9999991);
    address constant bob = address(0x9999992);
    address constant charlie = address(0x9999993);
    address constant registryAdmin = address(0x9999994);
    address constant managerAdmin = address(0x9999995);
    address constant pauser = address(0x9999996);
    address constant assetSender = address(0x9999997);
    address constant assetRecipient = address(0x9999998);
    address constant feeRecipient = address(0x9999999);
    address constant liquidator = address(0x3); // Add liquidator
    address[] users;

    GovernanceToken internal tokenInstance;
    Ecosystem internal ecoInstance;
    TimelockControllerUpgradeable internal timelockInstance;
    LendefiGovernor internal govInstance;
    Treasury internal treasuryInstance;
    InvestmentManager internal managerInstance;
    TeamManager internal tmInstance;
    LendefiAssets internal assetsInstance;
    // Markets Layer contracts
    LendefiMarketFactory internal marketFactoryInstance;
    LendefiCore internal marketCoreInstance;
    LendefiMarketVault internal marketVaultInstance;
    LendefiPoRFeed internal porFeedImplementation;
    WETH9 internal wethInstance;
    USDC internal usdcInstance;
    // IERC20 usdcInstance = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); //real usdc ethereum for fork testing

    // ==================== NETWORK CONFIGURATION ====================

    /**
     * @notice Get network-specific addresses for oracle validation
     * @dev Returns appropriate addresses based on chain ID
     * @return networkUSDC The USDC address for this network
     * @return networkWETH The WETH address for this network
     * @return UsdcWethPool The USDC/WETH pool address for this network
     */
    function getNetworkAddresses() internal returns (address networkUSDC, address networkWETH, address UsdcWethPool) {
        if (block.chainid == LendefiConstants.ETHEREUM_CHAIN_ID) {
            // Ethereum mainnet addresses
            networkUSDC = LendefiConstants.ETHEREUM_USDC;
            networkWETH = LendefiConstants.ETHEREUM_WETH;
            UsdcWethPool = LendefiConstants.USDC_ETH_POOL;
        } else {
            // Testnet or other networks - use mock/deployed addresses
            // Deploy WETH if not already deployed
            if (address(wethInstance) == address(0)) {
                wethInstance = new WETH9();
            }
            networkUSDC = address(usdcInstance);
            networkWETH = address(wethInstance);
            // For testnets, we'll need to deploy a mock pool or use a placeholder
            // This should be set to a real pool address in actual testnet deployment
            UsdcWethPool = address(0x1234567890123456789012345678901234567890); // Placeholder for testnet
        }
    }

    // ==================== DYNAMIC AMOUNT HELPERS ====================

    /**
     * @notice Helper function to get USDC amount scaled to its actual decimals
     * @param baseAmount The base amount (e.g., 1000 for 1000 USDC)
     * @return The amount scaled to USDC's decimal precision
     */
    function getUSDCAmount(uint256 baseAmount) internal view returns (uint256) {
        if (address(usdcInstance) == address(0)) {
            return baseAmount * 1e6; // Default to 6 decimals if USDC not deployed yet
        }
        return baseAmount * 10 ** usdcInstance.decimals();
    }

    /**
     * @notice Helper function to get a scaled amount for any ERC20 token
     * @param token The token address
     * @param baseAmount The base amount (e.g., 1000 for 1000 tokens)
     * @return The amount scaled to the token's decimal precision
     */
    function getTokenAmount(address token, uint256 baseAmount) internal view returns (uint256) {
        return baseAmount * 10 ** IERC20Metadata(token).decimals();
    }

    function deployTokenUpgrade() internal {
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }

        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
        assertTrue(tokenInstance.hasRole(UPGRADER_ROLE, address(timelockInstance)) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "GovernanceToken.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("GovernanceTokenV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(address(timelockInstance));
        tokenInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        GovernanceTokenV2 instanceV2 = GovernanceTokenV2(proxy);
        assertEq(instanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == tokenImplementation, "Implementation address didn't change");
        assertTrue(instanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)) == true, "Lost UPGRADER_ROLE");
    }

    function deployEcosystemUpgrade() internal {
        vm.warp(365 days);
        _deployToken();
        _deployTimelock();

        // ecosystem deploy
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(ecoInstance.hasRole(UPGRADER_ROLE, gnosisSafe), "Multisig should have UPGRADER_ROLE");

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Ecosystem.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("EcosystemV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        ecoInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Ecosystem)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        EcosystemV2 ecoInstanceV2 = EcosystemV2(proxy);
        assertEq(ecoInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(ecoInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe), "Lost UPGRADER_ROLE");
    }

    function deployTreasuryUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Treasury
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;

        bytes memory data =
            abi.encodeCall(Treasury.initialize, (address(timelockInstance), gnosisSafe, startOffset, vestingDuration));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(treasuryInstance.hasRole(treasuryInstance.UPGRADER_ROLE(), gnosisSafe));

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "Treasury.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TreasuryV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        treasuryInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Treasury)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TreasuryV2 treasuryInstanceV2 = TreasuryV2(proxy);
        assertEq(treasuryInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(treasuryInstanceV2.hasRole(treasuryInstanceV2.UPGRADER_ROLE(), gnosisSafe), "Lost UPGRADER_ROLE");
    }

    function deployTimelockUpgrade() internal {
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;

        TimelockControllerUpgradeable implementation = new TimelockControllerUpgradeable();
        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy1 = new ERC1967Proxy(address(implementation), initData);

        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy1)));

        // deploy Timelock Upgrade, ERC1967Proxy
        TimelockV2 newImplementation = new TimelockV2();
        bytes memory initData2 = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );
        ERC1967Proxy proxy2 = new ERC1967Proxy(address(newImplementation), initData2);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy2)));
    }

    function deployGovernorUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplAddressV1);
        assertEq(govInstance.uupsVersion(), 1);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiGovernor.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiGovernorV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        govInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Governor)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address govImplAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiGovernorV2 govInstanceV2 = LendefiGovernorV2(proxy);
        assertEq(govInstanceV2.uupsVersion(), 2, "Version not incremented to 2");
        assertFalse(govImplAddressV2 == govImplAddressV1, "Implementation address didn't change");
    }

    function deployIMUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
        _deployTreasury();

        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(treasuryInstance))
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implAddressV1);

        // Verify gnosis multisig has the required role
        assertTrue(
            managerInstance.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Timelock should have UPGRADER_ROLE"
        );

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "InvestmentManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("InvestmentManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(address(timelockInstance));
        managerInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for InvestmentManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        InvestmentManagerV2 imInstanceV2 = InvestmentManagerV2(proxy);
        assertEq(imInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(imInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Lost UPGRADER_ROLE");
    }

    function deployTeamManagerUpgrade() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();

        // deploy Team Manager with gnosisSafe as the upgrader role
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implAddressV1);
        assertTrue(tmInstance.hasRole(UPGRADER_ROLE, gnosisSafe) == true);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "TeamManager.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("TeamManagerV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        tmInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for TeamManager)
        vm.warp(block.timestamp + 3 days + 1);

        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        TeamManagerV2 tmInstanceV2 = TeamManagerV2(proxy);
        assertEq(tmInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(tmInstanceV2.hasRole(UPGRADER_ROLE, gnosisSafe) == true, "Lost UPGRADER_ROLE");
    }

    function deployComplete() internal {
        vm.warp(365 days);
        _deployTimelock();
        _deployToken();
        _deployEcosystem();
        _deployGovernor();

        // reset timelock proposers and executors
        vm.startPrank(guardian);
        timelockInstance.revokeRole(PROPOSER_ROLE, ethereum);
        timelockInstance.revokeRole(EXECUTOR_ROLE, ethereum);
        timelockInstance.revokeRole(CANCELLER_ROLE, ethereum);
        timelockInstance.grantRole(PROPOSER_ROLE, address(govInstance));
        timelockInstance.grantRole(EXECUTOR_ROLE, address(govInstance));
        timelockInstance.grantRole(CANCELLER_ROLE, address(govInstance));
        vm.stopPrank();

        //deploy Treasury
        _deployTreasury();
    }

    function _deployToken() internal {
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }
        // token deploy
        bytes memory data = abi.encodeCall(GovernanceToken.initializeUUPS, (guardian, address(timelockInstance)));
        address payable proxy = payable(Upgrades.deployUUPSProxy("GovernanceToken.sol", data));
        tokenInstance = GovernanceToken(proxy);
        address tokenImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tokenInstance) == tokenImplementation);
    }

    function _deployEcosystem() internal {
        // ecosystem deploy
        bytes memory data =
            abi.encodeCall(Ecosystem.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Ecosystem.sol", data));
        ecoInstance = Ecosystem(proxy);
        address ecoImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(ecoInstance) == ecoImplementation);
    }

    function _deployTimelock() internal {
        // timelock deploy
        uint256 timelockDelay = 24 * 60 * 60;
        address[] memory temp = new address[](1);
        temp[0] = ethereum;
        TimelockControllerUpgradeable timelock = new TimelockControllerUpgradeable();

        bytes memory initData = abi.encodeWithSelector(
            TimelockControllerUpgradeable.initialize.selector, timelockDelay, temp, temp, guardian
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(timelock), initData);
        timelockInstance = TimelockControllerUpgradeable(payable(address(proxy)));
    }

    function _deployGovernor() internal {
        // deploy Governor
        bytes memory data = abi.encodeCall(LendefiGovernor.initialize, (tokenInstance, timelockInstance, gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiGovernor.sol", data));
        govInstance = LendefiGovernor(proxy);
        address govImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(govInstance) == govImplementation);
        assertEq(govInstance.uupsVersion(), 1);
    }

    function _deployTreasury() internal {
        // deploy Treasury
        uint256 startOffset = 180 days;
        uint256 vestingDuration = 3 * 365 days;
        bytes memory data =
            abi.encodeCall(Treasury.initialize, (address(timelockInstance), gnosisSafe, startOffset, vestingDuration));
        address payable proxy = payable(Upgrades.deployUUPSProxy("Treasury.sol", data));
        treasuryInstance = Treasury(proxy);
        address implAddress = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(treasuryInstance) == implAddress);
    }

    function _deployInvestmentManager() internal {
        // deploy Investment Manager
        bytes memory data = abi.encodeCall(
            InvestmentManager.initialize, (address(tokenInstance), address(timelockInstance), address(treasuryInstance))
        );
        address payable proxy = payable(Upgrades.deployUUPSProxy("InvestmentManager.sol", data));
        managerInstance = InvestmentManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(managerInstance) == implementation);
    }

    function _deployTeamManager() internal {
        // deploy Team Manager
        bytes memory data =
            abi.encodeCall(TeamManager.initialize, (address(tokenInstance), address(timelockInstance), gnosisSafe));
        address payable proxy = payable(Upgrades.deployUUPSProxy("TeamManager.sol", data));
        tmInstance = TeamManager(proxy);
        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(tmInstance) == implementation);
    }

    /**
     * @notice Deploys the combined LendefiAssetOracle contract
     * @dev Replaces the separate Oracle and Assets modules with the combined contract
     */
    function _deployAssetsModule() internal {
        if (address(timelockInstance) == address(0)) {
            _deployTimelock();
        }
        if (address(usdcInstance) == address(0)) {
            usdcInstance = new USDC();
        }

        porFeedImplementation = new LendefiPoRFeed();

        // Get network-specific addresses
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        // Protocol Oracle deploy (combined Oracle + Assets)
        bytes memory data = abi.encodeCall(
            LendefiAssets.initialize,
            (
                address(timelockInstance),
                charlie,
                address(porFeedImplementation),
                ethereum,
                networkUSDC,
                networkWETH,
                UsdcWethPool
            )
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiAssets.sol", data));

        // Store the instance in both variables to maintain compatibility with existing tests
        assetsInstance = LendefiAssets(proxy);

        address implementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(assetsInstance) == implementation);
    }
    /**
     * @notice Upgrades the LendefiAssets implementation
     * @dev Follows the same pattern as other module upgrades
     */

    /**
     * @notice Upgrades the LendefiAssets implementation using timelocked pattern
     * @dev Uses the two-phase upgrade process: schedule → wait → execute
     */
    function deployAssetsModuleUpgrade() internal {
        // First make sure the assets module is deployed
        if (address(assetsInstance) == address(0)) {
            _deployAssetsModule();
        }

        // Get the proxy address
        address payable proxy = payable(address(assetsInstance));

        // Get the current implementation address for assertion later
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiAssets.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiAssetsV2.sol", opts);

        // Schedule the upgrade with that exact address (using timelock)
        vm.startPrank(address(timelockInstance));
        assetsInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for Assets)
        vm.warp(block.timestamp + 3 days + 1);

        // Execute the upgrade
        ITransparentUpgradeableProxy(proxy).upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiAssetsV2 assetsInstanceV2 = LendefiAssetsV2(proxy);

        // Assert that upgrade was successful
        assertEq(assetsInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(
            assetsInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Timelock should retain UPGRADER_ROLE"
        );

        // Test role management still works
        vm.startPrank(address(timelockInstance));
        assetsInstanceV2.revokeRole(UPGRADER_ROLE, address(timelockInstance));
        assertFalse(
            assetsInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Role should be revoked successfully"
        );
        assetsInstance.grantRole(UPGRADER_ROLE, address(timelockInstance));
        assertTrue(
            assetsInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Timelock should have UPGRADER_ROLE"
        );
        vm.stopPrank();
    }

    /**
     * @notice Upgrades the LendefiMarketFactory implementation using timelocked pattern
     * @dev Uses the two-phase upgrade process: schedule → wait → execute
     */
    function deployMarketFactoryUpgrade() internal {
        // First make sure the market factory is deployed
        if (address(marketFactoryInstance) == address(0)) {
            _deployMarketFactory();
        }

        // Get the proxy address
        address payable proxy = payable(address(marketFactoryInstance));

        // Get the current implementation address for assertion later
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);

        // Create options struct for the implementation
        Options memory opts = Options({
            referenceContract: "LendefiMarketFactory.sol",
            constructorData: "",
            unsafeAllow: "",
            unsafeAllowRenames: false,
            unsafeSkipStorageCheck: false,
            unsafeSkipAllChecks: false,
            defender: DefenderOptions({
                useDefenderDeploy: false,
                skipVerifySourceCode: false,
                relayerId: "",
                salt: bytes32(0),
                upgradeApprovalProcessId: ""
            })
        });

        // Deploy the implementation without upgrading
        address newImpl = Upgrades.prepareUpgrade("LendefiMarketFactoryV2.sol", opts);

        // Schedule the upgrade with that exact address
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.scheduleUpgrade(newImpl);

        // Fast forward past the timelock period (3 days for MarketFactory)
        vm.warp(block.timestamp + 3 days + 1);

        // Execute the upgrade
        marketFactoryInstance.upgradeToAndCall(newImpl, "");
        vm.stopPrank();

        // Verification
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiMarketFactoryV2 marketFactoryInstanceV2 = LendefiMarketFactoryV2(proxy);

        // Assert that upgrade was successful
        assertEq(marketFactoryInstanceV2.version(), 2, "Version not incremented to 2");
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertTrue(marketFactoryInstanceV2.hasRole(DEFAULT_ADMIN_ROLE, gnosisSafe), "Lost DEFAULT_ADMIN_ROLE");

        // Test role management still works - gnosisSafe should have admin control
        vm.startPrank(gnosisSafe);
        marketFactoryInstanceV2.grantRole(UPGRADER_ROLE, address(timelockInstance));
        assertTrue(
            marketFactoryInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Should grant UPGRADER_ROLE"
        );
        marketFactoryInstanceV2.revokeRole(UPGRADER_ROLE, address(timelockInstance));
        assertFalse(
            marketFactoryInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Should revoke UPGRADER_ROLE"
        );
        vm.stopPrank();
    }

    // ============ Markets Layer Deployment Functions ============

    /**
     * @notice Deploys the LendefiMarketFactory contract
     * @dev This contract creates Core+Vault pairs for different base assets
     */
    function _deployMarketFactory() internal {
        // Ensure dependencies are deployed
        require(address(timelockInstance) != address(0), "Timelock not deployed");
        // require(address(vaultFactoryInstance) != address(0), "VaultFactory not deployed");
        require(address(treasuryInstance) != address(0), "Treasury not deployed");
        // require(address(assetsInstance) != address(0), "Assets module not deployed");
        require(address(tokenInstance) != address(0), "Governance token not deployed");

        // Deploy implementations
        LendefiCore coreImpl = new LendefiCore();
        LendefiMarketVault marketVaultImpl = new LendefiMarketVault(); // For market vaults
        LendefiPositionVault positionVaultImpl = new LendefiPositionVault(); // For user position vaults
        LendefiAssets assetsImpl = new LendefiAssets(); // Assets implementation for cloning
        LendefiPoRFeed porFeedImpl = new LendefiPoRFeed();

        // Get network-specific addresses
        (address networkUSDC, address networkWETH, address UsdcWethPool) = getNetworkAddresses();

        // Deploy factory using UUPS pattern with direct proxy deployment
        bytes memory factoryData = abi.encodeCall(
            LendefiMarketFactory.initialize,
            (
                address(timelockInstance),
                address(tokenInstance),
                gnosisSafe,
                address(ecoInstance),
                networkUSDC,
                networkWETH,
                UsdcWethPool
            )
        );
        address payable factoryProxy = payable(Upgrades.deployUUPSProxy("LendefiMarketFactory.sol", factoryData));
        marketFactoryInstance = LendefiMarketFactory(factoryProxy);

        // Set implementations - pass the implementation address, NOT the proxy
        vm.startPrank(gnosisSafe);
        marketFactoryInstance.setImplementations(
            address(coreImpl),
            address(marketVaultImpl),
            address(positionVaultImpl),
            address(assetsImpl),
            address(porFeedImpl)
        );
        vm.stopPrank();
    }

    /**
     * @notice Deploys a specific market (Core + Vault) for a base asset
     * @param baseAsset The base asset address for the market
     * @param name The name for the market
     * @param symbol The symbol for the market
     */
    function _deployMarket(address baseAsset, string memory name, string memory symbol) internal {
        require(address(marketFactoryInstance) != address(0), "Market factory not deployed");
        // require(address(assetsInstance) != address(0), "Assets module not deployed");

        // Verify implementations are set
        require(marketFactoryInstance.coreImplementation() != address(0), "Core implementation not set");
        require(marketFactoryInstance.vaultImplementation() != address(0), "Vault implementation not set");

        // NOTE: MARKET_OWNER_ROLE no longer required - market creation is now permissionless with governance token requirement

        // Add base asset to allowlist (done by multisig which has MANAGER_ROLE)
        vm.prank(gnosisSafe);
        marketFactoryInstance.addAllowedBaseAsset(baseAsset);

        // Setup governance tokens for charlie (required for permissionless market creation)
        // Transfer governance tokens from guardian to charlie (guardian received DEPLOYER_SHARE during TGE)
        vm.prank(guardian);
        tokenInstance.transfer(charlie, 10000 ether); // Transfer 10,000 tokens (more than the 1000 required)

        // Charlie approves factory to spend governance tokens
        vm.prank(charlie);
        tokenInstance.approve(address(marketFactoryInstance), 100 ether); // Approve the 100 tokens that will be transferred

        // Create market via factory (charlie as market owner)
        vm.prank(charlie);
        marketFactoryInstance.createMarket(baseAsset, name, symbol);

        // Get deployed addresses (using charlie as market owner)
        IPROTOCOL.Market memory deployedMarket = marketFactoryInstance.getMarketInfo(charlie, baseAsset);
        marketCoreInstance = LendefiCore(deployedMarket.core);
        marketVaultInstance = LendefiMarketVault(deployedMarket.baseVault);

        // Get the assets module for this specific market from the market struct
        address marketAssetsModule = deployedMarket.assetsModule;
        assetsInstance = LendefiAssets(marketAssetsModule); // Update assetsInstance to point to the market's assets module

        // Grant necessary roles
        vm.startPrank(address(timelockInstance));
        ecoInstance.grantRole(REWARDER_ROLE, address(marketCoreInstance));
        // Grant market owner MANAGER_ROLE on vault (since factory can't do it without DEFAULT_ADMIN_ROLE)
        marketVaultInstance.grantRole(LendefiConstants.MANAGER_ROLE, charlie);
        vm.stopPrank();
    }

    /**
     * @notice Deploy a complete markets setup with USDC as base asset
     * @dev Deploys all necessary contracts and creates a USDC market
     */
    function deployMarketsWithUSDC() internal {
        // Warp time to ensure treasury deployment doesn't underflow
        vm.warp(365 days);

        // Ensure base contracts are deployed
        if (address(timelockInstance) == address(0)) _deployTimelock();
        if (address(tokenInstance) == address(0)) _deployToken();
        if (address(ecoInstance) == address(0)) _deployEcosystem();
        if (address(treasuryInstance) == address(0)) _deployTreasury();
        // if (address(assetsInstance) == address(0)) _deployAssetsModule();

        if (address(usdcInstance) == address(0)) usdcInstance = new USDC();

        // Initialize TGE if not already done (gives guardian initial token allocation)
        if (tokenInstance.tge() == 0) {
            vm.prank(guardian);
            tokenInstance.initializeTGE(address(ecoInstance), address(treasuryInstance));
        }

        // Deploy market factory
        _deployMarketFactory();

        // Deploy USDC market
        _deployMarket(address(usdcInstance), "Lendefi Yield Token", "LYTUSDC");
    }

    /**
     * @notice Upgrades the LendefiCore implementation using ERC1967Proxy pattern
     * @dev Follows the same pattern as deployTimelockUpgrade
     */
    function deployLendefiCoreUpgrade() internal {
        // First make sure the market core is deployed
        deployComplete();
        _deployAssetsModule();

        // Deploy new implementation
        LendefiPositionVault positionVaultImpl = new LendefiPositionVault();

        // Get initialization data from current core
        bytes memory initData = abi.encodeWithSelector(
            LendefiCore.initialize.selector,
            address(timelockInstance), // admin
            charlie, // marketOwner
            address(tokenInstance), // govToken_
            address(positionVaultImpl) // positionVault
        );
        address proxy1 = Upgrades.deployTransparentProxy("LendefiCore.sol", address(timelockInstance), initData);

        marketCoreInstance = LendefiCore(payable(address(proxy1)));
        address implAddressV1 = Upgrades.getImplementationAddress(proxy1);

        // Upgrade to LendefiCoreV2 with empty data (no re-initialization needed)
        vm.startPrank(address(timelockInstance));
        Upgrades.upgradeProxy(proxy1, "LendefiCoreV2.sol", "");
        vm.stopPrank();

        address implAddressV2 = Upgrades.getImplementationAddress(proxy1);
        LendefiCoreV2 coreInstanceV2 = LendefiCoreV2(proxy1);

        assertFalse(implAddressV2 == implAddressV1);

        bool isUpgrader = coreInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance));
        assertTrue(isUpgrader == true);

        // Test that core functions still work
        assertTrue(
            coreInstanceV2.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)), "Should have DEFAULT_ADMIN_ROLE"
        );
    }

    /**
     * @notice Upgrades the LendefiMarketVault implementation using ERC1967Proxy pattern
     * @dev Follows the same pattern as deployLendefiCoreUpgrade but for market vault
     */
    function deployMarketVaultUpgrade() internal {
        // Deploy base contracts first
        deployComplete();
        _deployAssetsModule();

        // Deploy a mock USDC if needed
        if (address(usdcInstance) == address(0)) {
            usdcInstance = new USDC();
        }

        // Deploy a core implementation for testing
        LendefiCore coreImpl = new LendefiCore();

        // Correct parameters for LendefiMarketVault.initialize
        bytes memory initData = abi.encodeWithSelector(
            LendefiMarketVault.initialize.selector,
            address(timelockInstance), // _timelock
            address(coreImpl), // core
            address(usdcInstance), // baseAsset
            address(ecoInstance), // _ecosystem
            address(assetsInstance), // _assetsModule
            "Test Vault", // name
            "TV" // symbol
        );

        address payable proxy = payable(Upgrades.deployUUPSProxy("LendefiMarketVault.sol", initData));
        LendefiMarketVault vaultInstance = LendefiMarketVault(proxy);
        address vaultImplementation = Upgrades.getImplementationAddress(proxy);
        assertFalse(address(vaultInstance) == vaultImplementation);

        // Get the current implementation address
        address implAddressV1 = Upgrades.getImplementationAddress(proxy);

        // Upgrade using Upgrades.upgradeProxy
        vm.startPrank(address(timelockInstance));
        Upgrades.upgradeProxy(proxy, "LendefiMarketVaultV2.sol", "", address(timelockInstance));
        vm.stopPrank();

        // Get the new implementation address
        address implAddressV2 = Upgrades.getImplementationAddress(proxy);
        LendefiMarketVaultV2 marketVaultInstanceV2 = LendefiMarketVaultV2(proxy);

        // Verify the upgrade worked correctly
        assertFalse(implAddressV2 == implAddressV1, "Implementation address didn't change");
        assertEq(marketVaultInstanceV2.version(), 2, "Version not incremented to 2");

        // Verify roles are maintained
        assertTrue(
            marketVaultInstanceV2.hasRole(DEFAULT_ADMIN_ROLE, address(timelockInstance)),
            "Should have DEFAULT_ADMIN_ROLE"
        );
        assertTrue(marketVaultInstanceV2.hasRole(UPGRADER_ROLE, address(timelockInstance)), "Should have UPGRADER_ROLE");

        // Update the marketVaultInstance reference to the upgraded version
        marketVaultInstance = LendefiMarketVault(proxy);
    }
}
