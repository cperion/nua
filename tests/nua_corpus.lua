-- Nua's sources through Mua with Nua's host: every tracked .lua and .nua file round-trips
-- through Mua's lexer, parses (Nua forms with the host's statements and prefixes), and what
-- it translates to compiles under LuaJIT. Mua's own tests are in the Mua repository.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. root .. '/.local/share/lua/5.1/?.lua;' .. package.path
local lex = require 'mua.lex'
local parse = require 'mua.parse'

local passed, failed = 0, 0
local function check(name, ok, detail)
    if ok then passed = passed + 1
    else failed = failed + 1; print('FAIL  corpus: ' .. name .. (detail and ('\n' .. tostring(detail)) or '')) end
end

-- every tracked source: the round trip is exact, and every number and string token is one
-- LuaJIT reads the same way
local function sh(cmd)
    local p = assert(io.popen(cmd)); local out = p:read '*a'; p:close(); return out
end
local files = {}
for f in sh('cd ' .. root .. ' && git ls-files "*.lua" "*.nua" 2>/dev/null'):gmatch '[^\n]+' do
    files[#files + 1] = f
end
local sources, literals = 0, 0
for _, f in ipairs(files) do
    local fh = io.open(root .. '/' .. f, 'rb')
    if fh then
        local src = fh:read '*a'; fh:close()
        local ok, ts = pcall(lex.scan, src, f)
        if not ok then
            check('scans ' .. f, false, ts)
        else
            check('round trip ' .. f, lex.text(ts) == src)
            sources = sources + 1
            for _, tk in ipairs(ts) do
                if tk.t == 'number' or tk.t == 'string' then
                    literals = literals + 1
                    local chunk = loadstring('return ' .. tk.v)
                    if not chunk then check(('LuaJIT reads %s:%d %s'):format(f, tk.line, tk.v), false) end
                end
            end
        end
    end
end
check('sources were found', sources > 100, sources)

-- every tracked source parses, except these, which do not by design: fixtures of failures
local NOT_MUA = { ['tests/modules/broken.nua'] = true }
local host = { statements = { export = function(p, tk)
    local r = p.r
    r:next()
    local n = r:name('after export')
    while r:accept('.') do r:name('after export') end
    if r:peek(1).t == 'name' and r:peek(1).v == 'as' and not r:peek(1).nl then r:next(); r:next() end
    return { k = 'export', name = n.v, line = tk.line }
end }, prefixes = { call = function(p, tk)
    local nt = p.r:peek(2)
    if nt.t == 'name' and not nt.nl then p.r:next(); local e = p:suffixed(); e.boundary = true; return e end
end } }
local parsed = 0
for _, f in ipairs(files) do
    if not NOT_MUA[f] and not f:match '^nua/experiments/' then
        local fh = io.open(root .. '/' .. f, 'rb')
        if fh then
            local src = fh:read '*a'; fh:close()
            local ok, e = pcall(parse.parse, src, f, f:match '%.nua$' and host or nil)
            if ok then parsed = parsed + 1 else check('parses ' .. f, false, e) end
        end
    end
end
check('sources were parsed', parsed > 100, parsed)

-- every parsed source translates to Lua that LuaJIT compiles (typed forms without the Nua host
-- are emitted with their annotations dropped; `export` gets a stub)
host.statements_emit = nil
local emit_host = { emit_statements = { export = function(node) return '-- export ' .. node.name end } }
local compiled = 0
for _, f in ipairs(files) do
    if not NOT_MUA[f] and not f:match '^nua/experiments/' then
        local fh = io.open(root .. '/' .. f, 'rb')
        if fh then
            local src = fh:read '*a'; fh:close()
            local ok, text = pcall(function()
                local block = parse.parse(src, f, f:match '%.nua$' and host or nil)
                return require('mua.emit').emit(block, { filename = f, host = emit_host })
            end)
            if not ok then check('translates ' .. f, false, text)
            else
                local chunk, err = loadstring(text, '@' .. f)
                if chunk then compiled = compiled + 1 else check('LuaJIT compiles ' .. f, false, err) end
            end
        end
    end
end
check('sources were compiled', compiled == parsed, compiled .. ' of ' .. parsed)

print(('corpus: %d passed, %d failed (%d sources round-tripped, %d literals cross-checked, %d parsed, %d compiled)'):format(
    passed, failed, sources, literals, parsed, compiled))
os.exit(failed == 0 and 0 or 1)
