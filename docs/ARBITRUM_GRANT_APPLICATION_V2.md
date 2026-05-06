# Arbitrum Foundation Grant Application — Cheesecoins Protocol (v2)

**Project:** Cheesecoins Protocol\
**Flagship implementation:** Nubians North NFT collection\
**Token:** CURD (denomination of the Cheesecoins protocol)\
**Network:** Arbitrum One (live since March 25, 2026)\
**Total ask:** $150,000 USD — Advanced Growth track, milestone-metered\
**Applicant:** Gregory Garner — solo founder, Nubians North farm (Ontario, Canada)\
**Repository:** https://github.com/garnergregg/MCP-Cheesecoins-Eco-sys\
**Web:** cheesecoins.com · nubiansnorth.com

> *Cheesecoins is the first agricultural supply-chain settlement protocol on Arbitrum — every link in the chain (vendor, producer, processor, distributor, merchant) is on-chain, paid in CURD, and reconcilable in real time. Live on mainnet. Working dairy goat farm at the center.*

---

### What's novel — the NFT primitive

Most agricultural tokenization projects pick one of three lanes: pure ownership tokens (no yield), DeFi receipts (no underlying asset), or governance tokens (no economics). Cheesecoins fuses all four into a single NFT primitive backed by a working farm.

Each Scene NFT in the Nubians North collection is, simultaneously:

- **A claim on a real-world asset** — the NFT represents a slice of a registered `Producer` in MerchantRegistry V3: a working dairy goat farm in Ontario generating real cash flow.
- **A yield-bearing financial instrument** — holders stake CURD against the NFT to earn protocol yield from the BootstrapYieldPool, and (post-Phase 2) from FX-hedge premium reserves and treasury T-bill yield.
- **A governance key** — staking enough CURD against an NFT confers Super Holder status, granting log-weighted votes on protocol upgrades and supply expansion (66% supermajority, 30-day vote, 2-day timelock).
- **A marketplace access token** — the same NFT will (Phase 2) wrap into a public fractional staking pool that lets anyone DCA into a real working farm in $5 increments — see §4.4.

The deployment side scales via a **project factory**: the deployed `CommerceNFTTemplate` proxy lets any registered producer launch their own project NFT collection through a single factory call. Today that's Nubians North. The next hundred farms onboarded under this grant inherit the same battle-tested template — no new contract development required to scale supply.

This RWA + yield + governance + access stack, all in one NFT primitive tied to an operating farm, is uncommon in DeFi. It is the protocol's structural answer to the question "why does anyone hold this NFT instead of any other?" — every utility compounds the others.

---

## 1. One-paragraph summary

Cheesecoins is a real-world-asset protocol that lets agricultural producers and the partners around them — vendors, processors, distributors, retailers — settle commerce on-chain in a single token (CURD). The protocol is live on Arbitrum One. Twelve contracts are deployed under a 2-of-2 Gnosis Safe; 200 million CURD is minted across treasury, yield pool, and direct-sale contracts; the BootstrapYieldPool holds 5,000,000 CURD for staker yield; CurdDirectSale is loaded with 10,000,000 CURD. As of May 4, 2026, **MerchantRegistry V3 is live on mainnet with a five-tier supply-chain enum** — making Cheesecoins the first protocol to formalize the full agricultural supply chain on-chain, not just a generic merchant rail. The flagship Nubians North dairy goat farm is registered as the first producer. This grant funds five workstreams measured against verifiable on-chain milestones: a six-month promotional onboarding campaign aimed at registering 30+ supply-chain partners across multiple tiers; a CURD/USDC liquidity pair; an FX-pegged redemption mode for cross-border merchants; the seed integration capital for an on-chain agricultural settlement index that fills a structural gap in DeFi data infrastructure; and consumer-facing additions (NFT-backed fractional staking pools and a real-return dashboard) that lower the user entry point and surface the protocol's economic story to a broader audience.

---

## 2. Mission: food sovereignty as freedom

Agriculture is consolidating. Small and mid-sized farms are losing access to capital, distribution, and price-discovery — not because they produce worse food, but because the financial and supply-chain rails were never built for them. Cheesecoins is a freedom-tech response: blockchain rails that level the field without forcing farms to choose between joining and surviving.

Our position is **more farms, not fewer.** The protocol is intentionally inclusive of larger operators — they participate as vendors, distributors, or merchants under the same registry as any small farm. The aim is decentralization without alienation.

---

## 3. What is live on Arbitrum One today

All of the following are deployed on Arbitrum One mainnet, owned by the Gnosis Safe `0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2`, and verifiable on Arbiscan. Full deployment manifest at `contracts-v2/deployments/42161-arbitrum-one-all.json`.

Each address below links to Arbiscan for one-click verification.

| Contract | Address | Status |
|---|---|---|
| CheesecoinsCore V2 (CURD token, 200M supply) | [`0x833551...fB89cD`](https://arbiscan.io/address/0x833551C5433551fDA5b49D03044D7Df51ffB89cD) | Live |
| NubiansNorthNFT (100 unique scenes, 500 copies each, 50,000 max supply) | [`0x4a99b2...808aAD`](https://arbiscan.io/address/0x4a99b2Dc6d5D4745148F13C06965508306808aAD) | Live; 100 minted to date |
| StakingManager | [`0xcfbd9e...cb35B6`](https://arbiscan.io/address/0xcfbd9e4B97DD40863b134e7979d3038Ec5cb35B6) | Live |
| BootstrapYieldPool | [`0x27b55A...9DE68C`](https://arbiscan.io/address/0x27b55A7fFaeD5df6f174bb29fc2D8f08329DE68C) | **Funded with 5M CURD** |
| CurdDirectSale | [`0x31ea59...12d10D`](https://arbiscan.io/address/0x31ea59d272472B8B2BBF1a7b58fCB0433712d10D) | **Loaded with 10M CURD** |
| ProjectSale | [`0x07FC04...71E7fc`](https://arbiscan.io/address/0x07FC042B155628980aA5B00EB9B53D3B3D71E7fc) | Live (no projects registered yet) |
| CommerceNFTTemplate (impl) | [`0xAe2fe1...66dabf`](https://arbiscan.io/address/0xAe2fe166c61c5e343283a7AEA9C1C00cb466dabf) | Live |
| **MerchantRegistry V3** (5-tier supply-chain enum) | [`0xCA7f73...8709bA`](https://arbiscan.io/address/0xCA7f73aCb86a8aCEf897c06eE23Adf8cDf8709bA) | **Live; Nubians North registered May 4 2026** |
| MerchantSettlement | [`0x94AA0B...da5FE0`](https://arbiscan.io/address/0x94AA0B5A4F3593FCd5c66A88A0De5deF0dda5FE0) | Deployed (config pending) |
| FiatRedemptionVault | [`0x9c293c...737274`](https://arbiscan.io/address/0x9c293c2C866278F1e3AF0ce6689fd2e451737274) | Deployed (funding pending) |
| TreasuryRateAdvisor | [`0x53aB92...1Ec77f`](https://arbiscan.io/address/0x53aB925B462b016535A1F077113d79c6681Ec77f) | Live |
| ProtocolTimelock | [`0x0E7d11...9ebb5C`](https://arbiscan.io/address/0x0E7d119224855ca259a80cb0C0a6a82fa29ebb5C) | Live |

**Treasury verifiable on-chain right now:** the Safe holds 165,000,000 CURD; the yield pool holds 5,000,000 CURD; the direct sale holds 10,000,000 CURD. Total accounted: 180M of the 200M supply.

**Audit posture:** in-house Foundry test suite under `contracts-v2/foundry-test/` — **859 tests passing** across all production contracts (CURD core, NFT, staking, sale, commerce, monetary, governance, options). Static analysis via **Slither** (most recent run May 2 2026) — output triaged against the manual audit findings; pattern-flag false positives (mock-contract immutables, `nonReentrant`-protected external calls following the checks-effects-interactions pattern, bounded administrative loops) documented and accepted. Manual contract-by-contract security audit (`contracts-v2/foundry-docs/SECURITY_AUDIT_REPORT_2026-03.md`) — 27 substantive findings identified; all critical-through-low severity remediated and verified, two info-severity items deferred with rationale. Mainnet-fork simulation required pre-broadcast for any state-changing upgrade. Third-party audit will be sought via the **Arbitrum Audit Program** (separate $10M ARB pool) — see Section 7.

### 3.1 The 5-tier registry — what it actually does

Every economic actor in the food chain registers in one on-chain registry, with a `tier` enum:

| Tier | Role | Real example |
|---|---|---|
| Vendor | Sells inputs / raw materials to a producer | Feed supplier, equipment vendor |
| Producer | Turns raw inputs into a primary product | Greg / Nubians North |
| Processor | Adds value (cheese, packaging, abattoir) | Local cheese plant |
| Distributor | Bulk movement to retailers | Wholesaler |
| Merchant | Sells to end consumers | Retailer, restaurant, market stall |

The registry was upgraded from V2 to V3 on May 4, 2026 — single-tx Gnosis Safe upgrade, mainnet-fork-simulated pre-broadcast, both pre-existing merchants preserved with default `Tier.Merchant`. The full chain Greg already operates day-to-day (Graham Farms → Nubians North → cheese plant → wholesaler → retail) is now expressible on-chain in a single registry, with tier-aware payment routing through `MerchantSettlement`.

This is the headline differentiator. Anyone can ship a "merchants accept token" rail. Cheesecoins models the **whole chain**.

---

## 4. What is proposed and grant-funded

We are explicit about the line between what exists and what the grant funds. Five workstreams sit downstream of the live-on-mainnet base:

### 4.1 Partner onboarding across all five tiers — promotion-led, the headline grant deliverable

Live registry plus a working POS phone app on cheesecoins.com is the technical foundation. The grant funds **the activity that turns a deployed registry into a live commerce network**: in-person partner onboarding, gas subsidies for first-time merchants, materials in English and French, and a follow-on rollout into the US South via existing operator contacts in Georgia and Mississippi.

### 4.2 FX-pegged redemption mode — Phase 2 deliverable

Cross-border ag commerce (Canada → US) inherently has FX risk. A vendor accepts CURD when CAD/USD is at one rate and cashes out at another, the protocol gets blamed for FX losses that aren't its fault. The proposed `FxPeggedRedemption` mode pegs the merchant's redemption value to the USD/CAD rate at receipt time (read via Pyth, already integrated in the Sepolia options market), funded by a small per-tx premium to a stability reserve. Merchants get **CAD-stable settlement automatically**; the protocol earns predictable revenue from the premium spread; the reserve overflow flows back to NFT holders. Built and audited under the grant; mainnet deploy after audit clears.

### 4.3 Cheesecoins Agricultural Settlement Index — Phase 2/3 deliverable

The `CheesecoinsOptionsMarket` is live on Sepolia (corn, wheat, soybeans, USD/CAD) but **NOT being shipped to mainnet on the current data quality**. Reason: USDA AMS publishes weekdays only — Friday-close prices are stale through Monday, which is fine for testnet validation but unacceptable for real-money exercise.

We verified in April 2026 that **no oracle on any chain currently provides reliable agricultural settlement prices** — Pyth has 6 of 7 ag commodity feeds dead, Chainlink has zero ag feeds, RedStone/API3/Supra advertise but don't publish. This is a structural DeFi data gap, not a Cheesecoins-specific limitation.

The grant funds the seed integration of a derived CME-based settlement index — `CommodityPriceOracle` v2 with multi-keeper redundancy, real-time CME-derived ingestion, and a public consumption interface (`getPrice(marketId)` already deployed). Other DeFi protocols then consume the index; Cheesecoins becomes the on-chain settlement index for agricultural commodities, not a downstream consumer of someone else's feed.

CME outreach is in flight (initial contact sent May 5, 2026); the grant's modest CME line item is seed integration capital while the data-licensing terms are negotiated directly.

### 4.4 NFT-Backed Fractional Staking Pools — Phase 2 deliverable

The protocol's current staking minimum is **100 CURD per NFT position** (`Config.MIN_STAKE_PER_NFT` enforced in `StakingManager.sol`). For young or budget-constrained users — the audience most likely to convert on the "support a real farm + earn yield + revolt against the system that bleeds you" pitch — a $100 minimum is a meaningful barrier.

The proposed `FractionalStakingPool.sol` lets every existing Nubians North NFT operate as a yield-bearing deposit pool accepting **micro-deposits as small as $5 in CURD**. The pool aggregates contributions from many small users, stakes the aggregate against the underlying NFT once the protocol minimum is hit, and distributes earned yield proportionally to depositors. The NFT holder running the pool earns a **small management fee** — turning collection ownership into a recurring revenue stream and creating a real economic incentive to acquire and hold Scene NFTs beyond their initial collectible appeal.

**Mechanism: delegated staking via StakingManager V2 upgrade.**

The `StakingManager` proxy (`0xcfbd9e4B97DD40863b134e7979d3038Ec5cb35B6`) is upgraded to V2 implementation with a new `stakeFor(nftId, amount, lockMonths, onBehalfOf)` function callable by NFT-owner-approved addresses. The NFT stays in the original holder's wallet; the `FractionalStakingPool` contract is approved (per-NFT, revocable) to stake the aggregated deposits on the holder's behalf. Yield distribution honors the original holder's Super Holder status — meaning **the holder keeps governance rights** while their NFT is generating pool revenue.

A custodial-pool alternative (NFT transferred into pool, pool becomes owner) was evaluated and rejected. While simpler to ship, it strips the original holder of Super Holder governance status during the period their NFT backs the pool — a non-trivial concession that misaligns long-term holder economics with governance participation. The delegated design preserves both.

Implementation involves a small upgrade to the existing `StakingManager` proxy (introducing a delegated-staking entry point so a pool contract can stake on a holder's behalf without taking custody of the NFT), a new aggregating pool contract that batches dollar-scale deposits up to the protocol minimum and distributes yield pro-rata to depositors, full Foundry test coverage of the V1→V2 migration plus pool aggregation and yield distribution, third-party audit via the Arbitrum Audit Program (separate $10M ARB pool), and a Super NFT governance proposal authorizing both changes (66% supermajority, 30-day vote, 2-day timelock) before execution. The upgrade is purely additive — backwards-compatible at the proxy level — and surfaces a deposit UI on cheesecoins.com once authorized.

Neither side modifies the existing `NubiansNorthNFT` contract. The work is purely additive: a backwards-compatible StakingManager upgrade + new pool contract.

Practical impact: lowers the user entry point from $100 to $5, opens the protocol to the recurring-micro-investment pattern ("DCA $5/month into a real farm"), and aligns long-term NFT-holder economics with broader user adoption.

### 4.5 Real Return Dashboard — Phase 2 frontend deliverable

**Proposed under this grant — does not yet exist on cheesecoins.com.** A single public page at `cheesecoins.com/inflation` that surfaces the protocol's economic story in plain English: **CURD is dollar-tracking** (USDC-backed); the inflation hedge is realized via staking. That nuance is currently buried in the technical docs.

The dashboard surfaces a real-return number — staker yield minus US CPI year-over-year — pulled from authoritative free public data (Federal Reserve FRED) plus on-chain reads from the protocol. Calibrated to honest math:

> *"Holding dollars lost you ~3% to inflation last year. Staking CURD earned you ~5% in yield. Real return: +2%. Updated daily."*

Staker yield is one of several economic surfaces in the protocol — alongside commerce fees, FX hedge premium, and (post-CME integration) Settlement Index subscriptions. This dashboard surfaces the consumer-facing one. Full revenue breakdown is in §8; modeled financial projections (P&L, cashflow, balance sheet, scenarios across Y1–Y3) live in `docs/CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx`.

The deliverable gives Tier 1A and 1B audiences a concrete sharable artifact addressing the "savings are eroded by holding dollars" pain point, and provides a content engine for the Annie + Alice educational channel — daily inflation-vs-yield commentary writes itself. Built under the grant by extending the existing Next.js front-end; no smart-contract changes required.

---

## 5. Why Arbitrum

The protocol's core unit economics — settling small merchant transactions in CURD, distributing micro-rewards across thousands of NFT holders, and producing on-chain food-safety records, supply-chain provenance, and HACCP-grade audit trails across the production chain — only work on a chain where a transaction costs cents, not dollars. Arbitrum's combination of low fees, Ethereum-equivalent security, and the deepest L2 stablecoin liquidity is the only environment where this protocol is economically viable.

Specific Arbitrum-native dependencies:
- Native USDC on Arbitrum (`0xaf88d065...`) as the protocol's on-ramp asset
- **Uniswap V3 on Arbitrum** as the venue for the CURD/USDC pair, deployed at the 0.05% stablecoin fee tier (the standard for pegged-pair pools). Chosen for aggregator routing priority (1inch / Matcha / Paraswap / 0x all source Uniswap V3 first), broadest wallet UX, and lowest discovery friction for new buyers
- Gnosis Safe on Arbitrum One as the existing treasury custodian
- Arbiscan as the merchant- and consumer-facing verification surface
- Pyth Network on Arbitrum as the FX oracle for the FX-pegged redemption mode

---

## 6. Roadmap and milestones

Grant disbursement tied to verifiable on-chain milestones. Every trigger reads from public Arbitrum One state — reviewers can independently verify via `cast logs` or Arbiscan.

| # | Milestone | Trigger (on-chain verifiable) | Disbursement |
|---|---|---|---|
| **M0** | **Grant accepted, kickoff** | Grant agreement signed | $20,000 promotion tranche 1 |
| **M1** | **First 5 partners onboarded** across at least 2 tiers | 5 distinct addresses with `setMerchantWithTier` events on `MerchantRegistry`; tier diversity verifiable from event data | $20,000 promotion tranche 2 |
| **M2** | **15 partners onboarded** across at least 3 tiers, with at least one settled CURD payment per partner | 15 unique `MerchantStatusChanged` events + 15+ `MerchantSettlement` events | $20,000 promotion tranche 3 + $20,000 liquidity tranche (CURD/USDC pool seeded) |
| **M3** | **30 partners onboarded** across all 5 tiers + first Commerce NFT project sold-out | 30 `MerchantStatusChanged` events covering all 5 `Tier` enum values + one `ProjectSale` `SaleClosed` event | $20,000 promotion tranche 4 |
| **M4** | **FxPeggedRedemption module audited and deployed to mainnet** | Audit report published; module deployed and configured on `FiatRedemptionVault` proxy | $6,000 audit + contingency + $18,000 founder development (paid against monthly delivery milestones, 6 months) + $6,000 external contractor (M4-stage deliverables) + $12,000 ops stipend (6 months) = $42,000 |
| **M5** | **CME data agreement signed; first integration test live on Sepolia** | Signed agreement evidence + on-chain price update events from CME-derived data on `CommodityPriceOracle` | $8,000 (CME data seed) |

**Per-tier breakdown for M3** (30 partners across all 5 tiers):

| Tier | Target count | Rationale |
|---|---|---|
| Merchants (retailers, restaurants, market stalls) | 12 | Largest tier by population — most fertile recruiting ground; conversion is fastest |
| Vendors (feed, equipment, input suppliers) | 7 | Existing relationships from Greg's farm operations make first-cohort recruiting straightforward |
| Producers (farms — direct peers of Nubians North) | 5 | Higher per-partner value but lower-count; recruited via direct relationship |
| Distributors (wholesalers) | 3 | Smaller universe, longer sales cycle; floor of 3 demonstrates the supply-chain story |
| Processors (cheese plants, abattoirs) | 3 | Same — higher complexity, smaller universe |
| **Total** | **30** | All 5 tiers represented; tier diversity verifiable from `MerchantTierSet` event data |

The breakdown reflects the realistic Ontario small-ag ecosystem composition: many retailers and input vendors, fewer specialized processors and distributors. Reviewers can verify tier coverage at any time by reading `MerchantTierSet(address indexed merchant, Tier indexed tier)` events on the registry contract.

**Soft cost per merchant: ~$100 average.** Components per partner:

- Gas subsidy: $5 (Arbitrum is cheap)
- Printed onboarding materials in English + French: $10
- 30-minute video onboarding call (founder time, attributed at modest hourly): $40
- Travel + booth time at regional farmers' markets / events: $40 (averaged across in-person and remote partners)
- Misc + buffer: $5

Total soft cost across 30 partners ≈ $3,000 — small fraction (~3.75%) of the $80,000 promotion budget. The bulk of the promotion bucket funds paid acquisition programs (boost campaigns, partner incentive payments at gates), not direct soft cost.

All triggers are verifiable on-chain or in published artifacts — no subjective milestones.

---

## 7. Budget breakdown — $150,000 total

Promotion-led structure, milestone-gated, on-chain auditable.

| Bucket | Amount | % | Release gate |
|---|---|---|---|
| **Promotion + partner incentives** | **$80,000** | **53%** | Tranched $20k upfront, $20k each at 5 / 15 / 30 partner thresholds (see M0–M3) |
| **Founder development** | $18,000 | 12% | $3k/month × 6 months, milestone-tied development & maintenance |
| **External contractor capacity** | $6,000 | 4% | Reserved against M4 deliverables (FxPegged audit prep, multi-keeper infra). Hired as needed against specific deliverables, not a standing salary. |
| **Liquidity tranche** (CURD/USDC seed on Arbitrum DEX) | $20,000 | 13% | Released at M2 when pool deploys at calibrated start price |
| **Ongoing operations stipend** (multi-keeper infra, uptime, support) | $12,000 | 8% | $2k/month × 6 months |
| **CME data seed** | $8,000 | 5% | M5: released on first paid CME integration test |
| **Audit + contingency** | $6,000 | 4% | M4: layers with the separate Arbitrum Audit Program application |

**Total: $150,000.**

Why this shape:
- Founder is solo. Time is the binding constraint, not capital. Most of the ask funds the activity that compounds (promotion + onboarding) instead of one-off infrastructure.
- Promotion-as-gate produces verifiable on-chain progress; reviewers can `cast logs` on the registry instead of reading status reports.
- CME at $8k seed (not a 12-month license commitment) — Greg is negotiating usage-based terms with CME directly. The grant funds initial integration, not perpetual licensing.
- Audit is deferred to the Arbitrum Audit Program (separate $10M ARB pool); the $6k contingency layer is for findings-remediation gas costs and final attestation.

---

## 8. Sustainability and revenue share back to Arbitrum DAO

Cheesecoins is not asking for perpetual subsidy. The grant is the **runway** for a sustainable subscription business; post-grant, the protocol covers its own infrastructure costs from:

1. Protocol fees on commerce (5% commerce / 2.5% capital, baked into `ProjectSale`)
2. Subscription fees from consumer protocols using the Cheesecoins Agricultural Settlement Index
3. FX hedge premium spread (post FxPeggedRedemption mainnet deploy)

**Revenue share back to Arbitrum DAO:**

> Subscription-fee revenue from consumer protocols accruing to the Arbitrum DAO treasury at **5%**, **capped at 1.5× grant amount** (cumulative payback ≤ $225,000), or **36 months from launch, whichever comes first**. After cap is met, share drops to 0%.

Why 5% / 1.5×:
- Bounded enough to keep the protocol attractive to future investors / lenders
- Generous enough to signal serious commitment to fairness ("we'll pay you back 50% premium when it succeeds")
- Aligned with the zkFetch precedent (3% / 10% revenue share to DAO) but capped to avoid unbounded liability

---

## 9. KPIs reported quarterly

All metrics derivable from on-chain events. No self-reported numbers.

- Partners registered, broken down by `Tier` enum value (`MerchantRegistry` `MerchantStatusChanged` + `MerchantTierSet` events)
- Total settlement volume (sum of `MerchantSettlement` event amounts)
- CURD/USDC pool depth and 30-day volume
- Active wallets paying via the merchant rail (90-day rolling)
- Commerce NFT projects launched and sold (ProjectSale events)
- Settlement Index oracle uptime % and freshness lag (post-M5)
- NFT secondary market activity on Nubians North scene collection

---

## 10. Geographic rollout

**Phase 1 — Ontario, Canada:** founder's home jurisdiction. Existing partner relationships across all five tiers (raw milk supplier Graham Farms, the cheese plant downstream, Nubians North as producer, regional retailers and direct-to-consumer markets). Lower-friction onboarding for the first 5–15 partners.

**Phase 2 — US South (Georgia and/or Mississippi):** the founder has existing operator contacts in both states. Georgia has a strong dairy and direct-to-consumer farm-market corridor; Mississippi has ag commerce volume but is underserved by fintech. Cross-border CA→US ag commerce naturally introduces the FX risk that the FxPeggedRedemption mode (Section 4.2) exists to solve — the geographic plan and the technical roadmap reinforce each other.

---

## 11. Team and growth structure

**Founder (current).** Gregory Garner — solo founder. Operates Nubians North dairy goat farm in Ontario, Canada. Has been building the Cheesecoins protocol since April 2025 — 13 months of solo work as of submission. Solidity / Foundry on the contract side; Next.js + Thirdweb on the front-end at cheesecoins.com. Treasury secured via 2-of-2 Gnosis Safe (Ledger + MetaMask). Documentary on the project ("The Money That Feeds You") on YouTube.

**Background.**

Greg grew up on a registered Holstein dairy farm but couldn't buy his way into Canada's quota-locked dairy system as a young farmer — so he had to move on from that dream. He earned an Ag Production and Management degree from University of Guelph's Ridgetown Campus, worked breeding-stock exports for Rowntree Farms and Cormdale Genetics, ran Manderley's turfgrass operation for five years, and then built Elevated Landscape Technologies — a green-roof and living-wall company the 2008 housing crisis nearly destroyed.

The years he spent fighting banks to recover from 2008 — and refusing to file bankruptcy, despite the pressure to do so — taught him how the monetary system actually works. One banker said it to his face: *"we don't need to work with you — we need a certain number of bankruptcies a year anyway."* Greg never became one of those statistics, but the line stuck. That sent him down the rabbit hole. He started following Bitcoin, watched the protocol design space mature, and eventually came back to dairy through goats — specifically because goats sit outside the quota system that had locked him out as a kid. Cheesecoins is the synthesis of that journey: food, freedom, and farming combined into a protocol designed as both an exit strategy from a system that pulls the rug out from under small operators on schedule, and a wealth-builder for the next generation that's tired of being told to wait their turn.

Father, Husband and now Grandfather, Greg has a vested interest in effecting change and creating an environment where financial freedom (same as Freedom) can be a reality for generations to come. Hobbies are playing guitar, writing songs, playing hockey. Generally referred to as a laughing stock by people watching him fight the system, and as a tough SOB by everyone who's actually been in the trenches with him.

**Advisory committee (forming).** A three-person advisory committee is being assembled to provide strategic counsel through the grant period. Compensation is structured as a CURD treasury allocation with vesting (no grant funds used for advisor compensation). Target areas of expertise: (a) agricultural commerce and supply-chain operations, (b) Solidity / smart-contract security, (c) DeFi go-to-market and partner growth. Names will be published before milestone M2 disbursement.

**Contractor capacity (reserved).** $6k of the grant budget is held against specific M4-stage deliverables (FxPegged audit prep, multi-keeper oracle infra). Engaged on a per-deliverable basis, not as a standing salary. This keeps the operation lean while providing structured surge capacity when audit-grade work is in flight.

**Parallel ecosystem support.** We will apply to the **Arbitrum Mentorship Program** Cohort 2 when applications open. The protocol matches the program's eligibility profile (early-stage builder, working prototype on Arbitrum, MVP/seed stage). Mentorship Program engagement is independent of this grant — no overlap or double-funding.

---

## 12. Risk and honesty disclosures

- The protocol is **founder-controlled at Stage 0 governance.** Decentralization is gradual and already wired on-chain: the deployed `FounderDecentralization` contract reduces founder governance weight on a 5-year linear schedule (50% Y1 → 40% Y2 → 30% Y3 → 20% Y4 → 10% Y5 → 0% cliff at Y5+). Super NFT holders gain proportional weight. This is documented in `docs/TOKENOMICS_V2.md` §3.3 and verifiable on Arbiscan.
- **Founder allocation is locked in 4-year linear vesting.** The full 20M CURD founder allocation was transferred into `FounderVestingWallet` (`0xbac3d40668Ce4030ab5D8cF0bBCFDA457E1216f5`) on May 5, 2026 with `start = March 25, 2026` (original mainnet launch date) — restoring the originally-designed vesting schedule that was authored at launch but not deployed. As of grant submission, ~2.8% (~575k CURD) is vested; the rest remains locked. Verifiable on-chain: `cast call <vesting> "releasable()(uint256)"`.
- One operations wallet was compromised on March 28, 2026 via an EIP-7702 delegation attack during an unrelated ENS interaction (~$130 lost). Mainnet was never exposed; the Safe was cleaned the same day. Sepolia testnet contracts deployed by that wallet are quarantined; the Sepolia stack was redeployed under a clean key on May 2, 2026 and the V3 registry upgrade was tested end-to-end on Sepolia before mainnet. Full incident notes in repo memory.
- The protocol carries **no debt and has no outside investors.** The grant is the first external capital.
- **Mainnet options market is intentionally NOT shipping yet.** The current Sepolia oracle (USDA AMS keeper) is fine for testnet but stale on weekends — unacceptable for real-money exercise. Phase 2 deliverable, contingent on the CME data integration. We'd rather miss a ship date than expose users to weekend-stale settlement.

---

## 13. Verifiable links

**On-chain (Arbiscan):**
- Treasury Safe (2-of-2 Gnosis): https://arbiscan.io/address/0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2
- CURD token: https://arbiscan.io/address/0x833551C5433551fDA5b49D03044D7Df51ffB89cD
- MerchantRegistry V3 (verified): https://arbiscan.io/address/0x033435CA67B79aCe3d9052157c34a584a5A8FDE9
- FounderVestingWallet (verified): https://arbiscan.io/address/0xbac3d40668Ce4030ab5D8cF0bBCFDA457E1216f5
- FounderDecentralization (governance schedule): https://arbiscan.io/address/0xC2378eC98B8Aedf8E748b86775739F25F2CCE86a

**Repository:**
- Source code: https://github.com/garnergregg/MCP-Cheesecoins-Eco-sys
- Mainnet manifest: https://github.com/garnergregg/MCP-Cheesecoins-Eco-sys/blob/main/contracts-v2/deployments/42161-arbitrum-one-all.json
- Tokenomics V2 spec: https://github.com/garnergregg/MCP-Cheesecoins-Eco-sys/blob/main/docs/TOKENOMICS_V2.md
- Financial projections workbook: https://github.com/garnergregg/MCP-Cheesecoins-Eco-sys/blob/main/docs/CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx

**Public:**
- Live front-end: https://cheesecoins.com
- Flagship NFT project: https://nubiansnorth.com
- Documentary ("The Money That Feeds You"): https://youtu.be/fqVk4zsG7Go

---

## TBDs to resolve before submitting

**Resolved May 6 2026 (drafted; awaiting Greg's stamp or rewrite):**

1. ~~Per-tier merchant breakdown for M3~~ — **DONE.** Section 6: 12 merchants / 7 vendors / 5 producers / 3 distributors / 3 processors = 30 total.
2. ~~Soft cost per merchant~~ — **DONE.** Section 6: $100 average per partner with component breakdown; total ~$3k of $80k promo budget.
6. ~~Rev share % final~~ — **DONE.** Locked at **5% capped at 1.5× grant ($225k cumulative)** or **36 months from launch, whichever first.** Confirmed by Greg May 5.

**Drafted, awaiting Greg's stamp or edit:**

3. **CME integration timing** in M5 — depends on CME's reply (sent May 5, follow-up trigger May 19). Currently reads "signed agreement evidence + on-chain price update events" — may need to soften timing language closer to submission if CME hasn't replied.
4. ~~Founder background paragraph~~ — **DONE May 6.** Drafted from Greg's bullet-point bio, then edited by Greg in his own voice. Three generations of stake (Father / Husband / Grandfather) and the "financial freedom = Freedom" framing locked in.
5. ~~Build duration~~ — **DONE May 6.** Building since April 2025 = 13 months of solo work as of submission.

**Still depends on external state:**

7. ~~DEX choice~~ — **DONE May 6.** Uniswap V3 on Arbitrum, 0.05% stablecoin tier. Chosen over Camelot V3 for aggregator routing priority, broader wallet UX, and lower discovery friction for non-Arbitrum-native users. Camelot considered for Year-2 secondary venue. Section 5 updated.
8. **Advisory committee names + bios** (Section 11) — three advisors covering ag commerce, smart-contract security, DeFi GTM. Target: published before M2 disbursement. Drafted as "names to be published before M2" — acceptable for submission.
9. **CURD treasury allocation for advisor compensation** — exact CURD amount + vesting schedule per advisor. Sketch is 50k each = 150k total. Spec'd in `project_advisory_committee_structure.md` memory.
10. **Mentorship Program Cohort 2 application** — watch the [Arbitrum Foundation blog](https://blog.arbitrum.foundation/) for Cohort 2 announcement. Tracked in `project_arbitrum_mentorship_program.md` memory.
