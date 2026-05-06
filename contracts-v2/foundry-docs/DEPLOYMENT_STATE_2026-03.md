# Cheesecoins / Nubians Protocol — Deployment State

**Last updated: May 4 2026**

This document is the source of truth for what is actually deployed. Read this before every session that touches contracts.

---

## Networks

- **Arbitrum One (42161)** — MAINNET — live March 25 2026
- **Arbitrum Sepolia (421614)** — testnet

---

## ⚠️ CRITICAL SECURITY NOTE — Compromised Wallet

The Sepolia deployer `0xe3116832f48d2B8d60CD38E43e2A300eB506f1D5` was **drained via EIP-7702** (incident date: ~March 28 2026).
**This wallet is dead. Never use it again. Its private key has been removed from `.env.sepolia`.**

All Sepolia contracts deployed on April 15 2026 (ProjectSale, CommerceNFT CSA test) were deployed by this compromised wallet and are permanently abandoned. See abandoned contracts section below.

**New clean Sepolia deployer:** `0x05D2850115d69A5AeF7514b4A1c502fAeeD08B73` (Greg's MetaMask "Sepolia Deployer", May 1 2026 onward). Earlier-used wallet `0xaaFdFb21b89b2619C7C53e79DDb7C29FcB271719` owns OptionsMarket + Oracle deployed April 17–28 — kept as Options-only admin, not used for new B3/Phase 2 deploys.
- MetaMask "for testing" account
- `.env.sepolia` updated to use this address
- Private key: add to `.env.sepolia` PRIVATE_KEY field (export from MetaMask → Account Details → Show Private Key)

Mainnet deployer is Ledger `0xDfb351Db881142f76f10f6D12c348002b473F9BA` — safe.

---

## Arbitrum One MAINNET — Complete Contract List

Source: `deployments/42161-arbitrum-one-all.json`

### Wallets
| Role | Address |
|---|---|
| Deployer (Ledger) | `0xDfb351Db881142f76f10f6D12c348002b473F9BA` |
| Owner / Treasury (Gnosis Safe 2-of-2) | `0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2` |
| Operations / Safe Signer (MetaMask) | `0xca855180556Ca127F7F8A5d92fE0191FE4EF443c` |
| USDC (Arbitrum One) | `0xaf88d065e77c8cC2239327C5EDb3A432268e5831` |

### Core Protocol Layer
| Contract | Address | Status |
|---|---|---|
| ProxyAdmin (core) | `0xc8C7108CA726Fc3dDEae64ca46fF6B4D39E1c136` | Live |
| CURD Token proxy | `0x833551C5433551fDA5b49D03044D7Df51ffB89cD` | Live |
| ProjectRegistry proxy | `0x5985D9BA6d641E8afeEd2cE95409E7728f1B21b3` | Live |
| ProjectFactory proxy | `0x79905e909977e5EC4056cD237736931450300BA3` | Live |
| EventAggregator proxy | `0xb0635BD2B9EC79C1006De5D5e38f7336F16aeB09` | Live |
| CURD/USD Price Feed | `0x6A51331B7b199398816977556d98BA731E44595B` | Live |
| CURD/USD Aggregator | `0x50834F3163758fcC1Df9973b6e91f0F0F0434aD3` | Live |

### NFT Layer
| Contract | Address | Status |
|---|---|---|
| NubiansNorthNFT proxy | `0x4a99b2Dc6d5D4745148F13C06965508306808aAD` | Live — 101 tokens minted, founder holds all |
| TransferHookRouter | `0x3949102aF153c4d072eA64898F3214A4A471B1C3` | Live — hooks wired to SceneTracker + StakingManager |
| SceneTracker | `0x8F00b61f5A241aaaaD03Bb437D32104B10181A6D` | Live — hasFullCollection = true |
| ProjectNFT template impl | `0x80dab9867c598433ff8a881637E3F38E420aFd6c` | Deployed (clone factory use) |
| YieldPool template impl | `0x8C1a1Aa8c6a4cA2FC6E0B54131eD35f8431e10fA` | Deployed (clone factory use) |
| CommerceNFTTemplate impl | `0xAe2fe166c61c5e343283a7AEA9C1C00cb466dabf` | Live — April 17 2026 |

### Staking Layer
| Contract | Address | Status |
|---|---|---|
| StakingManager proxy | `0xcfbd9e4B97DD40863b134e7979d3038Ec5cb35B6` | Live |
| BootstrapYieldPool proxy | `0x27b55A7fFaeD5df6f174bb29fc2D8f08329DE68C` | Live — **5,000,000 CURD funded ✅ (April 2026)** |

### Commerce / Sale Layer
| Contract | Address | Status |
|---|---|---|
| CsaCertificateSale | `0x5b0ad371B2b7408CEBf4d8b644a68b2eEf68e46A` | Live — Scene NFT gateway, all 100 scenes enabled |
| CurdDirectSale proxy | `0x31ea59d272472B8B2BBF1a7b58fCB0433712d10D` | Live — **10M CURD loaded** |
| CurdDirectSale impl | `0xf3a20062Ed203676D87aBA7Cd83DE01814309F5f` | Live |
| CurdDirectSale ProxyAdmin | `0xD2B7AC2f5954E6fFc276be5e7F23d64D3F85a4D2` | Live |
| ProjectSale proxy | `0x07FC042B155628980aA5B00EB9B53D3B3D71E7fc` | Live — **no projects registered yet** |
| ProjectSale impl | `0x8e2D3eC858442b4C44baa693490F9cE0066c585E` | Live |
| ProjectSale ProxyAdmin | `0x4588694eC019A4E62222050c3224a4afF3f1201a` | Live — owned by Gnosis Safe |

### Governance Layer
| Contract | Address | Status |
|---|---|---|
| ProtocolTimelock | `0x0E7d119224855ca259a80cb0C0a6a82fa29ebb5C` | Live — 2-day delay on mainnet |
| SuperHolderGovernance | `0x28c72A15b2b203398918F319040c51224Dd01E52` | Live — untested on mainnet |
| GovernanceWeighting | `0x6fAfC33516BC7c065fcFFC7854ACE6FFB10A01aA` | Live |
| FounderDecentralization | `0xC2378eC98B8Aedf8E748b86775739F25F2CCE86a` | Live |
| TransitionCalldataBuilder | `0xF32dd416997165E1e407FB7E2531e50Ee9B986B2` | Live |
| FounderVestingWallet | `0xbac3d40668Ce4030ab5D8cF0bBCFDA457E1216f5` | **Live (deployed May 5 2026)** — holds 20M CURD, 4-yr linear vest from Mar 25 2026 |

### B3 Layer (deployed — NOT YET CONFIGURED)
| Contract | Address | Status |
|---|---|---|
| B3 ProxyAdmin | `0xFB099D1c91d3edD29Ddab69cce452EB873ebEd0d` | Live |
| BurnAuthority proxy | `0x83f5FD2C6E03210CB39f916FacC8207344606554` | Deployed — **not configured** |
| BurnAuthority impl | `0x5D38f90A56005608Fb5d4f37171BAA2F5E934C1F` | Live |
| FiatRedemptionVault proxy | `0x9c293c2C866278F1e3AF0ce6689fd2e451737274` | Deployed — **fee=0, cap=0, not funded** |
| FiatRedemptionVault impl | `0xc1Ef724CD9D4bAFe91b446d816F3094c52C910b3` | Live |
| MerchantRegistry proxy | `0xCA7f73aCb86a8aCEf897c06eE23Adf8cDf8709bA` | **Live at V3** — 2 merchants registered (Nubians North + first-test) |
| MerchantRegistry impl V1 | `0x7159448A1344A4F5a865434F6457774EBB7AB461` | Historical |
| MerchantRegistry impl V2 | `0x35ad8b1dcFaEBC5f7F6Cb7B35f6D358736A0bC21` | Historical (active until May 4 2026) |
| MerchantRegistry impl V3 | `0x033435CA67B79aCe3d9052157c34a584a5A8FDE9` | **CURRENT** — 5-tier supply-chain enum, upgraded May 4 2026 |
| MerchantSettlement proxy | `0x94AA0B5A4F3593FCd5c66A88A0De5deF0dda5FE0` | Deployed — **not configured** |
| MerchantSettlement impl | `0xE45b1f68795a1e599b77d214D0Aceab9B4aAE6df` | Live |
| MerchantSettlement implV2 | `0x0ae9e096BB97592c6e6D5741959F42d9c5491f0d` | Live |
| TreasuryRateAdvisor proxy | `0x53aB925B462b016535A1F077113d79c6681Ec77f` | Deployed — **not configured** |
| TreasuryRateAdvisor impl | `0xBBCCA254aa02BAa73B74f190b471f8390F1D241F` | Live |

### Options Market Layer (Sepolia — REDEPLOYED with oracle routing April 28 2026)
| Contract | Address | Status |
|---|---|---|
| Options ProxyAdmin | `0xE21789e3C360D76098A8f3bAbB91bD4A2Edf69cf` | Live — Sepolia |
| CheesecoinsOptionsMarket proxy (CURRENT) | `0xf06CB7648de7de7B968018714534C6722eAa6195` | Live — Sepolia, w/ oracle routing ✅ |
| CheesecoinsOptionsMarket proxy (OLD, unreferenced) | `0x673F39104560FC37f8983315e91eBd8555412FFD` | Live but ignored — Pyth-only, superseded |
| CommodityPriceOracle | `0x43aEFD293ef29ABD5e512947d38F4131dBA894EF` | Live — Sepolia ✅ fed daily by USDA AMS keeper |

**v1 active markets (4 of 8):** Corn (1, oracle), Wheat (2, oracle), Soybeans (3, oracle), USD/CAD (8, Pyth)
**Deferred to v2:** Cattle (4), Coffee (5), WTI (6), NatGas (7) — write-disabled in UI, contract-configured but no keeper

USDA AMS keeper: `mcp/tools/keepers/usda_grain_keeper.py` (committed `9655e6da`)
Keeper schedule: GitHub Actions cron `0 23 * * *` (daily 23:00 UTC), workflow `.github/workflows/usda-grain-keeper.yml`
Last verified prices on-chain (April 28): corn $4.6075, wheat $6.215, soy $11.7725
Frontend: `/options` exercise confirmed working April 28; `/prices` rewired to oracle April 29 (commit `e21e731`)

Deploy script: `script/DeployOptionsMarketSepolia.s.sol`
Deployment artifact: `deployments/421614-options.json` (TODO: update with redeploy + oracle addresses)
Test file: `foundry-test/unit/CheesecoinsOptionsMarket.t.sol`
Mainnet role plan: owner = ProtocolTimelock `0x0E7d119224855ca259a80cb0C0a6a82fa29ebb5C`, treasury = Gnosis Safe `0x6C64ACd0Be573D7c90d9b0c6fFDf2E69573871D2`
Pyth on Arbitrum Sepolia: `0x4374e5a8b9C22271E9EB878A2AA31DE97DF15DAF`
Pyth on Arbitrum One: `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C`

Settlement: Pyth pull oracle (FX) + CommodityPriceOracle keeper-fed (grains), `getPriceNoOlderThan()` / `getPrice()` at exercise time
Premium split: 10% treasury / 90% writer, distributed at purchase (TradFi standard — confirmed Greg April 26 2026)
Stale release: writer reclaims collateral at 2× maxAge; buyer forfeits premium (already distributed)
**Mainnet cutover gate:** ≥7 consecutive USDA keeper days no panics + no exercise reverts. Started April 28 → earliest May 5 2026.

### NOT YET DEPLOYED ON MAINNET
- Any Commerce NFT project proxy (no projects registered yet — architecture ready)
- Any Commerce NFT project (no project registered in ProjectSale)
- `CheesecoinsOptionsMarket` — written + tested, deploy to Sepolia first
- `HedgeModule` — blocked on Uniswap pool
- `StabilityCoordinator` — blocked on Uniswap pool
- `MaturityOracle` — blocked on Phase B stack

---

## Arbitrum Sepolia TESTNET — Reality Check (verified on-chain May 1 2026)

**The entire pre-April-17 Sepolia stack is owned by the compromised deployer `0xe3116832...`** — drained via EIP-7702 March 28 2026. These contracts still execute non-admin calls (reads, transfers, allowances), but **owner/admin functions cannot be safely called** because signing from this wallet loses any attached ETH.

Treat all `0xe3116832...`-owned Sepolia contracts as **read-only useful, write-locked**. Full address list quarantined in `deployments/421614-sepolia-abandoned.json`. The original split files (`421614-sepolia-all.json`, `421614-b3.json`, `421614-commerce-project-csa.json`, `421614-project-sale.json`) have been replaced with redirect stubs.

### Sepolia — Owned by COMPROMISED wallet (admin-locked)

🚫 Do **NOT** call admin/owner methods on any of these. Reads only.
Replacement wallet for fresh redeploys: `0x05D2850115d69A5AeF7514b4A1c502fAeeD08B73` (Greg's MetaMask "Sepolia Deployer"). Note: `0xaaFdFb21...` separately owns OptionsMarket + CommodityPriceOracle but is not in Greg's labeled accounts — keep it admin'ing Options only.

**Core stack**
| Contract | Address |
|---|---|
| CURD proxy | `0x3f6be674ce67f4ac5fcdbb9839ab46ff8a6df6d9` |
| ProjectRegistry proxy | `0xbef6d930fd76c81b60b480a7f40e9affcee92cc3` |
| ProjectFactory proxy | `0x646c6519cc0c46ac74b1ad28d8cc4d9115eda97e` |
| StakingManager proxy | `0x32528ef3ec91fa5ed40b8a1845b13829141273ce` |
| BootstrapYieldPool proxy | `0x6e041a000fb9c2d590299636ace9a75063218e19` |
| TransferHookRouter | `0xD8711a91a90BE11023DB8E65449642C19030B07E` |
| TreasuryRateAdvisor proxy | `0xDcfBF490221702b2206ac24F4E0aD69C93B6459e` |
| NubiansNorthNFT (canonical, project ID 2) | `0x14c9c50e8ca7ff6B97E60949975F644E5F06dD4C` |
| NubiansNorthNFT (project ID 1, never canonical) | `0x62d0f51Cfa29df12D7c9ee2453b1d683CE4b73cA` |
| SceneTracker | `0xF77072A3beDeA3A2e69D30f517eA93F95932bdBE` |
| CsaCertificateSale | `0xe54C7C536D6F59c4283f55e0Cc32B4B814BBe76E` |
| ProxyAdmin | `0x0973c0a75416977EdD822828E39ca5B839617bcE` |

**B3 stack (deployed April 15 2026, never put into service)**
| Contract | Address |
|---|---|
| MockUSDC | `0x5f7aceba95c0cb9e84b895d3309cca8f4d693b89` |
| BurnAuthority proxy | `0x9bd058cd20f992c59807222de1d7858920e869a9` |
| FiatRedemptionVault proxy | `0xf950545c592f1e60ad0ff7d20d34e1aa0ff19af0` |
| MerchantRegistry proxy | `0xf3da38ad4ad8c47d099842ff24113a4bca50ea1b` |
| MerchantSettlement proxy | `0x26dd5ac567fa2b6c79f65c9c151c70363cdeccbb` |
| B3 ProxyAdmin | `0x47b0c6f1fb44e9c775dfaf21f2625c586a13ca2a` |

**Phase 2 commerce (deployed April 15 2026, never put into service)**
| Contract | Address |
|---|---|
| ProjectSale proxy | `0xCFD7D5a03Bb41b3e41Ea437b5ab7a23EEe44EBDA` |
| CommerceNFT impl | `0x108Cb2713616110bfc24c801FeA6b9b4601E9d13` |
| CSA Box NFT proxy (projectId=100) | `0x7077719C0093240592B882c3b1F72aB499582dCc` |

**Governance (March 12 audit-upgrade batch)** — `owner()` not exposed, custom interfaces. Same deployer, assume admin-locked: `SuperHolderGovernance 0x881caCbb...`, `ProtocolTimelock 0x4208a39a...`, `GovernanceWeighting 0x77BA0644...`, `FounderDecentralization 0x8a71Ee81...`, `TransitionCalldataBuilder 0xa898EEee...`.

### Sepolia — CLEAN (deployed by `0xaaFdFb21...`)

✅ Fully operational, admin functions safe to call.

| Contract | Address |
|---|---|
| CheesecoinsOptionsMarket proxy | `0xf06CB7648de7de7B968018714534C6722eAa6195` |
| Options ProxyAdmin | `0xE21789e3C360D76098A8f3bAbB91bD4A2Edf69cf` |
| CommodityPriceOracle | `0x43aEFD293ef29ABD5e512947d38F4131dBA894EF` |

USDC `0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d` is the Aave faucet — externally owned, neutral.

### Pending Sepolia redeploy (Path 1 scope)

To unblock B3 + Phase 2 commerce on testnet, redeploy under `0xaaFdFb21...`:
- Fresh CURD test token (or skip — many flows can use USDC only)
- MockUSDC (or reuse Aave faucet USDC)
- ProjectSale + Admin + Proxy
- B3 stack: BurnAuthority, FiatRedemptionVault, MerchantRegistry, MerchantSettlement, B3 ProxyAdmin
- CommerceNFTTemplate impl

NFT layer / SceneTracker / Options stack stay as-is — read-only display still works (NFT) and Options is already clean.

---

## What Is Functional End-to-End (Mainnet)

| Flow | Functional? | Notes |
|---|---|---|
| Buyer buys CURD | ✅ | CurdDirectSale live, 10M CURD loaded |
| Buyer buys Scene NFT | ✅ | CsaCertificateSale live, website wired |
| Buyer stakes NFT/CURD | ✅ | Contracts live, 5M CURD funded in BootstrapYieldPool (April 2026) |
| Buyer buys Commerce NFT | ❌ | ProjectSale live but no CommerceNFT deployed, no project registered |
| Write / buy commodity options | ⚠️ | LIVE end-to-end on Sepolia (4 of 8 markets — corn/wheat/soy/USD-CAD). Mainnet pending 7-day clean-streak (~May 5). |
| Partner registers as merchant | ✅ | **MerchantRegistry live at V3** with 5-tier supply-chain enum; Nubians North registered May 4 2026; POS validated end-to-end |
| CURD → USDC merchant settlement | ❌ | MerchantSettlement deployed, not configured |
| Fiat redemption vault | ❌ | Deployed, fee=0, cap=0, not funded, blocked on Uniswap anyway |
| Governance proposals | ⚠️ | Deployed, tested on Sepolia fork, untested on mainnet |
| Treasury yield / T-bill reserve | ❌ | Concept only — no T-bills purchased, no yield flowing |

---

## Known Issues / Gotchas

1. **NubiansNorthNFT hardcodes PROJECT_ID = 1** — wrong, canonical is 2. Always use `nftToProject` mapping.
2. **ProxyAdmin (core) owned by ProtocolTimelock** — upgrades require 2-day delay on mainnet.
3. **Hook wiring must happen BEFORE minting** on any new NFT deployment.
4. **ERC721A does not support tokenOfOwnerByIndex** — use `totalSupply()` + `ownerOf()` loop.
5. **Project ID 1 is abandoned** — ChatGPT test deploy, never interact.
6. **Sepolia ProjectSale + CommerceNFT owned by compromised wallet** — testnet only, cannot be safely administered.
7. **B3 contracts on mainnet deployed but not configured** — BurnAuthority, FiatRedemptionVault, MerchantSettlement, TreasuryRateAdvisor all need post-deploy Safe transactions before they do anything. (MerchantRegistry no longer in this list — live at V3 May 4 2026 with 2 merchants registered.)
8. ~~**BootstrapYieldPool has no yield funded**~~ — **RESOLVED April 2026: 5M CURD funded, staking yields active.**
9. **CommerceProjectSale.sol in repo is wrong** — non-upgradeable duplicate of ProjectSale. Do not deploy. Use ProjectSale proxy at `0x07FC042B155628980aA5B00EB9B53D3B3D71E7fc`.

---

## Governance Stage

**Current stage: Stage 0** — Founder EOA sole authority.

| Stage | Control | Trigger |
|---|---|---|
| Stage 0 | Founder EOA | Now |
| Stage 1 | Founder + DAO shared | MaturityOracle.isYear2Eligible() + PROPOSER_ROLE granted |
| Stage 2 | DAO sovereignty | MaturityOracle.isYear5Eligible() + founder weight decayed |

---

## BootstrapYieldPool Funding — COMPLETE (April 2026)

**Status:** ✅ Complete. Verified on-chain April 23 2026.

- CheesecoinsCore proxy upgraded to V2 impl `0xD22a0722B79F3a82E32d5BDb36eECBB9e42333C7`
- BootstrapYieldPool balance = 5,000,000 CURD (confirmed via `cast call`)
- Stakers now earn yield

**BOOTSTRAP_PID = type(uint256).max** (intentional — confirmed on-chain)

---

## What Needs To Happen Next (in priority order — as of April 26 2026)

1. ✅ ~~**BootstrapYieldPool funding**~~ — complete, 5M CURD funded, CheesecoinsCore upgraded to V2
2. ✅ ~~**Deploy CheesecoinsOptionsMarket to Sepolia**~~ — current proxy `0xf06CB7648de7de7B968018714534C6722eAa6195` w/ oracle routing
3. ✅ ~~**Test options market on Sepolia**~~ — write/buy/exercise confirmed April 28; USDA keeper feeding daily
4. **Sepolia 7-day clean-streak** — running. Earliest mainnet cutover ~May 5 2026
5. **Commerce NFT flow** — register first project (Meat & Cheese Box) in ProjectSale via Safe, wire admin approve button to actual `activateSale()` on-chain call
6. **B3 post-deploy config** — set fees, rate steps, daily cap, fund vault, register first merchant (via Safe)
7. ✅ ~~**MerchantRegistryV2 upgrade**~~ — completed prior to May 4 2026
8. ✅ ~~**MerchantRegistryV3 upgrade**~~ — completed May 4 2026 evening. Impl `0x033435CA67B79aCe3d9052157c34a584a5A8FDE9`, 5-tier enum, both pre-existing merchants survived with default Tier.Merchant.
9. **MerchantSettlementV2 rewrite** — current impl has storage collision bug, do not deploy
10. **Redeploy Sepolia ProjectSale + CommerceNFT** — previous deploy owned by compromised wallet `0xe3116832...`, must redeploy with clean wallet `0xaaFdFb21...`
