#!/usr/bin/env python3
"""Minimal Bebop API client (stdlib only).

Every request carries both attribution lines:
  - source=<BEBOP_SOURCE> as a query param
  - source-auth=<BEBOP_SOURCE_AUTH> as a query param AND request header

APIs:
  jam  -> Aggregation API   https://api.bebop.xyz/jam/{chain}/v2/...
  pmm  -> RFQ (PMM) API     https://api.bebop.xyz/pmm/{chain}/v3/...
"""

import argparse
import json
import os
import urllib.parse
import urllib.request

BASE = "https://api.bebop.xyz"
VERSIONS = {"jam": "v2", "pmm": "v3"}


def _load_env(path=os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k, v)
    except FileNotFoundError:
        pass


def request(api, chain, endpoint, params):
    _load_env()
    source = os.environ.get("BEBOP_SOURCE", "")
    auth = os.environ.get("BEBOP_SOURCE_AUTH", "")
    query = {k: v for k, v in params.items() if v is not None}
    query["source"] = source
    query["source-auth"] = auth
    url = f"{BASE}/{api}/{chain}/{VERSIONS[api]}/{endpoint}?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, headers={"source-auth": auth, "accept": "application/json"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def quote(chain, sell_token, buy_token, sell_amount, taker, api="jam", gasless=None, slippage=None):
    return request(api, chain, "quote", {
        "sell_tokens": sell_token,
        "buy_tokens": buy_token,
        "sell_amounts": sell_amount,
        "taker_address": taker,
        "gasless": gasless,
        "slippage": slippage,
    })


def order_status(chain, quote_id, api="jam"):
    return request(api, chain, "order-status", {"quote_id": quote_id})


def main():
    p = argparse.ArgumentParser(description="Bebop API client")
    p.add_argument("--api", choices=["jam", "pmm"], default="jam", help="jam=Aggregation, pmm=RFQ")
    p.add_argument("--chain", default="ethereum")
    sub = p.add_subparsers(dest="cmd", required=True)

    q = sub.add_parser("quote")
    q.add_argument("--sell", required=True, help="sell token address")
    q.add_argument("--buy", required=True, help="buy token address")
    q.add_argument("--amount", required=True, help="sell amount in wei/base units")
    q.add_argument("--taker", required=True, help="taker wallet address")
    q.add_argument("--gasless", default=None)
    q.add_argument("--slippage", default=None)

    s = sub.add_parser("status")
    s.add_argument("--quote-id", required=True)

    a = p.parse_args()
    if a.cmd == "quote":
        out = quote(a.chain, a.sell, a.buy, a.amount, a.taker, a.api, a.gasless, a.slippage)
    else:
        out = order_status(a.chain, a.quote_id, a.api)
    print(json.dumps(out, indent=2))


if __name__ == "__main__":
    main()
