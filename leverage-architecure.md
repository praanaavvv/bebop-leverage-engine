# Leveraged Longs on Aave, Executed Through Bebop

*Architecture walkthrough · Internal*

How the whole thing fits together, end to end, for someone who already knows Aave and can read Solidity.

**Target chain:** Base (8453) · **Debt layer:** Aave V3 · **Execution venue:** Bebop RFQ · **Flash liquidity:** Morpho Blue

**Contents**

1. What we are building
2. Why leverage is hard without a flash loan
3. Why every position needs its own address
4. The cast of characters
5. What Bebop actually gives us
6. Counterfactual addressing
7. The open transaction, line by line
8. Reduce and close, and why order matters
9. Where trust sits
10. The off-chain half
11. Making gasless a drop-in
12. Failure modes

---

## 1. What we are building

A user hands us 1,000 USDC and says "3x long ETH." One transaction later they own an Aave position holding 1 WETH of collateral against 2,000 USDC of debt. Their net equity is still 1,000 USDC, but their ETH exposure is 3,000 USDC. They can later increase leverage, decrease it, partially close, or fully close, each in a single transaction and a single signature.

That is the entire product. Everything in this document exists to make those four verbs work atomically and safely.

**BEFORE**

```
User EOA
├─ 1,000 USDC
└─ (nothing on Aave)
```

**AFTER (3x long, one transaction)**

```
Position 0xPOS (owned by user)
├─ Aave collateral: 1.00 WETH ($3,000)
├─ Aave debt: 2,000 USDC
├─ net equity: $1,000
├─ exposure: 3.0x
└─ health factor: ~1.245
```

> WETH at $3,000, liquidation threshold 0.83. Read the real LT on-chain, it moves with governance.

Note what the user's balance sheet does and does not contain. They hold no LP token, no share, no receipt. They own a contract. That contract is the Aave user. This distinction is the root of most of the design, so hold onto it.

---

## 2. Why leverage is hard without a flash loan

Aave gives you overcollateralised borrowing: supply collateral, borrow less than its value. There is no leverage primitive. To build 3x exposure with plain Aave calls you have to loop.

### The naive loop

Supply 1,000 USDC. Aave lets you borrow up to LTV, say 80%, so borrow 800. Swap that 800 for WETH. Supply the WETH. Now you can borrow 640 more. Swap, supply. Borrow 512. And so on.

| Round | Borrowed | Cumulative supplied | Exposure |
|---|---|---|---|
| 0 (deposit) | — | 1,000 | 1.00x |
| 1 | 800 | 1,800 | 1.80x |
| 2 | 640 | 2,440 | 2.44x |
| 3 | 512 | 2,952 | 2.95x |
| 4 | 410 | 3,362 | 3.36x |
| limit | — | 5,000 | 5.00x = 1/(1−LTV) |

Four rounds of borrow-swap-supply to approximately hit 3x. That is roughly a dozen external calls, four separate swaps each paying spread and gas, and four intermediate states where a price move between transactions can leave the user somewhere they did not ask to be. It is also impossible to express as one user intent.

### The flash loan collapses it

The insight is that Aave's LTV check happens at the moment you call `borrow`, against whatever collateral you hold at that instant. Collateral supplied earlier in the same transaction counts immediately. So you do not have to build up to the target; you can start at the target and pay for it afterwards.

```
flash-borrow 2,000 USDC (unsecured, must return it before the tx ends)
swap 1,000 + 2,000 = 3,000 USDC -> 1.00 WETH (one swap, full size)
supply 1.00 WETH to Aave (collateral now $3,000)
borrow 2,000 USDC from Aave (LTV check sees $3,000 collateral: fine)
repay flash 2,000 USDC
```

One swap instead of four. One transaction. And the only moment where Aave's solvency check runs is the `borrow`, by which point the collateral is already fully in place. The flash loan is doing nothing clever; it is just letting us reorder "get the money" and "post the collateral," which Aave normally forbids.

### The arithmetic, once

| Symbol | Meaning | Example |
|---|---|---|
| E | user equity, in debt-token units | 1,000 USDC |
| X | target leverage | 3.0 |
| L | flash size = E × (X − 1) | 2,000 USDC |
| S | swap size = E + L = E × X | 3,000 USDC |
| p | flash premium | 0 (Morpho Blue is free) |
| B | Aave borrow = L + p | 2,000 USDC |
| C | collateral out = whatever the swap returns, must be ≥ minOut | |

> **Why Morpho Blue and not Aave for the flash:** Morpho Blue charges zero for flash loans, so p = 0 and B = L exactly. Aave charges a premium and rounds it up using its own `PercentageMath`. Get that rounding wrong by one wei and the borrow comes up short and the entire transaction reverts. The CoW POC hit this and had to replicate Aave's half-up rounding exactly. With Morpho the failure mode does not exist. If you ever do fall back to Aave, read `POOL.FLASHLOAN_PREMIUM_TOTAL()` on-chain and ceil.

---

## 3. Why every position needs its own address

Aave's accounting is per-address and holistic. Your aToken balance, your variable debt token balance, your `UserConfiguration` bitmap of which reserves you use as collateral, your eMode category, and critically your single health factor, are all keyed by one address and computed across everything that address holds.

Three consequences fall straight out of that:

- **Positions cannot share an address.** If two users' collateral and debt sat in one contract, they would share one health factor. One user going underwater would get the other user liquidated. Non-starter.
- **One user cannot have two positions in one address either.** A 3x ETH long and a 2x BTC long in the same address net into a single blended HF. Closing one changes the other's liquidation price. You lose the ability to isolate risk, which is most of the point of a leverage product.
- **Therefore:** one address per position. A user with three positions owns three addresses.

### And the position, not a router, must be the actor

You might reasonably ask why we cannot just have one router contract do all the Aave calls with `onBehalfOf` set to the user's position. Half of that works:

```solidity
POOL.supply(asset, amount, onBehalfOf, referral) // anyone can supply FOR anyone
POOL.borrow(asset, amount, mode, referral, onBehalfOf)
// ^ requires onBehalfOf to have granted the caller CREDIT DELEGATION
```

Supplying on someone's behalf is a gift, so Aave permits it freely. Borrowing on someone's behalf creates a debt they owe, so it requires explicit delegation. Setting up delegation is an extra transaction per position and an extra standing permission, and the position would then be a contract that has delegated its credit to a router, which is a worse security story, not a better one.

So the position contract performs its own Aave calls. It is the Aave user, the flash borrower, and (section 5) the swap taker. A factory deploys it; nothing else acts on its behalf.

---

## 4. The cast of characters

Eight moving parts, four of them ours.

| Component | Ours? | What it does, and what it is trusted with |
|---|---|---|
| User EOA | no | Owns the position. Approves the position (or factory) to pull equity. Signs the transaction. In v1 this is the only address allowed to trigger actions. |
| PositionFactory | yes | Immutable. `positionOf(owner, index)` returns a deterministic CREATE2 address; `deploy()` creates the minimal clone if it does not exist. Holds no funds and no privileges over deployed positions. |
| Position clone | yes | The centre of everything. Holds tokens transiently, is the Aave user, is the Bebop taker, is the flash borrower. Roughly 250 lines. Owned by one EOA. Cannot make arbitrary calls: its only external call surface is an immutable allow-list. |
| Morpho Blue (0xBBBB…FFCb) | no | Flash liquidity, zero fee. `flashLoan(token, assets, data)` sends tokens to the caller, then calls back `onMorphoFlashLoan(assets, data)`, then pulls the tokens back via allowance. Trusted only to be honest about pulling exactly what it lent. |
| Aave V3 Pool (0xA238…D1c5) | no | The debt. supply, borrow, repay, withdraw, setUserEMode, and the health factor read. Read the Pool address from the immutable `PoolAddressesProvider`, since the Pool is a proxy. |
| BebopRouter (0xBeb0…bf2A) | no | The swap. Pulls the sell token from the taker via allowance, pays the buy token to the receiver. Trusted for nothing: we verify the outcome by measuring token balances, not by believing it. |
| Bebop API + our backend | backend yes | Off-chain. Produces the firm quote and the ready-to-broadcast calldata. Our backend holds the API key (it must never reach the browser) and attaches the origin fields. It cannot move funds; the worst it can do is hand us calldata that fails our on-chain checks. |
| Keeper | yes, later | Watches health factors, fetches a fresh quote, submits stop-loss reductions. Permissionless in principle. Constrained on-chain to the bounds the user signed. |

### What the Position contract looks like from outside

```solidity
contract Position {
    address public owner;

    // three verbs, all restricted in v1 to `owner`
    function open(OpenParams p, SwapCall s) external;
    function adjust(AdjustParams p, SwapCall s) external; // increase or reduce
    function close(CloseParams p, SwapCall s) external;

    // flash callback, restricted to the flash source + an in-flight flag
    function onMorphoFlashLoan(uint256 assets, bytes calldata data) external;
}

struct SwapCall {
    address target;         // must be in the immutable allow-list
    address approvalTarget; // from the quote response
    uint256 maxSell;        // hard cap on what the swap may consume
    uint256 minOut;         // hard floor on what it must return
    bytes data;              // opaque calldata from the Bebop API
}
```

`SwapCall` is the interesting part and the thing that distinguishes this architecture: we accept calldata we did not build, and we constrain it by bounds rather than by inspection. Section 9 covers why that is sound.

---

## 5. What Bebop actually gives us

Bebop is an RFQ venue, not an AMM. Market-maker desks quote firm prices over HTTP and sign an EIP-712 order. There is no bonding curve, no price impact at execution, no slippage. The quoted output is the guaranteed output until the quote expires.

Two execution modes. The one that matters is self-execution (`gasless=false`), where the API response includes a complete tx object:

```
GET /pmm/base/v3/quote
?sell_tokens=<USDC>&buy_tokens=<WETH>&sell_amounts=3000000000
&taker_address=<POSITION>&receiver_address=<POSITION>
&gasless=false
&origin_address=<USER EOA>&origin_target=<POSITION>
&source=<partner-id> [header: source-auth: <API KEY>]
```

```json
{
  "expiry": 1784900000,
  "approvalTarget": "0xBeb0009A...bf2A",
  "settlementAddress": "0xBeb0009A...bf2A",
  "buyTokens": {
    "0x4200...0006": {
      "amount": "1000000000000000000",
      "minimumAmount": "1000000000000000000"
    }
  },
  "sellTokens": {
    "0x8335...2913": { "amount": "3000000000" }
  },
  "tx": { "to": "0xBeb0009A...bf2A", "data": "0x...", "value": "0x0", "gas": 91793 },
  "onchainOrderType": "SingleOrder",
  "partialFillOffset": 12
}
```

Three properties of this response are load-bearing for us.

**1. No taker signature is required.** In self-execution the taker's authorisation is being `msg.sender`. Bebop's own contract interface says it outright: if the taker executes the order themselves, the taker signature can be `0x`. The maker already signed; the maker's order names a `taker_address`; the settlement contract checks that the caller is that address.

This is the single fact that makes the whole design work. It means a contract can be the taker. Our Position calls `tx.to` with `tx.data` and the swap settles. No EIP-1271, no signature forwarding, no fallback handler.

**2. `minimumAmount == amount`.** Firm price. When we assert `collateralReceived >= minOut` on-chain we are checking an exact promise, not a slippage-tolerant band. Do not apply an AMM-style slippage haircut to a Bebop quote when comparing venues; it is already net.

**3. There is an expiry, and it is short.**

| Mode | Base window | Requirement | Use for |
|---|---|---|---|
| standard | 60 s | tx broadcast and landed within 60 s | user-initiated actions |
| `expiry_type=short` | 3 s | tx included in a block within 3 s | tighter pricing, latency-sensitive only |

60 seconds on a 2-second-block chain is comfortable for a user clicking a button. It is not comfortable for a keeper under congestion, which is why the stop-loss design in section 11 has to fetch its quote at trigger time rather than pre-committing one.

> **Operational constraint, not a technical one.** Bebop's integrator rules are enforced socially by market makers, and violating them degrades your fill rates and eventually gets you deny-listed. Three that shape our code: (a) use the Price API WebSocket stream for the leverage slider and only call `/quote` on the confirm click; (b) never cache a quote and execute it later when it becomes favourable, that is textbook toxic flow; (c) because our taker is a contract, we must send `origin_address` (the real user EOA) and `origin_target`, and Bebop screens the `origin_target` contract before forwarding the request. We need to register our addresses with them before mainnet.

---

## 6. Counterfactual addressing

Here is a sequencing problem that looks like a paradox for about thirty seconds.

The maker signs an order naming `taker_address`. The settlement contract requires the caller to be that address. So to get a quote we must already know the Position's address. But the Position does not exist yet, because this is the user's first position and we are about to deploy it in the same transaction that opens it.

CREATE2 resolves it. The address is a pure function of the deployer, a salt, and the initcode, so it is knowable before deployment.

```
address = keccak256(0xff ++ factory ++ salt ++ keccak256(initcode))[12:]

salt = bytes32(uint256(uint160(owner)) << 96 | uint256(index))
initcode = the EIP-1167 minimal-proxy creation code pointing at IMPL
```

So the flow is: predict the address off-chain, request the quote for it, then deploy and use it in one transaction. OpenZeppelin's `Clones.predictDeterministicAddress` does the prediction, and the same function is available on-chain as a view so the frontend and the contract cannot disagree.

> **Note on the salt, versus the CoW version.** The CoW POC committed the entire trade intent into the CREATE2 salt (equity, leverage, validTo, both tokens, eMode, everything), so that a front-running caller invoking the public `bootstrap()` with different parameters would land on a different Safe and could not grief the user. We do not need that: our factory is called by the user inside the user's own transaction, so there is no public bootstrap function to grief. Salting on `(owner, index)` is sufficient and lets a user reuse an address deterministically.

The failure mode here is benign, which is worth knowing. If our prediction is wrong, the maker's signed order names an address that is not the caller, and the settlement contract reverts. We lose gas, not funds.

---

## 7. The open transaction, line by line

This is the whole product in one call trace. User has 1,000 USDC and wants 3x ETH. WETH is $3,000. Read it like a forge trace.

```
USER ──► PositionFactory.openNew(index=0, params, swapCall)
   │
   │   params    = { collateral: WETH, debt: USDC, equity: 1_000e6,
   │                 flash: 2_000e6, minHF: 1.15e18, eMode: 0 }
   │   swapCall  = { target: BebopRouter, approvalTarget: BebopRouter,
   │                 maxSell: 3_000e6, minOut: 1e18, data: 0x… }
   │
   ├─ 1. P = predict(owner=USER, index=0)          // 0xPOS
   ├─ 2. if P.code.length == 0 → clone + initialize(owner=USER)
   │
   └──► Position(0xPOS).open(params, swapCall)
          │
          ├─ 3. require(msg.sender == factory || msg.sender == owner)
          ├─ 4. USDC.transferFrom(USER, 0xPOS, 1_000e6)
          │      balances: 0xPOS holds 1,000 USDC
          │
          ├─ 5. tstore(IN_FLIGHT, keccak256(context))   // reentrancy + context binding
          │
          └──► Morpho.flashLoan(USDC, 2_000e6, context)
                 │   Morpho sends 2,000 USDC to 0xPOS
                 │   balances: 0xPOS holds 3,000 USDC
                 │
                 └──► Position.onMorphoFlashLoan(2_000e6, context)
                        │
                        ├─ 6. require(msg.sender == MORPHO)
                        ├─ 7. require(tload(IN_FLIGHT) == keccak256(context))
                        │
                        ├─ 8. snapshot: sellBefore = USDC.balanceOf(0xPOS) = 3_000e6
                        │              buyBefore  = WETH.balanceOf(0xPOS) = 0
                        │
                        ├─ 9. require(swapCall.target ∈ {BebopRouter, BebopSettlement})
                        ├─10. USDC.approve(swapCall.approvalTarget, 3_000e6)   // exact, not max
                        │
                        ├─11. swapCall.target.call(swapCall.data)
                        │       ├─ BebopRouter verifies maker sig, expiry, taker == 0xPOS
                        │       ├─ USDC.transferFrom(0xPOS → maker, 3_000e6)
                        │       └─ WETH.transferFrom(maker → 0xPOS, 1e18)
                        │       balances: 0xPOS holds 0 USDC, 1.00 WETH
                        │
                        ├─12. USDC.approve(swapCall.approvalTarget, 0)   // reset
                        ├─13. require(sellBefore - USDC.balanceOf(0xPOS) <= 3_000e6)
                        │      require(WETH.balanceOf(0xPOS) - buyBefore >= 1e18)  // minOut
                        │
                        ├─14. bal = WETH.balanceOf(0xPOS)   // FULL balance, not minOut
                        │      WETH.approve(POOL, bal)
                        │      POOL.supply(WETH, bal, 0xPOS, 0)
                        │      Aave: 0xPOS aWETH = 1.00, collateral value $3,000
                        │
                        ├─15. if (eMode != 0) {
                        │        POOL.setUserEMode(eMode)
                        │        POOL.setUserUseReserveAsCollateral(WETH, true)
                        │      }
                        │
                        ├─16. POOL.borrow(USDC, 2_000e6, 2, 0, 0xPOS)
                        │      Aave LTV check: $3,000 * 0.80 = $2,400 >= $2,000 ✓
                        │      Aave: 0xPOS vUSDC debt = 2,000
                        │      balances: 0xPOS holds 2,000 USDC, 0 WETH
                        │
                        ├─17. USDC.approve(MORPHO, 2_000e6)   // Morpho pulls it back
                        │
                        └─18. (,,,,, hf) = POOL.getUserAccountData(0xPOS)
                               require(hf >= 1.15e18)   // 1.245 ✓
                               │
                               │   Morpho pulls 2,000 USDC back
                               │   balances: 0xPOS holds 0 USDC, 0 WETH
                               │
                               └─19. tstore(IN_FLIGHT, 0); reset residual approvals; emit Opened(...)
```

A few things to notice about that trace.

**Step 14 supplies the full balance, not minOut.** If the maker filled better than quoted, the surplus WETH would otherwise sit in the Position as an idle ERC20 doing nothing for the user. Reading the realised balance and supplying all of it was a "medium" finding in the CoW POC's internal review. Same applies everywhere else we move a variable amount.

**Step 15 orders eMode between supply and borrow, deliberately.** eMode changes the LTV that the borrow is checked against, so it must be set after the collateral is in and before the borrow. The second call looks redundant but is not: assets whose base LTV is zero are not auto-enabled as collateral on supply, and inside their eMode category the borrow will LTV-validate against zero unless you enable them explicitly. The CoW POC hit exactly this with sDAI on Gnosis.

**Step 18 is a postcondition, not a precondition.** We check the health factor after the position exists, so a bad fill reverts the whole transaction rather than quietly opening something worse than the user asked for. Checking it before would tell you nothing. This escalated to a "high" finding in their review, because their adaptive borrow would otherwise push any under-delivery straight into the user's debt.

**The Position ends the transaction holding nothing.** Every token balance is transient. The Position's persistent state is entirely inside Aave (aTokens, debt tokens, config bitmap) plus one storage slot for `owner`. That is a good property: there is no idle balance for anyone to grief, and a stuck-funds bug has nowhere to manifest.

### Balance walk, if the trace is easier to read as a table

| Step | 0xPOS USDC | 0xPOS WETH | Aave coll. | Aave debt | HF |
|---|---|---|---|---|---|
| start | 0 | 0 | — | — | ∞ |
| 4 pull equity | 1,000 | 0 | — | — | ∞ |
| flash in | 3,000 | 0 | — | — | ∞ |
| 11 swap | 0 | 1.00 | — | — | ∞ |
| 14 supply | 0 | 0 | $3,000 | — | ∞ |
| 16 borrow | 2,000 | 0 | $3,000 | $2,000 | 1.245 |
| flash out | 0 | 0 | $3,000 | $2,000 | 1.245 |

---

## 8. Reduce and close, and why order matters

One code path covers three verbs. Full close, partial close, and deleverage differ only in the amounts.

```
flash D of the debt token
├─ POOL.repay(debt, repayAmount, 2, 0xPOS)        // MAX for a full close
├─ POOL.withdraw(collateral, sellAmount + extra, 0xPOS)  // MAX for a full close
├─ swap collateral → debt via Bebop
├─ repay flash (D + p)
├─ sweep residual balances of BOTH tokens to receiver     // read at execution time
└─ require(HF >= minHF)                            // skip on full close, HF is infinite
```

### Debt first. Always.

The ordering inside the flash window is not stylistic. Consider doing it the intuitive way:

**WRONG**

```
withdraw 1.00 WETH
swap WETH → USDC
repay 2,000 USDC
```
what Aave sees: `collateral $0, debt $2,000 → REVERT` (the withdraw itself fails its own LTV check)

**RIGHT**

```
flash 2,000 USDC
repay 2,000 USDC
withdraw 1.00 WETH
swap WETH → 3,000 USDC
repay flash 2,000 USDC
```
what Aave sees: `collateral $3,000, debt $2,000, HF 1.245` → `collateral $3,000, debt $0, HF ∞` → `collateral $0, debt $0, HF ∞` → position closed, 1,000 USDC to user

Repaying inside the flash window means the position is momentarily debt-free, so the withdraw has no LTV constraint to violate. Every intermediate state is valid. This is the same pattern the CoW POC used, and it is the reason the flash loan is needed on the way out as well as the way in.

### Bebop makes this easier than CoW did

On CoW, the reduce leg sold collateral into a solver auction bounded only by a `minBuy`, so you did not know the debt-token proceeds until settlement and had to size the flash conservatively. With a firm RFQ quote you know the output exactly before you send the transaction, so you can size the flash to the wei. Alternatively request an exactOut quote (`buy_amounts`) that buys precisely the debt you need to repay and lets the leftover collateral fall out as residual.

### The dust problem on a full close

aToken balances and variable debt balances both accrue every second. By the time your transaction lands, the quoted `sellAmount` is slightly stale relative to the actual collateral balance, and the debt is slightly larger than when you quoted. Three ways out, in order of how much I'd trust them today:

1. **Quote slightly under, sweep the rest.** Quote for 99.9% of the aToken balance, sell that, sweep the remaining collateral dust to the user. Simple, always works, leaves a few wei of collateral token in the user's wallet.
2. **Patch `partialFillOffset`.** The quote response tells you the byte offset in the calldata where the taker amount sits; overwrite it with the realised balance as a 32-byte zero-padded value. This is Bebop's officially supported flexible-size mechanism.
3. **Router `exactAmount == 0`.** Documented as "use whatever fromToken balance the router holds," which would consume the transferred balance exactly. Needs verification that it is reachable from API-returned calldata.

Use `type(uint256).max` for both the repay and the withdraw on a full close. Aave interprets it as "all of it" and computes the exact amount internally, which removes the debt-side staleness entirely.

---

## 9. Where trust sits

The uncomfortable fact in this architecture is that the Position executes calldata it did not build. Our backend fetched it from Bebop, and neither our backend nor Bebop is inside our trust boundary in a meaningful sense. So the question is: what stops malicious or merely wrong calldata from draining the position?

The answer is that we never inspect the instruction; we verify the observable effect. Six layers, in rough order of how much work each one does:

| Control | Stops |
|---|---|
| Immutable target allow-list — `require(target == ROUTER \|\| target == SETTLEMENT)` | Calldata aimed at an arbitrary contract. Without this, "call whatever bytes the backend sends" is a universal approval-drainer. |
| Bounded, reset approval — approve exactly `maxSell`, then zero | A swap consuming more than intended, and any lingering allowance surviving the transaction. Never `approve(max)`. |
| Token-delta assertions — measure before, measure after | Everything else the call might have done wrong. If the sell balance fell by no more than `maxSell` and the buy balance rose by at least `minOut`, we do not care what happened in between. |
| Health-factor postcondition | A fill that is technically within bounds but leaves the user at a leverage they did not ask for. |
| Flash callback guards — `msg.sender == MORPHO` + transient in-flight hash | Anyone calling `onMorphoFlashLoan` directly, and reentrancy through the callback. Morpho's callback has no initiator field, so the in-flight flag is doing real work here. |
| No delegatecall, ever | The obvious catastrophe. There is no reason for this contract to delegatecall anything. |

> **Worth internalising: this is the same shape as CoW's solution, inverted.** The CoW wrappers solved the equivalent problem by committing to hashes: the user's order appData bound a keccak of the exact pre/post calldata, and the wrapper refused to run anything whose hash did not match. That works because with CoW the hook calldata is known at signing time.
>
> We cannot commit to calldata, because the quote is fetched seconds before execution. So we commit to bounds instead. Weaker binding, correct for this venue. Write the reasoning into the contract comments, because to a reviewer it looks like a missing check rather than a deliberate choice.

### Trust in one line each

| We trust | To do | What if it misbehaves |
|---|---|---|
| Aave Pool | accounting, oracle, liquidation | we are as exposed as every other Aave user |
| Morpho Blue | pull back exactly what it lent | tx reverts; it is immutable and heavily used |
| Bebop contracts | nothing | our delta assertions catch it |
| Bebop API + our backend | nothing, beyond liveness | bad calldata reverts; no funds at risk |
| Our Position code | everything | this is the part that needs the audit |

---

## 10. The off-chain half

Roughly a third of this system is not on-chain, and pretending otherwise is how integrations rot.

```
BROWSER                          OUR BACKEND              BEBOP                BASE
───────                          ───────────              ─────                ────
slider moves
   │
   ├── WS subscribe ─────────────────────────────────► Price API (stream)
   │◄── indicative prices, continuously ───────────────┘
   │   (sizing, max-leverage display, liq price)
   │
user clicks Confirm
   │
   ├── POST /api/quote ───► attach source + key
   │                        attach origin_address (user EOA)
   │                        attach origin_target (position)
   │                        GET /pmm/base/v3/quote ──► firm quote + tx calldata
   │◄── quote (60 s clock starts) ◄─────────────────────┘
   │
   ├── build tx, user signs, broadcast ─────────────────────────────────────► Base
   │                                                                            │
   │◄── receipt ◄───────────────────────────────────────────────────────────────┘
   │
   └── poll position state from POOL.getUserAccountData(0xPOS)
```

### Why a backend is mandatory

The Bebop API key is passed as `source-auth` and Bebop's own docs say to keep it server-side and out of browser network requests. Without a key you get demo mode: widened quotes, heavy rate limits. So the browser cannot talk to Bebop directly. A thin proxy route is the minimum, and it is also the natural place to attach the origin fields consistently.

### Why the Price API stream exists in this diagram

Because `/quote` is rate-limited per key and costs makers real money to answer, and spraying it on every slider movement is the fastest route to being deny-listed. The stream is free to consume and gives you full depth for sizing. Match `expiry_type` between the stream and the firm quote or your pre-trade estimates will be systematically wrong.

### The 60-second clock

Once the quote is issued the transaction has to land. On Base with 2-second blocks that is comfortable, but the UI needs to handle the expiry case honestly: if the user leaves the confirm modal open for two minutes, re-quote rather than submitting a stale one. And never reuse a quote that has been sitting around waiting to become profitable, which Bebop explicitly calls out as toxic flow.

---

## 11. Making gasless a drop-in

v1 is a plain transaction: the user pays gas and `msg.sender` is the authorisation. But we want gasless later, and we want stop-losses, which are the same machinery. The design decision to make now is the shape of the entrypoint.

```solidity
struct Action {
    address position;
    uint256 nonce;               // per-position replay protection
    uint256 deadline;
    uint8   mode;                 // OPEN | INCREASE | REDUCE
    address collateral;
    address debt;
    uint256 equity;               // OPEN only
    uint256 maxSell;              // signed cap on swap input
    uint256 minOut;               // signed floor on swap output
    uint256 flash;
    uint256 repayAmount;          // REDUCE; MAX = full close
    uint256 minHealthFactor;
    address receiver;
    uint256 triggerHealthFactor;  // 0 = none; else require(HF < this)
}

function execute(Action calldata a, bytes calldata sig, SwapCall calldata s) external;
// v1: sig is empty, msg.sender must be owner
// v2: sig is an EIP-712 signature, anyone may relay
```

Same function, same struct, both phases. The only change in v2 is which branch of the authorisation check runs.

> **The one design point I would not get wrong.** The signature must bind economic bounds, not calldata. The relayer fetches the quote at relay time, so the calldata cannot exist when the user signs. What the user signs is `maxSell`, `minOut`, `minHealthFactor`, `deadline`, `receiver`, and the token pair. The relayer supplies the calldata, constrained by the immutable allow-list and the delta assertions.
>
> The result is that the relayer has exactly one degree of freedom, price improvement, and no way to extract value beyond `minOut`. This is where our design necessarily diverges from Kaze's `CowAuthWrapper`, which binds calldata directly because it can.

Two details that are easy to get wrong and were both fixed late in the CoW codebase:

- Bind the EIP-712 domain to `chainId` and the verifying contract, and put `position` inside the signed struct. An unbound digest signature is replayable against another position, or as a plain EOA order elsewhere. Their frontend still carries a comment marking an older module as "raw-digest EIP-1271 (legacy positions only)" superseded by a "Safe-bound, replay-safe" version.
- Reject high-`s` ECDSA signatures (`s <= secp256k1n/2`) and constrain `v` to 27 or 28. Or just use OpenZeppelin's `ECDSA`, which does it for you.

### Stop-losses, and why they are harder here than on CoW

The CoW POC got trustless stops almost free. It put a `requireHFBelow(safe, threshold)` call as the first pre-interaction of the order. The order then sat in CoW's public orderbook; while the health factor was above the threshold every solver's settlement simulation reverted on that first call, so the order was simply unfillable. The moment the market pushed HF under the threshold it became fillable and a solver filled it. No keeper, no oracle contract, no infrastructure.

There is no public orderbook here, and no fleet of solvers repeatedly simulating our orders. So:

1. the user signs an `Action` with `triggerHealthFactor` set;
2. a keeper we run watches `getUserAccountData(P).healthFactor` across known positions;
3. on a crossing the keeper fetches a fresh Bebop quote and submits `execute`;
4. `requireHFBelow` still runs on-chain as the first step, so the keeper cannot fire the stop early even if it wants to.

That last point is what keeps the stop trustworthy: the keeper is a liveness dependency, not a trusted party. But it is a real service with real uptime requirements, and it means the signed-Action plumbing is not optional if we want stops in the product.

---

## 12. Failure modes

The reverts you will actually see, and what each one means.

| Symptom | Cause | Fix |
|---|---|---|
| Bebop settlement reverts on taker check | the caller is not the `taker_address` the maker signed | the CREATE2 prediction and the quote request disagree. Verify with the on-chain view. |
| Bebop reverts on expiry | quote older than 60 s, or you warped time on a fork | re-quote. On forks, fork at the latest block and do not `vm.warp` forward. |
| Bebop reverts, maker nonce or balance | the maker's inventory moved, or the nonce was consumed | re-quote. Do not slice one intent into several quotes; that is what causes this on purpose. |
| Aave reverts on borrow, LTV | target leverage above 1/(1−LTV), or eMode not entered, or collateral not enabled | cap leverage in the UI from live reserve config; check the `setUserUseReserveAsCollateral` call. |
| Aave reverts on borrow, cap | reserve borrow cap or supply cap hit | read caps from the `ProtocolDataProvider` and surface the real maximum size. |
| Aave reverts, interest rate mode | passing 1 (stable) | always 2. Stable rate was removed in V3.3. |
| Flash repay short by 1 wei | premium rounded down | use Morpho (zero fee). If on Aave, read the premium on-chain and ceil. |
| minOut assertion fails | price moved and the maker filled worse, or the calldata was patched | correct behaviour. Surface it as "price moved, retry" in the UI. |
| HF assertion fails | the fill was within bounds but the resulting position is riskier than requested | correct behaviour. This check existing is the whole point. |
| Dust left after a full close | interest accrued between quoting and landing | use `type(uint256).max` for repay and withdraw; sweep both token balances read at execution time. |
| Fill rates quietly degrade over weeks | Bebop integrator rules violated: quote spam, slicing, cached quotes, missing `origin_address` | the most insidious failure here, because nothing reverts. Audit the backend against Bebop's best-practices page. |

---

## The one-paragraph version, for when someone asks

Leverage is a loop that a flash loan collapses into a single step. Aave keys everything by address, so each position gets its own minimal CREATE2 clone, and that clone (not a router) makes the Aave calls, because borrowing on someone's behalf needs credit delegation and supplying does not. The clone's address is predictable before it exists, which matters because Bebop's market maker signs an order naming the taker and the settlement contract requires the caller to be that address. Bebop's self-execution mode hands us ready-made calldata with no taker signature needed, which is the fact that makes a contract taker possible and deletes the entire wrapper, appData, and EIP-1271 apparatus the CoW version needed. We execute that calldata without trusting it, by bounding the approval and asserting on measured token deltas plus a health-factor postcondition. Flash liquidity comes from Morpho Blue because it is free, which removes the premium-rounding bug class entirely. The off-chain half is a quote proxy holding the API key and a price stream feeding the UI, and the gasless and stop-loss features are the same signed-Action machinery, which binds economic bounds rather than calldata because the quote does not exist at signing time.go through 