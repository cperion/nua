# Replacement compiler: data, vocabularies and activities

This document **selects the internal architecture to implement**. The field lists,
closed alternatives, vocabulary entries, ownership boundaries and completion rules
below are contracts, not placeholders for a later inventory. Implementation may
change a contract through an explicit design revision, not by hiding extra state
in a builder or treating an unspecified case as a language restriction.

[Syntax](../syntax.md) owns language/ABI semantics. [Buffers](buffers.md) owns the
memory model; this document carries its compiler data and operations.
[Tasks](tasks.md) owns native task stacks and scheduling.
[Architecture](../architecture.md) describes the current implementation separately.
This specification does not claim replacement code or executable acceptance exists.

## 1. The composition we are building

```text
Mua parser + nua.front
    hosted Word / Application / Body
              |
              v
    evaluating invocation                 same handlers for known and unknown
       |       |       |
    branches  loops  shared definitions
       \       |       /
         one Program graph
              |
     checking + budget insertion          same evaluator, same Program kinds
              |
       preparing + verifying
              |
       +------+------+
       C             libgccjit
```

There is no Nua source AST beside Mua's AST, no separate source interpreter,
no ownership program beside the program graph, and no evaluator fallback.
An ordinary saturated application enters an invocation; only a requested native
boundary enters the definition registry. Container and scheduler algorithms are
Nua words. Compiler Lua/Mua constructs types, evaluates operations and proves
contracts; C/assembly supplies platform mechanisms.

### 1.1 Modules and their exported vocabularies

The replacement lives in `next/`, written in Mua and **self-contained**: it requires nothing
from the current compiler in `nua/`, which stays runnable until the cutover and is then
deleted. Module names resolve under `next/` (`nua.compiler.data` is
`next/nua/compiler/data.mua`); `make test-next` runs `next/tests/` on upstream LuaJIT. Rows
marked *built* exist with tests; the others are implementation targets.

| Module | Exports | May depend on |
|---|---|---|
| `nua/shapes.mua` *built* | `list_of`, `map_of`, `set_of`, `names`, `Natural`, `Positive` | Mua |
| `nua/identity.mua` *built* | The identity brands of §1.2, `supply`, `describe` | `shapes` |
| `nua/types.mua` *built* | The native-type family, interned constructors, `describe`, `owns`, `borrows`, `layout` | `shapes` |
| `nua/compiler/data.mua` *built* | The records of §2–§3, from `values`, `places`, `program`, `contracts`; `operand_key` | `shapes`, `identity`, `types` |
| `nua/compiler/rules.mua` *built* | `check_types`, `fold`, constant constructors: the native rules of §3.2 | `types`, `data` |
| `nua/compiler/graph.mua` *built* | `building`, `seal`, `index`, `walk`, `rewrite`, `Unchanged`, `same`, `print` | `data` |
| `nua/compiler/facts.mua` *built* | `fork`, `empty`, `tracking` (`borrow`, `use`, `cache`, `store`, `moves`, `ends`, `move_owner`, `agree`, `join_borrows`, `overlap`) | `data` |
| `nua/compiler/verify.mua` *built* | `shape`, `graph`, `types`, `all` | `data`, `graph`, `rules` |
| `nua/compiler/verify_lifetimes.mua` *built* | `lifetimes` | `data`, `graph`, `facts`, `verify` |
| `nua/compiler/evaluate.mua` *built (scalars, records, control, calls)* | `evaluating`: the vocabulary of §5.2, with branches and loops (§6.1, §6.2) | `data`, `graph`, `facts`, `rules`; supplied definition capability and Nua word bindings |
| `nua/compiler/control.mua` | `branching`, `looping`, `complete_exits` | `data`, `graph`, `facts`; supplied evaluation capability |
| `nua/compiler/definitions.mua` *built (specialization, recursion, tail loops; contracts not yet)* | `defining`, `request`, `define_export` | `data`, `graph`, `facts`; supplied evaluation capability |
| `nua/compiler/budgets.mua` | `budgets` | `data`, `graph`; supplied evaluation and the scheduler's budget word |
| `nua/compiler/optimize.mua` | `fold`, `reach`, `sweep`, `optimize` | `data`, `graph`, `facts`, `rules`, `verify` |
| `nua/compiler/diagnostics.mua` | `reporting`, `render` | `data`; supplied source text |
| `nua/compiler/hosting.mua` *built* | `word`, `supply`, applications (§5.1) | `types` |
| `nua/compile.mua` *built* | `compile`, `compile_c` | Wires the preceding vocabularies and backend adapters |
| `nua/front.mua` *built* | The Mua host emitting hosted bodies (§5) | Mua parser/emitter; supplied hosting vocabulary |
| `nua/emit_c.mua` *built (scalars)*, JIT adapter | `emit prepared target -> BackendProduct` | Ready program, native layouts and mechanism bindings |

`compile` wires the mutually cooperating activities by passing functions; their
modules do not recursively `require` one another or consult a global current
compiler. The compilation root owns the scoped use of Lua's module machinery.
Native types are `nua/types.mua`'s; there is no second type system.

### 1.2 Contract notation and representation choices

The following listings are **interface notation**, not executable Mua listings.
`List T` is a dense ordered list; `Map K V` has only checked K/V entries; `Set T`
is a checked set; `Option T = absent | present(T)`. Missing and known `false`/`nil`
are different. Function arrows give curried application order. A final `Body`
argument is the trailing callback of an activity.

- Program nodes, identity brands and facts crossing activity boundaries are
  nominal checked records. Closed node alternatives are `family` kinds.
- Operation vocabularies and private working state are structural `define` tables.
  No nominal `Context`, universal `Activity`, or generic transaction framework.
- Outcome protocols with different payloads are `oneof`s. Each activity below
  names its own outcome; errors are not an extra success variant.
- Published records/lists/maps are read-only by ownership convention, enforced by
  tests and construction APIs. Mua `struct` alone does not make them immutable.
- IDs are separate nominal brands with `{ compilation: CompilationId, serial: U64 }`.
  The brands are `WordId`, `EnvironmentId`, `DefinitionId`, `BlockId`, `EdgeId`,
  `InstructionId`, `ValueId`, `PlaceId`, `BorrowId`, `LifetimeId`,
  `InvocationId`, `AttemptId`, `LoopId`, `BoundaryId`, `GlobalId`,
  `OriginId`, `HostId`. `CompilationId` is a fresh opaque identity. IDs are not
  source locations, payload addresses or allocation-site numbers.

## 2. The values that evaluation works with

### 2.1 Source, words and supply

```text
Span             { source: String, line: Positive, column: Option Positive }
Origin           { span: Span, expanded_from: Option OriginId,
                   introduced_by: Option WordId }
Diagnostic       { rule: String, primary: OriginId, message: String,
                   related: List RelatedLocation }
RelatedLocation  { origin: OriginId, message: String }

Requirement      { name: String, native_type: Option NativeType, opened: Bool }
Word             { id: WordId, name: String, requirements: List Requirement,
                   rest: Option String, result_type: NativeType,
                   environment: EnvironmentId, body: HostedBody, origin: OriginId }
Application      { word: WordId, supplied: List Argument }
Argument         = HostArgument { identity: HostId, value: Any }
                 | NativeArgument { value: NativeValue }
                 | WordArgument { application: Application }
                 | PackArgument { arguments: List Argument }
Environment      { id: EnvironmentId, parent: Option EnvironmentId,
                   bindings: Map String Binding }
Binding          = HostBinding { identity: HostId, value: Any }
                 | ValueBinding { value: NativeValue }
                 | PlaceBinding { place: PlaceId }
                 | WordBinding { application: Application }
                 | PackBinding { arguments: List Argument }
```

A requirement without `native_type` requires host/known supply. A native
requirement converts/checks its supplied argument against that native type. `rest`
collects an ordered argument pack under the existing source rules. Requirements
and native result types are evaluated when the word is constructed, not on every
invocation. `Application` is immutable supply, not a partially executed body.

`NativeType` is a `nua.types` descriptor. `Any` occurs only in explicitly host-owned
bindings; those bindings cannot be inserted into the native graph. Opaque Lua
closures remain Lua closures. Their identities and origins can be inspected;
the compiler does not serialize their arbitrary upvalues.

### 2.2 Native values and observations

```text
NativeValue = Bits       { type: NativeType, operand: Operand }
            | Aggregate  { type: NativeType, packed: Option Operand,
                           parts: Map ComponentPath NativeValue }
            | Reference  { type: NativeType, borrow: BorrowId }
            | Owned      { type: NativeType, header: Operand }

ComponentPath = List Component
Component     = Field(name: String) | Element(index: Operand) | Alternative(name: String)

Operand = Constant       { type: NativeType, bits: NativeConstant }
        | Parameter      { definition: DefinitionId, index: Positive, type: NativeType }
        | BlockArgument  { block: BlockId, index: Positive, type: NativeType }
        | Result         { value: ValueId, type: NativeType }
```

`NativeConstant` has the closed forms `IntegerBits(bytes)`, `FloatBits(bytes)`,
`BooleanBit(value)`, `UnitBits`, `AggregateBits(parts)`, `StaticBytes(bytes)`,
`SymbolAddress(name, offset)` and `DefinitionAddress(definition)`. Bytes use a
canonical byte order; the associated native type checks width, layout and legal
interpretation. This is not “any Lua number”. `Bits` excludes references and
owning types: their facts cannot be omitted by selecting a convenient constructor.

A `Reference` names its borrow; the borrow's facts (§2.4) say whether it is held
(a path, with a cached pointer or none yet) or stored (a fixed pointer operand).
Constructing `Ref` does not by itself force a pending scalar store or produce a
pointer. An `Owned` value is the operand holding its header bits; ownership of it is
linear in the graph (§2.4), not a separate identity.

An aggregate can have known parts and a residual packed representation. Every
missing part must be recoverable from `packed`; otherwise construction fails.
Owning/borrowed components retain their facts when packed. Dynamic sum alternatives
are accessed only under their active-tag proof. Fixed arrays use element paths;
buffer lengths are runtime data, not a compiler list of every element.

A read returns an observation now. Later place mutation cannot turn its `operand`
into a recipe that rereads the place. A borrowed observation still requires its
borrow to be live.

### 2.3 Places, contents and access

```text
Place            { id: PlaceId, type: NativeType, root: PlaceRoot,
                   path: ComponentPath, lifetime: LifetimeId, origin: OriginId }
PlaceRoot        = LocalRoot(invocation: InvocationId, local: Positive)
                 | GlobalRoot(global: GlobalId)
                 | ParameterRoot(definition: DefinitionId, parameter: Positive)
                 | IndirectRoot(pointer: Operand, borrow: BorrowId)
                 | ForeignRoot(pointer: Operand, contract: ForeignAccess)

Contents         = Uninitialized
                 | Tracked(value: NativeValue)
                 | Resident(info: ValueInfo)
                 | Moved(at: OriginId)

Access           { place: PlaceId, path: AccessPath }
AccessPath       = List AccessStep
AccessStep       = FieldStep(name: String) | KnownElement(index: U64)
                 | AnyElement | AlternativeStep(name: String) | Contents
ForeignAccess    { lifetime: LifetimeId, type: NativeType, mutable: Bool,
                   retains: Bool, effects: ForeignEffects }
```

`Contents` as an access step names a buffer's elements, as distinct from its header.
Unknown-index aliasing is conservative: `AnyElement` overlaps every element.
Local/global place IDs persist across content replacement. Field-place identities are
interned by root and path. `LocalRoot.invocation` is an identity namespace, not a
pointer to a retained `InvocationWork` record. An indirect access uses its borrow's
facts; it never silently substitutes the destination of a prior owner move. An element
place needs the dominating bounds/active-tag checks recorded in `ValueInfo.proofs`
(§3). Raw pointers use their existing unsafe contract.

### 2.4 Borrows and owner linearity

These are the compiler facts of the [buffer model](buffers.md#33-compiler-facts):

```text
BorrowPath   { root: PlaceId, steps: AccessPath, range: Option Range }
Range        { first: Operand, count: Operand }
BorrowInfo   { id: BorrowId, form: BorrowForm, origins: List Access,
               mutable: Bool, lifetime: LifetimeId, acquired: OriginId }
BorrowForm   = Held(path: BorrowPath)
             | Stored(pointer: Operand)
BorrowState  = Live(pointer: Option Operand) | Ended(at: OriginId, reason: EndReason)
EndReason    = Grew | Shrank | Removed | Cleared | Replaced | Moved | Released
```

A **held** borrow is a path. On each path of control its `Live` state may cache the
derived native pointer, dropped by a `Moves` on the borrow's storage; the next use derives it again from the current
headers. A **stored** borrow is a fixed pointer: it was written into data, passed to a
compiled word or to foreign code. `origins` lists every buffer the borrow may point
into; after a join it is the union of the incoming origins. `lifetime` is the
shortest owner lifetime among the origins, checked by the lifetime rule (syntax §9.5).

| Event | Held borrow overlapping it | Stored borrow overlapping it |
|---|---|---|
| `Moves access` | `Live` without its cached pointer | `Ended(Grew)` |
| `Ends access reason` | `Ended(reason)` | `Ended(reason)` |
| owner moved out of, replaced in or released from a place | `Ended(Moved / Replaced / Released)` | same |

Using an `Ended` borrow is a diagnostic naming the event and the use.

**Owners are linear values.** An `Owned` operand must be consumed exactly once on every
path: moved into a place, passed to an owning parameter, returned, or released. A
named owner place has `Contents` `Tracked`, `Resident` or `Moved`. A conditional move
releases the owner on the edges that did not move it, before the join, so places agree
at every join; no drop flag exists at runtime. There are no holding identities,
endpoints, custody records, loan subjects or epochs: SSA values and block arguments
already say which header went where.

Releasing is a typed walk generated from the native type (owning contents, then the
owner's buffers), evaluated as ordinary Nua words.

## 3. The one program graph

### 3.1 Containers and control

```text
Program          { revision: U64, definitions: Map DefinitionId Definition,
                   words: Map WordId WordInfo,
                   globals: Map GlobalId Global, exports: List Export,
                   lifetimes: Map LifetimeId Lifetime, origins: Map OriginId Origin }
WordInfo         { id: WordId, name: String, requirements: List Requirement,
                   result_type: NativeType, origin: OriginId }
Definition       { id: DefinitionId, word: WordId, kind: DefinitionKind,
                   signature: Signature, entry: BlockId, blocks: List Block,
                   places: Map PlaceId Place, origin: OriginId }
DefinitionKind   = NativeWord | TaskEntryWord | BlockingEntry
Signature        { parameters: List NativeType, result: NativeType,
                   abi: NativeABI, variadic: Bool }
NativeABI        = NuaBoundary | CBoundary | TaskEntry
Global           { id: GlobalId, name: String, type: NativeType,
                   initializer: GlobalInitializer, policy: GlobalPolicy,
                   lifetime: LifetimeId, origin: OriginId }
GlobalPolicy     = PlainGlobal | ThreadLocalGlobal | AtomicGlobal
                 | UncheckedSharedGlobal | ThreadAffineOwner
GlobalInitializer = StaticValue(value: NativeConstant) | FirstUse(definition: DefinitionId)
Export           { name: String, definition: DefinitionId }
Block            { id: BlockId, arguments: List BlockArgument,
                   instructions: List Instruction, terminator: Terminator }
Edge             { id: EdgeId, target: BlockId, arguments: List Operand }
Site             { id: InstructionId, origin: OriginId }

Terminator = Jump       { origin: OriginId, edge: Edge }
           | Branch     { origin: OriginId, condition: Operand,
                          when_true: Edge, when_false: Edge }
           | Return     { origin: OriginId, value: Operand }
           | Trap       { origin: OriginId, message: Operand }
```

`WordInfo` retains source identity without retaining a hosted body or its builder.
A block has one terminator; its edge arguments are simultaneous. `Return` is an
actual native return after completion, not an inline body return. A source wait is
not a terminator: it is a call of the scheduler's Nua wait word, which switches
context and returns when the operation completes (§7.2). Any definition may contain
one; a blocking-job body may not (it runs outside the scheduler).

The Nua boundary ABI passes each owning result through one caller-provided result
slot of its fixed native layout, into which the callee writes the header(s).
Non-owning results use their native result convention. C-boundary signatures retain their restrictions on
owners; task entry has the trusted runtime ABI, not a signature-based guess.

### 3.2 Instruction family: complete top-level membership

Every row below includes the mandatory `site: Site` field. These are the complete
top-level instruction kinds; there is no `Other`, C template, or untyped payload.

| Kind | Remaining fields | Evaluation/effect contract |
|---|---|---|
| `Compute` | `result: ValueId, type: NativeType, opcode: NumericOpcode, arguments: List Operand` | Native typed computation; validity classified by opcode/type |
| `Pack` | `result: ValueId, type: NativeType, components: List Operand` | Representation assembly; transports existing facts, never duplicates an owner |
| `Extract` | `result: ValueId, type: NativeType, aggregate: Operand, path: ComponentPath` | Projection under required tag/index proofs; no new owning move |
| `Load` | `result: ValueId, place: PlaceId` | Ordered observation; result facts taken at this site |
| `Store` | `place: PlaceId, value: Operand` | Non-owning assignment only; preserves reference facts when materialized |
| `Address` | `result: ValueId, place: PlaceId` | Expose this place; establish pending contents before exposure |
| `Check` | `condition: Operand, message: Operand, claim: CheckClaim` | Fallthrough establishes claim; failure traps at this site |
| `Invoke` | `result: Option ValueId, callee: Callee, arguments: List Operand, boundary: BoundaryId` | Complete ordered argument captures, callee effects and caller completion |
| `Atomic` | `result: Option ValueId, opcode: AtomicOpcode, address: Operand, arguments: List Operand, order: MemoryOrder, failure_order: Option MemoryOrder` | Atomic read/write/RMW with native legality checks |
| `Fence` | `order: MemoryOrder` | Atomic ordering; not a pure unused computation |
| `LifetimeStart` | `lifetime: LifetimeId` | Begin the declared logical lifetime |
| `LifetimeEnd` | `lifetime: LifetimeId` | End its borrows after source completion and owner release |
| `Moves` | `target: Access` | Declared effect of a library word: the buffers at `target` may relocate (§2.4) |
| `Ends` | `target: Access, reason: EndReason` | Declared effect of a library word: borrows of `target` end (§2.4) |
| `Budget` | `reason: BudgetReason` | Permitted native scheduling point; ordered control/memory effect |
| `Mechanism` | `result: Option ValueId, binding: String, arguments: List Operand` | A declared platform mechanism, never an opaque Nua algorithm |

```text
NumericOpcode = Add | Subtract | Multiply | Divide | Remainder | Negate
              | BitAnd | BitOr | BitXor | BitNot | ShiftLeft
              | ShiftRightSigned | ShiftRightUnsigned
              | Equal | NotEqual | Less | LessEqual
              | Convert | Reinterpret | PointerOffset | PointerDifference
AtomicOpcode  = Read | Write | Exchange | CompareExchange
              | FetchAdd | FetchSubtract | FetchAnd | FetchOr | FetchXor
MemoryOrder   = Relaxed | Consume | Acquire | Release | AcquireRelease | Sequential
BudgetReason  = LoopEdge | RecursiveEdge
CheckClaim    = Bounds(place: PlaceId, index: Operand, length: Operand)
              | ActiveAlternative(value: Operand, name: String)
              | Condition(value: Operand)
Callee        = DirectNua(definition: DefinitionId)
              | IndirectNua(pointer: Operand, signature: Signature, provenance: NuaEntry)
              | Foreign(pointer: Operand, signature: Signature, contract: ForeignEffects)
NuaEntry      = DefinitionEntry(definition: DefinitionId)
              | RuntimeEntry(name: String)
```

Greater comparisons reverse already captured operands into `Less`/`LessEqual`;
this does not reverse source evaluation. Short circuit and selection are control,
not eager numeric opcodes. Type/arity/result rules belong in a closed opcode
vocabulary shared by evaluation, verification and emission. Adding an opcode
requires those rules, not merely a new string accepted by `Compute`.

`Mechanism.binding` must resolve in the target's checked mechanism vocabulary.
Each entry has `{ signature, effects, c_symbol, jit_symbol }`. The required storage/
context entries are `map_pages`, `unmap_pages`, `reserve_range`, `commit_range`,
`release_range`, `move_bytes`, `context_initialize`, `context_switch`,
`context_finish`, `recover_jump` and `fatal_trap`; `remap_pages` is optional. OS threading, TLS and I/O use separately declared platform bindings.
Unknown bindings fail construction. `context_switch` is explicitly switching,
not an opaque foreign call that would fence its own switch. Page mechanisms
return status; allocation policy, size classes and free lists stay Nua.

### 3.3 Buffer words and effect declarations

There are no storage requests. Buffer operations are ordinary Nua words of the
`buffers` library ([buffers §4](buffers.md#4-the-operations)), evaluated in place like
any word: their checks, stores and mechanism calls appear at their source point.
The compiler supplies two general primitives that any library word may use:

```text
moves access                       -> emits Moves, applies §2.4
ends access reason                 -> emits Ends, applies §2.4
initialize buffer index value      -> extends the checked initialized prefix
finish buffer first limit          -> shrinks it; ends the affected elements
```

`Grow`, `Text`, `Store`, `Map` and their `.pinned` variants are written over these
words. A pinned buffer's `reserve` declares no `moves`. A container may refine `ends`
by key or ID. The typed release walk of an owner type is generated from its schema:
owning fields, the active alternative of a sum, initialized ranges of buffers;
runtime lengths become native loops. References and IDs are not owning edges.

### 3.4 Fact products, not a second program

```text
ValueInfo       { type: NativeType, components: Map ComponentPath ComponentInfo,
                  proofs: Set Proof }
ComponentInfo   = Plain | Borrowed(borrow: BorrowId) | Owning
                | Callable(entry: Option NuaEntry)
Proof           = Checked(site: InstructionId) | Taken(edge: EdgeId)
                | Known(claim: CheckClaim)
FlowFacts       { contents: Map PlaceId Contents,
                  borrows: Map BorrowId BorrowState,
                  live_lifetimes: Set LifetimeId }
EdgeFacts       { edge: EdgeId, flow: FlowFacts, arguments: List ValueInfo }
JoinRelation    { block: BlockId, incoming: List EdgeFacts }
SiteFacts       { before: FlowFacts, after: FlowFacts, effects: Effects }
DefinitionFacts { values: Map Operand ValueInfo, borrows: Map BorrowId BorrowInfo,
                  entries: Map BlockId FlowFacts, edges: Map EdgeId EdgeFacts,
                  joins: Map BlockId JoinRelation, sites: Map InstructionId SiteFacts,
                  terminators: Map BlockId Effects }
Analysis        { revision: U64, definitions: Map DefinitionId DefinitionFacts,
                  contracts: Map DefinitionId BoundaryContract }
```

`Map Operand` uses canonical operand identity, not a deep Lua-table key comparison.
Facts are tied to `Program.revision`. A rewrite returns a new revision and the
analyses it has actually rebuilt; it cannot reuse a certificate for changed code.

Each `JoinRelation` row is keyed by the actual incoming edge and carries contents and
borrow states together. A borrow-typed block argument gets a new borrow whose origins
are the union of its incoming borrows' origins and whose state is `Ended` if any live
incoming edge ended it. Loops have finite facts at the header, not a row for every
runtime iteration.

`Analysis` has no executable control of its own. Ordered checking follows the
actual blocks, instructions and edges of `Program`. It does not execute an
ownership-only copy of that program.

### 3.5 Effects and native boundary contracts

```text
Effects          { reads: List Access, writes: List Access,
                   moves: List Access, ends: List Access, consumes: List Access,
                   may_trap: Bool, may_wait: Bool, may_switch: Bool,
                   foreign_extent: Bool, nonreturning: Bool }
ForeignEffects   { reads: List Access, writes: List Access, retains: List Access,
                   may_reenter: Bool, noreturn: Bool }
InterfaceOrigin  = Incoming(parameter: Positive, path: AccessPath)
                 | GlobalOrigin(global: GlobalId, path: AccessPath)
InterfacePart    = PlainPart
                 | BorrowPart(origins: List InterfaceOrigin, mutable: Bool)
                 | OwnerPart
InterfaceInfo    { type: NativeType, parts: Map ComponentPath InterfacePart }
AliasRequirement { moved: Access, stored: Access, at: InstructionId }
BoundaryContract { definition: DefinitionId, inputs: List InterfaceInfo,
                   returns: Map BlockId InterfaceInfo,
                   effects: Map InstructionId Effects,
                   terminators: Map BlockId Effects,
                   requires_disjoint: List AliasRequirement,
                   normal_exits: Set BlockId, revision: U64 }
```

`Effects` describes **one execution site**. The boundary contract retains the
instruction/terminator maps and the definition's actual CFG, including nonreturning
prefixes. A call substitutes parameter accesses with the actual argument origins, then
applies the callee's `moves`, `ends` and `consumes` to the caller's facts in order.
`requires_disjoint` records each `moves` of a parameter's buffer while a stored borrow
parameter may point into it; a call whose arguments alias such a pair is rejected.

A returned borrow's `origins` name incoming parameters or globals, never callee
locals (the lifetime rule). When they name exactly one buffer, the caller re-roots the
result as a held borrow: its path is that buffer and the offset of the returned
pointer from the buffer's current `data`. Otherwise the result is stored.

Contract projection replaces local IDs by incoming/global paths. A remaining
callee-local place or borrow in the outward interface is a verification error.

## 4. Private state and completion outcomes

These structural records are private to the named activity. They are not fields
on published program nodes. Their fields are listed so ownership is testable.

```text
CompilationWork { id: CompilationId, sources: Map String String,
                  origins: Map OriginId Origin, words: Map WordId Word,
                  environments: Map EnvironmentId Environment,
                  globals: Map GlobalId Global, exports: List Export,
                  lifetimes: Map LifetimeId Lifetime,
                  definitions: DefinitionRegistry, diagnostics: List Diagnostic,
                  next_identity: U64, target: Target,
                  loader_scope: LoaderScope, bridge: HostBridge }
Draft           { attempt: AttemptId, parent: Option AttemptId,
                  definition: Option DefinitionId, blocks: Map BlockId BlockDraft,
                  places: Map PlaceId Place, values: Map Operand ValueInfo,
                  lifetimes: Map LifetimeId Lifetime,
                  borrows: Map BorrowId BorrowInfo, exits: List ExitSite,
                  requests: Set DefinitionId, state: DraftState }
DraftState      = Open | Adopted | Discarded
BlockDraft      { id: BlockId, arguments: List BlockArgument,
                  instructions: List Instruction, terminator: Option Terminator }
Path            { attempt: AttemptId, block: Option BlockId,
                  environment: EnvironmentId, lifetime: LifetimeId, facts: FlowFacts }
InvocationWork  { id: InvocationId, word: WordId, draft: Draft,
                  entry: Path, locals: List PlaceId, exits: List ExitSite,
                  result_type: NativeType, mode: EvaluationMode }
EvaluationMode  = HostOnly | Residual
ExitSite        { kind: ExitKind, path: Path, capture: Capture, origin: OriginId }
ExitKind        = InvocationReturn(target: InvocationId)
                | LoopBreak(target: LoopId) | LoopNext(target: LoopId)
Capture         { value: NativeValue }
CapturePurpose  = Observation | ArgumentCapture | ReturnCapture
Lifetime        { id: LifetimeId, parent: Option LifetimeId,
                  kind: LifetimeKind, completion: List CompletionAction }
LifetimeKind    = GlobalLife | InvocationLife | LexicalLife | TaskScopeLife | ForeignViewLife
CompletionAction = ReleaseLocal(place: PlaceId) | JoinScope(operation: Operand)
                 | FinishForeign(operation: Operand)
```

`LoaderScope` is the restoration handle owned by `nua.loader.with_context`:
`{ loaded, public_loaded, loaders, path, preload, cpath }`, holding the saved Lua
registry/package values. It is not another module cache. The compilation driver
restores it on success and failure; it does not promise concurrent compilation.

A `Capture` contains the value already observed, never a callback that rereads
it. An owning capture is the header operand; the place it came from is `Moved`.
Source capture, activity completion and writing the result header are three distinct
steps. `Observation` adds no owning move. An owning argument is moved before the next
argument is evaluated.

### 4.1 Outcomes returned by the drivers

```text
BodyResult       = FellThrough(path: Path) | Returned(exit: ExitSite) | Terminated
CallbackResult   = CallbackValue(path: Path, value: Argument)
                 | CallbackVoid(path: Path) | CallbackTerminated
InvocationResult = ReturnedValue(path: Path, value: NativeValue) | NoContinuation
BranchResult     = Joined(path: Path) | NoContinuation
LoopResult       = Exited(path: Path) | NoContinuation
HeaderAgreement  = Holds | Weaken(changes: List HeaderChange)
HeaderChange     = ForgetContents(place: PlaceId)
                 | Materialize(place: PlaceId)
                 | WidenOrigins(borrow: BorrowId, origins: List Access)
DefinitionResult = Complete(definition: Definition, contract: BoundaryContract)
                 | Awaiting(group: Set DefinitionId)
CompileResult    = Compiled(product: CompilationProduct)
                | Refused(problems: List Diagnostic)
CompilationProduct { program: Program, analysis: Analysis,
                     backend: BackendProduct, inspection: Inspection }
```

`NoContinuation` is not Unit and not an unknown native value. Body completion
must handle each outcome before returning to its parent. A branch with no normal
continuation may still have registered returns to its enclosing invocation. That
invocation completes its recorded return sites before deciding whether *it* has
`NoContinuation`. `return_value` registers an exit once; `Returned` carries the
same exit, not a second contribution. Source diagnostics and genuine Lua errors leave through the responsible protected activity; neither is
reported as successful `FellThrough`.

Nonlocal reconsideration retains the existing targeted-request approach, with an
explicit internal payload:

```text
ConstructionRequest { target: AttemptId, reason: Reconsideration }
Reconsideration = GeneralizeHeader(loop: LoopId, changes: List HeaderChange)
                | MaterializeCall(invocation: InvocationId)
                | ReviseContract(definition: DefinitionId)
```

Only the target's driver consumes it. Intermediate drivers finish/discard their
own drafts and restore their bindings, then propagate the same request. It is
never an operand or a host iterator result. This is compiler control, not a new
source exception mechanism or an eight-retry failure policy.

### 4.2 State owned at each boundary

| Activity | Creates and owns | Receives/borrows | Completion |
|---|---|---|---|
| `compiling` | `CompilationWork`, loading scope, diagnostic list | Source entries, target, backend | Return product or refusals; restore loader/bridge; product owns retained JIT resources |
| `building` | `Draft`, fresh block buffers | Identity supplier, parent destination | Adopt once or discard once; reject later writes; definition completion seals blocks |
| `evaluating` | `InvocationWork`, local lifetimes, evaluation vocabulary | Entry `Path`, word, supply, definition requests | Complete exits and release local owners; return value/path or no continuation |
| `branching` | Two child drafts and predecessor facts | Captured condition and entry facts | Adopt both valid residual arms; reconcile only continuing edges |
| `looping` | `LoopWork` (§6), round draft, header agreement | Entry path, carried places, hosted condition/body | Keep accepted known prefix; revise only rejected round/body; finish exits |
| `defining` | Definition drafts and recursive agreement group | Word/specialization request | Publish group only after contracts close; discard caller-local contributions |
| `budgets` | New output with budget points | Closed program, its call graph | Return the rewritten program; facts rebuilt for changed definitions |
| `rewriting` | New output, evolving analysis state | Read-only input and explicit shared capabilities | Return replacement graph/facts; never mutate inspected input |
| `emitting` | Names, declarations, backend handles | Verified ready program and target | Return backend product; close nonretained resources |

`facts.fork` copies the two `FlowFacts` maps and the live-lifetime set; their entries
are immutable records. A later write replaces an entry rather than changing a
shared borrow record. Name environments extend by fallback. These are two different operations.

### 4.3 Graph building vocabulary

```text
building parent identities -> (GraphWriter -> BuildDecision) -> BuildResult
BuildDecision = Adopt | Discard
BuildResult   = Built(fragment: GraphFragment) | Discarded
GraphWriter = {
    block        : String -> List NativeType -> BlockId,
    parameter    : BlockId -> Positive -> BlockArgument,
    declare      : Place -> Unit,
    lifetime     : Lifetime -> Unit,
    append       : BlockId -> Instruction -> Unit,
    terminate    : BlockId -> Terminator -> Unit,
    remember     : Operand -> ValueInfo -> Unit,
    borrow       : BorrowInfo -> Unit,
    exit         : ExitSite -> Unit,
    require      : DefinitionId -> Unit
}
GraphFragment { entry: Option BlockId, blocks: Map BlockId BlockDraft,
                places: Map PlaceId Place,
                lifetimes: Map LifetimeId Lifetime,
                values: Map Operand ValueInfo, borrows: Map BorrowId BorrowInfo,
                exits: List ExitSite, requests: Set DefinitionId }
```

A fragment is a **private construction product**, not a completed Program. Its
exit tails may still be open. Adoption transfers those block buffers and creates
parent-owned Path handles; only that parent writer can continue them. Definition
completion constructs immutable `Block` records after all tails are terminated.

Each child invocation/control construction writes fresh blocks. Adoption links its
entry and continuation with edges; a cleanup rewrite merges redundant blocks.
It does not append into a buffer captured by its parent. A wholly known HostOnly
invocation has no native blocks. `append` after a terminator, wrong-attempt handles,
undeclared operand facts and a second adoption/discard are construction errors.

Adoption transfers the fragment to the parent draft and makes its old writer
unusable. It is still tentative under that parent. On parent failure, all adopted
children's graph/fact/request contributions disappear with the parent. Globally
fresh identity serials need not be rolled back; their unused gaps carry no meaning.

### 4.4 Fact and graph operations

```text
Facts = {
    fork        : FlowFacts -> FlowFacts,
    agree       : List EdgeFacts -> BlockId -> JoinDecision,
    substitute  : InterfaceInfo -> List NativeValue -> ValueInfo,
    borrow      : FlowFacts -> BorrowPath -> Bool -> OriginId -> BorrowInfo,
    use         : FlowFacts -> BorrowId -> OriginId -> BorrowUse,
    store       : FlowFacts -> BorrowId -> Operand -> Unit,
    moves       : FlowFacts -> Access -> Site -> Unit,
    ends        : FlowFacts -> Access -> EndReason -> Site -> Unit,
    move_owner  : FlowFacts -> PlaceId -> Site -> Operand
}
Graph = {
    building    : Option AttemptId -> IdentitySupply -> (GraphWriter -> BuildDecision)
                  -> BuildResult,
    index       : Program -> GraphIndex,
    walk        : VisitPass -> Program -> Unit,
    rewrite     : RewritePass -> Program -> Program,
    same        : Program -> Program -> Bool,
    print       : Program -> String
}
IdentitySupply  { fresh: String -> BrandedIdentity }
GraphIndex      { definitions: Map DefinitionId Definition,
                  blocks: Map BlockId Block, sites: Map InstructionId Instruction,
                  predecessors: Map BlockId (List EdgeId), edges: Map EdgeId Edge,
                  definitions_of: Map Operand (Option InstructionId) }
```

`IdentitySupply.fresh` accepts only the ID brand names in §1.2. `VisitPass` and
`RewritePass` are checked family passes; rewriting each definition owns fresh block
output. Constants and formal/block parameters have no defining instruction, hence
`definitions_of` uses `Option`; their own kind records establish their definition.

```text
BorrowUse = Derive(path: BorrowPath) | Cached(pointer: Operand) | Fixed(pointer: Operand)
```

`borrow` records a new held borrow. `use` checks that a borrow is live and says how
to obtain its pointer: derive it from the current headers, reuse the cached pointer,
or use the stored one; it is a diagnostic for an ended borrow. `store` turns a held
borrow into a stored one with its materialized pointer. `moves` and `ends` apply the
table of §2.4 to every overlapping borrow. `move_owner` marks a place `Moved`, ends
the borrows of its contents and returns its header operand. Pointer transport alone is
not a use. `agree` and `substitute` return data; their enclosing activity performs any
required stores or releases. None of these functions allocates native storage during
compilation.

`Graph.same` compares kinds, native constant bits and ID-consistent graph structure,
with an explicit bijection for fresh local IDs. It preserves global/word/type
identity and sharing; it is not arbitrary recursive table equality. `Graph.print`
uses stable role-based names from traversal order, not Lua addresses.

## 5. The hosted-body and evaluation vocabulary

### 5.1 The bridge from Mua

```text
HostedBody : Evaluation -> Path -> List Argument -> BodyResult
HostedCallbackBody : Evaluation -> Path -> List Argument -> CallbackResult
ConditionBody : Evaluation -> Path -> List Argument -> ConditionResult
ConditionResult = Tested(path: Path, condition: NativeValue) | ConditionTerminated
HostCallback is an ordinary Lua callable wrapping HostedCallbackBody and its environment.
Hosting = {
    word       : Word -> Application,
    supply     : Application -> List Argument -> Application,
    apply      : Path -> Application -> InvocationResult,
    callback   : EnvironmentId -> HostedCallbackBody -> HostCallback,
    export     : String -> Application -> Unit
}
```

Mua's parser hands `nua.front` the actual typed/opened nodes. The host emits a Lua
closure with this body contract, preserving lexical captures. The closure calls
the evaluation vocabulary; it is not translated back into a second syntax tree.
The frontend sequences callee/receiver and operand evaluation in separate ordered
steps. It captures each supplied argument under its receiving requirement before
evaluating the next; partial applications retain that captured supply. Installing
an already captured argument at invocation entry is not another source move. Known branch selection invokes only the selected delayed body.

`Hosting.supply` never runs the body. `Hosting.apply` requires saturation, then
enters `evaluating`; source partial application uses `supply`. Native and host
callbacks retain their existing source return conventions through the adapter.
The adapter unwraps ordinary successful native values for existing Lua hooks; it
must propagate termination/reconsideration, never hand those outcomes to a hook
as if they were source values.

For Lua metamethods/hooks that need an ambient entry, the **compilation-owned**
`HostBridge` is the only bridge to it:

```text
BridgeSignal = Reconsider(request: ConstructionRequest)
             | NativeTerminated(target: AttemptId)
HostBridge { bindings: List BridgeBinding, pending: Option BridgeSignal,
             live: Bool }
BridgeBinding { attempt: AttemptId, evaluation: Evaluation, path: Path,
                invocation: InvocationId }
bridge.enter binding body -> body's ordinary result
bridge.current() -> BridgeBinding
bridge.raise signal -> does not return
```

`enter` pushes, runs protected work, pops on every exit, then returns or propagates.
A NativeTerminated signal stops the owning path/arm, not unrelated branch
construction. It is needed only when an ordinary Lua hook cannot return the
explicit NoContinuation outcome. Genuine Lua errors are never relabeled as signals.
Generated body operations pass their `Path` explicitly; semantic modules never
consult a process-global `current`. A staged host wrapper retains its compilation's
bridge, not a private draft output buffer. A closed bridge or stale attempt fails
before any staging operation. The existing Lua loading/generator contract is
retained; request propagation through supported hook/protected/generator boundaries
is an acceptance test, not permission to ban them. Opening a vocabulary does not
perform this push/pop or resource cleanup implicitly.

### 5.2 Evaluation: exact entries

`evaluating` creates these verbs once for one compilation: they capture what belongs to the
whole activity (identity supply, origins, the place and borrow registries, diagnostics, native
rules, definition capability). Everything that varies within it is on the path, an argument of
every verb: a mutable handle holding the writer and block code goes to, the flow facts, the
invocation, the innermost loop and the source line. A join replaces a path's state; a branch arm
or loop round gets a path of its own. Nothing consults a current path.

```text
evaluating : Word -> List Argument -> Path -> EvaluationServices -> InvocationResult
EvaluationServices {
    writer: GraphWriter,
    identities: IdentitySupply,
    report: Diagnostic -> Unit,
    get_word: WordId -> Word,
    get_environment: EnvironmentId -> Environment,
    add_environment: Environment -> EnvironmentId,
    native_rules: NativeRules,
    request_definition: AttemptId -> Application -> List ValueInfo
                        -> NativeABI -> DefinitionId,
    branching: Path -> NativeValue -> HostedBody -> HostedBody -> BranchResult,
    looping: Path -> List PlaceId -> ConditionBody -> HostedBody -> LoopResult,
    mode: EvaluationMode
}
NativeRules {
    result_type: NumericOpcode -> List NativeType -> NativeType,
    fold: NumericOpcode -> List NativeType -> List NativeConstant -> FoldingDecision,
    effects: NumericOpcode -> List NativeType -> Effects
}
FoldingDecision = Folded(value: NativeConstant) | NotFoldable | Invalid(reason: String)
Evaluation = {
    literal       : NativeType -> NativeConstant -> NativeValue,
    lookup        : Path -> String -> Argument,
    bind          : Path -> String -> Binding -> Path,
    declare       : Path -> String -> NativeType -> Option NativeValue -> PlaceId,
    read          : Path -> PlaceId -> NativeValue,
    write         : Path -> PlaceId -> NativeValue -> Unit,
    compute       : Path -> NumericOpcode -> List NativeValue -> NativeValue,
    field         : Path -> PlaceId -> String -> PlaceId,
    element       : Path -> PlaceId -> NativeValue -> PlaceId,
    address       : Path -> PlaceId -> NativeValue,
    borrow        : Path -> PlaceId -> AccessPath -> Option Range -> NativeValue,
    capture       : Path -> CapturePurpose -> NativeValue -> Capture,
    move_owner    : Path -> PlaceId -> NativeValue,
    copy          : Path -> PlaceId -> PlaceId -> Unit,
    release       : Path -> PlaceId -> Unit,
    moves         : Path -> Access -> Unit,
    ends          : Path -> Access -> EndReason -> Unit,
    apply         : Path -> Application -> List Argument -> InvocationResult,
    call          : Path -> Application -> List Argument -> InvocationResult,
    foreign       : Path -> Callee -> List NativeValue -> InvocationResult,
    branch        : Path -> NativeValue -> HostedBody -> HostedBody -> BranchResult,
    loop          : Path -> List PlaceId -> ConditionBody -> HostedBody -> LoopResult,
    return_value  : Path -> InvocationId -> NativeValue -> BodyResult,
    return_argument : Path -> Argument -> CallbackResult,
    break_loop    : Path -> LoopId -> BodyResult,
    next_loop     : Path -> LoopId -> BodyResult,
    trap          : Path -> NativeValue -> BodyResult,
    atomic        : Path -> AtomicOpcode -> NativeValue -> List NativeValue
                   -> MemoryOrder -> Option MemoryOrder -> Option NativeValue,
    fence         : Path -> MemoryOrder -> Unit,
    mechanism     : Path -> String -> List NativeValue -> Option NativeValue
}
```

All handlers validate path ownership/liveness first. `read` of a named owner in
value context is `move_owner`; borrowing contexts use `borrow`/`address`, never a
header-copy escape. `write` of an owner into a place releases the place's old value,
if live, then stores the new header: an owner-typed `Store` is a transfer, and the
lifetimes verifier counts it as the value's one transfer on that path. `release`
evaluates the owner type's release walk. `moves`/`ends` are the effect declarations
of §3.3. Spawning and waiting are Nua words over `mechanism` (§7.2).

| Verb | Known case | Residual case | Facts changed |
|---|---|---|---|
| `compute` | Native rule computes exact result if valid | Emit `Compute`; return `Bits(Result)` | None beyond result/proof registration |
| `read` | Return valid tracked observation | Emit `Load` and register its complete `ValueInfo` | Observation/owner capture as appropriate |
| `write` | Replace tracked contents; keep pending store lazy | Emit required store at observation/exposure boundary | Contents and borrow facts |
| `address` | Preserve the exact source place | Flush pending contents before `Address` | Exposure and loss of invalid private knowledge |
| `branch` | Execute selected body | Build isolated arms and a join | Edge-correlated flow facts |
| `move_owner` | Still requires the runtime header | Return the header operand; no instruction | Source `Moved`; borrows of its contents ended |
| `borrow` | Record a held path; no instruction | Same; pointer derived at first use | New live borrow |
| `call` | HostOnly follows in-place source rule | Request definition; emit `Invoke` even for a known result with effects | Ordered substituted boundary effects |
| `trap` | Source/host diagnostic when native execution is unavailable | Terminate path with `Trap` | No continuation; no dummy result |

The handler's returned value is not its whole effect. A known result cannot erase
an invocation, allocation, check, atomic operation or completion that must execute.
Buffer and container words use these same handlers; there is no second evaluator for
storage.
`Evaluation.apply` receives saturated supply; the frontend uses `Hosting.supply`
until then. Untyped callbacks can return host values, words and packs through
`CallbackResult`; they are not forced into a native result type. A typed body's
fallthrough is Unit only when its declared result permits Unit.

## 6. Control and native-definition construction

### 6.1 Branches: the actual join algorithm

```text
branching entry condition -> when_true -> when_false -> BranchResult
facts.agree predecessors -> destination -> JoinDecision
JoinDecision { arguments: List NativeType, incoming: List EdgeFacts,
               flow: FlowFacts, stores: List EdgeStore }
EdgeStore { edge: EdgeId, place: PlaceId, value: Operand }
```

1. Capture the condition before entering either arm. Known Bool chooses one body.
2. For a residual condition, make two writers and `facts.fork entry.facts` twice.
   Both share identity/type capabilities, not mutable contents maps or output.
3. Collect normal continuation paths separately from return/break/next/trap exits.
   Only the normal paths participate in this join; a terminated arm contributes no
   invented initialization or value.
4. For each live place, keep equal tracked native contents. For unequal values
   of one native type, create a block argument and supply its edge-specific value.
   A place exposed to memory gets its required edge stores before the jump.
5. For owner components, each incoming edge supplies its header operand; an owner
   moved on one edge only is released on the other edges before they enter the join.
   For borrow components, create a joined borrow per block argument: union of
   origins, `Ended` if any live incoming edge ended it, no cached pointer unless all
   edges agree. Record the whole incoming rows in one `JoinRelation`.
6. Establish missing-initialization/moved facts conservatively: another edge's
   initialized/live state is not permission to read. Check future observations
   against every feasible incoming row.
7. Adopt arm fragments, terminate their live tails with the constructed edges,
   and return the joined `Path`. No live predecessor returns `NoContinuation`.

`facts.agree` decides from captured facts; it does not emit stores or evaluate
source. `branching` owns establishment of that decision, including edge stores,
borrow states and owner releases, and rejects the whole construction if establishment fails.

### 6.2 Loops: entry, header, body, continuing edges, exits

```text
LoopWork { id: LoopId, attempt: AttemptId, entry: Path,
           carried: List PlaceId, header: BlockId,
           assumptions: FlowFacts, accepted_prefix: List GraphFragment,
           body: Option Draft, continuing: List ExitSite, exits: List ExitSite }
looping entry carried condition body -> LoopResult
check_header assumptions continuing -> HeaderAgreement
```

The driver is this sequence, not a generic retry framework:

1. Start with the actual carried places and entry observations. Known rounds run
   in the same evaluator. Keep a round only when it satisfies the source known-round
   rule; preserve already accepted rounds when a later round generalizes.
2. Allocate one residual header with block arguments for dynamic carried contents.
   Local IDs remain the original source places; aliases never point to round copies.
3. Evaluate the condition and body in a child draft under the header assumptions.
   Gather `LoopNext(this loop)` separately from breaks, returns and inner-loop edges.
4. Check every continuing edge. Equal restored contents can preserve an assumption;
   merely discovering a write/participant does not force a retry. Join borrow states
   over the entry and continuing edges as in §6.1: a borrow refreshed in the body is
   live on the backedge, a stale one carries its `Ended` state into the header.
5. On `Weaken`, discard that child draft and its contributions, update only the
   named assumptions, and reconstruct that body. Known scalar agreement weakens to
   a typed dynamic value on disagreement; it does not accumulate all encountered
   constants. Borrow information weakens by widening origins and dropping cached
   pointers, never by a physical root-count limit.
6. On `Holds`, establish simultaneous edge captures/stores, add the required budget
   point on each residual cycling edge, and seal the backedges. Complete exiting
   paths at their own continuations. Exit-only changes do not alter the next header.

The analysis domain contains native types, finite source/parameter component paths,
known-or-dynamic contents, initialization/move states, and live/ended borrows with
their origins. Unknown array indices use `AnyElement`; runtime cohort sizes are not
enumerated. Each header weakening removes an assumption. Known host unfolding can still fail to
terminate; that does not justify a placement-based rejection of a residual program.

### 6.3 Definition requests, captures and recursive agreement

```text
DefinitionKey   { word: WordId, supply: List SpecializationInput,
                  captures: List CaptureRequirement, abi: NativeABI }
SpecializationInput = KnownNative(type: NativeType, bits: NativeConstant)
                    | DynamicNative(info: InterfaceInfo)
                    | KnownHost(identity: HostId)
                    | KnownWord(application: Application)
CaptureRequirement { environment: EnvironmentId, name: String,
                     type: NativeType, mode: CaptureMode }
CaptureMode     = ByValue | ByPlace
DefinitionEntry { id: DefinitionId, key: DefinitionKey, state: DefinitionState,
                  clients: Set AttemptId, dependencies: Set DefinitionId,
                  host_dependencies: List HostDependency, reusable: Bool }
DefinitionState = Requested | Building(attempt: AttemptId)
                | AwaitingAgreement
                | Complete(definition: Definition, contract: BoundaryContract)
DefinitionRegistry { entries: Map DefinitionId DefinitionEntry,
                     keys: Map DefinitionKey (List DefinitionId), worklist: List DefinitionId }
HostDependency  = BindingRead(environment: EnvironmentId, name: String, value: Argument)
                | RawTableRead(table: HostId, key: Argument, value: Argument)

request requester application argument_info abi -> DefinitionId
require_capture definition binding mode -> Parameter
agree_group definitions -> List DefinitionResult
```

The key contains no caller-local place, allocation address or concrete borrow
identity. `InterfaceInfo` carries the borrow origins of the arguments. A
capture of a native value becomes a value parameter; a capture of a native place
becomes a Ref parameter to that same place. Capture order is stable first discovery
order after explicit parameters. Calls fill those parameters from their own path,
never from a cached caller operand. C function-pointer materialization retains its
existing closure restrictions; hidden captures do not change a declared C signature.

A completed specialization is reusable only while its observed host dependencies
still match. Validation uses compiler bindings/raw table reads, not user getters or
callbacks. Encountering an opaque host observation that cannot be validated sets
`reusable = false`: that completed definition is not reused for a later request.
Active recursive references still resolve to the group's provisional definition
under the stage-safe-body contract. This is a deliberately conservative definition
cache policy, not result memoization or a second evaluator. It does not mutate or
rematerialize an already-created native function value. Host effects are never
rerun just to test a cache key.

The definition driver:

1. Register the requested identity before evaluating its body. Recursive calls
   reference that identity, not a depth-specific definition.
2. Evaluate with fresh formal native parameters, stored borrows relative to them
   and the same evaluation vocabulary. Discover captures and dependencies in owned
   draft state. No outward contract is published yet.
3. Build the reachable call graph and its strongly connected components. Insert
   `RecursiveEdge` budgets after argument capture on intra-cycle calls before
   final effect agreement. For each group, project return origins and site effects
   to interface paths; propagate requirements across call edges until agreement.
   Pending native definitions conservatively retain possible switching effects.
   Nonreturning prefixes remain reachable even when the group has no normal return.
4. If new capture, move or invalidation facts invalidate a dependent construction,
   target that unfinished owner's attempt. Rebuild its owned output and facts
   together. A completed scalar prefix/sibling is not discarded without dependency.
5. Publish the group only when interfaces, call arities, lifetime constraints and
   ordered alias requirements agree. There is no “sixteen retries, reject valid
   placement” completion path. No finite-placement analysis participates here.
6. Remove failed clients' requests; collect only definitions reachable from accepted
   exports/tasks. Retained definitions contain formals, not rejected caller operands.

### 6.4 Completion ordering at a return

`return_value` captures first and records `ExitSite`; `complete_exits` performs:

```text
capture observed value
    -> run remaining source activity completion in lexical order
    -> write the result header into the receiver's place (owners) or return it
    -> release remaining local owners in reverse declaration order
    -> end the local lifetimes; check that no returned borrow names a local
    -> continue caller, or emit native Return
```

For a compiled word the receiver is the caller's result slot, which exists before the
callee's frame disappears. Releasing a local owner evaluates its typed release walk at
that point; a frozen source cannot move early, and a legal capture cannot be delayed
past a mutation that would change its value. Inline completion has no native ABI
return.

## 7. Storage, tasks and backend readiness

### 7.1 No storage realization

Storage needs no late phase. Buffer words are evaluated where their source operation
occurs (§3.3); owner release is evaluated by scope completion, conditional-move edges,
replacement and returns (§6.1, §6.4). The graph that leaves evaluation contains only
the instruction kinds of §3.2, all of them ready for the optimizer and the backends.

Storage consistency at a trap comes from the order every buffer word follows: build the
new storage completely, write the header, then release what it replaced. A header write
is a `Store` that cannot trap; moving an owner writes headers only. The verifier checks
that no `Check`, `Invoke` or `Mechanism` that may trap sits between the header writes of
one owner move. No recovery record or publication region exists.

### 7.2 Tasks: native stacks and context switches

A task runs on its own nonmoving native stack ([tasks](tasks.md),
[buffers §2.6](buffers.md#26-tasks-and-waits)). Spawning, waiting and
budget service are ordinary Nua words of the scheduler library:

- `spawn` captures values in order, takes a stack (a pinned reservation of bytes with
  a guard page) and a context through mechanisms, moves the captured owners into the
  start record and publishes the child.
- A **source wait** registers its operation and switches context. A **budget point**
  switches context. Both keep the actual native frames, including words compiled on
  their own; resuming returns to the native continuation. The resumed wait reads the
  completed result from its operation record.
- Every residual Nua cycle has budget coverage (§7.3). Opaque foreign extents defer
  service; a word whose effects include `may_wait` cannot become a C callback.

There is no typed frame, step function, wait state or wait mode. `TaskEntry` is the
trusted runtime ABI of a task's entry definition. Both C and JIT emit the same graph;
the context platform port, guard/probe rules and fatal task trap policy are not
replaceable by an OS-thread fallback.

### 7.3 Preparation order and invalidation

```text
prepare program analysis -> Prepared
Prepared { program: Program, analysis: Analysis, certificate: ReadyCertificate }
ReadyCertificate { revision: U64, definitions: Set DefinitionId }
```

The selected driver order is:

1. Close reachable native-definition groups and verify semantic graph/contracts.
2. Run optional folding, reachability and dead pure-result elimination on this graph.
3. Add/verify budget coverage for the resulting loop and native-call cycles, then
   recompute affected graph/alias/effect/lifetime facts, including switching effects.
   A newly discovered semantic effect that invalidates construction targets its
   owning attempt; it is not ignored because an optimizer already ran.
4. Verify backend readiness and produce `ReadyCertificate` for exactly this revision.

The optional optimizer has eight rounds, stopping earlier on graph-aware equality.
Every round must preserve a valid program. Mandatory agreement has no
“publish at cap” path. A structural change after step 4 invalidates the certificate.
No backend accepts a bare `Program` without a matching certificate.

`task_access` propagates parameter/global/callback origins across the reachable
call graph, including blocking entries and known Nua function pointers passed to
opaque code. `Global.policy` implements the existing atomic/TLS/unchecked-shared
exceptions and owner-global task prohibition. A native context switch does not
make an ordinary global write safe. Foreign hidden state retains its explicit
foreign contract; the checker does not claim to inspect arbitrary C.

| Verifier | Checks |
|---|---|
| `shape` | Nominal kinds, exact fields, dense lists, registered native types/opcodes/bindings |
| `graph` | Unique identities, complete targets, one terminator, edge arity, SSA dominance |
| `types` | Operand/result/native ABI rules against `rules`; place, component, callee and return types; initialized/tag/index proofs |
| `lifetimes` | Borrow uses against `Moves`/`Ends` in order and across joins; an owner value transferred at most once on every path (a store, owning argument, return, edge argument or pack); lifetime starts/ends; no trapping site between the header writes of one owner move. That every owner is released exactly once is checked at runtime against an allocation ledger |
| `task_access` | Reachable task/blocking/callback accesses; global policy, pointer origins and sendability; no `may_wait` callee as a C callback |
| `ready` | All preceding checks; closed definition graph; budget coverage; target mechanisms available |

`LifetimeStart`, `LifetimeEnd`, `Moves` and `Ends` remain checked zero-machine-code
events, not unresolved physical work. A materialized reference still needs its
separate address/packed operand. `Budget` and `Mechanism` are executable effects. Backend adapters cannot
classify these kinds together as ignorable bookkeeping.

### 7.4 Pass vocabulary membership

All family handlers have `(node, recurse, ...)`. These are the selected operations:

| Pass | Primary result | State/effects |
|---|---|---|
| `print` | String | Identity naming map; no mutation of program |
| `operands` | List Operand | None; exact uses of every instruction kind |
| `effects` | Effects | Native opcode/binding/contract tables |
| `verify_instruction` | Unit | Accumulate diagnostics under current graph/facts |
| `fold` | List Instruction | Evolving native-value facts; own replacement output |
| `reach` | Reachability map | Worklist over actual CFG, not a forward-label flag |
| `sweep` | List Instruction | Liveness and effect/validity facts; own output |
| `emit_c` | Unit | C emitter's declarations, labels and text buffer |
| `emit_jit` | Unit | JIT emitter's handle maps and resource owner |

`fold`/`sweep` spread an enumerated identity vocabulary. Their default **preserves**
a known kind; no pass accepts an unknown kind. Checkers/effect classifiers and
emitters list every kind deliberately. A stateful variant is made by invoking its
factory again, not by copying handlers that still capture the first output.

### 7.5 Compilation root and backend products

```text
SourceEntry      { filename: String, source: String }
ByteOrder        = LittleEndian | BigEndian
NativeLayout     { size: U64, alignment: U64, fields: List LayoutField }
LayoutField      { path: ComponentPath, type: NativeType, offset: U64 }
MechanismBinding { signature: Signature, effects: Effects,
                   c_symbol: String, jit_symbol: String }
StackContract    { alignment: U64, page_bytes: U64, red_zone_bytes: U64,
                   frame_probes: Bool, context_port: String }
Target           { name: String, pointer_bits: U32, byte_order: ByteOrder,
                   layout: NativeType -> NativeLayout,
                   mechanisms: Map String MechanismBinding,
                   stack: StackContract }
BackendRequest   = CText | ObjectFile(path: String) | Executable
BackendProduct   = WrittenC(text: String, map: List SourceMapEntry)
                 | WrittenObject(path: String, map: List SourceMapEntry)
                 | LoadedCode(exports: Map String NativeFunction, release: Function)
NativeFunction   { signature: Signature, address: HostNativeAddress }
SourceMapEntry   { definition: DefinitionId, generated: String, origin: OriginId }
Inspection       { programs: List Program, analyses: List Analysis,
                   decisions: List Explanation }
Explanation      { operation: String, origin: OriginId, detail: String }

compiling entries target backend_request -> CompileResult
emit prepared target backend_request -> BackendProduct
reporting sources -> Reporting
Reporting = {
    report : Diagnostic -> Unit,
    finish : Unit -> List Diagnostic
}
```

`HostNativeAddress` is the backend's host FFI address value, not a source operand.
`LoadedCode.release` owns the retained JIT result/code resources; returning from
emission cannot free them. File/compiler/probe resources that are not retained
finish in the emission activity on success or failure. C output and JIT handle
construction consume the same prepared graph. C operand evaluation is sequenced
by statements, never delegated to unspecified C argument evaluation order.

The root creates identity, reporting, bridge and definition-registry instances,
installs the Nua source loader, and binds `Hosting` to `evaluating`. It supplies
`request` to evaluation and the evaluation function back to the definition, control
and budget activities. Hosting collects the actual export requests. The root
closes those requests, calls `prepare`, calls the selected backend adapter, restores
its loading/bridge scopes, and returns `CompilationProduct`. It does not publish
partial output when a child construction was refused.

Reporting keeps source-order independent diagnostics and their related locations.
It never executes an unselected body or supplies a dummy native value to continue
an invalid construction. Host error decoration preserves the original cause;
internal graph failures, source refusals and native runtime traps are distinct.

## 8. Worked construction using these contracts

### 8.1 Supply and one evaluator

```lua
local affine = do(scale: U32, bias: U32, x: U32): U32 = scale * x + bias
local transform = affine 4 3
```

| Source action | Selected interface and result |
|---|---|
| `affine 4 3` | `Hosting.supply` returns `Application`; no invocation/body/output |
| `transform 5` | `evaluating` uses `compute Multiply` and `compute Add`; exact known U32 23 |
| `transform x` with runtime x | Same verbs emit two `Compute` instructions; no native call |
| `call transform x` | `request` creates/reuses a scale=4,bias=3 definition; caller emits `Invoke` |

### 8.2 Owners, observations and current contents

The first source situation selects an ordering of two independent owners A/B. A
header alias must not follow a moved owner; an earlier scalar observation must not
change. It is an architectural trace, not a test-run report.

```text
entry facts:
    A -> Tracked(Owned(type=T, header=%a)); B -> Tracked(Owned(type=T, header=%b))

body:
    %before = Load A.count
    %alias  = Address A                       -- a borrow of A's header
    Branch %choice -> choose_a(), choose_b()

choose_a:
    move A (A: Moved); move B (B: Moved)
    Jump join(%a, %b)

choose_b:
    move B (B: Moved); move A (A: Moved)
    Jump join(%b, %a)

join(%left, %right):
    each Owned block argument is consumed exactly once below
    ... use/release left; observe right; release right ...
```

The alias to A still names A's place, now `Moved`; using it through the header is
rejected. The count observation still means `%before`, not a fresh read through
`%alias`. Moving A and B ended the borrows of their contents. No holding identity or
join relation is needed: the block arguments carry the headers, and linearity checks
that each is consumed once.

For replacement of a live owner H inside a loop, with a view of its contents:

```text
header(%view):
    use %view                                  -- borrow v (Held, origins H.contents)
    %next = build replacement                  -- a new owner
    replace H with %next                       -- releases old H; v: Ended(Replaced)
    %view2 = view H 0 n                        -- borrow v2, Live
    Budget LoopEdge
    Jump header(%view2)
```

At the header, the entry edge supplies a live view and the backedge supplies v2, live:
the header borrow is live. Passing `%view` on the backedge instead supplies an ended
borrow; its use at the top of the next round is rejected. A growth of H instead of a
replacement would only drop v's cached pointer: the view survives and is derived again.

## 9. Acceptance and implementation boundary

The first replacement milestone must connect actual Mua hosting, these evaluation
interfaces, owner linearity and borrow facts, control agreement, buffer words in Nua
and one backend product. A scalar-only evaluator or a family declaration
library is not that milestone. Task/platform implementation follows the same selected
interfaces; it is not grounds to weaken the architectural contract meanwhile.

The concrete acceptance set is:

1. Load every family/pass with contracts enabled; reject missing handlers, unknown
   fields, sparse node lists and malformed graph/owner/borrow facts.
2. Host real Nua source for partial/known/mixed supply, earlier observations, branch
   correlation, partial moves, current-header replacement and refreshed/stale loops.
3. Repeat and nest factories; reject stale writers; accept child then reject parent;
   verify independent prior output and surviving prefix/sibling state are unchanged.
4. Exercise definition capture, argument/fresh results, recursive forwarding and
   combination, ordered aliased kill/use, and nonreturning call prefixes.
5. Account every allocation against an independent ledger (freed exactly once,
   never twice), including recursion, conditional moves and replacement; after traps
   at every buffer word, globals and caller storage are valid (leaks reported).
6. Verify waits and budget switches inside compiled words, a single executing
   continuation, foreign fencing, cleanup-before-DONE and seeded service rounds.
7. Compare known results, unoptimized/optimized prepared execution and C/JIT against
   independent expected values/effect/resource traces. Agreement between shared
   handlers/backends alone is not an independent oracle.

Positive partners must accompany refusals: refreshed versus stale borrow; a held
borrow surviving growth versus a stored one ending; a pinned buffer's stored borrow
surviving growth; valid large/late target cohorts versus an actual lifetime violation. An optimizer limit may reduce
optimization, not accepted source coverage or correctness.

The method is Mua's [compiler guide](https://github.com/cperion/mua/blob/b93e36fa75c9d23cc1e68c70bdb5834e8c17b476/docs/writing-compilers.md):
name the data, list the operations, give each activity its state and completion.
The concrete Nua contracts above are this design's choices, not the toy compiler's.

**No replacement implementation, dependency change or native test run accompanies
this specification.** The design now names its data and operations; implementation
and independent acceptance still have to establish that those contracts hold.
