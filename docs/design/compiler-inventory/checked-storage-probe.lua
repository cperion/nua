-- A safe-library design witness and focused rejection checks, staging only.
-- Run from the repository root: luajit docs/design/compiler-inventory/checked-storage-probe.lua
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local prefix = [[
local slots_of = require "examples.checked_storage.slots"
local slots = slots_of Text
local Slots = slots.Slots
]]
local cases = {
    { name = 'construct_borrow_replace_reuse_copy_move', body = [[
local words = Slots {}
local first = slots.build (Ref words) (Text {}) do(text)
    text:write "first"
    return
end
local second = slots.add (Ref words) (copy "second")
local before = U64 0
slots.borrow (Ref words) first do(text) before = text:str().length end
slots.replace (Ref words) first (copy "replacement")
slots.remove (Ref words) second
local reused = slots.add (Ref words) (copy "reused")
local duplicate = copy words
local moved = duplicate
local total = before
slots.borrow (Ref words) reused do(text) total = total + text:str().length end
slots.borrow (Ref moved) first do(text) total = total + text:str().length end
return total
]] },
    { name = 'shared_boundary_writer', body = [[
local append = do(text: Ref Text): Unit
    text:write "!"
end
local words = Slots {}
local i = slots.add (Ref words) (Text {})
slots.borrow (Ref words) i do(text) call append text end
local local_text = Text {}
call append (Ref local_text)
local size = local_text.length
slots.borrow (Ref words) i do(text) size = size + text:str().length end
return size
]] },
    { name = 'borrow_after_removal', reject = 'used after', body = [[
local words = Slots {}
local i = slots.add (Ref words) (copy "old")
local view: Str = ""
slots.borrow (Ref words) i do(text) view = text:str() end
slots.remove (Ref words) i
return view.length
]] },
    { name = 'borrow_after_reuse', reject = 'used after', body = [[
local words = Slots {}
local i = slots.add (Ref words) (copy "old")
local view: Str = ""
slots.borrow (Ref words) i do(text) view = text:str() end
slots.remove (Ref words) i
slots.replace (Ref words) i (copy "new")
return view.length
]] },
    { name = 'borrow_after_nested_growth', reject = 'used after', body = [[
local words = Slots {}
local i = slots.add (Ref words) (copy "old")
local size = U64 0
slots.borrow (Ref words) i do(text)
    local view = text:str()
    text:write "more"
    size = view.length
end
return size
]] },
    { name = 'use_after_owner_move', reject = 'was moved', body = [[
local words = Slots {}
local i = slots.add (Ref words) (Text {})
local moved = words
slots.borrow (Ref words) i do(text) text:write "invalid" end
return U64 0
]] },
    { name = 'borrow_escapes_local', reject = 'returns a borrow', source = prefix .. [[
local leak = do(): Str
    local words = Slots {}
    local i = slots.add (Ref words) (copy "local")
    local view: Str = ""
    slots.borrow (Ref words) i do(text) view = text:str() end
    return view
end
local entry = do(): U64 = leak().length
export entry
]] },
}
local policy = S.call_policy
local ok, err = pcall(function()
    S.call_policy = 'written'
    local accepted, rejected, failed = 0, 0, 0
    for _, case in ipairs(cases) do
        local source = case.source or (prefix .. '\nlocal entry = do(): U64\n' .. case.body .. '\nend\nexport entry\n')
        local success, result = pcall(function()
            local c, module = nua.compile(source, 'checked_storage_' .. case.name .. '.nua', { no_c = true })
            assert(c == nil, 'must not emit C')
            return module
        end)
        local expected = case.reject and not success and tostring(result):find(case.reject, 1, true)
            or not case.reject and success
        print(('CASE %s: %s'):format(case.name, expected and 'expected staging outcome' or 'FAIL'))
        if not success then print(tostring(result)) end
        if not expected then failed = failed + 1
        elseif case.reject then rejected = rejected + 1
        else accepted = accepted + 1 end
    end
    print(('Staging: %d completed, %d expected rejections, %d failures; no native execution.'):format(accepted, rejected, failed))
    assert(failed == 0, 'design witness has unexpected outcomes')
end)
S.call_policy = policy
if not ok then error(err, 0) end
