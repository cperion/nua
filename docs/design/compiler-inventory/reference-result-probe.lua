-- Required reference-result behavior, not acceptance of the current defects.
-- Exits nonzero while any required outcome is missing. Staging only.
package.path = './?.lua;./.local/share/lua/5.1/?.lua;' .. package.path
package.loaded['nua.driver_loaded'] = true
local nua = dofile('nua.lua')
local S = require 'nua.stage'
local cases = {
    { name = 'lookup_returns_checked_ref', source = [[
local slots_of = require "examples.checked_storage.slots"
local slots = slots_of Text
local Slots = slots.Slots
local entry = do(): U64
    local words = Slots {}
    local i = slots.add (Ref words) (Text {})
    local text = slots.get (Ref words) i
    return text:str().length
end
export entry
]] },
    { name = 'joined_ref_preserves_shared_storage', reject = 'used after', source = [[
local Item = struct { text: Text }
local Items = Grow Item
local choose = do(items: Ref Items, flag: Bool): Ref Text
    if flag then return Ref items[0].text end
    return Ref items[1].text
end
local entry = do(flag: Bool): U64
    local items = Items {}
    items:push Item {}
    items:push Item {}
    local text: Ref Text = choose (Ref items) flag
    local view = text:str()
    text:write "relocating growth"
    return view.length
end
export entry
]] },
}
local policy = S.call_policy
local ok, err = pcall(function()
    S.call_policy = 'written'
    local gaps = 0
    for _, case in ipairs(cases) do
        local success, result = pcall(nua.compile, case.source, 'reference_result_' .. case.name .. '.nua', { no_c = true })
        local correct = not case.reject and success
            or case.reject and not success and tostring(result):find(case.reject, 1, true)
        print(('CASE %s: %s'):format(case.name, correct and 'required staging outcome' or 'GAP'))
        if not success then print(tostring(result))
        elseif not correct then print('  staged successfully; required rejection is missing') end
        if not correct then gaps = gaps + 1 end
    end
    print(('Required reference-result checks: %d gaps; no native execution.'):format(gaps))
    assert(gaps == 0, 'reference-result guarantees are not implemented')
end)
S.call_policy = policy
if not ok then error(err, 0) end
