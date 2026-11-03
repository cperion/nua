-- nua.memory: Goose-style native storage for the residual program.
--
--   Store T   a managed store of fixed-size T objects; insertion returns an Id T
--   Id T      a generational ID: store token, slot, generation; it never owns
--   Grow T    a resizable array of fixed-size T
--
-- Stores and Grow arrays are resizable: each is created in place in the
-- storage it will live in (`local s: Store T = Store T {}` or a struct field),
-- gets the lowest free data-stack index of its function, and gives its space
-- back when its residual block ends. Resizable values are never copied: they
-- move only by reference (Ref), cannot be assigned, returned or read as values.
-- Their operations are runtime effects: they always stay in the residual code.

local types = require 'nua.types'
local S = require 'nua.stage'

local Mem = {}
local Builder = S.Builder
local dyn, known = S.dyn, S.known
local storage_library

local function fail(msg) S.fail(msg, 2) end
local function fresh(t) return setmetatable({ T = t, k = 'fresh' }, S.V) end

-- C names supplied by the backend: NodeStore, NodeId, U8Grow
local function elem_name(t)
    if t.kind == 'struct' then return require('nua.cgen').ctype(t) end
    if t.kind == 'ref' then return elem_name(t.elem) .. 'Ref' end
    return t.name
end

local function cname_of(t)
    if t.kind == 'store' then return elem_name(t.elem) .. 'Store' end
    if t.kind == 'id' then return elem_name(t.elem) .. 'Id' end
    if t.kind == 'grow' then return elem_name(t.elem) .. 'Grow' end
    if t.kind == 'rtarray' then return elem_name(t.elem) .. 'Array' end
    if rawget(t, 'ctype') then return t.ctype() end
end
Mem.cname_of = cname_of

-- A representation is Nua code, so it belongs to one compilation: a type that
-- outlives a compilation (Text is Grow U8) must not pin a stale descriptor.
-- One layout module serves a whole build, so its records are never duplicated.
local derived = setmetatable({}, { __mode = 'k' })   -- module -> { type -> layout }
local layouts_for = setmetatable({}, { __mode = 'k' })  -- module -> layout instance
local fallback, fallback_externs

-- A build that reuses the module loaded by an earlier compilation must emit the
-- same declarations it would have loaded itself.
local function carry_externs()
    if not fallback_externs then return end
    local have = {}
    for _, x in ipairs(S.module.externs) do have[x] = true end
    for _, x in ipairs(fallback_externs) do
        if not have[x] then
            S.module.externs[#S.module.externs + 1] = x
            have[x] = true
        end
    end
end

local function layouts_module()
    local module = S.module
    local inst = layouts_for[module]
    if inst then return inst end
    local before = #module.externs
    local ok, loaded = pcall(require, 'nua.storage_layout')
    -- Code generation runs after the compilation closes: reuse what staging had.
    if ok then
        fallback, fallback_externs = loaded, { unpack(module.externs, before + 1) }
    else
        carry_externs()
    end
    inst = ok and loaded or fallback
    if not inst then error('no Nua storage layout module is available', 0) end
    layouts_for[module] = inst
    return inst
end
-- every consumer in a build shares one layout module instance
Mem.layouts_module = layouts_module

local function layout_of(t)
    if t.representation then return { layout = t.representation } end
    local cache = derived[S.module]
    if not cache then cache = {}; derived[S.module] = cache end
    local r = cache[t]
    if r then return r end
    local layouts = layouts_module()
    r = { layout = t.kind == 'store' and layouts.Store
        or (t.kind == 'grow' or t.kind == 'rtarray') and layouts.Grow or layouts.Id }
    if t.kind == 'store' then
        r.slot = S.struct(cname_of(t) .. 'Slot', { { 'gen', types.U32 }, { 'next', types.U32 }, { 'value', t.elem } })
    end
    cache[t] = r
    return r
end

-- the native representation of a storage type in this compilation
function Mem.representation(t)
    return layout_of(t).layout
end

-- the data stack expression for local index k
local function gs_expr(k) return k == 0 and 'gs_sp' or ('gs_sp + ' .. k) end

-- data-stack indices ------------------------------------------------------------------------

local serials = 0
-- An owned slot: one data stack held by an owner place. The place's header
-- says which stack and where the owner began, so releasing reads the header:
-- a moved owner is released through whichever place holds it now.
local function releaser_for(t, fields)
    local representation = layout_of(t).layout
    fields = fields or { 'stack', 'base' }
    local cleanup = require('nua.storage_layout').releaser(representation, fields[1], fields[2])
    return function(place) cleanup(Mem.view(place, representation)) end
end
Mem.releaser_for = releaser_for

-- the residual block whose end releases an owner held by place p: the block
-- its root local was declared in
local function owning_block(b, p)
    local root = S.root_of(p)
    return rawget(root, 'block') or b.block
end

function Builder:gs_owned_list(blk)
    self.gs_owned = self.gs_owned or {}
    local owned = self.gs_owned[blk]
    if not owned then owned = {}; self.gs_owned[blk] = owned end
    return owned
end

-- The stack index an allocation lands on, as a value: one of this function's
-- own stacks (gs_sp + k), or its result stack j (gs_res + j)
function Mem.stack_index(k)
    if type(k) == 'table' then
        -- result stack j of this function: gs_res + its offset in its
        -- recursion's region + j; the backends read the offset once stacks
        -- are planned
        return dyn(types.U64, { op = 'res_index', fn = S.cur().fn, j = k.res, T = types.U64 })
    end
    return dyn(types.U64, { op = 'stack_index', offset = k, T = types.U64 })
end

-- Allocations are counted, so a rebuild can place the same one elsewhere: an
-- owner a materialized word returns is built on its result stack
-- (design memory.md §9: the callee receives its destination).
function Builder:next_allocation()
    self.alloc_count = (self.alloc_count or 0) + 1
    local at = self.fn and self.fn.result_allocs and self.fn.result_allocs[self.alloc_count]
    return self.alloc_count, at and at.first
end

-- Slots. A slot is one data stack held by an owner place: one of this
-- function's own indices (k), a result stack (res), or storage adopted from a
-- header (an owner parameter: neither). Slot records are never handed from
-- place to place: a move gives the destination a slot of its own over the same
-- storage, and the source's move mark, which follows paths, branches and joins
-- like any path fact, says the source no longer releases it. An index stays
-- claimed while any slot over it lives.
function Builder:claim(k)
    self.gs_live = self.gs_live or {}
    self.gs_claims = self.gs_claims or {}
    self.gs_claims[k] = (self.gs_claims[k] or 0) + 1
    self.gs_live[k] = true
    self.fn.gs_count = math.max(self.fn.gs_count or 0, k + 1)
end
function Builder:unclaim(k)
    local n = (self.gs_claims and self.gs_claims[k] or 1) - 1
    self.gs_claims[k] = n > 0 and n or nil
    if n <= 0 then self.gs_live[k] = nil end
end
S.slot_serial = function() return serials end

function Builder:register_slot(slot)
    if not slot.serial then serials = serials + 1; slot.serial = serials end
    slot.aliases = slot.aliases or {}
    slot.block = slot.block or owning_block(self, slot.place)
    slot.release = function() slot.free(slot.place) end
    for _, k in ipairs(slot.reserved or {}) do self:claim(k) end
    if slot.k then
        self:claim(slot.k)
    elseif slot.res then
        self.gs_res_slots = self.gs_res_slots or {}
        self.gs_res_slots[slot] = true
    else
        self.gs_extra = self.gs_extra or {}
        self.gs_extra[slot] = true
    end
    local owned = self:gs_owned_list(slot.block)
    owned[#owned + 1] = slot
    -- on this path the place now holds this storage
    S.mark_held(slot.place)
    -- a discarded speculative round forgets the slots it made
    self.registered = self.registered or {}
    self.registered[#self.registered + 1] = slot
    return slot
end

function Builder:gs_alloc(p, release)
    if not self.fn then
        fail('a ' .. p.T.display .. ' is runtime storage; it cannot be created at compile time')
    end
    local ordinal, j = self:next_allocation()
    local free = releaser_for(p.T, release)
    if j then
        self:register_slot { place = p, res = j, ordinal = ordinal, free = free, fields = release }
        return { res = j }
    end
    self.gs_live = self.gs_live or {}
    local k = 0
    while self.gs_live[k] do k = k + 1 end
    self:register_slot { place = p, k = k, ordinal = ordinal, free = free, fields = release }
    return k
end

-- every slot this builder holds
function Builder:all_slots()
    local out, seen = {}, {}
    for slot in pairs(self.gs_extra or {}) do
        if not seen[slot] then seen[slot] = true; out[#out + 1] = slot end
    end
    for slot in pairs(self.gs_res_slots or {}) do
        if not seen[slot] then seen[slot] = true; out[#out + 1] = slot end
    end
    for _, list in pairs(self.gs_owned or {}) do
        for _, slot in ipairs(list) do
            if not seen[slot] then seen[slot] = true; out[#out + 1] = slot end
        end
    end
    table.sort(out, function(a, b) return a.serial < b.serial end)
    return out
end

-- does this path still hold the place's storage (received, not moved on)?
local function moved_here(b, p)
    return S.moved_on_path(b.state, p) or not S.held_on_path(b.state, p)
end

-- The slots over an owner place's storage on this path, one per stack of
-- its header: the newest for each (a replacement made a newer one).
function Builder:slots_of(p)
    local by_fields, order = {}, {}
    for _, slot in ipairs(self:all_slots()) do
        if slot.place == p then
            local key = slot.fields and table.concat(slot.fields, '/') or 'stack/base'
            if not by_fields[key] then order[#order + 1] = key end
            by_fields[key] = slot
        end
    end
    local out = {}
    for _, key in ipairs(order) do out[#out + 1] = by_fields[key] end
    table.sort(out, function(a, b) return a.serial < b.serial end)
    return out
end

-- a slot's place ends: its claims go, and it is forgotten
function Builder:drop_slot(slot)
    if slot.k then self:unclaim(slot.k) end
    for _, k in ipairs(slot.reserved or {}) do self:unclaim(k) end
    if self.gs_extra then self.gs_extra[slot] = nil end
    if self.gs_res_slots then self.gs_res_slots[slot] = nil end
    local owned = self.gs_owned and self.gs_owned[slot.block]
    if owned then
        for i = #owned, 1, -1 do if owned[i] == slot then table.remove(owned, i) break end end
    end
end

-- emit the releases of these slots whose places this path still holds, newest
-- first, one per stack of a place
function Builder:release_slots(slots, why)
    table.sort(slots, function(a, b) return a.serial > b.serial end)
    local done = {}
    for _, slot in ipairs(slots) do
        if not moved_here(self, slot.place) then
            local key = tostring(rawget(slot.place, 'id')) .. ':' .. (slot.fields and table.concat(slot.fields, '/') or '')
            if not done[key] and not self.dead then slot.release() end
            done[key] = true
            if why then
                S.end_place(slot.place, why)
                for _, q in ipairs(slot.aliases) do S.end_place(q, why) end
            end
        end
    end
end

-- the stack fields of an owner type's header, as (stack, base) pairs
function Mem.release_fields(t)
    return rawget(t, 'release_fields') or { { 'stack', 'base' } }
end

-- the owners inside a place: itself, or an owner struct's owner fields, with
-- their field paths from the place
function Mem.owner_leaves(p, out, path)
    out, path = out or {}, path or {}
    if p.T.kind == 'struct' then
        for _, f in ipairs(p.T.fields) do
            if f.type.resizable then
                local sub = { unpack(path) }
                sub[#sub + 1] = f.name
                Mem.owner_leaves(S.field_place(p, f.name), out, sub)
            end
        end
    else
        out[#out + 1] = { place = p, path = path }
    end
    return out
end

-- An owner that arrives as a header value: a materialized word's parameter,
-- or the result of a materialized call. The place adopts its stacks without
-- allocating; `reserve` lists stack indices of this function that stay
-- unused while it lives (where a callee may have put the result).
function Builder:adopt_owner(p, v, placement)
    S.check_usable(p, true)
    self:release_owner(p, ("'" .. tostring(p.name) .. "' was replaced"))
    S.clear_moved(p)
    placement = placement or {}
    local position = 0
    local function adopt(q, e)
        if q.T.kind == 'struct' then
            for _, f in ipairs(q.T.fields) do
                local fe = { op = 'field', a = e, name = f.name, T = f.type }
                if f.type.resizable then adopt(S.field_place(q, f.name), fe)
                else self:store(S.field_place(q, f.name), dyn(f.type, fe)) end
            end
            return
        end
        if not self.dead then self:emit { op = 'store', place = q, e = e, what = 'adopting an owner' } end
        for _, fields in ipairs(Mem.release_fields(q.T)) do
            position = position + 1
            local at = placement[position] or {}
            self:register_slot { place = q, free = at.free or releaser_for(q.T, fields), k = at.k, res = at.res,
                                 ordinal = at.ordinal, param = at.param, reserved = at.reserved,
                                 fields = fields[1] ~= 'stack' and fields or nil }
        end
    end
    adopt(p, S.ex(v))
end

-- how many stacks an owner of type t occupies (an owner struct: all of its
-- owners'), in the order its header lists them
function Mem.stack_count(t)
    local n = 0
    local function count(u)
        if u.kind == 'struct' then
            for _, f in ipairs(u.fields) do if f.type.resizable then count(f.type) end end
        else
            n = n + #Mem.release_fields(u)
        end
    end
    count(t)
    return n
end
S.owner_stack_count = Mem.stack_count

-- A materialized function returns: the owners it adopted (owner parameters)
-- live on stacks that are not its own, so its epilogue does not give them
-- back; they are released here, on every exit this path still holds them.
function Builder:release_extras()
    local slots = {}
    for slot in pairs(self.gs_extra or {}) do slots[#slots + 1] = slot end
    self:release_slots(slots)
end

-- An owner leaves this builder's hands whole (moved into a materialized call,
-- or returned): whoever receives it releases it. Its slots stay until its
-- place ends, so their indices stay claimed; the caller marks it moved.
-- Returns what would release it on a path that does not let it go.
function Builder:hand_off(p)
    local releases = {}
    for _, leaf in ipairs(Mem.owner_leaves(p)) do
        S.check_usable(leaf.place)
        local slots = self:slots_of(leaf.place)
        if #slots == 0 then
            fail(("'%s' is a %s this word does not own (it is reached through a reference); "
                .. "move only owners you hold, or copy it"):format(tostring(leaf.place.name), leaf.place.T.display))
        end
        for _, slot in ipairs(slots) do releases[#releases + 1] = { place = leaf.place, free = slot.free } end
    end
    return releases
end

-- An owner's life ends here (it is replaced): its storage returns to where it
-- began, and every borrow of it ends. Its slots stay until its place ends.
function Builder:release_owner(p, why)
    self:release_slots(self:slots_of(p), why)
    S.end_place(p, why)
end

-- the offset a callee's base takes at this point: past every live index
function Builder:gs_offset()
    local top = -1
    for k in pairs(self.gs_live or {}) do if k > top then top = k end end
    return top + 1
end

-- a residual block ends: the owners it holds give their storage back, unless
-- this path moved them on
function Builder:gs_close(blk)
    local owned = self.gs_owned and self.gs_owned[blk]
    if not owned then return end
    local last = blk[#blk]
    local reachable_end = not (last and (last.op == 'ret' or last.op == 'goto' or last.op == 'break'))
    local slots = {}
    for i = #owned, 1, -1 do slots[#slots + 1] = owned[i] end
    if reachable_end then
        self:release_slots(slots, nil)
    end
    for _, o in ipairs(slots) do
        if not moved_here(self, o.place) then
            local why = "'" .. tostring(rawget(o.place, 'name')) .. "' ended"
            S.end_place(o.place, why)
            for _, q in ipairs(o.aliases or {}) do S.end_place(q, why) end
        end
        self:drop_slot(o)
    end
    self.gs_owned[blk] = nil
end

-- the stage hook: a sub-block finished
local sub = Builder.sub
function Builder:sub(fn, state, kind)
    local blk, st, dead, res = sub(self, function()
        local r = fn()
        self:gs_close(self.block)
        return r
    end, state, kind)
    return blk, st, dead, res
end

-- creating resizable values in place --------------------------------------------------------


-- An owner place receives an owner: a fresh one is created in place; a named
-- one moves (design memory.md §5.4). An owner it held before ends here.
function Builder:init_resizable(p, v)
    if S.is_place(v) and v.T == p.T then return self:move_owner(p, v) end
    if S.is_value(v) and v.k == 'dyn' and v.T == p.T then
        -- an owner parameter: its stacks are the caller's; the slots remember
        -- which parameter, so returning it is known to leave it where it is
        local e = S.ex(v)
        local placement
        if e.op == 'param' and self.fn and self.fn.param_of then
            for i, name in pairs(self.fn.param_of) do
                if name == e.name then
                    placement = {}
                    for n = 1, Mem.stack_count(p.T) do placement[n] = { param = i } end
                end
            end
        end
        return self:adopt_owner(p, v, placement)
    end
    if not (S.is_value(v) and v.k == 'fresh' and v.T == p.T) then
        fail(("'%s' is a %s: it is created in place (%s {}), moved from another %s, or copied"):format(
            p.name, p.T.display, p.T.display, p.T.display))
    end
    S.check_usable(p, true)
    self:release_owner(p, ("'" .. tostring(p.name) .. "' was replaced"))
    S.clear_moved(p)
    local source, text = rawget(v, 'copy_of'), rawget(v, 'copy_text')
    local count, items = rawget(v, 'length'), rawget(v, 'copy_slice')
    if rawget(p.T, 'init_word') then
        -- a type with several stacks: one slot each, then its header word over their indices
        local indices, first = {}, nil
        for i, fields in ipairs(Mem.release_fields(p.T)) do
            local k = self:gs_alloc(p, fields)
            first = first or k
            indices[i] = Mem.stack_index(k)
        end
        rawset(p, 'gs_k', first)
        p.T.init_word(p, indices)
        if source then p.T.copy_storage(p, source) end
        return
    end
    local k = self:gs_alloc(p)
    storage_library(p.T).layout.init(S.Ref(p), Mem.stack_index(k))
    -- `copy x`: the new owner receives x's contents (design memory.md §5.5)
    if source then storage_library(p.T).copy(S.Ref(p), S.Ref(source)) end
    if text then storage_library(p.T).append(S.Ref(p), text) end
    if count then storage_library(p.T).allocate(S.Ref(p), count) end
    if items then
        local ptr, len = S.slice_parts(items)
        storage_library(p.T).fill_from(S.Ref(p), ptr, len)
    end
end

-- `copy x`: the visible O(n) duplicate of an owner, built in its destination.
-- An owner struct copies its owners deeply and its values as values; a Str
-- copies into a Text; a value is already a copy of itself.
function Mem.copy(x)
    local b = S.cur()
    -- a Lua string is a Str of static data
    if type(x) == 'string' then x = S.str_literal(x) end
    x = S.through(x)
    if S.is_value(x) and x.k == 'ref' then x = x.place end
    if S.is_place(x) and x.T.resizable then
        S.check_usable(x)
        if x.T.kind == 'struct' then
            local f = {}
            for _, fd in ipairs(x.T.fields) do
                local q = S.field_place(x, fd.name)
                f[fd.name] = fd.type.resizable and Mem.copy(q) or b:read(q)
            end
            return S.agg(x.T, f)
        end
        local v = fresh(x.T)
        rawset(v, 'copy_of', x)
        return v
    end
    if S.is_place(x) then x = b:read(x) end
    if S.is_value(x) and rawget(x.T, 'is_str') then
        local v = fresh(require('nua.strings').Text)
        rawset(v, 'copy_text', x)
        return v
    end
    if S.is_value(x) and rawget(x.T, 'slice_elem') then
        local v = fresh(Mem.RtArray(rawget(x.T, 'slice_elem')))
        rawset(v, 'copy_slice', x)
        return v
    end
    if S.is_value(x) then return x end
    fail('copy needs a native value, an owner or a borrow, got ' .. S.describe(x))
end

-- Move an owner: its header is copied into the destination, which takes over
-- its stacks; the source can no longer be used. Nothing it owns is copied.
function Builder:move_owner(dst, src)
    src = S.through(src)
    if S.is_value(src) and src.k == 'ref' then src = src.place end
    if src == dst then return end
    S.check_usable(src)
    S.check_usable(dst, true)
    local releases = {}
    local function move(d, q)
        if d.T.kind == 'struct' then
            for _, f in ipairs(d.T.fields) do
                local dd, qq = S.field_place(d, f.name), S.field_place(q, f.name)
                if f.type.resizable then move(dd, qq) else self:store(dd, self:read(qq)) end
            end
            return
        end
        S.check_usable(q)
        local slots = self:slots_of(q)
        if #slots == 0 then
            local root = S.root_of(q)
            if root.pk == 'deref' and rawget(root, 'param_index') and rawget(root, 'param_fn') == self.fn then
                -- out of a Ref parameter: the caller's place counts as moved after
                -- the call (the summary says so); paths that do not move it here
                -- release it on their way out
                local index = rawget(root, 'param_index')
                S.note_move_out(self.fn, index, S.field_path(q))
                for _, fields in ipairs(Mem.release_fields(q.T)) do
                    releases[#releases + 1] = { place = q, free = releaser_for(q.T, fields) }
                end
                self:adopt_owner(d, dyn(d.T, S.read_expr(q)))
                return
            end
            if root.pk == 'deref' then
                fail(("'%s' is reached through a Ref whose target is not known while compiling, so it "
                    .. "cannot be moved out (the place it leaves would not be known); copy it, or pass the "
                    .. "owner itself"):format(tostring(q.name)))
            end
            fail(("'%s' is a %s this word does not own; move only owners you hold, or copy it"):format(
                tostring(q.name), q.T.display))
        end
        self:release_owner(d, ("'" .. tostring(d.name) .. "' was replaced"))
        if not self.dead then
            self:emit { op = 'store', place = d, e = S.read_expr(q), what = 'moving an owner' }
        end
        -- the destination gets slots of its own over the same storage; q's
        -- move mark keeps q from releasing it on this path
        for _, slot in ipairs(slots) do
            releases[#releases + 1] = { place = q, free = slot.free }
            local aliases = { q }
            for _, a in ipairs(slot.aliases or {}) do aliases[#aliases + 1] = a end
            self:register_slot { place = d, k = slot.k, res = slot.res, reserved = slot.reserved,
                                 ordinal = slot.ordinal, param = slot.param, fields = slot.fields,
                                 free = releaser_for(d.T, slot.fields), serial = slot.serial,
                                 aliases = aliases }
        end
    end
    move(dst, src)
    S.clear_moved(dst)
    S.mark_moved(src, dst, releases)
end

function S.init_resizable(p, v)
    S.cur():init_resizable(p, v)
end

-- operations ---------------------------------------------------------------------------------

-- the place a method receiver denotes (a place, or a reference to one)
local function receiver(x, what)
    x = S.through(x)
    if S.is_value(x) and x.k == 'ref' then x = x.place end
    if S.is_place(x) then
        if x.T.resizable then S.check_usable(x) end
        return x
    end
    fail(what .. ' needs the storage itself (a place or a Ref), got a value')
end

local function addr(p) return { op = 'addr', place = p, T = types.ref(p.T) } end

-- Internal native representation projection: no owner checks or algorithms.
-- Public Ptr still rejects resizable owners; library adapters use this only
-- inside the compiler's existing ownership/checked-place integration.
function Mem.view(x, representation)
    local p = receiver(x, 'native representation')
    local pt = types.ptr(representation)
    return dyn(pt, { op = 'conv', a = addr(p), T = pt })
end
function Mem.record(t, fields)
    local values = {}
    for _, f in ipairs(layout_of(t).layout.fields) do
        values[f.name] = S.ex(S.coerce(fields[f.name], f.type, 'native representation field'))
    end
    return dyn(t, { op = 'agg', T = t, fields = values })
end

-- an operation with effects: emitted where it happens; a result goes through a
-- temporary so its order relative to other effects is fixed
local function capture(value, what)
    local b = S.cur()
    value = S.value_of(value)
    local tmp = b:new_temp(value.T)
    b:emit { op = 'let', place = tmp, e = S.ex(value), what = what }
    return dyn(value.T, S.read_expr(tmp))
end


-- An index or key fixed where it is written, so a checked place denotes the
-- element it named then. A free expression is already its own value; one that
-- reads tracked locals at known versions names one value, captured once while
-- the lookups that could reuse it hold. Equal indices then give equal checked
-- keys, and `m[k] = m[k] + 1` resolves its element once.
local EFFECTS = { call = true, calli = true, rtcall = true, atomic = true, wait = true,
                  slot_at = true, task = true }
local function named_value(e)
    if type(e) ~= 'table' then return true end
    if EFFECTS[e.op] then return false end
    if e.op == 'read' then return S.free(e) or e.ver ~= nil end
    for k, c in pairs(e) do
        if type(c) == 'table' and k ~= 'T' and k ~= 'place' and k ~= 'fn' and k ~= 'ext'
            and rawget(c, 'op') and not named_value(c) then return false end
    end
    for _, a in ipairs(e.args or {}) do if not named_value(a) then return false end end
    for _, a in pairs(e.fields or {}) do if not named_value(a) then return false end end
    return true
end
local function fix_index(value, what)
    value = S.value_of(value)
    if S.is_known(value) then return value end
    local e = S.ex(value)
    if S.free(e) and not EFFECTS[e.op] and named_value(e) then return value end
    if not named_value(e) then return capture(value, what) end
    local b = S.cur()
    local key, here, epoch = S.expr_key(e), b.path or '', b.cepoch or 0
    b.fixed_indices = b.fixed_indices or {}
    local hit = b.fixed_indices[key]
    if hit and hit.epoch == epoch and here:sub(1, #hit.path) == hit.path then return hit.value end
    local fixed = capture(value, what)
    b.fixed_indices[key] = { epoch = epoch, path = here, value = fixed }
    return fixed
end
Mem.fix_index = fix_index

local storage_libraries, storage_module = {}, nil
storage_library = function(t)
    if storage_module ~= S.module then storage_libraries, storage_module = {}, S.module end
    if storage_libraries[t] then return storage_libraries[t] end
    local layout = require('nua.storage_layout')
    layout_of(t)
    local id = t.kind == 'store' and Mem.Id(t.elem)
    if id then layout_of(id) end
    local representation = layout_of(t)
    local p = layout.storage(t, representation.layout, t.elem, representation.slot,
        function(x) return Mem.view(x, representation.layout) end,
        function(fields) return Mem.record(id, fields) end, S.id_components)
    local library = require('nua.storage')
    local api = t.kind == 'store' and library.store(t, id, p) or library.grow(t, p)
    api.layout = p
    storage_libraries[t] = api
    return api
end

Mem.storage_library = storage_library

-- The operations of a container are the library's words (lib/storage.nua) over a Ref to
-- the owner; their effects on borrows are stated there (design §10.1). The adapter only
-- resolves the receiver and applies the language's index rule (D2: any unsigned integer)
-- to the arguments that are indices.
local function library_methods(t, names, index_args)
    local n = cname_of(t)
    local methods = {}
    for _, name in ipairs(names) do
        methods[name] = function(self, ...)
            local p = receiver(self, n .. ':' .. name)
            local b = S.cur()
            if b.fn then b.fn.uses_rt = true end
            local count = select('#', ...)
            local args = { ... }
            for _, i in ipairs(index_args[name] or {}) do args[i] = S.index_value(args[i]) end
            return storage_library(t)[name](S.Ref(p), (table.unpack or unpack)(args, 1, count))
        end
    end
    return methods
end

local function store_methods(t)
    return library_methods(t, { 'add', 'remove', 'has' }, {})
end

local function grow_methods(t)
    local n = cname_of(t)
    local methods = library_methods(t, { 'push', 'pop', 'truncate', 'clear' }, { truncate = { 1 } })
    -- the elements as a read-only slice borrowing the Grow, of the length it has now:
    -- growing keeps the slice valid (stacks never move); clear, pop and truncate end it
    methods.all = function(self)
        local p = receiver(self, n .. ':all')
        if not S.cur().fn then fail(n .. ' is runtime storage: it is viewed where it runs') end
        return storage_library(t).all(S.Ref(p))
    end
    methods.sub = function(self, a, z)
        local xs = methods.all(self)
        return S.member_slice(xs, 'sub')(xs, a, z)
    end
    return methods
end

-- s[id] and g[i]: an element as a checked place. Its address is computed (and
-- checked: the Id is current, the index in range) when used, and reused for the
-- same index until something could change the storage, which is found again then
local function index_hook(t)
    local n = cname_of(t)
    return function(x, key)
        local p = receiver(x, t.kind == 'store' and n .. '[id]' or n .. '[i]')
        -- an index is any unsigned integer, checked as U64 (design memory.md §15 D2)
        local k = t.kind == 'store' and S.coerce(key, types.id(t.elem), 'Id') or S.index_value(key)
        k = fix_index(k, 'capturing a storage index')
        local function resolve() return S.ex(storage_library(t).locate(S.Ref(p), k)) end
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        local place = S.checked_place(t.elem, nil, nil, true, resolve,
            n .. '/' .. S.expr_key(addr(p)) .. '/' .. S.expr_key(S.ex(k)))
        -- an element is the container's contents: borrows of it, and borrows
        -- stored in it, are checked against the container's owner
        rawset(place, 'owner_place', p)
        return place
    end
end

local function length(x)
    local p = receiver(x, 'length')
    return storage_library(p.T).length(S.Ref(p))
end

-- type constructors ----------------------------------------------------------------------------

-- Text is Grow U8 with text methods of its own: decorating again must add the
-- storage methods to what the type already offers, not replace them.
local function merge_methods(t, methods)
    local have = rawget(t, 'builtin_methods')
    if not have then return methods end
    for k, f in pairs(methods) do have[k] = f end
    return have
end
local function merge_properties(t, properties)
    local have = rawget(t, 'properties')
    if not have then return properties end
    for k, f in pairs(properties) do have[k] = f end
    return have
end

-- Storage types are interned across compilations, but their methods close over
-- Nua words of one compilation: decorate again for each one.
local function decorate(t)
    if rawget(t, 'decorated_for') == S.module then return t end
    rawset(t, 'decorated_for', S.module)
    rawset(t, 'decorated', true)
    rawset(t, 'ctype', function() return cname_of(t) end)
    rawset(t, 'native_layout', function() return layout_of(t).layout end)
    rawset(t, 'cdecl', function() return 'typedef ' .. layout_of(t).layout.cname .. ' ' .. cname_of(t) .. ';' end)
    if t.kind == 'store' then
        local ms = store_methods(t)
        local ar = { add = 2, remove = 2, has = 2 }
        for k, f in pairs(ms) do S.arity[f] = ar[k] end
        rawset(t, 'builtin_methods', merge_methods(t, ms))
        rawset(t, '__index', index_hook(t))
        rawset(t, 'properties', merge_properties(t, { length = length }))
        S.member_tables(t)
        rawset(t, 'construct', function(x)
            if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                fail(t.display .. ' {} takes no fields')
            end
            return fresh(t)
        end)
    elseif t.kind == 'rtarray' then
        -- the elements of an Array T are borrowed like a Grow's; its length is
        -- fixed, so it has no push and no clear
        local all = grow_methods(t)
        local ms = { all = all.all, sub = all.sub }
        S.arity[ms.all], S.arity[ms.sub] = 1, 3
        rawset(t, 'builtin_methods', merge_methods(t, ms))
        rawset(t, '__index', index_hook(t))
        rawset(t, 'properties', merge_properties(t, { length = length }))
        S.member_tables(t)
        rawset(t, 'construct', function(x)
            fail(t.display .. ' is built with its length: Array(' .. t.elem.display .. ', n) {}')
        end)
    elseif t.kind == 'grow' then
        local ms = grow_methods(t)
        local ar = { push = 2, all = 1, sub = 3, clear = 1, pop = 1, truncate = 2 }
        for k, f in pairs(ms) do S.arity[f] = ar[k] end
        rawset(t, 'builtin_methods', merge_methods(t, ms))
        rawset(t, '__index', index_hook(t))
        rawset(t, 'properties', merge_properties(t, { length = length }))
        S.member_tables(t)
        rawset(t, 'construct', function(x)
            if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                fail(t.display .. ' {} takes no fields')
            end
            return fresh(t)
        end)

    end
    return t
end

local function checked(make, what)
    return function(elem)
        local ok, t = pcall(make, elem)
        if not ok then fail(tostring(t):gsub('^[^:]+:%d+: ', '')) end
        if t.elem.kind == 'struct' and t.elem.resizable then
            fail(what .. ' holds fixed-size values; ' .. t.elem.display .. ' contains resizable storage')
        end
        return decorate(t)
    end
end

S.owner_leaves = Mem.owner_leaves
-- the index of result stack j (gs_res + j), or of this function's own stack k
function S.result_stack_value(j, k)
    if j then return Mem.stack_index({ res = j }) end
    return Mem.stack_index(k)
end
-- releasing a call's result rewinds its reserved stack to where it stood
-- before the call: the result, and what the callee left below it
function S.stack_rewinder(k)
    local stacks = require('nua.stacks')
    local start = capture(stacks.top(Mem.stack_index(k)), 'the top before a call')
    return function()
        stacks.reset(Mem.stack_index(k), start)
    end
end
-- what releases an owner place's stacks, through its header
function S.place_releases(p)
    local out = {}
    for _, leaf in ipairs(Mem.owner_leaves(p)) do
        for _, fields in ipairs(Mem.release_fields(leaf.place.T)) do
            out[#out + 1] = { place = leaf.place, free = releaser_for(leaf.place.T, fields) }
        end
    end
    return out
end
function S.release_place(p)
    for _, r in ipairs(S.place_releases(p)) do r.free(r.place) end
end

-- for nua.strings: Text is Grow U8 with text methods
Mem.receiver, Mem.capture, Mem.addr = receiver, capture, addr

Mem.Store = checked(types.store, 'Store')
Mem.Grow = checked(types.grow, 'Grow')
Mem.RtArray = checked(types.rtarray, 'Array')

-- Array(T, n) {} with n known only at runtime: an Array T of n zeroed elements
function Mem.array_of_length(t, n)
    local v = fresh(t)
    rawset(v, 'length', S.index_value(n))
    return v
end
Mem.Id = checked(types.id, 'Id')

-- Private representation projection for library words over opaque handles.
-- No encoding, comparison or hashing policy belongs in this compiler hook.
function S.id_components(x)
    local v = S.value_of(x, nil, 'Id components')
    if v.T.kind ~= 'id' then fail('Id components require an Id') end
    local e = S.ex(v)
    local function field(name, t)
        return S.dyn(t, { op = 'field', a = e, name = name, T = t })
    end
    return field('token', types.U64), field('slot', types.U32), field('gen', types.U32)
end

function Mem.prelude(env)
    env.Store, env.Grow, env.Id = Mem.Store, Mem.Grow, Mem.Id
    env.copy = Mem.copy
    env.Array = function(elem, n)
        if n == nil then return Mem.RtArray(elem) end
        if S.is_staged(n) and not S.is_known(S.value_of(n)) then
            -- a runtime length: the constructor of an Array T owner
            local t = Mem.RtArray(elem)
            return setmetatable({}, { __call = function(_, x)
                if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                    fail(('Array(%s, n) {} with n known only at runtime starts zeroed; it takes no '
                        .. 'elements'):format(elem.display))
                end
                return Mem.array_of_length(t, n)
            end })
        end
        if S.is_staged(n) then n = tonumber(S.value_of(n).v) end
        return S.Array(elem, n)
    end
    S.arity[Mem.copy] = 1
end

return Mem
