// SPDX-License-Identifier: MIT
pragma solidity 0.8.23;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../vendor/@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

/**
 * @title LendefiPoRFeed
 * @notice Proof of Reserves feed implementing Chainlink's AggregatorV3Interface for the Lendefi protocol
 * @dev This contract provides a standardized way to track and expose reserve data for specific assets
 *      within the Lendefi lending protocol. It implements Chainlink's AggregatorV3Interface to ensure
 *      compatibility with existing DeFi infrastructure and oracle consumers.
 *
 *      Key features:
 *      - Chainlink AggregatorV3Interface compliance for seamless integration
 *      - Round-based data storage with historical tracking capabilities
 *      - Role-based access control with owner and updater permissions
 *      - Automatic asset metadata integration (decimals, symbol)
 *      - Real-time reserve tracking and transparency
 *
 *      The contract serves as a bridge between Lendefi's internal reserve tracking
 *      and external consumers requiring standardized oracle data feeds.
 */
contract LendefiPoRFeed is AggregatorV3Interface, Initializable {
    /**
     * @notice Data structure representing a single round of reserve reporting
     * @dev Stores all relevant information for a specific reserve update, following
     *      Chainlink's data model for consistent oracle behavior
     * @param answer The reserve or supply value reported in this round (typically in base units)
     * @param startedAt Timestamp when this round was initiated
     * @param updatedAt Timestamp when this round data was last updated
     * @param answeredInRound The round ID in which this answer was computed
     */
    struct Round {
        int256 answer; // Reserve or supply value (e.g., USD in escrow or TUSD total supply)
        uint256 startedAt; // Timestamp when the round started
        uint256 updatedAt; // Timestamp when the round was updated
        uint80 answeredInRound; // Round ID when the answer was computed
    }

    // ========== STATE VARIABLES ==========

    /// @notice Address of the ERC20 asset for which reserves are being tracked
    /// @dev Used to determine decimals and symbol for the feed description
    address public asset;

    /// @notice Address authorized to update reserve data in this feed
    /// @dev Typically set to the LendefiMarketVault contract for automated updates
    address public updater;

    /// @notice Address of the contract owner with administrative privileges
    /// @dev Can change the updater address and transfer ownership
    address public owner;

    /// @notice Mapping of round IDs to their corresponding round data
    /// @dev Provides historical tracking of all reserve updates
    mapping(uint80 => Round) private rounds;

    /// @notice The most recent round ID that has been used
    /// @dev Increments with each new reserve update, ensures unique round identification
    uint80 public latestRoundId;

    // ========== EVENTS ==========

    /**
     * @notice Emitted when contract ownership is transferred to a new address
     * @param previousOwner Address of the previous owner
     * @param newOwner Address of the new owner
     */
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    /**
     * @notice Emitted when the authorized updater address is changed
     * @param previousUpdater Address of the previous updater
     * @param newUpdater Address of the new updater
     */
    event UpdaterChanged(address indexed previousUpdater, address indexed newUpdater);

    /**
     * @notice Emitted when reserve data is updated via updateAnswer function
     * @param current The new reserve value that was set
     * @param roundId The round ID associated with this update
     * @param updatedAt Timestamp when the update occurred
     */
    event AnswerUpdated(int256 indexed current, uint256 indexed roundId, uint256 updatedAt);

    /**
     * @notice Emitted when reserves are updated via updateReserves function
     * @param roundId The round ID associated with this reserve update
     * @param amount The new reserve amount that was set
     */
    event ReservesUpdated(uint80 roundId, int256 amount);

    // ========== ERRORS ==========

    /// @notice Thrown when a caller lacks the required authorization for an operation
    error Unauthorized();

    /// @notice Thrown when a required address parameter is the zero address
    error ZeroAddress();

    /// @notice Thrown when attempting to access data for a non-existent round
    error RoundNotAvailable();

    /// @notice Thrown when an invalid round ID is provided (e.g., not greater than current)
    error InvalidRoundId();

    // ========== INITIALIZATION ==========

    /**
     * @notice Initializes the Proof of Reserves feed with essential parameters
     * @dev Sets up the feed with the tracked asset, authorized updater, and owner.
     *      Creates the initial round (ID 1) with zero reserves to establish the
     *      data structure. This function can only be called once during deployment.
     * @param _asset Address of the ERC20 token whose reserves will be tracked
     * @param _updater Address authorized to update reserve data (typically a vault contract)
     * @param _owner Address that will own this contract and manage permissions
     *
     * @custom:requirements
     *   - All address parameters must be non-zero
     *   - Function can only be called once during deployment
     *
     * @custom:state-changes
     *   - Sets asset, updater, and owner addresses
     *   - Initializes latestRoundId to 1
     *   - Creates initial round with zero reserves and current timestamp
     *
     * @custom:access-control Only callable during contract initialization
     * @custom:error-cases
     *   - ZeroAddress: When any required address parameter is zero
     *
     * @custom:initialization-pattern Uses OpenZeppelin's Initializable for proxy safety
     */
    function initialize(address _asset, address _updater, address _owner) external initializer {
        if (_asset == address(0) || _updater == address(0) || _owner == address(0)) {
            revert ZeroAddress();
        }

        asset = _asset;
        updater = _updater;
        owner = _owner;

        // Initialize with round ID 1
        latestRoundId = 1;
        uint256 timestamp = block.timestamp;
        rounds[latestRoundId] = Round({answer: 0, startedAt: timestamp, updatedAt: timestamp, answeredInRound: 1});
    }
    // ========== UPDATE FUNCTIONS ==========

    /**
     * @notice Updates the feed with reserve data for a specific round ID
     * @dev Allows manual control over round IDs for precise data management.
     *      The provided round ID must be greater than the current latestRoundId
     *      to ensure chronological ordering of updates.
     * @param _roundId The round ID to use for this update (must be > latestRoundId)
     * @param _answer The reserve value to record for this round
     *
     * @custom:requirements
     *   - Caller must be the authorized updater
     *   - _roundId must be greater than the current latestRoundId
     *
     * @custom:state-changes
     *   - Updates latestRoundId to the provided _roundId
     *   - Creates new Round entry with current timestamp
     *   - Records the reserve value in the rounds mapping
     *
     * @custom:emits AnswerUpdated event with the new reserve data
     * @custom:access-control Restricted to the updater address
     * @custom:error-cases
     *   - Unauthorized: When caller is not the updater
     *   - InvalidRoundId: When _roundId is not greater than latestRoundId
     */
    function updateAnswer(uint80 _roundId, int256 _answer) external {
        if (msg.sender != updater) revert Unauthorized();
        if (_roundId <= latestRoundId) revert InvalidRoundId();

        uint256 timestamp = block.timestamp;

        // Update round data
        latestRoundId = _roundId;
        rounds[_roundId] =
            Round({answer: _answer, startedAt: timestamp, updatedAt: timestamp, answeredInRound: _roundId});

        emit AnswerUpdated(_answer, _roundId, timestamp);
    }

    /**
     * @notice Updates the reserve amount using auto-incremented round IDs
     * @dev Provides a simplified interface for regular reserve updates by automatically
     *      incrementing the round ID. This is the primary function used by automated
     *      systems like Chainlink Automation for periodic updates.
     * @param reserveAmount Current reserve amount of the tracked asset
     *
     * @custom:requirements
     *   - Caller must be the authorized updater
     *   - reserveAmount will be cast to int256 (must fit within int256 range)
     *
     * @custom:state-changes
     *   - Increments latestRoundId by 1
     *   - Creates new Round entry with current timestamp
     *   - Records the reserve amount in the rounds mapping
     *
     * @custom:emits ReservesUpdated event with the round ID and reserve amount
     * @custom:access-control Restricted to the updater address
     * @custom:error-cases
     *   - Unauthorized: When caller is not the updater
     *
     * @custom:automation This function is typically called by automated systems
     */
    function updateReserves(uint256 reserveAmount) external {
        if (msg.sender != updater) revert Unauthorized();

        // Create new round
        latestRoundId++;
        uint256 timestamp = block.timestamp;

        // Store round data
        rounds[latestRoundId] = Round({
            answer: int256(reserveAmount),
            startedAt: timestamp,
            updatedAt: timestamp,
            answeredInRound: latestRoundId
        });

        emit ReservesUpdated(latestRoundId, int256(reserveAmount));
    }

    // ========== MANAGEMENT FUNCTIONS ==========

    /**
     * @notice Updates the authorized updater address
     * @dev Allows the owner to change which address can update reserve data.
     *      This is useful for changing from manual updates to automated systems
     *      or updating the automation contract address.
     * @param newUpdater Address of the new authorized updater
     *
     * @custom:requirements
     *   - Caller must be the contract owner
     *   - newUpdater must not be the zero address
     *
     * @custom:state-changes
     *   - Updates the updater state variable to newUpdater
     *
     * @custom:emits UpdaterChanged event with old and new updater addresses
     * @custom:access-control Restricted to the owner address
     * @custom:error-cases
     *   - Unauthorized: When caller is not the owner
     *   - ZeroAddress: When newUpdater is the zero address
     */
    function setUpdater(address newUpdater) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newUpdater == address(0)) revert ZeroAddress();

        address oldUpdater = updater;
        updater = newUpdater;

        emit UpdaterChanged(oldUpdater, newUpdater);
    }

    /**
     * @notice Transfers ownership of the contract to a new address
     * @dev Permanently transfers all owner privileges to the specified address.
     *      The new owner will have full control over updater management and
     *      can transfer ownership again if needed.
     * @param newOwner Address of the new contract owner
     *
     * @custom:requirements
     *   - Caller must be the current contract owner
     *   - newOwner must not be the zero address
     *
     * @custom:state-changes
     *   - Updates the owner state variable to newOwner
     *
     * @custom:emits OwnershipTransferred event with old and new owner addresses
     * @custom:access-control Restricted to the current owner address
     * @custom:error-cases
     *   - Unauthorized: When caller is not the current owner
     *   - ZeroAddress: When newOwner is the zero address
     *
     * @custom:security-warning This action is irreversible, ensure newOwner is correct
     */
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert Unauthorized();
        if (newOwner == address(0)) revert ZeroAddress();

        address oldOwner = owner;
        owner = newOwner;

        emit OwnershipTransferred(oldOwner, newOwner);
    }

    // ========== AGGREGATOR INTERFACE IMPLEMENTATION ==========

    /**
     * @notice Retrieves data for a specific historical round
     * @dev Implements Chainlink's AggregatorV3Interface for compatibility with
     *      existing oracle consumers and DeFi protocols that expect this interface.
     * @param _roundId The round ID to query for historical data
     * @return roundId The requested round ID (echoed back)
     * @return answer The reserve value recorded in this round
     * @return startedAt Timestamp when this round was initiated
     * @return updatedAt Timestamp when this round was last updated
     * @return answeredInRound The round ID in which this answer was computed
     *
     * @custom:requirements
     *   - The specified round must exist (have been created previously)
     *
     * @custom:chainlink-compatibility Implements AggregatorV3Interface.getRoundData()
     * @custom:access-control Available to any caller (view function)
     * @custom:error-cases
     *   - Reverts with "Round does not exist" when _roundId has no data
     */
    function getRoundData(uint80 _roundId)
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory round = rounds[_roundId];
        require(round.updatedAt > 0, "Round does not exist");
        return (_roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    /**
     * @notice Retrieves the most recent round data
     * @dev Implements Chainlink's AggregatorV3Interface to provide current reserve
     *      information. This is typically the most frequently called function by
     *      external consumers requiring current reserve data.
     * @return roundId The latest round ID
     * @return answer The most recent reserve value
     * @return startedAt Timestamp when the latest round was initiated
     * @return updatedAt Timestamp when the latest round was last updated
     * @return answeredInRound The round ID in which this answer was computed
     *
     * @custom:requirements
     *   - At least one round of data must exist
     *
     * @custom:chainlink-compatibility Implements AggregatorV3Interface.latestRoundData()
     * @custom:access-control Available to any caller (view function)
     * @custom:error-cases
     *   - Reverts with "No data available" when no rounds have been created
     */
    function latestRoundData()
        external
        view
        override
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        Round memory round = rounds[latestRoundId];
        require(round.updatedAt > 0, "No data available");
        return (latestRoundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }

    /**
     * @notice Returns the number of decimals used by this feed
     * @dev Attempts to match the decimals of the tracked asset for consistency.
     *      If the asset's decimals() function is not available or fails, defaults to 18.
     *      This ensures reserve values are interpreted with the correct precision.
     * @return The number of decimals (typically matching the tracked asset)
     *
     * @custom:chainlink-compatibility Implements AggregatorV3Interface.decimals()
     * @custom:fallback Returns 18 decimals if asset decimals cannot be determined
     * @custom:access-control Available to any caller (view function)
     */
    function decimals() external view override returns (uint8) {
        try IERC20Metadata(asset).decimals() returns (uint8 assetDecimals) {
            return assetDecimals;
        } catch {
            return 18;
        }
    }

    /**
     * @notice Provides a human-readable description of this feed
     * @dev Generates a descriptive string that includes the asset symbol for clarity.
     *      The description helps users and interfaces understand what reserves are being tracked.
     * @return A string describing this feed (e.g., "Lendefi Protocol Reserves for USDC")
     *
     * @custom:chainlink-compatibility Implements AggregatorV3Interface.description()
     * @custom:format "Lendefi Protocol Reserves for {SYMBOL}" or "Lendefi Protocol Reserves for UNKNOWN"
     * @custom:fallback Uses "UNKNOWN" if asset symbol cannot be determined
     * @custom:access-control Available to any caller (view function)
     */
    function description() external view override returns (string memory) {
        string memory symbol = IERC20Metadata(asset).symbol();
        return string(abi.encodePacked("Lendefi Protocol Reserves for ", symbol));
    }

    /**
     * @notice Returns the version of the Aggregator interface implemented
     * @dev Indicates compliance with AggregatorV3Interface (version 3).
     *      This helps consumers understand the interface version and available functionality.
     * @return The version number (3 for AggregatorV3Interface)
     *
     * @custom:chainlink-compatibility Implements AggregatorV3Interface.version()
     * @custom:constant Always returns 3 for AggregatorV3Interface compliance
     * @custom:access-control Available to any caller (pure function)
     */
    function version() external pure override returns (uint256) {
        return 3; // AggregatorV3Interface
    }
}
