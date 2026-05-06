# Cheesecoins Ecosystem — Master Flowchart

> Renders in GitHub, VS Code with Mermaid extension, or any Mermaid viewer.
> This document covers: NFT classes, money inflows, products & rewards back to holders,
> and the protocol's revenue model.

---

## 1. NFT Class Taxonomy

Every NFT on the Cheesecoins protocol belongs to one of these classes.
Class determines: what the holder receives, whether they earn yield, and whether they earn governance rights.

```mermaid
graph TD
    ROOT["🧀 Cheesecoins Protocol NFTs"]

    ROOT --> SCENE["🌾 Scene NFT\n(Asset Class)"]
    ROOT --> COMMERCE["🛒 Commerce NFT\n(Forward Commitment Class)"]
    ROOT --> CAPEX["🏗️ CapEx NFT\n(Capital Class)"]
    ROOT --> INPUTCOST["🌱 Input Cost NFT\n(Operating Class)"]
    ROOT --> INNOVATION["💡 Innovation NFT\n(R&D Class)"]
    ROOT --> LAND["📋 Land Deed NFT\n(Land Class)"]

    SCENE --> SCENE1["Nubians North Collection\n100 scenes × 500 copies\n$80 USDC each\nGovernance + Staking"]

    COMMERCE --> C1["CSA Food Box\nPresale delivery commitment"]
    COMMERCE --> C2["Restaurant Meal\nRedeemable at partner location"]
    COMMERCE --> C3["Gift Certificate\n$X of farm products"]
    COMMERCE --> C4["Priority Purchase\nFirst dibs at locked price"]
    COMMERCE --> C5["Bulk Agreement\ne.g. 50 bales hay at set price"]
    COMMERCE --> C6["Service Commitment\ne.g. 20 hrs vet services"]
    COMMERCE --> C7["Processing Agreement\ne.g. process 50 pigs at $X each"]
    COMMERCE --> C8["Delivery Contract\ne.g. weekly milk to restaurant"]

    CAPEX --> CAP1["Equipment Financing\nTractor, milking system, etc."]
    CAPEX --> CAP2["Building Finance\nBarn, processing facility, greenhouse"]

    INPUTCOST --> IN1["Seasonal Operating Credit\nRenewable each season"]

    INNOVATION --> INN1["R&D Project\nFixed-term, non-renewable"]

    LAND --> L1["Fractional Land Rights\nSub-title NFTs on real parcels"]

    style SCENE fill:#1a5c2a,color:#fff
    style COMMERCE fill:#7c4d00,color:#fff
    style CAPEX fill:#1a3a5c,color:#fff
    style INPUTCOST fill:#3a1a5c,color:#fff
    style INNOVATION fill:#5c1a1a,color:#fff
    style LAND fill:#2a4a1a,color:#fff
```

---

## 2. Money Inflows — How Value Enters the Protocol

```mermaid
graph LR
    USER["👤 User / Buyer"]
    PARTNER["🏪 Partner\n(Farm, Restaurant, Retailer)"]
    PRODUCER["🌾 Producer\n(Farm applying to list)"]

    USER --> |"Buy CURD tokens\n(USDC → CURD via CurdDirectSale)"| CURD["💰 CURD Token\n(ERC-20)"]
    USER --> |"Buy Scene NFT\n$80 USDC or 80 CURD"| SCENE_SALE["CsaCertificateSale\n(Scene NFT gateway)"]
    USER --> |"Buy Commerce NFT\n(food box, meal, gift cert)\nUSDC or CURD"| COMMERCE_SALE["CommerceProjectSale\n(Commerce NFT gateway)"]
    USER --> |"Stake CURD or NFTs\nfor yield"| STAKING["StakingManager\n+ BootstrapYieldPool"]

    PARTNER --> |"Register as merchant\naccept CURD"| MERCHANT["MerchantRegistry\n+ MerchantSettlement"]
    PARTNER --> |"Submit Commerce NFT project\n(one wallet signature)"| COMMERCE_SALE

    PRODUCER --> |"Submit business plan\nvia Farm Tools"| FARM_TOOLS["🌾 Farm Tools\n(Producer Onboarding)"]
    FARM_TOOLS --> |"Approved project application"| COMMERCE_SALE

    SCENE_SALE --> TREASURY["🏦 Gnosis Safe Treasury\n(2-of-2 Ledger + MetaMask)"]
    COMMERCE_SALE --> TREASURY
    MERCHANT --> TREASURY
    STAKING --> TREASURY

    CURD --> |"Held in wallet\nused for purchases"| USER

    style TREASURY fill:#b8860b,color:#fff
    style CURD fill:#2d7a2d,color:#fff
```

---

## 3. Products & Rewards — What Comes Back to Holders

```mermaid
graph TD
    HOLD["👛 NFT Holder"]

    HOLD --> |"Holds Scene NFT\n(Nubians North)"| SCENE_R["Scene NFT Returns"]
    HOLD --> |"Holds Commerce NFT\n(food box, meal, etc.)"| COMMERCE_R["Commerce NFT Returns"]
    HOLD --> |"Holds any staked NFT\nor CURD"| STAKING_R["Staking Returns"]
    HOLD --> |"Holds all 100 scenes\n= Super Holder"| GOV_R["Governance Returns"]

    SCENE_R --> SR1["📦 First access to\nmilk plant products\n(when plant opens)"]
    SCENE_R --> SR2["🎟️ Partner promo codes\n$40 off Commerce NFTs"]
    SCENE_R --> SR3["📈 Staking yield\n(CURD rewards)"]
    SCENE_R --> SR4["🏷️ Verified community\nmember status"]

    COMMERCE_R --> CR1["🥩 Physical delivery\n(food box shipped June 2026)"]
    COMMERCE_R --> CR2["🍽️ Meal redemption\n(show NFT at partner location)"]
    COMMERCE_R --> CR3["🎁 Gift cert redemption\n($X of farm products)"]
    COMMERCE_R --> CR4["✅ On-chain fulfillment record\n(issuer calls markFulfilled)"]

    STAKING_R --> ST1["💰 CURD yield\n(BootstrapYieldPool)"]
    STAKING_R --> ST2["📊 Governance weight\n(proportional to stake age)"]

    GOV_R --> GR1["🗳️ Propose protocol changes\n(after 24-week stake minimum)"]
    GOV_R --> GR2["⚖️ Vote on proposals"]
    GOV_R --> GR3["🔒 Execute via ProtocolTimelock\n(2-day delay on mainnet)"]

    style SCENE_R fill:#1a5c2a,color:#fff
    style COMMERCE_R fill:#7c4d00,color:#fff
    style STAKING_R fill:#1a3a5c,color:#fff
    style GOV_R fill:#4a1a5c,color:#fff
```

---

## 4. Protocol Revenue Model — How the Ecosystem Sustains Itself

```mermaid
graph TD
    REV["💵 Protocol Revenue Sources"]

    REV --> R1["Scene NFT Sales\n10% protocol fee\n→ Treasury"]
    REV --> R2["Commerce NFT Sales\n5% protocol fee\n→ Treasury\n(95% to issuer/partner)"]
    REV --> R3["CapEx NFT Sales\n2.5% protocol fee\n→ Treasury"]
    REV --> R4["CurdDirectSale\nSpread on CURD purchases\n→ Treasury"]
    REV --> R5["MerchantSettlement\nFee on CURD→USDC settlements\n→ Treasury"]
    REV --> R6["FiatRedemptionVault\n2% redemption fee\n→ Treasury\n(Phase B — post Uniswap pool)"]

    TREASURY["🏦 Treasury\n(Gnosis Safe)"]

    R1 --> TREASURY
    R2 --> TREASURY
    R3 --> TREASURY
    R4 --> TREASURY
    R5 --> TREASURY
    R6 --> TREASURY

    TREASURY --> USE1["🌾 Fund milk plant build-out"]
    TREASURY --> USE2["💧 Seed Uniswap CURD/USDC pool\n(Phase B liquidity)"]
    TREASURY --> USE3["📣 Protocol marketing\n& community growth"]
    TREASURY --> USE4["⚙️ Protocol operations\n& infrastructure"]
    TREASURY --> USE5["📊 StakingManager yield reserves\n(BootstrapYieldPool top-ups)"]

    style TREASURY fill:#b8860b,color:#fff
    style REV fill:#1a1a1a,color:#fff
```

---

## 5. Full Participant Journey — End to End

```mermaid
graph TD
    subgraph BUYER ["👤 Buyer Journey"]
        B1["Discovers Cheesecoins\n(social, market, partner referral)"]
        B2["Creates free wallet\n(Thirdweb — email/Google/Apple)"]
        B3["Buys CURD\n(Transak card → USDC → CURD)\nor buys direct with USDC"]
        B4["Buys Scene NFT\n$80 — one of 100 farm scenes"]
        B5["Receives partner promo code\n$40 off a Commerce NFT"]
        B6["Buys food box at $35\n(Commerce NFT)"]
        B7["Receives box June 2026\n(on-chain fulfillment confirmed)"]
        B8["Stakes NFT + CURD\nearns yield over time"]
        B9["Collects all 100 scenes\n→ Super Holder\n→ governance rights"]
        B1-->B2-->B3-->B4-->B5-->B6-->B7-->B8-->B9
    end

    subgraph PRODUCER ["🌾 Producer / Partner Journey"]
        P1["Discovers Cheesecoins\n(Greg, market, community)"]
        P2["Opens Farm Tools\nFills business plan"]
        P3["Submits project application\n(one wallet signature)"]
        P4["Greg reviews & approves\n(one Ledger click)"]
        P5["Commerce NFT goes live\nListed on marketplace"]
        P6["Accepts CURD at counter\nor online"]
        P7["Monthly settlement\nCURD → USDC via MerchantSettlement"]
        P8["Marks deliveries fulfilled\n(markFulfilled on-chain)"]
        P1-->P2-->P3-->P4-->P5-->P6-->P7-->P8
    end

    subgraph PROTOCOL ["🧀 Protocol Layer"]
        PR1["Collects 5% fee on\nevery Commerce NFT sale"]
        PR2["Routes to Treasury\n(Gnosis Safe)"]
        PR3["Funds milk plant\n+ yield reserves\n+ liquidity pool"]
        PR1-->PR2-->PR3
    end

    B4 -.->|"protocol fee"| PR1
    B6 -.->|"protocol fee"| PR1
    P5 -.->|"sale proceeds\nminus 5% fee"| P6
```

---

## 6. Commerce NFT — Lifecycle

A Commerce NFT is a **forward commitment**. The issuer (producer or partner) promises to deliver. The buyer holds the on-chain receipt.

```mermaid
stateDiagram-v2
    [*] --> Pending : Buyer purchases NFT\n(payment collected, NFT minted)

    Pending --> Fulfilled : Issuer delivers goods/service\ncalls markFulfilled(tokenId)
    Pending --> Cancelled : Issuer cancels\ncalls markCancelled(tokenId)\n(refund handled off-chain)
    Pending --> Expired : maturityDate passes\nwithout fulfillment

    Fulfilled --> [*] : Delivery confirmed on-chain\nPermanent audit record
    Cancelled --> [*] : Cancellation recorded\nRefund reference stored
    Expired --> [*] : Expired — dispute resolution\nvia issuer + buyer
```

---

## 7. Commerce NFT Subtypes — What Can Be Issued

Any approved partner can issue a Commerce NFT. The `instrumentSubtype` field defines what the holder receives.

| Subtype | Example | Issuer | Delivery |
|---|---|---|---|
| `csa_food_box` | Nubians North Meat & Cheese Box — June 2026 | Greg / Nubians North | Physical shipment |
| `restaurant_meal` | Dinner for two at partner restaurant | Restaurant partner | In-person redemption |
| `gift_certificate` | $100 of farm products | Any farm partner | In-store or shipped |
| `priority_purchase` | First 10 copies of spring cheese at $X | Fromagerie | Delivery or pickup |
| `bulk_agreement` | 50 bales hay at $8/bale | Feed farm | Scheduled delivery |
| `service_commitment` | 20 hours vet services at $90/hr | Vet practice | Booked appointments |
| `processing_agreement` | Process 50 pigs at $250 each | Abattoir | Scheduled processing |
| `delivery_contract` | Weekly 10L milk delivery to restaurant | Dairy farm | Weekly route |
| `loyalty_discount` | 15% off all purchases for 1 year | Retailer | Applied at checkout |
| `line_of_credit` | $5,000 input cost advance | Protocol / investor | Funds released to farmer |

---

## 8. Deployment State — What Is Live vs. Planned

```mermaid
graph LR
    subgraph LIVE ["✅ Live on Arbitrum One Mainnet"]
        L1["CURD Token\n0x8335..."]
        L2["NubiansNorthNFT\n0x4a99..."]
        L3["StakingManager\n0xcfbd..."]
        L4["CsaCertificateSale\n0x5b0a..."]
        L5["CurdDirectSale\n0x31ea...\n10M CURD loaded"]
        L6["ProjectSale\n0x07FC...\nCommerce gateway"]
        L7["SuperHolderGovernance\n0x28c7..."]
        L8["ProjectRegistry\n0x5985..."]
        L9["ProjectFactory\n0x7990..."]
        L10["MerchantRegistryV2\n0xca7f...\nNubians North registered"]
    end

    subgraph NEXT ["🔨 Build Next — No Uniswap Required"]
        N1["CommerceProjectSale\n(user self-serve launcher)\nOne signature to list"]
        N2["Food Box NFT\n(CommerceNFTTemplate clone)\nProject ID 1001"]
        N3["Farm Tools\n(producer onboarding\nbusiness plan → NFT project)"]
        N4["Admin approval UI\n(Greg approves projects\nwith one Ledger click)"]
    end

    subgraph PHASE_B ["⏳ Phase B — Requires Uniswap Pool"]
        PB1["HedgeModule"]
        PB2["StabilityCoordinator"]
        PB3["FiatRedemptionVault"]
        PB4["MaturityOracle"]
    end

    style LIVE fill:#0a3a0a,color:#fff
    style NEXT fill:#3a2a0a,color:#fff
    style PHASE_B fill:#1a1a3a,color:#fff
```

---

*Last updated: April 2026*
*Owner: Greg Garner / Cheesecoins Protocol*
