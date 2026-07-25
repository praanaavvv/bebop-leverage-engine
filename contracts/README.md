# Leverage contracts (Aave V3 + Bebop RFQ, Base)

See `../implementation.md` for the full plan and flow diagrams.

```
src/Position.sol         # one isolated Aave position per clone: open / increase / reduce / close
src/PositionFactory.sol  # CREATE2 clones, address predictable before deploy (Bebop taker_address)
script/Deploy.s.sol      # Base mainnet deploy with real addresses
test/Position.t.sol      # layer-1 unit suite (mocked Aave / Morpho / Bebop)
test/fixtures/           # real quote JSONs for layer-3 fork tests (written by ../bebop.ts)
```

```bash
forge test                                                    # unit suite
forge script script/Deploy.s.sol --rpc-url base --broadcast   # deploy (BASE_RPC in env)
```

Fetch a fixture for fork tests:

```bash
node ../bebop.ts --api pmm --chain base quote \
  --sell 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913 \
  --buy 0x4200000000000000000000000000000000000006 \
  --amount 300000000 --taker <predicted position> --receiver <predicted position> \
  --origin-address <your EOA> --gasless false > test/fixtures/quote-open.json
```
