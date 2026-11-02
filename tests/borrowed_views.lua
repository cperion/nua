-- Scoped foreign/Grow loans must survive specialization without becoming raw views.
local root = arg[0]:match('^(.*)/tests/[^/]*$') or '.'
package.path = root .. '/?.lua;' .. package.path
local nua = require 'nua'
local stage = require 'nua.stage'
local passed, failed = 0, 0
local prefix = [[
local Optional = oneof { some: Str, none: Unit }
local Box = struct { text: Optional }
local identity = do(text: Str): Str = text
local length = do(text: Str): U32 = text.length
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
local function tail_length(text: Str, count: U32): U32
    if count == 0 then return text.length end
    return tail_length(text, count - 1)
end
local entry = do(p: Ptr U8, q: Ptr U8, n: U32, flag: Bool): U32
    local kept: Str = ""
]]
local suffix = [[
    return 0
end
export entry
]]
local rejected = {
    { 'direct text assignment', [[view_of(p, n, do(xs) kept = Str.of xs end)]], 'cannot be stored' },
    { 'subview assignment', [[view_of(p, n, do(xs) kept = Str.of(xs):sub(0, n) end)]], 'cannot be stored' },
    { 'dynamic retains provenance', [[view_of(p, n, do(xs) kept = dynamic(Str.of xs) end)]], 'cannot be stored' },
    { 'inline branch result', [[view_of(p, n, do(xs) kept = choose(Str.of xs, flag) end)]], 'cannot be stored' },
    { 'materialized identity', [[view_of(p, n, do(xs) kept = call identity(Str.of xs) end)]], 'native function boundary' },
    { 'cached materialized identity', [[
        local raw = Str.of(Slice(p, n))
        local first = call identity raw
        view_of(p, n, do(xs) kept = call identity(Str.of xs) end)
    ]], 'native function boundary' },
    { 'materialized scalar consumer', [[view_of(p, n, do(xs) local size = call length(Str.of xs) end)]], 'native function boundary' },
    { 'materialized output reference', [[view_of(p, n, do(xs) call stash(Str.of xs, Ref kept) end)]], 'native function boundary' },
    { 'function pointer', [[
        local f = fnptr identity
        view_of(p, n, do(xs) kept = f(Str.of xs) end)
    ]], 'native function boundary' },
    { 'opaque foreign call', [[
        local echo = extern("foreign_echo", { Str }, Str)
        view_of(p, n, do(xs) kept = echo(Str.of xs) end)
    ]], 'native function boundary' },
    { 'captured loan in native function', [[
        view_of(p, n, do(xs)
            local text = Str.of xs
            local get = do(): U32 = text.length
            local size = call get()
        end)
    ]], 'native function boundary' },
    { 'direct return', [[local saved = view_of(p, n, do(xs) return Str.of xs end)]], 'cannot outlive its activity' },
    { 'sum return', [[local saved = view_of(p, n, do(xs) return Optional.some(Str.of xs) end)]], 'cannot outlive its activity' },
    { 'record containing a sum return', [[
        local saved = view_of(p, n, do(xs) return Box { text = Optional.some(Str.of xs) } end)
    ]], 'cannot outlive its activity' },
    { 'dynamic sum result', [[
        view_of(p, n, do(xs)
            local optional = choose_optional(Str.of xs, flag)
            kept = optional { some = do(text) return text end, none = do() return Str "" end }
        end)
    ]], 'cannot be stored' },
    { 'immediate matched payload join', [[
        view_of(p, n, do(xs)
            choose_some(Str.of xs, flag) {
                some = do(text) kept = text end,
                none = do end,
            }
        end)
    ]], 'cannot be stored' },
    { 'residual tail-loop result', [[view_of(p, n, do(xs) kept = tail_view(Str.of xs, n) end)]], 'cannot be stored' },
    { 'Grow text assignment', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        bytes:view() do(xs) kept = Str.of xs end
    ]], 'cannot be stored' },
    { 'Grow dynamic text assignment', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        bytes:view() do(xs) kept = dynamic(Str.of xs) end
    ]], 'cannot be stored' },
    { 'Grow materialized call', [[
        local bytes = (Grow U8) {}
        bytes:push 65
        bytes:view() do(xs) local size = call length(Str.of xs) end
    ]], 'native function boundary' },
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
    { 'StrMap key at a native boundary', [[
        local map = StrMap(U32) {}
        map:put("key", 1)
        map:each do(key, value) local size = call length key end
    ]], 'native function boundary' },
    { 'known call memo cannot strip a loan', [[
        local raw = Str "abc"
        local first = identity raw
        view_of(rawmember(raw, "ptr"), raw.length, do(xs) kept = identity(Str.of xs) end)
    ]], 'cannot be stored' },
    { 'inner loan in a merged result', [[
        view_of(p, n, do(outer)
            local selected = view_of(q, n, do(inner)
                if flag then return Str.of outer end
                return Str.of inner
            end)
        end)
    ]], 'cannot outlive its activity' },
    { 'different loans across a residual backedge', [[
        local function rotate(a: Str, b: Str, count: U32): Str
            if count == 0 then return a end
            return rotate(b, a, count - 1)
        end
        view_of(p, n, do(outer)
            view_of(q, n, do(inner)
                local selected = rotate(Str.of outer, Str.of inner, n)
            end)
        end)
    ]], 'provenance cannot change' },
}
for _, operation in ipairs { 'saved.length', 'saved[0]', 'saved:equals "x"',
    'saved:sub(0, 0)', 'Str.of saved', 'dynamic saved', 'rawmember(saved, "ptr")' } do
    rejected[#rejected + 1] = { 'expired text: ' .. operation,
        'local saved = {}\nview_of(p, n, do(xs) saved.text = Str.of xs end)\nlocal used = '
            .. operation:gsub('saved', 'saved.text'),
        'after its activity ends' }
end
local accepted = {
    { 'inferred aliases and scalar copies', [[
        local size: U32 = 0
        view_of(p, n, do(xs)
            local text = Str.of xs
            local alias = identity text
            size = alias.length
        end)
        kept = "independent"
    ]] },
    { 'owned Chars copy', [[
        local saved = Chars 32 ()
        view_of(p, n, do(xs) saved = Chars 32 (Str.of xs) end)
        local size = saved.length
    ]] },
    { 'owned Text copy', [[
        local saved = Text {}
        view_of(p, n, do(xs) saved:write(Str.of xs) end)
        local size = saved.length
    ]] },
    { 'owned value crosses a native boundary', [[
        local size = do(text: Chars 32): U32 = text.length
        local saved = Chars 32 ()
        view_of(p, n, do(xs) saved = Chars 32 (Str.of xs) end)
        local result = call size saved
    ]] },
    { 'scalar crosses a native boundary inside a loan', [[
        local twice = do(value: U32): U32 = value * 2
        view_of(p, n, do(xs) local result = call twice(xs.length) end)
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
        view_of(p, n, do(xs)
            local text = Str.of xs
            kept = Str.of(Slice(rawmember(text, "ptr"), text.length))
        end)
    ]] },
    { 'independent literal result', [[kept = view_of(p, n, do(xs) return Str "independent" end)]] },
    { 'outer loan may pass through an inner activity', [[
        view_of(p, n, do(outer)
            local text = view_of(q, n, do(inner) return Str.of outer end)
            local size = text.length
        end)
    ]] },
    { 'same loan through a residual tail loop', [[
        view_of(p, n, do(xs) local size = tail_length(Str.of xs, n) end)
    ]] },
    { 'scalar extracted from a sum is independent', [[
        local size: U32 = 0
        view_of(p, n, do(xs)
            size = choose_optional(Str.of xs, flag) {
                some = do(text) return text.length end,
                none = do() return U32 0 end,
            }
        end)
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
