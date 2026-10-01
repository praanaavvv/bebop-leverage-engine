# bebop-api

Leveraged long positions on Base: **Aave V3** for borrowing, **Bebop RFQ** for swaps, and a **Morpho** flash loan (zero fee) to open or close in a single transaction.

Each user gets an isolated `Position` contract (an EIP-1167 clone deployed via CREATE2). Because its address is known before deployment, Bebop can quote with the position as the taker. Your own wallet signs every transaction; the backend never holds user keys.

> ⚠️ The contracts are **not audited**. Use small amounts at your own risk.

## What's here

| Path | Purpose |
|---|---|
| `contracts/` | Foundry project: `Position.sol` (opens, increases, and reduces positions) and `PositionFactory.sol` (deploys a position's clone at its precomputed address) |
| `bebop.ts` | Bebop API client with no dependencies (also usable as a CLI) |
| `server.ts` | Serves the UI and proxies quote requests so the Bebop key stays server-side |
| `web/` | Single-page UI: connect a wallet, preview a quote, open a long, close it |
| `scripts/` | Local fork setup and mainnet deploy |

## Quick start (local fork)

Requires Node ≥ 23 and [Foundry](https://getfoundry.sh).

```bash
cp .env.example .env      # Bebop credentials are optional (demo mode without them)
npm install
npm run dev               # starts an Anvil fork of Base, deploys contracts, serves http://localhost:3000
```

Click **Use fork test account**, then **Fund my wallet**, then **Open long**.

## Base mainnet

```bash
npm run deploy:base       # needs BASE_RPC + DEPLOYER_KEY in .env; asks for confirmation
npm run serve:live
```

## Tests

```bash
cd contracts && forge test
```

## License

MIT
