-- Countermodels for the retry-design review, not a replacement evaluator.
-- Run: luajit docs/design/compiler-inventory/retry-owner-probes.lua
-- No Nua compilation, native tools or dependencies. The earlier retry-probes.lua
-- remains unchanged: its observations stand, but did not establish a winner.

local checked = 0
local function check(condition, message)
    assert(condition, message)
    checked = checked + 1
end

-- This model deliberately changes ownership: the driver owns the draft and its
-- completion, outside the suspendable body. It does NOT finish arbitrary host
-- scopes hidden inside that body, or model native borrowing/placement/rollback.
local active
local events = {}
local function attempt(owner, body)
    local parent = active
    local draft = { owner = owner, work = {}, open = true }
    local thread = coroutine.create(body)
    active = draft
    local ok, value = coroutine.resume(thread, draft)
    active = parent
    draft.open = false
    events[#events + 1] = owner
    if not ok then
        draft.work = {}
        error(value, 0)
    end
    if coroutine.status(thread) == 'dead' then
        return { kind = 'completed', value = value }, draft
    end
    assert(type(value) == 'table' and (value.kind == 'retry' or value.kind == 'next_round'),
        'model received an unexpected yield')
    if value.kind == 'retry' then draft.work = {} end
    return value, draft
end

-- A successful body uses ordinary Lua operators and returns an ordinary value.
do
    local owner = {}
    local result, draft = attempt(owner, function(work)
        check(active == work, 'body must see its owned draft')
        work.work[1] = 'accepted'
        return 7
    end)
    check(result.kind == 'completed' and result.value == 7 and not draft.open
        and draft.work[1] == 'accepted' and active == nil,
        'driver must complete and keep successful work')
    print('owned driver: normal result=7 scope_closed=true accepted_work=kept')
end

-- Outer-target retry through an ordinary assignment hook and a host pcall.
-- The inner driver completes before forwarding. Both suspendable suffixes stop;
-- completion does not depend on either suffix executing.
do
    local outer, inner = {}, {}
    local request = { kind = 'retry', target = outer }
    local outer_draft, inner_draft
    local inner_after, outer_after, host_caught_error = false, false, false
    local first_event = #events + 1
    local result = attempt(outer, function(work)
        outer_draft = work
        work.work[1] = 'outer tentative'
        local child, child_work = attempt(inner, function(child_draft)
            inner_draft = child_draft
            child_draft.work[1] = 'child tentative'
            local place = setmetatable({}, {
                __newindex = function() coroutine.yield(request) end,
            })
            local ok = pcall(function() place.value = 1 end)
            host_caught_error = not ok
            inner_after = true
        end)
        check(not child_work.open and #child_work.work == 0 and active == work,
            'inner driver must complete/discard and restore outer binding before forwarding')
        if child.kind == 'retry' and child.target ~= inner then coroutine.yield(child) end
        outer_after = true
    end)
    check(result == request and result.target == outer and not inner_after and not outer_after,
        'retry must reach outer owner without executing either suffix')
    check(not inner_draft.open and not outer_draft.open and #outer_draft.work == 0
        and active == nil and not host_caught_error,
        'both drivers must complete without throwing retry through host pcall')
    check(#events == first_event + 1 and events[first_event] == inner and events[first_event + 1] == outer,
        'completion must occur once per owner, inner before outer')
    print('owned driver: outer retry received scopes_closed=2 completions=inner,outer suffixes_ran=false')
end

-- Known-tail transfer keeps accepted work instead of applying retry's discard.
do
    local owner = {}
    local request = { kind = 'next_round', target = owner, arguments = { 3 } }
    local result, draft = attempt(owner, function(work)
        work.work[1] = 'known round'
        coroutine.yield(request)
        error('known-tail suffix must not run')
    end)
    check(result == request and not draft.open and draft.work[1] == 'known round',
        'next round and rejected round have different work dispositions')
    print('owned driver: next round scope_closed=true accepted_work=kept')
end

-- Genuine errors are still errors, after the driver restores its own bindings.
do
    local owner, failure = {}, {}
    local failed_draft
    local ok, result = pcall(attempt, owner, function(work)
        failed_draft = work
        work.work[1] = 'rejected'
        error(failure, 0)
    end)
    check(not ok and result == failure and not failed_draft.open
        and #failed_draft.work == 0 and active == nil,
        'driver must preserve failure identity and complete its owned work')
    print('owned driver: host failure preserved scope_closed=true')
end

-- Counterexample to a naive coroutine-based design: an intervening host-owned
-- coroutine receives the yielded request, not the evaluator's driver. The host
-- function's ordinary result is not automatically an evaluator outcome.
do
    local owner = {}
    local request = { kind = 'retry', target = owner }
    local host_after = false
    local result, draft = attempt(owner, function()
        local place = setmetatable({}, {
            __newindex = function() coroutine.yield(request) end,
        })
        local generator = coroutine.wrap(function()
            place.value = 1
            return 17
        end)
        local produced = generator()
        host_after = true
        return produced
    end)
    check(result.kind == 'completed' and result.value == request and host_after and not draft.open,
        'host coroutine must expose the routing gap, not be silently counted as a handled retry')
    print('host-owned coroutine: request_became_data=true host_suffix_ran=true (routing unresolved)')
end

print(('PASS: %d review-model assertions; no Nua acceptance claim'):format(checked))
