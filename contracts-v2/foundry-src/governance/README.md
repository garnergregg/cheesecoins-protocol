# Governance Contracts

Production-quality governance contracts for the Cheesecoins DeFi ecosystem with super holder mechanics and founder decentralization.

## Overview

The governance system implements growth-weighted voting with logarithmic scaling to prevent mega-whale dominance while incentivizing project growth. Super holders (those owning complete 100-scene NFT collections) receive enhanced voting power, and the founder undergoes a 5-year decentralization schedule.

## Contracts

### 1. SuperHolderGovernance.sol

**Main governance contract implementing proposal and voting mechanics. Execution routes through ProtocolTimelock.**

#### Key Features
- **Super Holder Requirement**: Must own complete 100-scene NFT collection
- **Proposal System**: Create and vote on governance proposals
- **Voting Period**: 30 days (`Config.GOVERNANCE_VOTING_PERIOD`)
- **Supermajority Threshold**: 66% required for proposal passage (`Config.SUPERMAJORITY_THRESHOLD`)
- **Timelock Routing**: Passed proposals route via `ProtocolTimelock.scheduleBatch()` — internal execute queue permanently disabled
- **Flash Loan Protection**: ReentrancyGuard prevents attack vectors
- **Integration**: Uses GovernanceWeighting for vote power calculation

#### Core Functions
```solidity
// Become super holder by proving complete NFT collection
function becomeSuperHolder(uint256[] memory nftIds) external

// Create governance proposal
function propose(
    string memory description,
    address target,
    bytes memory callData
) external returns (uint256 proposalId)

// Vote on proposal (support = true for yes, false for no)
function vote(uint256 proposalId, bool support) external

// Queue passed proposal to ProtocolTimelock (internal execute() is permanently disabled)
function queueToProtocolTimelock(uint256 proposalId) external

// Atomically cancel governance proposal + timelock operation (CANCELLER_ROLE required)
function cancelTimelockOperation(uint256 proposalId) external

// Get voting power for address
function getVotingPower(address voter) external view returns (uint256)
```

#### Events
- `ProposalCreated(uint256 proposalId, address proposer, string description)`
- `VoteCast(address voter, uint256 proposalId, bool support, uint256 weight)`
- `ProposalExecuted(uint256 proposalId)`
- `SuperHolderCreated(address user, uint256 projectId, uint256 votingPower)`
- `ProposalQueued(uint256 proposalId, uint256 executionTime)`
- `ProposalCanceled(uint256 proposalId, address canceler)`

### 2. GovernanceWeighting.sol

**Calculates voting power using growth-weighted formula with logarithmic scaling.**

#### Formula
```
votingPower = ln(stakedCURD) × projectGrowthRate × superHolderMultiplier(2x)
```

#### Key Features
- **Logarithmic Scaling**: Prevents mega-whale dominance (1M vs 10M stake is only ~2.3x difference)
- **Growth Rate Multiplier**: Fast-growing projects have more influence
- **Super Holder 2x Bonus**: Complete NFT collection doubles voting power (`Config.SUPER_HOLDER_MULTIPLIER`)
- **Annual Recalculation**: Growth rates updated yearly
- **Integration**: Uses MathLibrary.ln() for calculations

#### Core Functions
```solidity
// Calculate voting power for voter
function calculateVotingPower(
    address voter,
    uint256 projectId,
    bool isSuperHolder
) public view returns (uint256 votingPower)

// Get project growth rate (cached or fresh)
function getProjectGrowthRate(uint256 projectId) public view returns (uint256)

// Recalculate growth rates for all projects (annual)
function recalculateGrowthRates() external

// Calculate weighted voting power across multiple stakes
function calculateMultiProjectVotingPower(
    address voter,
    uint256[] memory projectIds,
    bool isSuperHolder
) external view returns (uint256 totalVotingPower)

// Preview voting power for hypothetical stake
function previewVotingPower(
    uint256 stakedAmount,
    uint256 projectId,
    bool isSuperHolder
) external view returns (uint256 votingPower)
```

#### Events
- `GrowthRatesRecalculated(uint256 timestamp, uint256 projectCount)`
- `VotingPowerCalculated(address voter, uint256 votingPower, uint256 stakedAmount, uint256 growthRate, bool isSuperHolder)`

### 3. FounderDecentralization.sol

**Manages 5-year founder decentralization schedule with progressive weight reduction.**

#### Decentralization Schedule
- **Year 1**: 50% governance weight
- **Year 2**: 40% governance weight
- **Year 3**: 30% governance weight
- **Year 4**: 20% governance weight
- **Year 5**: 10% governance weight
- **Year 5+ (Cliff)**: 0% governance weight (converts to regular super holder)

#### Key Features
- **Founder Allocation**: 10M CURD (`Config.FOUNDER_ALLOCATION`)
- **Annual Weight Decrement**: 10% reduction per year (`Config.FOUNDER_WEIGHT_DECREMENT`)
- **Staking Participation**: Founder can stake and earn yields like everyone else
- **Y5 Cliff**: Automatic conversion to regular super holder with equal voting rights
- **Annual Update Mechanism**: Weight decreases automatically each year
- **Emergency Force Cliff**: Founder can manually trigger cliff after Y5

#### Core Functions
```solidity
// Get current year since protocol launch
function getCurrentYear() public view returns (uint256)

// Get founder governance weight based on current year
function getFounderWeight() public view returns (uint256)

// Update founder weight (annual mechanism)
function updateFounderWeight() external

// Force update to Y5 cliff (emergency, founder only)
function forceCliff() external

// Get founder voting power multiplier
function getFounderMultiplier() external view returns (uint256)

// Check if address is founder
function isFounder(address account) external view returns (bool)

// Get decentralization progress
function getDecentralizationStatus() external view returns (
    uint256 year,
    uint256 weight,
    bool isComplete,
    uint256 nextUpdateIn
)

// Calculate founder adjusted voting power
function calculateFounderAdjustedPower(
    address voter,
    uint256 baseVotingPower
) external view returns (uint256)
```

#### Events
- `FounderWeightUpdated(uint256 year, uint256 newWeight, uint256 timestamp)`
- `FounderDecentralizationComplete(address founder, uint256 finalWeight, uint256 timestamp)`
- `AnnualWeightDecrement(uint256 year, uint256 oldWeight, uint256 newWeight)`

## Security Features

### 1. Flash Loan Protection
- **ReentrancyGuard**: Prevents reentrancy attacks on voting and execution
- **Timelock Delay**: 2-day delay prevents same-block execution
- **Vote Snapshot**: Voting power calculated at vote time, not execution

### 2. Access Control
- **Super Holder Restriction**: Only complete NFT collection holders can propose/vote
- **Admin Control**: Proposal cancellation and admin management
- **Founder Restriction**: Certain functions only callable by founder

### 3. Governance Attack Prevention
- **Supermajority Threshold**: 66% required to pass proposals
- **Voting Period**: 30-day window prevents rushed decisions
- **One Vote Per User**: Cannot vote twice on same proposal
- **Logarithmic Scaling**: Prevents mega-whale dominance

### 4. Data Validation
- **ValidationLibrary**: All inputs validated (addresses, amounts, ranges)
- **Config Constants**: All parameters defined in central Config contract
- **Error Handling**: Custom errors for gas-efficient reverts

## Configuration

All parameters are defined in `Config.sol`:

```solidity
// Governance Parameters
uint256 public constant GOVERNANCE_VOTING_PERIOD = 30 days;
uint256 public constant SUPERMAJORITY_THRESHOLD = 66;
uint256 public constant TIMELOCK_DELAY = 2 days;
uint256 public constant SUPER_HOLDER_MULTIPLIER = 2;
uint256 public constant SUPER_HOLDER_REQUIRED_SCENES = 100;

// Founder Parameters
uint256 public constant FOUNDER_ALLOCATION = 10_000_000 * 10**18;
uint256 public constant FOUNDER_DECENTRALIZATION_YEARS = 5;
uint256 public constant FOUNDER_INITIAL_WEIGHT = 50;
uint256 public constant FOUNDER_WEIGHT_DECREMENT = 10;

// Security Parameters
uint256 public constant MAX_PROJECTS_PER_TX = 50;
```

## Deployment

### Deployment Order
1. Deploy `Config.sol` (library)
2. Deploy `MathLibrary.sol` (library)
3. Deploy `ValidationLibrary.sol` (library)
4. Deploy `StakingManager.sol` (dependency)
5. Deploy `ProjectRegistry.sol` (dependency)
6. Deploy `SceneTracker.sol` (required by MaturityOracle)
7. Deploy `GovernanceWeighting.sol` (pass StakingManager, ProjectRegistry)
8. Deploy `FounderDecentralization.sol` (pass founder address)
9. Deploy `ProtocolTimelock` (minDelay, proposers=[founderMultisig], executors=[founderMultisig], cancellers=[guardianMultisig])
10. Deploy `MaturityOracle` (sceneTracker, vault, settlement, T0)
11. Deploy `TransitionCalldataBuilder` (stateless — no constructor args needed)
12. Deploy `SuperHolderGovernance` (governanceWeighting, founderDecentralization, admin, protocolTimelock)

### Phase 5/6 Contracts

#### ProtocolTimelock.sol
- Wraps OZ `TimelockController`; `Config.TIMELOCK_DELAY` minimum enforced
- Explicit `cancellers[]` at deploy (guardian/security-council)
- `admin=address(0)` → self-governed immediately
- All meaningful protocol changes **must** go through this contract

#### MaturityOracle.sol
- `isYear2Eligible()`, `isYear3Eligible()`, `isYear5Eligible()`
- On-chain only: `block.timestamp`, `SceneTracker.superHolderCount`, `lastPauseTimestamp`, vault USDC balance
- Thresholds settable by admin (intended admin: `ProtocolTimelock`)

#### TransitionCalldataBuilder.sol
- Pure/stateless — no roles, no storage
- Returns atomic `scheduleBatch` payloads for each stage transition
- Deterministic salts per transition

#### GovernanceWeightView.sol
- Stateless view over `GovernanceWeighting` + `SceneTracker` + founder decay
- No state, no events — read-only helper for off-chain tooling and UIs

### External Dependencies
- **StakingManager**: Provides staked CURD amounts
- **ProjectRegistry**: Provides project growth rates
- **NFT Contracts**: Validates NFT ownership and scene numbers
- **MathLibrary**: Provides ln() function for logarithmic scaling
- **ValidationLibrary**: Provides input validation helpers

## Usage Examples

### Becoming a Super Holder
```solidity
// Collect all 100 scene NFTs from a project
uint256[] memory nftIds = new uint256[](100);
// ... populate with owned NFT IDs ...

// Become super holder
superHolderGovernance.becomeSuperHolder(nftIds);
```

### Creating a Proposal
```solidity
// Only super holders can create proposals
string memory description = "Increase staking rewards by 5%";
address target = address(stakingManager);
bytes memory callData = abi.encodeWithSignature("updateRewardRate(uint256)", 105);

uint256 proposalId = superHolderGovernance.propose(description, target, callData);
```

### Voting on a Proposal
```solidity
// Vote yes (true) or no (false)
superHolderGovernance.vote(proposalId, true);
```

### Executing a Proposal
```solidity
// After voting period ends and supermajority reached,
// queue the proposal to ProtocolTimelock:
superHolderGovernance.queueToProtocolTimelock(proposalId);
// → calls protocolTimelock.scheduleBatch(...)
// → emits TimelockOperationQueued(proposalId, opId)

// After timelock delay expires, execute directly via ProtocolTimelock:
bytes32 opId = superHolderGovernance.timelockOperationId(proposalId);
protocolTimelock.executeBatch(...); // using the stored opId

// Note: superHolderGovernance.execute(proposalId) reverts InternalQueueDisabled
```

### Checking Voting Power
```solidity
// Get your voting power
uint256 votingPower = superHolderGovernance.getVotingPower(msg.sender);

// Preview voting power for a stake
uint256 projectedPower = governanceWeighting.previewVotingPower(
    1000000 * 10**18, // 1M CURD
    projectId,
    true // is super holder
);
```

### Monitoring Founder Decentralization
```solidity
// Get current decentralization status
(uint256 year, uint256 weight, bool isComplete, uint256 nextUpdateIn) = 
    founderDecentralization.getDecentralizationStatus();

// Update founder weight (once per year)
founderDecentralization.updateFounderWeight();
```

## Testing Considerations

### Test Cases to Implement
1. **Super Holder Creation**: Validate 100 unique scene NFTs
2. **Proposal Creation**: Only super holders, valid parameters
3. **Voting**: Vote weight calculation, duplicate vote prevention
4. **Supermajority**: Test edge cases around 66% threshold
5. **Timelock**: Ensure 2-day delay enforced
6. **Reentrancy**: Attack vectors prevented
7. **Founder Decentralization**: Annual weight updates, cliff trigger
8. **Logarithmic Scaling**: Mega-whale dominance prevention
9. **Growth Rate Updates**: Annual recalculation
10. **Access Control**: Admin functions, super holder restrictions

## Audit Recommendations

### High Priority (Addressed in Phase 5/6)
- [x] NFT ownership validation via SceneTracker
- [x] Timelock mechanism — `ProtocolTimelock` implemented and tested
- [x] Reentrancy protection in all state-changing functions
- [x] Verify logarithmic scaling calculations (MathLibrary.ln)
- [ ] Test founder decentralization schedule edge cases on testnet

### Medium Priority
- [ ] Optimize gas usage in multi-project voting power calculations
- [ ] Review admin privilege scope and abuse vectors
- [ ] Test proposal cancellation scenarios (cancelTimelockOperation)

### Low Priority
- [ ] Add more detailed event logging
- [ ] Consider upgradeability patterns for future improvements

## License

MIT License - See LICENSE file for details

## Security Contact

security@cheesecoins.io
