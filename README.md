# Lendefi Protocol

```
  ═══════════[ Composable Lending Markets ]═══════════

  ██╗     ███████╗███╗   ██╗██████╗ ███████╗███████╗██╗
  ██║     ██╔════╝████╗  ██║██╔══██╗██╔════╝██╔════╝██║
  ██║     █████╗  ██╔██╗ ██║██║  ██║█████╗  █████╗  ██║
  ██║     ██╔══╝  ██║╚██╗██║██║  ██║██╔══╝  ██╔══╝  ██║
  ███████╗███████╗██║ ╚████║██████╔╝███████╗██║     ██║
  ╚══════╝╚══════╝╚═╝  ╚═══╝╚═════╝ ╚══════╝╚═╝     ╚═╝

  ═══════════[ Composable Lending Markets ]═══════════
```

## Composable Lending Markets Protocol

## Executive Summary

The Lendefi Protocol represents a next-generation composable lending infrastructure that enables the creation of independent, isolated lending markets for different base assets in a permissionless manner. Unlike traditional monolithic lending protocols, Lendefi implements a factory-based architecture where each market operates as an autonomous lending pool with its own base asset, liquidity providers, and risk parameters. This design enables unprecedented flexibility, scalability, and risk isolation while maintaining the sophisticated features expected from modern DeFi protocols.

For more information visit [Lendefi Markets](https://lendefimarkets.com).

## Architecture & Design

### Composable Market Architecture

The protocol's revolutionary architecture centers around composable lending markets, each functioning as an independent lending ecosystem:

- **Market Factory Pattern**: The `LendefiMarketFactory` deploys and manages multiple lending markets, each with its own base asset (USDC, DAI, USDT, etc.)
- **Isolated Liquidity Pools**: Each market maintains completely separate liquidity, preventing contagion between different base assets
- **Market-Specific Components**: Every market consists of:
  - **LendefiCore**: Manages positions and collateral, calculates borrow rates based on utilization and risk tiers
  - **LendefiMarketVault**: Manages liquidity for lenders, calculates supply rates, handles deposits/withdrawals with protocol PoR
  - **LendefiAssets**: Manages collateral asset configuration, price oracles, and collateral-specific PoR feeds
  - **Position Vaults**: Created by LendefiCore as minimal proxies to isolate each user's collateral

### Key Architectural Benefits

1. **Risk Isolation**: Issues in one market cannot affect liquidity or solvency in other markets
2. **Flexible Deployment**: New markets can be created for any ERC-20 asset without affecting existing markets
3. **Customizable Parameters**: Each market can have unique risk parameters, interest models, and collateral requirements
4. **Scalable Infrastructure**: The factory pattern enables unlimited market creation without protocol complexity
5. **Regulatory Compliance**: Market isolation facilitates compliance with jurisdiction-specific requirements

## Core Features

### Multi-Market Ecosystem

- **Independent Markets**: Each base asset (USDC, DAI, USDT, etc.) operates its own lending market
- **Cross-Market Collateral**: Users can use collateral from any whitelisted asset across different markets
- **Market-Specific Yield Tokens**: Each market issues its own ERC-4626 yield-bearing tokens to liquidity providers
- **Market-Specific Asset Modules**: Each market has its own asset configuration module for independent risk management
- **Automated Proof of Reserve**: Chainlink Automation ensures real-time PoR updates for each market

### Advanced Risk Management

The protocol implements a sophisticated multi-tier risk framework that applies across all markets:

- **Four Collateral Tiers**:

  - STABLE: Blue-chip stablecoins (1% liquidation bonus)
  - CROSS_A: Low-risk assets (2% liquidation bonus)
  - CROSS_B: Medium-risk assets (3% liquidation bonus)
  - ISOLATED: High-risk or new assets (4% liquidation bonus)

- **Position Types**:
  - **Cross-Collateral Positions**: Mix up to 20 different assets as collateral
  - **Isolated Positions**: Single-asset collateral for higher-risk assets
  - **Market-Agnostic Collateral**: Use any whitelisted asset as collateral in any market

### Isolated Position Vaults

Every position across all markets utilizes dedicated vault contracts:

- Complete asset segregation per position
- Direct liquidation transfers from vault to liquidator
- Enhanced security through position-level isolation
- Regulatory compliance through technical asset segregation
- Protection from cross-position vulnerabilities
- Optimized initialization with owner set during deployment
- Gas-efficient minimal proxy pattern for vault creation

## Market Creation & Management

### Market Factory

The `LendefiMarketFactory` serves as the protocol's deployment hub:

```solidity
// Create a new USD1 lending market
factory.createMarket(
    USD1_ADDRESS,
    "Lendefi USD1 Market",
    "mUSD1"
);
```

Each market deployment includes:

- Upgradeable LendefiCore contract (UUPS proxy) with position vault creation logic
- ERC-4626 compliant LendefiMarketVault with Chainlink Automation for protocol PoR
- Market-specific LendefiAssets module with collateral asset PoR feeds
- Position vault implementation template for cloning user vaults

### Market Lifecycle

1. **Deployment**: Anyone can create new markets via permissionless factory (with governance token requirements)
2. **Initialization**: Market components are deployed and linked automatically
3. **Configuration**: Risk parameters and collateral assets are configured by market creators
4. **Operation**: Users can supply liquidity, borrow, and manage positions
5. **Upgrades**: Individual markets can be upgraded without affecting others

### Permissionless Market Creation

The protocol now features **permissionless market creation**, enabling anyone to deploy new lending markets:

#### Requirements for Market Creation

- **Governance Token Balance**: Must hold at least 1,000 $LEND tokens
- **Market Creation Fee**: Pay 100 $LEND tokens per market created
- **Rate Limiting**: Maximum 21 markets per address (configurable)
- **Asset Allowlist**: Base asset must be approved by protocol governance

#### Market Creation Process

```solidity
// 1. Ensure you have enough governance tokens
require(govToken.balanceOf(creator) >= 1000 ether, "Insufficient balance");

// 2. Approve the factory to spend creation fee
govToken.approve(address(factory), 100 ether);

// 3. Create market (fee automatically deducted)
factory.createMarket(
    NEW_TOKEN_ADDRESS,
    "Lendefi New Token Market", 
    "lendNEW"
);
```

#### Governance Controls

- **Fee Management**: Protocol can adjust token requirements and fees
- **Asset Approval**: Only pre-approved assets can be used as base assets
- **Rate Limiting**: Prevents spam while allowing legitimate market creation
- **Emergency Pause**: Protocol can pause market creation if needed

#### Economic Incentives

- **Fee Collection**: Creation fees are collected by the protocol treasury
- **Market Ownership**: Creators become market owners with management privileges
- **Revenue Sharing**: Market owners earn fees from their markets' operations
- **Token Utility**: Increases utility and value capture for $LEND token holders

## Technical Implementation

### Smart Contract Architecture

```
LendefiMarketFactory
├── Creates Markets →
│   ├── LendefiCore (User functions)
│   │   ├── Position/Collateral Management
│   │   ├── Borrow Rate Calculations
│   │   ├── Creates Position Vaults
│   │   ├── MEV Protection
│   │   ├── Optimized TVL Tracking
│   │   └── LendefiPositionVault (Clones)
│   │       └── Individual User Vaults
│   ├── LendefiMarketVault (Yield Token)
│   │   ├── ERC-4626 Vault
│   │   ├── Liquidity Management
│   │   ├── Lender Rate Calculations
│   │   ├── Flash Loans (9 bps fee)
│   │   ├── Reward Distribution
│   │   ├── Chainlink Automation Integration
│   │   └── Protocol Collateralization PoR
│   └── LendefiAssets (Asset Management)
│       ├── Chainlink Oracle Integration
│       ├── Uniswap V3 TWAP Fallback
│       ├── Risk Parameters (4 Tiers)
│       ├── Asset Configuration
│       └── Collateral Asset PoR Feeds
└── LendefiView
    └── Read-only Aggregation
```

### Key Components

1. **LendefiMarketFactory**: Deploys and tracks all lending markets with implementation management
2. **LendefiCore**: Handles position/collateral management, calculates borrow rates, creates position vaults for users
3. **LendefiMarketVault**: Manages liquidity pools, calculates lender rates, handles deposits/withdrawals, provides protocol PoR via Chainlink Automation
4. **LendefiAssets**: Market-specific module managing collateral asset configuration, price oracles, and collateral asset PoR feeds
5. **LendefiPositionVault**: Minimal proxy vaults created by LendefiCore for each user position to isolate collateral
6. **LendefiView**: Read-only contract for efficient data aggregation across positions and markets

## Features Across Markets

### Unified Features

1. Support for up to 3000 collateral assets (shared across all markets)
2. Up to 1000 positions per user per market
3. Up to 20 collateral assets per position
4. Automatic interest compounding
5. Gas-efficient operations with optimized TVL tracking
6. Market-specific yield tokens (ERC-4626)
7. Complete upgradeability
8. DAO governance
9. Unified reward ecosystem
10. Flash loan functionality per market
11. MEV protection on all user operations
12. Optimized position creation with single initialization call

### Market-Specific Features

- Independent liquidity pools
- Customizable interest rate models
- Market-specific risk parameters
- Separate Proof of Reserve feeds
- Isolated protocol revenue streams

## Security Features

The protocol implements defense-in-depth security across all markets:

- **Access Control**: Role-based permissions with timelock governance
- **Reentrancy Protection**: Guards on all state-modifying functions
- **Pausability**: Emergency pause per market or protocol-wide
- **Oracle Security**: Multi-oracle support with freshness checks
- **Upgradeable Architecture**: UUPS pattern with version tracking
- **Input Validation**: Comprehensive checks and custom errors
- **MEV Protection**: Same-block operation prevention on deposits, withdrawals, and minting
- **TVL Tracking**: Optimized on-chain TVL updates with gas-efficient storage patterns
- **Slippage Protection**: Built-in slippage checks for all liquidity operations

## Economic Model

### Market-Specific Economics

Each lending market operates with independent economic parameters:

1. **Borrow Rates**: Calculated by LendefiCore based on utilization and collateral tier
2. **Supply Rates**: Calculated by LendefiMarketVault based on utilization and protocol fees
3. **Protocol Revenue**: Market-specific fee capture from spread between borrow and supply rates
4. **Flash Loans**: Configurable fees per market (default 9 bps) handled by MarketVault
5. **Liquidation Incentives**: Tier-based bonuses (1-4%) managed by LendefiCore

### Cross-Market Synergies

- Unified governance token requirements
- Shared collateral configurations
- Consistent risk tiers across markets
- Protocol-wide reward distribution

## Oracle Integration

### Chainlink Price Feeds

- Primary price source for all markets
- Staleness checks (8-hour maximum)
- Volatility monitoring
- Round completion verification

### Proof of Reserve

Two types of PoR feeds per market:

1. **Protocol Collateralization PoR** (LendefiMarketVault):

   - Tracks overall protocol collateralization for the base currency
   - Updated automatically via Chainlink Automation
   - Reports total borrowed vs total supplied

2. **Collateral Asset PoR** (LendefiAssets):
   - Individual PoR feeds for each collateral asset
   - Tracks reserves of specific collateral tokens
   - Used for asset verification and risk management

### Fallback Mechanisms

- Uniswap V3 TWAP as secondary source
- Multi-oracle median pricing
- Deviation thresholds

## Regulatory Compliance

### Market Isolation Benefits

The composable market architecture facilitates compliance:

- **Asset Segregation**: Complete separation between markets
- **Jurisdictional Flexibility**: Markets can be configured for specific regulatory requirements
- **Audit Trail**: Clear separation of funds and operations per market
- **Bankruptcy Remoteness**: Market isolation prevents cross-contamination

### U.S. GENIUS Act Compliance

The protocol's architecture aligns with emerging regulations:

- Technical asset segregation through isolated vaults
- Proof of Reserve integration for transparency
- Clear custody delineation
- Qualified custodian standards through smart contracts

## Getting Started

### Deploying a New Market

```solidity
// Anyone can create markets (permissionless with governance token requirements)
// Ensure you have the required governance tokens and approve spending
IERC20(govToken).approve(address(factory), 100 ether); // Approve creation fee

// Create markets for different base assets (fee automatically deducted)
factory.createMarket(USD1, "Lendefi mUSD1", "mUSD1");
factory.createMarket(DAI, "Lendefi mDAI", "mDAI");
factory.createMarket(USDT, "Lendefi mUSDT", "mUSDT");

// Check your governance token balance and markets created
uint256 balance = IERC20(govToken).balanceOf(msg.sender);
uint256 marketsCreated = factory.marketsCreatedBy(msg.sender);
```

### Using a Market

```solidity
// Get market information
IPROTOCOL.Market memory market = factory.getMarketInfo(USD1);

// Interact with specific market
LendefiCore core = LendefiCore(market.core);
LendefiMarketVault vault = LendefiMarketVault(market.baseVault);
LendefiAssets assets = LendefiAssets(market.assetsModule);

// Supply liquidity to USD1 market with slippage protection
core.depositLiquidity(amount, expectedShares, maxSlippageBps);

// Create position and get position ID
uint256 positionId = core.createPosition(WETH, false); // Returns position ID

// Supply collateral and borrow
core.supplyCollateral(WETH, amount, positionId);
core.borrow(positionId, borrowAmount);

// Mint shares with MEV protection
core.mintShares(sharesAmount, expectedAmount, maxSlippageBps);
```

## Deployed Markets

Track deployed markets and their configurations:

```solidity
// Get all active markets
IPROTOCOL.Market[] memory activeMarkets = factory.getAllActiveMarkets();

// Check market details
IPROTOCOL.Market memory usdcMarket = factory.getMarketInfo(USDC);
```

## Benefits of Composable Architecture

### For Users

- Choose optimal markets for borrowing based on rates
- Isolated risk per market
- Market-specific yield optimization
- Cross-market collateral utilization

### For Liquidity Providers

- Market-specific yield tokens
- Isolated risk exposure
- Choose markets based on risk/reward
- No cross-market contagion

### For Protocol

- Unlimited scalability
- Market-specific optimizations
- Easier regulatory compliance
- Simplified risk management

## Recent Optimizations

The protocol has undergone significant optimizations to improve gas efficiency, user experience, and decentralization:

### Protocol Governance Enhancements

- **Permissionless Market Creation**: Transitioned from admin-only to permissionless market deployment
- **Governance Token Integration**: Added $LEND token requirements and fees for market creation
- **Rate Limiting**: Implemented configurable limits to prevent spam while enabling legitimate use
- **Fee Collection**: Automated governance token fee collection for protocol treasury

### Gas Optimizations

- **TVL Tracking**: Streamlined TVL updates with efficient storage patterns reducing gas costs by ~30%
- **Position Vault Initialization**: Combined core and owner initialization into single call
- **Input Validation**: Optimized validation checks to reduce redundant operations
- **Storage Packing**: Improved struct packing for reduced storage costs

### Security & Access Control

- **Enhanced Pausability**: Added pause controls for market creation during emergencies
- **ReentrancyGuard**: Integrated reentrancy protection across critical functions
- **SafeERC20**: Enhanced token transfer safety with comprehensive error handling
- **Multi-inheritance Security**: Added multiple security layers (Pausable + ReentrancyGuard)

### Feature Enhancements

- **MEV Protection**: Enhanced protection on deposits, withdrawals, and share minting
- **Position Creation**: Now returns position ID directly for better UX
- **Slippage Controls**: Added comprehensive slippage protection across all liquidity operations
- **Upgrade Testing**: Comprehensive upgrade test coverage for all core contracts
- **Chainlink Automation**: Integrated automated Proof of Reserve updates for real-time collateralization reporting
- **Market-Specific Assets**: Each market now has its own asset configuration module for better isolation

## Future Developments

The composable architecture enables:

- Specialized markets (RWA, LST-specific, etc.)
- Cross-chain market deployment
- Market-specific strategies
- Advanced inter-market composability
- Automated market management

## Disclaimer

This software is provided as is with a Business Source License 1.1 without warranties of any kind. Some libraries included with this software are licensed under the MIT license, while others require GPL-v3.0. The smart contracts are labeled accordingly.

## Running Tests

This is a Foundry repository. To get more information visit [Foundry](https://github.com/foundry-rs/foundry/blob/master/foundryup/README.md).

```bash
# Install Foundry
curl -L https://foundry.paradigm.xyz | bash
foundryup

# Clone and setup
git clone https://github.com/LendefiMarkets/lendefi-markets.git
cd lendefi-markets

# Configure environment
echo "ALCHEMY_API_KEY=your_api_key_here" >> .env

# Build and test
npm install
npm run build
npm run test
```
