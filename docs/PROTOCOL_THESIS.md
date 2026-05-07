# Cheesecoins Protocol — Thesis

**What Cheesecoins is, why it exists, and how it's structurally different from everything else calling itself agricultural tokenization.**

---

## The thesis in one breath

Cheesecoins tokenizes **productive capacity**, not assets. NFTs are issued against verified business plans. NFT holders extend capital against an operation's future cash flow and earn protocol yield in return. The function being performed is **agricultural banking** — capital provision against verified productive intent, in exchange for yield. Cheesecoins does it cheaper, faster, and openly, where banks do it expensively, slowly, and exclusively.

---

## Why it exists

**Food sovereignty and financial freedom are the same idea said two different ways.**

Both are about escaping dependence on systems that can fail you — industrial food supply, or centralized banking. The people who feel that deeply already live the values Cheesecoins is built on. They are not a niche. They are a growing majority.

Real things — soil, animals, labour, community — have value that no bank can print away. Agriculture is consolidating. Small and mid-sized farms are losing access to capital, distribution, and price discovery — not because they produce worse food, but because the financial and supply-chain rails were never built for them. Cheesecoins is a freedom-tech response: rails that level the field without forcing farms to choose between joining and surviving.

Position: **more farms, not fewer.** The protocol is intentionally inclusive of larger operators — they participate as vendors, distributors, or merchants under the same registry as any small farm. The aim is decentralization without alienation.

---

## How it's structurally different from REIT-style ag tokenization

Most agricultural tokenization projects monetize **assets** — fractional ownership of land, barns, equipment, livestock. Investors buy a piece of a static asset; return depends on resale or rent. That's REIT-style. It's structurally indistinguishable from what banks have done with farm assets for a hundred years, just with a token wrapper.

Cheesecoins is built differently. Each NFT tokenizes **productive capacity** — a claim against the future cash flow a real operation will generate as it scales.

| | REIT-style ag tokenization | Cheesecoins |
|---|---|---|
| What's tokenized | Static assets (land, barn, herd) | Productive capacity (future cash flow from growth) |
| Holder relationship | Fractional owner of the asset | Capital provider against operation's growth |
| Return mechanism | Resale appreciation, rent income | Protocol yield from productive activity |
| Securities-law shape | Almost always an investment contract | Closer to a productive-capacity bond (structural intent; legal status jurisdiction-specific) |
| Gate to participate | Capital + KYC + bank approval | NFT ownership |
| Bank involved | Yes — origination, custody, fees | No — protocol replaces the bank function |

---

## Three design choices that lock in the thesis

**1. The NFT is the only gate.**
No staking, no governance weight, no fractional pool participation, no Super Holder rewards exist without an NFT. Every CURD-holder seeking yield is also a project supporter — by construction. The NFT is primary demand, not afterthought.

**2. Yield comes from productive activity, not asset rent.**
Stakers earn from the BootstrapYieldPool, FX-hedge premium reserves, T-bill yield on USDC reserves, and Phase 2 fractional-pool management fees. None of this depends on NFT secondary-market appreciation or on rent flowing from tokenized infrastructure.

**3. Production-receipt framing, not equity claim.**
Holders are capital providers earning protocol yield against the farm's growth — not co-owners of the farm or the protocol. Structural intent is closer to a productive-capacity bond than a fractional-equity ownership token. (Specific legal status is jurisdiction-dependent and requires counsel; framing here is design intent only.)

---

## Integration of the full agricultural supply chain

The same primitive — NFT issued against a verified productive plan, gating yield — scales across every link in the chain. MerchantRegistry V3 (live since May 4, 2026) formalizes this on-chain with a five-tier enum:

- **Vendors** — feed, equipment, input suppliers
- **Producers** — farms (Nubians North as flagship)
- **Processors** — cheese plants, abattoirs, value-add
- **Distributors** — wholesalers, regional logistics
- **Merchants** — retailers, restaurants, market stalls

All settle in CURD on-chain. NFT holders extend capital that funds growth. Yield from productive activity flows back. Bank-style intermediation collapses into a single integrated protocol.

---

## What's standing today (May 7, 2026)

**Live on Arbitrum One mainnet under 2-of-2 Gnosis Safe (`0x6C64ACd0...`):**

- 12 production contracts deployed and verified on Arbiscan
- MerchantRegistry V3 (5-tier enum) — live, Nubians North registered as first producer
- NubiansNorthNFT — 100 unique scenes, 500 copies each, 50,000 max supply, 100 minted to date
- StakingManager — NFT-gated, 100 CURD minimum stake per NFT
- BootstrapYieldPool — funded with 5,000,000 CURD
- CurdDirectSale — loaded with 10,000,000 CURD
- ProjectSale proxy — live, no projects registered yet
- CommerceNFTTemplate — factory pattern for per-partner NFT collections
- FxPeggedRedemption module — deployed, configuration pending
- FiatRedemptionVault — deployed, funding pending
- TreasuryRateAdvisor, ProtocolTimelock, SuperHolderGovernance, FounderDecentralization, FounderVestingWallet — all deployed
- Pyth Network FX oracle — integrated on Sepolia options market
- USDA grain price keeper — running on scheduled cron

**Test posture:**
- 859 Foundry tests passing across all production contracts
- Slither static analysis run May 2, 2026 — output triaged and documented
- Manual security audit (`SECURITY_AUDIT_REPORT_2026-03.md`) — 27 findings, all critical-through-low remediated

---

## What this grant funds (Arbitrum Foundation $150k Advanced Growth)

| Milestone | Deliverable | Target |
|---|---|---|
| M0 | Grant accepted, promo campaign launches | Jul 2026 |
| M1 | 5 partners across 2+ tiers | Jun 2026 (pre-grant) |
| M2 | CME data agreement signed; Settlement Index integration test live on Sepolia | Jul 2026 |
| M3 | 15 partners across 3+ tiers, CURD/USDC pool live on Uniswap V3 | Aug 2026 |
| M5 | FxPeggedRedemption audited and deployed to mainnet | Aug 2026 |
| M6 | 30 partners across all 5 tiers | Dec 2026 |

Plus consumer-facing additions: NFT-backed fractional staking pools (lowers user entry from 100 CURD to $5 CURD via delegated staking design) and a Real Return Dashboard surfacing inflation-adjusted yield in plain English.

Repayment to the Arbitrum DAO begins on the earliest of:
- M4 (first Commerce NFT project fully sold out)
- M7 (Nubians North 50% sellout — 25,000 of 50,000)
- Subscription rev-share from Settlement Index consumers (M2 forward)

Capped at 1.5× grant ($225k cumulative) or 36 months from M2.

---

## Roadmap — beyond this grant

**Real-world-asset NFTs.** A relatively small lift atop the existing primitive. NFTs issued against tokenized real assets (equipment, livestock, infrastructure) using the same staking-gate and yield-routing structure. Today's productive-capacity primitive extends naturally; new asset-class definitions and oracle integrations are the marginal work.

**Farm Planner.** Web application for businesses to submit verified business plans. Plan goes through validation → NFT issued against the plan → capital flows to the business as the NFT sells → yield routes back as the operation produces. Already started.

**Agricultural finance services** (per the original tokenomics opportunity model). The protocol's primitive scales to:

- Equipment loans, operating credit, leases — projected $3M revenue line at scale
- Equipment + building insurance — $1M
- HACCP compliance verification — $1.5M
- Organic certification verification — $1.5M
- Farm business planning tools — $500k
- Accounting / bookkeeping services — $1M
- All settling in CURD, all on-chain

This is the "bank for agriculture, but cheaper and integrated" buildout. Each service is a distinct contract layer atop the same NFT-gated yield primitive.

**Food Box.** Consumer-facing product. Bigger lift than RWA NFTs — involves logistics, fulfillment, B2C UX, regulatory compliance for direct-to-consumer food sales. Deferred until protocol-side mechanics are mature and partner network is dense enough to source.

---

## How to position externally

Lead with the farm and the values, not the NFT. Recovered from earlier positioning work:

> *"This is a real farm in northern Ontario. Real goats. Real milk. Real cheese. Real people who have been doing this for years. Now you can be part of it — not as a customer, but as a stakeholder."*

The NFT is how you join. The farm is why you join. **Buyers are customers. Members are community. Cheesecoins wants members.**

For technical and investor audiences, lead with the productive-capacity-tokenization framing and the bank-replacement angle. The four utilities each NFT carries (RWA claim, yield-bearing instrument, governance key, marketplace access token) are the proof of the design — surface them after the thesis is established, not as the headline.

---

## Source of truth

This doc is the canonical positioning reference for Cheesecoins. Any external copy — grant pitches, investor decks, marketing site, press, partner outreach — should derive from here. When the protocol's reality changes (new contracts deployed, new milestones hit, roadmap items completed), this doc gets updated and downstream copy follows.

Last updated: May 7, 2026
