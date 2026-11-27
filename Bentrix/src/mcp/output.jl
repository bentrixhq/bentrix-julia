# A model's output of any kind on the chart: the output_spec document built by hand for the eleven kinds beside
# a path (a path is forecast.jl's) - scalar, classes, quantiles, rank, position, weights, event, levels, action, text,
# series - checked as Bentrix checks it, a value outside its declared range refused in words and never clamped, and
# put through output_put; and the person's meaning (output_meaning) set through output_meaning_set, never in a model's
# file. An output never names its arrival: Bentrix stamps put_ms.
#
# A caller is anything `call(caller, name, args)` answers for: a Client, or a test's script.

export Output, OutputRefused, Meaning, OUTPUT_KINDS, MEANING_WORDS, output_scalar, output_classes, output_quantiles, output_rank,
       output_position, output_weights, output_event, output_levels, output_action, output_text, output_series,
       output_horizon!, output_check, output_spec, output_put, output_put_many, meaning_check, meaning_doc, output_meaning_set

"The twelve kinds, as the document writes them."
const OUTPUT_KINDS = ["path", "scalar", "classes", "quantiles", "rank", "position", "weights", "event", "levels", "action", "text", "series"]
"The meaning's closed words."
const MEANING_WORDS = ["buy", "sell", "nothing", "up", "down", "flat", "in", "out", "close"]
"An action's intents."
const OUTPUT_INTENTS = ["buy", "sell", "close_buys", "close_sells", "nothing"]

"A refusal in Bentrix's words, raised before anything is sent."
struct OutputRefused <: BentrixException
    msg::String
end
Base.showerror(io::IO, e::OutputRefused) = print(io, e.msg)

"""
    Meaning(; reads = "direction", high_means, low_means, act_above, act_below, hysteresis = 0, labels)

The output_meaning document: what a value means to the person.
"""
Base.@kwdef mutable struct Meaning
    reads::String = "direction"
    high_means::Union{String,Nothing} = nothing
    low_means::Union{String,Nothing} = nothing
    act_above::Union{Float64,Nothing} = nothing
    act_below::Union{Float64,Nothing} = nothing
    hysteresis::Float64 = 0.0
    labels::Dict{String,String} = Dict{String,String}()
end

"One output's document: its kind, its values as the document writes them, and the kind's own fields."
mutable struct Output
    kind::String
    model::String
    name::String
    symbol::String
    anchor_ms::Int64
    values::Vector{Dict{String,Any}}
    fields::Dict{String,Any}
    epoch::Int
    suggested_meaning::Union{Meaning,Nothing}
end

Output(kind, model, name, symbol, anchor_ms, values, fields = Dict{String,Any}()) =
    Output(kind, String(model), String(name), String(symbol), Int64(anchor_ms), values, fields, 0, nothing)

named(m) = Dict{String,Any}(string(k) => Float64(v) for (k, v) in m)

"A number per step; `range` its declared bounds, `(lo, hi)`, or `nothing`."
output_scalar(model, name, symbol, anchor_ms, values; range = nothing) =
    Output("scalar", model, name, symbol, anchor_ms, [Dict{String,Any}("value" => Float64(v)) for v in values],
           range === nothing ? Dict{String,Any}() : Dict{String,Any}("range" => [Float64(range[1]), Float64(range[2])]))
"Probabilities over named classes, one map per step."
output_classes(model, name, symbol, anchor_ms, names, steps; exclusive) =
    Output("classes", model, name, symbol, anchor_ms, [Dict{String,Any}("p" => named(p)) for p in steps],
           Dict{String,Any}("names" => collect(String, names), "exclusive" => exclusive))
"Quantiles at `levels`, one map per step keyed as the document writes a level (\"0.1\")."
output_quantiles(model, name, symbol, anchor_ms, levels, steps) =
    Output("quantiles", model, name, symbol, anchor_ms, [Dict{String,Any}("q" => named(q)) for q in steps], Dict{String,Any}("levels" => Float64.(levels)))
"A rank in 0..1 among `universe` markets."
output_rank(model, name, symbol, anchor_ms, universe, value) =
    Output("rank", model, name, symbol, anchor_ms, [Dict{String,Any}("value" => Float64(value))], Dict{String,Any}("universe" => universe))
"A target position in `units` (fraction, lots, ...)."
output_position(model, name, symbol, anchor_ms, target; units = "fraction") =
    Output("position", model, name, symbol, anchor_ms, [Dict{String,Any}("target" => Float64(target))], Dict{String,Any}("units" => units))
"Weights across markets."
output_weights(model, name, symbol, anchor_ms, w; long_only = true) =
    Output("weights", model, name, symbol, anchor_ms, [Dict{String,Any}("w" => named(w))], Dict{String,Any}("long_only" => long_only, "markets" => sort!(collect(String, keys(w)))))
"An event's score in 0..1, expected within `within_steps` (nothing for none)."
function output_event(model, name, symbol, anchor_ms, score; within_steps = nothing)
    v = Dict{String,Any}("score" => Float64(score))
    within_steps === nothing || (v["within_steps"] = within_steps)
    Output("event", model, name, symbol, anchor_ms, [v])
end
"Named price levels (stop, target, ...)."
output_levels(model, name, symbol, anchor_ms, levels) = Output("levels", model, name, symbol, anchor_ms, [Dict{String,Any}("levels" => named(levels))])
"An intent, with a size where it has one."
function output_action(model, name, symbol, anchor_ms, intent; size = nothing)
    v = Dict{String,Any}("intent" => intent)
    size === nothing || (v["size"] = Float64(size))
    Output("action", model, name, symbol, anchor_ms, [v])
end
"A sentence."
output_text(model, name, symbol, anchor_ms, text) = Output("text", model, name, symbol, anchor_ms, [Dict{String,Any}("text" => text)])
"Named lines, one map per step."
output_series(model, name, symbol, anchor_ms, names, steps) =
    Output("series", model, name, symbol, anchor_ms, [Dict{String,Any}("lines" => named(l)) for l in steps], Dict{String,Any}("names" => collect(String, names)))

"The horizon: `steps = n`, `business_days = n`, or `until = \"levels\" | \"next_output\"`."
function output_horizon!(o::Output; steps = nothing, business_days = nothing, until = nothing)
    o.fields["horizon"] = steps !== nothing ? Dict{String,Any}("steps" => steps) :
                          business_days !== nothing ? Dict{String,Any}("business_days" => business_days) : Dict{String,Any}("until" => until)
    return o
end

fmt(v) = isinteger(v) && abs(v) < 1e15 ? string(Int64(v)) : string(v)

function in_range(field, v, range)
    (v isa Real && isfinite(v)) || throw(OutputRefused("$field $v is not a number"))
    range === nothing || (range[1] <= v <= range[2]) || throw(OutputRefused("$field the output answers $(fmt(range[1])) to $(fmt(range[2])); $(fmt(v)) is outside it"))
end

label_ok(s) = occursin(r"^[a-z0-9_]{1,32}$", s)

"Refuses what Bentrix would refuse, in its words."
function output_check(o::Output)
    (label_ok(o.model) && label_ok(o.name)) || throw(OutputRefused("the model and the output are [a-z0-9_]{1,32}"))
    o.kind in OUTPUT_KINDS || throw(OutputRefused("$(o.kind) is not one of the twelve kinds"))
    isempty(o.values) && throw(OutputRefused("values holds no value"))
    r = get(o.fields, "range", nothing)
    names = get(o.fields, "names", String[])
    softmax = get(o.fields, "softmax", false) === true
    for (i, v) in enumerate(o.values)
        f = "values[$(i - 1)]"
        if o.kind == "scalar"
            in_range("$f.value", v["value"], r)
        elseif o.kind == "rank"
            in_range("$f.value", v["value"], r === nothing ? (0, 1) : r)
        elseif o.kind == "event"
            in_range("$f.score", v["score"], (0, 1))
        elseif o.kind == "position"
            in_range("$f.target", v["target"], r)
        elseif o.kind == "classes"
            isempty(names) && throw(OutputRefused("names a classes output names its classes"))
            for (k, p) in v["p"]
                k in names || throw(OutputRefused("$f.p $k is not one of the classes"))
                softmax || in_range("$f.p.$k", p, (0, 1))
            end
        elseif o.kind == "series"
            isempty(names) && throw(OutputRefused("names a series output names its lines"))
        elseif o.kind == "action"
            v["intent"] in OUTPUT_INTENTS || throw(OutputRefused("$f.intent $(v["intent"]) is not one of $(join(OUTPUT_INTENTS, ", "))"))
        elseif o.kind == "text"
            length(v["text"]) > 2000 && throw(OutputRefused("$f.text is longer than 2000 characters"))
        end
    end
    o.suggested_meaning === nothing || meaning_check(o.suggested_meaning, r)
    return o
end

"The output_spec document; never an arrival."
function output_spec(o::Output)
    d = Dict{String,Any}("schema_version" => 1, "model" => o.model, "output" => o.name, "symbol" => o.symbol, "kind" => o.kind,
                         "anchor" => Dict{String,Any}("time_ms" => o.anchor_ms), "values" => o.values)
    merge!(d, o.fields)
    o.epoch > 0 && (d["epoch"] = o.epoch)
    o.suggested_meaning === nothing || (d["suggested_meaning"] = meaning_doc(o.suggested_meaning))
    return d
end

"output_put on the workbench `bench`, after output_check."
output_put(c, o::Output, bench::AbstractString) = call(c, "output_put", Dict{String,Any}("bench" => bench, "output" => output_spec(output_check(o))))

"output_put_many: several outputs at one instant."
output_put_many(c, bench::AbstractString, outputs; all_or_nothing = false) =
    call(c, "output_put_many", Dict{String,Any}("bench" => bench, "outputs" => [output_spec(output_check(o)) for o in outputs], "all_or_nothing" => all_or_nothing))

"Refuses a word that is not the product's, a threshold outside `range`, a label empty or over 24."
function meaning_check(m::Meaning, range = nothing)
    for w in (m.high_means, m.low_means)
        w === nothing || w in MEANING_WORDS || throw(OutputRefused("\"$w\" is not one of the meaning's words"))
    end
    if range !== nothing
        for t in (m.act_above, m.act_below)
            t === nothing || (range[1] <= t <= range[2]) || throw(OutputRefused("the output answers $(fmt(range[1])) to $(fmt(range[2])); $(fmt(t)) is outside it"))
        end
    end
    for (k, l) in m.labels
        (k in MEANING_WORDS && !isempty(l) && length(l) <= 24) || throw(OutputRefused("the label \"$l\" for $k is not a meaning word's, or is empty or longer than 24"))
    end
    return m
end

"The output_meaning document."
function meaning_doc(m::Meaning)
    d = Dict{String,Any}("reads" => m.reads, "hysteresis" => m.hysteresis)
    m.high_means === nothing || (d["high_means"] = m.high_means)
    m.low_means === nothing || (d["low_means"] = m.low_means)
    m.act_above === nothing || (d["act_above"] = m.act_above)
    m.act_below === nothing || (d["act_below"] = m.act_below)
    isempty(m.labels) || (d["labels"] = copy(m.labels))
    return d
end

"output_meaning_set: the person's meaning of `model`'s `output` on the workbench `bench`."
output_meaning_set(c, bench::AbstractString, model, output, m::Meaning; range = nothing) =
    call(c, "output_meaning_set", Dict{String,Any}("bench" => bench, "model" => model, "output" => output, "meaning" => meaning_doc(meaning_check(m, range))))
