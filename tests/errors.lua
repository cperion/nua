-- each case: a program that must not compile, and part of the diagnostic
return {
    { name = 'a non-callable bare statement is not a no-op', expect = 'not callable',
      src = [[local f = do(n: U32): U32
    n
    return n
end
export f
]] },
    { name = 'bare methods do not invoke in expressions', expect = 'needs arguments',
      src = [[local Counter = struct { count: U32 }
function Counter:tick(): Unit
    self.count = self.count + 1
end
local f = do(c: Ref Counter): U32
    local action = c:tick
    return c.count
end
export f
]] },
    { name = 'tail call rejects a dynamic compile-time argument', expect = 'value is not known at compile time',
      src = [[local static_value = do(value): U32 = value
local f = do(n: U32): U32
    return static_value n
end
export f
]] },
    { name = 'known map rejects dynamic entries', expect = 'must be known',
      src = [[local f = do(k: U32): U32
    local m = Map.known(U32, U32, { { k, 1 } })
    return m.length
end
export f
]] },
    { name = 'known map indexing is not mutable', expect = 'immutable',
      src = [[local m = Map.known(U32, U32, { { 1, 10 } })
local f = do(): Unit
    m[1] = 20
end
export f
]] },
    { name = 'known map missing key fails during specialization', expect = 'map-key',
      src = [[local m = Map.known(Str, U32, {})
local f = do(): U32 return m["missing"] end
export f
]] },
    { name = 'known map has no mutators', expect = 'immutable',
      src = [[local m = Map.known(U32, U32, {})
local f = do(): Unit m:put(1, 2) end
export f
]] },
    { name = 'a map key may not define __eq', expect = 'the map key Money, which defines __eq',
      src = [[local Money = struct { cents: I64 }
function Money.__eq(a: Money, b: Money): Bool return a.cents == b.cents end
local M = Map(Money, U32)
local f = do(): U32
    local m = M {}
    m:put(Money { cents = 5 }, 1)
    return m.length
end
export f
]] },
    { name = 'a map key may not contain a type that defines __eq', expect = "field 'amount' of Pair is Money",
      src = [[local Money = struct { cents: I64 }
function Money.__eq(a: Money, b: Money): Bool return a.cents == b.cents end
local Pair = struct { label: U32, amount: Money }
local M = Map(Pair, U32)
local f = do(): U32
    local m = M {}
    return m.length
end
export f
]] },
    { name = 'a sum key may not carry a type that defines __eq', expect = "alternative 'some' of Choice is Money",
      src = [[local Money = struct { cents: I64 }
function Money.__eq(a: Money, b: Money): Bool return a.cents == b.cents end
local Choice = oneof { none: Unit, some: Money }
local M = Map(Choice, U32)
local f = do(): U32
    local m = M {}
    return m.length
end
export f
]] },
    { name = 'inferred local keeps its native type', expect = 'expected U32',
      src = [[local f = do(x: U32): U32
    local y = x
    y = Bool true
    return y
end
export f
]] },
    { name = 'an owner used after it moved', expect = "'text' was moved into 'other'",
      src = [[local f = do(): U32
    local text = Text {}
    local other = text
    return text.length
end
export f
]] },
    { name = 'host rebinding in a residual loop stays forbidden', expect = 'cannot be rebound',
      src = [[local f = do(n: U32): U32
    local host_count = 0
    for i: U32 = 1, n do
        host_count = host_count + 1
    end
    return host_count
end
export f
]] },
    { name = 'floating map keys', expect = 'Map key must have fixed semantic equality',
      src = [[local M = Map(F64, U32)]] },
    { name = 'a borrow of an entry of a map inside a map across an insertion',
      expect = "a map in 'outer' grew, so its entries may have moved",
      src = [[local f = do(): U32
    local outer = Map(U32, Map(U32, U32)) {}
    outer:put(1, Map(U32, U32) {})
    outer[1]:put(5, 50)
    local r = Ref outer[1][5]
    outer[1]:put(6, 60)
    return r
end
export f]] },
    -- owners inside elements (design memory.md §5.9)
    { name = 'a borrow of an element owner across its growth', expect = "grew, so its bytes may have moved",
      src = [[local f = do(): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local s = lines[0]:str()
    lines[0]:write "more"
    return s.length
end
export f]] },
    { name = 'a borrow of an element owner across growth of an unknown element',
      expect = "grew, so its bytes may have moved",
      src = [[local f = do(i: U64): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local s = lines[0]:str()
    lines[i]:write "more"
    return s.length
end
export f]] },
    { name = 'a borrow of an element owner across a word that grows it',
      expect = "the call to append, which may grow or clear it",
      src = [[local append = do(t: Ref Text): Unit
    t:write "x"
end
append.boundary = true
local f = do(): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local s = lines[0]:str()
    append(Ref lines[0])
    return s.length
end
export f]] },
    { name = 'a borrow of an element owner across its replacement', expect = "was replaced",
      src = [[local f = do(): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local s = lines[0]:str()
    lines[0] = Text {}
    return s.length
end
export f]] },
    { name = 'a recursive owner type', expect = 'a recursive owner type has unboundedly many owner positions',
      src = [[local Node = __S.struct("Node", function(self) return { { "children", Grow(self) } } end)]] },
    { name = 'an owner payload matched by value', expect = 'its handler takes it by reference',
      src = [[local Doc = oneof { empty: Unit, text: Text }
local f = do(): U64
    local d = Doc.text(Text {})
    return d { empty = do(): U64 return 0 end, text = do(t: Text): U64 return 1 end }
end
export f]] },
    { name = 'a task writing an owner global', expect = "a task cannot use the owner global 'log'",
      src = [[local log = global(Text, { name = "log" })
local run = do(n: U32): U32
    tasks do(..)
        spawn do
            log[0]:write "x"
        end
    end
    return n
end
export run]] },
    { name = 'a task reading an owner global', expect = "a task cannot use the owner global 'log'",
      src = [[local log = global(Text, { name = "log" })
local run = do(n: U32): U32
    tasks do(..)
        spawn do
            local k = log[0]:str().length
        end
    end
    return n
end
export run]] },
    { name = 'an exported owner global', expect = 'an owner global takes only a name',
      src = [[local log = global(Text, { name = "log", exported = true })]] },
    { name = 'a borrow of an element owner across compact', expect = "its container was compacted",
      src = [[local f = do(): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local s = lines[0]:str()
    lines:compact()
    return s.length
end
export f]] },
    { name = 'moving an owner out of an element', expect = 'an owner inside an element cannot be moved out of it',
      src = [[local f = do(): U64
    local lines = Grow(Text) {}
    lines:push(Text {})
    local t = lines[0]
    return 0
end
export f]] },
    { name = 'a slice of elements holding owners', expect = "its elements are reached one at a time",
      src = [[local f = do(): U64
    local lines = Grow(Text) {}
    local s = lines:all()
    return s.length
end
export f]] },
    { name = 'a map created while compiling', expect = 'runtime storage',
      src = [[local M = Map(U32, U32)
local f = do(): U32
    local m: M = M {}
    return m.length
end
local n = host(f())
]] },
    { name = 'a borrow of a replaced owner', expect = "'g' was replaced",
      src = [[local f = do(): U32
    local g = Grow(U32) {}
    g:push 1
    local r: Ref U32 = Ref g[0]
    g = Grow(U32) {}
    return r
end
export f
]] },
    { name = 'a Ref passed where an owner is expected', expect = 'owns its storage; a Ref borrows it',
      src = [[local M = Map(U32, U32)
local f = do(m: M): U32 = m.length
local g = do(): U32
    local m = M {}
    return f(Ref m)
end
export g
]] },
    { name = 'signed overflow at compile time', line = 1, expect = 'signed overflow',
      src = [[local f = do(a: I32): I32 = a * 2
local x = f(2147483647)
]] },
    { name = 'division by zero at compile time', expect = 'division by zero',
      src = [[local f = do(a: U32, b: U32): U32 = a / b
local x = f(1, 0)
]] },
    { name = 'partial application with a dynamic argument', line = 3, expect = 'not static',
      src = [[local add = do(a: U32, b: U32, c: U32): U32 = a + b + c
local g = do(x: U32): U32
    local h = add(x)
    return h(1, 2)
end
export g
]] },
    { name = 'typed parameters without a result type', expect = 'need a result type',
      src = [[local f = do(x: U32) = x + 1
]] },
    { name = 'rebinding a host local in a dynamic branch', line = 4, expect = 'cannot be rebound',
      src = [[local f = do(flag: Bool, x: U32): U32
    local y = 1
    if flag then
        y = y * 2
    end
    return y
end
export f
]] },
    { name = 'assigning a parameter', expect = 'parameters are immutable',
      src = [[local f = do(x: U32): U32
    x = x + 1
    return x
end
export f
]] },
    { name = 'assigning outside the typed body', expect = 'can only assign bindings it declares',
      src = [[local count = 0
local f = do(x: U32): U32
    count = count + 1
    return x
end
]] },
    { name = 'mismatched operand types', expect = 'convert one explicitly',
      src = [[local f = do(a: U32, b: I32): U32 = a + b
export f
]] },
    { name = 'literal out of range', expect = 'does not fit in U8',
      src = [[local f = do(a: U8): U8 = a + 300
export f
]] },
    { name = 'nonterminating specialization under known control', expect = 'does not terminate',
      src = [[local function up(k: U32): U32
    return up(k + 1) + 1
end
local g = do(x: U32): U32 = up(0) + x
export g
]] },
    { name = 'missing return', line = 6, expect = 'without returning',
      src = [[local f = do(flag: Bool): U32
    if flag then
        return 1
    end
end
export f
]] },
    { name = 'dynamic bound in a generation-time loop', expect = 'bounds must be known',
      src = [[local f = do(n: U32): U32
    local t: U32 = 0
    for i = 1, n do
        t = t + 1
    end
    return t
end
export f
]] },
    { name = 'non-Bool native condition', expect = 'must be Bool',
      src = [[local f = do(n: U32): U32
    if n then
        return 1
    end
    return 0
end
export f
]] },
    { name = 'reading an uninitialized typed local', line = 3, expect = 'read before it is written',
      src = [[local f = do(n: U32): U32
    local t: U32
    return t + n
end
export f
]] },
    { name = 'compile-time call of a foreign effect', expect = 'cannot evaluate at compile time',
      src = [[local p = extern("p", { U32 }, Unit)
local f = do(x: U32): Unit
    p(x)
end
f(3)
]] },
    { name = 'a reference in a channel message', expect = 'a reference points into memory someone else owns',
      src = [[local Box = struct { r: Ref U32 }
local C = Chan Box
]] },
    { name = 'an owner moved on one path is moved after the join', expect = "'s' was moved",
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N }
local f = do(x: U32): U32
    local s: Store N = Store(N) {}
    local g = G {}
    if x > 3 then g.nodes = s end
    return s.length
end
export f
]] },
    { name = 'a word returning a store returns a store', expect = 'expected a Store N',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): Store N = x
local g = do(x: U32): U32
    local s = f x
    return s.length
end
export g
]] },
    { name = 'a struct field of a moved owner struct', expect = "'g' was moved into 'h'",
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N, count: U32 }
local f = do(x: U32): U32
    local g = G {}
    local h: G = g
    return g.count
end
export f
]] },
    { name = 'an exported word cannot take an owner', expect = 'C cannot hand over an owner',
      src = [[local f = do(xs: Grow U32): U32 = xs.length
export f
]] },
    { name = 'an exported word cannot return an owner', expect = 'C cannot take over an owner',
      src = [[local f = do(n: U32): Grow U32
    local xs = Grow(U32) {}
    xs:push n
    return xs
end
export f
]] },
    { name = 'a payload borrow used after the variant changed', expect = 'was given another variant',
      src = [[local Running = struct { ticks: U32 }
local State = oneof { running: Running, stopped: U32 }
local f = do(n: U32): U32
    local state = State.running { ticks = n }
    local dummy: U32 = 0
    local held: Ref U32 = Ref dummy
    state {
        running = do(r: Ref Running): Unit
            held = Ref r.ticks
        end,
        stopped = do(c) end,
    }
    state = State.stopped 1
    return held
end
export f
]] },
    { name = 'a Slice.mut argument is marked with Ref', expect = 'mark it at the call: Ref xs',
      src = [[local zero = do(s: Slice.mut U32): Unit
    for i: U32 = 0, s.length - 1 do s[i] = 0 end
end
local f = do(n: U32): U32
    local xs = Grow(U32) {}
    xs:push n
    zero xs
    return xs[0]
end
export f
]] },
    { name = 'a read-only Slice is not written', expect = 'a Slice is a read-only view',
      src = [[local f = do(n: U32): U32
    local xs = Grow(U32) {}
    xs:push n
    local s = xs:all()
    s[0] = 1
    return xs[0]
end
export f
]] },
    { name = 'moving out through a Ref whose target is chosen at run time', expect = 'not known while compiling',
      src = [[local G = struct { order: Grow U32 }
local H = struct { r: Ref G }
local f = do(flag: Bool): U32
    local a = G {}
    local b = G {}
    local holder = H { r = Ref a }
    if flag then holder.r = Ref b end
    local taken = holder.r.order
    return taken.length
end
export f
]] },
    { name = 'an exported word moving out of a Ref argument', expect = 'a C caller could not know it moved',
      src = [[local G = struct { order: Grow U32 }
local f = do(g: Ref G): U32
    local o = g.order
    return U32 o.length
end
export f
]] },
    { name = 'a recursive result grows below a deeper result', expect = 'lies above it on the result stack',
      src = [[local function build(n: U32): Grow U32
    local out = Grow(U32) {}
    if n == 0 then return out end
    local inner = build(n - 1)
    out:push(U32 inner.length)
    return out
end
local f = do(n: U32): U32
    local xs = build n
    return xs.length
end
export f
]] },
    { name = 'an owner moved twice', expect = "'s' was moved into 'a'",
      src = [[local N = struct { v: U32 }
local f = do(x: U32): U32
    local s = Store(N) {}
    local a = s
    local b = s
    return x
end
export f
]] },
    { name = 'an owner struct moved after one of its fields moved', expect = "'g.nodes' was moved",
      src = [[local N = struct { v: U32 }
local G = struct { count: U32, nodes: Store N }
local f = do(x: U32): U32
    local g = G {}
    local n = g.nodes
    local h = g
    return x
end
export f
]] },
    { name = 'a recursion resizing an outer level owner while holding one', expect = 'resizes an owner created by an outer level',
      src = [[local function deep(n: U32, outer: Ref (Grow U32)): U32
    local mine = Grow(U32) {}
    mine:push n
    outer:push n
    if n == 0 then return U32 mine.length end
    return deep(n - 1, Ref mine) + U32 mine.length
end
local g = do(n: U32): U32
    local start = Grow(U32) {}
    return deep(n, Ref start)
end
export g
]] },
    { name = 'returning a reference to a local', expect = 'returns a reference to its own local',
      src = [[local leak = do(x: U32): Ref U32
    local y: U32 = x
    return Ref(y)
end
local f = do(x: U32): U32
    local r = leak(x)
    return r
end
export f
]] },
    { name = 'a store created at compile time', expect = 'cannot be created at compile time',
      src = [[local N = struct { v: U32 }
local f = do(x: U32): U32
    local s: Store N = Store(N) {}
    return x
end
local y = f(3)
]] },
    { name = 'old three-dot opening', expect = 'spread-syntax',
      src = [[local f = do(x: U32): U32
    local ctx... = { value = x }
    return value
end
export f
]] },
    { name = 'old three-dot opened parameter', expect = 'spread-syntax',
      src = [[local f = do(ctx...: U32): U32 = 1
]] },
    { name = 'old three-dot anonymous parameter', expect = 'spread-syntax',
      src = [[local f = do(...: U32): U32 = 1
]] },
    { name = 'old three-dot rest parameter', expect = 'spread-syntax',
      src = [[local f = do(...args): U32 = 1
]] },
    { name = 'old three-dot home read', expect = 'spread-syntax',
      src = [[local f = do(..: U32): U32 = (...)
]] },
    { name = 'two keyed spreads with a common field', expect = 'spread-overlap',
      src = [[local P = struct { x: U32, y: U32 }
local f = do(a: P, b: P): P = P { ..a, ..b, x = 1 }
export f
]] },
    { name = 'a keyed spread bringing an unknown field', expect = "has no field 'z'",
      src = [[local P = struct { x: U32 }
local Q = struct { x: U32, z: U32 }
local f = do(q: Q): P = P { ..q, z = 1 }
export f
]] },
    { name = 'a record spread into an ordered list', expect = 'spread-source',
      src = [[local P = struct { x: U32, y: U32 }
local add = do(a: U32, b: U32): U32 = a + b
local f = do(p: P): U32 = add(..p)
export f
]] },
    { name = 'a pack used as a value', expect = 'pack-use',
      src = [[local first = do(x: U32): U32 = x
local f = do(..xs): U32 = first(xs)
local g = do(a: U32): U32 = f(a)
export g
]] },
    { name = 'a pack index out of range', expect = 'pack-index',
      src = [[local f = do(..xs): U32 = xs[2]
local g = do(a: U32): U32 = f(a)
export g
]] },
    { name = 'a rest requirement that is not last', expect = 'rest-position',
      src = [[local f = do(..xs, y: U32): U32 = y
]] },
    { name = 'assigning an opened context', expect = 'context-use',
      src = [[local E = struct { n: U32 }
local f = do(x: U32): U32
    local e.. = E { n = x }
    e = E { n = 1 }
    return n
end
export f
]] },
    { name = 'a compile-time parameter given a runtime value', expect = 'compile-time parameter',
      src = [[local pick = do(k, x: U32): U32 = x
local f = do(x: U32): U32 = pick(x, x)
export f
]] },
    { name = 'reading the home where none is opened', expect = 'context-required',
      src = [[local f = do(x: U32): U32
    return (..)
end
]] },
    { name = 'a match missing an alternative', expect = "alternative 'dot' has no handler",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v }
export f
]] },
    { name = 'a match handling an unknown alternative', expect = "no alternative 'nope' to handle",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = 0, nope() = 1 }
export f
]] },
    { name = 'a match missing an alternative, even with a known tag', expect = 'has no handler',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(x: U32): U32 = S.num(x) { num(v) = v }
export f
]] },
    { name = 'a duplicate handler', expect = "duplicate key 'num'",
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = 0, num(v) = 1 }
export f
]] },
    { name = 'handlers with different result types on a runtime tag', expect = 'expected Bool, got U32',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s { num(v) = v, dot() = true }
export f
]] },
    { name = 'selecting a payload by name', expect = 'reached by matching',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(s: S): U32 = s.num
export f
]] },
    { name = 'a payload for a Unit alternative', expect = 'takes no payload',
      src = [[local S = oneof { dot: Unit, num: U32 }
local f = do(x: U32): S = S.dot(x)
export f
]] },
    { name = 'a reference payload returned past its target', expect = 'returns a borrow of its own local',
      src = [[local Node = struct { v: U32 }
local Link = oneof { none: Unit, some: Ref Node }
local make = do(): Link
    local node = Node { v = 1 }
    return Link.some(Ref node)
end
local f = do(): U32
    local link = make()
    return 0
end
export f
]] },
    { name = 'an empty oneof', expect = 'at least one named alternative',
      src = [[local Never = oneof { }
]] },
    { name = 'a known index outside a known length', expect = 'index-range',
      src = [[local f = do(b: Slice U8): U32
    local h = b:sub(0, 4)
    return U32(h[4])
end
export f
]] },
    { name = 'writing through a slice', expect = 'not-a-place',
      src = [[local f = do(b: Slice U8): Unit
    b[0] = 1
end
export f
]] },
    { name = 'pointer arithmetic', expect = 'not defined for Ptr U8',
      src = [[local f = do(p: Ptr U8): Ptr U8 = p + 1
export f
]] },
    { name = 'ordering pointers', expect = 'ordering is not offered',
      src = [[local f = do(p: Ptr U8, q: Ptr U8): Bool = p < q
export f
]] },
    { name = 'a pointer made a reference', expect = 'cannot become a checked borrow',
      src = [[local f = do(p: Ptr U32): U32
    local r = Ref(p)
    return 0
end
export f
]] },
    { name = 'a Map entry borrow used after a removal', expect = "a borrow of 'm' is used after an entry of 'm' was removed",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, U32) {}
    m[1] = 10
    local r = Ref m[1]
    m:remove 1
    r = r + 5
    return 0
end
export f
]] },
    { name = 'a Map entry borrow used after a removal of an unknown key', expect = "a borrow of 'm' is used after an entry of 'm' was removed",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, U32) {}
    m[1] = 10
    m[n] = 20
    local r = Ref m[1]
    m:remove n
    r = r + 5
    return 0
end
export f
]] },
    { name = 'a borrow stored in a Grow used after its source was cleared', expect = "a borrow of 'text' is used after 'text' was cleared",
      src = [[local f = do(n: U32): U32
    local text = Text {}
    text:write "inner"
    local g = Grow(Str) {}
    g:push(text:str())
    text:clear()
    return U32 g[0].length
end
export f
]] },
    { name = 'a borrow stored in a struct used after its source was cleared', expect = "a borrow of 'text' is used after 'text' was cleared",
      src = [[local Token = struct { text: Str }
local f = do(n: U32): U32
    local text = Text {}
    text:write "inner"
    local t = Token { text = text:str() }
    text:clear()
    return U32 t.text.length
end
export f
]] },
    { name = 'a borrow stored in a Map used after its source was cleared', expect = "a borrow of 'text' is used after 'text' was cleared",
      src = [[local f = do(n: U32): U32
    local text = Text {}
    text:write "inner"
    local m = Map(U32, Str) {}
    m[1] = text:str()
    text:clear()
    return U32 m[1].length
end
export f
]] },
    { name = 'a borrow of an inner owner stored in an outer Map', expect = "cannot be stored in 'm', which outlives it",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, Str) {}
    if n > 0 then
        local text = Text {}
        text:write "inner"
        m[1] = text:str()
    end
    return 0
end
export f
]] },
    { name = 'a borrowed Map key from an inner scope', expect = "cannot be stored in 'm', which outlives it",
      src = [[local f = do(n: U32): U32
    local m = Map.borrowing(Str, U32) {}
    if n > 0 then
        local src = Text {}
        src:write "alpha"
        m:put(src:str(), 1)
    end
    return 0
end
export f
]] },
    { name = 'a borrowed Map key used after its source was cleared', expect = "a borrow of 'src' is used after 'src' was cleared",
      src = [[local f = do(n: U32): U32
    local src = Text {}
    src:write "alpha"
    local m = Map.borrowing(Str, U32) {}
    m:put(src:str(), 1)
    src:clear()
    return U32 m.length + m["alpha"]
end
export f
]] },
    { name = 'a word followed by -1 is a subtraction', expect = "is a word, so `inc - n` subtracts from it",
      src = [[local inc = do(x: U32): U32 = x + 1
local f = do(n: U32): U32
    return inc -1
end
export f
]] },
    { name = 'a Grow borrow used after pop', expect = "a borrow of 'g' is used after 'g' was popped",
      src = [[local f = do(n: U32): U32
    local g = Grow(U32) {}
    g:push 1
    g:push 2
    local r = Ref g[0]
    local last = g:pop()
    return r + last
end
export f
]] },
    { name = 'a Grow borrow used after truncate', expect = "a borrow of 'g' is used after 'g' was truncated",
      src = [[local f = do(n: U32): U32
    local g = Grow(U32) {}
    g:push 1
    g:push 2
    local r = Ref g[0]
    g:truncate 1
    return r
end
export f
]] },
    { name = 'a Store element borrow used after a removal', expect = "is used after an element of 'nodes' was removed",
      src = [[local Node = struct { value: U32 }
local f = do(n: U32): U32
    local nodes = Store(Node) {}
    local a = nodes:add(Node { value = 1 })
    local b = nodes:add(Node { value = 2 })
    local r = Ref nodes[a]
    nodes:remove b
    return r.value
end
export f
]] },
    { name = 'a Map insertion inside its own each', expect = "changes 'm' while it is being iterated",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, U32) {}
    m[1] = 1
    m:each do(k, v)
        m[k + 100] = v
    end
    return 0
end
export f
]] },
    { name = 'a Map removal inside its own each', expect = "changes 'm' while it is being iterated",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, U32) {}
    m[1] = 1
    m:each do(k, v)
        m:remove k
    end
    return 0
end
export f
]] },
    { name = 'a Map change through a reference inside its own each', expect = "changes 'm' while it is being iterated",
      src = [[local f = do(n: U32): U32
    local m = Map(U32, U32) {}
    m[1] = 1
    local alias = Ref m
    m:each do(k, v)
        alias:put(k + 1, v)
    end
    return 0
end
export f
]] },
    { name = 'a word that changes a Map called inside its own each', expect = "changes 'm' while it is being iterated",
      src = [[local Counts = Map(U32, U32)
local add = do(m: Ref Counts, k: U32): Unit
    m[k] = 1
end
local f = do(n: U32): U32
    local m = Counts {}
    m[1] = 1
    m:each do(k, v)
        add(Ref m, k + 10)
    end
    return 0
end
export f
]] },
    { name = 'a Map(Str, V) insertion inside its own each', expect = "changes 'words' while it is being iterated",
      src = [[local f = do(n: U32): U32
    local words = Map(Str, U32) {}
    words:put("a", 1)
    words:each do(key, value)
        words:put("b", value)
    end
    return 0
end
export f
]] },
    { name = 'a with block with no type in its context', expect = "`with` here has no type",
      src = [[local f = do(n: U32): U32
    local p = with x = n end
    return p.x
end
export f
]] },
    { name = 'a Text borrow used after clearing', expect = "a borrow of 't' is used after 't' was cleared",
      src = [[local f = do(n: U32): U32
    local t = Text {}
    t:write "abc"
    local s = t:str()
    t:clear()
    return s.length
end
export f
]] },
    { name = 'a borrow returned past its owner', expect = "returns a borrow of its own local 'g'",
      src = [[local first = do(n: U32): Slice U32
    local g: Grow U32 = (Grow U32) {}
    g:push(n)
    return g:all()
end
local f = do(n: U32): U32
    local xs = first n
    return 0
end
export f
]] },
    { name = 'a store element borrowing a word local', expect = "cannot be stored in 'tokens'",
      src = [[local Token = struct { text: Str }
local fill = do(tokens: Ref (Store Token)): Unit
    local c = Chars(8) "ab"
    local id = tokens:add Token { text = c:str() }
end
local f = do(): U32
    local tokens = Store(Token) {}
    fill(Ref tokens)
    return tokens.length
end
export f
]] },
    { name = 'a signed index', expect = 'must be an unsigned integer',
      src = [[local f = do(p: Ptr U8, i: I32): U8 = p[i]
export f
]] },
    { name = 'an opaque type held by value', expect = 'hold it as Ptr FILE',
      src = [[local FILE = opaque "FILE"
local S = struct { f: FILE }
]] },
    { name = 'a variadic argument that is a record', expect = 'must be a native scalar',
      src = [[local printf = extern("printf", { CString }, I32, { header = "<stdio.h>", variadic = true })
local P = struct { x: U32 }
local f = do(x: U32): Unit
    printf("%u", P { x = x })
end
export f
]] },
    { name = 'a CString from a number', expect = 'expected a CString',
      src = [[local puts = extern("puts", { CString }, I32, { header = "<stdio.h>" })
local f = do(x: U32): Unit
    puts(3)
end
export f
]] },
    { name = 'a foreign struct without a header', expect = 'a header such as',
      src = [[local Stat = cstruct("struct stat", nil, { { "size", I64, "st_size" } })
]] },
    { name = 'reading an atomic plainly', expect = 'is read with :load()',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n
export f
]] },
    { name = 'writing an atomic plainly', expect = 'is written with :store(v)',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    c.n = 3
end
export f
]] },
    { name = 'a load with release order', expect = "memory order 'release' is not valid",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n:load("release")
export f
]] },
    { name = 'a store with acquire order', expect = "memory order 'acquire' is not valid",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    c.n:store(1, "acquire")
end
export f
]] },
    { name = 'an unknown memory order', expect = "unknown memory order 'strong'",
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): U32 = c.n:add(1, "strong")
export f
]] },
    { name = 'an atomic passed by value', expect = 'shared through Ref, never copied',
      src = [[local f = do(n: Atomic U32): U32 = 0
]] },
    { name = 'copying a struct holding an atomic', expect = 'is read with :load()',
      src = [[local C = struct { n: Atomic U32 }
local f = do(c: Ref C): Unit
    local d: C = c
end
export f
]] },
    { name = 'add on an atomic Bool', expect = 'offers load, store, exchange, cas;',
      src = [[local L = struct { held: Atomic Bool }
local f = do(l: Ref L): Bool = l.held:add(true)
export f
]] },
    { name = 'an atomic struct', expect = 'Atomic holds an integer, a Bool or a pointer',
      src = [[local P = struct { x: U32 }
local A = Atomic P
]] },
    { name = 'a task assigning a copy', expect = "'total' is a copy taken at spawn; a task cannot assign it", line = 4,
      src = [[local f = do(n: U32): U64
    local total: U64 = 0
    local bump = do(c: Chan U32): Unit
        total = total + 1
    end
    tasks do(scope..)
        spawn(bump, channel(U32, 1))
    end
    return total
end
export f
]] },
    { name = 'a spawned block assigning a copy', expect = "'count' is a copy taken at spawn", line = 5,
      src = [[local f = do(n: U32): U32
    local count: U32 = 0
    tasks do(scope..)
        spawn do
            count = count + 1
        end
    end
    return count
end
export f
]] },
    { name = 'a spawned block mentioning a reference', expect = "a task shares no memory: the outside value 'c' is a Ref C",
      src = [[local C = struct { n: U32 }
local f = do(c: Ref C): Unit
    tasks do(scope..)
        spawn do
            local m: U32 = c.n
        end
    end
end
export f
]] },
    { name = 'a wait inside recursion in a task', expect = 'a task cannot suspend inside it',
      src = [[local walk
walk = do(c: Chan U32, depth: U32): U32
    if depth == 0 then
        c:send(1)
        return 1
    end
    return walk(c, depth - 1) + walk(c, depth - 1)
end
local f = do(d: U32): Unit
    tasks do(scope..)
        local c = channel(U32, 64)
        spawn do
            local n: U32 = walk(c, d)
        end
    end
end
export f
]] },
    { name = 'first_of closed without a receive', expect = '`closed` runs when every received channel is closed, but no case receives',
      src = [[local f = do(c: Chan U32): Unit
    first_of { send(c, 1) do end, closed = do end }
end
export f
]] },
    { name = 'spawning with a reference', expect = "spawn: parameter 'c' of bump is a Ref C; a task shares no memory",
      src = [[local C = struct { n: U32 }
local bump = do(c: Ref C): Unit
    c.n = c.n + 1
end
local f = do(c: Ref C): Unit
    tasks do(scope..)
        spawn(bump, c)
    end
end
export f
]] },
    { name = 'a channel of pointers', expect = 'Chan Ptr U8: values crossing a channel are copies',
      src = [[local f = do(c: Chan (Ptr U8)): Unit
end
]] },
    { name = 'a channel of records holding a pointer', expect = "its field 'p' is a Ptr U8",
      src = [[local M = struct { p: Ptr U8 }
local f = do(c: Chan M): Unit
end
]] },
    { name = 'a task with a result', expect = "a task's result goes nowhere; send it on a channel",
      src = [[local g = do(n: U32): U32 = n + 1
local f = do(n: U32): Unit
    tasks do(scope..)
        spawn(g, n)
    end
end
export f
]] },
    { name = 'a channel leaving its scope', expect = 'a channel cannot leave its tasks scope',
      src = [[local f = do(): Unit
    local c = tasks do(scope..)
        return channel(U32, 1)
    end
end
export f
]] },
    { name = 'a first_of that cannot end', expect = 'first_of: when every channel is closed',
      src = [[local f = do(c: Chan U32): Unit
    first_of { recv(c) do(v) end }
end
export f
]] },
    { name = 'a receive missing a handler', expect = "alternative 'closed' has no handler",
      src = [[local f = do(c: Chan U32): U32
    local r: U32 = 0
    c:recv() { value = do(v) r = v end }
    return r
end
export f
]] },
    { name = 'spawning something that is not a word', expect = 'spawn: expects a block (spawn do ... end) or a typed word',
      src = [[local f = do(n: U32): Unit
    tasks do(scope..)
        spawn(42, n)
    end
end
export f
]] },
    { name = 'a channel unknown method', expect = "Chan U32 offers send, recv, close, each; not 'push'",
      src = [[local f = do(c: Chan U32): Unit
    c:push(1)
end
export f
]] },
    { name = 'a known index outside an array', expect = 'index-range: index 4 is outside an array of length 4', line = 3,
      src = [[local f = do(): U32
    local a: Array(U32, 4)
    return a[4]
end
export f
]] },
    { name = 'an empty array type', expect = 'n must be a positive integer known while compiling',
      src = [[local A = Array(U32, 0)
]] },
    { name = 'an array of references to a word local returned', expect = 'returns a borrow of its own local',
      src = [[local A = Array(Ref(U32), 1)
local make = do(): A
    local v: U32 = 1
    return A { Ref v }
end
local f = do(): U32
    local refs = make()
    return 0
end
export f
]] },
    { name = 'an array literal of the wrong length', expect = 'Array(U8, 3) { ... } lists 3 elements, got 2',
      src = [[local f = do(): U8
    local a: Array(U8, 3) = Array(U8, 3) { 1, 2 }
    return a[0]
end
export f
]] },
    { name = 'a slot used after it was sent', expect = 'this slot was sent at', line = 8,
      src = [[local B = struct { n: U32 }
local f = do(): Unit
    tasks do(scope..)
        local p = pool(B, 2)
        local c = channel(Slot B, 2)
        local s = p:take()
        c:send(s)
        p[s].n = 1
    end
end
export f
]] },
    { name = 'a slot released twice', expect = 'this slot was released at',
      src = [[local B = struct { n: U32 }
local f = do(): Unit
    tasks do(scope..)
        local p = pool(B, 2)
        local s = p:take()
        p:release(s)
        p:release(s)
    end
end
export f
]] },
    { name = 'a pool of pointers', expect = 'Pool Ptr U8: slots move between tasks',
      src = [[local f = do(p: Pool (Ptr U8)): Unit
end
]] },
    { name = 'a slot inside a oneof on a channel', expect = 'a Slot inside a oneof cannot move',
      src = [[local B = struct { n: U32 }
local M = oneof { buf: Slot B, none: Unit }
local f = do(c: Chan M): Unit
end
]] },
    { name = 'reading a slot directly', expect = 'is a handle: its contents are addressed through its pool, pool[slot]',
      src = [[local B = struct { n: U32 }
local f = do(s: Slot B): U32 = s.n
export f
]] },
    { name = 'I/O as a case of first_of', expect = 'I/O cannot lose a first_of: give io.read a deadline',
      src = [[local io = require "nua.io"
local f = do(c: Chan U32, file: io.File): Unit
    local buf: Array(U8, 8)
    first_of {
        recv(c) do(v) end,
        io.read(file, buf) do(n) end,
        closed = do end,
    }
end
export f
]] },
    { name = 'a read larger than its buffer', expect = 'io.read: 16 bytes do not fit a buffer of 8',
      src = [[local io = require "nua.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 16) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a read into something that is not a byte array', expect = 'io.read needs an Array(U8, N) to fill',
      src = [[local io = require "nua.io"
local f = do(file: io.File): Unit
    local n: U32 = 0
    io.read(file, n) { done = do(k) end, failed = do(e) end }
end
export f
]] },
    { name = 'an unknown I/O option', expect = "io.read: unknown option 'timeout'",
      src = [[local io = require "nua.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 8, { timeout = ms(5) }) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a timed read matched without timed_out', expect = "alternative 'timed_out' has no handler",
      src = [[local io = require "nua.io"
local f = do(file: io.File): Unit
    local buf: Array(U8, 8)
    io.read(file, buf, 8, { deadline = ms(5) }) { done = do(n) end, failed = do(e) end }
end
export f
]] },
    { name = 'a store addressed with the wrong key', expect = 'Id: expected Id N, got U32',
      src = [[local N = struct { v: U32 }
local G = struct { nodes: Store N }
local f = do(g: Ref G, k: U32): U32 = g.nodes[k].v
export f
]] },
    { name = 'a wait inside a blocking block', expect = 'a blocking block runs outside the scheduler: it cannot wait (send)',
      src = [[local f = do(): Unit
    tasks do(scope..)
        local c = channel(U32, 1)
        spawn do
            blocking do
                c:send(1)
            end
        end
    end
end
export f
]] },
    { name = 'an operator hook written as a method', expect = '__add is a hook, not a method',
      src = [[local N = struct { v: U32 }
function N:__add(other: N): N
    return N { v = self.v + other.v }
end
local f = do(a: N, b: N): N = a + b
export f
]] },
    { name = 'call before something that is not an application', expect = 'call needs an application',
      src = [[local f = do(x: U32): U32
    local y = call x
    return y
end
export f
]] },
    { name = 'call on an untyped Lua function', expect = 'call needs a native word',
      src = [[local twice = do(x) return x end
local f = do(x: U32): U32
    return call twice(x)
end
export f
]] },
    { name = 'text compared with ==', expect = 'text is compared with words, not operators',
      src = [[local f = do(a: Str): Bool = a == "x"
export f
]] },
    { name = 'a known index outside known text', expect = 'index-range: index 3 is outside text of length 3',
      src = [[local f = do(): U8
    local s: Str = "abc"
    return s[3]
end
export f
]] },
    { name = 'known text longer than its Chars(n)', expect = 'Chars(2) holds 2 bytes; this text has 3',
      src = [[local f = do(): U32
    local c: Chars(2) = Chars(2)("abc")
    return c.length
end
export f
]] },
    { name = 'a separator of two bytes', expect = 'split: the separator is one byte',
      src = [[local f = do(s: Str): Unit
    s:split(", ") do(p) end
end
export f
]] },
    { name = 'a local view stored in a global record', expect = 'cannot be stored',
      src = [[local Holder = struct { s: Str }
local held = global(Holder, {})
local f = do(): U32
    local c = Chars(8) "ab"
    held.s = c:str()
    return 0
end
export f
]] },
    { name = 'Chars overflow on the known word path', expect = 'Chars(4) holds 4 bytes; this text has 5',
      src = [[local f = do(s: Str): U32
    local c: Chars(4) = Chars(4)(s)
    return c.length
end
assert(host(f("abcde")) == 5)
]] },
    { name = 'raw array address is still a runtime boundary', expect = 'cannot evaluate at compile time',
      src = [[local f = do(): U8
    local c: Chars(4) = Chars(4)("abc")
    local p = Ptr(c.bytes)
    return p[0][0]
end
host(f())
]] },
}
