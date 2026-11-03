-- The trailing colon. A colon that ends a line, optionally followed by parameter
-- names, opens a block lambda:
--
--     with_buffer n:               with_buffer n do(..)
--     words:each: key value        words:each do(key, value)
--     tasks: scope..               tasks do(scope..)
--
-- The colon is a block opener only where Nua has no annotation colon: not after a
-- parameter list (`do(x: U32): U32`, `function f(x): T`), not in the names of a
-- `local`, not inside brackets, not in a `::label::`, and not directly followed by
-- a name (`xs:each`, a method call). Only the token list changes; the text that
-- follows the colon (names, comment) is kept so line numbers stay put.

local M = {}

local OPERAND = { iden = true, string = true, number = true, [')'] = true, [']'] = true, ['}'] = true }
local LITERAL = { ['true'] = true, ['false'] = true, ['nil'] = true }

local function skip_back(tokens, i)
    i = i - 1
    while i >= 1 and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i - 1 end
    return i
end

local function is_do(tk) return (tk[1] == 'keyword' or tk[1] == 'iden') and tk[2] == 'do' end

-- does the `(` at index i open a function's parameter list: `do(`, `function f(`?
local function parameter_list(tokens, i)
    local j = skip_back(tokens, i)
    if j < 1 then return false end
    if is_do(tokens[j]) then return true end
    if tokens[j][1] ~= 'iden' and tokens[j][2] ~= '__typed_function' then return false end
    while j >= 1 and tokens[j][1] == 'iden' do
        j = skip_back(tokens, j)
        if j >= 1 and (tokens[j][1] == '.' or tokens[j][1] == ':') then
            j = skip_back(tokens, j)
        else
            break
        end
    end
    return j >= 1 and tokens[j][1] == 'keyword' and tokens[j][2] == 'function'
end

-- is the colon at index i the annotation of a `local` name list?
local function local_annotation(tokens, i)
    local j = skip_back(tokens, i)
    while j >= 1 and (tokens[j][1] == 'iden' or tokens[j][1] == ',') do j = skip_back(tokens, j) end
    return j >= 1 and tokens[j][1] == 'keyword' and tokens[j][2] == 'local'
end

-- What follows the colon on its line: names, `name..`, `..`, then the end of the
-- line. Returns the parameter text and the index of the last token consumed, or nil.
local function parameters(tokens, i)
    local names, j, n = {}, i + 1, #tokens
    local last = i                                                   -- the last token of the names
    local first = tokens[j]
    if first and first[1] == 'iden' then return nil end            -- `xs:each`
    while j <= n do
        local tk = tokens[j]
        local t = tk[1]
        if t == 'space' then
            if tk[2]:find '\n' then return names, last end
        elseif t == 'comment' then
            if tk[2]:find '\n' then return nil end
        elseif t == 'iden' then
            names[#names + 1] = tk[2]
            last = j
        elseif t == '.' then
            local nx = tokens[j + 1]
            if not nx or nx[1] ~= '.' then return nil end
            if tokens[j - 1][1] == 'iden' and j - 1 > i then
                names[#names] = names[#names] .. '..'
            else
                names[#names + 1] = '..'
            end
            j = j + 1
            last = j
        else
            return nil
        end
        j = j + 1
    end
    return names, last
end

-- Rewrite every block colon in a token list. Tokens are { type, text, line }.
function M.rewrite(tokens)
    local out, depth = {}, 0
    local openers = {}                               -- index in `tokens` of each open bracket
    local closer_of = {}                             -- ')' index -> its '(' index
    local i, n = 1, #tokens
    while i <= n do
        local tk = tokens[i]
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then
            openers[#openers + 1] = i
        elseif t == ')' or t == '}' or t == ']' then
            local o = table.remove(openers)
            if o then closer_of[i] = o end
        end
        local block = false
        local p = t == ':' and skip_back(tokens, i)
        -- `=:` assigns a block (`key =: x`, `local f =: x`); it works inside brackets too
        local assigned = p and p >= 1 and tokens[p][1] == '='
        if t == ':' and (#openers == 0 or assigned) then
            local prev, nxt = tokens[i - 1], tokens[i + 1]
            local label = (prev and prev[1] == ':') or (nxt and nxt[1] == ':')
            if not label then
                local after_params = p >= 1 and tokens[p][1] == ')' and closer_of[p]
                    and parameter_list(tokens, closer_of[p])
                local operand = p >= 1 and (OPERAND[tokens[p][1]] or tokens[p][1] == '='
                    or (tokens[p][1] == 'keyword' and LITERAL[tokens[p][2]]))
                if operand and not after_params and not local_annotation(tokens, i) then
                    local names, last = parameters(tokens, i)
                    if names then
                        local line = tk[3]
                        if #names == 0 then names[1] = '..' end    -- `:` alone opens what it is given
                        out[#out + 1] = { 'space', ' ', line }
                        out[#out + 1] = { 'iden', 'do', line }
                        out[#out + 1] = { '(', '(', line }
                        for k, name in ipairs(names) do
                            if k > 1 then
                                out[#out + 1] = { ',', ',', line }
                                out[#out + 1] = { 'space', ' ', line }
                            end
                            if name == '..' then
                                out[#out + 1] = { '.', '.', line }
                                out[#out + 1] = { '.', '.', line }
                            else
                                local base = name:gsub('%.%.$', '')
                                out[#out + 1] = { 'iden', base, line }
                                if base ~= name then
                                    out[#out + 1] = { '.', '.', line }
                                    out[#out + 1] = { '.', '.', line }
                                end
                            end
                        end
                        out[#out + 1] = { ')', ')', line }
                        -- the original names are consumed; keep the line break
                        i = last + 1
                        block = true
                    end
                end
            end
        end
        if not block then
            out[#out + 1] = tk
            i = i + 1
        end
    end
    return out
end

-- Source text tools (nua fmt) work on do-forms. `expand` writes the trailing
-- colons of a source as the `do(..)` they mean; `colonize` writes untyped
-- trailing `do(names)` blocks back as colons. Both go through the lexer and
-- leave everything else byte for byte.
local lexer = require 'macro.lexer'

local function text_of(tokens)
    local parts = {}
    for i, tk in ipairs(tokens) do parts[i] = tk[2] end
    return table.concat(parts)
end

function M.expand(source)
    return text_of(M.rewrite(lexer.scan_raw_tokenlist(source)))
end

-- `do ( name, name.. )` at index i, followed by the end of its line: the
-- parameter text and the index of its `)`, or nil
local function untyped_head(tokens, i)
    local j = i + 1
    if not tokens[j] or tokens[j][1] ~= '(' then return nil end
    local names, k = {}, j + 1
    while true do
        local tk = tokens[k]
        if not tk then return nil end
        if tk[1] == 'iden' then
            names[#names + 1] = tk[2]
        elseif tk[1] == '.' and tokens[k + 1] and tokens[k + 1][1] == '.' then
            if #names > 0 and tokens[k - 1][1] == 'iden' then names[#names] = names[#names] .. '..'
            else names[#names + 1] = '..' end
            k = k + 1
        elseif tk[1] == ')' then
            break
        elseif tk[1] ~= ',' and tk[1] ~= 'space' then
            return nil
        end
        k = k + 1
    end
    local e = k + 1
    while tokens[e] and tokens[e][1] == 'space' and not tokens[e][2]:find '\n' do e = e + 1 end
    if tokens[e] and tokens[e][1] == 'comment' then e = e + 1 end
    if tokens[e] and not (tokens[e][1] == 'space' and tokens[e][2]:find '\n') then return nil end
    return names, k
end

function M.colonize(source)
    local tokens = lexer.scan_raw_tokenlist(source)
    local out, openers, i, n = {}, {}, 1, #tokens
    local closer_of = {}
    for k, tk in ipairs(tokens) do
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then openers[#openers + 1] = k
        elseif t == ')' or t == '}' or t == ']' then closer_of[k] = table.remove(openers) end
    end
    openers = {}
    while i <= n do
        local tk = tokens[i]
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then openers[#openers + 1] = i
        elseif t == ')' or t == '}' or t == ']' then table.remove(openers) end
        local done = false
        local p = is_do(tk) and skip_back(tokens, i)
        if is_do(tk) and (#openers == 0 or (p >= 1 and tokens[p][1] == '=')) then
            local operand = p >= 1 and (OPERAND[tokens[p][1]] or tokens[p][1] == '='
                or (tokens[p][1] == 'keyword' and LITERAL[tokens[p][2]]))
            local after_params = p >= 1 and tokens[p][1] == ')' and closer_of[p]
                and parameter_list(tokens, closer_of[p])
            local names, close = untyped_head(tokens, i)
            if operand and not after_params and names then
                -- drop the space before `do`, write `:` and the names
                while #out > 0 and out[#out][1] == 'space' and not out[#out][2]:find '\n' do out[#out] = nil end
                local text = ':'
                if #names > 0 and not (#names == 1 and names[1] == '..') then
                    text = text .. ' ' .. table.concat(names, ' ')
                end
                out[#out + 1] = { ':', text, tk[3] }
                i = close + 1
                done = true
            end
        end
        if not done then out[#out + 1] = tk; i = i + 1 end
    end
    local result = text_of(out)
    -- the colon form must mean what the do-form meant
    if M.expand(result) ~= source then return source end
    return result
end

return M
