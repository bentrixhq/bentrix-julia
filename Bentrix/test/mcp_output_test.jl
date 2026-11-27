# Model outputs of every kind and the person's meaning: every kind builds a document; a value outside its
# declared range is refused in words before anything is sent; three examples are three meanings; a put
# never sends an arrival.
#
#   julia sdk/julia/Bentrix/test/mcp_output_test.jl
#
# Mutation (2026-11-11), red: in_range not comparing - a 1.3 for a 0..1 output was sent.
include(joinpath(@__DIR__, "..", "src", "mcp", "MCP.jl"))
using .MCP

failed = 0
check(c, what) = c || (println("FAIL: ", what); global failed += 1)

mutable struct Rec
    names::Vector{String}
    args::Vector{Dict{String,Any}}
end
Rec() = Rec(String[], Dict{String,Any}[])
function MCP.call(r::Rec, name, args)
    push!(r.names, name)
    push!(r.args, args)
    Dict{String,Any}("ok" => true)
end

function refused(f, needle = "")
    try
        f()
        return false
    catch e
        e isa OutputRefused || rethrow()
        return isempty(needle) || occursin(needle, e.msg)
    end
end

built = [
    output_scalar("m1", "o1", "EURUSD", 1, [0.7]; range = (0, 1)),
    output_classes("m1", "o1", "EURUSD", 1, ["up", "down"], [Dict("up" => 0.6, "down" => 0.4)]; exclusive = true),
    output_quantiles("m1", "o1", "EURUSD", 1, [0.1, 0.9], [Dict("0.1" => 1.0, "0.9" => 1.2)]),
    output_rank("m1", "o1", "AAPL", 1, 4871, 0.62),
    output_position("m1", "o1", "EURUSD", 1, -0.5),
    output_weights("m1", "o1", "EURUSD", 1, Dict("EURUSD" => 0.6, "GBPUSD" => 0.4)),
    output_event("m1", "o1", "EURUSD", 1, 0.8; within_steps = 3),
    output_levels("m1", "o1", "EURUSD", 1, Dict("stop" => 1.09, "target" => 1.12)),
    output_action("m1", "o1", "EURUSD", 1, "buy"; size = 0.5),
    output_text("m1", "o1", "EURUSD", 1, "the trend held"),
    output_series("m1", "o1", "EURUSD", 1, ["a"], [Dict("a" => 1.0)]),
]
kinds = Set(["path"])
for o in built
    output_check(o)
    check(output_spec(o)["kind"] == o.kind, "$(o.kind) wrote another kind")
    push!(kinds, o.kind)
end
check(length(OUTPUT_KINDS) == 12 && length(kinds) == 12, "the builders cover $(length(kinds)) of $(length(OUTPUT_KINDS)) kinds")

r = Rec()
check(refused(() -> output_put(r, output_scalar("m1", "o1", "EURUSD", 1, [1.3]; range = (0, 1)), "bench"), "0 to 1; 1.3 is outside it"), "a 1.3 for a 0..1 output was sent")
check(isempty(r.names), "something was sent")
check(refused(() -> output_check(output_rank("m1", "o1", "AAPL", 1, 10, 1.5))), "a rank of 1.5 was taken")

m = Rec()
for mm in (Meaning(high_means = "buy", low_means = "sell", act_above = 0.6, act_below = 0.4), Meaning(high_means = "buy", low_means = "nothing", act_above = 0.6),
           Meaning(high_means = "sell", low_means = "nothing", act_above = 0.6))
    output_meaning_set(m, "bench", "m1", "o1", mm; range = (0, 1))
end
check(m.names[3] == "output_meaning_set" && m.args[3]["meaning"]["high_means"] == "sell", "the meaning was not sent as set")
check(refused(() -> output_meaning_set(m, "bench", "m1", "o1", Meaning(high_means = "profit"); range = (0, 1))), "profit was taken as a meaning's word")
check(refused(() -> output_meaning_set(m, "bench", "m1", "o1", Meaning(high_means = "buy", act_above = 1.5); range = (0, 1))), "a threshold outside the range was taken")

p = Rec()
output_put(p, output_horizon!(output_scalar("m1", "dir", "EURUSD", 1, [0.7]; range = (0, 1)); steps = 4), "bench")
output_put_many(p, "bench", [output_event("m1", "e", "EURUSD", 1, 0.9)]; all_or_nothing = true)
spec = p.args[1]["output"]
check(p.names[1] == "output_put" && spec["horizon"]["steps"] == 4, "output_put sent the wrong horizon")
check(!haskey(spec, "put_ms"), "an arrival was sent")
check(p.names[2] == "output_put_many" && p.args[2]["all_or_nothing"] === true, "output_put_many sent the wrong flag")

println(failed == 0 ? "output_test: all passed" : "output_test: $failed failed")
exit(failed == 0 ? 0 : 1)
