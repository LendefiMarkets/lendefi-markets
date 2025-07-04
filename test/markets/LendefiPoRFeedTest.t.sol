// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import "../BasicDeploy.sol";
import {LendefiPoRFeed} from "../../contracts/markets/LendefiPoRFeed.sol";
import {TokenMock} from "../../contracts/mock/TokenMock.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IPoRFeed} from "../../contracts/interfaces/IPoRFeed.sol";
import {IASSETS} from "../../contracts/interfaces/IASSETS.sol";
import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
/**
 * @title LendefiPoRFeedTest
 * @notice Comprehensive test suite for LendefiPoRFeed contract
 * @dev Tests all functions, error cases, and edge conditions for complete coverage
 */

contract LendefiPoRFeedTest is BasicDeploy {
    using Clones for address;

    LendefiPoRFeed public porFeed;
    TokenMock public testToken;

    // Test addresses
    address public testUpdater = address(0x100);
    address public testOwner = address(0x200);
    address public newUpdater = address(0x300);
    address public newOwner = address(0x400);

    // Events to test
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event UpdaterChanged(address indexed previousUpdater, address indexed newUpdater);
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);
    event ReservesUpdated(uint80 roundId, int256 amount);

    function setUp() public {
        // Deploy test token
        testToken = new TokenMock("Test Token", "TEST");

        // Deploy PoR feed
        porFeed = new LendefiPoRFeed();

        // Initialize the feed
        porFeed.initialize(address(testToken), testUpdater, testOwner);
    }

    // ========== INITIALIZATION TESTS ==========

    function test_Initialize() public {
        assertEq(porFeed.asset(), address(testToken), "Asset should be set correctly");
        assertEq(porFeed.updater(), testUpdater, "Updater should be set correctly");
        assertEq(porFeed.owner(), testOwner, "Owner should be set correctly");
        assertEq(porFeed.latestRoundId(), 1, "Latest round ID should be 1");

        // Check initial round data
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            porFeed.latestRoundData();
        assertEq(roundId, 1, "Initial round ID should be 1");
        assertEq(answer, 0, "Initial answer should be 0");
        assertEq(answeredInRound, 1, "Initial answered in round should be 1");
        assertGt(startedAt, 0, "Started at should be set");
        assertGt(updatedAt, 0, "Updated at should be set");
    }

    function test_Revert_Initialize_ZeroAsset() public {
        LendefiPoRFeed newFeed = new LendefiPoRFeed();

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        newFeed.initialize(address(0), testUpdater, testOwner);
    }

    function test_Revert_Initialize_ZeroUpdater() public {
        LendefiPoRFeed newFeed = new LendefiPoRFeed();

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        newFeed.initialize(address(testToken), address(0), testOwner);
    }

    function test_Revert_Initialize_ZeroOwner() public {
        LendefiPoRFeed newFeed = new LendefiPoRFeed();

        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        newFeed.initialize(address(testToken), testUpdater, address(0));
    }

    function test_Revert_Initialize_Twice() public {
        vm.expectRevert();
        porFeed.initialize(address(testToken), testUpdater, testOwner);
    }

    /*
    @notice Test cloning the PoR feed and initializing it
    @dev This tests that the clone can be initialized correctly
    @dev It also checks that trying to initialize a clone twice reverts
    The test is demonstrating that clones
    maintain independent storage
    state even when created from an
    already-initialized implementation.
    */
    function test_Revert_Initialize_Clone_Twice() public {
        address newPorFeedAddr = Clones.clone(address(porFeed));
        // Verify clone was successful
        if (newPorFeedAddr == address(0)) revert IASSETS.CloneDeploymentFailed();
        if (newPorFeedAddr.code.length == 0) revert IASSETS.CloneDeploymentFailed();
        // Initialize the clone from already initialized implementation
        IPoRFeed(newPorFeedAddr).initialize(address(testToken), testUpdater, testOwner);

        vm.expectRevert(abi.encodeWithSignature("InvalidInitialization()"));
        IPoRFeed(newPorFeedAddr).initialize(address(testToken), testUpdater, testOwner);
    }

    // ========== UPDATE ANSWER TESTS ==========

    function test_UpdateAnswer() public {
        uint80 roundId = 2;
        int256 answer = 1000e18;

        vm.prank(testUpdater);
        vm.expectEmit(true, true, false, true);
        emit AnswerUpdated(answer, roundId, block.timestamp);
        porFeed.updateAnswer(roundId, answer);

        assertEq(porFeed.latestRoundId(), roundId, "Latest round ID should be updated");

        // Verify round data
        (uint80 returnedRoundId, int256 returnedAnswer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            porFeed.getRoundData(roundId);
        assertEq(returnedRoundId, roundId, "Round ID should match");
        assertEq(returnedAnswer, answer, "Answer should match");
        assertEq(answeredInRound, roundId, "Answered in round should match");
        assertEq(startedAt, block.timestamp, "Started at should be current timestamp");
        assertEq(updatedAt, block.timestamp, "Updated at should be current timestamp");
    }

    function test_Revert_UpdateAnswer_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.updateAnswer(2, 1000e18);
    }

    function test_Revert_UpdateAnswer_InvalidRoundId() public {
        // Try to use same round ID
        vm.prank(testUpdater);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoundId()"));
        porFeed.updateAnswer(1, 1000e18);

        // Try to use lower round ID
        vm.prank(testUpdater);
        vm.expectRevert(abi.encodeWithSignature("InvalidRoundId()"));
        porFeed.updateAnswer(0, 1000e18);
    }

    function test_UpdateAnswer_MultipleRounds() public {
        uint80 roundId2 = 2;
        int256 answer2 = 1000e18;

        uint80 roundId3 = 5; // Skip some round IDs
        int256 answer3 = 2000e18;

        // First update
        vm.prank(testUpdater);
        porFeed.updateAnswer(roundId2, answer2);

        // Second update
        vm.prank(testUpdater);
        porFeed.updateAnswer(roundId3, answer3);

        assertEq(porFeed.latestRoundId(), roundId3, "Latest round ID should be updated to 5");

        // Verify both rounds exist
        (, int256 answer2Retrieved,,,) = porFeed.getRoundData(roundId2);
        (, int256 answer3Retrieved,,,) = porFeed.getRoundData(roundId3);

        assertEq(answer2Retrieved, answer2, "Round 2 answer should be preserved");
        assertEq(answer3Retrieved, answer3, "Round 5 answer should be correct");
    }

    // ========== UPDATE RESERVES TESTS ==========

    function test_UpdateReserves() public {
        uint256 reserveAmount = 5000e18;

        vm.prank(testUpdater);
        vm.expectEmit(true, true, false, true);
        emit ReservesUpdated(2, int256(reserveAmount));
        porFeed.updateReserves(reserveAmount);

        assertEq(porFeed.latestRoundId(), 2, "Latest round ID should be incremented to 2");

        // Verify round data
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            porFeed.latestRoundData();
        assertEq(roundId, 2, "Round ID should be 2");
        assertEq(answer, int256(reserveAmount), "Answer should match reserve amount");
        assertEq(answeredInRound, 2, "Answered in round should be 2");
        assertEq(startedAt, block.timestamp, "Started at should be current timestamp");
        assertEq(updatedAt, block.timestamp, "Updated at should be current timestamp");
    }

    function test_Revert_UpdateReserves_Unauthorized() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.updateReserves(1000e18);
    }

    function test_UpdateReserves_Sequential() public {
        uint256 amount1 = 1000e18;
        uint256 amount2 = 2000e18;
        uint256 amount3 = 1500e18;

        // First update
        vm.prank(testUpdater);
        porFeed.updateReserves(amount1);
        assertEq(porFeed.latestRoundId(), 2, "Should be round 2");

        // Second update
        vm.prank(testUpdater);
        porFeed.updateReserves(amount2);
        assertEq(porFeed.latestRoundId(), 3, "Should be round 3");

        // Third update
        vm.prank(testUpdater);
        porFeed.updateReserves(amount3);
        assertEq(porFeed.latestRoundId(), 4, "Should be round 4");

        // Verify latest data
        (, int256 latestAnswer,,,) = porFeed.latestRoundData();
        assertEq(latestAnswer, int256(amount3), "Latest answer should be the last update");
    }

    // ========== MANAGEMENT FUNCTION TESTS ==========

    function test_SetUpdater() public {
        vm.prank(testOwner);
        vm.expectEmit(true, true, false, true);
        emit UpdaterChanged(testUpdater, newUpdater);
        porFeed.setUpdater(newUpdater);

        assertEq(porFeed.updater(), newUpdater, "Updater should be changed");

        // Verify new updater can update
        vm.prank(newUpdater);
        porFeed.updateReserves(1000e18);
        assertEq(porFeed.latestRoundId(), 2, "New updater should be able to update");

        // Verify old updater cannot update
        vm.prank(testUpdater);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.updateReserves(2000e18);
    }

    function test_Revert_SetUpdater_Unauthorized() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.setUpdater(newUpdater);
    }

    function test_Revert_SetUpdater_ZeroAddress() public {
        vm.prank(testOwner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        porFeed.setUpdater(address(0));
    }

    function test_TransferOwnership() public {
        vm.prank(testOwner);
        vm.expectEmit(true, true, false, true);
        emit OwnershipTransferred(testOwner, newOwner);
        porFeed.transferOwnership(newOwner);

        assertEq(porFeed.owner(), newOwner, "Owner should be changed");

        // Verify new owner can set updater
        vm.prank(newOwner);
        porFeed.setUpdater(newUpdater);
        assertEq(porFeed.updater(), newUpdater, "New owner should be able to set updater");

        // Verify old owner cannot set updater
        vm.prank(testOwner);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.setUpdater(address(0x500));
    }

    function test_Revert_TransferOwnership_Unauthorized() public {
        vm.prank(charlie);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.transferOwnership(newOwner);
    }

    function test_Revert_TransferOwnership_ZeroAddress() public {
        vm.prank(testOwner);
        vm.expectRevert(abi.encodeWithSignature("ZeroAddress()"));
        porFeed.transferOwnership(address(0));
    }

    // ========== AGGREGATOR INTERFACE TESTS ==========

    function test_GetRoundData() public {
        // Update to create round 2
        uint80 roundId = 2;
        int256 answer = 1000e18;

        vm.prank(testUpdater);
        porFeed.updateAnswer(roundId, answer);

        // Test getRoundData
        (uint80 returnedRoundId, int256 returnedAnswer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            porFeed.getRoundData(roundId);

        assertEq(returnedRoundId, roundId, "Round ID should match");
        assertEq(returnedAnswer, answer, "Answer should match");
        assertEq(answeredInRound, roundId, "Answered in round should match");
        assertGt(startedAt, 0, "Started at should be set");
        assertGt(updatedAt, 0, "Updated at should be set");
    }

    function test_Revert_GetRoundData_NonExistent() public {
        vm.expectRevert("Round does not exist");
        porFeed.getRoundData(999);
    }

    function test_LatestRoundData() public {
        // Update to create new latest round
        uint256 reserveAmount = 5000e18;
        vm.prank(testUpdater);
        porFeed.updateReserves(reserveAmount);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            porFeed.latestRoundData();

        assertEq(roundId, 2, "Round ID should be 2");
        assertEq(answer, int256(reserveAmount), "Answer should match");
        assertEq(answeredInRound, 2, "Answered in round should be 2");
        assertGt(startedAt, 0, "Started at should be set");
        assertGt(updatedAt, 0, "Updated at should be set");
    }

    function test_Decimals() public {
        // Test with normal token (should return token decimals)
        uint8 feedDecimals = porFeed.decimals();
        uint8 tokenDecimals = testToken.decimals();
        assertEq(feedDecimals, tokenDecimals, "Should return token decimals");
    }

    function test_Decimals_Fallback() public {
        // Create a feed with a contract that doesn't have decimals()
        LendefiPoRFeed newFeed = new LendefiPoRFeed();
        newFeed.initialize(address(this), testUpdater, testOwner); // Use this contract as asset (no decimals function)

        uint8 feedDecimals = newFeed.decimals();
        assertEq(feedDecimals, 18, "Should fallback to 18 decimals");
    }

    function test_Description() public {
        string memory desc = porFeed.description();
        string memory expected = string(abi.encodePacked("Lendefi Protocol Reserves for ", testToken.symbol()));
        assertEq(desc, expected, "Description should include token symbol");
    }

    function test_Version() public {
        uint256 ver = porFeed.version();
        assertEq(ver, 3, "Version should be 3 for AggregatorV3Interface");
    }

    // ========== EDGE CASE TESTS ==========

    function test_UpdateAnswer_LargeRoundIdGap() public {
        // Jump to a very large round ID
        uint80 largeRoundId = type(uint80).max;
        int256 answer = 1000e18;

        vm.prank(testUpdater);
        porFeed.updateAnswer(largeRoundId, answer);

        assertEq(porFeed.latestRoundId(), largeRoundId, "Should handle large round ID");

        (, int256 retrievedAnswer,,,) = porFeed.getRoundData(largeRoundId);
        assertEq(retrievedAnswer, answer, "Answer should be stored correctly");
    }

    function test_UpdateReserves_LargeAmount() public {
        // Test with maximum uint256 that fits in int256
        uint256 largeAmount = uint256(type(int256).max);

        vm.prank(testUpdater);
        porFeed.updateReserves(largeAmount);

        (, int256 answer,,,) = porFeed.latestRoundData();
        assertEq(answer, int256(largeAmount), "Should handle large amounts");
    }

    function test_UpdateAnswer_NegativeValue() public {
        int256 negativeAnswer = -1000e18;

        vm.prank(testUpdater);
        porFeed.updateAnswer(2, negativeAnswer);

        (, int256 answer,,,) = porFeed.getRoundData(2);
        assertEq(answer, negativeAnswer, "Should handle negative values");
    }

    function test_Mixed_UpdateMethods() public {
        // Mix updateAnswer and updateReserves calls
        vm.startPrank(testUpdater);

        // Use updateAnswer for round 2
        porFeed.updateAnswer(2, 1000e18);
        assertEq(porFeed.latestRoundId(), 2, "Should be round 2");

        // Use updateReserves (should increment to round 3)
        porFeed.updateReserves(2000e18);
        assertEq(porFeed.latestRoundId(), 3, "Should be round 3");

        // Use updateAnswer for round 5 (skip round 4)
        porFeed.updateAnswer(5, 3000e18);
        assertEq(porFeed.latestRoundId(), 5, "Should be round 5");

        // Use updateReserves (should increment to round 6)
        porFeed.updateReserves(4000e18);
        assertEq(porFeed.latestRoundId(), 6, "Should be round 6");

        vm.stopPrank();

        // Verify all rounds exist with correct data
        (, int256 answer2,,,) = porFeed.getRoundData(2);
        (, int256 answer3,,,) = porFeed.getRoundData(3);
        (, int256 answer5,,,) = porFeed.getRoundData(5);
        (, int256 answer6,,,) = porFeed.getRoundData(6);

        assertEq(answer2, 1000e18, "Round 2 should be correct");
        assertEq(answer3, 2000e18, "Round 3 should be correct");
        assertEq(answer5, 3000e18, "Round 5 should be correct");
        assertEq(answer6, 4000e18, "Round 6 should be correct");

        // Round 4 should not exist
        vm.expectRevert("Round does not exist");
        porFeed.getRoundData(4);
    }

    function test_LatestRoundData_EmptyFeed() public {
        // Create new feed and check that latestRoundData works immediately after initialization
        LendefiPoRFeed newFeed = new LendefiPoRFeed();
        newFeed.initialize(address(testToken), testUpdater, testOwner);

        (uint80 roundId, int256 answer,,,) = newFeed.latestRoundData();
        assertEq(roundId, 1, "Should have initial round");
        assertEq(answer, 0, "Initial answer should be 0");
    }

    function test_Ownership_Chain() public {
        address owner2 = address(0x600);
        address owner3 = address(0x700);

        // Transfer from testOwner to owner2
        vm.prank(testOwner);
        porFeed.transferOwnership(owner2);
        assertEq(porFeed.owner(), owner2, "Should transfer to owner2");

        // Transfer from owner2 to owner3
        vm.prank(owner2);
        porFeed.transferOwnership(owner3);
        assertEq(porFeed.owner(), owner3, "Should transfer to owner3");

        // Verify only owner3 can manage now
        vm.prank(owner3);
        porFeed.setUpdater(newUpdater);
        assertEq(porFeed.updater(), newUpdater, "Owner3 should be able to set updater");

        // Verify previous owners cannot manage
        vm.prank(testOwner);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.setUpdater(address(0x800));

        vm.prank(owner2);
        vm.expectRevert(abi.encodeWithSignature("Unauthorized()"));
        porFeed.setUpdater(address(0x800));
    }
}
