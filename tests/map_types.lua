-- Recursive map key/value admissibility, independent of stage initialization.
local T = require 'nua.types'
local function rejects(f, message)
    local ok, err = pcall(f)
    assert(not ok and tostring(err):find(message, 1, true), tostring(err))
end
local Node = T.struct('MapTypeNode', { { 'n', T.U32 } })
-- Chars(n) is a library struct marked with its capacity (lib/chars.nua)
local Chars8 = T.struct('Chars8', { { 'len', T.U32 }, { 'bytes', T.array(T.U8, 8) } })
Chars8.chars_cap = 8
local Key = T.struct('MapTypeKey', { { 'label', Chars8 }, { 'id', T.id(Node) } })
local Choice = T.sum('MapTypeChoice', { { 'none', T.Unit }, { 'some', Key } })
local Value = T.struct('MapTypeValue', { { 'samples', T.array(T.F64, 4) }, { 'tag', Choice } })
-- The type is its identity: the family, the key and the element (what a family admits is
-- its declaration's rule, tested through the compiler in tests/errors.lua).
local function map(k, v) return T.owner('Map', v, 'Map(' .. k.display .. ', ' .. v.display .. ')', k) end
local function strmap(v) return T.owner('StrMap', v, 'Map(Str, ' .. v.display .. ')', T.Str) end
assert(map(Key, Value) == map(Key, Value))
assert(map(Choice, T.U32).resizable)
assert(strmap(Value) == strmap(Value))
assert(map(T.U32, T.U32) ~= map(T.U64, T.U32))
assert(map(T.U32, T.U32) ~= strmap(T.U32))
assert(T.map_key(T.Duration) and T.map_key(T.Bool))
local Grow = T.owner('Grow', T.U32, 'Grow U32')
for _, ty in ipairs { T.F32, T.F64, T.array(T.U8, 4), T.Str, T.CString,
    T.ptr(T.U8), T.ref(Node), T.atomic(T.U32), T.Unit, Grow, map(T.U32, T.U32) } do
    assert(not T.map_key(ty), ty.display)
end
-- a value is any element: borrows and handles included (design memory.md §5.11);
-- atomics wait (D4), a standalone Unit is nothing, and owners come with nested owners
for _, ty in ipairs { T.atomic(T.U32), T.Unit, Grow, map(T.U32, T.U32) } do
    assert(not T.map_value(ty), ty.display)
end
for _, ty in ipairs { T.Str, T.CString, T.ptr(T.U8), T.ref(Node), T.id(Node) } do
    assert(T.map_value(ty) and map(T.U32, ty).elem == ty and strmap(ty).elem == ty)
end
local Borrowed = T.struct('MapTypeBorrowed', { { 'p', T.ptr(T.U8) } })
local Hidden = T.sum('MapTypeHidden', { { 'none', T.Unit }, { 'some', Borrowed } })
assert(not T.map_key(Hidden) and T.map_value(Hidden))
assert(T.map_value(T.array(Borrowed, 2)))
local Owner = T.struct('MapTypeOwner', { { 'n', T.U32 }, { 'entries', strmap(Value) } })
assert(Owner.resizable and not T.map_value(Owner))
-- owner fields may come in any order, any number of them (design memory.md §5.2)
local AnyOrder = T.struct('MapTypeAnyOrder', { { 'entries', map(Key, Value) }, { 'n', T.U32 },
    { 'more', strmap(Value) } })
assert(AnyOrder.resizable)
-- Repeated module loads may reuse display names, not native type identity.
local A = T.struct('MapPayloadAgain', { { 'n', T.U32 } })
local B = T.struct('MapPayloadAgain', { { 'n', T.U32 } })
local SA = T.sum('FirstLookup', { { 'found', A }, { 'missing', T.Unit } })
local SB = T.sum('SecondLookup', { { 'found', B }, { 'missing', T.Unit } })
assert(SA ~= SB)
assert(SA == T.sum('AliasLookup', { { 'missing', T.Unit }, { 'found', A } }))
print('map types: recursive key/value rules passed')
