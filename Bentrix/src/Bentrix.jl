"""
**BENTRIX for Julia**: the engine in your own process through its C ABI
(`crates/bentrix-ffi/include/bentrix.h`), by `ccall` with no dependency beyond the standard library.
A `Local` answers the agents' tools by name — read, laboratory and paper, never a real account — and
`TradingEnv` is the Gym, a client of BENTRIX's own environment (`env_make`, `env_reset`, `env_step`),
the one every language reaches.

The library is the file `BENTRIX_FFI` names, or `libbentrix` in the folder `BENTRIX_FFI_DIR`
names, or on the system's library path.

```julia
using Bentrix
ws, store = Bentrix.make_tape(mktempdir())
local_ = Bentrix.Local(ws, store)
bench = Bentrix.call(local_, "get_state")["laboratories"][1]["benches"][1]["uri"]
env = Bentrix.TradingEnv(local_, bench; window = 8)
obs, info = Bentrix.reset!(env; seed = 5)
obs, reward, terminated, truncated, info = Bentrix.step!(env, 1)
```
"""
module Bentrix

import Libdl

export Local, TradingEnv, BentrixError, call, read_resource, arm, advance, settle, book, reset!, step!, make_tape

const LIB = Ref{Ptr{Cvoid}}(C_NULL)

function __init__()
    file = get(ENV, "BENTRIX_FFI", "")
    if isempty(file)
        name = "libbentrix"
        dir = get(ENV, "BENTRIX_FFI_DIR", "")
        file = isempty(dir) ? name : something(Libdl.find_library(name, [dir]), joinpath(dir, name))
    end
    LIB[] = Libdl.dlopen(file)
end

fn(name::Symbol) = Libdl.dlsym(LIB[], name)

"A refusal or a failure, in Bentrix's own words."
struct BentrixError <: Exception
    msg::String
end
Base.showerror(io::IO, e::BentrixError) = print(io, e.msg)

failure() = BentrixError(unsafe_string(ccall(fn(:bx_last_error), Cstring, ())))

"A C string this library answered, read and freed; a NULL is the last failure."
function take(p::Ptr{UInt8})
    p == C_NULL && throw(failure())
    s = unsafe_string(p)
    ccall(fn(:bx_free), Cvoid, (Ptr{UInt8},), p)
    return s
end

# ---- a small JSON reader and writer ---------------------------------------------------------------
# Objects are Dict{String,Any}, arrays Vector{Any}, numbers Float64 (parse reads the double the engine
# wrote), strings, booleans and nothing.

module JSON

function parse(s::AbstractString)
    s = String(s)
    i, v = value(s, 1)
    i = space(s, i)
    i > ncodeunits(s) || error("JSON: trailing text")
    return v
end

space(s, i) = (while i <= ncodeunits(s) && codeunit(s, i) in (0x20, 0x0a, 0x0d, 0x09); i += 1; end; i)

function value(s, i)
    i = space(s, i)
    i <= ncodeunits(s) || error("JSON: unexpected end")
    c = codeunit(s, i)
    if c == UInt8('{')
        o = Dict{String,Any}()
        i = space(s, i + 1)
        codeunit(s, i) == UInt8('}') && return i + 1, o
        while true
            i, k = str(s, space(s, i))
            i = space(s, i) + 1  # ':'
            i, o[k] = value(s, i)
            i = space(s, i)
            codeunit(s, i) == UInt8(',') || return i + 1, o
            i += 1
        end
    elseif c == UInt8('[')
        a = Any[]
        i = space(s, i + 1)
        codeunit(s, i) == UInt8(']') && return i + 1, a
        while true
            i, v = value(s, i)
            push!(a, v)
            i = space(s, i)
            codeunit(s, i) == UInt8(',') || return i + 1, a
            i += 1
        end
    elseif c == UInt8('"')
        return str(s, i)
    elseif startswith(SubString(s, i), "true")
        return i + 4, true
    elseif startswith(SubString(s, i), "false")
        return i + 5, false
    elseif startswith(SubString(s, i), "null")
        return i + 4, nothing
    end
    j = i
    while j <= ncodeunits(s) && codeunit(s, j) in codeunits("+-0123456789.eE")
        j += 1
    end
    return j, Base.parse(Float64, SubString(s, i, j - 1))
end

function str(s, i)
    out = IOBuffer()
    i += 1  # the opening quote
    while codeunit(s, i) != UInt8('"')
        c = codeunit(s, i)
        i += 1
        if c != UInt8('\\')
            Base.write(out, c)  # this module's own `write` is the JSON writer
            continue
        end
        e = Char(codeunit(s, i))
        i += 1
        if e == 'u'
            cp = Base.parse(UInt32, SubString(s, i, i + 3); base = 16)
            i += 4
            if 0xD800 <= cp <= 0xDBFF && SubString(s, i, i + 1) == "\\u"
                lo = Base.parse(UInt32, SubString(s, i + 2, i + 5); base = 16)
                i += 6
                cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00)
            end
            print(out, Char(cp))
        else
            print(out, get(Dict('n' => '\n', 't' => '\t', 'r' => '\r', 'b' => '\b', 'f' => '\f'), e, e))
        end
    end
    return i + 1, String(take!(out))
end

write(v) = sprint(io -> write(io, v))
write(io::IO, ::Nothing) = print(io, "null")
write(io::IO, v::Bool) = print(io, v ? "true" : "false")
write(io::IO, v::Integer) = print(io, v)
write(io::IO, v::AbstractFloat) = (isfinite(v) || error("JSON: a number that is not finite"); print(io, Float64(v)))
function write(io::IO, v::AbstractString)
    print(io, '"')
    for c in v
        if c == '"' || c == '\\'
            print(io, '\\', c)
        elseif c == '\n'
            print(io, "\\n")
        elseif c < ' '
            print(io, "\\u", lpad(string(UInt32(c); base = 16), 4, '0'))
        else
            print(io, c)
        end
    end
    print(io, '"')
end
function write(io::IO, v::AbstractDict)
    print(io, '{')
    first = true
    for (k, x) in v
        x === nothing && continue  # an argument not given is absent, never null
        first || print(io, ',')
        first = false
        write(io, string(k))
        print(io, ':')
        write(io, x)
    end
    print(io, '}')
end
function write(io::IO, v::Union{AbstractVector,Tuple})
    print(io, '[')
    for (n, x) in enumerate(v)
        n > 1 && print(io, ',')
        write(io, x)
    end
    print(io, ']')
end
write(io::IO, v::NamedTuple) = write(io, Dict(string(k) => x for (k, x) in pairs(v)))

end  # module JSON

# ---- the engine -------------------------------------------------------------------------------------

"An embedded Bentrix over a workspace and its recordings; `close` persists it and lets it go."
mutable struct Local
    handle::Ptr{Cvoid}
    function Local(workspace::Union{AbstractString,Nothing} = nothing, store::Union{AbstractString,Nothing} = nothing)
        h = ccall(fn(:bx_open), Ptr{Cvoid}, (Cstring, Cstring),
            workspace === nothing ? C_NULL : workspace, store === nothing ? C_NULL : store)
        h == C_NULL && throw(failure())
        l = new(h)
        finalizer(close, l)
        return l
    end
end

function Base.close(l::Local)
    if l.handle != C_NULL
        ccall(fn(:bx_close), Cvoid, (Ptr{Cvoid},), l.handle)
        l.handle = C_NULL
    end
    return nothing
end

session(l::Local) = (l.handle == C_NULL && throw(BentrixError("this session is closed")); l.handle)

"One tool by name, its arguments (a Dict or a NamedTuple; none when omitted); its answer."
function call(l::Local, tool::AbstractString, args = nothing)
    a = args === nothing ? C_NULL : JSON.write(args)
    JSON.parse(take(ccall(fn(:bx_call), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Cstring), session(l), tool, a)))
end

"One resource by its catalogue name, its template's variables."
function read_resource(l::Local, resource::AbstractString, vars = nothing)
    v = vars === nothing ? C_NULL : JSON.write(vars)
    JSON.parse(take(ccall(fn(:bx_read), Ptr{UInt8}, (Ptr{Cvoid}, Cstring, Cstring), session(l), resource, v)))
end

"Arm a workbench's engine (its venue over its recording)."
arm(l::Local, bench::AbstractString) =
    ccall(fn(:bx_arm), Cint, (Ptr{Cvoid}, Cstring, Csize_t), session(l), bench, 20_000) == 0 || throw(failure())

"Advance a workbench to `to_ms` on its clock, as Play would; where it stands."
function advance(l::Local, bench::AbstractString, to_ms::Integer)
    reached = Ref{Int64}(0)
    ccall(fn(:bx_advance), Cint, (Ptr{Cvoid}, Cstring, Int64, Ref{Int64}), session(l), bench, to_ms, reached) == 0 || throw(failure())
    return reached[]
end

"Frames until nothing is waiting."
settle(l::Local) = ccall(fn(:bx_settle), Cint, (Ptr{Cvoid}, Csize_t), session(l), 1000) == 0 || throw(failure())

"A workbench's open positions and pending orders."
function book(l::Local, bench::AbstractString)
    p = split(replace(bench, r"^bentrix://" => ""), '/')
    length(p) >= 4 || throw(BentrixError("not a workbench: $bench"))
    read_resource(l, "trade_book", Dict("home" => p[1], "owner" => p[2], "bench" => p[4]))
end

"The build this library was made from."
version() = unsafe_string(ccall(fn(:bx_version), Cstring, ()))

"An interval's length in ms (M1, H4, D1); 0 for one with no fixed length."
interval_ms(label::AbstractString) = ccall(fn(:bx_interval_ms), Int64, (Cstring,), label)

"The CI tape in `directory`: (workspace, store)."
function make_tape(directory::AbstractString)
    ws, store = Ref{Ptr{UInt8}}(C_NULL), Ref{Ptr{UInt8}}(C_NULL)
    ccall(fn(:bx_make_tape), Cint, (Cstring, Ref{Ptr{UInt8}}, Ref{Ptr{UInt8}}), directory, ws, store) == 0 || throw(failure())
    return take(ws[]), take(store[])
end

# ---- the Gym ----------------------------------------------------------------------------------------

"""
The last closed candles as log ratios to the last close, `market` (window × 4: open, high, low,
close), and the account: side, log equity ratio to the episode's start, open profit over it.
"""
struct Observation
    market::Matrix{Float32}
    account::Vector{Float32}
end

function Observation(o::AbstractDict)
    rows = o["market"]
    market = Matrix{Float32}(undef, length(rows), 4)
    for (i, r) in enumerate(rows), k in 1:4
        market[i, k] = r[k]
    end
    return Observation(market, Float32.(o["account"]))
end

"The Gym (Gymnasium's contract): `reset!(env; seed)` → (observation, info); `step!(env, action)` →
(observation, reward, terminated, truncated, info)."
mutable struct TradingEnv
    local_::Local
    id::String
    symbol::String
end

"An environment over `bench`; keywords are env_make's other arguments (`window = 8`, `episode_bars = 12`)."
function TradingEnv(l::Local, bench::AbstractString; options...)
    args = Dict{String,Any}(string(k) => v for (k, v) in options)
    args["bench"] = bench
    made = call(l, "env_make", args)
    return TradingEnv(l, made["env"], made["symbol"])
end

"A new episode; a seed given starts the draws over."
function reset!(env::TradingEnv; seed::Union{Integer,Nothing} = nothing)
    got = call(env.local_, "env_reset", Dict{String,Any}("env" => env.id, "seed" => seed))
    return Observation(got["obs"]), got["info"]
end

"One action: 0, 1 or 2 (discrete), a number in [-1, 1] (continuous), or a Dict (order)."
function step!(env::TradingEnv, action)
    got = call(env.local_, "env_step", Dict{String,Any}("env" => env.id, "action" => action))
    return Observation(got["obs"]), Float64(got["reward"]), got["terminated"], got["truncated"], got["info"]
end

function Base.close(env::TradingEnv)
    try
        call(env.local_, "env_close", Dict("env" => env.id))
    catch e
        e isa BentrixError || rethrow()
    end
    return nothing
end

end  # module Bentrix
