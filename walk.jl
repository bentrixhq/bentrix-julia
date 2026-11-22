# The Julia binding's walk on the CI tape: the engine (a second session refused, thirty hours advanced,
# a market order filled, the book read, a refusal in its words) and the Gym episode every binding runs,
# printed as JSON for sdk/python/tests/test_crosslang.py.
#
#   BENTRIX_FFI_DIR=<dir> julia --project=sdk/julia/Bentrix sdk/julia/walk.jl <empty directory>
using Bentrix

check(held, what) = held || (println(stderr, "FAILED: ", what); exit(1))

length(ARGS) == 1 || (println(stderr, "usage: walk.jl <empty directory>"); exit(2))
println("bentrix ", Bentrix.version())
ws, store = make_tape(ARGS[1])
l = Local(ws, store)
said = try
    close(Local(ws, store))
    nothing
catch e
    e isa BentrixError || rethrow()
    e.msg
end
check(said !== nothing, "a second session on the held workspace was not refused")
println("a second session refused: ", said)
bench = call(l, "get_state")["laboratories"][1]["benches"][1]["uri"]
arm(l, bench)
from = Int64(call(l, "replay_step", (bench = bench, unit = "tick", n = 1))["cursor_ms"])
reached = advance(l, bench, from + 30 * 3_600_000)
check(reached >= from + 30 * 3_600_000, "the workbench did not advance")
call(l, "order_market", (bench = bench, symbol = "XAUUSD", side = "buy", volume = 0.01))
advance(l, bench, reached + 60_000)
positions = book(l, bench)["positions"]
check(length(positions) == 1 && positions[1]["side"] == "buy", "the order did not fill")
refusal = try
    call(l, "no_such_tool")
    ""
catch e
    e isa BentrixError || rethrow()
    e.msg
end
check(occursin("no_such_tool", refusal), "a refusal did not say its tool")
check(Bentrix.interval_ms("H1") == 3_600_000, "H1 is not an hour")

env = TradingEnv(l, bench; interval = "H1", window = 8, episode = "window", episode_bars = 12)
obs, info = reset!(env; seed = 5)
check(size(obs.market) == (8, 4), "the observation is not shaped as declared")
rewards = Float64[]
hashes = String[info["ledger_hash"]]
for a in (1, 1, 2, 0, 2, 2, 1, 0, 1, 2, 0, 1)
    _, r, terminated, truncated, step = step!(env, a)
    push!(rewards, r)
    push!(hashes, step["ledger_hash"])
    (terminated || truncated) && break
end
close(env)
check(length(unique(hashes)) > 1, "the episode traded nothing")
# Julia prints a Float64 in the shortest digits that read back as the same double.
println(Bentrix.JSON.write(Dict("start_ms" => Int64(info["start_ms"]), "rewards" => rewards, "hashes" => hashes)))
close(l)
println("PASS")
