# Bentrix SDK for Julia

The Julia client of [Bentrix](https://bentrix.net) — charts, a replay laboratory and trading through your own MetaTrader — for a program or an agent.

It finds the Bentrix running on this computer through the agents folder Bentrix writes at every start, pairs with it under the name you give — the name you see in ☰ › Settings › **Agents**, where the pairing's permissions are set — and calls every tool of Bentrix's capability catalogue over MCP. Nothing is typed: no address, no key.

The client is generated from the catalogue of the Bentrix release it came with, and checks when it connects that the running Bentrix serves the same major version.

## What you need

Julia 1.6 or later, and Bentrix open on the same computer.

## Install

The client is the package `BentrixMCP`. From a clone of this repository:

```julia
using Pkg
Pkg.develop(path = "bentrix-julia/BentrixMCP")
```

## Connect

```julia
using BentrixMCP

b = BentrixMCP.connect("my-agent")
bench = b.workspace.get_state()["laboratories"][1]["benches"][1]["uri"]
p = split(replace(bench, "bentrix://" => ""), '/')
book = b.trade.book(p[1], p[2], p[4])
```

## The engine in your own process

The `Bentrix` package and its Gym (the in-process engine) use Bentrix's engine library, which is not part of this repository.

## Documentation

Every method, its arguments, the permission it needs and what it answers: **https://bentrix.net/en/docs/sdk/julia/**

## Licence

MIT — see [LICENSE](LICENSE). It covers this source code only. Bentrix's engine library that some of these bindings load (`libbentrix`), and the Bentrix application, are Bentrix's own and distributed under their own terms.
