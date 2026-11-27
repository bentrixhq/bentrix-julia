# The Julia MCP client's walk against a running Bentrix (bentrix --serve over the CI tape): it finds the
# application and pairs with nothing typed, reads its state through the generated surface, reads a
# resource by its template, and runs the same Gym episode every binding runs - through the agents'
# tools, over the wire - printed as JSON for sdk/python/tests/test_crosslang.py.
#
#   LOCALAPPDATA=<the serve's> julia --project=sdk/julia/Bentrix sdk/julia/mcpwalk.jl
using Bentrix.MCP

check(held, what) = held || (println(stderr, "FAILED: ", what); exit(1))

b = MCP.connect("julia-walk")
bench = b.workspace.get_state()["laboratories"][1]["benches"][1]["uri"]
p = split(replace(bench, "bentrix://" => ""), '/')
book = b.trade.book(p[1], p[2], p[4])
check(book["positions"] isa AbstractVector, "the book did not read: $book")
said = try
    MCP.call(b, "no_such_tool")
    ""
catch e
    sprint(showerror, e)
end
check(occursin("no_such_tool", said), "a refusal did not say its tool: $said")

made = b.strategy.env_make(bench; interval = "H1", window = 8, episode = "window", episode_bars = 12)
env = made["env"]
start = b.strategy.env_reset(env; seed = 5)
check(length(start["obs"]["market"]) == 8, "the observation is not shaped as declared")
rewards = Float64[]
hashes = String[start["info"]["ledger_hash"]]
for a in (1, 1, 2, 0, 2, 2, 1, 0, 1, 2, 0, 1)
    s = b.strategy.env_step(env, a)
    push!(rewards, s["reward"])
    push!(hashes, s["info"]["ledger_hash"])
    (s["terminated"] || s["truncated"]) && break
end
b.strategy.env_close(env)
# A tool's own refusal (isError), not a request the wire refused.
refusal = try
    b.strategy.env_step(env, 0)
    nothing
catch e
    e
end
check(refusal isa ToolError && occursin("No environment", refusal.msg), "a closed environment's step was not refused in its words: $refusal")
check(length(unique(hashes)) > 1, "the episode traded nothing")
# Julia prints a Float64 in the shortest digits that read back as the same double.
println(MCP.JSON.write(Dict("start_ms" => Int64(start["info"]["start_ms"]), "rewards" => rewards, "hashes" => hashes)))
println("PASS")
