# Phase 2 — Full Protocol Spec
*Updated: April 15 2026 — All decisions resolved. Ready to build.*

This spec defines the complete Phase 2 build. All open decisions have been answered by Greg.
Decisions are recorded in Section 11.

---

## 1. Vision

The Cheesecoins protocol is a multi-party agricultural commerce network.
Every economic relationship between participants — farmer to retailer, farmer to
end user, vendor to farmer, processor to farmer — can be represented as an NFT.

The goal of Phase 2 is to make that statement real:
- Any approved partner can issue NFTs representing their economic commitments
- Any buyer can purchase those NFTs using USDC or CURD
- Every sale routes proceeds to the issuer with a protocol fee to Cheesecoins
- The marketplace surfaces all active partner NFT projects
- 10,000 Nubians North NFTs sold = $400K liquidity. Everything serves this.

---

## 2. Participant Roles

| Role | Who They Are | What They Do |
|---|---|---|
| **Protocol** | Cheesecoins | Sets rules, takes protocol fee, lists projects on marketplace |
| **Issuer** | Approved partner (farmer, vendor, retailer, processor, service provider) | Creates NFT project, sets terms, receives sale proceeds |
| **Buyer** | Anyone | Purchases NFTs with USDC or CURD |
| **Holder** | NFT owner | Entitled to whatever the NFT represents (delivery, yield, governance) |
| **Merchant** | Vendor accepting CURD | Registered in MerchantRegistry; receives CURD payments directly |

### Money Flows

Every sale in the network:
```
Buyer pays (USDC or CURD)
  → Protocol fee (X%) → Cheesecoins Treasury
  → Remainder → Issuer (partner)
  → NFT minted to Buyer
```

For Nubians North specifically (the genesis project):
```
Buyer pays USDC
  → 100% → Cheesecoins Treasury (no external issuer)
  → NFT minted to Buyer
```

**Protocol fee: 5% on Commerce NFT sales, 2.5% on Capital and Land NFT sales.**
CURD token transfers themselves carry no protocol fee — fee applies only to NFT minting
via ProjectSale. This keeps us well below Visa/Mastercard (2-3%) on commerce, competitive
on capital instruments.

**Partner payout currency: Partner's choice — USDC or CURD.**
Configured per SaleConfig. CURD payouts enable partners to stake their proceeds for yield.

---

## 3. NFT Instrument Taxonomy

Four instrument types. Each maps to a contract template deployed via ProjectFactory.

### 3.1 Land NFT
**What it is:** Ownership stake or usage rights in agricultural land.

| Field | Value |
|---|---|
| Duration | Permanent (no expiry) |
| Governance | Full (same as Capex — land = long-term ownership) |
| Staking | Yes — yield from land rental/production |
| Transferable | Yes |
| Structure | Layered — see below |
| Legal wrapper | REQUIRED — termsUri points to IPFS-hosted title/deed document |

**Template:** `LandNFTTemplate.sol` — does not exist yet, needs to be written.

**Layered Land NFT Structure (DECIDED):**

Land ownership is layered, similar to real property law. Two tiers:

**Tier 1 — Deed NFT (root):**
- One token per land holding. Farmer typically retains this.
- Contains or references the legal description of the property.
- Image: photo of the farm or legal description document.
- Non-scene-based — one ERC721 token = one property.
- All Sub-NFTs reference this token's ID.

**Tier 2 — Sub-NFTs (productive capacity / rights):**
- Multiple tokens sold to investors, tied to the Deed NFT ID.
- Each Sub-NFT type represents a carved-out right:
  - Productive capacity (farm revenue share)
  - Mineral rights
  - Timber rights
  - Water rights
  - Grazing rights
  - Air rights / development rights
- Sub-NFTs are separate tokens with `parentDeedTokenId` field.
- Sub-NFTs are sold via ProjectSale — the standard sale infrastructure handles them.
- Different Sub-NFT classes can have different prices, supplies, and terms.

**Implementation approach:**
- `LandNFTTemplate` issues Deed NFTs (one per property).
- Sub-NFTs are issued as a separate NFT project (e.g. `LandSubNFT`) with
  `parentDeedTokenId` in their metadata, deployed via ProjectFactory.
- This keeps the architecture simple — Sub-NFTs are just another project type.

**Notes:**
- Build and deploy to testnet now.
- Do NOT enable on mainnet until a lawyer has reviewed the termsUri / legal wrapper.
- Could represent: full farm purchase, land lease, grazing rights, water rights.

---

### 3.2 Capital NFT (CapexNFTTemplate — EXISTS)
**What it is:** Long-term asset financing — buildings, equipment, livestock, infrastructure.

| Field | Value |
|---|---|
| Duration | No expiry |
| Governance | Full (Super Holder eligible) |
| Staking | Yes — maturity tiers |
| Transferable | Yes |
| Scenes | Scene-based (100 scenes × N copies default) |
| Legal wrapper | Recommended but not enforced |

**Template:** `CapexNFTTemplate.sol` ✅ BUILT

**Missing fields to add via upgrade:**
- `instrumentSubtype` — e.g. "equipment", "livestock", "building", "infrastructure"
- `termsUri` — IPFS link to offering terms / prospectus
- `issuerAddress` — the partner who created this project
- `faceValueUsdc6` — nominal value per NFT (informational, for marketplace display)

**Examples:**
- A dairy farmer raises $200K for a new milking system: 400 NFTs at $500 USDC each
- A hog farmer funds a new barn: 1,000 NFTs at $100 USDC
- A goat herd expansion: 500 NFTs at $80 USDC (same as Nubians North model)

---

### 3.3 Commerce NFT (InputCostNFTTemplate — PARTIAL)
**What it is:** A forward commercial commitment. The issuer commits to deliver
something — product, service, priority, credit — in exchange for upfront payment.

`InputCostNFTTemplate` handles the seasonal credit case. It needs to be
generalized (or a `CommerceNFTTemplate` written) to cover the full range.

| Field | Value |
|---|---|
| Duration | Fixed term (expiry) or renewable |
| Governance | None |
| Staking | Optional yield (depending on subtype) |
| Transferable | Configurable per project — issuer decides at launch |
| Scenes | Not scene-based — each token = one discrete commitment |
| Legal wrapper | Recommended |

**Subtypes:**
| Subtype | Example | Notes |
|---|---|---|
| `csa_subscription` | Weekly vegetable box for a season | Already works via CsaCertificateSale |
| `priority_purchase` | First dibs on heritage pork at locked price | Expires at season/year end |
| `bulk_agreement` | 50 bales of hay at locked price | |
| `line_of_credit` | Farm funded seed purchase, repaid at harvest | InputCostNFT covers this |
| `service_commitment` | 20 hours of vet services | Service provider issues |
| `processing_agreement` | Process 50 pigs at $X each | Processor issues |
| `delivery_contract` | Weekly milk delivery to restaurant | Farmer issues |
| `loyalty_discount` | 50% off one NFT purchase | PartnerNFTSale covers this |
| `gift_certificate` | $100 of farm products | Retailer/farm store issues |

**Template:** `CommerceNFTTemplate.sol` — needs to be written, supersedes
`InputCostNFTTemplate` for non-credit subtypes. OR: extend InputCostNFTTemplate
with `instrumentSubtype` field.

**Write new `CommerceNFTTemplate.sol`.** Must be flexible enough to handle all participant
types and all variable combinations. `InputCostNFTTemplate` stays for backward
compatibility. `CommerceNFTTemplate` is the canonical forward-commitment instrument.

---

### 3.4 Promo/Discount NFT (PartnerNFTSale — EXISTS)
**What it is:** Voucher-based discount on a Cheesecoins ecosystem NFT.
This is what the current partner program uses.

| Field | Value |
|---|---|
| Duration | Voucher expiry (set per-voucher off-chain) |
| Governance | None |
| Staking | No |
| Scenes | Uses existing NubiansNorth scenes |
| Contract | `PartnerNFTSale.sol` ✅ BUILT, not deployed |

**Action:** Deploy to Sepolia → mainnet. No changes needed.

---

## 4. Shared Base Fields

Every NFT instrument type (across all four categories) should carry these fields.
Some are stored on-chain, some in the IPFS metadata pointed to by `termsUri`.

### On-chain (all types):
```solidity
uint256  projectId          // ProjectRegistry ID
address  issuer             // Partner address (receives sale proceeds)
uint8    instrumentType     // 0=Land, 1=Capital, 2=Commerce, 3=Promo
string   instrumentSubtype  // e.g. "equipment", "csa_subscription", "priority_purchase"
uint256  faceValueUsdc6     // Nominal value per token (6 dec USDC, informational)
string   termsUri           // IPFS URI → legal/commercial terms document
uint256  maturityDate       // 0 = no expiry (Land, Capital)
bool     isTransferable     // Whether token can be sold on secondary market
bool     yieldEnabled       // Whether staking yield is active
```

### In IPFS metadata (termsUri document):
```
issuer_name
issuer_address_physical
instrument_title          // e.g. "Green Valley Spring Feed Credit 2026"
description               // What the holder is entitled to
delivery_terms            // How/when the issuer delivers
redemption_instructions   // How the holder redeems
legal_jurisdiction        // Which law governs (for Land especially)
offering_date
total_raise_target        // Optional — how much the issuer is trying to raise
```

---

## 5. ProjectSale Contract (NEEDS TO BE WRITTEN)

This is the most important missing piece. A single upgradeable sale contract
that handles payment and minting for any NFT instrument type.

### What it replaces:
- `CsaCertificateSale` (Nubians North only, non-upgradeable)
- `PartnerNFTSale` (promo vouchers only, non-upgradeable)

### What it does:
1. Partner registers their NFT project + sale terms
2. Buyer calls `buy(projectId, quantity)` or `buyWithVoucher(voucher, sig)`
3. Contract takes payment (USDC or CURD)
4. Routes protocol fee to treasury
5. Routes remainder to issuer
6. Mints NFT to buyer

### Key design requirements:
- Upgradeable (Transparent Proxy)
- Works with all NFT template types (anything implementing ISceneNFT or a new ICommerceNFT)
- Per-project configurable: price, supply cap, payment token, start/end date
- Supports both fixed-price and voucher-based (promo) purchases
- Per-project pauseable by owner or protocol admin
- Emits events for marketplace indexing

### Interface sketch:
```solidity
struct SaleConfig {
    address nftContract;       // The partner's NFT contract
    address issuer;            // Receives proceeds after fee
    uint256 priceUsdc6;        // Price per token (0 if voucher-only)
    address paymentToken;      // USDC or CURD address
    uint256 protocolFeeBps;    // Protocol cut (set by Cheesecoins)
    uint256 maxPerWallet;      // Anti-whale cap
    uint256 saleStart;         // Unix timestamp
    uint256 saleEnd;           // 0 = no end
    bool    active;
}

function registerSale(SaleConfig calldata config) external;
function buy(uint256 projectId, uint256 quantity) external;
function buyWithVoucher(PromotionVoucher calldata v, bytes calldata sig) external;
function pauseSale(uint256 projectId) external;
function setSaleConfig(uint256 projectId, SaleConfig calldata config) external;
```

**Partner self-registers via `/partners/launch` wizard. Sale is paused until admin
activates it.** Partner fills in all project details in the web UI, admin reviews and
calls `ProjectSale.activateSale()`. Project appears on marketplace when active.

**No CURD→USDC auto-swap until Uniswap pool exists (Phase B).** Each SaleConfig
specifies one payment token. Auto-swap wired in Phase B. See Section 12 for
Uniswap pool seeding requirements.

---

## 6. Merchant Infrastructure (BUILT, NOT DEPLOYED)

Enables vendors to officially accept CURD as payment for real goods and services.
These contracts are built and ready — just need deploying and wiring.

### Contracts:
- `MerchantRegistry.sol` — governance-controlled vendor allowlist
- `MerchantSettlement.sol` — CURD payment rail; payer sends CURD directly to merchant
- `MerchantRegistryV2.sol` — adds role-based access (deploy as upgrade when needed)
- `MerchantSettlementV2.sol` — adds pause tracking (required by MaturityOracle)

### How it works:
1. Partner applies to be a merchant (web form — already exists)
2. Protocol admin adds them to `MerchantRegistry`
3. When a customer pays in CURD at their store, `MerchantSettlement.settle()` is called
4. CURD transfers from buyer to merchant
5. Event emitted for receipt / audit

**Same flow as partner applications.** Merchant applies via web form → Discord notification
to Greg → Greg approves → merchant gets access to backend page where they configure their
NFT projects with guided prompts. Admin controls the allowlist; transitions to governance
at Stage 1.

---

## 7. The Marketplace (NEEDS TO BE BUILT — Frontend)

A new section of cheesecoins.com that lists all active partner NFT projects.

### Pages needed:
- `/marketplace` — currently shows only Nubians North. Needs to become a feed of all projects.
- `/marketplace/[projectId]` — partner project detail page + buy flow
- `/partners/launch` — partner project launch wizard (self-service onboarding)
- `/partners/dashboard` — existing, needs to show partner's project metrics

### `/marketplace` feed needs:
- Project name, issuer name, instrument type badge (Land / Capital / Commerce)
- NFT image / artwork
- Price per token, tokens remaining, total raise
- Buy button → project detail page

### `/marketplace/[projectId]` needs:
- Full project description + terms
- NFT artwork
- Buy flow (same USDC/CURD approve → buy pattern as current marketplace)
- Issuer profile
- How many tokens sold / remaining
- What holders are entitled to (from termsUri)

### `/partners/launch` (partner self-service):
This is the flow that turns an approved partner into an active issuer.

Steps:
1. Connect wallet (must match registered wallet in partners table)
2. Choose instrument type (Land / Capital / Commerce)
3. Choose subtype
4. Configure sale: name, description, price, supply, terms document upload
5. Upload NFT artwork (or select from template gallery)
6. Submit → creates Supabase record, paused until admin activates
7. Admin reviews + calls `ProjectSale.registerSale()` + flips `active = true`
8. Project appears on marketplace

**Partner uploads their own artwork if they have it, or chooses from a Cheesecoins
catalogue of templates organized by instrument type.** Templates enable fast onboarding
for partners who don't have custom artwork. Custom uploads enable differentiation.

---

## 8. What Needs To Be Written (Contract Summary)

| Contract | Status | Priority | Notes |
|---|---|---|---|
| `ProjectSale.sol` | Does not exist | P0 | Most important missing piece |
| `CommerceNFTTemplate.sol` | Does not exist | P1 | Superset of InputCostNFT |
| `LandNFTTemplate.sol` | Does not exist | P2 | Design now, deploy to mainnet after legal review |
| Upgrades to `CapexNFTTemplate` | Exists, needs fields | P1 | Add issuer, termsUri, faceValue, subtype |
| `PartnerNFTSale` deploy | Built, not deployed | P0 | Deploy to Sepolia → mainnet |
| `MerchantRegistry` deploy | Built, not deployed | P1 | Deploy + wire web form |
| `MerchantSettlement` deploy | Built, not deployed | P1 | Deploy + wire web form |

---

## 9. What Needs To Be Built (Frontend Summary)

| Feature | Status | Priority |
|---|---|---|
| Marketplace feed (all projects) | Does not exist | P0 |
| Partner project detail + buy page | Does not exist | P0 |
| Partner project launch wizard | Does not exist | P1 |
| Wire checkout to `ProjectSale` | Not wired | P0 |
| Wire promo code to `PartnerNFTSale` | Not wired | P0 |
| Merchant acceptance UI (CURD payment) | Does not exist | P1 |

---

## 10. Deployment Sequence

Order matters. Each step depends on the previous.

```
Phase 2A — Activate existing partner program
  1. Deploy PartnerNFTSale to Sepolia → test → mainnet
  2. Authorize PartnerNFTSale as minter on NubiansNorthNFT (Gnosis Safe)
  3. Wire website checkout to use PartnerNFTSale when promo code entered
  4. Approve first batch of real partners → issue promo codes

Phase 2B — Merchant infrastructure
  5. Deploy MerchantRegistry to mainnet
  6. Deploy MerchantSettlement to mainnet
  7. Register first merchants
  8. Wire merchant CURD payment to website

Phase 2C — Partner project NFT program
  9. Write + audit ProjectSale.sol
  10. Write + audit CommerceNFTTemplate.sol
  11. Upgrade CapexNFTTemplate with new fields
  12. Deploy ProjectSale to Sepolia, test full flow
  13. Deploy to mainnet, register as authorized minter
  14. Build /marketplace feed + project detail page
  15. Build /partners/launch wizard
  16. Onboard first capital/commerce partners

Phase 2D — Land NFTs (after legal review)
  17. Write LandNFTTemplate.sol
  18. Legal review of termsUri structure
  19. Deploy to testnet only until legal sign-off
  20. Deploy to mainnet when cleared
```

---

## 11. Decisions — Resolved

| # | Decision | Answer |
|---|---|---|
| 1 | Protocol fee % | 5% commerce, 2.5% capital/land. No fee on CURD transfers. |
| 2 | Partner payout currency | Partner's choice — USDC or CURD per SaleConfig |
| 3 | Land NFT transferable? | Yes |
| 4 | Land NFT structure | Layered: Deed NFT (root, farmer holds) + Sub-NFTs (rights sold to investors) |
| 5 | Commerce NFT transferable? | Configurable per project — issuer decides at launch |
| 6 | Extend InputCostNFT or new CommerceNFT? | New `CommerceNFTTemplate.sol` |
| 7 | Who can register a ProjectSale? | Partner self-registers, admin activates |
| 8 | CURD→USDC auto-swap for partner payouts? | Phase B only (needs Uniswap pool) |
| 9 | Who can register merchants? | Admin via existing Discord flow; governance at Stage 1 |
| 10 | Partner NFT artwork | Partner uploads OR chooses from Cheesecoins catalogue |

---

## 12. Uniswap v3 Pool — Seeding Requirements

The CURD/USDC Uniswap v3 pool unlocks Phase B: HedgeModule, StabilityCoordinator,
auto-swap for partner payouts, and CurdDirectSale oracle pricing.

**Can $5,000 USDC get it started?**

Technically yes, but it would be tight. Here's what the numbers actually mean:

| Liquidity | Price impact on $500 buy | Usable? |
|---|---|---|
| $5K each side ($10K total) | ~5% slippage | Barely functional |
| $10K each side ($20K total) | ~2.5% slippage | Acceptable bootstrap |
| $20K each side ($40K total) | ~1% slippage | Good trading experience |

Uniswap v3 uses concentrated liquidity — you set a price range (e.g. $0.005–$0.05 USDC per CURD).
All your liquidity sits within that range, making it more capital-efficient than v2.
With a tight range, $10K each side behaves more like $30-40K in Uniswap v2.

**What you need:**
- USDC side: real USDC from treasury (Gnosis Safe)
- CURD side: withdraw from CurdDirectSale (10M CURD loaded) — you have this already
- Starting price: needs to be set. Current CurdDirectSale price is the reference.
- Gas: ~$5-10 on Arbitrum One to deploy pool + add liquidity

**Recommendation:**
Start with $10K USDC + equivalent CURD at the CurdDirectSale price.
That's the minimum for a functional trading experience.
$5K USDC works as a technical launch but large trades will cause severe slippage.

**This is a Gnosis Safe transaction** — requires 2-of-2 sign-off (Ledger + MetaMask).
Do not do this until we've verified the starting price is right.

**Required before deploying HedgeModule, StabilityCoordinator, or FiatRedemptionVault.**
