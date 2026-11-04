-- nua.types: native types are compile-time Lua values.
--
-- Every type is a table with a `kind`. Scalars carry their C semantics (width,
-- signedness); constructed types are memoized so `Ref(T) == Ref(T)`.

local T = {}

local Type = {}
Type.__index = Type
T.Type = Type

function Type:__tostring() return self.display end
function T.is_type(x) return getmetatable(x) == Type end

local function new(t)
    return setmetatable(t, Type)
end

-- scalars -----------------------------------------------------------------------------

local function int(bits, signed)
    local name = (signed and 'I' or 'U') .. bits
    return new {
        kind = 'int', bits = bits, signed = signed, display = name, name = name,
        cname = (signed and 'int' or 'uint') .. bits .. '_t',
        wide = bits == 64,                 -- Known values held as 64-bit cdata
        small = bits < 32,                 -- promoted by C: arithmetic needs casts
    }
end

T.U8, T.U16, T.U32, T.U64 = int(8, false), int(16, false), int(32, false), int(64, false)
T.I8, T.I16, T.I32, T.I64 = int(8, true), int(16, true), int(32, true), int(64, true)
-- a span of time in nanoseconds: its own type, so it does not mix with plain counts
T.Duration = int(64, false)
T.Duration.display, T.Duration.name = 'Duration', 'Duration'
T.F32 = new { kind = 'float', bits = 32, display = 'F32', name = 'F32', cname = 'float' }
T.F64 = new { kind = 'float', bits = 64, display = 'F64', name = 'F64', cname = 'double' }
T.Bool = new { kind = 'bool', display = 'Bool', name = 'Bool', cname = 'bool' }
T.Unit = new { kind = 'unit', display = 'Unit', name = 'Unit', cname = 'void' }
-- a C string: `const char *`; a Lua string literal is a known CString
T.CString = new { kind = 'cstr', display = 'CString', name = 'CString', cname = 'const char *' }

-- an opaque C type, usable only behind a Ptr (FILE, DIR, ...)
local opaques = {}
function T.opaque(cname)
    if type(cname) ~= 'string' or not cname:match '^[%a_][%w_]*$' then
        error('opaque expects a C type name, got ' .. tostring(cname), 2)
    end
    if not opaques[cname] then
        opaques[cname] = new { kind = 'opaque', display = cname, name = cname, cname = cname }
    end
    return opaques[cname]
end

T.scalars = { 'U8', 'U16', 'U32', 'U64', 'I8', 'I16', 'I32', 'I64', 'F32', 'F64', 'Bool', 'Unit', 'CString' }

function T.is_int(t) return t.kind == 'int' end
function T.is_float(t) return t.kind == 'float' end
function T.is_numeric(t) return t.kind == 'int' or t.kind == 'float' end
function T.is_scalar(t)
    return t.kind == 'int' or t.kind == 'float' or t.kind == 'bool'
end

-- constructed types -------------------------------------------------------------------

local memo = {}
local function memoized(kind, elem, make)
    memo[kind] = memo[kind] or setmetatable({}, { __mode = 'k' })
    local t = memo[kind][elem]
    if not t then t = new(make()); memo[kind][elem] = t end
    return t
end

local function check_type(x, what)
    if not T.is_type(x) then
        error(what .. ' expects a type, got ' .. tostring(x), 3)
    end
    return x
end

function T.ref(elem)
    check_type(elem, 'Ref')
    return memoized('ref', elem, function()
        return { kind = 'ref', elem = elem, display = 'Ref ' .. elem.display }
    end)
end

function T.ptr(elem)
    check_type(elem, 'Ptr')
    return memoized('ptr', elem, function()
        return { kind = 'ptr', elem = elem, display = 'Ptr ' .. elem.display }
    end)
end

-- An element of an array or a container, or a map value: any fixed-size type
-- that is neither an owner nor an atomic (design memory.md §5.11). Atomics are
-- never copied, and elements move by copy; owners nested in containers are
-- milestone 5 (arenas).
function T.element(elem)
    local k = elem.kind
    return not (k == 'unit' or k == 'opaque' or k == 'atomic' or k == 'group' or elem.resizable)
end

-- An element of a container (Grow, Array T, Store) or a map value: an element type, or an
-- owner, or a struct holding owners (design memory.md §5.9): its owners live in the
-- container's arenas.
function T.owner_element(elem)
    local k = elem.kind
    if k == 'owner' or ((k == 'struct' or k == 'sum') and elem.resizable) then return true end
    return T.element(elem)
end

function T.id(elem)
    check_type(elem, 'Id')
    return memoized('id', elem, function()
        return { kind = 'id', elem = elem, display = 'Id ' .. elem.display }
    end)
end

-- A library owner type (design memory.md §10.1): `family` names the declaration that
-- states its header, stacks, algorithms and operations; the type is only its identity,
-- from the family, the optional key type and the element. What a family admits is its
-- declaration's rule (T.element, T.map_key and T.map_value are the predicates).
local owner_memo = {}
-- `length`: a family whose owners hold a number of elements fixed in the type (Array(T, n)
-- of elements that hold owners).
function T.owner(family, elem, display, key, length)
    check_type(elem, family)
    if key ~= nil then check_type(key, family) end
    local by_family = owner_memo[family]
    if not by_family then by_family = {}; owner_memo[family] = by_family end
    local id = key or length or false
    local by_key = by_family[id]
    if not by_key then by_key = setmetatable({}, { __mode = 'k' }); by_family[id] = by_key end
    local t = by_key[elem]
    if not t then
        t = new { kind = 'owner', family = family, elem = elem, key = key, display = display, resizable = true,
                  length = length }
        by_key[elem] = t
    end
    return t
end

-- structs -----------------------------------------------------------------------------
-- Fields are ordered. A struct holding owner fields, any number of them in any
-- order, is itself an owner (design memory.md §5.2).

function T.struct(name, fields)
    local t = new { kind = 'struct', name = name, display = name, fields = {},
                    index = {}, methods = {}, incomplete = true }
    if type(fields) == 'function' then fields = fields(t) end
    local function incomplete_value(ft)
        if rawget(ft, 'incomplete') then return true end
        if ft.kind == 'array' then return incomplete_value(ft.elem) end
        if ft.kind == 'sum' then
            for _, alt in ipairs(ft.alts) do
                if incomplete_value(alt.type) then return true end
            end
        end
        return false
    end
    local resizable
    for i, f in ipairs(fields) do
        local fname, ftype = f[1], f[2]
        if not T.is_type(ftype) then
            error(("field '%s' of struct %s: expected a type, got %s"):format(
                fname, name, tostring(ftype)), 2)
        end
        if incomplete_value(ftype) then
            error(("field '%s' of struct %s: an incomplete type must be held through Ptr"):format(fname, name), 2)
        end
        if t.index[fname] then error(("struct %s: duplicate field '%s'"):format(name, fname), 2) end
        if ftype.kind == 'unit' then error(("struct %s: field '%s' cannot be Unit"):format(name, fname), 2) end
        if ftype.kind == 'opaque' then
            error(("struct %s: field '%s' is the opaque type %s; hold it as Ptr %s"):format(name, fname,
                ftype.display, ftype.display), 2)
        end
        if ftype.resizable or (ftype.kind == 'struct' and ftype.resizable) then
            resizable = fname
        end
        t.fields[i] = { name = fname, type = ftype }
        t.index[fname] = t.fields[i]
    end
    t.resizable = resizable and true or nil
    t.incomplete = nil
    return t
end

-- function values ---------------------------------------------------------------------
-- Fn(params...): ret is a C function pointer. Parameters and result are fixed
-- by the signature; the pointee is a residual function (spec 41.3).

local fn_ids, fn_types = setmetatable({}, { __mode = 'k' }), {}
local function fn_id(t)
    local id = fn_ids[t]
    if not id then id = (fn_ids.n or 0) + 1; fn_ids.n = id; fn_ids[t] = id end
    return id
end
function T.fn(params, ret)
    local key = { 'r' .. fn_id(ret) }
    local names = {}
    for i, p in ipairs(params) do
        check_type(p, 'Fn')
        if p.kind == 'unit' or p.kind == 'opaque' or p.resizable then
            error('Fn parameter ' .. i .. ' cannot be ' .. p.display, 2)
        end
        key[#key + 1] = 'p' .. fn_id(p)
        names[i] = p.display
    end
    check_type(ret, 'Fn')
    if ret.kind == 'opaque' or ret.resizable then error('Fn cannot return ' .. ret.display, 2) end
    local k = table.concat(key, ',')
    if not fn_types[k] then
        fn_types[k] = new { kind = 'fn', params = params, ret = ret,
            display = 'Fn(' .. table.concat(names, ', ') .. '): ' .. ret.display }
    end
    return fn_types[k]
end

-- atomics ----------------------------------------------------------------------------------------
-- Atomic T: accessed only by atomic operations. In C it is a plain T accessed
-- with the __atomic builtins, so layouts stay the same as C's and the kernel's.

local atomics = {}
function T.atomic(elem)
    if not T.is_type(elem) then error('Atomic expects a type, got ' .. tostring(elem), 2) end
    if not (elem.kind == 'int' or elem.kind == 'bool' or elem.kind == 'ptr') then
        error('Atomic holds an integer, a Bool or a pointer, not ' .. elem.display, 2)
    end
    if not atomics[elem] then
        atomics[elem] = new { kind = 'atomic', elem = elem, display = 'Atomic ' .. elem.display,
                              name = 'Atomic' .. (elem.name or 'Ptr') }
    end
    return atomics[elem]
end

-- fixed-length arrays -----------------------------------------------------------------------------
-- Array(T, n): n elements of a fixed-size T, a value. In C a struct wrapping
-- T e[n], so arrays copy and pass by value as structs do.

local arrays = {}
function T.array(elem, n, raw)
    if not T.is_type(elem) then error('Array expects an element type, got ' .. tostring(elem), 2) end
    if type(n) ~= 'number' or n ~= math.floor(n) or n < 1 or n > 0x7fffffff then
        error(('Array(%s, n): n must be a positive integer known while compiling, got %s'):format(
            elem.display, tostring(n)), 2)
    end
    -- raw: the elements of a FixedArray, storage inside its header (they may be owners)
    if not T.element(elem) and not (raw and T.owner_element(elem)) then
        error(('Array holds fixed-size values, not %s'):format(elem.display), 2)
    end
    arrays[elem] = arrays[elem] or {}
    if not arrays[elem][n] then
        local base = (elem.name or 'T'):gsub('[^%w_]', '_')
        arrays[elem][n] = new { kind = 'array', elem = elem, length = n,
                                display = ('Array(%s, %d)'):format(elem.display, n),
                                name = base .. 'x' .. n }
    end
    return arrays[elem][n]
end

-- channels -------------------------------------------------------------------------------------
-- Chan T: a handle to a channel. What crosses a channel is a copy, so T holds
-- no reference to anyone's memory: no Ref, Ptr, Slice, CString, Id or Atomic.

-- whether values of t borrow someone else's storage: a view, or an aggregate
-- holding one. Such values follow the lifetime rule; storage that outlives
-- every owner (globals, containers, messages) cannot hold them.
local borrow_cache = setmetatable({}, { __mode = 'k' })
function T.holds_borrow(t)
    local cached = borrow_cache[t]
    if cached ~= nil then return cached end
    local yes = rawget(t, 'slice_elem') ~= nil or t.kind == 'ref'
    if not yes and t.kind == 'struct' then
        for _, f in ipairs(t.fields or {}) do yes = yes or T.holds_borrow(f.type) end
    elseif t.kind == 'array' then yes = T.holds_borrow(t.elem)
    elseif t.kind == 'sum' then
        for _, a in ipairs(t.alts) do yes = yes or T.holds_borrow(a.type) end
    end
    borrow_cache[t] = yes
    return yes
end

-- why t cannot cross between tasks, or nil when it can
function T.unsendable(t)
    local k = t.kind
    if k == 'int' or k == 'float' or k == 'bool' or k == 'unit' or k == 'chan' or k == 'pool' or k == 'slot' then
        return nil
    end
    if rawget(t, 'slice_elem') then return 'a slice is a view of memory someone else owns' end
    if k == 'struct' then
        for _, f in ipairs(t.fields) do
            local why = T.unsendable(f.type)
            if why then return ("its field '%s' is a %s: %s"):format(f.name, f.type.display, why) end
        end
        return nil
    end
    if k == 'array' then
        local why = T.unsendable(t.elem)
        if why then return ('its elements are %s: %s'):format(t.elem.display, why) end
        return nil
    end
    if k == 'sum' then
        for _, a in ipairs(t.alts) do
            local why = T.unsendable(a.type)
            if why then return ("its alternative '%s' holds a %s: %s"):format(a.name, a.type.display, why) end
        end
        return nil
    end
    if k == 'ref' then return 'a reference points into memory someone else owns' end
    if k == 'ptr' then return 'a pointer points into memory someone else owns' end
    if k == 'cstr' then return 'a CString points into memory someone else owns' end
    if k == 'atomic' then return 'atomics are shared memory, which tasks do not have' end
    if k == 'id' then return 'an Id names a slot of a store someone else owns' end
    return 'it is not a plain value'
end

local chans = {}
function T.chan(elem)
    if not T.is_type(elem) then error('Chan expects a type, got ' .. tostring(elem), 2) end
    if elem.kind == 'unit' then error('Chan Unit carries nothing; use Chan Bool for a signal', 2) end
    local why = T.unsendable(elem)
    if why then error(('Chan %s: values crossing a channel are copies, and %s'):format(elem.display, why), 2) end
    local where = T.slot_misplaced(elem)
    if where then
        error(('Chan %s: a Slot inside %s cannot move (its ownership would depend on a runtime choice)'):format(
            elem.display, where), 2)
    end
    if not chans[elem] then
        chans[elem] = new { kind = 'chan', elem = elem, display = 'Chan ' .. elem.display,
                            name = 'Chan' .. (elem.name or 'T'), cname = 'nua_chan' }
    end
    return chans[elem]
end

-- pools: slots of T whose ownership moves between tasks (syntax §20.6)
local function holds_slot_inside(t, inside)
    if t.kind == 'slot' then return inside end
    if t.kind == 'struct' then
        for _, f in ipairs(t.fields) do
            local w = holds_slot_inside(f.type, inside)
            if w then return w end
        end
    elseif t.kind == 'sum' then
        for _, a in ipairs(t.alts) do
            local w = holds_slot_inside(a.type, 'a oneof')
            if w then return w end
        end
    elseif t.kind == 'array' then
        return holds_slot_inside(t.elem, 'an array')
    end
    return nil
end
T.slot_misplaced = function(t) return holds_slot_inside(t, nil) end

local pools, slots = {}, {}
function T.pool(elem)
    if not T.is_type(elem) then error('Pool expects a type, got ' .. tostring(elem), 2) end
    local why = T.unsendable(elem)
    if why then error(('Pool %s: slots move between tasks, and %s'):format(elem.display, why), 2) end
    local k = elem.kind
    if not (k == 'int' or k == 'float' or k == 'bool' or k == 'struct' or k == 'sum' or k == 'array')
        or elem.resizable then
        error(('a Pool holds fixed-size values, not %s'):format(elem.display), 2)
    end
    if not pools[elem] then
        pools[elem] = new { kind = 'pool', elem = elem, display = 'Pool ' .. elem.display,
                            name = 'Pool' .. (elem.name or 'T'), cname = 'nua_pool' }
    end
    return pools[elem]
end
function T.slot(elem)
    if not T.is_type(elem) then error('Slot expects a type, got ' .. tostring(elem), 2) end
    if not slots[elem] then
        T.pool(elem)
        slots[elem] = new { kind = 'slot', elem = elem, display = 'Slot ' .. elem.display,
                            name = 'Slot' .. (elem.name or 'T'), cname = 'nua_slot' }
    end
    return slots[elem]
end

-- a tasks scope, as the runtime sees it; never a value of the language
T.Group = new { kind = 'group', display = 'tasks scope', name = 'Group', cname = 'nua_scope *' }

-- slices --------------------------------------------------------------------------------------
-- A read-only view: a pointer and a U32 length. Internally a two-field struct,
-- so the evaluator tracks the length apart from the pointer.

local slices = {}
function T.slice(elem)
    if not T.is_type(elem) then error('Slice expects a type, got ' .. tostring(elem), 2) end
    if elem.kind == 'unit' or elem.resizable then
        error('Slice holds fixed-size values, not ' .. elem.display, 2)
    end

    if slices[elem] then return slices[elem] end
    local base = (elem.kind == 'struct' or elem.kind == 'sum') and elem.name or elem.name or 'T'
    local t = T.struct(base .. 'Slice', { { 'ptr', T.ptr(elem) }, { 'len', T.U64 } })
    t.display = 'Slice ' .. elem.display
    t.slice_elem = elem
    slices[elem] = t
    return t
end

-- Slice.mut T: a run of elements, writable; its length cannot change
local mut_slices = {}
function T.slice_mut(elem)
    if not T.is_type(elem) then error('Slice.mut expects a type, got ' .. tostring(elem), 2) end
    if elem.kind == 'unit' or elem.resizable then
        error('Slice.mut holds fixed-size values, not ' .. elem.display, 2)
    end
    if mut_slices[elem] then return mut_slices[elem] end
    local base = elem.name or 'T'
    local t = T.struct(base .. 'SliceMut', { { 'ptr', T.ptr(elem) }, { 'len', T.U64 } })
    t.display = 'Slice.mut ' .. elem.display
    t.slice_elem = elem
    t.slice_mut = true
    mut_slices[elem] = t
    return t
end

-- text: Str is a read-only view of bytes (a slice of U8 with text words); Chars(n), short
-- text as a value, is a library type (lib/chars.nua)
T.Str = T.struct('Str', { { 'ptr', T.ptr(T.U8) }, { 'len', T.U64 } })
T.Str.display = 'Str'
T.Str.slice_elem = T.U8
T.Str.is_str = true

-- sums -------------------------------------------------------------------------------------
-- A finite set of named alternatives, each with a payload type (Unit for none).
-- Alternative order is canonical (by name), so two spellings of the same
-- alternatives are the same type.

local sums = {}

function T.sum(name, alts)
    if #alts == 0 then error('oneof needs at least one named alternative', 2) end
    local list, seen = {}, {}
    for _, a in ipairs(alts) do
        local an, at = a[1], a[2]
        if seen[an] then error(("oneof: duplicate alternative '%s'"):format(an), 2) end
        seen[an] = true
        if not T.is_type(at) then
            error(("oneof: alternative '%s' needs a type, got %s"):format(an, tostring(at)), 2)
        end
        if at.resizable and not T.owner_element(at) then
            error(("oneof: alternative '%s' is resizable storage; payloads are fixed-size"):format(an), 2)
        end
        list[#list + 1] = { name = an, type = at }
    end
    table.sort(list, function(x, y) return x.name < y.name end)
    local key = {}
    for i, a in ipairs(list) do key[i] = a.name .. '=' .. tostring(a.type) end
    key = table.concat(key, ';')
    -- Display names are not type identities: two loaded modules may each
    -- declare a Payload struct. Never intern their lookup sums together.
    local candidates = sums[key] or {}
    for _, candidate in ipairs(candidates) do
        local same = #candidate.alts == #list
        for i, a in ipairs(list) do
            local other = candidate.alts[i]
            if not other or other.name ~= a.name or other.type ~= a.type then same = false; break end
        end
        if same then return candidate end
    end
    local t = new { kind = 'sum', name = name, display = name, alts = list, index = {} }
    for i, a in ipairs(list) do
        a.tag = i - 1
        t.index[a.name] = a
        -- a payload holding owners makes the sum an owner (design memory.md §5.9)
        if a.type.resizable then t.resizable = true end
    end
    candidates[#candidates + 1] = t
    sums[key] = candidates
    return t
end

-- Maps: recursively admit data, never merely an outer fixed-size layout.
local function map_data(t, key, unit, visiting)
    if not T.is_type(t) or t.resizable then return false end
    if key and rawget(t, 'slice_elem') then return false end
    local k = t.kind
    if not key then
        -- a value is any element: scalars, ids, borrows (Ref, Str, Slice), handles (Ptr, Slot,
        -- Chan, Pool), and structs, sums and arrays of these. Atomics wait (design D4).
        if k == 'unit' then return unit end
        if k == 'atomic' or k == 'group' or k == 'opaque' then return false end
        if k ~= 'struct' and k ~= 'sum' and k ~= 'array' then return true end
    end
    if k == 'int' or k == 'bool' or k == 'id' or rawget(t, 'chars_cap') then return true end
    if k == 'unit' then return unit end
    if k == 'float' then return not key end
    if visiting[t] then return false end
    visiting[t] = true
    local ok = false
    if k == 'struct' then
        ok = true
        for _, f in ipairs(t.fields) do
            if not map_data(f.type, key, false, visiting) then ok = false; break end
        end
    elseif k == 'sum' then
        ok = true
        for _, a in ipairs(t.alts) do
            if not map_data(a.type, key, true, visiting) then ok = false; break end
        end
    elseif k == 'array' and not key then
        ok = map_data(t.elem, false, false, visiting)
    end
    visiting[t] = nil
    return ok
end
function T.map_key(t) return map_data(t, true, false, {}) end
function T.map_value(t) return map_data(t, false, false, {}) end

-- C sizes for the default target (LP64). Used only for diagnostics; layout is
-- left to the C compiler.
function T.fixed(t)
    return not t.resizable
end

return T
