# Cheesecoins Protocol

The first agricultural supply-chain settlement protocol on Arbitrum. Every link in the chain — vendor, producer, processor, distributor, merchant — is on-chain, paid in CURD, and reconcilable in real time. Live on mainnet. Working dairy goat farm at the center.

## Status

**Live on Arbitrum One since March 25, 2026.**

Twelve contracts deployed under a 2-of-2 Gnosis Safe. 200 million CURD minted. MerchantRegistry V3 (5-tier supply-chain enum) live since May 4, 2026. Nubians North registered as the first producer.

## Key contracts (Arbitrum One mainnet)

| Contract | Address |
|---|---|
| CURD token (CheesecoinsCore V2) | [0x833551...fB89cD](https://arbiscan.io/address/0x833551C5433551fDA5b49D03044D7Df51ffB89cD) |
| NubiansNorthNFT | [0x4a99b2...808aAD](https://arbiscan.io/address/0x4a99b2Dc6d5D4745148F13C06965508306808aAD) |
| MerchantRegistry V3 | [0xCA7f73...8709bA](https://arbiscan.io/address/0xCA7f73aCb86a8aCEf897c06eE23Adf8cDf8709bA) |
| StakingManager | [0xcfbd9e...cb35B6](https://arbiscan.io/address/0xcfbd9e4B97DD40863b134e7979d3038Ec5cb35B6) |
| BootstrapYieldPool | [0x27b55A...9DE68C](https://arbiscan.io/address/0x27b55A7fFaeD5df6f174bb29fc2D8f08329DE68C) |
| ProtocolTimelock | [0x0E7d11...9ebb5C](https://arbiscan.io/address/0x0E7d119224855ca259a80cb0C0a6a82fa29ebb5C) |

Full mainnet manifest: [`contracts-v2/deployments/42161-arbitrum-one-all.json`](contracts-v2/deployments/42161-arbitrum-one-all.json)

## Documentation

- [Arbitrum Foundation grant application (v2)](docs/ARBITRUM_GRANT_APPLICATION_V2.pdf)
- [Tokenomics V2](docs/TOKENOMICS_V2.md)
- [Phase 2 build spec](docs/PHASE_2_SPEC.md)
- [Monetary constitution](docs/MONETARY_CONSTITUTION.md)
- [Ecosystem flowchart](docs/ECOSYSTEM_FLOWCHART.md)
- [NFT metadata source of truth](docs/NFT_METADATA_SOURCE_OF_TRUTH.md)
- [Financial projections (Y1–Y3 model)](docs/CHEESECOINS_FINANCIAL_PROJECTIONS.xlsx)
- [Security audit report](contracts-v2/foundry-docs/SECURITY_AUDIT_REPORT_2026-03.md)
- [Deployment state](contracts-v2/foundry-docs/DEPLOYMENT_STATE_2026-03.md)

## Build & test

Requires [Foundry](https://book.getfoundry.sh/).

```
cd contracts-v2
forge build
forge test
```

859 tests across all production contracts.

## Web

- [cheesecoins.com](https://cheesecoins.com)
- [nubiansnorth.com](https://nubiansnorth.com)

## License

[BUSL-1.1](LICENSE) — Business Source License 1.1. Converts to Apache 2.0 on May 6, 2030.
