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

local MARK = '--[=[nua:with]=]'
M.MARK = MARK

-- the do-block opener tokens for `names`, written where a colon stood
local function block_head(names, line)
    local out = { { 'space', ' ', line }, { 'iden', 'do', line }, { '(', '(', line } }
    if #names == 0 then names[1] = '..' end            -- `:` alone opens what it is given
    for k, name in ipairs(names) do
        if k > 1 then
            out[#out + 1] = { ',', ',', line }
            out[#out + 1] = { 'space', ' ', line }
        end
        if name ~= '..' then out[#out + 1] = { 'iden', (name:gsub('%.%.$', '')), line } end
        if name:sub(-2) == '..' then
            out[#out + 1] = { '.', '.', line }
            out[#out + 1] = { '.', '.', line }
        end
    end
    out[#out + 1] = { ')', ')', line }
    return out
end

-- `do ( ... ) :` a typed lambda: a word's body, which `endall` never closes
local function typed_lambda(tokens, i)
    local n, j, depth = #tokens, i + 1, 0
    while j <= n and (tokens[j][1] == 'space' or tokens[j][1] == 'comment') do j = j + 1 end
    if not tokens[j] or tokens[j][1] ~= '(' then return false end
    repeat
        local t = tokens[j][1]
        if t == '(' then depth = depth + 1 elseif t == ')' then depth = depth - 1 end
        j = j + 1
    until depth == 0 or j > n
    while j <= n and (tokens[j][1] == 'space' or tokens[j][1] == 'comment') do j = j + 1 end
    return tokens[j] ~= nil and tokens[j][1] == ':'
end

-- `do ( ... )` at index i followed by `=` (an expression lambda has no `end`),
-- also with a result type: `do(x: U32): U32 = ...`
local function expression_lambda(tokens, i)
    local n, j, depth = #tokens, i + 1, 0
    while j <= n and (tokens[j][1] == 'space' or tokens[j][1] == 'comment') do j = j + 1 end
    if not tokens[j] or tokens[j][1] ~= '(' then return false end
    repeat
        local t = tokens[j][1]
        if t == '(' then depth = depth + 1 elseif t == ')' then depth = depth - 1 end
        j = j + 1
    until depth == 0 or j > n
    while j <= n and (tokens[j][1] == 'space' or tokens[j][1] == 'comment') do j = j + 1 end
    if tokens[j] and tokens[j][1] == '=' then return true end
    if tokens[j] and tokens[j][1] == ':' then
        while j <= n do                                 -- the type, up to `=` or the end of the line
            local tk = tokens[j]
            if tk[1] == '=' then return true end
            if tk[1] == 'space' and tk[2]:find '\n' then return false end
            j = j + 1
        end
    end
    return false
end

local function skip_forward(tokens, i)
    i = i + 1
    while tokens[i] and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i + 1 end
    return tokens[i] and i
end

local function significant_after(tokens, i)
    i = i + 1
    while tokens[i] and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i + 1 end
    return i
end

-- does the `with` at i stand where an expression starts, and begin entries (not a variable)?
local EXPRESSION_START = { ['='] = true, ['('] = true, [','] = true, ['{'] = true, [';'] = true }
local function contextual_with(tokens, i)
    local p = skip_back(tokens, i)
    if p < 1 then return false end
    local before = tokens[p]
    if not (EXPRESSION_START[before[1]] or (before[1] == 'keyword' and before[2] == 'return')) then return false end
    local nx = tokens[significant_after(tokens, i)]
    if not nx then return false end
    if nx[1] == '.' or nx[1] == '[' or nx[1] == 'iden' or nx[1] == 'string' or nx[1] == 'number' then
        return not (tokens[i + 1] and (tokens[i + 1][1] == '.' or tokens[i + 1][1] == '('))
    end
    return false
end


-- Rewrite every block colon and every `with` block in a token list. Tokens are
-- { type, text, line }.
--
-- A stack of what is open (brackets, blocks closed by `end`, `with` blocks) tells
-- where a colon may open a block (statement level: not inside brackets, not
-- directly inside a `with`, where a colon is an annotation) and which `end` closes
-- a `with` (`T with k = v k = v end` is `T { k = v, k = v }`).
function M.rewrite(tokens, mark, full)
    local out, stack = {}, {}
    local loops = {}                           -- stack depth -> loop headers waiting for their `do`
    local closer_of, openers = {}, {}
    for i, tk in ipairs(tokens) do
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then openers[#openers + 1] = i
        elseif t == ')' or t == '}' or t == ']' then closer_of[i] = table.remove(openers) end
    end
    local last, newline = nil, false           -- last significant output token (index), a line break since
    local i, n = 1, #tokens
    local function emit(tk)
        out[#out + 1] = tk
        if tk[1] ~= 'space' and tk[1] ~= 'comment' then last, newline = #out, false
        elseif tk[1] == 'space' and tk[2]:find '\n' then newline = true end
    end
    local function top() return stack[#stack] end
    local function push(kind, line) stack[#stack + 1] = { kind = kind, line = line, entries = 0 } end
    -- an entry of the `with` on top of the stack starts at token i
    local function entry_start(i)
        local tk = tokens[i]
        local nxt = significant_after(tokens, i)
        local t2 = tokens[nxt] and tokens[nxt][1]
        if tk[1] == 'iden' then
            if t2 == '=' then return true end
            if t2 == ':' and tokens[nxt + 1] and tokens[nxt + 1][1] == 'space' then return true end
            return newline                        -- a positional value on a line of its own
        end
        return tk[1] == '.' and newline and tokens[i + 1] and tokens[i + 1][1] == 'iden'
    end
    while i <= n do
        local tk = tokens[i]
        local t, v = tk[1], tk[2]
        local sig = t ~= 'space' and t ~= 'comment'
        local handled = false
        local frame = sig and top()
        -- an entry of a `with` block: separate it from the previous one
        if frame and frame.kind == 'with' and not (t == 'keyword' and v == 'end')
            and entry_start(i) then
            if frame.entries > 0 then
                local lt, lv = out[last][1], out[last][2]
                local ends = OPERAND[lt] or (lt == 'keyword' and (LITERAL[lv] or lv == 'end'))
                if ends and out[last] ~= frame.opener then
                    table.insert(out, last + 1, { ',', ',', tk[3] })
                    last = last + 1
                end
            end
            frame.entries = frame.entries + 1
        end
        if sig then
            if t == '(' or t == '{' or t == '[' then
                push('bracket', tk[3])
            elseif t == ')' or t == '}' or t == ']' then
                if top() and top().kind == 'bracket' then stack[#stack] = nil end
            elseif t == 'keyword' and (v == 'while' or v == 'for') then
                loops[#stack] = (loops[#stack] or 0) + 1       -- its `do` is Lua's own
            elseif (t == 'keyword' or t == 'iden') and v == 'do' then
                if (loops[#stack] or 0) > 0 then
                    loops[#stack] = loops[#stack] - 1
                    push('control', tk[3])
                elseif not expression_lambda(tokens, i) then
                    -- after an operand or `=`, `(`, `,`, `{`, `return`: a lambda; where a statement starts: Lua's block
                    local p = skip_back(tokens, i)
                    local before = p >= 1 and tokens[p]
                    local lambda = before and (OPERAND[before[1]] or EXPRESSION_START[before[1]]
                        or (before[1] == 'keyword' and (before[2] == 'return' or LITERAL[before[2]])))
                    push(lambda and not typed_lambda(tokens, i) and 'lambda' or 'control', tk[3])
                end
            elseif t == 'keyword' and (v == 'function' or v == 'if') then
                push('control', tk[3])
            elseif t == 'keyword' and v == 'repeat' then
                push('repeat', tk[3])
            elseif t == 'keyword' and v == 'until' then
                if top() and top().kind == 'repeat' then stack[#stack] = nil end
            elseif t == 'keyword' and v == 'end' or (t == 'iden' and v == 'endall') then
                local f = top()
                if v == 'endall' then
                    -- every open Nua block, back to Lua control (design: `endall` closes a spine)
                    local chain, depth = {}, #stack
                    while depth >= 1 and (stack[depth].kind == 'lambda' or stack[depth].kind == 'with') do
                        chain[#chain + 1] = stack[depth].kind
                        depth = depth - 1
                    end
                    local has_with = false
                    for _, kind in ipairs(chain) do if kind == 'with' then has_with = true end end
                    for _ = 1, #chain do stack[#stack] = nil end
                    if has_with or full then
                        -- a data block is not a lambda: write the closers out, innermost first
                        for k, kind in ipairs(chain) do
                            -- (source tools get each closer on a line of its own, to lay them out)
                            if k > 1 then emit({ 'space', mark and '\n' or ' ', tk[3] }) end
                            if kind == 'with' then emit({ '}', '}', tk[3] })
                            else emit({ 'keyword', 'end', tk[3] }) end
                        end
                        handled = true
                    end
                elseif f and f.kind == 'with' then
                    stack[#stack] = nil
                    emit({ '}', '}', tk[3] })
                    handled = true
                elseif f and (f.kind == 'lambda' or f.kind == 'control') then
                    stack[#stack] = nil
                end
            elseif t == 'iden' and v == 'with' and contextual_with(tokens, i) then
                -- `with` in expression position (after `return`, `=`, `(`, `,`, `{`): its type
                -- comes from the context, so it is a table the type-directed coercion consumes
                push('with', tk[3])
                -- `with { entries }`: an ordinary application of the prelude's `with` to a table
                if not mark then emit({ 'iden', 'with', tk[3] }); emit({ 'space', ' ', tk[3] }) end
                emit({ '{', '{', tk[3] })
                top().opener = out[#out]
                if mark then emit({ 'comment', MARK, tk[3] }) end
                handled = true
            elseif t == 'iden' and v == 'with' and last then
                -- `T with` (after an operand, not followed by `=`) opens a data block
                local p = skip_back(tokens, i)
                local operand = p >= 1 and (OPERAND[tokens[p][1]]
                    or (tokens[p][1] == 'keyword' and LITERAL[tokens[p][2]]))
                local nx = tokens[significant_after(tokens, i)]
                local adjacent = tokens[i + 1] and (tokens[i + 1][1] == '.' or tokens[i + 1][1] == '(')
                if operand and not adjacent and not (nx and nx[1] == '=') then
                    push('with', tk[3])
                    emit({ '{', '{', tk[3] })
                    top().opener = out[#out]
                    -- source tools mark the brace, to write the `with` back
                    if mark then emit({ 'comment', MARK, tk[3] }) end
                    handled = true
                end
            elseif t == ':' then
                local p = skip_back(tokens, i)
                local f = top()
                local assigned = p >= 1 and tokens[p][1] == '='
                local statement = not f or f.kind == 'lambda' or f.kind == 'control' or f.kind == 'repeat'
                local prev, nxt = tokens[i - 1], tokens[i + 1]
                local label = (prev and prev[1] == ':') or (nxt and nxt[1] == ':')
                if (statement or assigned) and not label and p >= 1 then
                    local after_params = tokens[p][1] == ')' and closer_of[p]
                        and parameter_list(tokens, closer_of[p])
                    local operand = OPERAND[tokens[p][1]] or tokens[p][1] == '='
                        or (tokens[p][1] == 'keyword' and LITERAL[tokens[p][2]])
                    if operand and not after_params and not local_annotation(tokens, i) then
                        local names, stop = parameters(tokens, i)
                        if names then
                            for _, h in ipairs(block_head(names, tk[3])) do emit(h) end
                            push('lambda', tk[3])
                            i = stop + 1
                            handled, tk = true, nil
                        end
                    end
                end
            end
        end
        if tk then
            if not handled then emit(tk) end
            i = i + 1
        end
    end
    for _, f in ipairs(stack) do
        if f.kind == 'with' then
            error(('line %d: a `with` block is not closed (expected `end`)'):format(f.line), 0)
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

function M.expand(source, mark, full)
    return text_of(M.rewrite(lexer.scan_raw_tokenlist(source), mark, full))
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
    if M.expand(result) ~= M.expand(source) then return source end
    return result
end

-- Which block or bracket is innermost at each token, for source text that has no
-- colon blocks and no `with` (it was expanded): returns top_at[i] (a frame) and
-- the frame each bracket token opens.
local function frames_of(tokens)
    local stack, top_at, opened = {}, {}, {}
    for i, tk in ipairs(tokens) do
        top_at[i] = stack[#stack]
        local t, v = tk[1], tk[2]
        if t == '(' or t == '{' or t == '[' then
            local f = { kind = 'bracket', open = i }
            stack[#stack + 1] = f
            opened[i] = f
        elseif t == ')' or t == '}' or t == ']' then
            if stack[#stack] and stack[#stack].kind == 'bracket' then stack[#stack] = nil end
        elseif (t == 'keyword' or t == 'iden') and v == 'do' then
            if not expression_lambda(tokens, i) then stack[#stack + 1] = { kind = 'block' } end
        elseif t == 'keyword' and (v == 'function' or v == 'if') then
            stack[#stack + 1] = { kind = 'block' }
        elseif t == 'keyword' and v == 'repeat' then
            stack[#stack + 1] = { kind = 'repeat' }
        elseif t == 'keyword' and v == 'until' then
            if stack[#stack] and stack[#stack].kind == 'repeat' then stack[#stack] = nil end
        elseif t == 'keyword' and v == 'end' or (t == 'iden' and v == 'endall') then
            if stack[#stack] and stack[#stack].kind == 'block' then
                stack[#stack] = nil
                if v == 'endall' then
                    while stack[#stack] and stack[#stack].kind == 'block' do stack[#stack] = nil end
                end
            end
        end
    end
    return top_at, opened
end

-- Mark the multi-line tables that follow a head (`T {`, `f(x) {`): `withize` writes
-- them as `with` blocks. One-line tables and tables with no head (`{ 1, 2 }`,
-- `local t = { a = 1 }`, which are Lua's) are left alone.
function M.mark_tables(source)
    local tokens = lexer.scan_raw_tokenlist(source)
    local close_of, stack = {}, {}
    for i, tk in ipairs(tokens) do
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then stack[#stack + 1] = i
        elseif t == ')' or t == '}' or t == ']' then close_of[table.remove(stack)] = i end
    end
    -- a table is data when some top-level entry is keyed (`k = v`, `k: T`, `[k] = v`, `.k`)
    local function keyed(open)
        local depth = 0
        for k = open + 1, close_of[open] - 1 do
            local t = tokens[k][1]
            if t == '(' or t == '{' or t == '[' then
                if t == '[' and depth == 0 then
                    local c = close_of[k]
                    local nx = c and skip_forward(tokens, c)
                    if nx and tokens[nx][1] == '=' then return true end
                end
                depth = depth + 1
            elseif t == ')' or t == '}' or t == ']' then depth = depth - 1
            elseif depth == 0 and t == 'iden' then
                local nx = skip_forward(tokens, k)
                local n = nx and tokens[nx]
                if n and (n[1] == '=' or (n[1] == ':' and tokens[nx + 1] and tokens[nx + 1][1] == 'space')) then
                    return true
                end
            elseif depth == 0 and t == '.' and tokens[k + 1] and tokens[k + 1][1] == 'iden' then
                local p = skip_back(tokens, k)
                local pt = p >= 1 and tokens[p][1]
                if pt == '{' or pt == ',' or pt == ';' then return true end
            end
        end
        return false
    end
    local out, header = {}, false              -- header: between `for`/`while` and its `do`
    for i, tk in ipairs(tokens) do
        out[#out + 1] = tk
        if tk[1] == 'keyword' and (tk[2] == 'for' or tk[2] == 'while') then header = true
        elseif tk[1] == 'keyword' and tk[2] == 'do' then header = false end
        if tk[1] == '{' and close_of[i] and not header and keyed(i) then
            local p = skip_back(tokens, i)
            local head = p >= 1 and (OPERAND[tokens[p][1]]) and tokens[p][1] ~= 'string'
            local multiline = false
            for k = i + 1, close_of[i] - 1 do
                if tokens[k][1] == 'space' and tokens[k][2]:find '\n' then multiline = true; break end
            end
            local k = i + 1
            while tokens[k] and tokens[k][1] == 'space' do k = k + 1 end
            local marked = tokens[k] and tokens[k][1] == 'comment' and tokens[k][2] == MARK
            if head and multiline and not marked then out[#out + 1] = { 'comment', MARK, tk[3] } end
        end
    end
    return text_of(out)
end

-- Write the braces `expand` marked back as `with ... end`. A separator is dropped
-- where the reader would put it back (before an entry that starts with `name =`,
-- `name:` or a line of its own, and before the closing brace). Without the marks
-- the source is returned with its braces; the result is only accepted when
-- expanding it gives the braces' own token stream.
function M.withize(source, unit)
    unit = unit or '    '
    local tokens = lexer.scan_raw_tokenlist(source)
    local top_at, opened = frames_of(tokens)
    local close_of, stack = {}, {}
    for i, tk in ipairs(tokens) do
        local t = tk[1]
        if t == '(' or t == '{' or t == '[' then stack[#stack + 1] = i
        elseif t == ')' or t == '}' or t == ']' then close_of[table.remove(stack)] = i end
    end
    local function next_sig(i)
        i = i + 1
        while tokens[i] and (tokens[i][1] == 'space' or tokens[i][1] == 'comment') do i = i + 1 end
        return i
    end
    local blocks, plain = {}, {}
    for i, tk in ipairs(tokens) do
        if tk[1] == '{' then
            local j = i + 1
            while tokens[j] and tokens[j][1] == 'space' do j = j + 1 end
            if tokens[j] and tokens[j][1] == 'comment' and tokens[j][2] == MARK then
                local block = { open = i, close = close_of[i], drop = {} }
                blocks[#blocks + 1] = block
                for k = i + 1, j do block.drop[k] = true end
                local f = opened[i]
                local function has_newline(a, b)
                    for q = a, b do
                        if tokens[q][1] == 'space' and tokens[q][2]:find '\n' then return true end
                    end
                    return false
                end
                -- a table that spans lines is written one entry per line, `end` on a line of its own
                local multiline = has_newline(i + 1, close_of[i] - 1)
                block.before, block.moved = {}, {}
                if multiline then
                    -- the block's own line is indented like the entry of the block around it
                    -- (that entry gets a line of its own), else like the line it is on
                    local indent
                    for q = #blocks - 1, 1, -1 do
                        local outer = blocks[q]
                        if outer.open < i and i < outer.close and outer.moved then
                            -- the entry of `outer` this table sits in, if that entry was moved to a line
                            -- of its own and no line break separates its start from the table
                            local start
                            for at in pairs(outer.moved) do
                                if at < i and (not start or at > start) then start = at end
                            end
                            if start and not has_newline(start, i) then indent = outer.moved[start] end
                            break
                        end
                    end
                    if not indent then
                        indent = ''
                        for q = i - 1, 1, -1 do
                            if tokens[q][1] == 'space' and tokens[q][2]:find '\n' then
                                indent = tokens[q][2]:match('[^\n]*$'); break
                            end
                        end
                    end
                    block.indent = indent
                    local function own_line(at, text)
                        local p = at - 1
                        if tokens[p][1] == 'space' and tokens[p][2]:find '\n' then return end
                        if tokens[p][1] == 'space' then block.drop[p] = true end
                        block.before[at] = '\n' .. text
                        block.moved[at] = text
                    end
                    local at = next_sig(j)
                    if at < close_of[i] then own_line(at, indent .. unit) end
                    for k = i + 1, close_of[i] - 1 do
                        local c = tokens[k]
                        if top_at[k] == f and (c[1] == ',' or c[1] == ';') then
                            local nx = next_sig(k)
                            if nx < close_of[i] then own_line(nx, indent .. unit) end
                        end
                    end
                    own_line(close_of[i], indent)
                end
                for k = i + 1, close_of[i] - 1 do
                    local c = tokens[k]
                    if top_at[k] == f and (c[1] == ',' or c[1] == ';') then
                        local nx = next_sig(k)
                        local first, second = tokens[nx], tokens[next_sig(nx)]
                        local newline = multiline or has_newline(k + 1, nx - 1)
                        local starts = first and first[1] == 'iden' and second and (second[1] == '='
                            or (second[1] == ':' and tokens[next_sig(nx) + 1] and tokens[next_sig(nx) + 1][1] == 'space'))
                        -- entries on one line keep their commas; at a line end the reader writes it back
                        if nx == close_of[i] or (newline and (starts or (first and (first[1] == 'iden' or first[1] == '.')))) then
                            block.drop[k] = true
                        end
                    end
                end
            end
        elseif tk[1] == 'comment' and tk[2] == MARK then
            plain[i] = true
        end
    end
    -- the source with the selected blocks written as `with ... end`
    local function build(selected)
        local drop, replace, before = {}, {}, {}
        for _, block in ipairs(selected) do
            for k in pairs(block.drop) do drop[k] = true end
            for k, text in pairs(block.before) do before[k] = text end
            replace[block.open], replace[block.close] = 'with', 'end'
        end
        local out = {}
        for i, tk in ipairs(tokens) do
            if not plain[i] and not drop[i] then
                if before[i] then out[#out + 1] = { 'space', before[i] } end
                local text = replace[i]
                if text then
                    if out[#out] and out[#out][1] ~= 'space' then out[#out + 1] = { 'space', ' ' } end
                    out[#out + 1] = { 'iden', text }
                else
                    out[#out + 1] = tk
                end
            end
        end
        return text_of(out)
    end
    local function plain_text()
        local out = {}
        for i, tk in ipairs(tokens) do
            local is_mark = tk[1] == 'comment' and tk[2] == MARK
            if not is_mark then out[#out + 1] = tk end
        end
        return text_of(out)
    end
    local function normal(text)
        -- a comma before the closing brace is only spelling
        local parts = {}
        for _, tk in ipairs(lexer.scan_raw_tokenlist(text)) do
            if tk[1] ~= 'space' and tk[1] ~= 'comment' then
                if tk[1] == '}' and parts[#parts] == ',' then parts[#parts] = nil end
                parts[#parts + 1] = tk[2]
            end
        end
        return table.concat(parts, '\0')
    end
    local braces = plain_text()
    if #blocks == 0 then return braces end
    local want = normal(braces)
    local function accepted(selected)
        local text = build(selected)
        return normal(M.expand(text, true)) == want and text
    end
    local all = accepted(blocks)
    if all then return all end
    -- one block the reader would not recover must not keep the others from converting
    local chosen = {}
    for _, block in ipairs(blocks) do
        if accepted({ block }) then chosen[#chosen + 1] = block end
    end
    return accepted(chosen) or braces
end

-- Nua blocks found without rewriting: for text that has `with` blocks and do-forms
-- (the formatter's output before the colon pass). Frames are { kind, open, close, parent }.
local function scan_blocks(tokens)
    local stack, frames, close_frame, depth_at, loops = {}, {}, {}, {}, {}
    local function push(kind, i)
        local f = { kind = kind, open = i, parent = stack[#stack] }
        frames[#frames + 1] = f
        stack[#stack + 1] = f
    end
    for i, tk in ipairs(tokens) do
        depth_at[i] = #stack
        local t, v = tk[1], tk[2]
        if t == '(' or t == '{' or t == '[' then push('bracket', i)
        elseif t == ')' or t == '}' or t == ']' then
            if stack[#stack] and stack[#stack].kind == 'bracket' then stack[#stack] = nil end
        elseif t == 'keyword' and (v == 'while' or v == 'for') then
            loops[#stack] = (loops[#stack] or 0) + 1
        elseif (t == 'keyword' or t == 'iden') and v == 'do' then
            if (loops[#stack] or 0) > 0 then
                loops[#stack] = loops[#stack] - 1
                push('control', i)
            elseif not expression_lambda(tokens, i) then
                local p = skip_back(tokens, i)
                local before = p >= 1 and tokens[p]
                local lambda = before and (OPERAND[before[1]] or EXPRESSION_START[before[1]]
                    or (before[1] == 'keyword' and (before[2] == 'return' or LITERAL[before[2]])))
                push(lambda and not typed_lambda(tokens, i) and 'lambda' or 'control', i)
            end
        elseif t == 'keyword' and (v == 'function' or v == 'if') then push('control', i)
        elseif t == 'keyword' and v == 'repeat' then push('repeat', i)
        elseif t == 'keyword' and v == 'until' then
            if stack[#stack] and stack[#stack].kind == 'repeat' then stack[#stack] = nil end
        elseif t == 'keyword' and v == 'end' then
            local f = stack[#stack]
            if f and f.kind ~= 'bracket' then
                f.close = i
                close_frame[i] = { f }
                stack[#stack] = nil
            end
        elseif t == 'iden' and v == 'endall' then
            -- an `endall` already written closes the lambdas on top of the stack
            local popped = {}
            while stack[#stack] and (stack[#stack].kind == 'lambda' or stack[#stack].kind == 'with') do
                local f = stack[#stack]
                f.close = i
                popped[#popped + 1] = f
                stack[#stack] = nil
            end
            close_frame[i] = popped
        elseif t == 'iden' and v == 'with' then
            local p = skip_back(tokens, i)
            local operand = p >= 1 and (OPERAND[tokens[p][1]]
                or (tokens[p][1] == 'keyword' and LITERAL[tokens[p][2]]))
            local nx = tokens[significant_after(tokens, i)]
            local adjacent = tokens[i + 1] and (tokens[i + 1][1] == '.' or tokens[i + 1][1] == '(')
            if (operand and not adjacent and not (nx and nx[1] == '=')) or contextual_with(tokens, i) then
                push('with', i)
            end
        end
    end
    return frames, close_frame, depth_at
end

-- the token that ends a lambda's header: its parameter list's `)`, or `do` itself
local function header_end(tokens, frame)
    local i = frame.open
    local j = significant_after(tokens, i)
    if tokens[j] and tokens[j][1] == '(' then
        local depth = 0
        repeat
            local t = tokens[j][1]
            if t == '(' then depth = depth + 1 elseif t == ')' then depth = depth - 1 end
            j = j + 1
        until depth == 0 or j > #tokens
        return j - 1
    end
    return i
end

-- Fold the trailing `end` lines that close Nua blocks into one `endall`, and lay the chain
-- out flat: the wrappers (`tasks:`, `spawn:`), then the content indented once, with the
-- links of the handler chain at the content's indent, sibling entries one level in, and the
-- innermost body one level in. A chain is folded only if it has a `with` (lambda-only
-- chains keep the spine style) and the macro would read the result back as the same program.
function M.foldends(source, unit)
    unit = unit or '    '
    local tokens = lexer.scan_raw_tokenlist(source)
    local frames, close_frame = scan_blocks(tokens)
    local lines = {}
    for l in (source .. '\n'):gmatch('([^\n]*)\n') do lines[#lines + 1] = l end
    if lines[#lines] == '' then lines[#lines] = nil end
    local sig_on, comment_on = {}, {}
    for i, tk in ipairs(tokens) do
        local line = tk[3]
        if tk[1] == 'comment' then comment_on[line] = true
        elseif tk[1] ~= 'space' then
            sig_on[line] = sig_on[line] or {}
            table.insert(sig_on[line], i)
        end
    end
    local function indent_of(line) return #(lines[line]:match('^ *')) end
    -- lines holding only an `end` that closes a block
    local closer_line = {}
    for line, list in pairs(sig_on) do
        local i = list[1]
        if #list == 1 and not comment_on[line] and close_frame[i] then closer_line[line] = i end
    end
    local runs, ordered = {}, {}
    for line in pairs(closer_line) do ordered[#ordered + 1] = line end
    table.sort(ordered)
    for _, line in ipairs(ordered) do
        local run = runs[#runs]
        if run and run.last == line - 1 then run[#run + 1] = line; run.last = line
        else runs[#runs + 1] = { line, last = line } end
    end
    local edits = {}
    for r = #runs, 1, -1 do
        local run = runs[r]
        -- the closers of the run, innermost first, one frame each (an `endall` line has several)
        local entries = {}
        for _, line in ipairs(run) do
            for _, f in ipairs(close_frame[closer_line[line]]) do entries[#entries + 1] = { line = line, frame = f } end
        end
        -- skip the explicit closers of Lua control blocks that come first (innermost)
        local k = 1
        while entries[k] and entries[k].frame.kind == 'control' do k = k + 1 end
        local chain, first_line = {}, entries[k] and entries[k].line
        local prev, last_chain_line
        while entries[k] do
            local f = entries[k].frame
            if f.kind ~= 'lambda' and f.kind ~= 'with' then break end
            if prev and prev.parent ~= f then break end
            chain[#chain + 1] = f
            last_chain_line = entries[k].line
            prev = f
            k = k + 1
        end
        local outer = chain[#chain]
        local ok = #chain >= 3 and outer.parent and outer.parent.kind == "control"
        local has_with = false
        for _, f in ipairs(chain) do if f.kind == 'with' then has_with = true end end
        if ok and has_with then
            -- C[1] is the outermost link
            local C, m = {}, #chain
            for j = 1, m do C[j] = chain[m - j + 1] end
            local opener_line, header_line = {}, {}
            for j = 1, m do
                local o = C[j].kind == 'with' and C[j].open or header_end(tokens, C[j])
                header_line[j] = tokens[o][3]
                -- the header must end its line, and the line must start the statement
                local list = sig_on[header_line[j]]
                if list[#list] ~= o then ok = false end
                opener_line[j] = tokens[C[j].open][3]
                if opener_line[j] ~= header_line[j] and C[j].kind == 'with' then ok = false end
            end
            local last_line = last_chain_line
            if ok then
                -- bodies: a lambda link holds nothing but the next link
                for j = 1, m - 1 do
                    if C[j].kind == 'lambda' then
                        for l = header_line[j] + 1, opener_line[j + 1] - 1 do
                            if lines[l]:match('%S') then ok = false end
                        end
                    end
                end
            end
            if ok then
                local base = indent_of(opener_line[1])
                local level, seen_with = { base }, C[1].kind == 'with'
                for j = 2, m do
                    local step = 0
                    if C[j].kind == 'with' and not seen_with and C[j - 1].kind == 'lambda' then step = #unit end
                    if C[j].kind == 'with' then seen_with = true end
                    level[j] = level[j - 1] + step
                end
                local first_closer = first_line
                local new_indent = {}                -- line -> target indent of the first line of its segment
                local segments = {}
                local function segment(from, to, target)
                    if from > to then return end
                    local lead
                    for l = from, to do if lines[l]:match('%S') then lead = l; break end end
                    if not lead then return end
                    segments[#segments + 1] = { from = from, to = to, shift = target - indent_of(lead) }
                end
                for j = 1, m do
                    segment(header_line[j], header_line[j], level[j])   -- the link's own line
                    local stop = (j < m) and (opener_line[j + 1] - 1) or (first_closer - 1)
                    segment(header_line[j] + 1, stop, level[j] + #unit)  -- siblings or the innermost body
                end
                edits[#edits + 1] = { segments = segments, closers = { first_line, last_line }, base = base }
            end
        end
    end
    if #edits == 0 then return source end
    local result = {}
    for i, l in ipairs(lines) do result[i] = l end
    for _, e in ipairs(edits) do                     -- bottom-up, so earlier line numbers hold
        for _, sgm in ipairs(e.segments) do
            for l = sgm.from, sgm.to do
                if result[l]:match('%S') then
                    local width = math.max(0, #(result[l]:match('^ *')) + sgm.shift)
                    result[l] = (' '):rep(width) .. result[l]:gsub('^ *', '')
                end
            end
        end
        for l = e.closers[1], e.closers[2] do result[l] = false end
        result[e.closers[1]] = (' '):rep(e.base) .. 'endall'
    end
    local out = {}
    for _, l in ipairs(result) do if l then out[#out + 1] = l end end
    local folded = table.concat(out, '\n') .. '\n'
    -- the macro must read the folded text back as the same program
    local function normal(text)
        local parts = {}
        for _, tk in ipairs(lexer.scan_raw_tokenlist(text)) do
            if tk[1] ~= 'space' and tk[1] ~= 'comment' then parts[#parts + 1] = tk[2] end
        end
        return table.concat(parts, '\0')
    end
    if normal(M.expand(folded, true, true)) ~= normal(M.expand(source, true, true)) then return source end
    return folded
end

return M
