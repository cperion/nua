-- Borrows (foreign loans, owner views) follow one lifetime rule through specialization.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local nua = require 'nua'
local stage = require 'nua.stage'
local passed, failed = 0, 0
local prefix = [[
local Optional = oneof { some: Str, none: Unit }
local Box = struct { text: Optional }
local identity = do(text: Str): Str = text
local length = do(text: Str): U64 = text.length
local stash = do(text: Str, target: Ref Str): Unit
    target = text
end
local choose = do(text: Str, flag: Bool): Str
    if flag then return text end
    return ""
end
local choose_optional = do(text: Str, flag: Bool): Optional
    if flag then return Optional.some text end
    return Optional.none()
end
local choose_some = do(text: Str, flag: Bool): Optional
    if flag then return Optional.some(text:sub(0, 0)) end
    return Optional.some text
end
local function tail_view(text: Str, count: U32): Str
    if count == 0 then return text end
    return tail_view(text, count - 1)
end
local function tail_length(text: Str, count: U32): U64
    if count == 0 then return text.length end
    return tail_length(text, count - 1)
end
local Token = struct { text: Str, kind: U32 }
local leak = do(): Str
    local c = Chars(8) "ab"
    return c:str()
end
local wipe = do(t: Ref Text): Unit
    t:clear()
end
local append = do(t: Ref Text): Unit
    t:write "b"
end
local fill_grow = do(target: Ref Str, wrap: Bool): Unit
    local bytes = (Grow U8) {}
    bytes:push 65
    if wrap then target = dynamic(Str.of(bytes:all())) else target = Str.of(bytes:all()) end
end
local fill_token = do(target: Ref Token, whole: Bool): Unit
    local c = Chars(8) "ab"
    if whole then target = Token { text = c:str(), kind = 1 } else target.text = c:str() end
end
local RefBox = struct { r: Ref U32 }
local hold_local = do(target: Ref RefBox): Unit
    local v: U32 = 1
    target.r = Ref v
end
local escape_box = do(): RefBox
    local v: U32 = 1
    return RefBox { r = Ref v }
end
local pick_ref = do(r: Ref U32): Ref U32 = r
local gref = global(Ref U32, {})
local entry = do(p: Ptr U8, q: Ptr U8, n: U32, flag: Bool): U32
    local kept: Str = ""
    local outer = Token { text = "", kind = 0 }
    local cell: U32 = 0
    local box = RefBox { r = Ref cell }
]]
local suffix = [[
    return 0
end
export entry
]]
local rejected = {
    { 'direct text assignment', [[view_of(p, n) do(xs) kept = Str.of xs end]], 'cannot be stored' },
    { 'subview assignment', [[view_of(p, n) do(xs) kept = Str.of(xs):sub(0, n) end]], 'cannot be stored' },
    { 'dynamic retains provenance', [[view_of(p, n) do(xs) kept = dynamic(Str.of xs) end]], 'cannot be stored' },
    { 'inline branch result', [[view_of(p, n) do(xs) kept = choose(Str.of xs, flag) end]], 'cannot be stored' },
    { 'materialized identity', [[view_of(p, n) do(xs) kept = call identity(Str.of xs) end]], 'cannot be stored' },
    { 'cached materialized identity', [[
        local raw = Str.of(Slice(p, n))
        local first = call identity raw
        view_of(p, n) do(xs) kept = call identity(Str.of xs) end
    ]], 'cannot be stored' },
    { 'materialized output reference', [[view_of(p, n) do(xs) call stash(Str.of xs, Ref kept) end]], 'cannot be stored in' },
    { 'function pointer', [[
        local f = fnptr identity
        view_of(p, n) do(xs) kept = f(Str.of xs) end
    ]], 'native function boundary' },
    { 'opaque foreign call', [[
        local echo = extern("foreign_echo", { Str }, Str)
        view_of(p, n) do(xs) kept = echo(Str.of xs) end
    ]], 'native function boundary' },
    { 'captured loan in native function', [[
        view_of(p, n) do(xs)
            local text = Str.of xs
            local get = do(): U64 = text.length
            local size = call get()
        end
    ]], 'native function boundary' },
    { 'direct return', [[local saved = view_of(p, n) do(xs) return Str.of xs end]], 'cannot outlive its activity' },
    { 'sum return', [[local saved = view_of(p, n) do(xs) return Optional.some(Str.of xs) end]], 'cannot outlive its activity' },
    { 'record containing a sum return', [[
        local saved = view_of(p, n) do(xs) return Box { text = Optional.some(Str.of xs) } end
    ]], 'cannot outlive its activity' },
    { 'dynamic sum result', [[
        view_of(p, n) do(xs)
            local optional = choose_optional(Str.of xs, flag)
            kept = optional { some = do(text) return text end, none = do() return Str "" end }
        end
    ]], 'cannot be stored' },
    { 'immediate matched payload join', [[
        view_of(p, n) do(xs)
            choose_some(Str.of xs, flag) {
                some = do(text) kept = text end,
                none = do end,
            }
        end
    ]], 'cannot be stored' },
    { 'residual tail-loop result', [[view_of(p, n) do(xs) kept = tail_view(Str.of xs, n) end]], 'cannot be stored' },
    { 'Grow text assignment', [[fill_grow(Ref kept, false)]], 'cannot be stored' },
    { 'Grow dynamic text assignment', [[fill_grow(Ref kept, true)]], 'cannot be stored' },
    { 'Grow borrow used after clear', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        local xs = bytes:all()
        bytes:clear()
        local size = xs.length
    ]], 'used after' },
    { 'Text borrow used after clear', [[
        local out = Text {}
        out:write "abc"
        local s = out:str()
        out:clear()
        local size = s.length
    ]], 'used after' },
    { 'borrow used after a call that may clear', [[
        local out = Text {}
        out:write "abc"
        local s = out:str()
        call wipe(Ref out)
        local size = s.length
    ]], 'used after' },
    { 'word returns a borrow of its own local', [[local s = leak()]], 'returns a borrow of its own local' },
    { 'function returns a borrow of its own local', [[local s = call leak()]], 'returns a borrow' },
    { 'borrow stored in an outer record', [[fill_token(Ref outer, true)]], 'cannot be stored' },
    { 'reference to a word local stored in the caller\'s record', [[hold_local(Ref box)]], 'cannot be stored' },
    { 'record holding a reference to a word local returned', [[local held = escape_box()]],
        'returns a borrow of its own local' },
    { 'reference to a local stored in a global', [[gref[0] = Ref cell]], 'cannot be stored' },
    { 'reference to a Grow element used after clear', [[
        local cells = Grow(U32) {}
        cells:push 1
        local r: Ref U32 = Ref cells[0]
        cells:clear()
        local v: U32 = r
    ]], 'used after' },
    { 'borrow stored in an outer record field', [[fill_token(Ref outer, false)]], 'cannot be stored' },
    { 'StrMap key assignment', [[
        local map = StrMap(U32) {}
        map:put("key", 1)
        map:each do(key, value) kept = key end
    ]], 'cannot be stored' },
    { 'StrMap dynamic key assignment', [[
        local map = StrMap(U32) {}
        map:put("key", 1)
        map:each do(key, value) kept = dynamic key end
    ]], 'cannot be stored' },
    { 'known call memo cannot strip a loan', [[
        local raw = Str "abc"
        local first = identity raw
        view_of(rawmember(raw, "ptr"), raw.length) do(xs) kept = identity(Str.of xs) end
    ]], 'cannot be stored' },
    { 'inner loan in a merged result', [[
        view_of(p, n) do(outer)
            local selected = view_of(q, n) do(inner)
                if flag then return Str.of outer end
                return Str.of inner
            end
        end
    ]], 'cannot outlive its activity' },
    { 'different loans across a residual backedge', [[
        local function rotate(a: Str, b: Str, count: U32): Str
            if count == 0 then return a end
            return rotate(b, a, count - 1)
        end
        view_of(p, n) do(outer)
            view_of(q, n) do(inner)
                local selected = rotate(Str.of outer, Str.of inner, n)
            end
        end
    ]], 'provenance cannot change' },
}
for _, operation in ipairs { 'saved.length', 'saved[0]', 'saved:equals "x"',
    'saved:sub(0, 0)', 'Str.of saved', 'dynamic saved', 'rawmember(saved, "ptr")' } do
    rejected[#rejected + 1] = { 'expired text: ' .. operation,
        'local saved = {}\nview_of(p, n) do(xs) saved.text = Str.of xs end\nlocal used = '
            .. operation:gsub('saved', 'saved.text'),
        'after its activity ends' }
end
local accepted = {
    { 'materialized scalar consumer', [[view_of(p, n) do(xs) local size = call length(Str.of xs) end]] },
    { 'Grow materialized call', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        local size = call length(Str.of(bytes:all()))
    ]] },
    { 'StrMap key at a native boundary', [[
        local map = StrMap(U32) {}
        map:put("key", 1)
        map:each do(key, value) local size = call length key end
    ]] },
    { 'Grow grows while borrowed', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        local xs = bytes:all()
        bytes:push 66
        local size = xs.length
    ]] },
    { 'clear after the last use of a borrow', [[
        local out = Text {}
        out:write "abc"
        local s = out:str()
        local size = s.length
        out:clear()
        out:write "d"
        local again = out:str()
        local later = again.length
    ]] },
    { 'a call that only appends keeps borrows', [[
        local out = Text {}
        out:write "a"
        local s = out:str()
        call append(Ref out)
        local size = s.length
    ]] },
    { 'borrow in a record declared after its owner', [[
        local c = Chars(8) "ab"
        local token = Token { text = c:str(), kind = 1 }
        local size = token.text.length
    ]] },
    { 'materialized identity keeps the argument owner', [[
        local c = Chars(8) "ab"
        local same = call identity(c:str())
        local size = same.length
    ]] },
    { 'reference to a Grow survives clearing it', [[
        local bytes = Grow(U8) {}
        local r: Ref (Grow U8) = Ref bytes
        bytes:clear()
        r:push 1
    ]] },
    { 'function compiled on its own returns a reference to its argument', [[
        local r: Ref U32 = call pick_ref(Ref cell)
        r = 5
    ]] },
    { 'reference rebound in place and stored in a later record', [[
        local other: U32 = 1
        local r: Ref U32 = Ref cell
        r = Ref other
        local later = RefBox { r = r }
        later.r = 3
    ]] },
    { 'same-scope holder declared before its owner', [[
        local holder: Str = ""
        local c = Chars(8) "ab"
        holder = c:str()
        local size = holder.length
    ]] },
    { 'inferred aliases and scalar copies', [[
        local size: U64 = 0
        view_of(p, n) do(xs)
            local text = Str.of xs
            local alias = identity text
            size = alias.length
        end
        kept = "independent"
    ]] },
    { 'owned Chars copy', [[
        local saved = Chars 32 ()
        view_of(p, n) do(xs) saved = Chars 32 (Str.of xs) end
        local size = saved.length
    ]] },
    { 'owned Text copy', [[
        local saved = Text {}
        view_of(p, n) do(xs) saved:write(Str.of xs) end
        local size = saved.length
    ]] },
    { 'owned value crosses a native boundary', [[
        local size = do(text: Chars 32): U64 = text.length
        local saved = Chars 32 ()
        view_of(p, n) do(xs) saved = Chars 32 (Str.of xs) end
        local result = call size saved
    ]] },
    { 'scalar crosses a native boundary inside a loan', [[
        local twice = do(value: U64): U64 = value * 2
        view_of(p, n) do(xs) local result = call twice(xs.length) end
    ]] },
    { 'StrMap key copied into owned storage', [[
        local map = StrMap(U32) {}
        map:put("key", 1)
        local owned = Chars 32 ()
        map:each do(key, value) owned = Chars 32 key end
        local size = owned.length
    ]] },
    { 'raw slice remains a trusted boundary', [[kept = Str.of(Slice(p, n))]] },
    { 'explicit raw pointer extraction remains trusted', [[
        view_of(p, n) do(xs)
            local text = Str.of xs
            kept = Str.of(Slice(rawmember(text, "ptr"), text.length))
        end
    ]] },
    { 'independent literal result', [[kept = view_of(p, n) do(xs) return Str "independent" end]] },
    { 'outer loan may pass through an inner activity', [[
        view_of(p, n) do(outer)
            local text = view_of(q, n) do(inner) return Str.of outer end
            local size = text.length
        end
    ]] },
    { 'same loan through a residual tail loop', [[
        view_of(p, n) do(xs) local size = tail_length(Str.of xs, n) end
    ]] },
    { 'scalar extracted from a sum is independent', [[
        local size: U64 = 0
        view_of(p, n) do(xs)
            size = choose_optional(Str.of xs, flag) {
                some = do(text) return text.length end,
                none = do() return U64 0 end,
            }
        end
    ]] },
}
local function run(case, reject, index)
    local source = prefix .. case[2] .. '\n' .. suffix
    local path = root .. '/build/tmp/borrowed-view-' .. index .. '.nua'
    local ok, result = pcall(nua.compile, source, path, { no_c = true })
    local correct = reject and not ok and tostring(result):find(case[3], 1, true) or not reject and ok
    if correct and stage.builder() == nil then passed = passed + 1
    else
        failed = failed + 1
        print('FAIL borrowed view: ' .. case[1] .. '\n' .. tostring(result))
    end
end
for i, case in ipairs(rejected) do run(case, true, i) end
for i, case in ipairs(accepted) do run(case, false, #rejected + i) end
-- Independent scalar results must be read before a foreign owner's cleanup,
-- even when a Lua staging continuation does not bind its own arguments.
local binding_path = root .. '/tests/foreign_result_binding.nua'
local binding_file = assert(io.open(binding_path))
local binding_source = binding_file:read '*a'; binding_file:close()
local binding_c = nua.compile(binding_source, binding_path)
local binding_body = binding_c:match('foreign_byte%b()%s*(%b{})') or ''
local read_at, free_at = binding_body:find('pointer[', 1, true), binding_body:find('free(', 1, true)
if read_at and free_at and read_at < free_at then passed = passed + 1
else failed = failed + 1; print('FAIL borrowed view: scalar read before cleanup\n' .. binding_c) end

print(('%d borrowed-view checks passed, %d failed'):format(passed, failed))
assert(failed == 0)
