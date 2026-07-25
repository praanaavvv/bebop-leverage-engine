# Leveraged trading on Aave + Bebop (Base)

Build reference. Replaces CoW Protocol with Bebop RFQ as the execution venue and keeps Aave V3 as the debt layer.

Verified against Bebop docs (docs.bebop.xyz, July 2026), the Aave address book, safe-deployments, and the two CoW leverage POCs (`koeppelmann/Cowswap-Leverage`, `kaze-cow/cowswap-pro`, both branch `feat/onchain-leverage`).

Status markers used throughout:
- **[V]** verified from primary source
- **[?]** needs empirical confirmation on a fork before we rely on it
- **[ASK]** needs a conversation with Bebop

---

## 0. Adding the Bebop docs MCP

### Claude Code (recommended, native)

```bash
# project scope (writes .mcp.json, commit it so the whole team gets it)
claude mcp add --scope project --transport http bebop-docs https://docs.bebop.xyz/mcp

# or user scope (available in every project on your machine)
claude mcp add --scope user --transport http bebop-docs https://docs.bebop.xyz/mcp

claude mcp list          # confirm registered
# then inside Claude Code:
/mcp                     # check connection status
```

`--transport http` is the current standard for remote servers. `--scope` precedence is local > project > user. No auth header needed; the Bebop docs server is public and read-only.

Equivalent `.mcp.json` if you'd rather hand-write it:

```json
{
  "mcpServers": {
    "bebop-docs": {
      "type": "http",
      "url": "https://docs.bebop.xyz/mcp"
    }
  }
}
```

### The `npx add-mcp` route

`add-mcp` (npm package `add-mcp`, by neon-solutions) is a third-party CLI that writes MCP config into ~15 different agents (Claude Code, Codex, Cursor, VS Code, OpenCode, Cline, and others) from one command:

```bash
npx add-mcp https://docs.bebop.xyz/mcp
# target a specific agent:
npx add-mcp https://docs.bebop.xyz/mcp --agent claude-code
```

It's convenient if you're running several agents. For Claude Code alone, `claude mcp add` is fewer moving parts and doesn't pull a third-party package into the loop.

### What the server actually gives you

Three tools plus one skill resource:

| Tool | Use |
|---|---|
| `search_bebop_api_docs` | semantic search over the docs |
| `query_docs_filesystem_bebop_api_docs` | read-only `rg`/`cat`/`head`/`tree`/`jq` over a virtual FS of the docs and OpenAPI specs. This is how you read a full page: `cat /rfq-api/quickstart.mdx` |
| `submit_feedback` | report a docs bug |

Resource `mintlify://skills/bebop` is a skill describing quote requests, order submission, approvals, gasless execution, and pricing streams. Read it once at the start of a session.

Useful raw endpoints even without the MCP:
- `https://docs.bebop.xyz/llms.txt` (full page index)
- any page as markdown by appending `.md`, e.g. `https://docs.bebop.xyz/rfq-api/quickstart.md`
- OpenAPI: `https://docs.bebop.xyz/specs/rfq-api.json`, `.../aggregation-api.json`

---

## 1. How Bebop works, and which product we use

Bebop is two liquidity systems behind one brand. **[V]**

### RFQ API (`/pmm/...`) — this is the one we want

Professional market-maker desks quote firm prices over HTTP. The maker signs an EIP-712 order. The price is **firm with 0% slippage until expiry**, and `buyTokens[x].minimumAmount == buyTokens[x].amount`. There is no AMM curve, no price impact at execution, no sandwich risk on the swap leg.

Two execution modes, set by the `gasless` query param:

- `gasless=false` (self-execution): the quote response contains a ready-to-broadcast `tx` object (`to`, `data`, `value`, `gas`). **No taker signature is required.** The taker's authorization *is* being `msg.sender`. Bebop's own interface comments confirm this: "if taker executes order himself then signature can be `'0x'`". This is the mode we use, and it is exactly what makes a smart-contract taker possible.
- `gasless=true` (default): you sign an EIP-712 order and POST to `/v3/order`; Bebop pays gas. Makers retain **last look** and can reject, so orders can come back `Failed`. Not suitable for an atomic leverage transaction.

Quote expiry on Base: **60s standard, 3s with `expiry_type=short`**. Short expiry gives tighter pricing but the tx must *land in a block* before expiry, not merely be broadcast. **[V]**

### Aggregation API (`/jam/...`) — the JAM solver auction

Intent-based, solver competition, taker signs a `JamOrder`. Conceptually much closer to CoW. Its settlement contract validates taker signatures via **EIP-1271** (`JamValidation.validateSignature` falls through to `IERC1271.isValidSignature` when the taker has code), so a contract taker works here too. **[V]**

We are not using JAM for v1. It reintroduces the asynchronous-third-party-executor problem that made the CoW version complicated. Keep it in mind as a later option if we want broader token coverage.

### BopAMM

Closed beta, oracle-priced on-chain AMM from the same MM network, with a `swapWithFallback` that tries the on-chain book and settles via RFQ if it can't fill. Interesting later; ignore for now.

### Authentication and rate limits **[V]**

- Pass `source=<your-partner-id>` as a query param and the key as `source-auth` (query param or header).
- Without a key you get **demo mode**: widened quotes, heavy rate limits. Fine for fork testing, useless for production pricing.
- Keys are per-integration. Keep the key **server-side only**. This forces a small backend proxy; the frontend must never call Bebop directly.

### Bebop's integrator rules that constrain our design **[V]**

Straight from their best-practices page, and they matter because violating them gets you maker-level deny-listed:

1. **Use the Price API WebSocket stream for sizing, not `/quote`.** Only call `/quote` at the moment of execution. So: the leverage slider in the UI reads the stream; `/quote` fires on the confirm click.
2. **Never cache a quote and execute it later when it becomes favourable.** That's toxic flow.
3. **One quote per intended fill.** Don't slice. If you need flexibility on size, use **partial fills** (the quote response has a `partialFillOffset` telling you where in the calldata to patch the fill amount).
4. **One quote for the same pair per transaction.**
5. **Origin fields.** This is the important one for us:

| Field | We send |
|---|---|
| `taker_address` | the Position contract (required) |
| `origin_address` | the end user's EOA (required for us, since our taker is a contract) |
| `origin_target` | the `to` of the resulting tx, i.e. our entrypoint contract |
| `origin_source` | optional, a stable sub-source id |

Their docs say **"Bebop screens this contract before forwarding the request"** about `origin_target`, and that depending on integration profile they may *require* `origin_address` and reject requests without it. **[ASK]** We need to tell Bebop our contract addresses and integration shape before mainnet.

---

## 2. The architecture

### What we delete relative to the CoW version

Almost everything. The CoW POC needed generalized wrappers, an appData EIP-712 envelope, EIP-1271 blessing through transient storage, on-chain reconstruction of a JSON appData document, a counterfactual Safe whose address commits to the trade economics, a same-token "carrier" order, and a `tx.gasprice == 0` hack in a Safe fallback handler. All of that exists because a third party (a solver) executes your swap in *their* transaction, minutes later, and order identity is the keccak of an off-chain document.

Bebop self-execution hands us calldata we call ourselves, in our own transaction, synchronously. So leverage collapses to what it actually is: four operations in one function.

### What we keep

1. **The isolated position account.** Aave positions are keyed by address. One address per position. This is the single most important structural decision (section 3).
2. **Counterfactual addressing.** We need the position address *before* it exists, so we can pass it as `taker_address` to Bebop. CREATE2 gives us that, same trick as the CoW version, minus the machinery.
3. **Health-factor guards as in-transaction postconditions**, not pre-checks.
4. **Supply the full realized balance**, never the quoted minimum, so positive slippage isn't stranded (this was a "medium" finding in their internal review).
5. **Debt-first ordering inside the flash window** on any reduce, so Aave's LTV check never sees an invalid intermediate state.
6. **Aave MAX semantics** (`type(uint256).max`) on repay and withdraw for a full close, plus a residual sweep with balances read at execution time. Otherwise interest accrual strands dust.
7. **Read amounts at execution time.** aToken and variable-debt balances move every second.

### The core flow (open a long)

```
User has E of debt token (e.g. USDC). Wants X× long collateral (e.g. WETH).

off-chain:
  1. predict position address P = CREATE2(factory, user, index)
  2. compute L = (X - 1) * E                    // flash size, in debt token
  3. GET /pmm/base/v3/quote
       sell_tokens = USDC, sell_amounts = E + L  (= X * E)
       buy_tokens  = WETH
       taker_address = P, receiver_address = P
       origin_address = user EOA, origin_target = <entrypoint>
       gasless = false
     -> firm quote: buyTokens[WETH].amount = C_min, tx = {to, data}, expiry

on-chain, one transaction:
  4. deploy P if it has no code (CREATE2 clone)
  5. pull E from user -> P                       // ERC20 approve, or permit
  6. P: flashLoan(debtToken, L)                  // Morpho Blue, zero fee
  7. P: approve(approvalTarget, X * E)
  8. P: call(tx.to, tx.data)                     // Bebop settles, WETH -> P
  9. P: assert collateralReceived >= C_min
 10. P: approve(POOL, fullCollateralBalance); POOL.supply(WETH, full, P, 0)
 11. P: if eMode != 0 { POOL.setUserEMode(e); POOL.setUserUseReserveAsCollateral(WETH, true) }
 12. P: POOL.borrow(USDC, L + premium, 2, 0, P)  // premium == 0 with Morpho
 13. P: approve(flashSource, L + premium)        // Morpho pulls it back
 14. P: assert healthFactor(P) >= minHF
 15. P: reset all approvals to 0
```

Result: collateral worth roughly `X * E`, debt roughly `(X - 1) * E`. One transaction, one user signature (or zero extra with permit), around 150 lines of Solidity.

### The amount math

```
E   = user equity, in debt-token units
X   = target leverage (1e4 fixed point, so 2.5x -> 25000)
L   = flash size            = E * (X - 1e4) / 1e4
S   = swap size             = E + L        = E * X / 1e4
p   = flash premium
B   = Aave borrow           = L + p
C   = collateral acquired   = whatever the swap actually returns (>= C_min)
```

With **Morpho Blue as the flash source, `p = 0`** and `B = L` exactly. That deletes an entire class of bug. The CoW POC hardcoded Aave's 5bps premium and had to replicate Aave's `PercentageMath.percentMul` half-up rounding exactly, because flooring left the borrow one wei short and reverted the whole settlement. Their own docs list "fixed 5bps flash premium" as a known limitation.

If you do use Aave for the flash, **read `POOL.FLASHLOAN_PREMIUM_TOTAL()` on-chain**, never hardcode it, and round the premium up:

```solidity
premium = (L * FLASHLOAN_PREMIUM_TOTAL + 9999) / 10000;  // ceil
```

### Reduce / partial close / deleverage

One mode covers close, partial close, and deleverage, exactly as in the CoW version:

```
flash D of debt token
  -> POOL.repay(debt, repayAmount, 2, P)      // repayAmount = MAX for full close
  -> POOL.withdraw(collateral, sellAmount + extra, P)   // MAX for full close
  -> swap collateral -> debt via Bebop
  -> repay flash (D + p)
  -> sweep residual (both tokens) to receiver
  -> assert HF >= minHF        // skip on full close, HF becomes infinite
```

**Bebop is strictly better than CoW here.** With an `exactIn` quote you know the debt-token output *exactly* (firm price), so you can size the flash precisely instead of guessing from a `minBuy` bound. Alternatively use `buy_amounts` (exactOut) to buy exactly `D + p` of debt token and let the leftover collateral fall out as residual.

Full-close dust handling: both the aToken balance and the variable-debt balance grow every block, so the quoted `sellAmount` will be slightly stale by the time the tx lands. Options:
- quote for slightly less than the current aToken balance, sell that, sweep the collateral remainder to the user (simplest, tiny dust in collateral token);
- **[?]** use the router's `exactAmount == 0` mode, documented as "use whatever `fromToken` balance the router holds", which would consume the full transferred balance. Needs verification that this is reachable from API-returned calldata.
- **[?]** patch the fill amount at `partialFillOffset` (32-byte zero-padded hex) down to the realized balance. This is the officially supported flex-size mechanism.

### Increase leverage

```
POOL.borrow(debt, extraDebt, 2, 0, P)
  -> swap debt -> collateral via Bebop
  -> POOL.supply(collateral, fullBalance, P, 0)
  -> assert HF >= minHF
```

No flash loan needed (borrow happens first), but the borrow is capped by Aave's current `availableBorrows` for the position.

---

## 3. The position account: clone vs Safe

This decides the shape of everything else.

### Recommendation for v1: minimal CREATE2 clone

```solidity
contract PositionFactory {
    address public immutable IMPL;

    function positionOf(address owner, uint96 index) public view returns (address) {
        return Clones.predictDeterministicAddress(IMPL, _salt(owner, index), address(this));
    }
    function _salt(address owner, uint96 index) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(owner)) << 96 | uint256(index));
    }
    function deploy(address owner, uint96 index) public returns (address p) {
        p = positionOf(owner, index);
        if (p.code.length == 0) {
            Clones.cloneDeterministic(IMPL, _salt(owner, index));
            Position(p).initialize(owner);
        }
    }
}
```

Why a clone rather than a Safe:
- deployment is roughly 45k gas vs roughly 250k for a Safe proxy plus module setup
- no module system, no fallback handler, no EIP-1271 plumbing to reason about
- we don't need Safe's multi-owner or arbitrary-tx capability; we need exactly three verbs
- the CoW version used a Safe because it needed `execTransactionFromModule` (so a wrapper could act as the user) and EIP-1271 (so a contract could own a CoW order). Neither applies to us
- fewer trusted components means a smaller audit surface

The salt commits to `(owner, index)` only, not to the trade economics. The CoW version committed the entire intent into the salt because `bootstrap()` was publicly callable and needed to be grief-proof. Our factory is called by the user in their own tx, so that isn't required.

### If you do want a Safe

Reasons you might: users already recognize Safe, and a Safe position can be recovered or managed manually via the Safe UI if our contracts break. That last point is a real operational argument.

Canonical Safe **v1.4.1** addresses, confirmed deployed on Base (chain 8453): **[V]**

| Contract | Address |
|---|---|
| SafeProxyFactory | `0x4e1DCf7AD4e460CfD30791CCC4F9c8a4f820ec67` |
| SafeL2 (singleton) | `0x29fcB43b46531BcA003ddC8FCB67FFE91900C762` |
| MultiSend | `0x38869bf66a61cF6bDB996A6aE40D5853Fd43B526` |
| MultiSendCallOnly | `0x9641d764fc13c8B624c04430C7356C1C7C8102e2` |
| CompatibilityFallbackHandler | `0xfd0732Dc9E303f09fCEf3a7388Ad10A83459Ec99` |

Traps if you go this route, all learned the hard way in the CoW codebase:
- **`MultiSendCallOnly` forbids inner delegatecalls.** Their `closeAndSweep` and `openPostA` helpers exist as single delegatecalls precisely because they could not ride inside a MultiSend blob. Budget for this.
- Enabling modules at setup requires a setup helper contract called via the `to`/`data` params of `Safe.setup`. Their Gnosis deployment used `SafeModuleSetup`; on Base, check `safe-modules-deployments` or just deploy your own one-function init helper (they did exactly that, `LevSafeInit`).
- The CREATE2 salt is `keccak256(abi.encodePacked(keccak256(initializer), saltNonce))` and the initcode hash is `keccak256(abi.encodePacked(factory.proxyCreationCode(), uint256(uint160(singleton))))`. Get either wrong and the predicted address is wrong. Pull `proxyCreationCode()` from the chain rather than embedding a literal.
- A module can make the Safe do anything. If a solver or relayer chooses the calldata, they own the Safe. Kaze's v2 rewrite exists largely because the v1 auth check was reachable only through the Safe's fallback handler, and a wrapper-chosen `pre` running *as the Safe* could repoint that fallback handler and skip the check entirely. Do not put an authorization check anywhere downstream of something the caller controls.

---

## 4. Contract inventory

### Already deployed, we only need addresses

**Bebop (same on all supported EVM chains except zkSync Era)** **[V]**

| Contract | Address | Role |
|---|---|---|
| BebopRouter | `0xBeb0009ACa35087ce7cCF11637E24dd1Aad3bf2A` | one-to-one swaps; `approvalTarget` and `tx.to` for our case |
| BebopSettlement (Blend) | `0xbbbbbBB520d69a9775E85b458C58c648259FAD5F` | many-to-one and one-to-many |
| JamSettlement | `0xbeb0b0623f66bE8cE162EbDfA2ec543A522F4ea6` | Aggregation API only |
| Jam Balance Manager | `0xC5a350853E4e36b73EB0C24aaA4b8816C9A3579a` | Aggregation API `approvalTarget` |

**Always read `approvalTarget` and `tx.to` from the quote response.** Do not hardcode. Hardcoding is exactly what broke integrators when the router was introduced in front of the settlement contract. Our on-chain allow-list should contain both the router and the settlement contract, and we assert `tx.to` is one of them.

`BebopRouter.swap` signature, for decoding and verification: **[V]**

```solidity
function swap(
    int256 exactAmount,          // >0 exactIn, <0 exactOut, ==0 use router's held balance
    BebopRouterOrder calldata order,
    bytes calldata extraInfo,
    bytes calldata routerSignature,
    bytes calldata bebopPmmCalldata,
    Hook[] calldata hooks
)
```

The PMM order struct, for reference: **[V]**

```solidity
struct BlendSingleOrder {
    uint256 expiry;
    address taker_address;      // must be our Position
    address maker_address;
    uint256 maker_nonce;
    address taker_token;
    address maker_token;
    uint256 taker_amount;
    uint256 maker_amount;
    address receiver;           // our Position
    uint256 packed_commands;
    uint256 flags;
}
```

**Aave V3 on Base (chain 8453)** **[V]** (from `bgd-labs/aave-address-book`, `AaveV3Base.sol`)

| Contract | Address |
|---|---|
| PoolAddressesProvider | `0xe20fCBdBfFC4Dd138cE8b2E6FBb6CB49777ad64D` |
| Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` |
| PoolConfigurator | `0x5731a04B1E775f0fdd454Bf70f3335886e9A96be` |
| AaveOracle | `0x2Cc0Fc26eD4563A5ce5e8bdcfe1A2878676Ae156` |
| ProtocolDataProvider | `0x0F43731EB8d45A581f4a36DD74F5f358bc90C73A` |
| UiPoolDataProvider | `0x0C6BC4a12039788be08F87e87Cff87FEDbd1D386` |

Best practice: read `POOL` from `PoolAddressesProvider.getPool()` rather than embedding the Pool address, since the provider is immutable and the Pool is a proxy whose implementation changes.

**Base assets (Aave-listed, with aToken and variable-debt token)** **[V]**

| Asset | Underlying | aToken | vDebt | Dec |
|---|---|---|---|---|
| WETH | `0x4200000000000000000000000000000000000006` | `0xD4a0e0b9149BCee3C920d2E00b5dE09138fd8bb7` | `0x24e6e0795b3c7c71D965fCc4f371803d1c1DcA1E` | 18 |
| USDC (native) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` | `0x4e65fE4DbA92790696d040ac24Aa414708F5c0AB` | `0x59dca05b6c26dbd64b5381374aAaC5CD05644C28` | 6 |
| wstETH | `0xc1CBa3fCea344f92D9239c08C0568f6F2F0ee452` | `0x99CBC45ea5bb7eF3a5BC08FB1B7E56bB2442Ef0D` | `0x41A7C3f5904ad176dACbb1D99101F59ef0811DC1` | 18 |
| cbETH | `0x2Ae3F1Ec7F1F5012CFEab0185bfc7aa3cf0DEc22` | `0xcf3D55c10DB69f28fD1A75Bd73f3D8A2d9c595ad` | `0x1DabC36f19909425f654777249815c073E8Fd79F` | 18 |
| weETH | `0x04C0599Ae5A44757c0af6F9eC3b93da8976c150A` | `0x7C307e128efA31F540F2E2d976C995E0B65F51F6` | `0x8D2e3F1f4b38AA9f1ceD22ac06019c7561B03901` | 18 |

Use **native USDC** (`0x8335...`), not USDbC (`0xd9aA...`, bridged, being wound down).

**Aave eMode categories on Base** **[V]**

| Id | Category |
|---|---|
| 0 | none |
| 1 | WETH / cbETH / wstETH / weETH collateral, WETH debt |
| 7 | weETH, WETH debt |
| 8 | wstETH, WETH debt |
| 9 | cbETH, WETH debt |
| 10 | cbBTC, USDC/GHO debt |
| 3 | ezETH, USDC debt |

eMode 1 is the interesting one for an ETH-correlated leveraged long (much higher LTV than the base category). Enter the category **after** the supply and **before** the borrow, and explicitly call `setUserUseReserveAsCollateral` because assets with base LTV 0 are not auto-enabled as collateral on supply. Both of these are lessons from the CoW code (their sDAI-on-Gnosis case had base LTV 0 and was only leverageable inside its category).

**Flash loan sources on Base**

| Source | Address | Fee | Callback |
|---|---|---|---|
| Morpho Blue | `0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb` | **zero** | `onMorphoFlashLoan(uint256 assets, bytes data)` |
| Aave V3 Pool | `0xA238Dd80C259a72e81d7e4664a9801593F98d1c5` | `FLASHLOAN_PREMIUM_TOTAL` (read on-chain) | `executeOperation(...)` |

**Use Morpho Blue.** Flash loans are free, `flashLoan(token, assets, data)` sends the assets to the caller (no recipient plumbing), and you repay by approving Morpho to pull `assets` back. Liquidity is the whole balance of that token across all Morpho markets, which for USDC and WETH on Base is deep. **[V]**

Keep Aave as a fallback behind an interface, because Morpho liquidity for a given token is not guaranteed.

**Other**

- Permit2: `0x000000000022D473030F116dDEE9F6B43aC78BA3` (canonical, all chains). Bebop supports Permit2 approvals **only in gasless mode**, so it's irrelevant for v1 execution but useful for pulling user equity gaslessly. **[V]** for the gasless-only restriction.

### What we deploy

| Contract | Purpose | Rough size |
|---|---|---|
| `PositionFactory` | CREATE2 clone deployment, deterministic `positionOf(owner, index)` | ~60 LOC |
| `Position` (implementation) | the whole protocol: open / increase / reduce / close, flash callback, guards | ~250 LOC |
| `IFlashSource` + `MorphoFlashSource` + `AaveFlashSource` | pluggable flash liquidity | ~40 LOC each |
| `MockBebopRouter` (test only) | fixed-rate swap, so unit tests need no network | ~40 LOC |

That's it. Four contracts against the CoW version's eleven.

---

## 5. Security model

This is where I'd spend the most care, because the position contract executes calldata it did not build.

### The calldata problem

Bebop hands us opaque bytes. We must not blindly `call` them. The mitigations, in order of importance:

1. **Target allow-list.** `require(target == BEBOP_ROUTER || target == BEBOP_SETTLEMENT)`. Immutable, set at construction.
2. **Bounded approval.** Approve `approvalTarget` for *exactly* the amount we intend to sell, and reset to zero immediately after the call. Never `approve(max)`.
3. **Verify by token deltas, never by trusting the return.** Snapshot both balances before, snapshot after, and assert:
   - `sellBalanceBefore - sellBalanceAfter <= maxSell`
   - `buyBalanceAfter - buyBalanceBefore >= minOut`
   `minOut` comes from the quote's `buyTokens[x].amount`, passed in by the caller and enforced on-chain.
4. **Assert no residual allowance** after the call.
5. **No delegatecall, ever**, to anything the caller influences.
6. **Reentrancy.** The flash callback is the reentrancy surface. Use a transient-storage (EIP-1153, available on Base) in-flight flag, assert `msg.sender == flashSource` and that we initiated the loan. Morpho's callback has no initiator field, so the in-flight flag is doing real work here.
7. **Bind the flash context.** Morpho passes our `data` through, and it crossed no external boundary in a way an attacker controls, but do the cheap thing anyway: `tstore` a keccak of the context before the call and re-check it in the callback. This is the "trampoline" pattern from CoW's audited FlashLoanRouter and their `CowFlashLoanWrapper`. Costs almost nothing.

### Postconditions

- `minHealthFactor` asserted at the end of every state-changing action, read live from `POOL.getUserAccountData(P)`. This is what stops a bad fill from silently opening a worse position than the user asked for. In their code this was escalated to a "high" finding: the adaptive borrow would quietly push any under-delivery into the user's debt unless a signed HF floor reverted the whole transaction.
- Sweep both token balances to the receiver on a full close, reading balances at execution time.
- `deadline` on every action.

### Signature malleability (relevant once we add gasless)

Reject high-`s` ECDSA signatures (`s <= secp256k1n/2`) and constrain `v` to 27/28. Their `LevManagerModule._recover` does exactly this after a review finding. Or just use OpenZeppelin's `ECDSA`, which handles it.

---

## 6. Designing gasless in now (without building it)

You chose "start plain, design so gasless drops in later." Here is the shape that makes that a drop-in rather than a rewrite.

Every state-changing entrypoint takes a struct plus an optional signature:

```solidity
struct Action {
    address position;
    uint256 nonce;
    uint256 deadline;
    uint8   mode;              // OPEN | INCREASE | REDUCE
    address collateral;
    address debt;
    uint256 equity;            // OPEN only
    uint256 maxSell;           // hard cap on what the swap may consume
    uint256 minOut;            // hard floor on what the swap must return
    uint256 flash;
    uint256 repayAmount;       // REDUCE; MAX = full close
    uint256 minHealthFactor;
    address receiver;
    uint256 triggerHealthFactor; // 0 = no trigger; else require HF < this
}

function execute(Action calldata a, bytes calldata sig, SwapCall calldata swap) external;
```

v1: `sig` is empty and `msg.sender` must be the owner. v2: `sig` is an EIP-712 signature and anyone may relay.

**The one design point that differs materially from the CoW version, and you should get it right from the start:**

Kaze's `CowAuthWrapper` binds the *exact pre/post calldata* into the user's signature, because with CoW the hook calldata is known at signing time. **We cannot do that.** The Bebop quote is fetched at relay time, seconds before execution, by whoever is relaying. Binding calldata into the signature would make gasless impossible.

So the signature must bind **economic bounds, not calldata**:

- `maxSell`, `minOut`, `minHealthFactor`, `deadline`, `receiver`, and the token pair are all signed and enforced on-chain.
- The swap target and calldata are supplied by the relayer, constrained only by the immutable allow-list and the delta assertions above.

That gives the relayer exactly one degree of freedom, price improvement, and no way to extract value beyond `minOut`. It is a weaker binding than Kaze's, and it is the correct one for this venue. Write it down in the contract comments, because it looks like a gap if you don't explain why it isn't one.

EIP-712 domain must bind `chainId` **and** the verifying contract, and the `position` must be inside the signed struct. Kaze's own frontend notes flag a "v2: raw-digest EIP-1271 (legacy positions only)" implementation superseded by "v4: Safe-bound EIP-1271 (replay-safe)". Don't repeat that mistake: an unbound digest signature is replayable against another position or as a plain EOA order.

### Stop-loss

CoW got trustless stops nearly free: `requireHFBelow` as the first pre-interaction meant the order sat in the public orderbook, every solver's simulation reverted while HF was above the threshold, and it became fillable the moment the market pushed HF under. There is no public orderbook here, so:

- store or sign the trigger (`triggerHealthFactor`) as part of an `Action`
- a keeper watches `getUserAccountData(P).healthFactor` for all known positions
- when HF crosses, the keeper fetches a fresh Bebop quote (60s window on Base) and submits `execute(action, sig, swap)`
- `requireHFBelow` still runs on-chain as the first step, so a keeper cannot fire the stop early

This is a real service, not 20 lines. It also means the gasless/relayer path is not optional if we want stops, which is another reason to get the signed-`Action` shape right now.

---

## 7. Aave gotchas that will bite

- `interestRateMode` is always **2** (variable). Stable rate was removed in V3.3; passing 1 reverts.
- `getUserAccountData` returns HF scaled 1e18, and `type(uint256).max` when the position has no debt. Handle that in the guard.
- **Supply and borrow caps.** A large open can revert on a reserve cap even when the position itself is healthy. Read caps from the ProtocolDataProvider and surface the real max in the UI.
- **Isolation mode** assets can only borrow stablecoins and have a debt ceiling. Check `getDebtCeiling` before listing a pair.
- Collateral supplied earlier in the same transaction counts immediately, so supply-then-borrow in one tx is fine.
- `withdraw(asset, type(uint256).max, to)` withdraws the full aToken balance; `repay(asset, type(uint256).max, 2, onBehalfOf)` repays the full debt. Use both for full close; anything else strands dust.
- Aave V3.1 introduced **virtual accounting**: flash-loan-available liquidity is the virtual balance, not the raw token balance of the aToken. Don't compute available liquidity from `token.balanceOf(aToken)`.
- `borrow(..., onBehalfOf)` requires **credit delegation** from `onBehalfOf` to the caller. This is why the Position itself must perform the borrow, and why a router-centric design where an external contract does everything on behalf of the position does not work. `supply(..., onBehalfOf)` has no such restriction.
- The Base Pool is the L2Pool variant with additional calldata-compressed methods. The standard methods work fine; the compressed ones save L1 data gas if you want to optimize later.

## 8. Base specifics

- Chain id **8453**. Roughly 2s blocks, cheap execution gas, but there is an **L1 data availability component** to the fee. Bebop calldata is chunky (a signed order plus wrapped PMM calldata plus signatures), so the data cost is a meaningful share of the total. Measure it before optimizing anything else.
- Sequencer is first-come-first-served with no public mempool, so no sandwich risk. Combined with RFQ's firm price, the swap leg has effectively zero MEV exposure. This is a genuine advantage over an AMM-based leverage product and worth saying out loud in the product pitch.
- WETH is the canonical predeploy `0x4200...0006`.

---

## 9. Testing

### Layer 1: unit tests, no network

Foundry against a **`MockBebopRouter`** that swaps at a fixed oracle rate and a **`MockFlashSource`**. Covers all the arithmetic, the HF guards, the delta assertions, reentrancy, approval hygiene, MAX semantics, and the residual sweep. This is where most of your test count should live, because it's fast and deterministic.

### Layer 2: forked Base with real Aave, mocked swap

```bash
anvil --fork-url $BASE_RPC --fork-block-number <recent> --chain-id 8453
```

Real Aave Pool, real oracle, real caps, real eMode config. Mock swap. This catches every Aave integration bug without needing a live quote.

### Layer 3: forked Base with a real Bebop quote

The tricky one, and worth getting right because it's the only thing that proves the integration.

A live Bebop quote is a maker EIP-712 signature over `(expiry, taker, maker, maker_nonce, tokens, amounts, receiver, ...)`. To execute it on a fork you need all of:

1. `block.timestamp <= expiry`. Anvil's forked chain starts at the fork block's timestamp, which is in the past, so this holds naturally. **Do not `vm.warp` forward** past the expiry.
2. The maker has the balance and the approval to the settlement contract at the fork state. True if you fork at or near the latest block.
3. `maker_nonce` unconsumed. Always true on a fresh fork.
4. `taker_address` equals the caller. Which means the quote must be requested for the **predicted** Position address, and the test must execute from that Position.

Working pattern:

```
scripts/fetch-quote.ts
  1. read predicted position address from a forge script (or recompute CREATE2 in TS)
  2. GET /pmm/base/v3/quote?...&taker_address=<predicted>&gasless=false
  3. write the full response to test/fixtures/quote-open.json

test/OpenPosition.fork.t.sol
  string memory j = vm.readFile("test/fixtures/quote-open.json");
  address to    = vm.parseJsonAddress(j, ".tx.to");
  bytes memory d = vm.parseJsonBytes(j, ".tx.data");
  uint256 minOut = vm.parseJsonUint(j, ".buyTokens.<addr>.amount");
  // fork at the block that was latest when the quote was fetched
```

Order of operations matters: fork at latest, **then** fetch the quote, **then** run the test, all within the 60s window if you care about the expiry check, or simply don't advance time.

Demo mode (no API key) is enough for this layer. Prices will be poor; correctness is what you're testing.

### Layer 4: Base mainnet, tiny

Fresh EOA, 1 to 5 USDC of equity, 2x. Base gas is cheap enough that a full open-increase-reduce-close cycle costs cents. Verify on Basescan and against `UiPoolDataProvider`. Their POC did exactly this on Gnosis barn and documented each proven action with a tx hash; copy that discipline, keep a `PROVEN.md`.

### Note on my sandbox

My container's network allow-list does not include `api.bebop.xyz`, so I cannot fetch a live quote from here to show you the exact response shape. Two options: paste a quote JSON into the chat and I'll work from it, or get `api.bebop.xyz` (and a Base RPC) added to the allowed domains by an org owner.

---

## 10. Open questions

**[ASK] Bebop, before mainnet**
1. Will makers quote for a **contract** `taker_address`? Their `origin_target` screening implies contract takers are a supported and screened category, but we should register our Position implementation and factory addresses explicitly.
2. Is `origin_address` mandatory for our integration profile? Docs say it may be, and that requests without it get rejected.
3. What is the actual rate limit on `/quote` for our key, and is it per chain?
4. Is `expiry_type=short` (3s on Base) usable for a keeper-driven stop-loss, or should we stay on the 60s standard window?

**[?] Verify empirically on a fork**
5. Does `BebopRouter.swap` / `swapSingle` require `msg.sender == order.taker_address`? Strongly implied by "if taker executes order himself then signature can be `'0x'`", but confirm, because our whole design rests on it.
6. Is `exactAmount == 0` ("use whatever `fromToken` balance the router holds") reachable from API-returned calldata, or do we have to patch `partialFillOffset`? This determines how we handle full-close dust.
7. What is `FLASHLOAN_PREMIUM_TOTAL()` on the Base Aave Pool right now? Read it, don't assume 5bps.
8. Actual gas cost of an open on Base including the L1 data component, with real Bebop calldata.

---

## 11. Build order

1. `Position` + `PositionFactory` + `MorphoFlashSource` + `MockBebopRouter`. Full unit test suite. No network.
2. Layer-2 fork tests: real Aave on Base, mocked swap. Open, increase, reduce, partial close, full close. Assert HF invariants (a proportional partial close should leave HF **exactly** unchanged; that's a good property test, and their POC proved it on-chain).
3. Bebop integration: the quote-fetch script, the fixture harness, layer-3 fork test for open. Answers questions 5 and 6.
4. Reduce and close against real Bebop quotes on a fork. Decide the dust strategy.
5. eMode support. Verify eMode 1 gives the LTV you expect for WETH-collateral / USDC-debt, or whether you need a USDC-debt category instead.
6. Mainnet, tiny amounts. Keep a `PROVEN.md` with tx hashes per action.
7. Backend quote proxy (holds the API key), Price API WebSocket stream for the slider, frontend.
8. Signed-`Action` verification and the relayer. Then the HF keeper and stops.

Do not skip step 2 to get to step 3 faster. Roughly every non-trivial bug in the reference POC was an Aave semantics bug (base LTV 0, collateral not auto-enabled, premium rounding, idle positive slippage, dust from interest accrual), not a venue-integration bug.

---

## 12. Reference material

**Bebop**
- index: https://docs.bebop.xyz/llms.txt
- RFQ quickstart: https://docs.bebop.xyz/rfq-api/quickstart.md
- best practices (read this twice): https://docs.bebop.xyz/rfq-api/guides/best-practices.md
- settlement contracts: https://docs.bebop.xyz/core-concepts/settlement-smart-contracts.md
- execution modes: https://docs.bebop.xyz/core-concepts/execution-modes.md
- partial fills: https://docs.bebop.xyz/rfq-api/guides/partial-fills.md
- short expiry: https://docs.bebop.xyz/rfq-api/guides/short-expiry.md
- router migration (has the `swap` signature): https://docs.bebop.xyz/rfq-api/guides/router-migration-guide.md
- auth: https://docs.bebop.xyz/core-concepts/authentication.md
- audits: https://docs.bebop.xyz/audits.md
- JAM contracts (EIP-1271 taker validation, PMM order structs): https://github.com/bebop-dex/bebop-jam-contracts

**Aave**
- address book: https://github.com/bgd-labs/aave-address-book (`src/AaveV3Base.sol`)
- docs: https://aave.com/docs/aave-v3/smart-contracts

**Morpho**
- flash loans: https://docs.morpho.org/learn/concepts/flashloans/

**Safe**
- deployments: https://github.com/safe-global/safe-deployments

**The CoW POCs (design reference, unaudited demo code, do not fork)**
- gen 1: `github.com/koeppelmann/Cowswap-Leverage`, branch `feat/onchain-leverage`. Read `docs/PLAN.md` and the four `docs/codex-*review.md` files; the review findings are the most valuable part.
- gen 2: `github.com/kaze-cow/cowswap-pro`, branch `feat/onchain-leverage`. Read `contracts/src/CowAuthWrapper.sol` for the EIP-712 envelope and the SECURITY GUARANTEE comment on `_wrap`.
