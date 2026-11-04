# Audit: owners inside owners (memory.md §5.9–§5.11, milestone 5)

Written 2026-11-03. This audits the *proposed* design of nested owners against the rest of
[memory.md](memory.md) and against the implementation as it stands after milestone 4. It
changes no design text: §5.9 and §5.10 are still "(proposed)" and §14 still says "None". The
corrections it asks for are listed in §6 for approval, not applied.

**Resolved 2026-11-03.** The findings were folded into one model instead of nine separate
decisions: owner *positions* (memory.md §5.9 R1–R5, §5.10, decision D13). N1–N9 and C1–C6
below are superseded by that text; they are kept as the record of why.

Method: every holder crossed with every role (the §5.11 table, owner column), then every
operation on a holder crossed with what it does to nested contents, the stack count, borrows
and release. Each finding says what the proposal claims, what breaks or is missing, and what
is recommended.

## 1. What the proposal claims

1. One **arena stack per nesting level** holds the contents of owners that sit in elements;
   each element holds a header (where its contents begin, length, capacity). The stack count
   stays static because the nesting depth is part of the type.
2. A nested owner whose contents end at the arena top extends in place; otherwise its
   contents move to the top with doubled capacity.
3. Growing a nested owner ends borrows of *that* owner's contents; unknown indices end
   borrows of every element's contents of the holder.
4. Space abandoned by moving, and the contents of removed elements, return on clear, on the
   end of the outer owner, or on an explicit `compact()`.
5. A `oneof` with an owner payload needs one stack and no arena: replacing the variant resets
   the stack to its base.
6. `copy` is deep. Owners may be globals, each with its own reserved region.

## 2. The mechanism that falls out

Everything below follows from one reading of claim 2, so it is stated first.

> **Every owner has the same header: stack, base, length, capacity. A stack may host several
> owners. Growth extends in place iff the owner's capacity ends at the stack's top, and
> otherwise relocates the contents to the top with doubled capacity.**

A top-level owner always satisfies "ends at the top" (its stack is its own), so it never
relocates and keeps today's behavior and cost (one comparison). A nested owner is the same
word with the other branch taken. This matters for three reasons:

- A word over `Ref Text` must work whether the `Text` is a local or an element of a
  `Grow Text`. One header layout makes that one word, specialized as today.
- Today's header is `{ stack, base, len }` (`nua_grow`) and `extend` traps when an owner
  "grew while it was not at the top of its data stack". Relocation replaces that trap, so
  the change is local: `extend` and its callers in `lib/storage.nua` and `lib/map.nua`,
  which are Nua words. Callers must write back the base `extend` returns.
- The arena is just a stack used by many owners. Creating a nested owner is the existing
  `init` of its type with the arena as its stack; filling it from a source is the existing
  `copy`. No second mechanism exists.

Header cost: `Grow` and `Text` headers grow by one word (capacity). Nested headers also
carry the arena's stack index, so a `Ref` to an element is self-sufficient (see F2).

## 3. Findings

**F1. A move between nesting levels is a copy, which contradicts §5.4.** §5.4 says "Nothing
is copied. The storage stays where it is; the destination takes over." That holds for a
move between two top-level places: the header is copied and the stack travels with it. It
cannot hold for `lines:push(text)` with a named top-level `text` at its last use, because
`text`'s bytes live on `text`'s own stack and the element's contents must live in the
holder's arena. The same goes for `pop`, `take` or a result leaving a nested position: the
bytes go from the arena to the destination's stack. Cost: O(length), once, and the source
is released (or its arena bytes become dead).
*Building in place avoids it*: `lines:push(read_line f)` already places the callee's result
in the new element (§5.3), as does `Text` being written into the element. So the copy
appears only for a named owner moved across levels.
→ **Decision N1.**

**F2. A reference to a nested owner needs the arena.** An element's header alone cannot
resolve its bytes unless the header names its stack. `Ref lines[i]` passed as a `Ref Text`
parameter must be usable for reading and growth with no other context. Fat references
(place plus arena) would double the size of every `Ref` and change calls; storing the stack
index in each header costs one word per owner. → part of **N2**.

**F3. The arena needs bookkeeping on the *holder*, which the proposal omits.** Compaction
and "dead bytes" accounting need, per arena: stack, base, length and dead bytes.
`Map(Str, V)` already has exactly this (`arena_stack`, `arena_base`, `arena_len`, `dead`),
so the layout is proved. A `Store Player` with two nested fields has two such records.

**F4. Memory is not bounded under churn unless compaction is automatic.** The proposal's
reclamation is clear, end of the outer owner, or an explicit `compact()`. `Store` and `Map`
promise bounded memory under churn because removed slots are reused; for nested contents a
long-lived `Store` of players with names would leak every removed name until the program
ends. `Map(Str, V)` solves this with automatic compaction when dead bytes reach half the
arena. Growth abandonment alone is bounded by doubling (about 2× live); removal is not.
→ **Decision N3.** Recommended shape: compaction runs **only inside operations that already
end borrows** (`remove`, `pop`, `truncate`, `clear`, replacing an element's owner), never
in `push` or growth. That bounds memory and adds no invalidation to growth.

**F5. Growth ends borrows even when it does not move.** The compiler cannot know at compile
time whether a growth relocates, so claim 3 must be static: any growth of a nested owner
ends borrows of its contents. A top-level owner, by contrast, never invalidates on growth
(§6.3). So `local s = names[0]:str(); names[0]:write "x"; use s` is rejected although it
would run correctly if the owner happened to be at the top. This is the price of the
design, and the cost is user-visible. Alternatives considered: a runtime generation check
(violates "no checks that facts could remove" and adds state), or chunked storage with no
moves (turns every element access into two loads). Recommended: accept, and make the
diagnostic name the growth ("`names[0]:write` may move the contents of `names`").
→ **Decision N4.**

**F6. Recursive owner types have no static stack count.** `Json = oneof { array: Grow Json,
object: Map(Str, Json) }` or `Node = struct { children: Grow Node }` have unbounded nesting
depth, so claim 1 ("depth is part of the type") fails. Today types cannot be recursive
except through `Ref`/`Id`, so this is new ground. Two options:
(a) **Reject recursive owner types** and say why; trees go through `Id` into a `Store`, as
§6.4 already recommends for long-lived relationships;
(b) **One arena per strongly connected component of the owner-type graph**: all levels of
`Json` share one arena, compaction walks the live tree recursively (a Nua word recursing
over data). The stack count stays static, so this is sound.
Recommended: (a) for milestone 5 with a diagnostic that names (b)'s idea, and keep (b) as
the extension. → **Decision N5.**

**F7. The `oneof` claim is true only for a top-level `oneof`.** "Replacing the variant resets
that stack to its base" holds for a local `oneof`. A `oneof` that is an *element* of a
container has its payload in the holder's arena, with other elements' contents beside it,
so replacing the variant abandons the payload (dead bytes) like a removal. Also the stack
count of a `oneof` is the **maximum** over its alternatives (alternatives share stacks), not
one. → correction C3, **Decision N7**.

**F8. Arrays of owners must share an arena.** `Array(Text, n)` and `Bounded(Text, n)` hold
`n` headers inline and `n` is not bounded (it may be 1000), so one stack per element is
impossible. All elements share one arena per array and use the same relocate-or-extend
growth. struct fields remain the one case where each owner gets its own stack, because the
field count is small and static. → **Decision N6.**

**F9. Arenas are per owner position, not per nesting level.** The proposal's own examples
contradict "one arena per nesting level": `Store Player` with `name: Text` and `items:
Grow Item` has 3 stacks (slots, names' arena, items' arena), which is two arenas at *one*
level. The rule that gives its numbers is: **one stack per owner leaf in the type's owner
tree**: `Map(Str, Text)` = slots, index, key arena, value arena (4); `Grow (Grow (Grow
U8))` = 3. `Mem.stack_count` already counts leaves for structs and uses each owner type's
`stacks` declaration, so this extends the `owner_type` declaration (`stacks` becomes a
function of the type).

**F10. Moving out of an element is already rejected, correctly.** D6 rejects moving out
through a `Ref` whose target is a field, an element or a runtime-chosen place, so `local t =
lines[i]` cannot move. The remaining ways to take a nested owner out are `copy lines[i]`
and `pop`/`take`, which F1 covers. Assigning `lines[i] = x` with a named owner `x` is the
same cross-level transfer (copy once); `lines[i] = lines[j]` is rejected like any move out
of an element, and `lines[i] = copy lines[j]` is the spelling. Elements being overwritten
abandon their old contents (dead bytes).

**F11. Copying an owner header is aliasing.** `Slice.mut T` of owner elements, or any
generic word that does `items[i] = value` for `T` an owner, would copy a header and leave
two owners sharing contents. The library words in `lib/storage.nua` write elements with a
plain store, which is correct only because elements are values. For owner elements, the
store of an owner value into an element place must be *adopt* (create the element's nested
owners in the arena, then `copy`). This is the one missing primitive: **an owner-aware
store into an element place**, made by the compiler from the element type's owner leaves,
the way `copy` is today. It is not a feature-specific subsystem: it is `copy`'s destination
being an element.

**F12. Compaction is a generic Nua word over the type's owner tree.** It walks the holder's
live elements (slot order for `Store`/`Map`, index order for `Grow`/`Array`, the active
alternative of a `oneof`), moves their nested contents above the arena, then back down, and
updates headers. Nested depth k needs the walk of level k−1 to find the headers, which
live in arena k−1. `Map(Str, V)` implements the single-level case; the multi-level case is
the same word applied per level, specialized at compile time. It belongs in
`lib/storage.nua`, not in the compiler.

**F13. `clear`, `pop`, `truncate`, `remove` need nested-aware effects.** `clear` resets the
slots stack and every arena: O(1). `truncate n` and `pop` cannot reset an arena because
surviving elements' contents are interleaved: they add the removed elements' capacities to
the dead count (O(removed) walk) and may compact (F4). `Store:remove` does the same for one
element. Each already ends borrows (`retire`); the new part is the dead accounting.

**F14. Owner globals (§5.10) are under-specified and unsafe as written.** "Each owner
global gets its own reserved region" is not a slot of a thread's or task's stack set: a
global is process-wide and reachable from every thread. As written, the main thread could
grow a global while a task reads it, which is the race the whole task model excludes
("a task owns its memory", D1's freeze applies only to the spawner's own owners). Options:
(a) **tasks may not touch owner globals** (read or write): simplest, consistent with
"tasks do not write ordinary globals" and "a task owns its memory"; (b) read-only inside
tasks with a freeze: the freeze would have to cover every owner global reachable from any
word called in the scope, which is not decidable cheaply. Recommended: (a); revisit only
when a program needs shared read-only tables (those are `Map.known` or static data today).
Globals live in their own reserved regions with the same header, released at exit, and
trap recovery does not release them. → **Decision N8.**

**F15. Borrows rooted at nested contents need two roots.** `Ref names[i][j]` (an element of
a nested owner) depends on the nested owner's contents, not on the holder's slots. The
token model ("roots are owners") needs a path-qualified root: the holder plus "contents of
element ?". This is what `retire(owner, selector?)` already carries (a key narrows which
borrows end), so no new primitive is needed: nested growth is `retire(holder, nested
contents)` and an unknown index is the selector "any". The summaries `fn.shrinks` and
`grow_sites` must record nested growth the same way (a word that grows `names[k]` through a
`Ref` argument shrinks that argument's nested contents).

**F16. Tasks and results behave.** Owners still never cross; D1's frozen borrow reaches
nested contents at any depth because the freeze is on the owner and read-only is
transitive (§8). D7 result stacks need one per owner leaf (F9). Moving a *holder* moves
its header and its stacks, with no per-element work. Recursion shares stack indices per
frame, so arenas stack like any other (a frame cannot grow an outer frame's nested owner
while it holds one above it: the existing summary rule applies unchanged).

## 4. The §5.11 owner column, cell by cell

| Holder | Verdict | Notes |
|---|---|---|
| typed local, parameter, result | yes | exists. Result stacks: one per owner leaf (F9, F16). |
| struct field | yes | each top-level owner leaf has its own stack; fields of an element struct become arena-based (F9). |
| `oneof` payload, as a local | yes | the stack is reset when the variant is replaced. |
| `oneof` payload, as an element | yes, with a correction | arena payload; replacing abandons it (F7). Stack count is the maximum over alternatives. |
| `Array(T, n)`, `Bounded(T, n)` element | yes | one shared arena per array (F8). |
| `Grow`, `Array T` element | yes | arena; header per element (F2). |
| `Store` element | yes | arena; `remove` abandons contents (F13); slot reuse starts with an empty header. |
| `Map` value | yes | arena; `put` on an existing key replaces and abandons the old contents; `ensure` creates empty. |
| `Map` key | no | unchanged. |
| global | yes, with a correction | main thread only (F14). |
| task crossing, spawn, message, pool slot | no | unchanged; `copy` of a holder cannot cross either. |
| a task's view of its spawner | read-only | frozen at any depth (F16). |

Operations on a holder with nested owners:

| Operation | Nested contents | Borrows ended | Cost |
|---|---|---|---|
| `push` of a fresh result | built in the new element | none | O(1) plus the build |
| `push` of a named owner at its last use | copied across levels, source released | none | O(n) once (N1) |
| growth of an element's nested owner | extends in place or relocates | that owner's contents (all elements' if the index is unknown) | amortized O(1), 2× slack |
| `pop` / `take` | copied out to the destination | the contents of the holder | O(n) once |
| `clear` | slots and every arena reset | everything of the holder | O(1) |
| `truncate`, `remove`, overwrite | dead bytes added, compaction when dead ≥ live | the contents of the holder (the element when keys are known to differ) | O(removed), amortized |
| `copy holder` | built compact in the new arenas | none | O(total) |
| `compact()` (explicit) | moves live contents down | the contents of the holder | O(live) |

## 5. Decisions requested

Recommendations first; each is a decision for you, not a default taken.

- **N1. Transfers between nesting levels copy once.** `push` of a named top-level owner,
  `pop`, `take`, and assigning a named owner into an element copy the contents across and
  release the source. Building in place (a call result, a `write` into the element) copies
  nothing. The alternative is to forbid these transfers and require `copy x` plus an
  explicit release; that makes every cost visible but turns a move into ceremony.
- **N2. One header for every owner:** stack, base, length, capacity; extend iff the
  capacity ends at the top, else relocate with doubled capacity. Top-level owners never
  relocate. Nested headers are self-sufficient (they name their arena).
- **N3. Compaction is automatic but only inside operations that already end borrows**
  (`remove`, `pop`, `truncate`, overwrite, `clear`), when dead bytes are at least the live
  bytes and at least 4096; `compact()` stays available for explicit use. Growth never
  compacts.
- **N4. Growth of a nested owner statically ends borrows of its contents,** all elements'
  contents of the holder when the index is unknown, with a diagnostic that names the growth.
  Top-level owners keep "growth invalidates nothing".
- **N5. Recursive owner types are rejected** in milestone 5, with a diagnostic pointing at
  `Id` into a `Store`; the shared-arena-per-recursive-component design is recorded as the
  extension.
- **N6. Arrays and `Bounded` of owners share one arena per array;** struct fields keep one
  stack each.
- **N7. A `oneof` stack count is the maximum over its alternatives;** an element `oneof` abandons
  its payload on replacement.
- **N8. Owner globals are the main thread's only;** tasks may not read or write them.
- **N9. Moving out of an element stays rejected;** the ways out are `copy`, `pop` and
  `take`.

## 6. Corrections to the design text, once N1–N9 are decided

These are for you to approve; none is applied.

- **C1 (§5.4).** "Nothing is copied" applies to moves between top-level places. A move across
  nesting levels copies the contents once (N1).
- **C2 (§5.9).** "One arena per nesting level" → one stack per owner leaf (F9); the header
  is stack, base, length, capacity (N2); the holder keeps arena bookkeeping (F3); compaction
  runs inside borrow-ending operations (N3); recursive owner types are rejected (N5);
  arrays share an arena (N6).
- **C3 (§5.9, `oneof`).** The "reset to base, no arena" sentence applies to a local `oneof`; an
  element `oneof` uses the arena (F7, N7).
- **C4 (§5.10).** Owner globals belong to the main thread; regions are process-wide, not
  slots of a thread's stack set (F14, N8).
- **C5 (§14).** "None" is wrong until N1–N9 are decided; list them.
- **C6 (§6.3).** The two "proposed" rows (nested growth, `compact()`) gain the selector
  detail of F15 and the cost note of N4.

## 7. Implementation outline (milestone 5, after the decisions)

1. **Uniform header and relocation.** Add capacity to the `Grow`/`Store`/`Map` headers and
   make `extend` relocate; update the growth effects (`grows`) and every word in
   `lib/storage.nua` and `lib/map.nua` that calls it. Top-level behavior and C output must
   not change (the listings and size checks are the guard).
2. **Type-directed stack counting.** `owner_type` declarations take `stacks` as a function
   of the type; `Mem.stack_count` and the result stacks follow the owner-leaf rule (F9).
3. **Owner-aware element store** (F11): creating, copying and overwriting an element
   builds its nested owners in the arena; `types.element` and `map_value` admit owners.
4. **Dead accounting and compaction** words for `Grow`, `Array T`, `Store`, `Map` (F12,
   F13), then `oneof`, `Array(T, n)` and `Bounded` payloads and elements.
5. **Borrow effects** for nested growth, removal and compaction (F15), with summaries.
6. **Owner globals** (F14), after the rest.

Tests the milestone owes: rejection cases for each borrow-ending row in §4; the existing
storage model fuzzer extended with nested owners (it compares against a model, which is the
right guard for relocation and compaction); a churn test that checks the arena stays
bounded; C-size checks that top-level code is unchanged.
