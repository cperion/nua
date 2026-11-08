-- Retry-transport design experiments, not compiler implementation or acceptance tests.
-- Run from the repository root: luajit docs/design/compiler-inventory/retry-probes.lua
-- Only Lua control flow is exercised: no Nua compilation, C emission or native tools.
-- The return-only and abandoned-coroutine cases deliberately exhibit counterexamples.

local checked = 0
local function check(condition, message)
    assert(condition, message)
    checked = checked + 1
end

local function scoped(state, body)
    state.open = true
    local ok, result = pcall(body)
    state.open = false
    state.completions = (state.completions or 0) + 1
    if not ok then error(result, 0) end
    return result
end

-- If all callers cooperate, ordinary outcomes work and completion runs normally.
do
    local target, state = {}, {}
    local request = { kind = 'retry', target = target }
    local function operation() return request end
    local function body()
        local outcome = operation()
        if outcome.kind == 'retry' then return outcome end
        state.after = true
        return { kind = 'done' }
    end
    local outcome = scoped(state, body)
    check(outcome == request and not state.after and not state.open,
        'cooperative returned outcome must stop the body and complete its scope')
    print('cooperative return: after=false scope_open=false request_preserved=true')
end

-- An opaque host hook has the ordinary Lua ABI: __newindex returns nothing to
-- its caller. Checking an outcome after the surrounding host function is too late.
do
    local target, state = {}, {}
    local request = { kind = 'retry', target = target }
    local place = setmetatable({}, { __newindex = function() return request end })
    local result = scoped(state, function()
        place.value = 1
        state.after = true
        return 7
    end)
    check(result == 7 and state.after and not state.open,
        'Lua assignment should discard the returned request (the counterexample)')
    print('return through __newindex: after=true scope_open=false result=7 (unsuitable)')
end

-- LuaJIT can yield through this metamethod and pcall. But dropping the suspended
-- body does not execute the scope's completion code. Resuming normally executes
-- the suffix we needed to prevent, rather than performing cancellation cleanup.
do
    local state, request = {}, { kind = 'retry', target = {} }
    local place = setmetatable({}, {
        __newindex = function() return coroutine.yield(request) end,
    })
    local thread = coroutine.create(function()
        return scoped(state, function()
            place.value = 1
            state.after = true
            return 7
        end)
    end)
    local ok, outcome = coroutine.resume(thread)
    check(ok and outcome == request and coroutine.status(thread) == 'suspended',
        'this LuaJIT must yield through the tested metamethod and pcall')
    check(state.open and not state.after and not state.completions,
        'suspended body has not completed its host scope')
    print('yield at retry: after=false scope_open=true completions=0 (cannot simply abandon)')
    local resumed, result = coroutine.resume(thread)
    check(resumed and result == 7 and state.after and not state.open and state.completions == 1,
        'ordinary resumption continues the unwanted suffix')
    print('resume normally: after=true scope_open=false completions=1 (not cancellation)')

    local abandoned_state = {}
    local abandoned = coroutine.create(function()
        scoped(abandoned_state, function()
            place.value = 1
            abandoned_state.after = true
        end)
    end)
    local yielded, requirement = coroutine.resume(abandoned)
    local weak_thread = setmetatable({ abandoned }, { __mode = 'v' })
    abandoned = nil
    collectgarbage('collect')
    collectgarbage('collect')
    check(yielded and requirement == request and weak_thread[1] == nil
        and abandoned_state.open and not abandoned_state.after and not abandoned_state.completions,
        'collecting the abandoned coroutine must not be mistaken for scope completion')
    print('abandon coroutine: collected=true scope_open=true completions=0')
end

-- A private nonlocal carrier can cross opaque Lua while owner boundaries expose
-- value outcomes. This is explicitly an exception to the guide, not a trick for
-- claiming error-based alternatives have gone away. No production API is proposed
-- by this mechanically small model; target lifetimes/state disposal need more work.
do
    local carrier_type = {}
    local function transfer(request)
        error(setmetatable({ request = request }, carrier_type), 0)
    end
    local function attempt(body)
        local ok, result = pcall(body)
        if ok then return { kind = 'done', value = result } end
        if type(result) == 'table' and getmetatable(result) == carrier_type then
            return result.request
        end
        error(result, 0)
    end
    local outer, inner = {}, {}
    local request = { kind = 'retry', target = outer }
    local outside_scope, inside_scope = {}, {}
    local events = {}
    local place = setmetatable({}, { __newindex = function() transfer(request) end })
    local outcome = attempt(function()
        return scoped(outside_scope, function()
            local child = attempt(function()
                return scoped(inside_scope, function()
                    place.value = 1
                    inside_scope.after = true
                end)
            end)
            -- Complete this activity's owned tentative work before relaying an
            -- outward request. Only the matching owner may consume the retry.
            check(not inside_scope.open and inside_scope.completions == 1,
                'inner host scope must complete before the activity handles its outcome')
            if child.kind == 'retry' and child.target ~= inner then
                events[#events + 1] = 'inner discarded'
                transfer(child)
            end
            error('outer retry was consumed by the wrong activity')
        end)
    end)
    check(outcome == request and outcome.target == outer,
        'outward retry must reach its matching owner unchanged')
    check(not outside_scope.open and outside_scope.completions == 1 and not inside_scope.after,
        'unwind must run both scope completions without executing the suffix')
    check(table.concat(events, ',') == 'inner discarded', 'inner must discard exactly once')
    print('private unwind: after=false scopes_open=false completions=2 target=outer')

    local failure = { message = 'host failure', kind = 'retry', target = outer }
    local failed_scope = {}
    local ok, err = pcall(attempt, function()
        return scoped(failed_scope, function() error(failure, 0) end)
    end)
    check(not ok and err == failure and not failed_scope.open,
        'an unbranded table error, even with retry-like fields, must remain the same error')
    print('host failure: same_error=true scope_open=false (not a retry)')

    -- The carrier is private, not uncatchable. Host code that swallows all errors
    -- can swallow it too. Production design must not claim otherwise.
    local swallowed = attempt(function()
        pcall(function() transfer(request) end)
        return 'continued'
    end)
    check(swallowed.kind == 'done' and swallowed.value == 'continued',
        'ordinary pcall can swallow even a branded private carrier')
    print('swallowing host pcall: continued=true (private unwind limitation)')
end

-- Minimal boundary acknowledgement can refuse a swallowed carrier. It cannot
-- undo the host suffix that already ran; arbitrary host-effect rollback is not
-- provided by this model (or by the current compiler).
do
    local pending
    local intercepted = { message = 'retry transport was intercepted' }
    local request = { kind = 'retry', target = {} }
    local function transfer()
        assert(pending == nil, 'another transfer is already pending')
        pending = { request = request }
        error(pending, 0)
    end
    local function guarded_attempt(body)
        local ok, result = pcall(body)
        local carrier = pending
        pending = nil
        if carrier then
            if ok or result ~= carrier then error(intercepted, 0) end
            return carrier.request
        end
        if not ok then error(result, 0) end
        return { kind = 'done', value = result }
    end
    check(guarded_attempt(function() return 7 end).value == 7, 'normal result must pass')
    check(guarded_attempt(transfer) == request and pending == nil,
        'boundary must acknowledge the exact pending carrier')
    local after = false
    local ok, err = pcall(guarded_attempt, function()
        pcall(transfer)
        after = true
        return 7
    end)
    check(not ok and err == intercepted and after and pending == nil,
        'intercepted transfer must refuse output, not pretend to undo host execution')
    print('acknowledged unwind: swallowed_carrier=refused host_suffix_already_ran=true')
end

print(('PASS: %d Lua-mechanism assertions; not Nua acceptance evidence'):format(checked))
