# bebop.py — Line-by-Line Explanation

A minimal Bebop DEX API client using only the Python standard library.

**The flow in one sentence:** terminal args → `main()` → `quote()`/`order_status()` → `request()` (which loads credentials, builds the URL, hits Bebop) → JSON printed to your screen.

---

## Module setup (lines 19–20)

```python
BASE = "https://api.bebop.xyz"
VERSIONS = {"jam": "v2", "pmm": "v3"}
```

- `BASE` — the root URL for all Bebop API calls.
- `VERSIONS` — maps each API family to its version: JAM (aggregation/solver) uses `v2`, PMM (market-maker RFQ) uses `v3`. Used later to build URLs like `/jam/ethereum/v2/quote`.

---

## `_load_env()` — lines 23–32

Reads your `.env` file and puts its values into environment variables (so your credentials never have to be hardcoded).

| Line | What it does |
|------|--------------|
| 23 | Default path is `.env` sitting **next to bebop.py** (not wherever you ran the command from). `__file__` is the script's own path, `dirname` gets its folder. |
| 25 | Opens the file for reading. |
| 26 | Loops over each line of the file. |
| 27 | Strips whitespace/newlines off the line. |
| 28 | Skips blank lines, comments (`#...`), and anything without an `=`. |
| 29 | `line.split("=", 1)` splits on the **first** `=` only — so a value containing `=` (like a token) stays intact. `k` = variable name, `v` = value. |
| 30 | `os.environ.setdefault(k, v)` — sets the env var **only if it isn't already set**. So an `export BEBOP_SOURCE=...` in your shell wins over the `.env` file. |
| 31–32 | If there's no `.env` file, silently do nothing (you might be using real shell env vars instead). |

---

## `request(api, chain, endpoint, params)` — lines 35–45

The core function. Builds the URL, attaches credentials, makes the HTTP GET, returns parsed JSON. Everything else is a thin wrapper around this.

| Line | What it does |
|------|--------------|
| 36 | Loads the `.env` file first so credentials are available. |
| 37–38 | Pulls `BEBOP_SOURCE` and `BEBOP_SOURCE_AUTH` from the environment (empty string if missing). |
| 39 | Filters out any params whose value is `None` — optional args like `gasless`/`slippage` simply don't appear in the URL if you didn't pass them. |
| 40–41 | Adds the two attribution/auth values as query parameters (`source=` and `source-auth=`) — Bebop requires both. |
| 42 | Assembles the final URL: `https://api.bebop.xyz/{api}/{chain}/{version}/{endpoint}?key=val&...`. `urlencode` safely escapes all values. E.g. `https://api.bebop.xyz/jam/ethereum/v2/quote?sell_tokens=0x...&source=aryan&...` |
| 43 | Creates the request object, and *also* sends `source-auth` as an HTTP **header** (belt-and-suspenders — some endpoints prefer the header), plus `accept: application/json`. |
| 44 | Fires the request with a 30-second timeout; `with` ensures the connection is closed. |
| 45 | Parses the response body as JSON and returns it as a Python dict. |

---

## `quote(...)` — lines 48–56

Gets a swap price quote. A convenience wrapper: it names the arguments and forwards them to `request()` against the `quote` endpoint.

- **Line 48** — parameters: what you're selling, what you're buying, how much (in base units, e.g. `1000000` = 1 USDC), your wallet (`taker`), which API (`jam` default), and two optional flags.
- **Lines 49–56** — calls `request()` with the Bebop parameter names:
  - `sell_tokens` / `buy_tokens` — token contract addresses (plural because Bebop supports comma-separated multi-token swaps).
  - `sell_amounts` — amount in base units (USDC = 6 decimals, WETH = 18 decimals).
  - `taker_address` — required even for a price check.
  - `gasless` — `"true"`/`"false"`: whether you want a gasless (signature-based) order or raw calldata to execute yourself.
  - `slippage` — max slippage tolerance.
  - Any of these that are `None` get stripped out by line 39 of `request()`.

---

## `order_status(chain, quote_id, api="jam")` — lines 59–60

Checks what happened to an order after you submitted it.

- **Line 60** — calls the `order-status` endpoint with a single param, the `quote_id` you got back from a previous `quote()` call. Returns the order's current state (pending/filled/etc.).

---

## `main()` — lines 63–85

The command-line interface. Turns terminal arguments into calls to the two functions above.

| Line | What it does |
|------|--------------|
| 64 | Creates the argument parser (this is what powers `--help`). |
| 65 | Global `--api` flag — choose `jam` or `pmm`, defaults to `jam`. |
| 66 | Global `--chain` flag, defaults to `ethereum`. |
| 67 | Sets up **subcommands** — you must type either `quote` or `status` as the command. |
| 69–75 | Defines the `quote` subcommand and its flags: `--sell`, `--buy`, `--amount`, `--taker` (all required), plus optional `--gasless` and `--slippage`. |
| 77–78 | Defines the `status` subcommand with one required flag, `--quote-id`. |
| 80 | Parses what you typed into an object `a`. |
| 81–84 | Dispatch — if you ran `quote`, call `quote()`; otherwise call `order_status()`. |
| 85 | Pretty-prints the API's JSON response with 2-space indentation. |

---

## Entry point (lines 88–89)

```python
if __name__ == "__main__":
    main()
```

Standard Python idiom: run `main()` only when the file is executed directly (`python bebop.py ...`), not when it's imported as a module — so you can also do `from bebop import quote` in another script without triggering the CLI.

---

## Usage example

```bash
python bebop.py quote \
  --sell 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48 \
  --buy 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2 \
  --amount 1000000 \
  --taker 0xYourWalletAddress
```

Check an order afterwards:

```bash
python bebop.py status --quote-id <quote_id_from_response>
```
