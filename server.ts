#!/usr/bin/env node
/**
 * Backend for the leverage test harness.
 *
 *   - serves the frontend (web/index.html)
 *   - /api/config : chain + contract addresses the frontend needs
 *   - /api/quote  : Bebop RFQ proxy — the API key stays server-side (per the reference doc,
 *                   the frontend must never call Bebop directly)
 *   - /api/faucet : funds an address with ETH + USDC on the Anvil fork (dev convenience only)
 *
 * The user's OWN wallet signs and sends deploy/approve/execute — this backend never holds a
 * user key. Only the faucet is fork-specific (impersonation); everything else is the real
 * production shape.
 */
import { existsSync, readFileSync } from "node:fs";
import { createServer, type ServerResponse } from "node:http";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createPublicClient, createTestClient, createWalletClient, http, parseEther, type Address } from "viem";
import { base } from "viem/chains";
import { request as bebopRequest } from "./bebop.ts";

const ROOT = dirname(fileURLToPath(import.meta.url));
// fork (default): localhost Anvil, faucet enabled. live: real Base, faucet disabled.
// live mode: run with `HARNESS_MODE=live node --env-file=.env server.ts` after deploying to Base.
const LIVE = process.env.HARNESS_MODE === "live";
const RPC = LIVE ? process.env.BASE_RPC : "http://localhost:8545";
if (LIVE && !RPC) throw new Error("HARNESS_MODE=live needs BASE_RPC (use node --env-file=.env)");
const PORT = 3000;

// Base (8453)
const USDC = "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913" as Address;
const WETH = "0x4200000000000000000000000000000000000006" as Address;
const A_WETH = "0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7" as Address;
const VDEBT_USDC = "0x59dca05b6c26dbd64b5381374aAaC5CD05644C28" as Address;
const A_USDC = "0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB" as Address; // faucet source (holds pooled USDC)
const POOL = "0xA238Dd80C259a72e81d7e4664a9801593F98d1c5" as Address;

const pub = createPublicClient({ chain: base, transport: http(RPC) });
const test = createTestClient({ mode: "anvil", chain: base, transport: http(RPC) });

// Live mode reads addresses.live.json (written by deploy:base) so a fork run of
// `npm run dev` — which rewrites addresses.json with FORK addresses at the same
// chainId 8453 — can never clobber the mainnet deployment the live app points at.
const liveAddrs = join(ROOT, "contracts/addresses.live.json");
const addrPath = LIVE && existsSync(liveAddrs) ? liveAddrs : join(ROOT, "contracts/addresses.json");
const { factory: FACTORY, impl: IMPL } = JSON.parse(readFileSync(addrPath, "utf8")) as {
  factory: Address;
  impl: Address;
};

const erc20 = [
  { type: "function", name: "transfer", stateMutability: "nonpayable", inputs: [{ type: "address" }, { type: "uint256" }], outputs: [{ type: "bool" }] },
] as const;

const config = {
  chainId: base.id, // 8453
  live: LIVE,
  rpc: RPC,
  factory: FACTORY,
  impl: IMPL,
  usdc: USDC,
  weth: WETH,
  aWeth: A_WETH,
  vDebtUsdc: VDEBT_USDC,
  pool: POOL,
};

/** Give an address 10 ETH (gas) + 5000 USDC on the fork by impersonating the aUSDC contract. */
async function faucet(address: Address) {
  await test.setBalance({ address, value: parseEther("10") });
  await test.setBalance({ address: A_USDC, value: parseEther("1") });
  await test.impersonateAccount({ address: A_USDC });
  const whale = createWalletClient({ account: A_USDC, chain: base, transport: http(RPC) });
  const hash = await whale.writeContract({
    address: USDC, abi: erc20, functionName: "transfer", args: [address, 5_000_000_000n], account: A_USDC, chain: base,
  });
  await pub.waitForTransactionReceipt({ hash });
  await test.stopImpersonatingAccount({ address: A_USDC });
}

async function quote(sell: Address, buy: Address, amount: string, taker: Address, origin: Address) {
  return bebopRequest("pmm", "base", "quote", {
    sell_tokens: sell, buy_tokens: buy, sell_amounts: amount,
    taker_address: taker, receiver_address: taker, origin_address: origin, gasless: "false",
  });
}

function json(res: ServerResponse, code: number, body: unknown) {
  res.writeHead(code, { "content-type": "application/json" });
  res.end(JSON.stringify(body));
}

async function readBody(req: import("node:http").IncomingMessage) {
  const chunks: Uint8Array[] = [];
  for await (const c of req) chunks.push(c as Uint8Array);
  return chunks.length ? JSON.parse(Buffer.concat(chunks).toString()) : {};
}

createServer(async (req, res) => {
  try {
    const url = req.url ?? "/";
    if (req.method === "GET" && (url === "/" || url === "/index.html")) {
      res.writeHead(200, { "content-type": "text/html" });
      res.end(readFileSync(join(ROOT, "web/index.html")));
      return;
    }
    if (req.method === "GET" && url === "/viem.js") {
      res.writeHead(200, { "content-type": "application/javascript" });
      res.end(readFileSync(join(ROOT, "web/viem.js")));
      return;
    }
    if (req.method === "GET" && !url.startsWith("/api/") && !url.includes("..")) {
      try {
        const body = readFileSync(join(ROOT, "web", url.slice(1)));
        const type = url.endsWith(".js") ? "application/javascript" : url.endsWith(".html") ? "text/html" : "text/plain";
        res.writeHead(200, { "content-type": type });
        res.end(body);
        return;
      } catch { /* fall through to 404 */ }
    }
    if (req.method === "GET" && url === "/api/config") return json(res, 200, config);
    if (req.method === "POST" && url === "/api/faucet") {
      if (LIVE) return json(res, 400, { error: "faucet is fork-only; fund your wallet with real USDC + ETH" });
      const b = await readBody(req);
      await faucet(b.address);
      return json(res, 200, { ok: true });
    }
    if (req.method === "POST" && url === "/api/quote") {
      const b = await readBody(req);
      return json(res, 200, await quote(b.sell, b.buy, b.amount, b.taker, b.origin));
    }
    json(res, 404, { error: "not found" });
  } catch (e) {
    json(res, 500, { error: (e as Error).message });
  }
}).listen(PORT, () => console.log(`harness [${LIVE ? "LIVE Base" : "fork"}] → http://localhost:${PORT}  (factory ${FACTORY})`));
