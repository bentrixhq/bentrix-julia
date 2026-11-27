# Bentrix SDK for Julia

The Julia client of [Bentrix](https://bentrix.net) — charts, a replay laboratory and trading through your own MetaTrader — for a program or an agent.

It finds the Bentrix running on this computer through the agents folder Bentrix writes at every start, pairs with it under the name you give — the name you see in ☰ › Settings › **Agents**, where the pairing's permissions are set — and calls every tool of Bentrix's capability catalogue over MCP. Nothing is typed: no address, no key.

The client is generated from the catalogue of the Bentrix release it came with, and checks when it connects that the running Bentrix serves the same major version.

## What you need

Julia 1.6 or later, and Bentrix open on the same computer.

## Install

Everything is the one package `Bentrix`: the client of a running Bentrix is its module `Bentrix.MCP`, and the engine in your own process is `Bentrix` itself. From a clone of this repository:

```julia
using Pkg
Pkg.develop(path = "bentrix-julia/Bentrix")
```

## Connect

```julia
using Bentrix.MCP

b = MCP.connect("my-agent")
bench = b.workspace.get_state()["laboratories"][1]["benches"][1]["uri"]
p = split(replace(bench, "bentrix://" => ""), '/')
book = b.trade.book(p[1], p[2], p[4])
```

A workbench as one object: its orders, its book, its clock.

```julia
bench = open_bench(b)
answer = buy(bench, 0.1; sl = 2300.0)
println(answer.ok ? answer.outcome : answer.reason)
step(bench; interval = "H1")
```

## The engine in your own process

The package's own module `Bentrix` and its Gym run Bentrix's engine inside your program, with no window. The engine is Bentrix's own library, `libbentrix`, which Bentrix's installer puts in its folder (`%LOCALAPPDATA%\Programs\BENTRIX\libbentrix.dll` on Windows) and the binding finds there; `BENTRIX_FFI` (the file) or `BENTRIX_FFI_DIR` (its folder) names another. It runs for a computer signed in to Bentrix with Plus or Pro; with Free, connect to the running application as above.

## Documentation

Every method, its arguments, the permission it needs and what it answers: **https://bentrix.net/en/docs/sdk/julia/**

## Licence

MIT — see [LICENSE](https://github.com/bentrixhq/bentrix-julia/blob/main/LICENSE). It covers this source code only: Bentrix's engine library (`libbentrix`) and the Bentrix application are Bentrix's own, under their own terms.
