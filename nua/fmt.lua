-- The Nua formatter: Mua's formatter (mua.fmt) with Nua's host. Mua parses and lays out; Nua adds
-- the forms it understands (`export`, `call`), the facts that say which callees are words
-- (nua/application.lua), the exports of the Nua modules a file requires, the `type_style` setting
-- and the pass it controls.
local fmt = require 'mua.fmt'
local front = require 'nua.front'
local application = require 'nua.application'
local loader = require 'nua.loader'
local M = {}

-- The environment of a chunk's word facts: prelude names, and the exports of the Nua modules it
-- requires, found the way compilation finds them and read (never run) with the formatter's own
-- parse. A Lua module on the path takes precedence.
local root = (debug.getinfo(1, 'S').source:match('^@(.*)/nua/[^/]*$')) or '.'
local function module_environment(filename, api)
    local dir = filename and filename:match('^(.*)/[^/]*$') or '.'
    local path = dir .. '/?.lua;' .. dir .. '/?/init.lua;' .. package.path
    local cache, env = {}, { globals = true }
    function env.module(name)
        if cache[name] ~= nil then return cache[name] or nil end
        cache[name] = false -- a cycle resolves to unknown
        if package.preload[name] or package.searchpath(name, path) then return nil end
        for _, file in ipairs(loader.candidates(root, name, path)) do
            local f = io.open(file, 'rb')
            if f then
                local source = f:read('*a'); f:close()
                cache[name] = api.exports(source, file, env) or false
                return cache[name] or nil
            end
        end
    end
    return env
end

-- A native local takes its type from its initializer (spec 8.1), so an
-- annotation can repeat what the syntax already shows. Two cases are decided
-- here, and nothing else, because the formatter does not know what any other
-- initializer evaluates to:
--   * the initializer is exactly an application of the annotated type
--     expression: `local p: Point = Point { ... }`
--   * the initializer is a name whose declared type is the same bare type
--     name: `local i: U32 = n` with `n: U32` a parameter or earlier local
local function unparen(e)
    while type(e) == 'table' and e.k == 'paren' do e = e.e end
    return e
end

-- text views stay explicit: inference does not copy a borrowed view
local KEEP_TYPES = { Str = true, Text = true }

local function drop_inferred(source, info, filename, options, api)
    if options.type_style ~= 'inferred' then return source end
    local fingerprint, parse = api.fingerprint, api.parse
    local native = {}
    for _, stat in ipairs(info.locals) do native[stat] = true end
    local edits, dropped = {}, {}
    local scopes = {}
    local function declare(name, fact) scopes[#scopes].names[name] = fact end
    local function lookup(name)
        for i = #scopes, 1, -1 do
            local fact = scopes[i].names[name]
            if fact ~= nil then return fact end
        end
    end
    local function push() scopes[#scopes + 1] = { names = {} } end
    local function pop() scopes[#scopes] = nil end
    local function typefp(t) return fingerprint(unparen(t)) end

    local walk
    local function walk_children(node)
        local keys = {}
        for k in pairs(node) do
            if k ~= 'line' and k ~= 'end_line' then keys[#keys + 1] = k end
        end
        table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
        for _, k in ipairs(keys) do walk(node[k]) end
    end
    function walk(node)
        if type(node) ~= 'table' then return end
        local k = node.k
        if k == 'local' then
            for _, e in ipairs(node.exprs) do walk(e) end
            local pairwise = #node.exprs == #node.names
            for i, entry in ipairs(node.names) do
                local init = pairwise and node.exprs[i] or nil
                local span = entry.type and info.typespans[entry.type]
                local fact = false
                if entry.type then fact = typefp(entry.type) end
                if native[node] and span and type(init) == 'table' then
                    local same = false
                    if init.k == 'call' and typefp(init.fn) == fact then same = true end
                    local t = unparen(entry.type)
                    if init.k == 'name' and t.k == 'name' and not KEEP_TYPES[t.name]
                        and lookup(init.name) == fact then same = true end
                    if same then
                        edits[#edits + 1] = { info.tokens[span[1]].first, info.tokens[span[2]].last }
                        dropped[#dropped + 1] = entry
                    end
                elseif not entry.type and type(init) == 'table' and init.k == 'call' then
                    fact = typefp(init.fn)
                end
                declare(entry.name, fact)
            end
        elseif k == 'localfunction' then
            declare(node.name, false)
            walk(node.fn)
        elseif k == 'open' then
            walk(node.init)
            declare(node.name, false)
        elseif k == 'numfor' then
            walk(node.lo); walk(node.hi); walk(node.step)
            push()
            declare(node.var, node.type and typefp(node.type) or false)
            walk(node.body)
            pop()
        elseif k == 'genfor' then
            for _, e in ipairs(node.exprs) do walk(e) end
            push()
            for _, n in ipairs(node.names) do declare(n, false) end
            walk(node.body)
            pop()
        elseif k == nil and node.params and node.body then
            push()
            for _, prm in ipairs(node.params) do
                declare(prm.name, (prm.type and not prm.opened) and typefp(prm.type) or false)
            end
            walk(node.body)
            pop()
        elseif k == nil and #node > 0 then
            push()
            for _, child in ipairs(node) do walk(child) end
            pop()
        else
            walk_children(node)
        end
    end
    push()
    walk(info.ast)
    if #edits == 0 then return source end
    table.sort(edits, function(a, b) return a[1] > b[1] end)
    local candidate = source
    for _, edit in ipairs(edits) do
        candidate = candidate:sub(1, edit[1] - 1) .. candidate:sub(edit[2] + 1)
    end
    local types = {}
    for i, entry in ipairs(dropped) do types[i] = entry.type; entry.type = nil end
    local expected = fingerprint(info.ast)
    for i, entry in ipairs(dropped) do entry.type = types[i] end
    local ok, reparsed = pcall(parse, candidate, filename)
    if ok and fingerprint(reparsed.ast) == expected then return candidate end
    return source
end


local host = {
    parse = front.host,
    facts = application.facts,
    environment = module_environment,
    -- an arrow lambda is not accepted in a typed body (docs/design/macro-layer.md, L3), so Nua
    -- keeps its expression lambdas as `do`
    defaults = { type_style = 'inferred', lambda_style = 'do' },
    validate = function(options)
        if options.type_style ~= 'inferred' and options.type_style ~= 'preserve' then
            error('fmt: type_style must be "inferred" or "preserve"', 0)
        end
    end,
    passes = { drop_inferred },
    -- `export name` mentions the name it exports
    mentions = function(node, matches)
        return node.k == 'export' and matches(node.name:match('^[^.]*'))
    end,
}
M.host = host
M.defaults = setmetatable({ type_style = 'inferred', lambda_style = 'do' }, { __index = fmt.defaults })

function M.options(options) return fmt.options(options, host) end
function M.format(source, options, filename) return fmt.format(source, options, filename, host) end

return M
