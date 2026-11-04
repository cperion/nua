-- Nua's facts for Mua's analysis (mua.scope, design macro-layer.md §4.9): which
-- callees are words, which prelude names and externs declare an arity, which modules a
-- `require` reaches. Shared by staged code generation and the formatter, so the compiler and
-- the formatter cannot disagree.
local scope = require 'mua.scope'
local M = {}

-- Prelude functions with a declared arity (S.arity). stage.lua declares these
-- same arities.
M.prelude_arity = { band = 2, bor = 2, bxor = 2, shl = 2, shr = 2 }

-- the shared word-application machinery, as stage.lua and the formatter use it
M.word_arguments = scope.word_arguments
M.without_handler = scope.without_handler
M.regroups = scope.regroups
M.chain = scope.chain

-- A typed function is a word: its parameters are its arity.
local function word(fn)
    if fn.result then return { word = true, arity = #fn.params, rest = fn.rest ~= nil } end
end

local function unquote(text)
    local q = text:sub(1, 1)
    if (q == '"' or q == "'") and text:sub(-1) == q and not text:find('\\', 1, true) then
        return text:sub(2, -2)
    end
end

-- `extern("name", { A, B }, R [, opts])`: a declared parameter list is a declared
-- arity, unless the options might make it variadic.
local function extern_fact(args)
    local params, opts = args[2], args[4]
    if #args < 3 or #args > 4 or not params or params.k ~= 'table' then return end
    for _, item in ipairs(params.items) do
        if item.kind ~= 'pos' or item.e.k == 'spread' then return end
    end
    if opts then
        if opts.k ~= 'table' then return end
        for _, item in ipairs(opts.items) do
            if item.kind ~= 'named' or item.name == 'variadic' then return end
        end
    end
    return { arity = #params.items }
end


local facts = {
    word = word,
    global = function(name)
        local arity = M.prelude_arity[name]
        return arity and { arity = arity } or nil
    end,
    call = function(global, e, env)
        if global == 'extern' then return extern_fact(e.args) end
        if global == 'require' and env.module and #e.args == 1 and e.args[1].k == 'str' then
            local name = unquote(e.args[1].text)
            return name and env.module(name) or nil
        end
    end,
}
M.facts = facts

-- env: see mua.scope; Nua's facts are supplied
function M.analyze(ast, env)
    env = env or {}
    env.facts = facts
    return scope.analyze(ast, env)
end

return M
