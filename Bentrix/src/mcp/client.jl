# The hand-written half of Bentrix's Julia MCP client: the connection and everything that does not change
# when a capability is added (generated.jl is the rest, from the catalogue). It speaks MCP revision
# 2026-07-28 over Streamable HTTP with Downloads (libcurl): every request is its own POST carrying the
# protocol version, the client's identity and its (empty) capabilities in _meta - the same wire as the
# Python client's _runtime.py and the JavaScript client's client.js, field for field.

const PROTOCOL_VERSION = "2026-07-28"
const CLIENT_NAME = "bentrix-julia-sdk"
const CLIENT_VERSION = "0.1.0"
"A call that asks the server to wait is given that long and this many seconds more (found 2026-11-02: wait_for beyond the client's own timeout ended in the client before the server could answer)."
const LONG_POLL_MARGIN_S = 15
# **Busy, try again**: the JSON-RPC code Bentrix answers when it refused a request BEFORE doing anything
# with it — one program's 20 calls a second spent, too many connections or streams, a task it could not
# read in time. Nothing ran, so the same request is sent again after the wait the answer names
# (retryAfterMs, a second when none), at most BUSY_RETRIES times and each wait at most BUSY_WAIT_MAX_S;
# then the refusal is thrown. An order is never sent twice by this.
const BUSY = -40001
const BUSY_RETRIES = 10
const BUSY_WAIT_MAX_S = 5.0

"The wait a busy answer's `data` names, in seconds, bounded."
function busy_wait_s(data)
    ms = data isa AbstractDict ? get(data, "retryAfterMs", nothing) : nothing
    ms = ms isa Real && ms > 0 ? ms : 1000
    return min(ms / 1000, BUSY_WAIT_MAX_S)
end

"Every error Bentrix's client raises: a request or a tool refused, an order refused, a forecast declined."
abstract type BentrixException <: Exception end

"A refusal or a failure, in Bentrix's own words."
struct McpError <: BentrixException
    msg::String
end
Base.showerror(io::IO, e::McpError) = print(io, e.msg)

"A tool ran and answered isError: the product's own sentence, verbatim."
struct ToolError <: BentrixException
    tool::String
    msg::String
end
Base.showerror(io::IO, e::ToolError) = print(io, e.tool, ": ", e.msg)

"One Bentrix endpoint: every capability of its catalogue under `b.<domain>`."
mutable struct Client
    url::String
    token::String
    catalogue_version::String
    id::Int
    domains::NamedTuple
    Client(url, token) = (c = new(url, token, CATALOGUE_VERSION, 0, (;)); c.domains = _domains(c); c)
end

function Base.getproperty(c::Client, s::Symbol)
    s in fieldnames(Client) && return getfield(c, s)
    d = getfield(c, :domains)
    haskey(d, s) && return d[s]
    error("Bentrix has no domain $s")
end
Base.propertynames(c::Client) = (fieldnames(Client)..., keys(getfield(c, :domains))...)

# An optional list argument: nothing stays nothing.
_array(x) = x === nothing ? nothing : collect(x)

# Leave out what is nothing, so the server's own default applies.
plain(args) = Dict{String,Any}(string(k) => v for (k, v) in pairs(something(args, Dict{String,Any}())) if v !== nothing)

"A header value, or the standard Base64 sentinel when plain ASCII cannot carry it."
function header_value(v::AbstractString)
    safe = all(c -> ' ' <= c <= '~', v) && v == strip(v) && !(startswith(v, "=?base64?") && endswith(v, "?="))
    safe ? String(v) : "=?base64?" * Base64.base64encode(v) * "?="
end

_scalar(v::Bool) = v ? "true" : "false"
_scalar(v::AbstractFloat) = isinteger(v) && abs(v) < 1e15 ? string(Int64(v)) : string(v)
_scalar(v) = string(v)

function _escape(s::AbstractString)
    io = IOBuffer()
    for b in codeunits(s)
        if (UInt8('A') <= b <= UInt8('Z')) || (UInt8('a') <= b <= UInt8('z')) || (UInt8('0') <= b <= UInt8('9')) || b in codeunits("-_.~")
            Base.write(io, b)
        else
            print(io, '%', uppercase(string(b; base = 16, pad = 2)))
        end
    end
    String(take!(io))
end

# A workbench's address stands for its three parts: given as `bench` - or, the first of the three
# passed by position, as `home` - a `bentrix://<home>/<owner>/bench/<name>` address (or a workbench, by its `uri`)
# fills `home`, `owner` and `bench`. Parts given as before are left as they are.
function _from_address!(values::Dict{String,Any})
    for key in ("bench", "home")
        v = get(values, key, nothing)
        v = v !== nothing && hasproperty(v, :uri) ? getproperty(v, :uri) : v
        if v isa AbstractString && startswith(v, "bentrix://")
            parts = split(v[length("bentrix://")+1:end], '/')
            if length(parts) >= 4 && parts[3] == "bench"
                values["home"], values["owner"], values["bench"] = String(parts[1]), String(parts[2]), String(parts[4])
            end
            return values
        end
    end
    values
end

"The RFC 6570 subset the catalogue uses: `{name}` and `{?a,b}`. A nothing optional is left out."
function expand_template(template::AbstractString, vars)
    values = _from_address!(plain(vars))
    replace(template, r"\{([?&]?)([^}]+)\}" => function (m)
        g = match(r"\{([?&]?)([^}]+)\}", m)
        op, names = g.captures[1], g.captures[2]
        if !isempty(op)
            ps = [n * "=" * _escape(_scalar(values[n])) for n in split(names, ',') if haskey(values, n)]
            return isempty(ps) ? "" : op * join(ps, "&")
        end
        haskey(values, names) || throw(McpError("the URI template $template needs $names"))
        _escape(_scalar(values[names]))
    end)
end

function _post(url, body, headers; timeout = 60)
    out = IOBuffer()
    resp = Downloads.request(url; method = "POST", input = IOBuffer(body), output = out, headers = headers, timeout = timeout, throw = false)
    resp isa Downloads.Response || throw(McpError("$url: $(resp)"))
    ctype = ""
    for (k, v) in resp.headers
        lowercase(k) == "content-type" && (ctype = v)
    end
    return resp.status, ctype, String(take!(out))
end

"The final response on a request-scoped event stream; notifications before it are ignored."
function read_sse(text, id)
    data = String[]
    for raw in [split(text, '\n'); ""]
        line = rstrip(raw, '\r')
        if isempty(line)
            if !isempty(data)
                msg = try
                    JSON.parse(join(data, "\n"))
                catch
                    nothing
                end
                if msg isa AbstractDict && get(msg, "id", nothing) == id && (haskey(msg, "result") || haskey(msg, "error"))
                    return msg
                end
            end
            empty!(data)
        elseif startswith(line, "data:")
            push!(data, lstrip(line[6:end]))
        end
    end
    throw(McpError("the stream ended without a response"))
end

"One request, sent again while Bentrix answers busy (`BUSY`): it ran nothing."
function rpc(c::Client, method, params, name = nothing; timeout = 60)
    for attempt in 0:BUSY_RETRIES
        out = _rpc_once(c, method, params, name; timeout = timeout)
        out isa Tuple || return out
        code, message, data = out
        if code == BUSY && attempt < BUSY_RETRIES
            sleep(busy_wait_s(data))
            continue
        end
        throw(McpError("[$(code isa AbstractFloat && isinteger(code) ? Int64(code) : code)] $message"))
    end
end

"One request: its result, or a refusal as `(code, message, data)`."
function _rpc_once(c::Client, method, params, name; timeout = 60)
    c.id += 1
    id = c.id
    params["_meta"] = Dict{String,Any}(
        "io.modelcontextprotocol/protocolVersion" => PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientInfo" => Dict("name" => CLIENT_NAME, "version" => CLIENT_VERSION),
        "io.modelcontextprotocol/clientCapabilities" => Dict{String,Any}(),
    )
    body = JSON.write(Dict{String,Any}("jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params))
    headers = ["Content-Type" => "application/json", "Accept" => "application/json, text/event-stream",
        "MCP-Protocol-Version" => PROTOCOL_VERSION, "Mcp-Method" => method, "Authorization" => "Bearer " * c.token]
    name === nothing || push!(headers, "Mcp-Name" => header_value(name))
    status, ctype, text = _post(c.url, body, headers; timeout = max(60, timeout))
    msg = if startswith(ctype, "text/event-stream")
        read_sse(text, id)
    else
        try
            JSON.parse(text)
        catch
            throw(McpError("[$status] HTTP $status with no JSON-RPC body"))
        end
    end
    if get(msg, "error", nothing) !== nothing
        err = msg["error"]
        return (get(err, "code", status), get(err, "message", ""), get(err, "data", nothing))
    end
    return get(msg, "result", Dict{String,Any}())
end

"A tool by its wire name; `nothing` arguments are left out."
function call(c::Client, name::AbstractString, args = nothing)
    a = plain(args)
    wait = get(a, "timeout_ms", nothing)
    res = rpc(c, "tools/call", Dict{String,Any}("name" => name, "arguments" => a), name; timeout = wait isa Real ? wait / 1000 + LONG_POLL_MARGIN_S : 60)
    get(res, "resultType", nothing) == "input_required" && throw(McpError("$name needs input this client cannot give; answer it in Bentrix's window"))
    text = join(p["text"] for p in get(res, "content", Any[]) if get(p, "type", nothing) == "text")
    get(res, "isError", false) === true && throw(ToolError(name, isempty(text) ? "the tool failed" : text))
    get(res, "structuredContent", nothing) !== nothing && return res["structuredContent"]
    isempty(text) && return Dict{String,Any}()
    try
        JSON.parse(text)
    catch
        Dict{String,Any}()
    end
end

"A long operation: a NamedTuple with `handle`, `status()`, `cancel()` and `wait(; timeout, poll)`."
function call_job(c::Client, name::AbstractString, args = nothing)
    raw = call(c, name, args)
    handle = raw isa AbstractDict && length(raw) == 1 && get(raw, "job", nothing) isa AbstractString ? raw["job"] : nothing
    status() = handle === nothing ? Dict{String,Any}("status" => "completed") : call(c, "job_get", Dict("job" => handle))
    cancel() = handle === nothing ? nothing : (call(c, "job_cancel", Dict("job" => handle)); nothing)
    function wait(; timeout = nothing, poll = 0.5)
        handle === nothing && return raw
        deadline = timeout === nothing ? Inf : time() + timeout
        while true
            st = status()
            s = get(st, "status", nothing)
            s == "completed" && return something(get(st, "result", nothing), Dict{String,Any}())
            s in ("failed", "cancelled") && throw(McpError("job $handle $s: $(get(st, "message", ""))"))
            time() >= deadline && throw(McpError("job $handle is still $s"))
            sleep(poll)
        end
    end
    return (; handle, status, cancel, wait)
end

function _read_uri(c::Client, uri)
    res = rpc(c, "resources/read", Dict{String,Any}("uri" => uri), uri)
    contents = get(res, "contents", Any[])
    (isempty(contents) || !(get(contents[1], "text", nothing) isa AbstractString)) && throw(McpError("$uri answered no text content"))
    JSON.parse(contents[1]["text"])
end

read_resource(c::Client, template::AbstractString, vars = nothing) = _read_uri(c, expand_template(template, vars))

"Every page of a cursor-paged resource, as a vector: `next` is the URI of the following page."
function read_pages(c::Client, template::AbstractString, vars = nothing)
    pages = Any[]
    uri = expand_template(template, vars)
    while uri isa AbstractString && !isempty(uri)
        page = _read_uri(c, uri)
        push!(pages, page)
        uri = get(page, "next", nothing)
    end
    pages
end

"One wait on a stream: `(items, next)`; give `next` back as `after` to read on."
wait_for(c::Client, template::AbstractString, vars = nothing, after = nothing, timeout_ms = 30000) =
    call(c, "wait_for", Dict{String,Any}("uri" => expand_template(template, vars), "timeout_ms" => timeout_ms, "after" => after))

"Refuse a server on another major line of the catalogue."
function verify_catalogue(c::Client)
    server = string(call(c, "agent_whoami")["catalogue_version"])
    major(v) = (p = split(v, '.'); length(p) == 3 && all(x -> all(isdigit, x) && !isempty(x), p) ? parse(Int, p[1]) : throw(McpError("$v is not a version major.minor.patch")))
    major(server) == major(c.catalogue_version) || throw(McpError("this SDK was generated from catalogue $(c.catalogue_version); the server's is $server"))
    server
end

# ---- finding the running application, and pairing with it ------------------------------------------

"The folder Bentrix writes its endpoint and secret into - user_dir(Data, \"agents\"), as the application has it."
function agents_dir()
    lad = get(ENV, "LOCALAPPDATA", "")
    isempty(lad) || return joinpath(lad, "BENTRIX", "agents")
    home = get(ENV, "HOME", "")
    isempty(home) ? "bentrix-agents" : joinpath(home, ".local", "share", "bentrix", "agents")
end

function _alive(pid::Integer)
    Sys.iswindows() && return true  # a stale file then reads as a refused connection, said by the request
    ccall(:kill, Cint, (Cint, Cint), pid, 0) == 0 || Base.Libc.errno() == Base.Libc.EPERM
end

function read_endpoint(folder)
    file = joinpath(folder, "endpoint.json")
    doc = try
        JSON.parse(read(file, String))
    catch
        throw(McpError("Bentrix is not running: there is no readable endpoint.json in $folder"))
    end
    url = get(doc, "url", nothing)
    pid = get(doc, "pid", nothing)
    (url isa AbstractString && startswith(url, "http://127.0.0.1:") && pid isa Real) || throw(McpError("Bentrix is not running: $file is not an endpoint file"))
    _alive(Int(pid)) || throw(McpError("Bentrix is not running: $file is stale (process $(Int(pid)) has ended)"))
    url
end

function read_secret(folder)
    file = joinpath(folder, "local.secret")
    isfile(file) || throw(McpError("there is no readable local.secret in $folder: Bentrix writes it at every start"))
    secret = strip(read(file, String))
    isempty(secret) && throw(McpError("local.secret is empty"))
    String(secret)
end

"The name this process pairs under: BENTRIX_AGENT_NAME, else the script's name."
function default_name()
    env = strip(get(ENV, "BENTRIX_AGENT_NAME", ""))
    isempty(env) || return String(env)
    isempty(PROGRAM_FILE) ? CLIENT_NAME : "$CLIENT_NAME ($(basename(PROGRAM_FILE)))"
end

"Present the secret to url/pair and answer the token. The secret travels in this one body."
function pair(url::AbstractString, secret::AbstractString, name::AbstractString)
    body = JSON.write(Dict{String,Any}("secret" => secret, "client" => Dict("name" => name)))
    status, _, text = _post(rstrip(url, '/') * "/pair", body, ["Content-Type" => "application/json"])
    doc = try
        JSON.parse(text)
    catch
        Dict{String,Any}()
    end
    if !(200 <= status <= 299)
        err = get(doc, "error", Dict{String,Any}())
        code = get(err, "code", "")
        code == "wrong_secret" && throw(McpError("Bentrix refused the secret in the secret file: it writes a new secret at every start"))
        throw(McpError("Bentrix answered the pairing request with HTTP $status $code: $(get(err, "message", ""))"))
    end
    token = get(doc, "token", nothing)
    (token isa AbstractString && !isempty(token)) || throw(McpError("Bentrix answered the pairing request with no token"))
    token
end

"Find the running application, pair under `name` and connect: a `Client`."
function connect(name = nothing; agents_folder = nothing)
    folder = something(agents_folder, agents_dir())
    url = read_endpoint(folder)
    Client(url, pair(url, read_secret(folder), something(name, default_name())))
end
