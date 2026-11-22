"""
**BENTRIX's MCP client for Julia**: every capability of a running BENTRIX over its Model Context
Protocol endpoint, generated from the capability catalogue (`generated.jl`) over a hand-written
runtime (`client.jl`), with the standard library only (Downloads, Base64). The engine in your own
process is the `Bentrix` package beside it.

```julia
using BentrixMCP
b = BentrixMCP.connect("my-agent")
bench = b.workspace.get_state()["laboratories"][1]["benches"][1]["uri"]
made = b.strategy.env_make(bench; window = 8)
```
"""
module BentrixMCP

import Base64
import Downloads

export connect, McpError, ToolError, call, call_job, read_resource, read_pages, wait_for, verify_catalogue

# ---- a small JSON reader and writer, the engine package's own ---------------------------------------
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

include("generated.jl")
include("client.jl")
include("forecast.jl")
include("output.jl")

end  # module BentrixMCP
