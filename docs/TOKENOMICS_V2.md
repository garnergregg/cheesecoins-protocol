# Cheesecoins Tokenomics — v2

*Companion document to `ARBITRUM_GRANT_APPLICATION_V2.md` and `CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx`. Version 2 supersedes the original tokenomics in `contracts-v2/foundry-docs/Tokenomics.ods` and reflects the protocol's actual deployment state + planned supply trajectory tied to real-world-asset (RWA) growth.*

**Last updated:** 2026-05-05
**Status:** Draft — pending Super NFT governance ratification
**Network:** Arbitrum One mainnet (live since 2026-03-25)

---

## 1. Headline

Cheesecoins (CURD) is a productive-asset-backed token. Its supply is **not algorithmic, not arbitrary** — it expands only when underlying real-world economic activity (registered partners, settlement volume, tokenized capital projects) justifies it, and only by **explicit Super NFT governance vote.**

The original 200,000,000 CURD supply was sized for a single farm (Nubians North). The protocol's design intentionally allows for an additional authorized expansion of up to 200,000,000 CURD as the supply chain scales — making total possible supply **400,000,000 CURD**, contingent on triggers defined in this document.

This is the same elastic-supply pattern used by USDC, DAI, Frax, and all major RWA-backed tokens: **token supply tracks productive backing, not speculative demand.**

---

## 2. Original allocation (live on mainnet today)

Total minted as of May 2026: **200,000,000 CURD.** All addresses verifiable on Arbiscan; manifest at `contracts-v2/deployments/42161-arbitrum-one-all.json`.

| Pool | Amount | % | Address / Status |
|---|---|---|---|
| Treasury (Gnosis Safe) | 165,000,000 | 82.5% | `0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2` — locked, governance-controlled |
| BootstrapYieldPool | 5,000,000 | 2.5% | `0x27b55A7fFaeD5df6f174bb29fc2D8f08329DE68C` — funded April 2026, distributed to stakers |
| CurdDirectSale | 10,000,000 | 5.0% | `0x31ea59d272472B8B2BBF1a7b58fCB0433712d10D` — sold to direct buyers |
| Founder allocation (original) | 20,000,000 | 10.0% | Founder wallet (Greg Garner) — initial seed, no vesting on this baseline tranche |

**Net circulating at protocol launch (March 2026):** ~20M CURD (founder allocation) + small ongoing trickle from CurdDirectSale.

---

## 3. Founder allocation — 20M with 4-year linear vesting

### 3.1 Original allocation

The protocol's `Config.FOUNDER_ALLOCATION = 20,000,000 × 10^18` (20M CURD). Founder address is `0xDfb351Db881142f76f10f6D12c348002b473F9BA` (Greg Garner, Ledger wallet).

### 3.2 Vesting

`FounderVestingWallet.sol` exists in the repo (`contracts-v2/foundry-src/monetary/FounderVestingWallet.sol`) and implements **4-year linear vesting** (`Config.FOUNDER_VEST_DURATION = 4 * 365 days`) with no clawbacks. The contract uses a standard OpenZeppelin pattern.

**Deployment status (UPDATED May 5, 2026):** `FounderVestingWallet` deployed at `0xbac3d40668Ce4030ab5D8cF0bBCFDA457E1216f5` on Arbitrum One mainnet, verified on Arbiscan. 20M CURD transferred from founder Ledger into the vesting wallet on the same day. **Retroactive vesting now active** with `start = March 25, 2026` (original mainnet launch).

Verified on-chain May 5, 2026:
- `curd()` = `0x833551C5...89cD` ✅
- `beneficiary()` = `0xDfb351Db...F9BA` (founder Ledger) ✅
- `start()` = `1774396800` (Mar 25 2026 UTC) ✅
- `duration()` = `126144000` (4 years in seconds) ✅
- Vesting wallet CURD balance: 20,000,000 ✅
- Founder Ledger CURD balance: 0 ✅
- Currently `releasable()`: ~574,908 CURD (~42 days vested)

The originally-designed vesting schedule:

| Date | Vested (cumulative) | Remaining locked |
|---|---|---|
| March 25, 2026 (start) | 0 | 20,000,000 |
| March 25, 2027 (Y1) | 5,000,000 | 15,000,000 |
| March 25, 2028 (Y2) | 10,000,000 | 10,000,000 |
| March 25, 2029 (Y3) | 15,000,000 | 5,000,000 |
| March 25, 2030 (Y4) | 20,000,000 | 0 |

Linear vest: `vested = totalAllocation × (now − start) / duration`.

**As of doc date (May 5, 2026):** ~41 days of vesting elapsed → ~561,000 CURD vested, ~19.44M will be locked once deployment + transfer complete.

### 3.3 Governance-weight decentralization (LIVE on-chain, separate from vesting)

The deployed `FounderDecentralization.sol` at `0xC2378eC98B8Aedf8E748b86775739F25F2CCE86a` implements a **5-year governance-weight decentralization** — independent of CURD vesting. It governs voting weight, not allocation:

| Year | Founder governance weight |
|---|---|
| Y1 (current) | 50% |
| Y2 | 40% |
| Y3 | 30% |
| Y4 | 20% |
| Y5 | 10% |
| Y5+ cliff | 0% (founder becomes regular super holder, no special weight) |

Weight decrements (10% per year) are wired in `Config.FOUNDER_WEIGHT_DECREMENT`. The Y5 cliff converts the founder to a regular super holder with no additional governance weight.

**Live on-chain values (verified May 5, 2026):**
- `founder()` = `0xDfb351Db881142f76f10f6D12c348002b473F9BA`
- `currentFounderWeight()` = `50` (Y1 weight, decreases annually)

## 3a. Founder performance reward (30M CURD — PROPOSED, tied to supply expansion)

### 3a.1 Headline

**30,000,000 CURD = 15% of the proposed 200M supply expansion** (see §4). Vested against milestones the supply expansion itself is gated on. **NOT funded from existing treasury** — comes from the new mints, only when the protocol's RWA growth justifies the expansion.

Total founder allocation if both the original 20M and full performance reward are realized:
- Original: **20M** (subject to 4-year vesting per §3.2)
- Performance reward: **30M** (subject to vesting + milestone gates)
- **Total: 50M / 400M post-expansion = 12.5%**

This sits at the lower end of the standard 10-20% DeFi founder range while being tied entirely to verifiable on-chain growth metrics that are independently in the protocol's interest.

### 3a.2 Status

This mechanism has **not been authored as a contract, not voted on by Super NFT holders, and is not currently live on-chain.** It is included here as a discussion framework for governance ratification, alongside the supply expansion authorization in §4.

### 3a.3 Proposed framework

| Parameter | Value |
|---|---|
| Total reward pool | **30,000,000 CURD** |
| Source | **Supply expansion mints** (15% of each tranche per §4.4 routing) |
| Vesting mechanism | New contract `FounderRewardVesting.sol` (not yet authored) — milestone-gated + linear tail |
| Authorization mechanism | Super NFT governance vote (66% supermajority, 30-day vote, 2-day timelock) — packaged with supply expansion authorization |
| Tranche structure | Tied to expansion tranches A / B / C (see §4.3) |

### 3a.4 Tranche structure (matches the supply expansion gates)

The 30M founder reward unlocks proportionally with the expansion tranches that fund it. The triggers are the same — same RWA growth that justifies expansion is what unlocks the founder share.

| Tranche | Founder reward | Source mint | Trigger (per §4.3) |
|---|---|---|---|
| A | 7,500,000 CURD (15% of 50M) | Tranche A mint | 5,000 partners + $250M cumulative GMV |
| B | 11,250,000 CURD (15% of 75M) | Tranche B mint | 25,000 partners + $1B cumulative GMV |
| C | 11,250,000 CURD (15% of 75M) | Tranche C mint | 100,000 partners + $5B cumulative GMV |
| **Total** | **30,000,000 CURD** | | |

Each tranche has a **6-month linear vesting tail** after the trigger fires, so a milestone hit at end of Y1 begins vesting Jan-Jun Y2. Prevents single-event dump pressure.

### 3a.5 Why this design

- **Reward is locked to expansion**: founder cannot collect performance reward unless the protocol's RWA backing has grown to justify the supply expansion. Same triggers, same backing requirements — no insider mint without productive value.
- **15% from each tranche, proportional**: aligns with §4.4 routing rebalance.
- **Linear vest tail**: aligns founder retention through each phase of growth.
- **Funded from new supply, not existing treasury**: existing 165M treasury preserved for protocol operations.

### 3a.6 Accounting treatment

If authorized via governance, the unvested portion is carried as a balance-sheet liability per Greg's directive May 5, 2026. The Cheesecoins Financial Projections workbook reflects this on the Balance Sheet sheet (Liabilities → "Founder performance reward, committed unvested").

### 3a.7 Implementation requirements

The deployed contracts do not have any of this wired. Making the founder reward real requires:

1. **`SupplyExpansionAuthority.sol`** — encodes the trigger conditions (§4.2) and routing (§4.4) including the 15% founder slice
2. **`FounderRewardVesting.sol`** — accepts CURD from each expansion tranche, vests linearly per the schedule above
3. **Audit** — both contracts. Eligible for Arbitrum Audit Program (separate $10M ARB pool)
4. **Super NFT governance vote** — 66% supermajority, 30-day voting period, 2-day timelock. Single vote can authorize the entire framework (both contracts + initial parameters)
5. **Tranches activate sequentially** as their triggers fire — no manual founder action required until the contract is live

Stage 0 governance (founder-controlled) means Greg practically controls the vote timing, but the **mechanism** for the doc's integrity is the governance vote with Super NFT holders fully informed (this document is part of that informing).

---

## 4. Authorized supply expansion (NEW — governance-gated)

The protocol authorizes the issuance of **up to 200,000,000 additional CURD** beyond the original 200M baseline, conditional on the trigger framework below. This brings the **maximum possible total supply to 400,000,000 CURD.**

### 4.1 Why expansion may be needed

The original 200M was sized for one farm. As the protocol scales:

- **Partner growth**: 44,400 partners by Y3 in the base scenario, vs. ~10 active at launch
- **CurdDirectSale demand**: at Y3 trajectory (1M buyers × $350 avg purchase / deflationary CURD price ~$1.18), demand exceeds 200M supply
- **NFT collateral**: each Capital/Land NFT project tokenizes real-world assets that need CURD-denominated settlement
- **Liquidity depth**: Uniswap LP needs deeper paired liquidity as volume grows

Without expansion, CURD price appreciates dramatically (good for early holders, painful for new partners trying to onboard). Elastic supply matched to RWA growth keeps the unit economics workable for new entrants.

### 4.2 Trigger conditions (ALL must be true)

A new mint tranche may be authorized only when ALL of the following hold:

1. **RWA growth threshold** — total registered partners across all 5 tiers ≥ specific count (see schedule below)
2. **Settlement volume threshold** — cumulative GMV settled on-chain ≥ specific dollar amount
3. **Backing ratio maintained** — USDC treasury reserves + Uniswap LP USDC + tokenized RWA value ≥ 1.0× new circulating supply at $1 par
4. **Super NFT governance vote** — at least 51% of Super NFT holders (full 100-scene collectors) vote to authorize the specific tranche, with a **2-day ProtocolTimelock delay** before execution
5. **Quarterly mint cap** — no single quarter authorizes more than 25M CURD (max 100M per year) — prevents flooding

### 4.3 Mint schedule (subject to trigger gates)

| Tranche | Amount | RWA threshold (partners) | Settlement threshold (GMV) | Earliest authorization |
|---|---|---|---|---|
| **Tranche A** | 50,000,000 | 5,000 | $250M cumulative | After Y1 |
| **Tranche B** | 75,000,000 | 25,000 | $1B cumulative | After Y2 |
| **Tranche C** | 75,000,000 | 100,000 | $5B cumulative | After Y3 |

If any tranche's triggers are not met by the projected year, that tranche is deferred — never issued early.

### 4.4 Routing rules (where new CURD goes)

When a tranche is authorized, the new CURD is routed transparently:

| Allocation | % of tranche | Purpose |
|---|---|---|
| Uniswap CURD/USDC LP | 26% | Deepens trading liquidity proportional to user growth |
| Partner incentive program | 21% | Onboarding subsidies, retention rewards, ag-supply-chain participants |
| BootstrapYieldPool top-up | 17% | Maintains staker yield as more CURD circulates |
| Founder performance reward | 15% | Tied to milestone vesting — see §3a |
| Treasury (Gnosis Safe) | 13% | General protocol operations + future commitments |
| FxStabilityReserve top-up | 8% | Backs the FX-pegged redemption mode (Phase 2) |

Each non-founder allocation was scaled by 0.85× against the original v1 routing to make room for the 15% founder slice. Proportions remain stable across tranches A / B / C.

**The founder slice is the ONLY personal allocation in this framework.** No advisors, contractors, or other individuals receive direct allocation from supply expansion. Advisors are funded separately from the existing treasury (see Token Treasury allocations in the Financial Projections workbook).

### 4.5 Anti-dilution protections

- **Maximum total supply hard-capped at 400,000,000 CURD** in this document. Any future expansion beyond 400M requires a separate revision and a higher governance threshold (75% Super NFT supermajority).
- **Quarterly mint cap (25M CURD)** prevents flash dilution.
- **Backing ratio requirement** ensures every new CURD is backed by demonstrable RWA value, not pure inflation.
- **Routing rules forbid founder/insider allocations from expansion** — eliminates the worst-case "founder mints to self" pattern.

---

## 5. Stakeholder governance rights — actual on-chain mechanism

The deployed `SuperHolderGovernance.sol` (`0x28c72A15b2b203398918F319040c51224Dd01E52` on Arbitrum One) implements the live mechanism. **All values below are from `Config.sol` and verified on-chain May 5, 2026.**

### 5.1 Who can propose and vote

Only **Super Holders** can propose or vote. Super Holder status requires:
- Owning a complete 100-scene Nubians North NFT collection (verified via `SceneTracker.hasFullCollection()`)
- Active staking position in the staking manager (`StakingManager.getUserProjectStaked(voter, projectId) > 0`)

Becoming a Super Holder is a one-time action: call `becomeSuperHolder(uint256[] memory nftIds)` proving collection completeness.

### 5.2 Voting weight formula

Voting weight is **NOT** one-vote-per-Super-NFT. It uses a log-weighted, anti-whale formula in `GovernanceWeighting.sol`:

```
votingPower = ln(stakedCURD) × projectGrowthRate × superHolderMultiplier(2x)
```

- **Logarithmic scaling** prevents mega-whale dominance — 1M staked vs. 10M staked is only ~2.3× difference, not 10×
- **Project growth rate** multiplier rewards holders aligned with expanding projects
- **Super Holder 2× bonus** applies on top of stake-derived power

This means 100 small Super Holders can outvote one large Super Holder, by design.

### 5.3 Proposal lifecycle

| Step | Mechanism | Duration / threshold |
|---|---|---|
| **Propose** | `propose(description, target, callData)` — Super Holders only | — |
| **Vote** | `vote(proposalId, support)` — yes/no | 30-day voting period (`GOVERNANCE_VOTING_PERIOD`) |
| **Pass threshold** | Requires **66% supermajority** of cast votes | `SUPERMAJORITY_THRESHOLD = 66` |
| **Queue** | `queueToProtocolTimelock(proposalId)` routes via `ProtocolTimelock.scheduleBatch()` | Internal `execute()` is permanently disabled |
| **Timelock delay** | All passed proposals wait the timelock delay before executing | **2 days mainnet** (`TIMELOCK_DELAY = 2 days`) |
| **Execute** | After timelock elapses, anyone can execute the queued operation | — |
| **Cancel** | Admin or proposer can cancel; CANCELLER_ROLE can cancel both proposal and timelock op atomically | — |

### 5.4 What proposals can do

A passed Super NFT proposal can call any function on any contract that the protocol Safe / ProtocolTimelock has authority over. Practical examples:
- Authorize a treasury transfer (e.g., founder reward, advisor compensation, partner incentive)
- Change protocol fees on `ProjectSale`
- Authorize a new mint (when supply expansion contract is built — see §4)
- Add or remove a merchant operator
- Upgrade a proxy implementation (subject to ProxyAdmin permissions)

### 5.5 Founder weight overlay

Per §3, the founder has additional governance weight on a 5-year decentralization schedule (50% Y1 → 0% Y5). This is layered on top of the formula in §5.2. By Y5+, the founder's special weight is gone and they participate as a regular Super Holder.

### 5.6 Why this design

- **Productive participation > speculation**: Super Holder requires NFT collection completeness AND active staking. Pure token holders cannot vote.
- **Anti-whale**: log scaling prevents capital concentration from dominating governance.
- **Mandatory delay**: 2-day timelock means no flash-loan-driven attacks; community can react before execution.
- **Non-bypassable**: `SuperHolderGovernance.execute()` is permanently disabled — all execution must route via `ProtocolTimelock`. This is in the deployed bytecode.

---

## 6. Accounting treatment summary

The Cheesecoins Financial Projections workbook (`docs/CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx`) reflects the following:

| Item | Balance Sheet treatment |
|---|---|
| Original 200M CURD allocation | Documented; treasury holdings reduce equity-side asset value as CURD is sold/distributed |
| Founder performance reward (committed, unvested) | **Liability** at face value $1 × unvested CURD count |
| Founder performance reward (vested, issued) | Removed from liability; CURD is now in circulation (not protocol's obligation) |
| Authorized supply expansion (not yet exercised) | **Memo / contingent disclosure** — NOT in equity totals until issued |
| Authorized supply expansion (issued tranche) | New CURD enters circulation; routing per §4.4 hits LP, yield pool, etc. |
| Advisor vesting (3 × 50k) | Liability for unvested portion |
| Merchant float commitments | Liability = total partners × $1,000 USD float per partner |
| ARB DAO revenue share | Liability = 5% of cumulative operating revenue, capped at $225,000 |

---

## 7. Disclosure framework

This tokenomics document is the **single authoritative source** for:

- Total supply caps
- Allocation pools and their addresses
- Founder reward triggers and vesting
- Supply expansion triggers, mint caps, and routing rules
- Governance rights by stakeholder class

**Any change to this document requires:**

1. Public notice of proposed amendment (forum post or equivalent)
2. Super NFT governance vote
3. ProtocolTimelock delay (minimum 2 days mainnet)
4. Updated commit to this file in the public repository, with the AIP (Arbitrum Improvement Proposal) reference

**The public can verify at any time:**

- Original supply: on-chain via CURD token contract
- Treasury holdings: Gnosis Safe at `0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2`
- Founder reward vesting state: published quarterly + verifiable in vesting contract once deployed
- Supply expansion authorizations: each tranche logged on-chain via `MintAuthorized` event (when contract is built)

---

## 8. Open items

- [ ] **Decide whether to pursue the founder performance reward at all** (§3a). If yes:
  - [ ] Greg proposes specific pool size (10M / 15M / 20M) and milestone gates
  - [ ] Author `FounderRewardVesting.sol` (~80–150 lines, standard token vesting pattern)
  - [ ] Audit the new contract
  - [ ] Submit Super NFT governance proposal authorizing treasury transfer to vesting contract
- [ ] Build the supply expansion authorization contract (`SupplyExpansionAuthority.sol`) — only if §4 expansion is needed (Y2+ at earliest)
- [ ] Wire `MintAuthorized` events for transparency once expansion contract is built
- [ ] Submit this document for Super NFT governance ratification (currently draft)
- [ ] Cross-reference into the v2 grant application as a linked appendix

## 9. What was corrected in this version

This document was initially drafted with several inaccuracies that were corrected after reading the actual deployed contracts:

| Error in earlier draft | Corrected to on-chain reality |
|---|---|
| "51% Super NFT vote threshold" | **66% supermajority** (`SUPERMAJORITY_THRESHOLD`) |
| "1 vote per Super NFT" | **Log-weighted** voting: `ln(stakedCURD) × growthRate × 2× super holder multiplier` |
| Founder allocation listed as "20M" without verifying | Confirmed **20M** via `cast call FOUNDER_ALLOCATION()` on mainnet |
| Implied existing founder reward mechanism | **No such mechanism exists on-chain.** Marked §3a as PROPOSED, not authorized. |
| Voting period unspecified | **30 days** (`GOVERNANCE_VOTING_PERIOD`) |
| Did not document the 5-yr governance-weight decentralization schedule | Added §3 — 50% Y1 → 0% Y5 cliff, already wired in `FounderDecentralization.sol` |

The financial projections workbook (`CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx`) carries an illustrative founder-reward liability schedule (10M Y1 / 5M Y2 / 0 Y3) that reflects the proposal sketch in §3a. Once Greg + Super NFT governance ratify the actual numbers, the workbook will be updated to match.

---

## 10. Related documents

- `ARBITRUM_GRANT_APPLICATION_V2.md` — grant pitch referencing this tokenomics
- `ARBITRUM_GRANT_DISCUSSION_NOTES.md` — strategy notes including supply expansion rationale
- `CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx` — three-year P&L + Balance Sheet showing tokenomics implications
- `contracts-v2/foundry-docs/Tokenomics.ods` — original tokenomics (legacy, superseded by this v2 document)
- `contracts-v2/foundry-docs/DEPLOYMENT_STATE_2026-03.md` — deployment manifest with all contract addresses

---

*This document is a living draft. The protocol's commitment is to transparency about supply mechanics, not to perfection of the initial framing.*
