# Nua memory: model and API (design proposal)

Status: **proposal for review.** Nothing here is implemented yet. When it is
approved, its contracts move into [syntax.md](../syntax.md) (§9, §12, §14, §15) and
its compiler/runtime parts into [architecture.md](../architecture.md) (§7, §8, §12).
Until then those documents describe the current implementation.

Starting point: [Goose](https://aardappel.github.io/goose/docs/goose_spec.html).
Its runtime model is kept as a guarantee, because its simplicity and speed come from
it. Its surface and its limits are re-engineered where Nua's own nature (in-place
specialization, tasks, generational IDs, the foreign boundary) asks for something
else.

## 1. The safety contract

A Nua program that compiles, without raw pointers, never:

- reads or writes outside a value's storage (indices are checked; checks that a
  path already proves are removed);
- uses storage after its owner ended;
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
| Values copy; owners never copy silently. `copy x` is the visible O(n) copy. | A cost the reader cannot see is a cost the reader cannot judge. |
| Reading is unmarked; writing is marked. `Ref x` at a call site, `Slice.mut T` in a signature. | Let the contract say copy or borrow (design guide §13). |
| An owner passed where a read-only borrow is expected borrows without a marker: `sum xs`. | Reading cannot invalidate anything; ceremony would buy nothing. |
| Owner fields start empty: `Graph {}`. Initial contents are optional: `Grow U32 { 1, 2, 3 }`. | Creation in place should read like construction of any value. |
| An owner is returned like a value; the callee builds it where the caller keeps it. | A word's result is its result; placement is the compiler's job. |
| Checks are on; facts remove them. | Safety by default, cost only where nothing proves the bound. |
| Raw memory is spelled raw: `Ptr T`, `Slice(p, n)`. | The trusted boundary is visible in the source. |

## 3. Roles

The design guide's roles (§5.1) become the type vocabulary. A user chooses a role;
the size class (fixed, variable, resizable) follows from it.

| Role | Meaning | Types |
|---|---|---|
| **value** | copied freely, owned by whoever holds it | scalars, `struct`, `oneof`, `Array(T, n)`, `Bounded(T, n)`, `Chars n` |
| **owner** | has storage; created in place; borrowed or returned, never copied silently | `Grow T`, `Array T`, `Store T`, `Map(K, V)`, `Text`, and any struct holding one |
| **borrow** | uses an owner's storage; cannot outlive it | `Ref T`, `Slice T`, `Slice.mut T`, `Str` |
| **name** | identifies an entity without owning it; survives removal | `Id T` |
| **raw** | the trusted foreign boundary | `Ptr T`, `Slice(p, n)` |
| **handle** | runtime-owned state with its own transfer rules | `Chan`, `Pool`, `Slot` (unchanged) |

## 4. Values

Fixed-size, copied on assignment and passing, stored in C locals and registers.

| Type | Meaning |
|---|---|
| `Array(T, n)` | `n` elements of a fixed `T`, `n` known while compiling |
| `Bounded(T, n)` | capacity `n` inline, with a runtime length; `push`, `pop`, `clear` within capacity; exceeding it traps |
| `Chars n` | `Bounded(U8, n)` with the text words |
| `struct`, `oneof` | as today; fields and payloads may now hold borrows (§6.4) |

A `oneof` is replaced only as a whole, and handlers receive payload **copies**: no
reference ever points into a payload, so replacing the variant is always safe
(Goose's fixed mode). Nua has no variable-mode sums.

## 5. Owners

### 5.1 The owner types

| Type | Storage | Element addresses |
|---|---|---|
| `Grow T` | resizable: grows at the top of its stack | stable while it lives; shrinking needs no live borrow (§6.3) |
| `Array T` | variable: length fixed when built, at runtime | stable |
| `Store T` | a `Grow` of slots with a free list and generations (Nua library) | stable; addressed by `Id T` |
| `Map(K, V)` | Nua library over `Grow`; `Map(Str, V)` adds a key arena | move on rehash: reached only through checked places (§5.6) |
| `Text` | `Grow U8` with the text words | as `Grow` |

`Array(T, n)` with a known `n` is a value; built with a runtime length it is the
owner `Array T`. One constructor; the binding time of the length decides the class.

### 5.2 Creation

An owner is created where it lives: a typed local, or a field of an owner struct.

```lua
local xs = Grow U32 {}               -- empty
local ys = Grow U32 { 1, 2, 3 }      -- with contents
local buf = Array(U8, n) {}          -- n known: a value; n at runtime: an owner
local out = Text {}
```

Any struct that holds an owner is an owner struct. It may hold any number of owner
fields; each gets its own data stack. Owner fields left out of the constructor start
empty:

```lua
local Graph = struct {
    nodes: Store Node,
    edges: Store Edge,
    name: Chars 32,
}

local g = Graph {}                   -- nodes and edges empty, name zeroed
local h = Graph { name = Chars(32) "roads" }
```

### 5.3 Returning

An owner is returned like a value. The callee builds it directly in the caller's
destination: a local, a field, an element being pushed, or an argument.

```lua
local squares = do(n: U32): Grow U64
    local out = Grow U64 {}
    for i: U32 = 1, n do out:push U64 i * U64 i end
    return out
end

local xs = squares 10                -- built on xs's stack, never copied
g.paths:push(route a b)              -- built in the new element
```

### 5.4 Copying

`copy x` duplicates an owner into a new destination. It is the only way to duplicate
one, so every O(n) copy appears in the source. Assigning a named owner to another
place is an error that suggests `copy` or `Ref`.

### 5.5 Passing

| Parameter | Argument | Meaning |
|---|---|---|
| `Ref T` | `Ref g` | borrow for reading and writing, including growth |
| `Slice T`, `Str` | `g` | read-only borrow of the elements; no marker |
| `Slice.mut T` | `Ref g` | borrow of the elements for writing; length fixed |
| `T` (an owner type) | a fresh owner: a constructor or call result | the parameter is built in place; a named owner needs `copy g` or `Ref g` |

`Ref` at a call site always means *this argument may change*.

### 5.6 Checked places

A checked place is a place computed by a word and found again at each use: `s[id]`,
`m[k]`, `g[i]`. It holds no address between uses, so it stays correct whatever
happens to the container in between. This is a general protocol: a library type
defines how a key resolves to a place, and the compiler treats the result as a place.

Containers whose own algorithm moves entries (`Map` rehashes, `Map(Str, V)` compacts
its arena) give out checked places only. `Grow`, `Array T` and `Store T` give out
real borrows. Each container states which it does; the compiler does not special-case
it.

### 5.7 Release

The only deallocation is leaving the scope that created an owner: its stack's top
returns to where the owner began. There are no destructors and no reference counting.
Early returns, `break` and trap recovery release the same way.

## 6. Borrows

### 6.1 The borrow types

| Type | Is |
|---|---|
| `Ref T` | one place, read and write |
| `Slice T` | a run of elements, read-only: pointer and `U32` length |
| `Slice.mut T` | a run of elements, writable; its length cannot change |
| `Str` | `Slice U8` with the text words |

Borrows are ordinary expressions, not activities:

```lua
local head = xs:sub(0, 3)            -- Slice U32 borrowing xs
local all = xs:all()
local s = out:str()                  -- Str borrowing out
```

### 6.2 The one lifetime rule

> **A borrow must not outlive the owner it borrows from.**

The compiler tracks, for every borrow, the owners it depends on (its *roots*; the
word appears only in compiler documentation). The rule applies at every point where
a borrow could escape:

- **Storing:** a borrow may be stored only in a place that its owners outlive.
- **Returning:** a returned borrow must depend only on owners the caller can see:
  the word's arguments, outer owners, or static data. A borrow of the word's own
  local cannot be returned; return the owner itself or `copy` it.
- **Branches:** a value leaving a branch cannot borrow an owner created inside it.
- **Joins:** a value that may come from several borrows depends on all of them.

A Lua string literal is a `Str` of static data and borrows nothing that ends.

**Assigning to a `Ref`** (decided 2026-11-02) follows the type of the right-hand
side. A `Ref` local, a `Ref` field or a `Ref` element is rebound by a `Ref` value
(`r = Ref y`) and written through by a value of the referred type (`r = 5`). `Ref T`
and `T` are different types, so the two never collide, and a `Ref` parameter keeps
its meaning (`target = text` writes through).

**Containers** (decided 2026-11-02): `Store` and `Grow` elements may hold borrows.
They are places like any other, checked against the container's owner by the
storing rule. A global may hold a borrow only of static data or of another
global, since it outlives every owner.

### 6.3 Invalidation

Growth never moves elements, so **growing does not invalidate borrows**. Only
operations that free or reuse element storage do:

| Operation | Allowed when |
|---|---|
| `xs:push v`, `xs:append s`, text writes | always |
| `xs:pop()`, `xs:clear()`, `xs:truncate n` | no borrow of `xs` is used later |
| `s:remove id` (Store) | always: the slot is kept, its generation changes |
| `m:put`, `m:remove` (Map) | always: Map gives out only checked places; inside `m:each`, structural changes to `m` are rejected |

"Used later" is liveness, not lexical scope: a borrow whose last use comes before
the `clear` does not block it.

```lua
local head = xs:sub(0, 3)
xs:push 99                           -- fine: head stays valid
print head[0]
xs:clear()                           -- fine: head is not used again
```

### 6.4 Borrows in aggregates

Structs, sums and arrays may hold borrows. The one lifetime rule applies to the
aggregate as a whole: it depends on everything its fields borrow.

```lua
local Token = struct { kind: Kind, text: Str }

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
checked once against a summary:

- which of its arguments each returned borrow may depend on;
- which arguments it may shrink or structurally change.

The summary is derived from the body; nothing is written by the programmer. `Ref`,
`Slice`, `Str` and aggregates holding them cross `call` under the same summary.
Inside a recursive cycle, a borrow of a local of the cycle may be passed down but
not stored or returned.

### 6.6 Foreign memory

`view_of(p, n, body)` lends foreign elements to `body` as a `Slice T`. Inside the
activity it is an ordinary borrow; it cannot escape it. This is the one way to give
foreign memory a lifetime the compiler checks. `Ptr T` and `Slice(p, n)` carry
none: they are the programmer's trusted contract, and `Ptr place` drops a lifetime
explicitly.

## 7. Names

`Store T` and `Id T` keep their current meaning (generations from 1, retired on wrap,
store tokens never reused). `s[id]` is a checked place; with stacks that never move,
resolving it is a generation check against a stable base. `Store` and `Id` are Nua
library types over `Grow`, not compiler kinds.

Choose by need:

| Need | Use |
|---|---|
| use part of an owner for a while | a borrow |
| refer to an entity that may be removed, possibly from elsewhere | an `Id` |

## 8. Tasks

A value crosses a task boundary (spawn copies, channel messages) only if it holds no
borrows. Owners never cross; pool slots keep their move semantics. A task cannot
borrow its spawner's owners.

## 9. Runtime model

- **Static data stacks.** Each program (main and each task program) has a number of
  data stacks fixed while compiling. Simultaneously live resizable owners get
  distinct stacks; owners with disjoint lifetimes share them, assigned like
  registers. A resizable owner is always the top of its stack.
- **Stacks never move.** A stack is a reserved address range, committed when touched.
  Growth bumps the top after one comparison against the reservation's limit;
  exceeding it traps. There are no guard pages: a guard costs a kernel mapping per
  stack, and Linux allows about 65k per process by default, so thousands of tasks
  would exhaust it. One comparison beside the store a push already does is cheap,
  the specializer removes it when a bound is known, and the same code serves targets
  without virtual memory.
- **Reservations.** 64 GiB per stack for threads and 1 GiB per stack for tasks by
  default, both build parameters. A task's whole stack set is one reservation.
- **Tasks.** Each task gets its program's stack set from a pool; returned sets give
  their memory back to the system.
- **Calls.** A word that uses data stacks receives its base index, as today; a
  callee building an owner result receives its destination stack.
- **Recursion.** A recursive call may not happen while a resizable owner of the cycle
  is live (unchanged: it keeps the stack count fixed).
- **Targets without virtual memory** use the same semantics with a fixed capacity per
  stack, chosen explicitly as a target profile.

## 10. Compiler primitives and the library

Compiler primitives (Lua and minimal C):

- size classes and scope ownership;
- data stacks: assignment, base and destination passing, release;
- `Array(T, n)`, `Array T`, `Bounded(T, n)`, `Grow T`;
- owner structs with any number of owner fields;
- borrows with roots, the lifetime rule, liveness for invalidation, boundary
  summaries;
- the checked-place protocol;
- `copy`, `view_of`, `Ptr`, `Slice(p, n)`.

Written in Nua, specialized with the program:

- `Store T` and `Id T`;
- `Map(K, V)` including `Map(Str, V)`;
- `Text`, `Str`, `Chars n` text words;
- every container algorithm.

The `init_storage` hook, the compiler-side Store/Grow kinds and the Grow loan
activity are removed.

## 11. Choosing the right primitive

The static rules are the fast, default path. When one rejects a program, it is
not a dead end: each rule has a way out with a known cost, and the diagnostic names
it. A developer chooses by what the data must survive.

| Need | Primitive | Cost | Guarantee |
|---|---|---|---|
| small data, passed around | **value** | a copy of its bytes | independent of everything |
| data that grows, used in one scope | **owner** | a bump on its stack | released when the scope ends |
| use part of an owner for a while | **borrow**: `Ref`, `Slice`, `Str` | nothing at runtime | checked while compiling |
| reach an element by key or index, now | **checked place**: `m[k]`, `g[i]`, `s[id]` | one lookup per use | correct whatever happened to the container before |
| refer to an entity that may be removed, from anywhere, for any time | **name**: `Id T` | a generation check per use | a stale name is detected, never confused with a new entity |
| keep data past its owner, or give it to another task | **`copy`**, a channel message, a pool slot | O(n) once | the result owns its own storage |
| memory the compiler cannot see | **raw**: `Ptr T`, `Slice(p, n)`; scoped with `view_of` | nothing | the programmer's contract |

Read the table downward as escape hatches. A borrow that must outlive its owner
becomes a copy. A borrow that must survive the owner's shrinking or the element's
removal becomes an `Id` or a checked place. Memory that comes from C is raw until a
wrapper lends it with `view_of`. Each step trades a static guarantee for a dynamic
one or for a copy, and each step is visible in the source.

Diagnostics point at the next step:

```
head borrows xs (line 14); xs:clear() at line 16 frees what head still uses at line 17
  keep an index or copy the elements: copy xs:sub(0, 3)

kept is stored in g (lives until line 40) but borrows line, which ends at line 12
  store an Id, or copy the text into a Text or Chars n

word find returns a borrow of its own local 'tmp'
  return the owner itself (it is built in the caller's place) or a copy
```

## 12. Changes from today

| Today | Proposed |
|---|---|
| two owners: scope and store | one owner: the scope; a store is a container |
| one resizable field per struct, last | any number of owner fields |
| `Graph { nodes = Store(Node) {} }` | `Graph {}` |
| resizable values cannot be returned | returned, built at the caller's destination |
| no `copy` | `copy x` |
| `Slice T` read-only only | `Slice T` and `Slice.mut T` |
| `g:view() do(xs) ... end`, `out:str() do(s) ... end` | `g:all()`, `g:sub(a, b)`, `out:str()` |
| push rejected while a view is live | push always allowed; shrinking checks liveness |
| references banned from aggregates | allowed under the lifetime rule |
| scoped views cannot cross `call` | borrows cross under derived summaries |
| `StrMap V` | `Map(Str, V)` |
| Map structural changes during `each` trap at runtime | rejected while compiling |
| §9.3 variable-size values: not implemented | `Array T` |
| data stacks are movable heap buffers | reserved, non-moving stacks |

## 13. Migration

Decided order: **non-moving stacks first.** They remove most of today's special
cases, so the later milestones build on a simpler base. Each milestone ends with the
full acceptance checks (`make test`, `make test-native`).

1. **Non-moving stacks.** `lib/stacks.nua` reserves address ranges (`mmap`,
   committed on touch, no guard pages) instead of growing buffers with `realloc`;
   the reservation sizes are build parameters. The relocation primitive
   (`nua_gs_pin`) and the pinning in Text and the Map arena go. Growth during
   `g:view` and `out:str` is allowed; only shrinking is rejected there.
2. **One borrow system.** Roots for `Ref`, `Slice`, `Str` and aggregates holding
   them; the one lifetime rule; liveness-based shrink checks; derived boundary
   summaries for materialized words. `g:all()`, `g:sub(a, b)` and `out:str()`
   become plain borrows here, since their shrink checks need liveness. The current special checks (return of an own
   local, scoped-view tokens, the aggregate ban) are replaced, not kept beside it.
3. **Owners.** Owner structs with any number of owner fields and default-empty
   fields; returning owners into the caller's destination; `copy`; `Array T`;
   `Slice.mut T`; owner-typed parameters.
4. **Library.** `Store`/`Id`, `Map(K, V)` with `Map(Str, V)`, and the text types as
   Nua over the compiler primitives; `init_storage` and the compiler storage kinds
   removed.

## 14. Open questions

1. **Map boundary summaries**: whether "may change structure" is precise enough
   through every materialized word to drop the runtime iteration guard entirely, or
   whether a guard remains for indirect calls.
2. **Grow-shrink storage**: Goose's `[>..<]` (fast LIFO reuse, borrows held only in
   locals) is left out until a program needs it.
3. **Staged storage**: owners whose contents are known while compiling could fold
   like lazy structs, making `Map.known` an ordinary known `Map`. It needs no runtime
   change and is left for a later proposal.
