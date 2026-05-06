📜 MONETARY_CONSTITUTION.md
Cheesecoins Monetary Constitution

Version 1.0 — Pre-Launch Governance Lock

1. Purpose

This document defines the monetary, supply, expansion, burn, revenue, and governance rules governing Cheesecoins (CURD).

It is intended to:

Prevent economic drift

Anchor long-term policy

Provide clarity to token holders

Define enforceable on-chain rules

Align founder, treasury, and ecosystem incentives

This constitution supersedes conversational intent and informal interpretation.

If a rule exists here, it must map to on-chain enforcement or be explicitly marked as future-stage implementation.

2. Supply Architecture
2.1 Genesis Supply

Initial Supply: 200,000,000 CURD

Maximum Supply Cap: 400,000,000 CURD (hard cap)

The protocol is designed to begin with 200M and expand only under controlled conditions up to 400M.

No minting beyond 400M is permitted.

3. Genesis Allocation
3.1 Founder Allocation

10% of initial supply = 20,000,000 CURD

Subject to 4-year vesting

Vesting may include metric gating (see Section 7)

Purpose:

Align founder with long-term growth

Avoid short-term extraction

Ensure commitment through early-stage volatility

3.2 Treasury Allocation

Remaining genesis supply allocated to Treasury.

Treasury functions:

Ecosystem funding

Liquidity provisioning

Burn operations

Strategic investment

Team funding (future)

Expansion support

4. Founder Revenue Share

Founder receives:

1% of total ecosystem revenue

Revenue sources include:

NFT protocol fees (20% fee split)

Marketplace fees

Project management fees

Financial instrument revenue

Any Cheesecoins ecosystem revenue

4.1 Distribution Method

Revenue routed through EcosystemRevenueRouter

Founder accrues 1% claimable balance

Founder must actively claim

Distribution is claim-based (not auto-streamed)

4.2 Sunset Clause

Founder revenue share automatically ends when:

totalSupply == MAX_SUPPLY (400M)

At that point:

Founder receives no further revenue share.

Ecosystem revenue fully accrues to treasury/DAO.

5. Stage Definitions
Stage 0 — Launch → LP Activation

Active:

NFT minting

Treasury accumulation

CURD staking

Founder revenue share

Treasury discretionary burns (metric-aware)

No USDC redemption

Inactive:

Liquidity pool

Hedge

Peg mechanism

Supply expansion

DAO sovereign control

Stage 1 — LP + Hedge Activation

Triggered when:

Treasury USDC ≥ $40,000,000

Upon activation:

70–80% of treasury USDC allocated to LP

Hedge mechanics may activate

Peg logic may activate

Expansion still gated by Section 6.

Stage 2 — Expansion Governance Era

Supply may expand beyond 200M only if:

DAO vote passes

On-chain metric checks pass

Treasury backing ratio ≥ 75%

See Section 6.

6. Supply Expansion Rules

Supply expansion is prohibited unless all of the following are true:

totalSupply < MAX_SUPPLY

DAO vote passed via governance

Treasury backing ratio ≥ 75%

Treasury USDC ≥ LP threshold (or defined metric)

6.1 Backing Ratio Definition

Backing ratio is defined as:

treasuryUSDC / circulatingSupply ≥ 75%

Circulating supply excludes:

Treasury-held CURD

Vesting-locked CURD

Contract-escrowed CURD

6.2 Expansion Distribution

Future minting may allocate:

Treasury allocation

Team allocation (if approved)

Founder percentage (if constitutionally allowed at that time)

Founder revenue share does not increase from expansion beyond 1%.

7. Founder Vesting Metric Gating

Founder vesting may be conditioned on:

Treasury backing ≥ 75%

LP activation

Revenue threshold

DAO confirmation

This prevents vesting unlock during systemic stress.

8. Burn Policy

Burns are:

Treasury-only

Metric-aware

Discretionary during Stage 0

Governed during Stage 2

Burns must NOT occur if:

System is coin-starved

Circulating supply is below operational threshold

Treasury backing remains strong and supply contraction is unnecessary

Burn objective:

Stabilize supply

Maintain backing ratio

Support long-term value integrity

9. Redemption Policy

Stage 0:

No USDC redemption available.

Stage 1:

Redemption may activate only after LP + hedge deployment.

No guarantee of instant liquidity.

CURD is an ecosystem currency with phased financialization.

10. Governance Transition

Founder-controlled Stage 0 → DAO-controlled Stage 2.

Founder revenue sunsets at MAX_SUPPLY.

Burn and expansion authority transitions fully to DAO once sovereign.

End of Constitution
