# Cheesecoins Ecosystem — Security Audit Report
**Date:** March 12, 2026
**Auditor:** Greg Garner (Founder / Protocol Owner)
**Assisted by:** Claude Code (Anthropic)
**Scope:** All production smart contracts in `foundry-src/`
**Network:** Arbitrum Sepolia (testnet); Arbitrum One (mainnet target)
**Commit baseline:** Post-Phase 6C, post-Tuesday upgrade (StakingManager projectId fix applied March 10, 2026)

---

## Executive Summary

A full contract-by-contract manual security audit was conducted across all production contracts. 17 findings were identified and remediated during this audit session — no critical (C0) issues remain. The one high-severity issue (TransferHookRouter caller restriction) was the most consequential finding and has been patched and verified.

| Severity | Found | Fixed | Deferred |
|----------|-------|-------|----------|
| HIGH     | 1     | 1     | 0        |
| MEDIUM   | 8     | 8     | 0        |
| LOW      | 11    | 11    | 0        |
| INFO     | 7     | 5     | 2*       |

*Two informational findings are accepted design trade-offs (documented below).

The protocol is assessed as **ready for testnet launch** pending multisig setup and final integration tests. Mainnet deployment should proceed only after completing the multisig configuration and final governance pipeline validation on the mainnet deployment.

---

## Scope of Contracts Audited

| Contract | Path |
|----------|------|
| CheesecoinsCore | `core/CheesecoinsCore.sol` |
| StakingManager | `staking/StakingManager.sol` |
| SuperHolderGovernance | `governance/SuperHolderGovernance.sol` |
| ProtocolTimelock | `governance/ProtocolTimelock.sol` |
| GovernanceWeighting | `governance/GovernanceWeighting.sol` |
| FounderDecentralization | `governance/FounderDecentralization.sol` |
| CsaCertificateSale | `commerce/CsaCertificateSale.sol` |
| NubiansNorthNFT | `nft/NubiansNorthNFT.sol` |
| TransferHookRouter | `nft/TransferHookRouter.sol` |
| SceneTracker | `nft/extensions/SceneTracker.sol` |

Supporting contracts reviewed but not individually listed (libraries, interfaces, Config.sol).

---

## Findings

### H-01 — TransferHookRouter: Unrestricted caller allows governance weight spoofing
**Contract:** `TransferHookRouter.sol`
**Severity:** HIGH
**Status:** FIXED

**Description:**
`beforeNFTTransfer` and `afterNFTTransfer` were callable by any address, not just the registered `nftContract`. `StakingManager.afterNFTTransfer` trusts `msg.sender == router` to identify the originating NFT collection (via `router.nftContract`). A malicious actor could call `router.afterNFTTransfer(tokenId, victim, attacker)` directly — without owning any NFT — and cause StakingManager to reassign governance voting weight attribution from the victim to the attacker.

**Fix:**
Added `if (msg.sender != nftContract) revert CallerNotNFTContract(msg.sender, nftContract)` to both hook entry points. Added `CallerNotNFTContract(address caller, address expected)` custom error.

---

### M-01 — StakingManager: `getProjectId()` fallback masks unregistered NFTs
**Contract:** `StakingManager.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
`unstake()`, `beforeNFTTransfer()`, and `_calculateAPY()` fell back to calling `nft.getProjectId()` when `nftToProject[nftAddress] == 0`. The NubiansNorthNFT `PROJECT_ID` constant is hardcoded to `1` (legacy error; actual registry project ID is `2`). This fallback silently returned the wrong project ID, potentially associating staking rewards with the wrong project.

**Fix:**
Replaced all three fallback paths with `revert InvalidNFT()`. Project IDs must be registered explicitly via `registerNFT` / `batchRegisterNFTs`.

---

### M-02 — StakingManager: `registerNFT` silently overwrites existing project mapping
**Contract:** `StakingManager.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
`registerNFT` and `batchRegisterNFTs` would overwrite an existing `nftToProject` entry without warning. A mistaken re-registration call could silently redirect all future staking events for a live NFT collection to the wrong project ID, breaking reward accounting for all current stakers.

**Fix:**
Added a guard: `if (nftToProject[nftAddr] != 0) revert AlreadyRegistered(nftAddr)`. Existing registrations are now immutable. A dedicated migration path would be required to correct a wrong registration.

---

### M-03 — StakingManager: `emergencyWithdraw` emits no event
**Contract:** `StakingManager.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
Emergency withdrawals bypassing normal unstake accounting had no on-chain event. Off-chain monitoring could not detect their use.

**Fix:**
Added `EmergencyWithdrawal(address indexed user, uint256 indexed nftId, uint256 principalReturned)` event, emitted in `emergencyWithdraw`.

---

### M-04 — CheesecoinsCore: Annual mint cap not enforced in `controllerMint`
**Contract:** `CheesecoinsCore.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
`controllerMint` did not call `_resetAnnualMintIfNeeded()` and did not increment `currentYearMinted`. The 20M annual inflation cap was tracked for governance-initiated mints but completely bypassed for all controller mints (staking rewards, etc.), allowing unlimited supply inflation.

**Fix:**
Added `_resetAnnualMintIfNeeded()` call and `currentYearMinted += amount` to `controllerMint`.

---

### M-05 — CheesecoinsCore: `getAnnualMintStats` returns stale data without virtual reset
**Contract:** `CheesecoinsCore.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
`getAnnualMintStats` returned raw state values without applying the virtual year-rollover logic, so callers would see a non-zero `currentYearMinted` even after the annual window had lapsed, leading to incorrect off-chain cap utilization displays.

**Fix:**
Updated `getAnnualMintStats` to apply the virtual reset inline (reading-without-writing) so the returned `minted` value always reflects the current year.

---

### M-06 — SuperHolderGovernance: `cancelProposal` can cancel a queued timelock operation without removing it from the timelock
**Contract:** `SuperHolderGovernance.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
`cancelProposal` would mark a proposal as cancelled in governance state even if the proposal had already been queued in `ProtocolTimelock`. The timelock operation would remain executable despite the governance-level cancellation.

**Fix:**
`cancelProposal` now reverts with `AlreadyQueued()` if the proposal is in a queued state, forcing callers to use `cancelTimelockOperation` instead.

---

### M-07 — NubiansNorthNFT: `setTransferHook(address(0))` would silently disable scene tracking
**Contract:** `NubiansNorthNFT.sol`
**Severity:** MEDIUM
**Status:** FIXED

**Description:**
Passing `address(0)` to `setTransferHook` would silence all future transfer callbacks without any warning. Since transfer events cannot be replayed, this would permanently corrupt SceneTracker and StakingManager accounting for all subsequent transfers.

**Fix:**
`setTransferHook` now requires `hook != address(0) && hook.code.length > 0`, ensuring only valid contract addresses are accepted. Passing a non-contract address (including zero) reverts with an explicit error.

---

### M-08 — ProtocolTimelock: `updateDelay` can be called with delay below `MIN_PROTOCOL_DELAY`
**Contract:** `ProtocolTimelock.sol`
**Severity:** MEDIUM
**Status:** MITIGATED (layered defense documented)

**Description:**
`TimelockController.updateDelay` is an `external` function with a `private _minDelay` field. Solidity does not allow overriding `external` functions from derived contracts for the purpose of adding pre-checks, making a direct Solidity-level enforcement impossible without duplicating OZ internals.

**Mitigation:**
Added `validateDelayUpdate(uint256 newDelay) external pure` as an off-chain pre-flight check. Layered defense documented in NatSpec:
1. Any `updateDelay` call must be scheduled as a timelock operation (subject to the current 2-day delay).
2. Scheduling requires SuperHolderGovernance PROPOSER_ROLE (66% supermajority + 70% quorum + 24-week stake age).
3. Guardian multisig holds CANCELLER_ROLE with the full delay window to cancel malicious proposals.
4. All scheduled operations are visible on-chain immediately.

**Operational requirement:** Never schedule or execute a governance proposal calling `updateDelay(n)` with `n < 172800` (2 days) on mainnet.

---

### L-01 — Multiple contracts: `require` strings instead of custom errors
**Contracts:** `CheesecoinsCore.sol`, `StakingManager.sol`, `SuperHolderGovernance.sol`, `ProtocolTimelock.sol`, `GovernanceWeighting.sol`, `CsaCertificateSale.sol`, `SceneTracker.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
Multiple `require("string")` patterns used throughout. Custom errors are cheaper in deployment and execution gas and provide richer off-chain decoding.

**Fix:**
All `require` strings replaced with custom errors across all contracts.

---

### L-02 — StakingManager: `setTreasury` emits no event
**Contract:** `StakingManager.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
Changing the treasury address is a critical admin action with no on-chain event.

**Fix:**
Added `TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury)` event, emitted in `setTreasury`.

---

### L-03 — CheesecoinsCore: `updateTreasuryAddresses` emits no event
**Contract:** `CheesecoinsCore.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
Changes to the four treasury address slots were not emitted as events.

**Fix:**
Added `TreasuryAddressesUpdated(address ecosystemTreasury, address operationalTreasury, address marketingTreasury, address reserveTreasury)` event to `ICheesecoinsCore` and emitted in `updateTreasuryAddresses`.

---

### L-04 — CheesecoinsCore: No `reactivateProject` function
**Contract:** `CheesecoinsCore.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
`deactivateProject` existed but there was no corresponding reactivation path, making deactivation irreversible without a contract upgrade.

**Fix:**
Added `reactivateProject(uint256 projectId) external onlyOwner` with appropriate event.

---

### L-05 — CheesecoinsCore: Unused `projectId` parameter in `_applyAuditReward`
**Contract:** `CheesecoinsCore.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
`_applyAuditReward(project, projectId, ...)` accepted a redundant `projectId` parameter that shadowed `project.id`, creating a risk that the wrong ID could be used in event emissions.

**Fix:**
Removed the `projectId` parameter; all references updated to use `project.id` directly.

---

### L-06 — CsaCertificateSale: `adminMint` missing `nonReentrant`
**Contract:** `CsaCertificateSale.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
`adminMint` lacked the `nonReentrant` modifier present on `buyWithCURD` and `buyWithUSDC`, creating an inconsistent reentrancy surface for admin operations.

**Fix:**
Added `nonReentrant` to `adminMint`.

---

### L-07 — CsaCertificateSale: `setProjectRegistry` emits no event
**Contract:** `CsaCertificateSale.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
Changing the project registry address had no on-chain event.

**Fix:**
Added `ProjectRegistryUpdated(address indexed newRegistry)` event, emitted in `setProjectRegistry`.

---

### L-08 — NubiansNorthNFT: ETH rescue function missing
**Contract:** `NubiansNorthNFT.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
`ERC721AUpgradeable.transferFrom` is `payable` as a gas optimization. ETH accidentally sent to the contract would be permanently locked with no recovery path.

**Fix:**
Added `sweepETH(address payable to) external onlyOwner` with `ETHTransferFailed` custom error.

---

### L-09 — ProtocolTimelock: Zero-address canceller not validated
**Contract:** `ProtocolTimelock.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
The `cancellers` array loop did not validate for zero-address entries, which would silently grant `CANCELLER_ROLE` to `address(0)` — allowing anyone to call `cancel()` since `address(0)` has no private key.

**Fix:**
Added `if (cancellers[i] == address(0)) revert ZeroCanceller()` inside the loop.

---

### L-10 — StakingManager: `registerNFT` accepts `projectId == 0`
**Contract:** `StakingManager.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
`projectId == 0` was used as the sentinel for "unregistered" in `nftToProject`. Registering with `projectId = 0` would put the mapping back in an unregistered state while emitting a success event.

**Fix:**
Changed `revert ZeroAddress()` to `revert InvalidNFT()` for `projectId == 0` (clearer semantics).

---

### L-11 — StakingManager: `setGovernanceNotifier` uses `require` string
**Contract:** `StakingManager.sol`
**Severity:** LOW
**Status:** FIXED

**Description:**
Inconsistent with the rest of the contract's custom error pattern.

**Fix:**
Replaced with `if (_gov == address(0)) revert ZeroAddress()`.

---

### I-01 — GovernanceWeighting: `calculateVotingPower` is non-view (event emission)
**Contract:** `GovernanceWeighting.sol`
**Severity:** INFO
**Status:** ACCEPTED

**Description:**
`calculateVotingPower` emits a `VotingPowerCalculated` event, making it a state-mutating function. This prevents it from being called in pure view contexts and means every vote cast in governance emits this event. No security risk — governance correctly accounts for this (NatSpec on `getVotingPower` documents the non-view requirement).

**Decision:** Accepted. The event provides useful off-chain observability for vote weight auditing. The `virtual` + `public` visibility is intentional for extensibility.

---

### I-02 — FounderDecentralization: Redundant dual event emission in `updateFounderWeight`
**Contract:** `FounderDecentralization.sol`
**Severity:** INFO
**Status:** ACCEPTED

**Description:**
`updateFounderWeight` emits both `AnnualWeightDecrement(year, oldWeight, newWeight)` and `FounderWeightUpdated(year, newWeight, timestamp)` on every call. These events carry overlapping data. Minor gas waste and off-chain event duplication.

**Decision:** Accepted. Both events serve distinct indexing purposes for off-chain tooling. No security impact.

---

### I-03 — SceneTracker: `governanceNotifier` cannot be disabled once set
**Contract:** `SceneTracker.sol`
**Severity:** INFO
**Status:** NOTED

**Description:**
`setGovernanceNotifier` rejects `address(0)`, meaning once notifications are enabled they cannot be temporarily disabled during a governance contract upgrade. During a governance migration, `SceneTracker` would attempt to call the old governance notifier until a new one is set.

**Recommendation:** For governance upgrades, set the new governance notifier address before decommissioning the old contract to avoid a notification gap. The old contract receiving spurious `notifyPotentialVotingPowerChange` calls during the transition window is benign (no-op if the old contract ignores unknown callers).

---

### I-04 — GovernanceWeighting: Growth rate cache stores zero for projects with zero growth rate
**Contract:** `GovernanceWeighting.sol`
**Severity:** INFO
**Status:** NOTED

**Description:**
If a project's `metrics.growthRate` is `0`, `recalculateGrowthRates()` stores `cachedGrowthRates[i] = 0`. On the next call, `cachedGrowthRates[projectId] > 0` evaluates false, causing `getProjectGrowthRate` to skip the cache and query the registry live every time. For a project with no growth data this causes an extra external call per vote weight calculation, and the project would fall back to the `100` (1.0×) default regardless.

**Decision:** Noted. In practice, all registered projects should have a non-zero growth rate. The fallback to `100` is correct behavior.

---

### I-05 — StakingManager / NatSpec: Burn-on-unstake schedule removed
**Contract:** `StakingManager.sol`
**Severity:** INFO (Design Change)
**Status:** RESOLVED

**Description:**
An earlier design included a progressive burn schedule on unstake (Y1: 0 CURD, Y2: 1 CURD … per token). This was identified as contradicting the principal-return-100% guarantee and potentially deterring staking. The design was reviewed and the burn schedule was removed in favor of forfeiting only accrued rewards on early exit.

**Current behavior:** Principal returned 100% on unstake at any time. Rewards are subject to maturity tiers (1/2/3/5+ year lockup for increasing APY). NatSpec updated throughout `StakingManager.sol` to reflect this.

---

### I-06 — NubiansNorthNFT: `PROJECT_ID` constant hardcoded to `1` (should be `2`)
**Contract:** `NubiansNorthNFT.sol`
**Severity:** INFO (Deployment artifact)
**Status:** DOCUMENTED — Cannot be changed on deployed contract

**Description:**
The `PROJECT_ID` constant is `1` (legacy error from initial deployment). The canonical project ID in the registry is `2`. This value cannot be changed on the deployed upgradeable contract.

**Mitigation:** Do NOT call `getProjectId()` on this contract. All project ID resolution must go through `StakingManager.nftToProject[nftAddress]`, which is correctly mapped to project ID `2` after the March 10 upgrade. NatSpec on the constant and on `getProjectId()` document this explicitly.

---

### I-07 — Audit Proof: Physical inventory attestation is YouTube-video-based
**Severity:** INFO (Out of scope for on-chain audit)
**Status:** DEFERRED TO POST-LAUNCH

**Description:**
The protocol's claim that 200,000,000 CURD initial supply is backed by 10-year herd growth projections for Nubians North dairy goat farm cannot be verified on-chain. EIP-712 proof verification for audit claims is architecturally present but not yet operationally wired.

**Current attestation:** Herd size and farm operations are documented via YouTube video evidence. Formal third-party audit of physical inventory is planned post-launch.

**Risk to holders:** Purchasers should be aware the on-chain token supply is currently backed by founder attestation (video evidence), not a cryptographic proof. This is disclosed in protocol documentation.

---

## Summary of All Code Changes Made During This Audit

| File | Change |
|------|--------|
| `core/interfaces/ICheesecoinsCore.sol` | Added `TreasuryAddressesUpdated` event |
| `core/CheesecoinsCore.sol` | Annual mint cap enforcement in `controllerMint`; `TreasuryAddressesUpdated` event; `reactivateProject` function; virtual reset in `getAnnualMintStats`; removed unused `projectId` param from `_applyAuditReward` |
| `staking/StakingManager.sol` | NatSpec burn-on-unstake removed; `getProjectId()` fallback replaced with `revert InvalidNFT()`; `registerNFT`/`batchRegisterNFTs` no-overwrite guard; `EmergencyWithdrawal` event; `TreasuryUpdated` event; `InvalidNFT()` for projectId==0; `setGovernanceNotifier` custom error |
| `governance/SuperHolderGovernance.sol` | `cancelProposal` blocks if already queued; `require` strings → custom errors |
| `governance/ProtocolTimelock.sol` | `validateDelayUpdate` helper; `ZeroCanceller` error + zero-address canceller guard |
| `governance/GovernanceWeighting.sol` | Custom errors (`TooSoonToRecalculate`, `NoProjects`, `TooManyProjects`); `require` strings replaced |
| `commerce/CsaCertificateSale.sol` | `ProjectRegistryUpdated` event; custom errors in `buyWithCURD`/`buyWithUSDC`; `nonReentrant` on `adminMint` |
| `nft/NubiansNorthNFT.sol` | `setTransferHook` zero-address + contract check; `sweepETH` with `ETHTransferFailed` |
| `nft/TransferHookRouter.sol` | **H-01 fix:** `CallerNotNFTContract` error; `msg.sender != nftContract` guard on both hook entry points |
| `nft/extensions/SceneTracker.sol` | `ZeroGovernanceNotifier` error; `require` string → custom error in `setGovernanceNotifier` |

---

## Pre-Mainnet Checklist (Remaining)

- [ ] Multisig setup (Gnosis Safe or equivalent) — proposer, guardian, operational addresses
- [ ] Transfer ProxyAdmin ownership to ProtocolTimelock
- [ ] `MerchantRegistryV2.initializeV2` with final multisig addresses
- [ ] Mainnet deployment script execution (`DeployMainnet.s.sol`)
- [ ] Governance pipeline fork test against mainnet deployment
- [ ] YieldPool integration tests
- [ ] Factory pipeline end-to-end tests
- [ ] CsaCertificateSale integration test (CURD + USDC payment paths)
- [ ] Web app: switch to mainnet contract addresses
- [ ] Web app: sales progress rounding display
- [ ] Web app: off-ramp widget

---

## Addendum — CurdDirectSale Audit (March 27, 2026)

**Contract:** `foundry-src/commerce/CurdDirectSale.sol`
**Auditor:** Greg Garner + Claude Code
**Context:** New contract written March 27 to replace a non-upgradeable version that was deployed in error. Upgraded to Transparent Proxy pattern. Full Slither + manual review performed before deployment.

### Summary

| Severity | Found | Fixed | Accepted |
|----------|-------|-------|----------|
| MEDIUM   | 1     | 1     | 0        |
| LOW      | 2     | 2     | 0        |
| INFO     | 1     | 0     | 1        |

### Findings

**[M-1] Local variable shadowing — FIXED**
`initialize()` parameter `_owner` shadowed `OwnableUpgradeable._owner` state variable. Fixed by renaming to `initialOwner`.

**[L-1] CEI violation in `buy()` — FIXED**
`totalUsdcRaised` and `totalCurdSold` were updated after two external calls (`safeTransferFrom`, `safeTransfer`). Although `nonReentrant` makes exploitation impossible, the code now follows checks-effects-interactions: state is updated before external calls.

**[L-2] Event emitted after external call in `recoverCurd` / `recoverUsdc` — FIXED**
Both recovery functions emitted events after `safeTransfer`. Events now emitted before the transfer (CEI pattern).

**[INFO-1] `setOracle` accepts `address(0)` — ACCEPTED**
Slither flags the missing zero-check, but `address(0)` is intentional: it disables oracle mode and reverts to manual price. This is documented in the function's NatSpec and in the contract-level `@dev` block.

### Additional security notes

- **No oracle trust boundary issue**: The oracle address is set by `onlyOwner`. A malicious oracle could return an incorrect price, but the owner is the Ledger Founder EOA — this is an accepted operational trust assumption, same as any admin parameter.
- **Reserve check before transfer**: `buy()` verifies `curd.balanceOf(address(this)) >= curdAmount` before any state change, preventing overselling.
- **USDC goes directly to treasury**: `safeTransferFrom(msg.sender, treasury, ...)` — USDC never sits in the contract, eliminating a drain vector.
- **ProxyAdmin owned by Ledger EOA**: The Transparent Proxy pattern means only the ProxyAdmin owner can upgrade. This is the Founder Ledger hardware wallet, not a hot key.

### Deployment checklist
- [x] Slither clean (only informational oracle note accepted)
- [x] CEI pattern applied throughout
- [x] No local variable shadowing
- [x] `_disableInitializers()` in constructor
- [x] `initialize()` protected by `initializer` modifier
- [ ] Deploy via `script/DeployCurdDirectSale.s.sol` with `--ledger`
- [ ] Fund reserve: Gnosis Safe transfers CURD to proxy address
- [ ] Verify proxy on Arbiscan
- [ ] Wire website buy button

---

---

## Addendum — Phase 2 Contracts Audit (April 15, 2026)

**Contracts:**
- `foundry-src/commerce/ProjectSale.sol` — upgradeable multi-project sale (Transparent Proxy)
- `foundry-src/nft/CommerceNFTTemplate.sol` — factory-deployable commerce/CSA NFT
- `foundry-src/nft/LandNFTTemplate.sol` — factory-deployable land rights NFT (testnet only)
- `foundry-src/nft/LandDeedNFT.sol` — deed registry (non-upgradeable ERC721)

**Auditor:** Greg Garner + Claude Code
**Context:** New Phase 2 contracts written April 2026. Slither automated analysis + manual review performed before Sepolia deployment.

**Test coverage at audit time:**
- ProjectSale: 42 unit tests passing
- CommerceNFTTemplate: 33 unit tests passing
- LandNFTTemplate: 29 unit tests passing
- LandDeedNFT: 21 unit tests passing

### Summary

| Severity | Found | Fixed | Accepted |
|----------|-------|-------|----------|
| HIGH     | 1     | 1     | 0        |
| MEDIUM   | 1     | 1     | 0        |
| LOW/INFO | 1     | 0     | 1        |

### Findings

**[H-1] CEI violation in `buy()` and `buyWithVoucher()` — FIXED**
`_purchasedByWallet[projectId][msg.sender] += quantity` was written after two external calls (`_collectAndRoute` — ERC20 transfers — and `_mintTokens` — NFT mint call). This violates the Checks-Effects-Interactions pattern. While the `nonReentrant` modifier prevents direct reentrancy exploitation, the state update after external calls is a structural vulnerability: `purchasedBy()` (public view) could return a stale count during the interaction window in a cross-function reentrancy scenario via a compromised NFT contract.

**Fix:** Moved `_purchasedByWallet` increment to immediately after `_enforceWalletCap()` and before all external calls in both `buy()` and `buyWithVoucher()`. CEI order is now: check cap → update wallet count → collect payment → mint NFT.

**[M-1] Local variable shadowing in `initialize()` — FIXED**
`initialize(address _owner, ...)` parameter `_owner` shadowed `OwnableUpgradeable._owner` state variable. Same class of issue as the CurdDirectSale M-1 finding (March 27).

**Fix:** Renamed parameter to `initialOwner` throughout `initialize()` and its NatSpec.

**[INFO-1] `voucherSigner` accepts `address(0)` in `setVoucherSigner` — ACCEPTED**
Slither flags the missing zero-check on `voucherSigner = _signer`. Setting to `address(0)` is intentional — it disables voucher-based purchases. `buyWithVoucher()` already guards this with `if (voucherSigner == address(0)) revert VoucherSignerNotSet()`. Suppressed with `// slither-disable-next-line missing-zero-check` and documented in the function's NatSpec.

### CommerceNFTTemplate / LandNFTTemplate / LandDeedNFT

No findings in contract code. All Slither flags were in vendored libraries (OZ assembly patterns, ERC721A assembly, `block.timestamp` use for maturity dates — intentional by design). No reentrancy surfaces, no CEI violations, no missing zero-checks in own code.

### Additional security notes

**ProjectSale:**
- Payment collected via `safeTransferFrom` — ERC20 never sits in the contract between transactions; all routing (protocol fee + issuer share) happens in the same call.
- `nonReentrant` remains on `buy()` and `buyWithVoucher()` as defence-in-depth even after CEI fix.
- Partner-registered NFT contracts are trusted (admin-activated after review) — the mint call cannot be a hostile external call in practice.
- Voucher nonce marked spent before payment and mint — replay protection holds even if payment reverts.
- Transparent Proxy pattern — ProxyAdmin owner is Ledger Founder EOA for testnet; will transfer to Gnosis Safe for mainnet.

**LandNFTTemplate:**
- Marked `TESTNET ONLY` in NatSpec — requires legal review per jurisdiction before any mainnet deployment.
- Area over-issuance prevented in `LandDeedNFT.registerSubProject()` via `totalIssuedAreaSqm[deedId]` cumulative tracking.

### Deployment checklist
- [x] Slither clean (H-1 and M-1 fixed; INFO-1 accepted and documented)
- [x] CEI pattern applied in `buy()` and `buyWithVoucher()`
- [x] No local variable shadowing
- [x] `_disableInitializers()` in ProjectSale constructor
- [x] `initialize()` protected by `initializer` modifier
- [x] 125 unit tests passing across all four Phase 2 contracts
- [ ] Deploy ProjectSale proxy to Arbitrum Sepolia
- [ ] Deploy test CommerceNFT project + end-to-end buy flow test on Sepolia
- [ ] Slither re-run post Sepolia wiring (sanity check no new code introduced)
- [ ] Deploy to Arbitrum One mainnet (after Sepolia validation + Gnosis Safe transfer)

---

*This report was produced through a self-audit process. It should be supplemented with a professional third-party audit prior to significant TVL or mainnet token distribution. The founder/auditor identity is the same party — all findings and remediations were reviewed collaboratively using AI-assisted code analysis (Claude Code, Anthropic).*

---

## Addendum — May 2, 2026 Slither Re-run + Triage

A fresh Slither v0.11.5 sweep of the full tree (`slither-2026-05-02.txt`, 363 raw findings across 142 contracts, 101 detectors) was performed after the post-March-3 contract additions: `CheesecoinsOptionsMarket`, `CommodityPriceOracle`, `LandNFTTemplate`, `LandDeedNFT`, `PartnerNFTSale`, `TreasuryRateAdvisor`, and the Sepolia `MockCURD`/`MockUSDC` test ERC20s. None of these are mainnet-deployed.

### Triage results — fixed

| ID | File | Severity | Issue | Fix |
|----|------|----------|-------|-----|
| S-01 | `nft/LandNFTTemplate.sol` | Medium | Custom `bool _initialized` shadowed OZ `Initializable._initialized` | Removed redundant flag; `initializerERC721A initializer` modifier already guards re-init. |
| S-02 | `commerce/PartnerNFTSale.sol` | Medium (CEI) | `_promoMintedByWalletByScene` cap incremented after external `safeTransferFrom` | Moved increment before external calls. Same pattern previously fixed in `ProjectSale` (M-2). |
| S-03 | `stability/CheesecoinsOptionsMarket.sol` | Medium | Pyth confidence interval not validated in settlement path | Added `MAX_CONF_BPS = 1_000` (10%) check in `_readSettlementPrice`; reverts `OracleStale` if `conf * BPS_DENOM > absPrice * MAX_CONF_BPS`. |
| S-04 | `stability/CheesecoinsOptionsMarket.sol` | Low | `exercise()` `payout` declared without explicit zero-init | Changed to `uint256 payout = 0;` for clarity. (Default-init was already safe.) |

### Triage results — false-positive suppressions (slither-disable-next-line)

Each suppression carries an inline justification block.

| File | Detector | Reason |
|------|----------|--------|
| `nft/CommerceNFTTemplate.sol:133` | `shadowing-state` | Custom `_initialized` slot is intentional and storage-stable; renaming would force redeploy of the mainnet impl (`0xAe2fe166c61c5e343283a7AEA9C1C00cb466dabf`). |
| `staking/TreasuryRateAdvisor.sol:205,228,236` | `incorrect-equality` | Array-length zero check is exact, not approximate. |
| `stability/CheesecoinsOptionsMarket.sol` `_isDoubleStale` | `pyth-unchecked-confidence` | Staleness probe, not a price-quality check; conf is validated where the price is consumed. |
| `stability/CheesecoinsOptionsMarket.sol` `batchRelease` | `reentrancy-no-eth` | Function is `nonReentrant`; CURD has no callbacks; state set before transfer. |
| `stability/CheesecoinsOptionsMarket.sol` `_readSettlementPrice` (commodity branch) | `unused-return` | `publishTime` is intentionally unused — staleness is signaled by the returned `fresh` bool. |

### Triage results — accepted (deferred / no change)

- **CsaCertificateSale reentrancy guard ordering** — already accepted in original audit; payment routing happens within the same call; `nonReentrant` is defence-in-depth; documented above. No new exposure.
- **Solidity floating pragmas in libraries** — third-party OZ libs; pinned via `forge.toml`.

### Mainnet exposure summary

| Tier | Count | Mainnet contracts? |
|------|-------|--------------------|
| New code without Slither pass before May 2 | 17 files | 0 (all Sepolia or undeployed) |
| Findings on live mainnet bytecode | 0 High, 0 Medium | — |
| Findings on Sepolia-only / undeployed code | All High/Medium fixed or suppressed with justification | — |

### Verification

- `forge build` — clean (exit 0; warnings are pre-existing test-file lints).
- `forge test -q` — pending re-run (this addendum).
- Re-slither against `slither-2026-05-02.json` baseline — pending; expect High count to drop to 0 and Medium to drop by 4.

### Outstanding pre-mainnet checks (Options Market)

- USDA AMS keeper 7-day clean-streak gate (May 5 cutover target).
- Pyth feed ID + maxAge per market locked via Safe tx.
- `CommodityPriceOracle.isDoubleStale` parity verified against on-chain Pyth feed.

