# Buffers: Nua's memory model

**Approved design, 2026-11-08.** The user agreed to the buffer model ("i agree with
this idea !!"), chose the name `Buffer` for its one storage primitive, and chose
`.pinned` type variants (`Text.pinned`, `Grow.pinned T`) for storage that never moves.
This document owns the memory model of the replacement compiler. [Syntax](../syntax.md)
§9 states its language contract; [architecture](../architecture.md) distinguishes it
from the current implementation; [compiler activities](compiler-activities.md) carries
its compiler data and operations. No implementation or test run accompanies it.

It replaced the earlier designs: Goose-style fixed data stacks, then affine regions
with custody, fragments, recovery domains, a PREPARE/READY/COMMIT/RETIRE protocol,
positions and compaction cuts. The native task runtime approved with the regions is kept
in [tasks](tasks.md), with one change: a source wait is a context switch (§2.6).

## 1. Why the earlier design grew

The earlier designs let several owners share storage. Goose gives each type position one
stack; region completion let nested owners be fragments of an enclosing region. Shared
storage leaves holes when one tenant grows or is removed. Reclaiming the holes means
moving live data, and moving live data means knowing every pointer into it. That
reasoning is a collector's: positions are its spaces, compaction moves live data, cuts
are a static write barrier, retirement lists are its sweep, and the commit protocol
keeps it consistent across traps. Every runtime distinction then reappeared as a
compiler fact (holdings, endpoints, custody, loan subjects, epochs, storage guarantees).

The buffer model removes the premise. **No two owners share storage**, so storage is
never compacted, and nothing needs a collector's reasoning. The developer experience
that sharing was meant to buy (growth that keeps borrows valid) comes instead from
how the compiler represents a borrow it holds (§2.3).

## 2. The rules

### 2.1 Roles

The roles are unchanged from the earlier designs:

| Role | Types |
|---|---|
| value | scalars, `struct`, `oneof`, `Array(T, n)`, `Bounded(T, n)`, `Chars n`, when they hold no owner |
| owner | `Buffer T`, `Grow T`, `Array T`, `Store T`, `Map(K, V)`, `Text`, their `.pinned` variants, any aggregate holding one |
| borrow | `Ref T`, `Slice T`, `Slice.mut T`, `Str` |
| name | `Id T` |
| raw | `Ptr T`, `Slice(p, n)` |
| handle | `Chan`, `Pool`, `Slot` |

### 2.2 Owners and their buffers

**A buffer is a header and one allocation.** The header is `{ data, length, capacity }`
(a pinned buffer adds its reserved limit). The allocation holds `capacity` elements, of
which the first `length` are initialized. A buffer owns exactly its allocation.

**Every owner is made of buffers.** `Grow T` is one buffer. `Text` is one buffer of
`U8`. `Store T` is a buffer of slots. `Map(K, V)` is a buffer of entry slots and a
buffer of index cells (plus a buffer of key bytes for `Map(Str, V)`). An aggregate
holding owners holds their headers. A nested owner, such as each `Text` in a
`Grow Text`, is an element whose header owns its own allocation. Nothing is shared, so
nested and top-level owners follow the same rules.

`Buffer T` is a safe public type: its words check bounds and keep the initialized
prefix. It is the foundation that library containers are written over. Ordinary
programs normally use `Grow T` and the other containers.

The owner rules of syntax §9.2 stay as they are:

- **Created in place**, starting empty.
- **Moved at its last use**, with exact moves on some paths only: the paths that do not
  move an owner release it before they join.
- **Never copied silently**: `copy` is the visible O(n) duplicate.
- **Returned like a value**, built where the caller keeps it.
- **Replaced by assignment**, which ends the old value.
- **Released when its life ends.**

**Moving an owner moves its header bits.** It never moves its payload. **Releasing an
owner** is a finite typed walk: release the owning contents (initialized elements, the
active alternative of a sum, owning fields), then release its allocations. The
specializer generates it from the type; runtime lengths become ordinary loops.

### 2.3 Borrows: held and stored

> **The header is the truth. A borrow you hold is a path from a header.**

A **held** borrow is a value of a local or a temporary inside a word being evaluated. The
compiler represents it as a path: a root place, field and element steps, and a range.
Examples are `(players, element i)`, `(buf, bytes 0..n)` and
`(lines, element i, bytes 0..n)`. It produces the native pointer when the borrow is used,
and keeps that pointer in a register until an operation that may move a buffer on the
path. After such an operation it derives the pointer again from the current header (one
load per moved step). Aliases cannot defeat this: two `Ref`s to an owner reach the same
header.

A **stored** borrow is a native pointer (or pointer and length) whose value has left the
compiler's view:

- it was written into data (a field of an aggregate in memory, an element, a global);
- it crossed into a word compiled on its own (a `call`, recursion, an export) as an
  argument;
- it was passed to foreign code.

A borrow returned by a compiled word becomes held again in the caller when the word's
contract names one origin buffer: the caller derives its path from that buffer's header
and the returned offset. Otherwise it stays stored.

Buffer operations have one of two effects on the borrows of a buffer's contents:

| Effect | Operations | Held borrow | Stored borrow |
|---|---|---|---|
| **Moves** | growth that may relocate: `push`, `append`, text writes, `reserve`, inserting a new map key, `Store:add`, growing a nested owner | survives; its pointer is derived again | **ends** |
| **Ends** | `pop`, `truncate`, `clear`, `remove`, replacement, moving or releasing the owner | **ends** | **ends** |

A `.pinned` buffer's growth has neither effect (§2.4).

This yields three rules for developers:

> 1. **Growth never ends a borrow you hold.**
> 2. **Removing, shrinking, clearing, replacing or moving an owner ends the borrows of
>    what it removed.**
> 3. **A stored borrow ends when its buffer grows, unless the buffer is pinned.**

They join the lifetime rule of syntax §9.5, which is unchanged: a borrow must not outlive
the owner it borrows from (storing, returning, branches and joins, use). As today, an
ended borrow is an error only where it is used afterwards; liveness, not scope, decides.

`Ends` is precise where the compiler can tell positions apart. `Store:remove id` and
`Map:remove k` end the removed slot's borrows; borrows of other slots survive when the
compiler proves them different (by known IDs or keys), and end otherwise. Shrinking a
buffer ends every borrow of its contents. A reference to an owner's header (`Ref g`)
survives `clear` and replacement while that header place lives.

A compiled word's contract records, for each argument, whether the word may move or end
its buffers. A call that would move a buffer while also receiving a stored borrow of
it is rejected at the call: the stored borrow would outlive the move inside the callee.

### 2.4 Pinned buffers

`Grow.pinned T` and `Text.pinned` (and any library type built over `Buffer.pinned T`)
reserve a range of address space when created and commit pages as they grow. **Their
storage never moves**, so their growth has no `Moves` effect: stored borrows of their
contents survive growth too. A pinned buffer has a reserved limit, given at creation or
taken from the runtime default; growing past it traps. Everything else (moving the
owner, `Ends`, release, `copy`) is as for any owner.

Pinning is a choice of data structure, visible in the type, so a word can require it:

```lua
local Token = struct { kind: Kind, text: Str }
local scan = do(src: Ref Text.pinned, out: Ref Grow Token)
    ...                        -- stores views of src in out while src keeps growing
end
```

Pinned buffers are for a few large, long-lived buffers (sources being read, journals,
logs). Creating one costs a system call and its minimum footprint is a page, so the
default remains moving storage. On Linux a large moving buffer may grow with `mremap`;
that is an allocator speed gain with no semantic effect.

### 2.5 Traps and the validity of storage

Every buffer operation builds its new storage completely, then publishes it by writing
the header, then releases what it replaced. **Header writes never trap.** Moving an
owner writes headers only. So at every trap, every reachable header describes complete,
valid storage. There is no transaction protocol and no recovery record: this ordering
is the whole storage-consistency guarantee.

- In a task, a trap is fatal to the process (syntax §20).
- A plain in-process entry may recover (`nua_try`). Globals and the caller's storage
  remain valid. Earlier source effects are not rolled back. The storage the trapped
  entry still owned is **leaked, not reclaimed**: recovery frees nothing and reads no
  abandoned frame.

### 2.6 Tasks and waits

Each task runs on its own nonmoving native stack ([tasks](tasks.md)). **Every
suspension is a context switch**: a budget point, and a source wait too. A task is no
longer compiled into a typed frame and a step function; its frames stay on its stack
while it waits.

- A word compiled on its own may wait; nothing restricts waits to inline bodies.
- No switch happens inside a foreign extent ([tasks §3](tasks.md#3-seeded-service-and-foreign-extents)). A word that may wait
  cannot be given to C as a callback; that is refused when compiling.
- A plain thread that waits switches to the scheduler (seeded mode) or blocks (worker
  mode), as [tasks §2](tasks.md#2-dispatch-and-continuation-lifetime) specifies.
- A task's stack is a pinned reservation of bytes with a guard page; exhaustion is fatal.

Budget points remain: on every residual loop backedge, and on entry to a compiled word
that is part of a call cycle.

### 2.7 What developers see

```lua
local p = Ref players[i]
players:push new_player
p.hp = 10                      -- fine: p is held

local line = buf:str()
buf:write "more"
emit line                      -- fine: line is derived again from buf

local t = Ref lines[i]
lines[j]:write "x"             -- another nested text grows
print t                        -- fine

local head = xs:sub(0, 3)
xs:clear
print head[0]                  -- error: 'xs' was cleared at line N; 'head' borrows its contents

local tok = Token { kind = Kind.word, text = src:sub(0, 1) }
src:write more_input
use tok.text                   -- error: the view stored in 'tok' ends because 'src' grew
                               -- (declare src Text.pinned, or store an offset)
```

Each error names the operation and the later use. Indices, `Id`s, copied values and
passing `Ref xs` never conflict with mutation.

## 3. The data

### 3.1 Runtime representations

| Value | Representation |
|---|---|
| `Buffer T`, `Grow T`, `Text` | header `{ data: Ptr T, length: U64, capacity: U64 }` |
| `.pinned` variants | header `{ data, length, capacity, limit: U64 }` |
| `Array T` | buffer header whose length is fixed when built |
| `Store T` | `{ slots: Buffer (Slot T), free, live, token }` |
| `Map(K, V)` | `{ entries: Buffer (Entry K V), index: Buffer U32, free, ... }`; `Map(Str, V)` adds `keys: Buffer U8` |
| `Ref T` | a pointer |
| `Slice T`, `Str` | pointer and `U64` length |
| aggregate owner | its fields, each owner field a header |

There is no runtime object per borrow, per region or per operation. Store and map
layouts are library choices in Nua; the table shows the intended composition.

### 3.2 Allocation

Each thread and each task has a **storage context**: the allocator's state. The
allocator is a Nua library over the platform mechanisms of §3.4.

- **Small allocations** come from per-size-class free lists over pages taken from the
  mechanisms. Allocating and freeing are a few instructions each.
- **Large allocations** map their own pages and release them when freed; growth may use
  `mremap` where available.
- **Pinned buffers** reserve their limit as address space and commit pages as they grow.

Capacity policy (growth factor, size classes, thresholds) is Nua code. A buffer is freed
by the context that owns it; a task never frees another task's storage (tasks share no
owners, syntax §20).

### 3.3 Compiler facts

These replace holdings, endpoints, custody, loans, loan subjects, epochs and storage
guarantees. They are published as nominal records in `nua/compiler/data.mua`
([compiler activities §2](compiler-activities.md#2-the-values-that-evaluation-works-with)).

```text
Access       { place: PlaceId, path: AccessPath }
BorrowPath   { root: PlaceId, steps: AccessPath, range: Option Range }
Range        { first: Operand, count: Operand }
BorrowInfo   { id: BorrowId, form: BorrowForm, origins: List Access, acquired: OriginId }
BorrowForm   = Held(path: BorrowPath, pointer: Option Operand)
             | Stored(pointer: Operand)
BorrowState  = Live | Ended(at: OriginId, reason: EndReason)
EndReason    = Grew | Shrank | Removed | Cleared | Replaced | Moved | Released
Contents     = Uninitialized | Tracked(value: NativeValue)
             | Resident(info: ValueInfo) | Moved(at: OriginId)
```

`Held.pointer` is the cached native pointer, valid until a `Moves` on the path; `absent`
means "derive it at the next use". `origins` lists every buffer the borrow may point
into (several after a join). A borrow whose steps include an unknown element index uses
`AnyElement` in its origins; its path keeps the actual index operand.

### 3.4 Platform mechanisms

C supplies only these storage mechanisms: `map_pages`, `unmap_pages`, `remap_pages`
(optional), `reserve_range`, `commit_range`, `release_range`, `move_bytes`, plus the
context mechanisms of [tasks §4](tasks.md#4-platform-mechanism-and-resource-lifecycle) (`context_initialize`, `context_switch`,
`context_finish`) and `fatal_trap` / `recover_jump`. Allocation policy, size classes,
free lists and typed walks are Nua.

## 4. The operations

### 4.1 Buffer words and their declared effects

`Buffer T` words are ordinary Nua over the mechanisms. The compiler knows only two
general primitives, which any library word may use:

- **the effect declarations** `moves access` and `ends access reason`, which record the
  effect at the word's site;
- **the initialized-prefix transitions** `initialize buffer index value` and
  `finish buffer first limit`, which a buffer's own words use to extend or shrink the
  checked initialized range.

| Word | Result | Declared effect |
|---|---|---|
| `reserve b n` | capacity ≥ n | `moves b` (moving), none (pinned) |
| `push b v` / `append b s` | element(s) initialized at the end | via `reserve`; consumes an owning `v` |
| `pop b` | the last element, owned | `ends b (Shrank)` |
| `truncate b n` | length n | `ends b (Shrank)` |
| `clear b` | length 0 | `ends b (Cleared)` |
| `b[i]` | the element as a place | none; bounds check unless proved |
| `view b i j` | `Slice T` | none; a new borrow of `(b, i..j)` |
| `release b` | – | `ends b (Released)`; releases initialized owning elements first |

`Grow`, `Text`, `Store`, `Map` and their pinned variants are written over these words and
inherit their effects. A container may refine `ends` by key or ID, as `Store:remove` and
`Map:remove` do (§2.3). The effect declaration is the replacement for today's
`__S.retire`, `__S.restructure` and `__S.grows`.

### 4.2 What each effect does to the facts

| Event | Held borrows whose origins overlap | Stored borrows whose origins overlap | Owner places |
|---|---|---|---|
| `moves access` | drop `pointer` | `Ended(Grew)` | – |
| `ends access reason` | `Ended(reason)` | `Ended(reason)` | – |
| owner move out of a place | `Ended(Moved)` | `Ended(Moved)` | `Moved(at)` |
| owner replaced | `Ended(Replaced)` | `Ended(Replaced)` | new `Tracked` |
| store borrow into data / pass to compiled word / pass to C | becomes `Stored` (materialize pointer first) | – | – |
| use of a borrow | `Live`: derive pointer if absent; `Ended`: error naming `at` and the use | same | – |

Overlap compares origins by place and access path; `AnyElement` overlaps every element.

## 5. State across boundaries

Following the compiler guide's §4.5 question, *what survives a boundary*:

| Boundary | Borrow states | Held pointer caches | Owner place states |
|---|---|---|---|
| branch, two arms | forked | forked | forked |
| branch join | `Ended` on any live incoming edge → `Ended` (reason kept); a block argument of borrow type gets the union of origins | dropped unless equal on all edges | equal or rejected as in syntax §9.2; a place moved on one edge only is released on the other edge before the join |
| loop header | joined like a branch over the entry and continuing edges; a borrow passed around the backedge is checked on that edge | dropped if a `moves` occurs in the body | as at a join |
| inline invocation | shared: the callee works on the caller's facts | shared | shared |
| compiled word (`call`) | arguments become `Stored` parameters; the contract states moves/ends per argument; a returned borrow is held again when it names one origin | caller's caches dropped by the contract's `moves` | contract's consumes |
| task spawn | no borrow crosses (syntax §20) | – | captured owners move into the task |
| foreign call | arguments become `Stored`; effects from the foreign contract | dropped for buffers the C code may change | – |

The loop case needs no epochs. If the body ends a view and takes a fresh one before the
backedge, the header joins two live borrows. If it passes the old one, that edge carries
an ended borrow, and its use in the next round is rejected.

## 6. Activities and completion

- **Evaluation** creates borrows as held paths, applies §4.2 at each site, and derives
  pointers on use. Buffer words are evaluated in place like any word: their mechanism
  calls, stores and checks appear at their source point. There is **no late storage
  realization**: no `Storage`, `StartTask` or `SourceWait` instruction survives
  evaluation, and none exists.
- **Scope completion** belongs to the evaluator: at the end of a scope, on the edge of
  a conditional move, at replacement and at a return, it evaluates the `release` word of
  each live owner place, in reverse declaration order. An owner-typed SSA value must be
  consumed exactly once on every path; the verifier checks that linearity.
- **Returns**: capture the result, complete the scope, write the result header into the
  caller's slot. An owner result is built in the caller's slot; its buffers come from
  the context's allocator.
- **Compiled words** publish a contract: per argument, its moves, ends and consumes; per
  result, its borrow origins; and the alias requirements of §2.3.
- **Budget insertion** is the only late pass: after the call graph is closed, it adds
  budget points on residual backedges and on entries of compiled words in call cycles.
- **Tasks**: spawning is a Nua word that takes a stack from the mechanisms, initializes a
  context, moves the captures and publishes the task to the scheduler. Waiting is a Nua
  word that registers the operation and switches context.

## 7. Scenarios

| Scenario | Outcome |
|---|---|
| `Ref players[i]` across `players:push` | held path `(players, i)`; the pointer is derived again after the push |
| view of a `Text` across `write` | held `(buf, 0..n)`; derived again |
| nested `lines[j]:write` while holding `lines[i]`'s bytes | `moves (lines, AnyElement)` drops the cache; derived again |
| two owners A/B chosen by a branch and swapped | SSA block arguments carry the headers; linearity checks each is consumed once; no holding identities |
| owner `H` replaced in a loop while a view is refreshed | the replacement ends the old view; the fresh view is live on the backedge; the stale one is rejected at use |
| tokenizer storing `Str` in tokens while `src` grows | rejected (rule 3) unless `src: Text.pinned` |
| compiled `get_line buf` returning a `Str` of `buf` | contract names one origin; held again in the caller |
| `call f (Ref xs) (xs:all())` where `f` may grow its first argument | rejected at the call |
| trap while building a new value for a global | the global's header was not yet written: old value intact; the new partial storage leaks |
| task waits inside a compiled word | context switch; frames stay on the task stack |

## 8. What stays and what goes

| Kept | Removed |
|---|---|
| owner rules, `copy`, results in the caller's place, exact conditional moves | regions, region custody, fragments, detachment, Homes |
| the lifetime rule, liveness-based checking, no lifetime syntax | positions, stable/shared-position guarantees, compaction cuts |
| `Store`/`Id` generations, map semantics | recovery domains, operation records, PREPARE/READY/COMMIT/RETIRE |
| container algorithms in Nua; a few C mechanisms | holdings, endpoints, loan subjects, epochs as compiler facts |
| native task stacks, dispatch, seeded service, foreign extents | the typed-frame step function for source waits; wait modes |
| plain in-process trap recovery | reclamation of a trapped entry's storage |

## 9. Acceptance obligations

The replacement's first milestone ([compiler activities §9](compiler-activities.md#9-acceptance-and-implementation-boundary))
carries these checks, each with a positive partner:

1. Every row of §7, through real Nua source, inline and compiled.
2. Rules 1–3 for each container, top level and nested, known and unknown index.
3. Linearity: conditional moves, partial moves of struct fields, swaps, returns of
   owners chosen by a branch, owners in sum payloads.
4. Release order and completeness against an independent allocation ledger (every
   allocation freed exactly once, nothing freed twice), including recursion.
5. Trap recovery: globals and caller storage valid after traps at every buffer
   operation of a test program; a leak is reported, not a corruption.
6. Pinned buffers: stored borrows across growth, the reserved limit trap.
7. Tasks: waits and budget switches in compiled words, seeded replay, foreign extents
   refusing waiting callbacks.
8. C and JIT agreement against independent expected values.
