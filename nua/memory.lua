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
-- stage reaches the few memory hooks it calls back (arena events) through S.Mem
S.Mem = Mem
local Builder = S.Builder
local dyn, known = S.dyn, S.known
local storage_library

local function fail(msg) S.fail(msg, 2) end
local function fresh(t) return setmetatable({ T = t, k = 'fresh' }, S.V) end

-- C names supplied by the backend: NodeStore, NodeId, U8Grow
local cname_of
local function elem_name(t)
    if t.kind == 'struct' then return require('nua.cgen').ctype(t) end
    if t.kind == 'owner' or t.kind == 'id' then return cname_of(t) end
    if t.kind == 'ref' then return elem_name(t.elem) .. 'Ref' end
    return t.name
end

-- The library owner types (design memory.md §10.1): each is a declaration made by a Nua
-- library module with `owner_type` (lib/owners.nua), and the generic code below reads
-- it. A new owner type is a new declaration, not a new branch in the compiler.
local families = {}
local function family_of(t) return rawget(t, 'family') and families[t.family] end

function cname_of(t)
    if rawget(t, 'cname') then return t.cname end    -- a family that names its own types (setup)
    local f = family_of(t)
    if f then return elem_name(t.elem) .. f.suffix end
    if t.kind == 'id' then return elem_name(t.elem) .. 'Id' end
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
    if t.kind == 'sum' then return { layout = layouts_module().Bookkeeping } end
    local cache = derived[S.module]
    if not cache then cache = {}; derived[S.module] = cache end
    local r = cache[t]
    if r then return r end
    local layouts = layouts_module()
    local f = family_of(t)
    r = { layout = f and f.header or layouts.Id }
    if f and f.slot then
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
    -- a sum: its first stack's slot releases the live payload and resets them all
    if t.kind == 'sum' then
        if fields and fields.offset ~= 0 then return function() end end
        return function(place) Mem.release_sum(place) end
    end
    local representation = layout_of(t).layout
    fields = fields or { 'stack', 'base' }
    local cleanup = require('nua.storage_layout').releaser(representation, fields[1], fields[2], fields.offset)
    return function(place) cleanup(Mem.view(place, representation)) end
end
Mem.releaser_for = releaser_for

-- the residual block whose end releases an owner held by place p: the block
-- its root local was declared in
-- which stack of an owner's header a slot releases: a field pair, and for an arena (an
-- owner position of its elements, §5.9) its offset from the owner's first stack
local function fields_key(fields)
    if not fields then return 'stack/base' end
    return table.concat(fields, '/') .. (fields.offset and ('+' .. fields.offset) or '')
end

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
    -- an arena tenant's stack: the holder's arena, an index value
    if type(k) == 'table' and k.arena then return k.arena end
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

-- Arena tenants (design memory.md §5.3, §5.9 R3). An owner this function allocates and then
-- stores into a container's element is built, on the next build of the function, at the top
-- of that container's arenas, where the element takes over its header: nothing is copied.
-- It stays the top of those stacks for its whole life, so it keeps a one-tenant owner's
-- growth and borrow rules: the placement holds only while nothing else touches the arenas
-- (an arena event: an element growing, compaction, an element built there, the holder
-- released or handed on, another tenant, a call that reaches the holder). Placements are
-- found in one build and made in the next (fn.arena_allocs, by allocation ordinal, as
-- result placements are); a placement whose quiet window turns out to be broken is
-- revoked (false) and the owner is copied, as before. Behaviour never depends on it.
local clock = 0
function Mem.tick() clock = clock + 1; return clock end

-- the storage an owner's own stacks are, as a key: its first index, its parameter, or the
-- call result it adopted
local function slot_key(slots)
    local first, low = slots[1], nil
    if not first then return nil end
    for _, s in ipairs(slots) do
        if s.k and not (s.fields and s.fields.offset) and (not low or s.k < low) then low = s.k end
    end
    if low then return 'k' .. low end
    if first.param then return 'p' .. first.param end
    if first.ordinal and not first.tenant then return 'o' .. first.ordinal end
    return nil
end
function Builder:storage_key(p) return slot_key(self:slots_of(p)) end

-- the outermost holder of a place inside elements (its arenas are that holder's)
local function outer_holder(q)
    while q do
        local e = q
        while e and not (rawget(e, 'owner_place') and not (rawget(e, 'fname') or ''):match('^as%.')) do
            e = rawget(e, 'parent')
        end
        if not e then return q end
        q = rawget(e, 'owner_place')
    end
    return q
end

function Builder:arena_event_key(key)
    self.arena_events = self.arena_events or {}
    self.arena_events[#self.arena_events + 1] = { key = key or '*', at = Mem.tick() }
end
-- an arena event at the storage of the holder x lies in (a place or a Ref)
function Mem.arena_event(x)
    local b = S.cur()
    if not (b and b.fn) then return end
    x = S.through(x)
    if S.is_value(x) and x.k == 'ref' then x = x.place end
    local key
    if S.is_place(x) then
        local q = outer_holder(x)
        if q and q.T.resizable and not Mem.shared_position(q) then key = b:storage_key(q) end
    end
    b:arena_event_key(key)
end
-- nothing touched the storage `key` since `since`
function Builder:arena_quiet(key, since)
    for _, e in ipairs(self.arena_events or {}) do
        if e.at > since and (e.key == key or e.key == '*') then return false end
    end
    return true
end
-- a placement to make, or to revoke, on the next build (signalled when the build ends)
function Builder:pend_arena(ordinal, spec)
    local fn = self.fn
    fn.pending_arena = fn.pending_arena or {}
    if fn.pending_arena[ordinal] == false then return end
    fn.pending_arena[ordinal] = spec
end
function Builder:revoke_tenant(rec) self:pend_arena(rec.ordinal, false) end
-- the holder a placement names, as it stands now: its newest slot over that storage
function Builder:find_holder(desc)
    local best
    for _, s in ipairs(self:all_slots()) do
        local hit = (desc.param and s.param == desc.param) or (desc.ordinal and s.ordinal == desc.ordinal)
        if hit and not (s.fields and s.fields.offset) and not S.moved_on_path(self.state, s.place)
            and S.held_on_path(self.state, s.place) then
            if not best or s.serial > best.serial then best = s end
        end
    end
    return best
end
-- the first stack of the holder, as an index value: static for one of this function's own
-- owners, read from its header otherwise
function Builder:holder_first(hs)
    local low
    for _, s in ipairs(self:slots_of(hs.place)) do
        if s.k and not (s.fields and s.fields.offset) and (not low or s.k < low) then low = s.k end
    end
    if low then return low end
    local header = Mem.storage_library(hs.place.T).layout.header(S.Ref(hs.place))
    local first = S.dot(header, 'stack')
    if S.is_place(first) then first = self:read(first) end
    return Mem.capture(first, "the holder's first stack")
end
-- the index value of stack i (from 0) of a placement
function Builder:arena_index(first, offset, i)
    if type(first) == 'number' then return Mem.stack_index(first + offset + i) end
    return first + (offset + i)
end
-- start a tenant of the placement `spec` for allocation `ordinal`: its record, or nil (revoked)
function Builder:open_tenant(ordinal, spec, n)
    local hs = self:find_holder(spec.holder)
    if not hs or n ~= spec.n then self:pend_arena(ordinal, false); return nil end
    local key = slot_key(self:slots_of(hs.place))
    self:arena_event_key(key)
    return { key = key, offset = spec.offset, ordinal = ordinal, at = Mem.tick(),
             first = self:holder_first(hs) }
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
    slot.release = function()
        -- a tenant leaves the arenas' top here: its window must have stayed quiet
        local rec = slot.tenant
        if rec and not self:arena_quiet(rec.key, rec.at) then self:revoke_tenant(rec) end
        -- a holder released: its arenas go with it
        local key = not rec and slot_key({ slot })
        if key then self:arena_event_key(key) end
        slot.free(slot.place)
    end
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

-- An owner's stacks, one per entry of its release fields, as one allocation: a run of
-- consecutive indices (or result stacks), so the stack of each owner position of its
-- elements is its first stack plus a fixed offset (design memory.md §5.9, R2).
function Builder:gs_alloc(p, list)
    if not self.fn then
        fail('a ' .. p.T.display .. ' is runtime storage; it cannot be created at compile time')
    end
    local ordinal, j = self:next_allocation()
    local n = #list
    if n > 1 then
        self.alloc_spans = self.alloc_spans or {}
        self.alloc_spans[ordinal] = math.max(self.alloc_spans[ordinal] or 0, n)
    end
    local out = {}
    if j then
        for i, fields in ipairs(list) do
            self:register_slot { place = p, res = j + i - 1, ordinal = ordinal, free = releaser_for(p.T, fields),
                                 fields = fields }
            out[i] = { res = j + i - 1 }
        end
        return out
    end
    local spec = self.fn.arena_allocs and self.fn.arena_allocs[ordinal]
    local rec = spec and self:open_tenant(ordinal, spec, n)
    if rec then
        for i, fields in ipairs(list) do
            self:register_slot { place = p, ordinal = ordinal, tenant = rec, alloc_at = rec.at,
                                 free = releaser_for(p.T, fields), fields = fields }
            out[i] = { arena = self:arena_index(rec.first, rec.offset, i - 1) }
        end
        return out
    end
    local at = Mem.tick()
    self.gs_live = self.gs_live or {}
    local k = 0
    while true do
        local free = true
        for i = 0, n - 1 do if self.gs_live[k + i] then free = false break end end
        if free then break end
        k = k + 1
    end
    for i, fields in ipairs(list) do
        self:register_slot { place = p, k = k + i - 1, ordinal = ordinal, free = releaser_for(p.T, fields),
                             fields = fields, alloc_at = at }
        out[i] = k + i - 1
    end
    return out
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
            local key = fields_key(slot.fields)
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
            local key = tostring(rawget(slot.place, 'id')) .. ':' .. (slot.fields and fields_key(slot.fields) or '')
            if not done[key] and not self.dead then slot.release() end
            done[key] = true
            if why then
                S.end_place(slot.place, why)
                for _, q in ipairs(slot.aliases) do S.end_place(q, why) end
            end
        end
    end
end

-- the stack fields of an owner type's own header, as (stack, base) pairs
function Mem.own_fields(t)
    -- a sum holding owners has none of its own: its payloads' (design memory.md §5.9)
    if t.kind == 'sum' then return {} end
    return rawget(t, 'release_fields') or { { 'stack', 'base' } }
end

-- Owner positions (design memory.md §5.9, R2). An owner holds its own stacks, then one
-- stack per owner position of its elements (or map values): their arenas, shared by every
-- element. The count is static; the order is the elements' owners, depth first.
function Mem.position_count(u)
    if u.kind == 'struct' then
        local n = 0
        for _, f in ipairs(u.fields) do if f.type.resizable then n = n + Mem.position_count(f.type) end end
        return n
    end
    if not u.resizable then return 0 end
    -- a sum's alternatives share its stacks: as many as its largest needs
    if u.kind == 'sum' then
        local n = 0
        for _, a in ipairs(u.alts) do n = math.max(n, Mem.position_count(a.type)) end
        return n
    end
    local elem = rawget(u, 'elem')
    return #Mem.own_fields(u) + ((elem and elem.resizable) and Mem.position_count(elem) or 0)
end

-- every stack an owner type holds, as (stack, base) pairs: its own, then its arenas. A
-- root owner begins at one offset on all of its stacks, so an arena is released to the
-- owner's own base, on the stack at its offset from the first.
function Mem.release_fields(t)
    if t.kind == 'sum' then
        local out = {}
        for i = 1, Mem.position_count(t) do out[i] = { 'stack', 'base', offset = i - 1, sum = true } end
        return out
    end
    local own = Mem.own_fields(t)
    local elem = rawget(t, 'elem')
    if not (elem and elem.resizable) then return own end
    local out = { unpack(own) }
    local first = own[1] or { 'stack', 'base' }
    for i = 1, Mem.position_count(elem) do
        out[#out + 1] = { first[1], first[2], offset = #own + i - 1 }
    end
    return out
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
                                 tenant = at.tenant, alloc_at = at.alloc_at,
                                 fields = (fields[1] ~= 'stack' or fields.offset) and fields or nil }
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
        for _, slot in ipairs(slots) do
            releases[#releases + 1] = { place = leaf.place, free = slot.free }
            -- a callee may use its arenas, and a tenant handed on would leave them in use
            if slot.tenant then self:revoke_tenant(slot.tenant) end
        end
        self:arena_event_key(slot_key(slots) or (slots[1] and slots[1].tenant and slots[1].tenant.key))
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
    -- an owner inside an element: its holder's arenas hold the contents (§5.9)
    if Mem.element_of(p) then return self:overwrite_element(p, v) end
    local global = rawget(S.root_of(p), 'owner_global')
    if global then return self:init_global(p, global, v) end
    if p.T.kind == 'sum' and S.is_value(v) and (v.k == 'sumv' or (v.k == 'fresh' and rawget(v, 'copy_of'))) then
        return self:init_sum(p, v)
    end
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
    -- one slot per stack the owner holds, then its init word over their indices
    local all = Mem.release_fields(p.T)
    local indices, ks = {}, self:gs_alloc(p, all)
    for i, k in ipairs(ks) do indices[i] = Mem.stack_index(k) end
    rawset(p, 'gs_k', ks[1])
    local elements = rawget(v, 'elements')
    -- an owner with arenas begins at one offset on all of its stacks, each arena with
    -- its record (§5.9)
    if #all > #Mem.own_fields(p.T) then
        local stacks = require('nua.stacks')
        local base = Mem.capture(stacks.level(indices[1], #all), "an owner's base")
        for i, fields in ipairs(all) do
            if fields.offset then stacks.open_arena(indices[i], base) end
        end
    end
    p.T.init_word(p, indices, { copy_of = source, text = text, length = count, items = items, elements = elements })
end

-- Build the owners of a value into a place on the stacks `indices` (one-tenant: a sum's
-- payload). Each owner takes its run of them, arenas opened at `base`; a named owner is
-- copied and ends here, a fresh one is built there; other fields are stored as values.
function Builder:init_on(dst, indices, base, value, copying)
    local stacks = require('nua.stacks')
    local offset = 0
    local named = {}
    local function put(d, q)
        if d.T.kind == 'struct' then
            for _, f in ipairs(d.T.fields) do
                local dd = S.field_place(d, f.name)
                local qq
                if S.is_place(q) then qq = S.field_place(q, f.name) else qq = q.f[f.name] end
                if f.type.resizable then put(dd, qq) else self:store(dd, S.is_place(qq) and self:read(qq) or qq) end
            end
            return
        end
        local all = Mem.release_fields(d.T)
        local sub = {}
        for i = 1, #all do sub[i] = indices[offset + i] end
        offset = offset + #all
        for i, fields in ipairs(all) do
            if fields.offset then stacks.open_arena(sub[i], base) end
        end
        if S.is_place(q) then
            S.check_usable(q)
            d.T.init_word(d, sub, { copy_of = q })
            if not copying then named[#named + 1] = q end
        else
            d.T.init_word(d, sub, { copy_of = rawget(q, 'copy_of'), text = rawget(q, 'copy_text'),
                                    length = rawget(q, 'length'), items = rawget(q, 'copy_slice') })
        end
    end
    put(dst, value)
    for _, q in ipairs(named) do
        self:release_owner(q, ("'%s' was moved into '%s'"):format(tostring(q.name), tostring(dst.name)))
        S.mark_moved(q, dst, {})
    end
end

-- A sum holding owners receives a variant (design memory.md §5.9): the old payload ends, the
-- sum takes its stacks (as many as its largest alternative needs) at one base, keeps where
-- they began, and its payload's owners are built on them.
function Builder:init_sum(p, v)
    S.check_usable(p, true)
    self:release_owner(p, ("'" .. tostring(p.name) .. "' was given another variant"))
    S.clear_moved(p)
    local all = Mem.release_fields(p.T)
    local indices, ks = {}, self:gs_alloc(p, all)
    for i, k in ipairs(ks) do indices[i] = Mem.stack_index(k) end
    rawset(p, 'gs_k', ks[1])
    local base = Mem.capture(require('nua.stacks').level(indices[1], #all), "a sum's base")
    self:sum_on(p, indices, base, v)
end

-- Build a variant into the sum place p, whose stacks are `indices` from `base`: a variant
-- value, `copy s` (fresh, with copy_of), a named sum (copied: `copying` says it does not
-- end here), or nothing (the first alternative, its owners empty). The sum keeps where its
-- stacks began; its payload's owners are built on them.
function Builder:sum_on(p, indices, base, v, copying)
    local layouts = layouts_module()
    local source = S.is_place(v) and v or (v and rawget(v, 'copy_of'))
    local function keep() layouts.keep(Mem.view(p, layouts.Bookkeeping), indices[1], base) end
    if source then
        -- whichever variant it holds, its payload's owners copied onto these stacks
        S.check_usable(source)
        local named = S.is_place(v) and not copying
        source = S.resolve_checked(source)
        for _, a in ipairs(p.T.alts) do
            S.when_variant(source, a, function()
                if a.type.resizable then
                    self:emit { op = 'store', place = p, what = 'a variant',
                                e = { op = 'sum', T = p.T, alt = a.name, e = { op = 'zero', T = a.type } } }
                    keep()
                    self:init_on(S.payload_place(p, a), indices, base, S.payload_place(source, a), true)
                else
                    self:emit { op = 'store', place = p, e = S.read_expr(source), what = 'a variant' }
                    keep()
                end
            end)
        end
        if named then
            self:release_owner(v, ("'%s' was moved into '%s'"):format(tostring(v.name), tostring(p.name)))
            S.mark_moved(v, p, {})
        end
        return
    end
    if v == nil then
        -- the first alternative, its owners empty
        local first = p.T.alts[1]
        v = first.type.resizable and S.constructor(p.T, first.name)(Mem.empty_value(first.type))
            or S.zero_value(p.T)
    end
    local alt = p.T.index[rawget(v, 'tag')]
    local payload = rawget(v, 'p')
    if not self.dead then
        if alt.type.resizable then
            self:emit { op = 'store', place = p, what = 'a variant',
                        e = { op = 'sum', T = p.T, alt = alt.name, e = { op = 'zero', T = alt.type } } }
        else
            self:emit { op = 'store', place = p, e = S.ex(v), what = 'a variant' }
        end
    end
    keep()
    if alt.type.resizable then self:init_on(S.payload_place(p, alt), indices, base, payload) end
end

-- A sum's stacks end: its live payload's owners first (their arenas), then every stack of
-- the sum returns to its base
function Mem.release_sum(place)
    local layouts = layouts_module()
    local stacks = require('nua.stacks')
    for _, alt in ipairs(place.T.alts) do
        if alt.type.resizable then
            S.when_variant(place, alt, function() S.release_place(S.payload_place(place, alt)) end)
        end
    end
    local h = Mem.view(place, layouts.Bookkeeping)
    local first, base = S.dot(h, 'stack'), S.dot(h, 'base')
    local b = S.cur()
    if S.is_place(first) then first = b:read(first) end
    if S.is_place(base) then base = b:read(base) end
    for i = 0, Mem.position_count(place.T) - 1 do stacks.reset(first + i, base) end
end

-- An owner global receives an owner (design memory.md §5.10): on its reserved stacks, which
-- never move to another owner. `fresh` is the setup at its first use; afterwards the old
-- contents end first. A named owner is copied and ends here.
function Builder:init_global(p, g, v, first_use)
    local stacks = require('nua.stacks')
    if not first_use then
        S.check_usable(p, true)
        S.end_borrows(p, ("'" .. tostring(g.name) .. "' was replaced"))
        S.release_place(p)
    end
    local offset = g.first
    local named = {}
    local function put(d, q)
        if d.T.kind == 'struct' then
            for _, f in ipairs(d.T.fields) do
                local dd = S.field_place(d, f.name)
                local qq = S.is_place(q) and S.field_place(q, f.name) or (q and q.f and q.f[f.name])
                if f.type.resizable then put(dd, qq)
                elseif qq ~= nil then self:store(dd, S.is_place(qq) and self:read(qq) or qq) end
            end
            return
        end
        local all = Mem.release_fields(d.T)
        local indices = {}
        for i = 1, #all do indices[i] = S.known(types.U64, offset + i - 1) end
        offset = offset + #all
        -- a sum: its variant, its payload's owners on its stacks; a named sum is copied
        -- and ends in sum_on, nothing is the first alternative with its owners empty
        if d.T.kind == 'sum' then
            local base = Mem.capture(stacks.level(indices[1], #all), "an owner global's base")
            self:sum_on(d, indices, base, q)
            return
        end
        if #all > #Mem.own_fields(d.T) then
            local base = Mem.capture(stacks.level(indices[1], #all), "an owner global's base")
            for i, fields in ipairs(all) do
                if fields.offset then stacks.open_arena(indices[i], base) end
            end
        end
        if S.is_place(q) then
            S.check_usable(q)
            d.T.init_word(d, indices, { copy_of = q })
            named[#named + 1] = q
        else
            q = q or {}
            d.T.init_word(d, indices, { copy_of = rawget(q, 'copy_of'), text = rawget(q, 'copy_text'),
                                        length = rawget(q, 'length'), items = rawget(q, 'copy_slice'),
                                        elements = rawget(q, 'elements') })
        end
    end
    put(p, v)
    stacks.keep_owner_globals(S.known(types.U64, offset))
    for _, q in ipairs(named) do
        self:release_owner(q, ("'%s' was moved into '%s'"):format(tostring(q.name), tostring(g.name)))
        S.mark_moved(q, p, {})
    end
end
local ensures = setmetatable({}, { __mode = 'k' })
function S.ensure_owner_global(g)
    local per = ensures[S.module]
    if not per then per = {}; ensures[S.module] = per end
    local ensure = per[g]
    if not ensure then
        local name = S.global_cname(g)
        ensure = require('nua.storage').owner_global(name, function()
            S.cur():init_global(S.global_place(g), g, nil, true)
        end)
        per[g] = ensure
    end
    local b = S.cur()
    if not b.fn then fail("'" .. tostring(g.name) .. "' is an owner global: it is runtime storage, used where it runs") end
    ensure()
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
        local v = fresh(Mem.owners.Grow(types.U8))
        rawset(v, 'copy_text', x)
        return v
    end
    if S.is_value(x) and rawget(x.T, 'slice_elem') then
        local v = fresh(Mem.owners.Array(rawget(x.T, 'slice_elem')))
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
            if Mem.shared_position(q) then
                fail(("an owner inside an element cannot be moved out of it (its bytes live in its "
                    .. "container's arena); copy it (copy %s), or pop it out of the container"):format(
                    tostring(rawget(rawget(root, 'owner_place') or root, 'name')) .. '[...]'))
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
                                 tenant = slot.tenant, alloc_at = slot.alloc_at,
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

-- Is an owner place at a shared position (design memory.md §5.9, R2): inside an element
-- of a container, whose arena it shares with the other elements? Known while compiling:
-- an element is a checked place of its container, and a word compiled on its own is
-- specialized on whether each Ref argument is one.
-- the payload of a sum is reached like an element (its borrows are the sum's contents), but
-- a sum holds one payload at a time: inside a one-tenant sum it is one-tenant too
local function payload_place(q)
    local name = rawget(q, 'fname')
    return type(name) == 'string' and name:sub(1, 3) == 'as.'
end
function Mem.shared_position(x)
    x = S.through(x)
    if S.is_value(x) and x.k == 'ref' then x = x.place end
    if not S.is_place(x) then return false end
    local q = x
    while q do
        if (rawget(q, 'owner_place') and not payload_place(q)) or rawget(q, 'shared') then return true end
        q = rawget(q, 'parent')
    end
    return false
end
S.one_tenant_payload = function(q) return payload_place(q) and not Mem.shared_position(rawget(q, 'parent')) end
S.shared_position = Mem.shared_position

-- A named owner q stored into the element owner d of holder hp at position `at`: a tenant
-- of that very placement is adopted (d takes its header; q ends without releasing). An owner
-- this function allocated, whose life so far left hp's arenas quiet, is placed there on the
-- next build. Returns whether q was adopted.
function Builder:adopt_tenant(hp, d, q, at)
    local slots = self:slots_of(q)
    local first = slots[1]
    if not (first and self.fn) or Mem.shared_position(hp) then return false end
    local hkey = self:storage_key(hp)
    local rec = first.tenant
    if rec then
        if rec.key ~= hkey or rec.offset ~= at then return false end
        if not self:arena_quiet(rec.key, rec.at) then
            self:revoke_tenant(rec)
            return false
        end
        if not self.dead then
            self:emit { op = 'store', place = d, e = S.read_expr(q), what = 'a tenant becomes the element' }
        end
        S.end_place(q, ("'%s' was moved into an element"):format(tostring(q.name)))
        S.mark_moved(q, d, {})
        return true
    end
    if not hkey or Mem.position_count(q.T) ~= #Mem.own_fields(q.T) then return false end
    local o = first.ordinal
    if not o or not first.alloc_at then return false end
    for _, sl in ipairs(slots) do
        if sl.ordinal ~= o or sl.res or sl.param or sl.tenant then return false end
    end
    if (self.fn.arena_allocs and self.fn.arena_allocs[o] ~= nil)
        or (self.fn.result_allocs and self.fn.result_allocs[o]) then return false end
    if not first.k then
        -- a call result: built in place only from a call that cannot reach the holder
        local rc = self.result_calls and self.result_calls[o]
        if not (rc and rc.arena_ok and not rc.keys[hkey] and not rc.keys['*']) then return false end
    end
    local hs = self:slots_of(hp)[1]
    if (hs.alloc_at or 0) >= first.alloc_at then return false end
    if not self:arena_quiet(hkey, first.alloc_at) then return false end
    self:pend_arena(o, { holder = { ordinal = not hs.param and hs.ordinal or nil, param = hs.param },
                         offset = at, n = #slots })
    return false
end

-- Build owners into a place inside an element of the holder hp: `offset` is the position of
-- the place's first owner, counted from the holder's first stack. The source is a named owner
-- (copied: bytes always live on their position's stack), a fresh owner (built in place), or
-- a struct value holding them; value fields are stored as values.
local function put_owner(hp, dst, offset, value)
    local b = S.cur()
    local header = storage_library(hp.T).layout.header(S.Ref(hp))
    local first = S.dot(header, 'stack')
    if S.is_place(first) then first = b:read(first) end
    first = Mem.capture(first, "the holder's first stack")
    local put
    -- a sum: its variant, and its payload's owners at its positions (shared by the alternatives)
    local function put_sum(d, q)
        local start = offset
        local function variant(alt, payload)
            if not b.dead then
                b:emit { op = 'store', place = d, what = 'a variant',
                         e = { op = 'sum', T = d.T, alt = alt.name, e = { op = 'zero', T = alt.type } } }
            end
            offset = start
            put(S.payload_place(d, alt), payload)
        end
        if S.is_value(q) and q.k == 'sumv' then
            local alt = d.T.index[rawget(q, 'tag')]
            if alt.type.resizable then variant(alt, rawget(q, 'p'))
            elseif not b.dead then b:emit { op = 'store', place = d, e = S.ex(q), what = 'a variant' } end
        else
            q = S.resolve_checked(q)
            for _, alt in ipairs(d.T.alts) do
                S.when_variant(q, alt, function()
                    if alt.type.resizable then variant(alt, S.payload_place(q, alt))
                    else b:emit { op = 'store', place = d, e = S.read_expr(q), what = 'a variant' } end
                end)
            end
        end
        offset = start + Mem.position_count(d.T)
    end
    function put(d, q)
        if d.T.kind == 'sum' then return put_sum(d, q) end
        if d.T.kind == 'struct' then
            for _, f in ipairs(d.T.fields) do
                local dd = S.field_place(d, f.name)
                local qq
                if S.is_place(q) then qq = S.field_place(q, f.name)
                elseif S.is_value(q) and q.k == 'agg' then qq = q.f[f.name]
                else fail('storing a ' .. d.T.display .. ' into an element needs a value of it') end
                if f.type.resizable then put(dd, qq) else b:store(dd, S.is_place(qq) and b:read(qq) or qq) end
            end
            return
        end
        local indices = {}
        local at = offset
        for i = 1, #Mem.release_fields(d.T) do indices[i] = first + (offset + i - 1) end
        offset = offset + #Mem.release_fields(d.T)
        if S.is_place(q) and b:adopt_tenant(hp, d, q, at) then
            -- built where it lands: the element takes over its header
        elseif S.is_place(q) then
            Mem.arena_event(hp)
            d.T.init_word(d, indices, { copy_of = q })
        elseif S.is_value(q) and q.k == 'fresh' then
            Mem.arena_event(hp)
            d.T.init_word(d, indices, { copy_of = rawget(q, 'copy_of'), text = rawget(q, 'copy_text'),
                                        length = rawget(q, 'length'), items = rawget(q, 'copy_slice') })
        else
            fail('storing a ' .. d.T.display .. ' into an element needs an owner, got ' .. S.describe(q))
        end
    end
    put(dst, value)
end

-- An owner stored into an element (design memory.md §5.9, R3): the element's owners begin
-- on the holder's arenas, each at its position's offset from the holder's first stack, and
-- take a copy of the value's contents; its other fields are stored as values. The value
-- is an owner the calling word holds (its parameter), released where it ends: bytes always
-- live on their position's stack, so a move into an element copies them once.
Mem.put_owner = put_owner
function S.store_owner(holder, ptr, value)
    local hp = receiver(holder, 'storing an owner into an element')
    local src = receiver(value, 'storing an owner into an element')
    local v = S.value_of(ptr)
    put_owner(hp, S.element_place(v.T.elem, S.ex(v), hp), #Mem.own_fields(hp.T), src)
end

-- the element a place lies in, its holder, and the field path from the element to it
local function element_of(p)
    local path, q = {}, p
    while q and not (rawget(q, 'owner_place') and not payload_place(q)) do
        table.insert(path, 1, rawget(q, 'fname'))
        q = rawget(q, 'parent')
    end
    if not q then return nil end
    return q, rawget(q, 'owner_place'), path
end
Mem.element_of = element_of
-- a fresh value built into the element e refers to: its owners in the holder's arenas
S.build_into = function(e, value)
    local place = receiver(e, 'an element')
    local hp = rawget(place, 'owner_place')
    put_owner(hp, place, #Mem.own_fields(hp.T), value)
end
-- the outermost holder of an owner inside elements, as a Ref, when it is known while
-- compiling: a root's arenas are compacted from the root (design memory.md §5.9, R5)
S.root_holder = function(x)
    local q = receiver(x, 'an owner')
    while true do
        local _, holder = element_of(q)
        if not holder then break end
        q = holder
    end
    if Mem.shared_position(q) then return nil end
    return S.Ref(q)
end
-- the position of the owner at `path` inside an element of a holder of type t
local function position_at(t, path)
    local offset = #Mem.own_fields(t)
    local u = t.elem
    for _, name in ipairs(path) do
        for _, f in ipairs(u.fields) do
            if f.name == name then break end
            if f.type.resizable then offset = offset + Mem.position_count(f.type) end
        end
        u = u.index[name].type
    end
    return offset
end

-- An owner place inside an element receives an owner (`lines[i] = t`, `players[id].name = t`):
-- the old contents end (their borrows, and their bytes in the arenas, R5), the new ones are
-- built there, and a named source ends here: it was moved, and its bytes were copied.
function Builder:overwrite_element(p, v)
    local element, hp, path = element_of(p)
    local src = S.through(v)
    if S.is_value(src) and src.k == 'ref' then src = src.place end
    if S.is_place(src) then
        S.check_usable(src)
        if Mem.shared_position(src) then
            fail(("an owner inside an element cannot be moved out of it; copy it (copy %s), or pop it"):format(
                tostring(rawget(element_of(src) or src, 'name'))))
        end
    end
    local storage = require('nua.storage')
    S.end_borrows(p, ("an element of '%s' was replaced"):format(tostring(rawget(S.root_of(hp), 'name'))))
    storage.abandon(p.T, S.Ref(p))
    put_owner(hp, S.resolve_checked(p), position_at(hp.T, path), src)
    if S.is_place(src) then
        self:release_owner(src, ("'%s' was moved into an element"):format(tostring(src.name)))
        S.mark_moved(src, p, {})
    end
    storage.compact_root(S.Ref(hp))
end

-- Internal native representation projection: no owner checks or algorithms.
-- Public Ptr still rejects resizable owners; library adapters use this only
-- inside the compiler's existing ownership/checked-place integration.
function Mem.view(x, representation)
    -- an owner inside a container is a checked place: found again where it is used
    local p = S.resolve_checked(receiver(x, 'native representation'))
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
    local f = family_of(t)
    local id = f.ids and Mem.Id(t.elem)
    if id then layout_of(id) end
    local representation = layout_of(t)
    local p = f.projection and f.projection(t) or layout.storage(t, representation.layout, t.elem, representation.slot,
        function(x) return Mem.view(x, representation.layout) end,
        function(fields) return Mem.record(id, fields) end, S.id_components)
    local api = f.api(t, id, p)
    api.layout = p
    storage_libraries[t] = api
    return api
end

Mem.storage_library = storage_library
S.storage_library = storage_library
-- an array type whose elements are storage inside a header (FixedArray, design §5.9)
S.raw_array = function(elem, n) return types.array(elem, n, true) end
-- an empty value of a type that may hold owners: its owners fresh, its values zero
local function empty_value(t)
    if t.kind == 'owner' then return fresh(t) end
    if t.kind == 'struct' and t.resizable then
        local fields = {}
        for _, f in ipairs(t.fields) do fields[f.name] = empty_value(f.type) end
        return S.agg(t, fields)
    end
    return S.zero_value(t)
end
Mem.empty_value = empty_value
-- an element at ptr of the holder starts empty, its owners in the holder's arenas
S.init_element = function(holder, ptr)
    local hp = receiver(holder, 'an element')
    local v = S.value_of(ptr)
    Mem.put_owner(hp, S.element_place(v.T.elem, S.ex(v), hp), #Mem.own_fields(hp.T), empty_value(v.T.elem))
end
-- for the library's walks over owners inside elements (lib/storage.nua, design §5.9)
S.own_stack_count = function(t) return #Mem.own_fields(t) end
-- a Ref to an element at ptr of the holder: an owner inside it is at a shared position
S.element_ref = function(holder, ptr)
    local v = S.value_of(ptr)
    return S.Ref(S.element_place(v.T.elem, S.ex(v), receiver(holder, 'an element')))
end
-- a Ref to a field of the place a Ref names
S.ref_field = function(r, name)
    return S.Ref(S.field_place(receiver(r, 'a field'), name))
end

-- The arguments of a container operation, by what they are (a declaration's `args`):
--   index       any unsigned integer, checked as U64 (design memory.md §15 D2)
--   key         a key, converted to the family's key type
--   stored_key  a key that is stored or named later: captured where it is written
--   value       an element, converted and captured with the borrows it carries
local arg_kinds = {
    index = function(t, f, x) return S.index_value(x) end,
    key = function(t, f, x) return f.key(t, x) end,
    stored_key = function(t, f, x) return f.capture_key(t, f.key(t, x)) end,
    value = function(t, f, x)
        -- an owner moves (or is built) into the word's owner parameter, then into the element
        if t.elem.resizable then return x end
        local given = S.coerce(x, t.elem, (f.label or f.name) .. ' value')
        local view = S.value_view(given)
        local v = capture(given, 'capturing a ' .. string.lower(f.label or f.name) .. ' value')
        if view then rawset(v, 'view', view) end
        return v
    end,
}

-- the place a method receiver denotes, as the family wants it checked
local function owner_receiver(t, f, x, what)
    local p = receiver(x, what)
    if f.receive then f.receive(t, p) end
    return p
end

-- The operations of a container are the library's words (lib/storage.nua, lib/map.nua) over
-- a Ref to the owner; their effects on borrows are stated there (design §10.1). The adapter
-- only resolves the receiver and converts the arguments the declaration names.
local function adapter(t, f, name)
    local n = cname_of(t)
    local kinds = f.args[name] or {}
    local has_value = false
    for _, kind in ipairs(kinds) do has_value = has_value or kind == 'value' end
    return function(self, ...)
        local p = owner_receiver(t, f, self, f.keyed and t.display or n .. ':' .. name)
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        local count = select('#', ...)
        local args = { ... }
        for i, kind in ipairs(kinds) do args[i] = arg_kinds[kind](t, f, args[i]) end
        if has_value then S.bump_checked() end
        -- a fresh owner pushed or added is built in its new element (design memory.md §5.3)
        local lib = storage_library(t)
        local value = args[1]
        if t.elem.resizable and lib[name .. '_built'] and S.is_value(value)
            and (value.k == 'fresh' or value.k == 'sumv' or value.k == 'agg') then
            return lib[name .. '_built'](S.Ref(p), function(e) S.build_into(e, value) end)
        end
        return lib[name](S.Ref(p), (table.unpack or unpack)(args, 1, count))
    end
end
-- for a family's `extra` operations that are still one library word
function Mem.adapter(t, name) return adapter(t, family_of(t), name) end

local function library_methods(t, f)
    local methods = {}
    for _, name in ipairs(f.methods) do methods[name] = adapter(t, f, name) end
    return methods
end

local function view_methods(t)
    local n = cname_of(t)
    local methods = {}
    -- the elements as a read-only slice borrowing the owner, of the length it has now:
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

-- s[id], g[i] and m[k]: an element as a checked place. Its address is computed (and
-- checked: the Id is current, the index in range, the key present) when used, and reused
-- for the same index until something could change the storage, which is found again then
local function index_hook(t, f)
    local n = cname_of(t)
    return function(x, key)
        local keyed = f.index == 'key'
        local p = owner_receiver(t, f, x, keyed and t.display or (f.ids and n .. '[id]' or n .. '[i]'))
        local k
        if keyed then
            k = arg_kinds.stored_key(t, f, key)
        else
            -- an index is any unsigned integer; an Id is the store's own handle
            k = f.ids and S.coerce(key, types.id(t.elem), 'Id') or S.index_value(key)
            k = fix_index(k, 'capturing a storage index')
        end
        local function resolve() return S.ex(S.value_of(storage_library(t).locate(S.Ref(p), k))) end
        local b = S.cur()
        if b.fn then b.fn.uses_rt = true end
        local stable = f.index_stable == nil or f.index_stable(t)
        local text = S.expr_key(S.ex(S.value_of(k)))
        local place = S.checked_place(t.elem, nil, nil, stable, resolve,
            n .. '/' .. S.expr_key(addr(p)) .. '/' .. text)
        -- an element is the container's contents: borrows of it, and borrows
        -- stored in it, are checked against the container's owner
        rawset(place, 'owner_place', p)
        if keyed then rawset(place, 'element_key', { text = text, known = S.is_known(k) }) end
        -- which element, for the borrows of owners inside it (design memory.md §5.9, R4)
        rawset(place, 'index_key', { text = text, known = S.is_known(k) })
        return place
    end
end

local function length(x)
    local p = receiver(x, 'length')
    local f = family_of(p.T)
    if f and f.receive then f.receive(p.T, p) end
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
    local f = family_of(t)
    -- names, entry types and the representation of this compilation's type
    if f and f.setup then f.setup(t) end
    rawset(t, 'ctype', function() return cname_of(t) end)
    rawset(t, 'native_layout', function() return layout_of(t).layout end)
    rawset(t, 'cdecl', function() return 'typedef ' .. layout_of(t).layout.cname .. ' ' .. cname_of(t) .. ';' end)
    if not f then return t end    -- an Id has a name and a layout, nothing more
    rawset(t, 'init_word', function(p, indices, from)
        f.init(storage_library(t), S.Ref(p), indices, from)
    end)
    if f.stacks then rawset(t, 'release_fields', f.stacks) end
    local ms = library_methods(t, f)
    if f.views and t.elem.resizable then
        -- a slice would read the elements' headers as values: two owners of the same bytes
        local function refuse()
            fail(('%s holds owners: its elements are reached one at a time (g[i]), not as a slice'):format(
                t.display))
        end
        ms.all, ms.sub = refuse, refuse
    end
    if f.views and not t.elem.resizable then
        -- the elements are borrowed like a Grow's (g:all(), g:sub(a, b))
        local views = view_methods(t)
        ms.all, ms.sub = views.all, views.sub
        rawset(t, 'viewed_elem', t.elem)
    end
    -- operations that are not one library word over converted arguments
    for name, fn in pairs(f.extra and f.extra(t, ms) or {}) do ms[name] = fn end
    -- a container whose elements hold owners compacts its root's arenas on request (§5.9)
    if rawget(t, 'elem') and t.elem.resizable then
        ms.compact = function(self)
            local p = owner_receiver(t, f, self, cname_of(t) .. ':compact')
            if S.cur().fn then S.cur().fn.uses_rt = true end
            return require('nua.storage').compact_now(S.Ref(p))
        end
        f.arity.compact = 1
    end
    for name, fn in pairs(ms) do S.arity[fn] = f.arity[name] end
    rawset(t, 'builtin_methods', merge_methods(t, ms))
    rawset(t, '__index', index_hook(t, f))
    if f.newindex then
        rawset(t, '__newindex', function(self, k, value) return ms[f.newindex](self, k, value) end)
    end
    rawset(t, 'iterates', f.iterates and true or nil)
    rawset(t, 'properties', merge_properties(t, { length = length }))
    S.member_tables(t)
    rawset(t, 'construct', f.construct and f.construct(t) or function(x)
        if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
            fail(t.display .. ' {} takes no fields')
        end
        return fresh(t)
    end)
    if f.ids then rawset(t, 'visit_types', function(visit) visit(Mem.Id(t.elem)) end) end
    return t
end

local function checked(make, what)
    return function(elem)
        local ok, t = pcall(make, elem)
        if not ok then fail(tostring(t):gsub('^[^:]+:%d+: ', '')) end
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
Mem.receiver, Mem.capture, Mem.addr, Mem.fresh = receiver, capture, addr, fresh

-- A library module declares an owner type (lib/owners.nua) and gets its type constructor.
-- Declarations belong to one compilation: they are made again by each one.
Mem.owners = {}
function S.owner_type(decl)
    assert(type(decl) == 'table' and decl.name and decl.header and decl.api and decl.init,
        'owner_type needs a name, header, api and init')
    decl.suffix = decl.suffix or decl.name
    decl.methods, decl.args, decl.arity = decl.methods or {}, decl.args or {}, decl.arity or {}
    families[decl.name] = decl
    local constructor = function(...)
        local key, elem, length
        if decl.keyed then key, elem = ... elseif decl.sized then elem, length = ... else elem = ... end
        for _, x in ipairs(decl.keyed and { key, elem } or { elem }) do
            if not types.is_type(x) then fail((decl.label or decl.name) .. ' expects a type, got ' .. tostring(x)) end
        end
        -- a struct still being defined holds this owner: the type would contain itself, and
        -- its owner positions would have no end (design memory.md §5.9, R2)
        if rawget(elem, 'incomplete') then
            fail(('%s of %s, which is still being defined: a recursive owner type has unboundedly many '
                .. 'owner positions; build the tree in a Store and link it with Id %s'):format(
                decl.label or decl.name, elem.display, elem.display))
        end
        local message
        if decl.admit then message = decl.admit(key, elem)
        elseif not types.owner_element(elem) then
            message = decl.name .. ' holds fixed-size values, not ' .. elem.display
        end
        if message then fail(message) end
        local display = decl.display and decl.display(key, elem, length) or (decl.name .. ' ' .. elem.display)
        return decorate(types.owner(decl.name, elem, display, key, length))
    end
    Mem.owners[decl.name] = constructor
    return constructor
end

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

local loading_owners = false
function Mem.prelude(env)
    env.Id = Mem.Id
    -- the module that declares the owner types is itself loaded with this prelude
    if not loading_owners then
        loading_owners = true
        local ok, owners = pcall(require, 'nua.owners')
        loading_owners = false
        if not ok then error(owners, 0) end
        env.Store, env.Grow, env.Map, env.Chars = owners.Store, owners.Grow, owners.Map, owners.Chars
        env.Text = owners.Grow(types.U8)
    end
    env.copy = Mem.copy
    env.Array = function(elem, n)
        if n == nil then return Mem.owners.Array(elem) end
        if S.is_staged(n) and not S.is_known(S.value_of(n)) then
            -- a runtime length: the constructor of an Array T owner
            local t = Mem.owners.Array(elem)
            return setmetatable({}, { __call = function(_, x)
                if type(x) ~= 'table' or S.is_staged(x) or next(x) ~= nil then
                    fail(('Array(%s, n) {} with n known only at runtime starts zeroed; it takes no '
                        .. 'elements'):format(elem.display))
                end
                return Mem.array_of_length(t, n)
            end })
        end
        if S.is_staged(n) then n = tonumber(S.value_of(n).v) end
        -- elements that hold owners: the array is an owner holding its elements' arenas (§5.9)
        if types.is_type(elem) and elem.resizable then return Mem.owners.FixedArray(elem, n) end
        return S.Array(elem, n)
    end
    S.arity[Mem.copy] = 1
end

return Mem
