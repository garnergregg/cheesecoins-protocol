# NFT Metadata — Source of Truth

## The only source of truth for NFT descriptions is IPFS.

**Metadata CID (on-chain):** `bafybeig6evhwhmgswnwnpl4jaeea2xhpq2shm4l7lx62s4sbpq2wmsn7fy`
**Image CID:** `bafybeiajfypjvrlhz2j56u4olhoabm5adlpfouuu25vyfk4louc6rvuy5q`
**Pinata gateway:** `https://fuchsia-accepted-mosquito-993.mypinata.cloud/ipfs`

### How tokenURI resolves

The contract builds: `baseURI + sceneNumber + ".json"`

Example — Scene 1:
```
https://fuchsia-accepted-mosquito-993.mypinata.cloud/ipfs/bafybeig6evhwhmgswnwnpl4jaeea2xhpq2shm4l7lx62s4sbpq2wmsn7fy/1.json
```

This is what OpenSea reads. This is what the marketplace reads. This is what feeds the social posts.

### Local metadata files

`/Users/greggarner/Nubians-North-web-site/assets/metadata/{scene_id}.json`

These files were uploaded to Pinata to produce the metadata CID above. They are kept in sync with IPFS — **confirmed April 5 2026** by comparing scenes 1 and 31 against live Pinata responses.

**Use the local files as the source when regenerating queue/seed text.** Do not use the website's `nftScenes.ts` data file — it may lag behind metadata updates.

### When descriptions are revised

If descriptions are updated on IPFS (new Pinata upload → new CID):
1. Update `Config.sol` → `NFT_BASE_URI` to the new CID
2. Call `setBaseURI()` on the deployed NFT contract
3. Update the local metadata files to match
4. Re-run `mcp/scripts/queue_nft_scenes.py` to regenerate `post_queue_seed.jsonl`
5. Push — Render bootstrap will update pending queue entries automatically

### MCP post queue

- **Source:** `mcp/orchestrator/agents/queue_nft_scenes.py` reads local metadata files → writes `post_queue_seed.jsonl`
- **Render bootstrap** merges seed into disk queue on every deploy, and now also **updates text of existing pending entries** when seed text has changed (patched April 5 2026)
- **DO NOT** regenerate descriptions from `nftScenes.ts` or any other source

### DO NOT run the local MCP server while Render is live

Both servers dispatch from their own queue files. Running both causes duplicate posts to Telegram and Discord. The local server is for development only — kill it before Render goes live.

```bash
# Kill local server if accidentally running
lsof -ti :9101 | xargs kill -9
```
