# Nua memory: model and API (design proposal)

Status, revision of 2026-11-02:

- **Implemented:** milestone 1 (data stacks never move) and milestone 2 (one borrow
  system rooted in owners). [syntax.md](../syntax.md) §9, §12 and §14 and
  [architecture.md](../architecture.md) §5.7 and §8.1 describe them.
- **Decided, not yet implemented:** items marked *decided*.
- **Proposed, awaiting review:** everything else, including this revision's audit
  results. §15 records the decisions taken on it.

When the rest is approved, its contracts move into syntax.md (§9, §11, §12, §14, §15,
§20) and its compiler and runtime parts into architecture.md (§7, §8, §12).

Starting point: [Goose](https://aardappel.github.io/goose/docs/goose_spec.html). Its
runtime model is kept where its simplicity and speed come from: data stacks assigned
while compiling, stacks that never move, results built where they live, deallocation
at scope exit, no exclusivity rules. Its limits are not kept by default. Each one is
engineered away, or kept with its reason and its cost stated.

## 1. The safety contract

A Nua program that compiles, without raw pointers, never:

- reads or writes outside a value's storage (indices are checked; checks that a
  path already proves are removed);
- uses storage after its owner ended, or after the operation that freed or reused it;
- observes storage at a type other than the one it was written with.

Nua does **not** restrict aliasing. Two references to one place are fine, and
writes through either are visible through both. The specializer already orders
effects through aliases (architecture §8.2); the type system does not repeat it.

## 2. Defaults

The common program needs no memory vocabulary beyond types and `Ref`. Each default
follows a language principle:

| Default | Principle |
|---|---|
| No lifetime syntax, ever. The compiler infers what a borrow depends on. | Knownness and specialization carry facts; the programmer writes intent. |
| Values copy. Owners move at their last use and never copy silently; `copy x` is the visible O(n) copy. | A cost the reader cannot see is a cost the reader cannot judge. |
| Reading is unmarked; writing is marked. `Ref x` at a call site, `Slice.mut T` in a signature. | Let the contract say copy or borrow (design guide §13). |
| An owner passed where a read-only borrow is expected borrows without a marker: `sum xs`. | Reading cannot invalidate anything; ceremony would buy nothing. |
| Owner fields start empty: `Graph {}`. Initial contents are optional: `Grow U32 { 1, 2, 3 }`. | Creation in place should read like construction of any value. |
| An owner is returned like a value; the callee builds it where the caller keeps it. | A word's result is its result; placement is the compiler's job. |
| Anything that composes values may compose owners: `Grow Text`, `Store Player` with a `Text` field, `Sum` payloads. | Containers should not care what they contain. |
| Checks are on; facts remove them. | Safety by default, cost only where nothing proves the bound. |
| Raw memory is spelled raw: `Ptr T`, `Slice(p, n)`. | The trusted boundary is visible in the source. |

## 3. Roles

The design guide's roles (§5.1) become the type vocabulary. A user chooses a role;
the size class (fixed, variable, resizable) follows from it.

| Role | Meaning | Types |
|---|---|---|
| **value** | copied freely, owned by whoever holds it | scalars, `Struct`, `Sum`, `Array(T, n)`, `Bounded(T, n)`, `Chars n`, when they hold no owner |
| **owner** | has storage; created in place; borrowed, moved or returned, never copied silently | `Grow T`, `Array T`, `Store T`, `Map(K, V)`, `Text`, and any aggregate holding one |
| **borrow** | uses an owner's storage; cannot outlive it | `Ref T`, `Slice T`, `Slice.mut T`, `Str` |
| **name** | identifies an entity without owning it; survives removal | `Id T` |
| **raw** | the trusted foreign boundary | `Ptr T`, `Slice(p, n)` |
| **handle** | runtime-owned state with its own transfer rules | `Chan`, `Pool`, `Slot` |

## 4. Values

Fixed-size, copied on assignment and passing, stored in C locals and registers.

| Type | Meaning |
|---|---|
| `Array(T, n)` | `n` elements of `T`, `n` known while compiling |
| `Bounded(T, n)` | capacity `n` inline, with a runtime length; `push`, `pop`, `clear` within capacity; exceeding it traps |
| `Chars n` | `Bounded(U8, n)` with the text words |
| `Struct`, `Sum` | fields and payloads may hold borrows (*decided*) and owners (§5.9) |

**Payloads can be borrowed** (proposed; Goose's fixed mode is not kept). A handler
receives a copy of the payload, as today, unless its parameter is declared `Ref`.
It then borrows the payload of the sum place being matched:

```lua
state {
    running = do(r: Ref Running): Unit                        -- updated in place
        r.ticks = r.ticks + 1
    end,
    stopped = do(s) log s.reason end,                         -- a copy, as today
}
```

Replacing the variant (`state = State.stopped ...`) ends borrows of the old payload,
under the same liveness rule as `clear` (§6.3). A sum *value* (not a place) has no
storage to borrow, so its handlers receive copies.

## 5. Owners

### 5.1 The owner types

| Type | Storage | Element addresses |
|---|---|---|
| `Grow T` | resizable: grows at the top of its stack | stable; growth invalidates nothing, shrinking needs no live borrow (§6.3) |
| `Array T` | variable: length fixed when built, at runtime | stable |
| `Store T` | a `Grow` of slots with a free list and generations (Nua library) | stable; addressed by `Id T`; `remove` ends borrows of elements (§6.3) |
| `Map(K, V)` | a `Store` of entries plus a hash index of keys (Nua library) | stable: rehashing rebuilds only the index; `m[k]` gives a real borrow; `remove` ends borrows of entries |
| `Text` | `Grow U8` with the text words | as `Grow` |

`Array(T, n)` with a known `n` is a value; built with a runtime length it is the
owner `Array T`. One constructor; the binding time of the length decides the class.

**Map's layout** (proposed, replaces today's open addressing, whose rehash moves
entries). Entries live in slots that never move; a separate index maps hashes to
slots, and only the index is rebuilt when the map grows. Removed slots are reused
through a free list, as in `Store`, so memory stays bounded under churn. Iteration
follows slot order. Consequences:

- `m[k]` is a real borrow, like `g[i]`. Today it is only a checked place.
- **`m[k] = v` inserts or replaces** (*decided* 2026-11-02), as in Lua: the library
  `Map` defines `__newindex` (syntax §16). Reading a missing key still traps
  (`m[k]`, `m[k] + 1`, `Ref m[k]`): a read has no value to return; `m:find k` and
  `m:has k` are the non-trapping forms. Writing a field of a missing entry
  (`m[k].x = 1`) modifies an entry, so it traps too; `m:ensure(k, initial)` creates
  it. Today assignment does not insert (syntax §15.1).
- `Map(Str, V)` keeps its keys in a key arena. Removed keys' bytes are reclaimed when
  they exceed the live bytes, by compacting the arena; compaction moves keys, so a
  `put` that may compact ends borrows of the keys (not of the values).

### 5.2 Creation

An owner is created where it lives: a typed local, a field, an element, a payload
(§5.9).

```lua
local xs = Grow U32 {}               -- empty
local ys = Grow U32 { 1, 2, 3 }      -- with contents
local buf = Array(U8, n) {}          -- n known: a value; n at runtime: an owner
local out = Text {}
```

Any aggregate that holds an owner is an owner. A struct may hold any number of owner
fields, in any order, nested (*decided*); each top-level owner field gets its own data
stack. Owner fields left out of the constructor start empty, and value fields left out
start zeroed (*decided*):

```lua
local Graph = Struct {
    nodes: Store Node,
    edges: Store Edge,
    name: Chars 32,
}

local g = Graph {}                   -- nodes and edges empty, name zeroed
local h = Graph { name = Chars(32) "roads" }
```

### 5.3 Returning

An owner is returned like a value (*decided*). The callee builds it directly in the
caller's destination: a local, a field, an element being pushed, a payload, or an
argument.

```lua
local squares = do(n: U32): Grow U64
    local out = Grow U64 {}
    for i: U32 = 1, n do out:push U64 i * U64 i end
    return out
end

local xs = squares 10                -- built on xs's stack, never copied
lines:push(read_line f)              -- built in the new element (§5.9)
```

### 5.4 Moving

(proposed) Using a named owner at its **last use** as a value moves it: assigning
it, passing it to an owner-typed parameter, returning it, or giving it to a field or
an element.

```lua
local nodes = load_nodes file
local edges = load_edges file
local g = Graph { .nodes, .edges }   -- moved: nothing is copied
```

- **Nothing is copied.** The storage stays where it is; the destination takes over
  the duty to release it.
- **Use after a move is rejected,** with the move site in the diagnostic: `nodes
  moved into g.nodes at line 3`. Last use is liveness, as for invalidation (§6.3).
- **Using a named owner as a value when it is used again later** is rejected, with
  `copy` or `Ref` suggested.
- **Through a `Ref` parameter** (*decided*, D6): a word may move an owner out of a
  `Ref` argument. Evaluated in place, the caller's place is moved; compiled on its
  own, the word's summary says which part of which argument it moves, the caller's
  place counts as moved after the call, and the word's exits on paths that do not
  move it release it. An exported word may not, since its C caller could not know.
  Through a `Ref` read from data whose target is not known while compiling (a field,
  an element, a local chosen at run time), moving out is rejected: the place it
  would leave is unknown.
- **A move on some paths only** is exact (*decided*, D5): on the paths that move
  it, the destination takes over; on the others, the owner is released at its last
  use (§5.8). The point of release is known while compiling on every path: no drop
  flags, no reserved bytes, no rejection.
- **Assigning to an owner place that already holds an owner** (`g.nodes = fresh`)
  releases the old owner there, since it is dead from that point (§5.8).

### 5.5 Copying

`copy x` duplicates an owner, including nested owners, into a new destination. It is
the only way to duplicate one, so every O(n) copy appears in the source.

- An owner struct copies its owner fields deeply and its value fields as values.
- A copied `Store` keeps its token: the original's `Id`s name the same entities in
  the copy.
- `copy` of a borrow builds the matching owner: a `Str` into a `Text`, a `Slice T`
  into an `Array T`. `copy` of a value is the value.

### 5.6 Passing

| Parameter | Argument | Meaning |
|---|---|---|
| `Ref T` | `Ref g` | borrow for reading and writing, including growth |
| `Slice T`, `Str` | `g` | read-only borrow of the elements; no marker |
| `Slice.mut T` | `Ref g` | borrow of the elements for writing; length fixed |
| `T` (an owner type) | a fresh owner (a constructor or call result), a moved owner, or `copy g` | the parameter owns it |

`Ref` at a call site always means *this argument may change*.

### 5.7 Checked places

A checked place is a place computed by a word and found again at each use: `s[id]`,
`m[k]`, `g[i]`. It holds no address between uses, so it stays correct whatever
happens to the container in between. This is a general protocol: a library type
defines how a key resolves to a place, and the compiler treats the result as a place.
A container whose algorithm moves entries gives out checked places only; with the
layouts of §5.1, `Grow`, `Array T`, `Store T` and `Map` all give out real borrows too.

### 5.8 Release

(*decided*, D5) An owner is released when its life ends: its stack's top returns to
where the owner began. Its life ends at the last use of the owner or of any borrow
of it, on each path; at the latest, when the scope that holds it ends. A top-level
owner is always the top of its stack, so it can always be released at that point.
There are no destructors and no reference counting. Early returns, `break` and trap
recovery release the same way. A moved owner is released by its destination.

Releasing at the end of life, not only at scope exit, is what makes partial moves
(§5.4) and replacement exact, and lets later owners reuse the bytes sooner.
Implemented: exact release for moves on some paths and for replacement; every other
owner is released when its scope ends, the latest point allowed. Releasing every
owner at its last use needs a liveness pass over the generated program, including
pointers derived from the owner (*decided* 2026-11-02: a later milestone). A nested
owner's contents (§5.9) are not released one by one: they return with their arena.

### 5.9 Nested owners

(proposed) An owner may sit inside a container element, an `Array(T, n)` or
`Bounded(T, n)` element, a `Sum` payload or a map value:

```lua
local lines = Grow Text {}
local players = Store Player {}      -- Player = Struct { name: Text, items: Grow Item }
local cache = Map(U64, Text) {}
```

**The mechanism: one arena per nesting level.** The number of data stacks must stay
fixed while compiling (§9). A holder whose elements contain owners takes one extra
stack, its arena, where those owners' contents live. Each element holds a small
header (where its contents begin, length, capacity). The depth of owner nesting is
part of the type, so the stack count is static: `Grow Text` uses 2 stacks, `Store
Player` 3 (slots, names' arena, items' arena), `Grow (Grow (Grow U8))` 3.
`Map(Str, V)`'s key arena is this mechanism already.

- **Growth.** A nested owner whose contents end at the arena's top extends in place:
  building elements one at a time never moves anything. Otherwise its contents move
  to the top with doubled capacity.
- **What moving costs.** Growing a nested owner ends borrows of *that* owner's
  contents (liveness, §6.3). When the compiler cannot tell two elements apart
  (`lines[i]` and `lines[j]` with unknown indices), it ends borrows of the contents
  of every element of that holder. Top-level owners never move, and borrows of the
  elements themselves (the headers) are unaffected.
- **Reclaiming.** Space abandoned by moving, and the contents of removed elements,
  return when the outer owner is cleared or ends, or on an explicit `compact()`
  (which moves contents, so it ends borrows of them). Doubling bounds the space
  abandoned by growth to the live size; space abandoned by removal is bounded by
  the outer owner's lifetime.
- **A `Sum` with an owner payload** is an owner with one stack: replacing the
  variant resets that stack to its base. No arena is needed, since only one payload
  exists at a time.
- **Copying** an outer owner copies the nested contents (`copy` is deep).

### 5.10 Owner globals

(proposed) A global may be an owner. Each owner global gets its own reserved region,
reserved at its first use and released at exit; the number of owner globals is known
while compiling. Today's global rules apply unchanged: tasks do not write ordinary
globals (syntax §21.1).

### 5.11 What may hold what

Every holder crossed with every role. Three invariants decide each cell:

1. **The number of data stacks is fixed while compiling** (§9). Nested owners use
   arenas (§5.9), so owners fit everywhere the compiler counts nesting.
2. **Every borrow's owner is known to the compiler** (§6.2). A borrow may sit wherever
   the holder's lifetime can be compared with its owner's.
3. **A task owns its memory** (§8). It may read its spawner's owners for the
   duration of a tasks scope (*decided*, D1), and nothing else crosses but copies.

| Holder ↓ / held → | value | borrow | owner | `Id` | `Chan`, `Pool` | `Slot` | `Ptr` | `Atomic` |
|---|---|---|---|---|---|---|---|---|
| typed local, parameter, result | yes | yes | yes | yes | yes | yes | yes | yes |
| struct field | yes | yes | yes | yes | yes | yes | yes | yes |
| `Sum` payload | yes | yes | yes (§5.9) | yes | yes | yes | yes | deferred (D4) |
| `Array(T, n)`, `Bounded(T, n)` element | yes | yes | yes (§5.9) | yes | yes | yes | yes | deferred (D4) |
| `Grow`, `Array T`, `Store` element | yes | yes | yes (§5.9) | yes | yes | yes | yes | deferred (D4) |
| `Map` value | yes | yes | yes (§5.9) | yes | yes | yes | yes | deferred (D4) |
| `Map` key | with semantic equality (syntax §15.1), `Bounded(T, n)` of such | yes, with `Map.borrowing` (below) | as its borrow type, copied by the map | yes | no | no | no | no |
| global | yes | of static data or globals (*decided*) | yes (§5.10) | yes | yes (*decided*, D3) | yes | yes | yes |
| task crossing: spawn copy, message, pool slot type | sendable (syntax §20.5) | no | no | no | yes | moves | no | no |
| a task's view of its spawner, within a tasks scope | read | read-only (*decided*, D1, §8) | read-only borrow | yes | yes | no | no | atomic operations, as today |

The **no** cells, and why:

- **Map keys that are handles, slots, pointers or atomics.** A key needs semantic
  equality and a stable hash; these have neither (syntax §15.1).
- **Owner keys** are written as their borrow type, and the map keeps its own copy:
  `Map(Str, V)`, `Map(Slice T, V)`. A key the map does not copy is a borrow:
  `Map.borrowing(Str, V)` keeps the caller's `Str` keys, checked against the map's
  owner like any stored borrow, and compares them by contents. Tokens keyed by their
  text in a source buffer need no copies.
- **Task crossings.** Owners, borrows, pointers, `Id`s and atomics point into memory a
  task owns; a `copy` into a message or a pool slot crosses instead. Reading the
  spawner's owners within a tasks scope is not a crossing: the value stays where it
  is (§8).

Uniform element types: today `Id`, `Ptr` and `Slot` are admitted as elements only
inside a struct, and `Chan`, `Pool`, `Slot` and `Ptr` are not map values. Those
limits came from earlier implementation steps. A `Slot` is protected by the
runtime's ownership check wherever it sits (syntax §20.6), and a `Ptr` is the
programmer's contract wherever it sits.

## 6. Borrows

### 6.1 The borrow types

| Type | Is |
|---|---|
| `Ref T` | one place, read and write |
| `Slice T` | a run of elements, read-only: pointer and `U64` length |
| `Slice.mut T` | a run of elements, writable; its length cannot change |
| `Str` | `Slice U8` with the text words |

Lengths are `U64`, and an index may be any unsigned integer type, checked against
the length (*decided*, D2; implemented).

Borrows are ordinary expressions, not activities (*implemented*):

```lua
local head = xs:sub(0, 3)            -- Slice U32 borrowing xs
local all = xs:all()
local s = out:str()                  -- Str borrowing out
```

### 6.2 The one lifetime rule

> **A borrow must not outlive the owner it borrows from.** (*implemented*)

The compiler tracks, for every borrow, the owners it depends on (its *roots*; the
word appears only in compiler documentation). The rule applies at every point where
a borrow could escape:

- **Storing:** a borrow may be stored only in a place that its owners outlive.
- **Returning:** a returned borrow must depend only on owners the caller can see:
  the word's arguments, outer owners, or static data. A borrow of the word's own
  local cannot be returned; return the owner itself (it moves) or `copy` it.
- **Branches:** a value leaving a branch cannot borrow an owner created inside it.
- **Joins:** a value that may come from several borrows depends on all of them.

A Lua string literal is a `Str` of static data and borrows nothing that ends.

**Assigning to a `Ref`** (*decided*, implemented) follows the type of the right-hand
side. A `Ref` local, a `Ref` field or a `Ref` element is rebound by a `Ref` value
(`r = Ref y`) and written through by a value of the referred type (`r = 5`).

**Containers** (*decided*, implemented for `Store` and `Grow`): elements are places
like any other, checked against the container's owner by the storing rule. A global
may hold a borrow only of static data or of another global.

### 6.3 Invalidation

Top-level owners never move, so **growing a top-level owner invalidates nothing**.
Only operations that free, reuse or move storage end borrows, and only borrows that
are used afterwards matter:

| Operation | Ends borrows of | Status |
|---|---|---|
| `xs:push v`, `xs:append s`, text writes on a top-level owner | nothing | implemented |
| `xs:pop()`, `xs:clear()`, `xs:truncate n` | `xs`'s contents | implemented |
| `s:remove id` (Store), `m:remove k` (Map) | the store's or map's elements; only the removed one when the compiler proves the others differ | proposed: today a borrow of a removed element sees the next entity put in its slot |
| `m:put k v` (Map) | nothing; for `Map(Str, V)`, the keys (arena compaction) | proposed |
| growing a nested owner (§5.9) | that owner's contents | proposed |
| `compact()` of a holder with nested owners | the nested contents | proposed |
| replacing a `Sum` variant (§4) | the old payload | proposed |

"Used afterwards" is liveness, not lexical scope: a borrow whose last use comes
before the operation does not block it.

```lua
local head = xs:sub(0, 3)
xs:push 99                           -- fine: head stays valid
print head[0]
xs:clear()                           -- fine: head is not used again
```

**Map iteration.** Inside `m:each`, changing `m`'s structure (`put` of a new key,
`remove`) is rejected while compiling. Through a materialized word, the boundary
summary says whether it may change an argument's structure. Through an indirect call
(a `Fn` value), whose summary is unknown, the compiler assumes it may change every
container it can reach. No runtime guard remains (this resolves the former open
question on Map boundary summaries).

### 6.4 Borrows in aggregates

Structs, sums, arrays and containers may hold borrows (*implemented*, except map
values). The one lifetime rule applies to the aggregate as a whole: it depends on
everything its fields borrow.

```lua
local Token = Struct { kind: Kind, text: Str }

local first_token = do(src: Str): Token
    return Token { kind = Kind.word, text = src:sub(0, 1) }   -- borrows src: allowed
end
```

Long-lived relationships between entities are still `Id`s into a `Store`; a borrow
in an aggregate is for structured *views* (tokens over a source, a parsed header
over a buffer).

### 6.5 Function boundaries

Words evaluated in place see every concrete owner, so the rule is checked precisely
at each site. A materialized word (`call`, a re-entered recursion, an export) is
checked once against a summary (*implemented* for results and shrinking):

- which of its arguments each returned borrow may depend on;
- which arguments it may shrink, grow, or structurally change.

The summary is derived from the body; nothing is written by the programmer. `Ref`,
`Slice`, `Str` and aggregates holding them cross `call` under the same summary.

### 6.6 Foreign memory

`view_of(p, n, body)` lends foreign elements to `body` as a `Slice T`. Inside the
activity it is an ordinary borrow; it cannot escape it. This is the one way to give
foreign memory a lifetime the compiler checks. `Ptr T` and `Slice(p, n)` carry
none: they are the programmer's trusted contract, and `Ptr place` drops a lifetime
explicitly.

## 7. Names

`Store T` and `Id T` keep their meaning (generations from 1, retired on wrap, store
tokens never reused). `s[id]` checks the generation at each use; with stacks that
never move, that is a comparison against a stable base. `Store` and `Id` are Nua
library types over `Grow`, not compiler kinds.

| Need | Use |
|---|---|
| use part of an owner for a while | a borrow |
| refer to an entity that may be removed, possibly from elsewhere | an `Id` |

## 8. Tasks

A value crosses a task boundary (spawn copies, channel messages) only if it holds no
borrows. Owners never cross; pool slots keep their move semantics.

**Reading the spawner's owners** (*decided*, D1). A task may hold a read-only borrow
of an owner of its spawner, for the duration of the tasks scope that spawned it. A
`tasks do … endall` scope always ends before the owners outside it, so the lifetime
rule holds. Races are excluded statically: an owner borrowed by a task is **frozen**
for the scope. Neither the spawner nor any task writes it, grows it, shrinks it or
moves it until the scope ends; a write is rejected while compiling, naming the task
that borrows it. A task writes only its own owners and sends results by channel or
pool slot. This gives parallel processing of a large input without copying it.

The borrow is read-only at any depth: a `Ref` or `Slice.mut` reached through the
frozen owner is read-only in the task. Atomics keep their own rules (syntax §19).

## 9. Runtime model

- **Static data stacks.** Each program (main and each task program) has a number of
  data stacks fixed while compiling. Simultaneously live top-level owners get
  distinct stacks; owners with disjoint lifetimes share them, assigned like
  registers. Each nesting level of owners inside a holder adds one arena stack
  (§5.9). A top-level owner is always the top of its stack.
- **Stacks never move** (*implemented*). A stack is a reserved address range,
  committed when touched. Growth bumps the top after one comparison against the
  reservation's limit; exceeding it traps. There are no guard pages: a guard costs a
  kernel mapping per stack, and Linux allows about 65k mappings per process by
  default.
- **Capacity** (stated; previously implicit). The address space bounds how many
  stacks can be reserved at once. On x86-64 with 4-level paging (128 TiB of user
  space), 64 GiB per stack allows about 2,000 thread stacks, and 1 GiB per task stack
  allows about 130,000 task stacks in total across live tasks. Reservations are
  therefore sized, not fixed:
  - the defaults are build parameters (`NUA_THREAD_STACK_BYTES`,
    `NUA_TASK_STACK_BYTES`);
  - a `tasks` scope may state its tasks' reservation, for programs with many small
    tasks;
  - a stack whose owners have a bound known while compiling reserves that bound.
- **Tasks.** Each task gets its program's stack set from a pool; returned sets give
  their memory back to the system. A task reading its spawner's frozen owners (§8)
  addresses them where they are: stacks never move, so no copy and no pinning is
  needed.
- **Calls.** A word that uses data stacks receives its base index. A word compiled
  on its own that returns an owner receives its destination, the result stacks
  `gs_res`, `gs_res + 1`, ... (*decided*, D7). Each owner allocation the word may
  return gets its own result stack, so candidate results never stack on each other;
  the compiler finds which allocations these are when it reaches the returns and
  builds the word again with them placed there. The caller reserves the result
  stacks past its live owners, and releasing the result rewinds them to where they
  stood before the call. A result that is one of the word's owner parameters stays
  where it is.
- **Recursion** (proposed; replaces "no recursive call while an owner of the cycle is
  live"). Frames of a recursive cycle share the cycle's stack indices: each level's
  owners begin above the previous level's on the same stacks, and unwinding releases
  them in order. The stack count stays fixed; depth is bounded by bytes, not by
  stacks. An outer level's owners cannot grow while a deeper level runs, except
  through a `Ref` passed down. That one case, a frame growing an owner created by an
  outer level of the same cycle while it holds an owner above it, is found from the
  boundary summary and rejected; the diagnostic suggests creating the growing owner
  outside the cycle and passing it down, which is the accumulator pattern.
- **Recursive owner results** (*decided*, D7). Every level of a recursion passes its
  own result stacks down, so a deeper level's result lands above the shallower
  levels' on the same stacks, and releases stay in order. A level returning its
  result releases what lies above it; results it consumed stay below until the
  outermost caller rewinds the stacks, so their bytes are retained for the
  recursion's duration. On a result stack only the newest owner can grow: a level
  that grows its own result while a deeper result lies above it is rejected while
  compiling, with the fix (build the result after what it is made from).
- **Targets without virtual memory** use the same semantics with a fixed capacity per
  stack, chosen explicitly as a target profile.

## 10. Compiler primitives and the library

Compiler primitives (Lua and minimal C):

- size classes, scope ownership and moves;
- data stacks: assignment, arenas for nested owners, base and destination passing,
  release;
- `Array(T, n)`, `Array T`, `Bounded(T, n)`, `Grow T`;
- owner aggregates;
- borrows with roots, the lifetime rule, liveness for invalidation, boundary
  summaries;
- the checked-place protocol;
- `copy`, `view_of`, `Ptr`, `Slice(p, n)`.

Written in Nua, specialized with the program:

- `Store T` and `Id T`;
- `Map(K, V)`, `Map(Str, V)`, `Map.borrowing`;
- `Text`, `Str`, `Chars n` text words;
- every container algorithm, including nested-owner growth and `compact()` in arenas.

The `init_storage` hook, the compiler-side Store/Grow kinds and the Grow loan
activity are removed.

## 11. Choosing the right primitive

The static rules are the fast, default path. When one rejects a program, it is
not a dead end: each rule has a way out with a known cost, and the diagnostic names
it. A developer chooses by what the data must survive.

| Need | Primitive | Cost | Guarantee |
|---|---|---|---|
| small data, passed around | **value** | a copy of its bytes | independent of everything |
| data that grows | **owner**, anywhere a value can be | a bump on its stack or arena | released when its outermost owner's scope ends |
| hand storage to another place | **move** at last use | nothing | one owner at a time |
| use part of an owner for a while | **borrow**: `Ref`, `Slice`, `Str` | nothing at runtime | checked while compiling |
| reach an element by key or index, now | **checked place**: `m[k]`, `g[i]`, `s[id]` | one lookup per use | correct whatever happened to the container before |
| refer to an entity that may be removed, from anywhere, for any time | **name**: `Id T` | a generation check per use | a stale name is detected, never confused with a new entity |
| keep data past its owner, or give it to another task | **`copy`**, a channel message, a pool slot | O(n) once | the result owns its own storage |
| memory the compiler cannot see | **raw**: `Ptr T`, `Slice(p, n)`; scoped with `view_of` | nothing | the programmer's contract |

Read the table downward as escape hatches. A borrow that must outlive its owner
becomes a move or a copy. A borrow that must survive the owner's shrinking or the
element's removal becomes an `Id` or a checked place. Memory that comes from C is raw
until a wrapper lends it with `view_of`. Each step trades a static guarantee for a
dynamic one or for a copy, and each step is visible in the source.

Diagnostics point at the next step:

```
head borrows xs (line 14); xs:clear() at line 16 frees what head still uses at line 17
  keep an index or copy the elements: copy xs:sub(0, 3)

kept is stored in g (lives until line 40) but borrows line, which ends at line 12
  move line into g, store an Id, or copy the text into a Text or Chars n

nodes moved into g.nodes at line 3; it is used again at line 5
  use g.nodes, or copy nodes before the move

word find returns a borrow of its own local 'tmp'
  return the owner itself (it moves) or a copy
```

## 12. Changes from today

| Today | Proposed |
|---|---|
| two owners: scope and store | one owner: the scope; a store is a container |
| one resizable field per struct, last | any number of owner fields, anywhere |
| `Graph { nodes = Store(Node) {} }` | `Graph {}` |
| resizable values cannot be returned | returned, built at the caller's destination |
| named owners cannot be assigned | moved at their last use |
| no `copy` | `copy x` |
| owners released only when their scope ends | released at the end of their life, which makes partial moves and replacement exact |
| a task shares no memory with its spawner | a task reads its spawner's owners, frozen for the tasks scope |
| `U32` lengths and indices | `U64` lengths; any unsigned index type |
| `Chan` globals rejected | `Chan` and `Pool` globals allowed |
| containers, sums and arrays hold no owners | nested owners in arenas |
| owners cannot be globals | owner globals in their own regions |
| `Slice T` read-only only | `Slice T` and `Slice.mut T` |
| sum handlers receive payload copies only | a `Ref` handler parameter borrows the payload |
| a `Store` borrow survives `remove` and sees the next entity | `remove` ends borrows of elements |
| Map rehash moves entries; `m[k]` is a checked place only | slots never move; `m[k]` is a real borrow |
| `StrMap V` | `Map(Str, V)`, plus `Map.borrowing(Str, V)` |
| `m[k] = v` traps on a missing key; only `put` inserts | `m[k] = v` inserts or replaces |
| map values hold no borrows; `Chan`, `Pool`, `Slot`, `Ptr` are not map values | uniform element and value types |
| `Id`, `Ptr`, `Slot` admitted as elements only inside a struct | admitted directly |
| Map structural changes during `each` trap at runtime | rejected while compiling, with no runtime guard |
| no recursive call while an owner of the cycle is live | recursion stacks owners on the cycle's indices |
| reservation sizes fixed per build; capacity unstated | capacity stated; reservations sized per program and per tasks scope |
| `g:view() do(xs) ... end`, `out:str() do(s) ... end` | `g:all()`, `g:sub(a, b)`, `out:str()` (*implemented*) |
| push rejected while a view is live | push always allowed; shrinking checks liveness (*implemented*) |
| references banned from aggregates | allowed under the lifetime rule (*implemented*) |
| scoped views cannot cross `call` | borrows cross under derived summaries (*implemented*) |
| data stacks are movable heap buffers | reserved, non-moving stacks (*implemented*) |
| §9.3 variable-size values: not implemented | `Array T` |

## 13. Migration

Each milestone ends with the full acceptance checks (`make test`, `make
test-native`).

1. **Non-moving stacks.** Done.
2. **One borrow system.** Done.
3. **Owners.** Owner structs with any number of owner fields, default-empty and
   zeroed fields; moves at last use; returning owners into the caller's destination;
   `copy`; `Array T`; `Slice.mut T`; owner-typed parameters; recursion with live
   owners; release at end of life (D5); uniform element types; payload borrows;
   `U64` lengths (D2); `Chan` and `Pool` globals (D3).
4. **Library.** `Store`/`Id` with `remove` ending borrows; `Map(K, V)` with the slot
   layout, real borrows, borrows in values, `m[k] = v` inserting, `Map(Str, V)` and
   `Map.borrowing`; the
   text types; all as Nua over the compiler primitives; compile-time `each` checks
   with no runtime guard; `init_storage` and the compiler storage kinds removed.
5. **Nested owners.** Arenas for owners in container elements, arrays, `Bounded`,
   payloads and map values; `compact()`; owner globals.
6. **Capacity.** Reservations per tasks scope and from known bounds.
7. **Tasks.** Read-only borrows of the spawner's owners across a tasks scope, with
   frozen owners (D1).

## 14. Open questions

None. The former open questions are decided (§15 D9–D11).

## 15. Decisions

Recorded 2026-11-02.

- **D1. Tasks reading their spawner's owners: yes**, read-only, with the borrowed
  owners frozen for the tasks scope (§8).
- **D2. Lengths and indices: `U64`** lengths; indices of any unsigned integer type
  (§6.1). Implemented in milestone 3, with every `.length` use migrated. I/O
  operation counts stay `U32` at the runtime boundary (the kernel moves less than
  2 GiB per call); a longer slice written whole traps.
- **D3. `Chan` and `Pool` globals: allowed.** Handles are generational, so a stale
  one traps and never reaches freed memory.
- **D4. Atomics in containers, arrays and payloads: deferred** until a program needs
  them. When taken up, they need element construction in place.
- **D6. Moving out through a `Ref`: allowed through a `Ref` parameter, rejected through
  a `Ref` read from data** whose target is not known while compiling (§5.4).
- **D7. Recursive owner results: result stacks** passed down the recursion, with the
  growth check (§9). Decided 2026-11-02, after the simpler check proved unsound
  (results returned up a recursion would share stacks and could be released out of
  order).
- **D8. General release at the last use: a later milestone** (§5.8).
- **D9. Grow-shrink storage: covered by `Grow`.** What Goose's `[>..<]` gives (a
  vector that grows and shrinks with fast reuse) is `Grow` with `pop`, `truncate` and
  `clear` under the liveness rule (§6.3); `pop` and `truncate` land in milestone 4.
- **D10. Owners stay runtime-only.** An owner's contents are runtime storage, never
  tracked while compiling; staging lives in values and known descriptions
  (`Map.known`).
- **D11. Mutual recursion with owners: implemented in milestone 3.** A recursion's
  words share one result region, each word at its own offset assigned when the
  recursion is planned, and every level passes the region down; the summaries of
  which `Ref` arguments its words move out are computed together over the
  recursion, which is built again until they agree.
- **D5. Partial moves: no choice was needed.** The earlier options (keep the unmoved
  owner's bytes until the destination ends, or reject) came from keeping Goose's
  release-at-scope-exit. Releasing an owner at the end of its life (§5.8) makes a move
  on some paths exact and static.
