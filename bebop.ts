#!/usr/bin/env node
/**
 * Minimal Bebop API client (no dependencies — Node >= 23 runs this directly:
 * `node bebop.ts ...`).
 *
 * Every request carries both attribution lines:
 *   - source=<BEBOP_SOURCE> as a query param
 *   - source-auth=<BEBOP_SOURCE_AUTH> as a query param AND request header
 *
 * APIs:
 *   jam  -> Aggregation API   https://api.bebop.xyz/jam/{chain}/v2/...
 *   pmm  -> RFQ (PMM) API     https://api.bebop.xyz/pmm/{chain}/v3/...
 *
 * Leverage fixture (see contracts/test/fixtures/):
 *   node bebop.ts --api pmm --chain base quote \
 *     --sell <USDC> --buy <WETH> --amount 300000000 \
 *     --taker <predicted Position> --receiver <predicted Position> \
 *     --origin-address <user EOA> --origin-target <entrypoint> \
 *     --gasless false > contracts/test/fixtures/quote-open.json
 */
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { parseArgs } from "node:util";

const BASE = "https://api.bebop.xyz";
const VERSIONS: Record<string, string> = { jam: "v2", pmm: "v3" };

type Params = Record<string, string | undefined>;

function loadEnv(path = join(dirname(fileURLToPath(import.meta.url)), ".env")): void {
  let text: string;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return; // no .env — real shell env vars may be in use
  }
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#") || !line.includes("=")) continue;
    const i = line.indexOf("=");
    const k = line.slice(0, i);
    if (!(k in process.env)) process.env[k] = line.slice(i + 1);
  }
}

// Hard concurrency bound: AT MOST ONE Bebop request in flight at any instant.
// Every Bebop call — quotes, native price fetches, order status, anything — routes
// through request(), so this serial gate guarantees we never have two outbound
// requests to Bebop at the same time. Extra calls queue and run strictly one-by-one.
let bebopGate: Promise<void> = Promise.resolve();

async function fireRequest(api: string, chain: string, endpoint: string, params: Params): Promise<unknown> {
  loadEnv();
  const auth = process.env.BEBOP_SOURCE_AUTH ?? "";
  const query = new URLSearchParams();
  for (const [k, v] of Object.entries(params)) if (v !== undefined) query.set(k, v);
  query.set("source", process.env.BEBOP_SOURCE ?? "");
  query.set("source-auth", auth);
  const url = `${BASE}/${api}/${chain}/${VERSIONS[api]}/${endpoint}?${query}`;
  const resp = await fetch(url, {
    headers: { "source-auth": auth, accept: "application/json" },
    signal: AbortSignal.timeout(30_000),
  });
  return resp.json();
}

export function request(api: string, chain: string, endpoint: string, params: Params): Promise<unknown> {
  const prev = bebopGate; // the previous request's completion signal
  let release!: () => void;
  bebopGate = new Promise<void>((r) => (release = r)); // this request's completion signal
  return (async () => {
    await prev; // wait until nothing else is in flight (always resolves; never rejects)
    try {
      return await fireRequest(api, chain, endpoint, params);
    } finally {
      release(); // let the next queued request start
    }
  })();
}

export function quote(chain: string, params: Params, api = "jam"): Promise<unknown> {
  return request(api, chain, "quote", params);
}

export function orderStatus(chain: string, quoteId: string, api = "jam"): Promise<unknown> {
  return request(api, chain, "order-status", { quote_id: quoteId });
}

async function main(): Promise<void> {
  const { values: v, positionals } = parseArgs({
    allowPositionals: true,
    options: {
      api: { type: "string", default: "jam" }, // jam=Aggregation, pmm=RFQ
      chain: { type: "string", default: "ethereum" },
      sell: { type: "string" }, // sell token address
      buy: { type: "string" }, // buy token address
      amount: { type: "string" }, // sell amount in wei/base units
      taker: { type: "string" }, // taker address (the Position for leverage)
      receiver: { type: "string" }, // receiver address, defaults to taker
      "origin-address": { type: "string" }, // end-user EOA (required for contract takers)
      "origin-target": { type: "string" }, // the `to` of the resulting tx
      gasless: { type: "string" }, // "false" = self-execution calldata
      slippage: { type: "string" },
      "quote-id": { type: "string" },
    },
  });

  const cmd = positionals[0];
  let out: unknown;
  if (cmd === "quote") {
    for (const req of ["sell", "buy", "amount", "taker"] as const) {
      if (!v[req]) throw new Error(`--${req} is required`);
    }
    out = await quote(
      v.chain,
      {
        sell_tokens: v.sell,
        buy_tokens: v.buy,
        sell_amounts: v.amount,
        taker_address: v.taker,
        receiver_address: v.receiver,
        origin_address: v["origin-address"],
        origin_target: v["origin-target"],
        gasless: v.gasless,
        slippage: v.slippage,
      },
      v.api,
    );
  } else if (cmd === "status") {
    if (!v["quote-id"]) throw new Error("--quote-id is required");
    out = await orderStatus(v.chain, v["quote-id"], v.api);
  } else {
    throw new Error("usage: node bebop.ts [--api jam|pmm] [--chain <chain>] quote|status ...");
  }
  console.log(JSON.stringify(out, null, 2));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message ?? e);
    process.exit(1);
  });
}
