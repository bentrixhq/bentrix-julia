# The Julia Bench's walk against a running Bentrix (bentrix --serve over a practice tape): the common tasks - a
# refusal read as an answer, a step, a buy with a stop and a target, a modify, a part closed, close_all, the account
# and the deals - through bench.jl, the layer generated from the Bench table. What it saw is printed as JSON for
# sdk/python/tests/test_bench.py, which holds it to the engine's own walk over the same tape.
#
#   LOCALAPPDATA=<the serve's> julia --project=sdk/julia/Bentrix sdk/julia/mcpbench.jl              (a running Bentrix)
#   BENTRIX_PRACTICE=<a practice folder> julia --project=sdk/julia/Bentrix sdk/julia/mcpbench.jl    (the engine)
import Bentrix
using Bentrix.MCP

check(held, what) = held || (println(stderr, "FAILED: ", what); exit(1))

# One walk, either door: the engine in this process over a practice folder, or the running Bentrix.
practice = get(ENV, "BENTRIX_PRACTICE", "")
door = isempty(practice) ? MCP.connect("julia-bench") : Bentrix.Local(joinpath(practice, "ws"), joinpath(practice, "store"))
bench = open_bench(door)
check(markets(bench) == ["XAUUSD"], "the markets: $(markets(bench))")
refused = buy(bench, 0.001)
check(!refused.ok && refused.kind == "volume_out_of_range", "the refusal: $(refused.raw)")
check(refused.reason !== nothing && occursin("volume_min", refused.remedy) && endswith(refused.docs, "go/concept.volume/"), "the refusal's words: $(refused.raw)")
first = step(bench; interval = "H1")
check(first !== nothing && first["time"] > 0 && first["close"] > 0, "the first step: $first")
walk_group = group(bench, "walk")
check(walk_group == 1, "a group's number: $walk_group")
closed = bars(bench; interval = "H1", limit = 5)
check(closed isa AbstractVector && length(closed) == 1 && closed[1][1] == first["time"], "the closed candles: $closed")
q = quote_now(bench)
check(q !== nothing && q["ask"] > q["bid"], "the quote: $q")
sl, tp = round(q["ask"] - 30.0), round(q["ask"] + 30.0)
check(buy(bench, 0.1; sl, tp).ok, "the buy")
step(bench; interval = "H1")
ps = positions(bench)
check(length(ps) == 1, "the positions: $ps")
p = ps[1]
check(p["side"] == "buy" && p["volume"] == 0.1 && p["sl"] == sl && p["tp"] == tp, "the position: $p")
check(modify(bench, p; sl = sl + 5.0).ok, "the modify")
moved = positions(bench)[1]
check(moved["sl"] == sl + 5.0 && moved["tp"] == tp, "only what was named changes: $moved")
check(close(bench, moved; lots = 0.04).ok, "the part closed")
step(bench; interval = "H1")
rest = positions(bench)[1]
check(rest["volume"] == 0.06, "the rest: $rest")
check(close_all(bench).ok, "close_all")
step(bench; interval = "H1")
check(isempty(positions(bench)), "a position stayed")
nothing_open = close_all(bench)
check(nothing_open.ok && get(nothing_open.raw, "closed", nothing) == 0, "close_all with nothing open: $(nothing_open.raw)")
acct = account(bench)
check(acct["equity"] == acct["balance"] && acct["balance"] != 10000.0, "the account: $acct")
ds = deals(bench)
entries = [d["entry"] for d in ds]
check(count(==("in"), entries) == 1 && count(==("out"), entries) == 2, "the deals: $entries")
kept = keep(bench, "kept")
check(isempty(positions(kept)), "the kept workbench reads")
# Past the days' end, advance stands at their last moment, by either door.
walk_end = advance(bench, 4102444800000)
check(walk_end isa Integer && 0 < walk_end < 4102444800000, "the days' end: $walk_end")
if door isa MCP.Client
    # A workbench resource by its address: the same book as by its three parts.
    p = split(bench.uri[length("bentrix://")+1:end], '/')
    by_parts = MCP.JSON.write(door.trade.book(p[1], p[2], p[4]))
    check(MCP.JSON.write(door.trade.book(bench.uri)) == by_parts, "the book by its address")
    check(MCP.JSON.write(door.trade.book(bench)) == by_parts, "the book by the workbench")
end
seen = Dict{String,Any}(
    "refused" => Any[refused.outcome, refused.kind, refused.reason],
    "first" => first,
    "group" => walk_group,
    "bars" => Any[closed[1][1]],
    "deals" => Any[Any[d["entry"], d["side"], d["volume"]] for d in ds],
    "balance" => acct["balance"],
    "end" => walk_end,
)
println(MCP.JSON.write(seen))
println("PASS")
