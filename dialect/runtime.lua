-- dialect.runtime: what emitted dialect code calls (design macro-layer.md §4.5–§4.8). Plain
-- Lua. A host replaces entries by giving its chunks a global `__dialect` built with extend().
--
-- Costs are paid where a value is built (a keyed spread, a Struct or Sum value, a contract
-- check), never per name access (design E1).

local R = {}
local unpack = unpack or table.unpack

-- describing values and checkers, for diagnostics ----------------------------------------------

local checkers = setmetatable({}, { __mode = 'k' })     -- checker -> { name, test }
local structs = setmetatable({}, { __mode = 'k' })      -- Struct type -> { name, fields, index, meta }
local sums = setmetatable({}, { __mode = 'k' })         -- Sum type -> { name, alts, index, meta }
local closed = setmetatable({}, { __mode = 'k' })       -- closed structural type -> { declared names }
local instance_of = setmetatable({}, { __mode = 'k' })  -- instance metatable -> its Struct or Sum

local function describe_value(v)
    local mt = type(v) == 'table' and getmetatable(v)
    local owner = mt and instance_of[mt]
    if owner then
        if structs[owner] then return 'a ' .. structs[owner].name end
        return ('%s.%s'):format(sums[owner].name, rawget(v, 'tag'))
    end
    if type(v) == 'string' then
        local s = #v > 20 and (v:sub(1, 17) .. '...') or v
        return ('a string %q'):format(s)
    end
    if type(v) == 'number' or type(v) == 'boolean' then return ('%s %s'):format(type(v), tostring(v)) end
    if v == nil then return 'nil' end
    return 'a ' .. type(v)
end
R.describe_value = describe_value

function R.describe(T)
    if checkers[T] then return checkers[T].name end
    if structs[T] then return structs[T].name end
    if sums[T] then return sums[T].name end
    if closed[T] then return 'a closed structural type' end
    if type(T) == 'function' then return 'a predicate' end
    return describe_value(T)
end

-- the structural markers (design §4.6) ----------------------------------------------------------

R.required = setmetatable({}, { __tostring = function() return 'required' end })
R.optional = setmetatable({}, { __tostring = function() return 'optional' end })

-- the names a closed type declares: its string keys, the markers' included
function R.closed(t)
    if type(t) ~= 'table' then error(('closed: a %s is not a structural type'):format(type(t)), 2) end
    local declared = {}
    for k in pairs(t) do if type(k) == 'string' then declared[k] = true end end
    closed[t] = declared
    return t
end

-- keyed spread: `{ ..a, name = v, ..b }` arrives as a table whose spreads sit under marked keys,
-- numbered in source order; the rest are its fields --------------------------------------------

local marks = {}
function R.spread_mark(n)
    local m = marks[n]
    if not m then
        m = setmetatable({ spread = n }, { __tostring = function() return '..' end })
        marks[n] = m
    end
    return m
end
local function is_mark(k) return type(k) == 'table' and marks[rawget(k, 'spread') or 0] == k end

-- the entries a spread source gives: a table's string keys, in order
function R.entries(source)
    if type(source) ~= 'table' then
        error(('spread-source: a %s has no entries to spread (spread a table)'):format(type(source)), 3)
    end
    local keys = {}
    for k in pairs(source) do if type(k) == 'string' then keys[#keys + 1] = k end end
    table.sort(keys)
    local out = {}
    for i, k in ipairs(keys) do out[i] = { k, source[k] } end
    return out
end

-- the value a keyed spread builds: `required` fields must be supplied, `optional` ones left out
-- are absent; a spread of a closed type admits only the fields it declares, and is closed too
function R.finish(fields, explicit, sources)
    local declared
    for _, src in ipairs(sources) do
        local d = type(src) == 'table' and closed[src]
        if d then
            declared = declared or {}
            for k in pairs(d) do declared[k] = true end
        end
    end
    if declared then
        for k in pairs(explicit) do
            if not declared[k] then error(("closed: '%s' is not a field of this structural type"):format(k), 3) end
        end
    end
    for k, v in pairs(fields) do
        if v == R.required then error(("required: the field '%s' is not supplied"):format(k), 3) end
        if v == R.optional then fields[k] = nil end
    end
    if declared then closed[fields] = declared end
    return fields
end

-- the spreads' entries, then the explicit fields, which override them; a field two spreads
-- give is an error
function R.keyed(t)
    local spreads, fields, explicit = {}, {}, {}
    for k, v in pairs(t) do
        if is_mark(k) then spreads[#spreads + 1] = { k.spread, v }
        elseif type(k) == 'string' then fields[k] = v; explicit[k] = true
        else error('spread-context: a keyed spread admits only `name = value` items and spreads', 2) end
    end
    table.sort(spreads, function(a, b) return a[1] < b[1] end)
    local from, sources = {}, {}
    for _, s in ipairs(spreads) do
        sources[#sources + 1] = s[2]
        for _, kv in ipairs(R.entries(s[2])) do
            local name = kv[1]
            if from[name] then error(("spread-overlap: field '%s' comes from two spreads"):format(name), 2) end
            from[name] = true
            if not explicit[name] then fields[name] = kv[2] end
        end
    end
    return R.finish(fields, explicit, sources)
end

-- `with ... end` where an expression starts: the table itself, unless a host gives it meaning
function R.with(t) return t end

-- `define`: the identity; a structural type is the table it is given
function R.define(t) return t end

-- `f(a, ..t)`: the array part of t, as the call's last arguments
function R.expand(t) return unpack(t, 1, t.n or #t) end

-- checkers and contracts (design §4.7) ------------------------------------------------------------

local function checker(name, test)
    local c = setmetatable({}, { __tostring = function() return name end })
    checkers[c] = { name = name, test = test }
    return c
end
R.checker = checker
R.Number = checker('Number', function(v) return type(v) == 'number' end)
R.String = checker('String', function(v) return type(v) == 'string' end)
R.Boolean = checker('Boolean', function(v) return type(v) == 'boolean' end)
R.Table = checker('Table', function(v) return type(v) == 'table' end)
R.Function = checker('Function', function(v) return type(v) == 'function' end)
R.Any = checker('Any', function() return true end)
R.Unit = checker('Unit', function(v) return v == nil end)
local optionals = setmetatable({}, { __mode = 'k' })
function R.Optional(T)
    local c = optionals[T]
    if not c then
        c = checker('Optional(' .. R.describe(T) .. ')', function(v) return v == nil or (R.check(T, v)) end)
        optionals[T] = c
    end
    return c
end

-- does v pass the checker T? Returns true, or false and why
function R.check(T, v)
    local c = checkers[T]
    if c then return c.test(v) end
    local s = structs[T] or sums[T]
    if s then return type(v) == 'table' and getmetatable(v) == s.meta end
    local declared = closed[T]
    if declared then
        if type(v) ~= 'table' then return false end
        for k in pairs(v) do
            if type(k) ~= 'string' or not declared[k] then return false, ("has the undeclared field '%s'"):format(tostring(k)) end
        end
        for k in pairs(declared) do
            if T[k] == R.required and v[k] == nil then return false, ("lacks the required field '%s'"):format(k) end
        end
        return true
    end
    if type(T) == 'function' then return T(v) and true or false end
    error(('%s is not a checker (a checker is a built-in like Number, a predicate, a closed structural type, '
        .. 'a Struct or a Sum)'):format(describe_value(T)), 3)
end

-- a contract: v passes T, or an error naming what (`parameter 'x' of f`) at the given level
local function contract(T, v, what, level)
    local ok, why = R.check(T, v)
    if not ok then
        error(('contract: %s expects %s, got %s%s'):format(what, R.describe(T), describe_value(v),
            why and (' (it ' .. why .. ')') or ''), level)
    end
    return v
end
-- a parameter's contract blames the caller (level 4: contract, param, the function, its
-- caller); a local's and a result's, the line in the function (level 3)
-- (contract is called as a statement: a tail call would drop a frame and shift the level)
function R.param(T, v, name, fname) contract(T, v, ("parameter '%s' of %s"):format(name, fname), 4); return v end
function R.local_(T, v, name, fname) contract(T, v, ("local '%s' in %s"):format(name, fname), 3); return v end
-- a result's contract: the value returned (one value: the emitter brackets the call, which
-- also keeps it from being a tail call)
function R.result(T, fname, v)
    contract(T, v, 'the result of ' .. fname, 3)
    return v
end

-- Struct and Sum (design §4.8) --------------------------------------------------------------------

-- a nominal record type: closed, typed fields; instances branded by a metatable through
-- which methods (`function P:m() ... end`) are reached
function R.Struct(name, fields, unchecked)
    local S = {}
    local info = { name = name, fields = fields, index = {}, meta = { __index = S, __name = name } }
    for _, f in ipairs(fields) do info.index[f[1]] = f[2] end
    structs[S] = info
    instance_of[info.meta] = S
    setmetatable(S, {
        __tostring = function() return name end,
        __call = function(_, t)
            if t == nil then t = {} end
            if type(t) ~= 'table' then error(('%s takes a table of fields, got %s'):format(name, describe_value(t)), 2) end
            if not unchecked then
                for k in pairs(t) do
                    if not info.index[k] then error(("%s has no field '%s'"):format(name, tostring(k)), 2) end
                end
                for _, f in ipairs(fields) do
                    contract(f[2], t[f[1]], ("the field '%s' of %s"):format(f[1], name), 3)
                end
            end
            return setmetatable(t, info.meta)
        end,
    })
    return S
end

-- a tagged union: a constructor per alternative, payloads checked; a value is matched by calling
-- it with one handler per alternative, and every match checks the handlers name exactly those
function R.Sum(name, alts, unchecked)
    local S = {}
    local info = { name = name, alts = alts, index = {}, meta = {} }
    for _, a in ipairs(alts) do info.index[a[1]] = a[2] end
    sums[S] = info
    instance_of[info.meta] = S
    info.meta.__tostring = function(v) return ('%s.%s'):format(name, rawget(v, 'tag')) end
    info.meta.__call = function(v, handlers)
        if type(handlers) ~= 'table' then
            error(('matching a %s takes a table of handlers, one per alternative'):format(name), 2)
        end
        for k in pairs(handlers) do
            if not info.index[k] then error(("%s has no alternative '%s' to handle"):format(name, tostring(k)), 2) end
        end
        for _, a in ipairs(alts) do
            if handlers[a[1]] == nil then error(("matching a %s: the alternative '%s' has no handler"):format(name, a[1]), 2) end
        end
        local tag = rawget(v, 'tag')
        if info.index[tag] == R.Unit then return handlers[tag]() end
        return handlers[tag](rawget(v, 'value'))
    end
    for _, a in ipairs(alts) do
        local tag, T = a[1], a[2]
        S[tag] = function(payload)
            if not unchecked then contract(T, payload, ('the payload of %s.%s'):format(name, tag), 3) end
            return setmetatable({ tag = tag, value = payload }, info.meta)
        end
    end
    setmetatable(S, { __tostring = function() return name end })
    return S
end

-- opening (design §4.4, E1) ----------------------------------------------------------------------
-- An opened Lua table introduces its string keys as they are when it is opened. open returns
-- that set and the table; emitted code reads a free name `x` as (names.x ? ctx.x : x), over
-- the openings in scope, innermost first, so no access allocates or calls. A host returns its
-- own set and an accessor (a proxy whose metamethods read, write and bind methods).

local EMPTY = {}
function R.open(ctx)
    if ctx == nil then return EMPTY, EMPTY end
    if type(ctx) ~= 'table' then error(('open: a %s introduces no names (open a table)'):format(type(ctx)), 2) end
    local names = {}
    for k in pairs(ctx) do if type(k) == 'string' then names[k] = true end end
    return names, ctx
end

-- a runtime with some entries replaced: a host's chunks see it as their `__dialect`
function R.extend(overrides)
    return setmetatable(overrides, { __index = R })
end

-- the words a dialect program may name without defining them: the emitter binds those a chunk
-- uses to these, unless the chunk's environment defines them
R.words = { 'define', 'closed', 'required', 'optional', 'check', 'Number', 'String', 'Boolean', 'Table',
            'Function', 'Any', 'Unit', 'Optional' }

return R
