# A model's forecast on the chart, built by hand: the forecast_spec document step by step - a time form (an
# interval) or an element form (a chart built by price: renko, kagi, line_break, point_figure, range_bars - no
# interval, its rule in form.elements) - put through forecast_put; and an evaluation's sheet waited on:
# forecast_eval_make's answer is the run at once, or an ask the person answers in Bentrix's window, watched on the
# bentrix://forecasts/eval event. A forecast never names its arrival: Bentrix stamps put_ms.
#
# A caller is anything `call(caller, name, args)` answers for: a Client, or a test's script.

export Forecast, forecast_step!, forecast_spec, forecast_put, forecast_put_many, eval_started, DeclinedByThePerson, EvalFailed, EVAL_EVENT

const EVAL_EVENT = "bentrix://forecasts/eval"

"""
    Forecast(model, symbol, timeframe, anchor_ms; chart_type = "candlestick", elements = nothing, epoch = 0)

The forecast_spec document. `timeframe` is a time form's interval, `nothing` for an element form (a chart built by
price), whose rule is `elements` where it is not the chart's own. `anchor_ms` is the open of the last closed bar (or
the moment of the last closed element) it is made at.
"""
mutable struct Forecast
    model::String
    symbol::String
    timeframe::Union{String,Nothing}
    anchor_ms::Int64
    chart_type::String
    elements::Union{Dict{String,Any},Nothing}
    epoch::Int
    note::Union{String,Nothing}
    look::Union{Dict{String,Any},Nothing}
    steps::Vector{Dict{String,Any}}
end

Forecast(model, symbol, timeframe, anchor_ms; chart_type = "candlestick", elements = nothing, epoch = 0, note = nothing, look = nothing) =
    Forecast(String(model), String(symbol), timeframe === nothing ? nothing : String(timeframe), Int64(anchor_ms), String(chart_type),
             elements === nothing ? nothing : Dict{String,Any}(elements), epoch, note, look, Dict{String,Any}[])

"A forecast of a chart built by price: no interval, `elements` its rule (`nothing` for the chart's own)."
of_elements(model, symbol, chart_type, anchor_ms; elements = nothing, kw...) = Forecast(model, symbol, nothing, anchor_ms; chart_type = chart_type, elements = elements, kw...)

"""
    forecast_step!(f, close; open, high, low, volume, bands, quantiles, samples, expected_ms)

One more bar. `bands` as `(lo, hi)` or `(lo, hi, p)` tuples; `expected_ms`, on every step or none, is what places an
element form on a chart by time.
"""
function forecast_step!(f::Forecast, close; open = nothing, high = nothing, low = nothing, volume = nothing, bands = nothing,
                        quantiles = nothing, samples = nothing, expected_ms = nothing)
    s = Dict{String,Any}("close" => Float64(close))
    for (k, v) in (("open", open), ("high", high), ("low", low), ("volume", volume), ("expected_ms", expected_ms))
        v === nothing || (s[k] = v)
    end
    if bands !== nothing && !isempty(bands)
        s["bands"] = [length(b) > 2 ? Dict{String,Any}("lo" => b[1], "hi" => b[2], "p" => b[3]) : Dict{String,Any}("lo" => b[1], "hi" => b[2]) for b in bands]
    end
    quantiles === nothing || isempty(quantiles) || (s["quantiles"] = Dict{String,Any}(string(k) => Float64(v) for (k, v) in quantiles))
    samples === nothing || isempty(samples) || (s["samples"] = Float64.(collect(samples)))
    push!(f.steps, s)
    return f
end

"The forecast_spec document."
function forecast_spec(f::Forecast)
    form = Dict{String,Any}("chart_type" => f.chart_type)
    f.timeframe === nothing || (form["timeframe"] = f.timeframe)
    f.elements === nothing || (form["elements"] = copy(f.elements))
    d = Dict{String,Any}("schema_version" => 1, "model" => f.model, "symbol" => f.symbol, "form" => form,
                         "anchor" => Dict{String,Any}("time_ms" => f.anchor_ms), "steps" => f.steps, "epoch" => f.epoch)
    f.note === nothing || (d["note"] = f.note)
    f.look === nothing || (d["look"] = f.look)
    return d
end

"forecast_put on the workbench `bench`: its arrival, its state, where it stands on each chart."
forecast_put(c, f::Forecast, bench::AbstractString) = call(c, "forecast_put", Dict{String,Any}("bench" => bench, "forecast" => forecast_spec(f)))

"forecast_put_many: several markets and models at one instant."
forecast_put_many(c, bench::AbstractString, fs; all_or_nothing = false) =
    call(c, "forecast_put_many", Dict{String,Any}("bench" => bench, "forecasts" => [forecast_spec(f) for f in fs], "all_or_nothing" => all_or_nothing))

"The person's No on the evaluation's sheet. Not a failure: nothing was made or fetched."
struct DeclinedByThePerson <: BentrixException
    ask::String
end
Base.showerror(io::IO, e::DeclinedByThePerson) = print(io, "the person declined ", e.ask)

"A laboratory not made over the span, or a run that did not start on it, with Bentrix's why."
struct EvalFailed <: BentrixException
    ask::String
    why::String
end
Base.showerror(io::IO, e::EvalFailed) = print(io, e.why)

"""
    eval_started(c, made; timeout_ms = 60_000, idle_limit = nothing) -> Int

The run to drive, from forecast_eval_make's answer: its eval at once, or - over days the workbench's laboratory does
not hold - the person's answer on the sheet, watched on `EVAL_EVENT`: `started` answers the run's id; `declined`
throws `DeclinedByThePerson`; `failed` throws `EvalFailed`. No tool answers the sheet. `idle_limit` waits in a row
with no move of this ask end the watch with an error (never, when `nothing`).
"""
function eval_started(c, made; timeout_ms = 60_000, idle_limit = nothing)
    get(made, "eval", nothing) === nothing || return Int(made["eval"])
    ask = made["ask"]
    uri = something(get(made, "watch", nothing), EVAL_EVENT)
    cursor = occursin("after=", uri) ? first(split(split(uri, "after=")[2], "&")) : "0"
    uri = first(split(uri, ['{', '?']))
    idle = 0
    while idle_limit === nothing || idle < idle_limit
        page = call(c, "wait_for", Dict{String,Any}("uri" => String(uri), "after" => String(cursor), "timeout_ms" => timeout_ms))
        get(page, "next", nothing) === nothing || (cursor = page["next"])
        moved = false
        for item in get(page, "items", Any[])
            get(item, "ask", nothing) == ask || continue
            moved = true
            state = get(item, "state", nothing)
            state == "started" && return Int(item["eval"])
            state == "declined" && throw(DeclinedByThePerson(ask))
            state == "failed" && throw(EvalFailed(ask, something(get(item, "why", nothing), "the evaluation did not start")))
        end
        idle = moved ? 0 : idle + 1
    end
    error("$ask: no answer on the sheet")
end
