-- dialect.lex: the Lua dialect's lexer (design macro-layer.md §4.1). Plain Lua, no
-- dependencies, written for this project.
--
-- scan(source, filename) returns the tokens of a source, each { t, v, line, col, pos }:
--   t     the kind: 'name', 'keyword', 'number', 'string', 'comment', 'space', 'shebang',
--         'eof', or an operator's or punctuation's own text ('(', '..', '...', '==', '::')
--   v     the exact source text of the token
--   line  the line it starts on (from 1); col its byte column (from 1); pos its byte offset
-- Concatenating every token's v gives the source back, byte for byte: spacing and comments
-- are tokens, so source tools keep them. The last token is 'eof' (empty text).
--
-- The token rules are LuaJIT's, the build the project pins, which carries LuaJIT 3.0's syntax
-- backport (design macro-layer.md L1): names may use bytes 0x80-0xFF; `goto` is a keyword
-- (`const` and `continue` are soft keywords: names to the lexer); the operators include
-- `! != && || ? ?. ?? -> ~ & | << >> ~>>` and the compound assignments `+= -= *= /= %= &= |=
-- <<= >>= ~>>= ..=` (`~=` stays one token: the parser tells xor-assignment from "not equal");
-- a line `# n "name"` starting in column 1 is a line directive; a number
-- is read greedily (digits, letters, `_`, `.`, and a sign after an exponent letter) and then
-- validated (`_` is ignored after the first digit, `0b` is binary), so `42ULL`, `0x1p4`, `3i`,
-- `1_000`, `0b101` are one token and `1..x` is a malformed number, as in LuaJIT; a line break
-- is \n, \r, \r\n or \n\r.

local M = {}

local KEYWORDS = {}
for w in ([[and break do else elseif end false for function goto if in local nil not or
repeat return then true until while]]):gmatch '%S+' do KEYWORDS[w] = true end
M.keywords = KEYWORDS

-- operators and punctuation, longest first within each leading byte
local OPERATORS = {
    ['.'] = { '..=', '...', '..', '.' }, ['='] = { '==', '=' }, ['~'] = { '~>>=', '~>>', '~=', '~' },
    ['<'] = { '<<=', '<<', '<=', '<' }, ['>'] = { '>>=', '>>', '>=', '>' }, [':'] = { '::', ':' },
    ['!'] = { '!=', '!' }, ['&'] = { '&&', '&=', '&' }, ['|'] = { '||', '|=', '|' },
    ['?'] = { '?.', '??', '?' }, ['-'] = { '->', '-=', '-' }, ['+'] = { '+=', '+' },
    ['*'] = { '*=', '*' }, ['/'] = { '/=', '/' }, ['%'] = { '%=', '%' },
}
for c in ('^#;,(){}[]'):gmatch '.' do OPERATORS[c] = { c } end

local function err(filename, line, col, msg)
    error(('%s:%d:%d: %s'):format(filename or '?', line, col, msg), 0)
end

-- a number's text is valid Lua (LuaJIT): decimal or hex, optional fraction and exponent,
-- an optional integer suffix (LL, ULL) or imaginary suffix (i)
local function valid_number(text)
    local body, suffix = text, nil
    for _, sfx in ipairs { 'ull', 'll', 'i' } do
        if #body > #sfx and body:sub(-#sfx):lower() == sfx then
            body, suffix = body:sub(1, -#sfx - 1), sfx
            break
        end
    end
    body = body:sub(1, 1) .. body:sub(2):gsub('_', '')      -- `_` is ignored after the first digit
    local bin = body:match '^0[bB](.*)$'
    if bin then return bin:match '^[01]+$' ~= nil end
    local digits, exp_pattern = '%d', '^[eE][+-]?%d+$'
    local hex = body:match '^0[xX](.*)$'
    if hex then body, digits, exp_pattern = hex, '%x', '^[pP][+-]?%d+$' end
    local int, dot, frac, exp = body:match('^(' .. digits .. '*)(%.?)(' .. digits .. '*)(.*)$')
    if not int or (int == '' and frac == '') then return false end
    if exp ~= '' and not exp:match(exp_pattern) then return false end
    -- the integer suffixes take integers only
    if suffix and suffix ~= 'i' and (dot ~= '' or exp ~= '') then return false end
    return true
end
M.valid_number = valid_number

-- the end of a long bracket opened at i (`[`, `=` x level, `[`): returns the position of its
-- last byte, or nil when it is not closed
local function long_end(src, i, level)
    local close = ']' .. ('='):rep(level) .. ']'
    local _, stop = src:find(close, i, true)
    return stop
end

-- the level of a long bracket opening at i, or nil when the bytes at i do not open one
local function long_open(src, i)
    local eq = src:match('^%[(=*)%[', i)
    if eq then return #eq end
end

function M.scan(src, filename)
    local tokens, n = {}, 0
    local i, len = 1, #src
    local line, line_start = 1, 1
    local function push(t, stop)
        n = n + 1
        tokens[n] = { t = t, v = src:sub(i, stop), line = line, col = i - line_start + 1, pos = i }
    end
    -- count the line breaks in src[a..b] and move line/line_start past them
    local function lines(a, b)
        local k = a
        while k <= b do
            local c = src:byte(k)
            if c == 10 or c == 13 then
                local d = src:byte(k + 1)
                if k < b and ((c == 10 and d == 13) or (c == 13 and d == 10)) then k = k + 1 end
                line, line_start = line + 1, k + 1
            end
            k = k + 1
        end
    end
    -- a first line `#!...` is skipped by Lua's file loader; it is kept as a token
    if src:sub(1, 2) == '#!' then
        local stop = (src:find('[\r\n]', 1) or len + 1) - 1
        push('shebang', stop)
        i = stop + 1
    end
    while i <= len do
        local c = src:sub(i, i)
        local b = src:byte(i)
        if c == '#' and i == line_start and src:find('^#[ \t]*%d', i) then
            -- a line directive: `# n "name"` in column 1 sets the line LuaJIT reports
            local stop = (src:find('[\r\n]', i) or len + 1) - 1
            push('directive', stop)
            i = stop + 1
        elseif c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == '\f' or c == '\v' then
            local stop = (src:find('[^ \t\n\r\f\v]', i) or len + 1) - 1
            push('space', stop)
            lines(i, stop)
            i = stop + 1
        elseif c == '-' and src:sub(i + 1, i + 1) == '-' then
            local level = long_open(src, i + 2)
            local stop
            if level then
                stop = long_end(src, i + 2 + level + 2, level)
                if not stop then err(filename, line, i - line_start + 1, 'unfinished long comment') end
            else
                stop = (src:find('[\r\n]', i) or len + 1) - 1
            end
            push('comment', stop)
            lines(i, stop)
            i = stop + 1
        elseif (b >= 65 and b <= 90) or (b >= 97 and b <= 122) or b == 95 or b >= 128 then
            local stop = (src:find('[^%w_\128-\255]', i) or len + 1) - 1
            local word = src:sub(i, stop)
            push(KEYWORDS[word] and 'keyword' or 'name', stop)
            i = stop + 1
        elseif (b >= 48 and b <= 57) or (c == '.' and src:find('^%d', i + 1)) then
            -- greedy, as Lua reads a number: then the whole text must be one valid number
            local k = i
            while k <= len do
                local d = src:sub(k, k)
                if d:find '[%w_.\128-\255]' then
                    k = k + 1
                elseif (d == '+' or d == '-') and src:sub(k - 1, k - 1):find(
                    src:sub(i, i + 1):lower() == '0x' and '[pP]' or '[eE]') then
                    k = k + 1
                else
                    break
                end
            end
            local text = src:sub(i, k - 1)
            if not valid_number(text) then
                err(filename, line, i - line_start + 1, "malformed number near '" .. text .. "'")
            end
            push('number', k - 1)
            i = k
        elseif c == '"' or c == "'" then
            local k = i + 1
            while true do
                local d = src:sub(k, k)
                if d == '' or d == '\n' or d == '\r' then
                    err(filename, line, i - line_start + 1, 'unfinished string')
                elseif d == '\\' then
                    local e = src:sub(k + 1, k + 1)
                    if e == '' then err(filename, line, i - line_start + 1, 'unfinished string') end
                    -- an escaped line break continues the string: \r\n or \n\r is one break
                    if (e == '\n' and src:sub(k + 2, k + 2) == '\r') or (e == '\r' and src:sub(k + 2, k + 2) == '\n') then
                        k = k + 3
                    else
                        k = k + 2
                    end
                elseif d == c then
                    break
                else
                    k = k + 1
                end
            end
            push('string', k)
            lines(i, k)
            i = k + 1
        elseif c == '[' and long_open(src, i) then
            local level = long_open(src, i)
            local stop = long_end(src, i + level + 2, level)
            if not stop then err(filename, line, i - line_start + 1, 'unfinished long string') end
            push('string', stop)
            lines(i, stop)
            i = stop + 1
        elseif c == '[' and src:find('^%[=', i) then
            err(filename, line, i - line_start + 1, 'invalid long string delimiter')
        elseif OPERATORS[c] then
            local matched
            for _, op in ipairs(OPERATORS[c]) do
                if src:sub(i, i + #op - 1) == op then matched = op break end
            end
            if not matched then err(filename, line, i - line_start + 1, "unexpected symbol near '" .. c .. "'") end
            push(matched, i + #matched - 1)
            i = i + #matched
        else
            err(filename, line, i - line_start + 1, "unexpected symbol near '" .. c .. "'")
        end
    end
    n = n + 1
    tokens[n] = { t = 'eof', v = '', line = line, col = i - line_start + 1, pos = i }
    return tokens
end

-- the source text of tokens (all of them: the round trip)
function M.text(tokens)
    local parts = {}
    for k, tk in ipairs(tokens) do parts[k] = tk.v end
    return table.concat(parts)
end

return M
