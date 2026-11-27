# A forecast's builder and an evaluation's sheet.
#
#   julia sdk/julia/Bentrix/test/mcp_forecast_test.jl
#
# Mutations (2026-11-08), each red: forecast_spec writing the timeframe whatever it is (the element form named an
# interval); declined read as a failure (a decline was EvalFailed).
include(joinpath(@__DIR__, "..", "src", "mcp", "MCP.jl"))
using .MCP

failed = 0
check(c, what) = c || (println("FAIL: ", what); global failed += 1)

mutable struct Sheet
    pages::Vector{Vector{Any}}
    asked::Vector{String}
end
Sheet(pages...) = Sheet(collect(Vector{Any}, pages), String[])

function MCP.call(s::Sheet, name, args)
    (name == "wait_for" && args["uri"] == EVAL_EVENT) || error("not the eval event")
    push!(s.asked, args["after"])
    items = isempty(s.pages) ? Any[] : popfirst!(s.pages)
    Dict{String,Any}("items" => items, "next" => string(parse(Int, args["after"]) + length(items)))
end

moved(ask, state, kv...) = Dict{String,Any}("ask" => ask, "state" => state, kv...)

f = MCP.of_elements("bricks", "EURUSD", "renko", 1_700_000_000_000; elements = Dict("renko_box" => 0.0005))
forecast_step!(f, 1.1005; expected_ms = 1_700_000_600_000)
d = forecast_spec(f)
check(!haskey(d["form"], "timeframe") && d["form"]["chart_type"] == "renko" && d["form"]["elements"]["renko_box"] == 0.0005, "the element form named an interval")
check(d["steps"][1]["expected_ms"] == 1_700_000_600_000, "a step lost its expected_ms")
check(forecast_spec(forecast_step!(Forecast("m", "EURUSD", "H1", 0), 1.0))["form"]["timeframe"] == "H1", "the time form named no interval")

check(eval_started(Sheet(), Dict{String,Any}("eval" => 7.0); idle_limit = 1) == 7, "a run at once")
ask = Dict{String,Any}("ask" => "bentrix://ask/2", "watch" => "bentrix://forecasts/eval?after=0")
s = Sheet(Any[moved("bentrix://ask/1", "declined"), moved("bentrix://ask/2", "asked")], Any[moved("bentrix://ask/2", "made_laboratory")],
          Any[moved("bentrix://ask/2", "started", "eval" => 11.0)])
check(eval_started(s, ask; idle_limit = 3) == 11, "the run the person started")
check(s.asked == ["0", "2", "3"], "the cursor $(s.asked)")
try
    eval_started(Sheet(Any[moved("bentrix://ask/2", "declined")]), ask; idle_limit = 3)
    check(false, "a decline answered a run")
catch e
    check(e isa DeclinedByThePerson, "a decline was EvalFailed")
end
try
    eval_started(Sheet(Any[moved("bentrix://ask/2", "failed", "why" => "the laboratory was not made")]), ask; idle_limit = 3)
    check(false, "a failure answered a run")
catch e
    check(e isa EvalFailed && e.why == "the laboratory was not made", "a failure lost its why")
end
try
    eval_started(Sheet(), ask; idle_limit = 2)
    check(false, "a watch with no answer did not end")
catch e
    check(!(e isa DeclinedByThePerson), "silence was a decline")
end
println(failed == 0 ? "PASS" : "FAILED $failed")
exit(failed == 0 ? 0 : 1)
