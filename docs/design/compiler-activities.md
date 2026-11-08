# Replacement compiler: data, vocabularies and activities

This document **selects the internal architecture to implement**. The field lists,
closed alternatives, vocabulary entries, ownership boundaries and completion rules
below are contracts, not placeholders for a later inventory. Implementation may
change a contract through an explicit design revision, not by hiding extra state
in a builder or treating an unspecified case as a language restriction.

[Syntax](../syntax.md) owns language/ABI semantics. [Region completion](region-completion.md)
owns the approved allocator, transfer, recovery and native-task architecture.
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
     checking + realizing Nua words       same evaluator, same Program kinds
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

These are the selected replacement module boundaries. Names under `nua/compiler/`
are implementation targets, not claims that those files already exist.

| Module | Exports | May depend on |
|---|---|---|
| `nua/compiler/data.mua` | Checked wire shapes below; identity/list/map checkers | Mua contracts; `nua.types` |
| `nua/compiler/graph.mua` | `building`, `rewrite`, `walk`, `index`, `same`, `print` | `data` |
| `nua/compiler/facts.mua` | `fork`, `agree`, `substitute`, `observe`, `invalidate`, `transfer`, `rebind`, `check_edge` | `data`; graph indices |
| `nua/compiler/evaluate.mua` | `evaluating`, `apply`, `invoke` | `data`, `graph`, `facts`; supplied definition/storage capabilities |
| `nua/compiler/control.mua` | `branching`, `looping`, `complete_exits` | `data`, `graph`, `facts`; supplied evaluation capability |
| `nua/compiler/definitions.mua` | `defining`, `request`, `agree_group` | `data`, `graph`, `facts`; supplied evaluation capability |
| `nua/compiler/realize.mua` | `realizing`, `storage`, `tasks`, `budgets` | `data`, `graph`; supplied evaluation and Nua word bindings |
| `nua/compiler/verify.mua` | `shape`, `graph`, `types`, `lifetimes`, `task_access`, `publication`, `ready` | `data`, `graph`, `facts` |
| `nua/compiler/optimize.mua` | `fold`, `reach`, `sweep`, `optimize` | `data`, `graph`, `facts`, `verify` |
| `nua/compiler/diagnostics.mua` | `reporting`, `render` | `data`; supplied source text |
| `nua/compiler/compile.mua` | `compiling`, `prepare` | Wires the preceding vocabularies and backend adapters |
| `nua/front.lua` | Existing Mua host, changed to the hosted-body contract in §5 | Mua AST/emitter; supplied hosting vocabulary |
| C/JIT adapters | `emit prepared target -> BackendProduct` | Ready program, native layouts and mechanism bindings |

`compile` wires the mutually cooperating activities by passing functions; their
modules do not recursively `require` one another or consult a global current
compiler. `nua.loader` still owns the scoped use of Lua's module machinery.
Native type construction remains in `nua.types`; this is not another type system.

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
  `InstructionId`, `ValueId`, `PlaceId`, `HoldingId`, `LoanId`, `LifetimeId`,
  `InvocationId`, `AttemptId`, `LoopId`, `BoundaryId`, `GlobalId`, `TaskId`,
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
            | Reference  { type: NativeType, representation: Option Operand,
                           access: ReferenceInfo }
            | Owned      { type: NativeType, header: Operand, holding: HoldingId,
                           endpoint: Endpoint }

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
interpretation. This is not “any Lua number”. `Bits` excludes safe references and
owning types: their facts cannot be omitted by selecting a convenient constructor.

A reference to an exact tracked place may have no materialized representation yet.
Reification produces its pointer or pointer/length representation only when needed;
constructing `Ref` does not by itself force a pending scalar store. An indirect
reference must have its captured native representation. An `Owned` use must match
both its holding and current endpoint; an old host wrapper cannot consume that
holding again after it has transferred elsewhere.

An aggregate can have known parts and a residual packed representation. Every
missing part must be recoverable from `packed`; otherwise construction fails.
Owning/borrowed components retain their facts when packed. Extracting a header
operand does not manufacture a second holding. Dynamic sum alternatives are
accessed only under their active-tag proof. Fixed arrays use element paths;
container payload lengths are runtime data, not a compiler list of every element.

A read returns an observation now. Later place mutation cannot turn its `operand`
into a recipe that rereads the place. Borrowed observations still require live loans.

### 2.3 Places, contents and access

```text
Place            { id: PlaceId, type: NativeType, root: PlaceRoot,
                   path: ComponentPath, lifetime: LifetimeId, origin: OriginId }
PlaceRoot        = LocalRoot(invocation: InvocationId, local: Positive)
                 | GlobalRoot(global: GlobalId)
                 | ParameterRoot(definition: DefinitionId, parameter: Positive)
                 | IndirectRoot(pointer: Operand, access: ReferenceInfo)
                 | ForeignRoot(pointer: Operand, contract: ForeignAccess)

Contents         = Uninitialized
                 | Tracked(value: NativeValue)
                 | Resident(info: ValueInfo)
                 | Moved(at: OriginId)

StorageGuarantee = Stable | SharedPosition
ReferenceInfo    { targets: TargetRelation, loans: List LoanId,
                   guarantee: StorageGuarantee, mutable: Bool }
TargetRelation   = Exact(place: PlaceId)
                 | Selected(join: BlockId, component: ComponentPath)
                 | Relative(parameter: Positive, path: AccessPath)
                 | BoundedUnknown(lifetime: LifetimeId, path: AccessPath)
AccessPath       = List AccessStep
AccessStep       = FieldStep(name: String) | KnownElement(index: U64)
                 | AnyElement | AlternativeStep(name: String)
ForeignAccess    { lifetime: LifetimeId, type: NativeType, mutable: Bool,
                   retains: Bool, effects: ForeignEffects }
```

Here `BoundedUnknown` means **lifetime-bounded**, not a bound on the number of
possible targets. It represents late-selected runtime targets without scanning
their collection or allocating one compiler root per element. Unknown-index
aliasing remains conservative. It does not weaken a proved stable guarantee.
The existing prohibition on owning moves through unknown Ref targets remains.

Local/global place IDs persist across content replacement. Field-place identities
are interned by root and path. `LocalRoot.invocation` is an identity namespace,
not a pointer to a retained `InvocationWork` record. An indirect access uses its captured pointer and
access facts; it never silently substitutes the destination of a prior source move.
An element place additionally needs the dominating bounds/active-tag checks recorded
in `ValueInfo.proofs` (§3). Unsafe raw pointers use their existing unsafe contract.

### 2.4 Holdings, loans and loop epochs

```text
Holding          { id: HoldingId, type: NativeType, endpoint: Endpoint,
                   header: Operand, guarantee: StorageGuarantee,
                   custody: Custody, lifetime: LifetimeId }
Endpoint         = InPlace(place: PlaceId) | InCapture(value: ValueId)
                 | InResult(boundary: BoundaryId) | InOperation(instruction: InstructionId)
Custody          = WholeRegion | Fragment(custodian: HoldingId, path: AccessPath)
                 | BorrowedCustody(parameter: Positive, path: AccessPath)

Loan             { id: LoanId, lender: LifetimeId, subject: LoanSubject,
                   acquired: OriginId }
LoanSubject      = Header(place: PlaceId)
                 | ContentsOf(place: PlaceId, position: AccessPath, epoch: Epoch)
                 | ForeignContents(contract: ForeignAccess)
Epoch            = EntryEpoch(place: PlaceId)
                 | CutEpoch(site: InstructionId, place: PlaceId)
                 | HeaderEpoch(block: BlockId, place: PlaceId)
LoanState        = Live | Ended(at: OriginId)
```

These are compiler facts; runtime ownership uses the region/header ABI in
[region completion](region-completion.md#2-actual-resources-and-exclusive-custody).
There are no runtime per-borrow objects and no concrete epoch history vector.
`BorrowedCustody` gives a native callee access to an existing owner through Ref;
it does not give that callee authority to release its caller's whole region.

An epoch is relative to one execution of its block, not globally identified by
its instruction address. On a loop edge, first compare a loan's epoch with that
edge's current owner epoch. Only a matching current relation is renamed to the
header's `HeaderEpoch`. An old loan does not become current merely because its
syntax or address repeats. A refreshed loan passes this substitution; a stale one
fails. Backedge transport itself creates neither a cut nor a source move.

Whole regions transfer their actual current custody. A fragment can escape only
through detachment before its custodian ends. Equal/empty header bits do not prove
which holding was selected. Partial moves change only the selected component's
endpoint and leave sibling authority intact.

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
                   wait_mode: WaitMode,
                   signature: Signature, entry: BlockId, blocks: List Block,
                   places: Map PlaceId Place, origin: OriginId }
DefinitionKind   = NativeWord | TaskStep | BlockingEntry | StorageHelper
WaitMode         = PlainBlocking | TaskSuspending | NoSourceWait
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
           | SourceWait { origin: OriginId, operation: Operand, resume: Edge }
```

`WordInfo` retains source identity without retaining a hosted body or its builder.
A block has one terminator; its edge arguments are simultaneous. `Return` is an
actual native return after completion, not an inline body return. `SourceWait`
marks the existing source-wait operation, not budget suspension. Before emission,
`PlainBlocking` waits become ordinary Nua blocking-wait calls; `TaskSuspending`
waits become step-function control and typed frame access in this same graph.
`NoSourceWait` rejects a source wait. `SourceWait` may not remain in a ready program.
Root plain entries select PlainBlocking; task steps select TaskSuspending. Ordinary
inline invocations inherit their caller's mode. Shared/materialized native bodies
and blocking-job bodies retain NoSourceWait; budget capability does not relax it.

The Nua boundary ABI passes each owning result through one caller-provided complete
result holding of its fixed native layout. Non-owning results use their native
result convention. An aggregate's independently owning fields remain distinct
holdings in that fixed layout. C-boundary signatures retain their restrictions on
owners; task entry has the trusted runtime ABI, not a signature-based guess.

### 3.2 Instruction family: complete top-level membership

Every row below includes the mandatory `site: Site` field. These are the complete
top-level instruction kinds; there is no `Other`, C template, or untyped payload.

| Kind | Remaining fields | Evaluation/effect contract |
|---|---|---|
| `Compute` | `result: ValueId, type: NativeType, opcode: NumericOpcode, arguments: List Operand` | Native typed computation; validity classified by opcode/type |
| `Pack` | `result: ValueId, type: NativeType, components: List Operand` | Representation assembly; transports existing facts, never duplicates custody |
| `Extract` | `result: ValueId, type: NativeType, aggregate: Operand, path: ComponentPath` | Projection under required tag/index proofs; no new owning move |
| `Load` | `result: ValueId, place: PlaceId` | Ordered observation; result facts taken at this site |
| `Store` | `place: PlaceId, value: Operand` | Non-owning assignment only; preserves reference facts when materialized |
| `Address` | `result: ValueId, place: PlaceId` | Expose this place; establish pending contents before exposure |
| `Check` | `condition: Operand, message: Operand, claim: CheckClaim` | Fallthrough establishes claim; failure traps at this site |
| `Invoke` | `result: Option ValueId, callee: Callee, arguments: List Operand, boundary: BoundaryId` | Complete ordered argument captures, callee effects and caller completion |
| `Atomic` | `result: Option ValueId, opcode: AtomicOpcode, address: Operand, arguments: List Operand, order: MemoryOrder, failure_order: Option MemoryOrder` | Atomic read/write/RMW with native legality checks |
| `Fence` | `order: MemoryOrder` | Atomic ordering; not a pure unused computation |
| `Storage` | `result: Option ValueId, request: StorageRequest` | Logical resource/custody operation, realized by Nua words |
| `LifetimeStart` | `lifetime: LifetimeId` | Begin the declared logical lifetime |
| `LifetimeEnd` | `lifetime: LifetimeId` | End its loans after required source completion and ownership cleanup |
| `Borrow` | `loan: LoanId` | Record acquisition at this graph site; does not force address materialization |
| `LoanCut` | `target: PlaceId, position: AccessPath, reason: CutReason` | Explicit semantic invalidation; no runtime per-loan bookkeeping |
| `StartTask` | `result: ValueId, task: TaskId, captures: List Operand` | Typed capture and child publication protocol, realized by Nua words |
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
BudgetReason  = LoopEdge | RecursiveEdge | StorageStep
CutReason     = OwningTransfer | SharedGrowth | TruncateContents
              | RootCompletion | NativeCompletion | ExplicitCompact
CheckClaim    = Bounds(place: PlaceId, index: Operand, length: Operand)
              | ActiveAlternative(value: Operand, name: String)
              | Condition(value: Operand)
Callee        = DirectNua(definition: DefinitionId)
              | IndirectNua(pointer: Operand, signature: Signature, provenance: NuaEntry)
              | Foreign(pointer: Operand, signature: Signature, contract: ForeignEffects)
NuaEntry      = DefinitionEntry(definition: DefinitionId)
              | TaskStepEntry(task: TaskId)
              | RuntimeEntry(name: String)
```

Greater comparisons reverse already captured operands into `Less`/`LessEqual`;
this does not reverse source evaluation. Short circuit and selection are control,
not eager numeric opcodes. Type/arity/result rules belong in a closed opcode
vocabulary shared by evaluation, verification and emission. Adding an opcode
requires those rules, not merely a new string accepted by `Compute`.

`Mechanism.binding` must resolve in the target's checked mechanism vocabulary.
Each entry has `{ signature, effects, c_symbol, jit_symbol }`. The required storage/
context entries are `reserve`, `commit_pages`, `release`, `move_bytes`,
`context_initialize`, `context_switch`, `context_finish`, `recover_jump` and
`fatal_trap`. OS threading, TLS and I/O use separately declared platform bindings.
Unknown bindings fail construction. `context_switch` is explicitly switching,
not an opaque foreign call that would fence its own switch. Reserve returns
status/provenance; allocation policy and all resource-list algorithms stay Nua.

### 3.3 Storage requests and their realization bindings

```text
StorageRequest = CreateOwner { type: NativeType, destination: PlaceId }
               | TransferOwner { source: HoldingId, destination: Endpoint,
                                 kind: TransferKind }
               | CopyOwner { source: PlaceId, destination: Endpoint }
               | EndOwner { holding: HoldingId }
               | ReserveStorage { owner: PlaceId, position: AccessPath, capacity: Operand }
               | InitializeElement { owner: PlaceId, index: Operand, value: Operand }
               | EndElements { owner: PlaceId, first: Operand, limit: Operand }
               | CompactStorage { owner: PlaceId, position: AccessPath }
TransferKind   = SourceTransfer | Transport
```

These are general typed-storage capabilities, not Map/Text/Store-specific
instructions. `InitializeElement` is a trusted initialized-buffer transition,
not a public uninitialized-slot API. Public append/pop/replace/truncate algorithms
are Nua words composing checked operations; compiler code does not choose their
capacity policy, walk payloads or rebuild map indices.

| Request | Nua binding selected by realization |
|---|---|
| `CreateOwner` | `regions.create type` |
| `TransferOwner` | `regions.transfer type kind` |
| `CopyOwner` | `regions.copy type` |
| `EndOwner` | `regions.end_value type` |
| `ReserveStorage` | `buffers.reserve type position guarantee` |
| `InitializeElement` | `buffers.initialize type` |
| `EndElements` | `buffers.end_range type` |
| `CompactStorage` | `regions.compact type position` |

These bindings live in the replacement Nua runtime/storage vocabulary. Their type
arguments specialize finite structural visitors; their native arguments carry
captured headers, addresses, indices, capacities and durable operation/context
records. Realization replaces `Storage` with their evaluated graph and retains the
associated source `LoanCut` exactly once. Private helper copies do not add another
cut. Adoption avoiding a payload copy does not erase that event. `Storage` may not
remain in backend-ready code. `Transport` changes the receiving endpoint of the
same installed holding without a source cut. It must preserve existing valid
loans; required fragment detachment occurs at the actual source transfer, not as
an unexpected relocation during later compiler transport.

### 3.4 Fact products, not a second program

```text
ValueInfo       { type: NativeType, components: Map ComponentPath ComponentInfo,
                  proofs: Set Proof }
ComponentInfo   = Plain | Borrowed(info: ReferenceInfo) | Owning(holding: HoldingId)
                | Callable(entry: Option NuaEntry)
Proof           = Checked(site: InstructionId) | Taken(edge: EdgeId)
                | Known(claim: CheckClaim)
FlowFacts       { contents: Map PlaceId Contents, holdings: Map HoldingId Holding,
                  loans: Map LoanId LoanState,
                  epochs: Map PlaceId (Map AccessPath Epoch),
                  live_lifetimes: Set LifetimeId }
EdgeFacts       { edge: EdgeId, flow: FlowFacts, arguments: List ValueInfo }
JoinRelation    { block: BlockId, incoming: List EdgeFacts }
SiteFacts       { before: FlowFacts, after: FlowFacts, effects: Effects }
DefinitionFacts { values: Map Operand ValueInfo, loans: Map LoanId Loan,
                  entries: Map BlockId FlowFacts, edges: Map EdgeId EdgeFacts,
                  joins: Map BlockId JoinRelation, sites: Map InstructionId SiteFacts,
                  terminators: Map BlockId Effects }
Analysis        { revision: U64, definitions: Map DefinitionId DefinitionFacts,
                  contracts: Map DefinitionId BoundaryContract,
                  tasks: Map TaskId TaskPlan, realizations: Map RealizationSite Realization }
```

`Map Operand` uses canonical operand identity, not a deep Lua-table key comparison.
Facts are tied to `Program.revision`. A rewrite returns a new revision and the
analyses it has actually rebuilt; it cannot reuse a certificate for changed code.

Each `JoinRelation` row is keyed by the actual incoming edge. The row contains
owner, reference and current-contents facts together. Selection consults that row,
not independent unions of possible owners and borrows. Nested relations refer to
other joins by ID; the driver does not enumerate every whole-program path.
Loops have finite header-relative facts, not a row for every runtime iteration.

`Analysis` has no executable control of its own. Ordered checking follows the
actual blocks, instructions and edges of `Program`. It does not execute an
ownership-only copy of that program.

### 3.5 Effects and native boundary contracts

```text
Effects          { reads: List Access, writes: List Access, exposes: List Access,
                   consumes: List Access, cuts: List Access,
                   may_trap: Bool, may_wait: Bool, may_switch: Bool,
                   foreign_extent: Bool, nonreturning: Bool }
Access           { target: TargetRelation, path: AccessPath }
ForeignEffects   { reads: List Access, writes: List Access, retains: List Access,
                   may_reenter: Bool, noreturn: Bool }
InterfaceOrigin  = Incoming(parameter: Positive, path: AccessPath)
                 | GlobalOrigin(global: GlobalId, path: AccessPath)
                 | FreshResult(path: ComponentPath)
                 | SelectedResult(join: BlockId, component: ComponentPath)
InterfaceLoan    = HeaderLoan | InputContents(position: AccessPath)
                 | AcquiredContents(position: AccessPath, site: InstructionId)
InterfacePart    = PlainPart
                 | BorrowPart(origin: InterfaceOrigin, loan: InterfaceLoan,
                              guarantee: StorageGuarantee)
                 | OwnerPart(origin: InterfaceOrigin, guarantee: StorageGuarantee)
InterfaceInfo    { type: NativeType, parts: Map ComponentPath InterfacePart }
AliasRequirement { left: Access, right: Access, at: InstructionId }
BoundaryContract { definition: DefinitionId, inputs: List InterfaceInfo,
                   returns: Map BlockId InterfaceInfo,
                   effects: Map InstructionId Effects,
                   terminators: Map BlockId Effects,
                   requires_disjoint: List AliasRequirement,
                   completion_cuts: List Access,
                   normal_exits: Set BlockId, revision: U64 }
```

`Effects` describes **one execution site**. The boundary contract retains the
instruction/terminator maps and the definition's actual CFG, including nonreturning
prefixes and source waits. A trap/wait terminator is not lost because it has no
instruction result. It is not an unordered final may-read/may-kill summary. A call substitutes parameter
accesses with actual argument relations, then checks ordered use/kill constraints
on that graph. Required separation of an invalidator and a subsequent old-view
observation is represented by `requires_disjoint`; it is not inferred from final
return facts. Return rows preserve which actual exit supplies each result origin;
`SelectedResult` refers to that definition's correlated join rows after projection.
`completion_cuts` are applied at caller completion before returned-loan validation.
An `AcquiredContents` site is the actual `Borrow` instruction, not a fictional
post-call acquisition. A header loan is distinct from a contents loan.

Contract projection replaces local IDs by incoming/global/result paths. A remaining
callee-local place, loan or holding in the outward interface is a verification
error. Actual header custody crosses the native boundary; compile-time origin
alternatives do not become a runtime cleanup-history vector.

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
                  loans: Map LoanId Loan, exits: List ExitSite,
                  requests: Set DefinitionId, state: DraftState }
DraftState      = Open | Adopted | Discarded
BlockDraft      { id: BlockId, arguments: List BlockArgument,
                  instructions: List Instruction, terminator: Option Terminator }
Path            { attempt: AttemptId, block: Option BlockId,
                  environment: EnvironmentId, lifetime: LifetimeId, facts: FlowFacts }
InvocationWork  { id: InvocationId, word: WordId, draft: Draft,
                  entry: Path, locals: List PlaceId, exits: List ExitSite,
                  result_type: NativeType, mode: EvaluationMode, wait_mode: WaitMode }
EvaluationMode  = HostOnly | Residual
ExitSite        { kind: ExitKind, path: Path, capture: Capture, origin: OriginId }
ExitKind        = InvocationReturn(target: InvocationId)
                | LoopBreak(target: LoopId) | LoopNext(target: LoopId)
Capture         { value: NativeValue, ready_after: Set LifetimeId,
                  transfer: Option PendingTransfer }
PendingTransfer { source: HoldingId, destination: Endpoint }
CapturePurpose  = Observation | ArgumentCapture | ReturnCapture | Transport
Lifetime        { id: LifetimeId, parent: Option LifetimeId,
                  kind: LifetimeKind, completion: List CompletionAction }
LifetimeKind    = GlobalLife | InvocationLife | LexicalLife | TaskScopeLife | ForeignViewLife
CompletionAction = EndLocal(place: PlaceId) | JoinScope(operation: Operand)
                 | FinishForeign(operation: Operand) | ApplyNativeCuts(boundary: BoundaryId)
```

`LoaderScope` is the restoration handle owned by `nua.loader.with_context`:
`{ loaded, public_loaded, loaders, path, preload, cpath }`, holding the saved Lua
registry/package values. It is not another module cache. The compilation driver
restores it on success and failure; it does not promise concurrent compilation.

A `Capture` contains the value already observed, never a callback that rereads
it. Owning captures retain complete header/custody information. `ready_after`
records existing legal protectors that must complete before destructive transfer;
it does not introduce new task-borrow permissions. Source capture, activity
completion and the final owning transfer are three distinct operations.
`Observation`/`Transport` add no owning move. An owning argument is transferred
into its complete argument holding before the next argument is evaluated.
`ReturnCapture` records a pending transfer when existing legal protectors defer it;
the complete captured value, not a future reread, survives that interval.

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
                 | WidenTargets(place: PlaceId, targets: TargetRelation)
                 | WidenGuarantee(place: PlaceId, guarantee: StorageGuarantee)
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
| `evaluating` | `InvocationWork`, local lifetimes, evaluation vocabulary | Entry `Path`, word, supply, definition requests | Complete exits and local holdings; return value/path or no continuation |
| `branching` | Two child drafts and predecessor facts | Captured condition and entry facts | Adopt both valid residual arms; reconcile only continuing edges |
| `looping` | `LoopWork` (§6), round draft, header agreement | Entry path, carried places, hosted condition/body | Keep accepted known prefix; revise only rejected round/body; finish exits |
| `defining` | Definition drafts and recursive agreement group | Word/specialization request | Publish group only after contracts close; discard caller-local contributions |
| `realizing` | Working graph, queue of logical sites, realization records | Completed semantic graph, Nua bindings | Resolve all reachable logical storage/task sites and verify protocols |
| `rewriting` | New output, evolving analysis state | Read-only input and explicit shared capabilities | Return replacement graph/facts; never mutate inspected input |
| `emitting` | Names, declarations, backend handles | Verified ready program and target | Return backend product; close nonretained resources |

`facts.fork` copies the four `FlowFacts` maps and the live-lifetime set; their entries
are immutable records. A later write replaces an entry rather than changing a
shared holding/loan record. Name environments extend by fallback. These are two different operations.

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
    loan         : Loan -> Unit,
    exit         : ExitSite -> Unit,
    require      : DefinitionId -> Unit
}
GraphFragment { entry: Option BlockId, blocks: Map BlockId BlockDraft,
                places: Map PlaceId Place,
                lifetimes: Map LifetimeId Lifetime,
                values: Map Operand ValueInfo, loans: Map LoanId Loan,
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
    observe     : FlowFacts -> NativeValue -> OriginId -> Unit,
    invalidate  : FlowFacts -> Access -> CutReason -> Site -> Unit,
    transfer    : FlowFacts -> HoldingId -> Endpoint -> Site -> Holding,
    rebind      : FlowFacts -> HoldingId -> Endpoint -> Holding,
    check_edge  : EdgeFacts -> FlowFacts -> EdgeFacts
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

`observe` checks current loans and owner endpoints; it does not mark mere pointer
transport as dereferencing contents. `invalidate` changes matching current epochs
and loan states under the target relation. `transfer` moves one authority, updates
source/destination facts and records the required source cut. `rebind` implements
compiler transport with no new cut or duplicated authority. `check_edge` verifies
and normalizes incoming facts, including the loop epoch substitution. `agree` and
`substitute` return data; their enclosing activity performs any required stores or
cleanup. None of these functions allocates native storage during compilation.

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
an already captured argument at invocation entry uses transport, not another source
move. Known branch selection invokes only the selected delayed body.

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

`evaluating` creates these verbs once for one invocation. They capture the invocation's
writer, identity supplier, diagnostics, native rules and explicit definition/storage
capabilities. The current path is an argument, not a field swapped in those modules.

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
                        -> NativeABI -> WaitMode -> DefinitionId,
    branching: Path -> NativeValue -> HostedBody -> HostedBody -> BranchResult,
    looping: Path -> List PlaceId -> ConditionBody -> HostedBody -> LoopResult,
    mode: EvaluationMode,
    wait_mode: WaitMode
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
    borrow        : Path -> PlaceId -> AccessPath -> NativeValue,
    capture       : Path -> CapturePurpose -> NativeValue -> Capture,
    transfer      : Path -> HoldingId -> Endpoint -> NativeValue,
    transport     : Path -> HoldingId -> Endpoint -> NativeValue,
    copy          : Path -> PlaceId -> Endpoint -> NativeValue,
    end_value     : Path -> HoldingId -> Unit,
    storage       : Path -> StorageRequest -> Option NativeValue,
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
    start_task    : Path -> TaskPlan -> List NativeValue -> NativeValue,
    wait          : Path -> NativeValue -> Path,
    mechanism     : Path -> String -> List NativeValue -> Option NativeValue
}
```

All handlers validate path ownership/liveness first. `read` of a named owner in
value context captures its current holding for the prescribed move; borrowing
contexts use `borrow`/`address`, never a header-copy escape. `write` dispatches an
owning assignment to `transfer`; it cannot emit a raw owner-typed `Store`.

| Verb | Known case | Residual case | Facts changed |
|---|---|---|---|
| `compute` | Native rule computes exact result if valid | Emit `Compute`; return `Bits(Result)` | None beyond result/proof registration |
| `read` | Return valid tracked observation | Emit `Load` and register its complete `ValueInfo` | Observation/owner capture as appropriate |
| `write` | Replace tracked contents; keep pending store lazy | Emit required store at observation/exposure boundary | Contents and reference/holding facts |
| `address` | Preserve the exact source place | Flush pending contents before `Address` | Exposure and loss of invalid private knowledge |
| `branch` | Execute selected body | Build isolated arms and a join | Edge-correlated flow facts |
| `transfer` | Still requires runtime owner storage | Emit `Storage(TransferOwner)` and its logical cut | Source moved, destination custody, old loans ended |
| `call` | HostOnly follows in-place source rule | Request definition; emit `Invoke` even for a known result with effects | Ordered substituted boundary effects |
| `trap` | Source/host diagnostic when native execution is unavailable | Terminate path with `Trap` | No continuation; no dummy result |

The handler's returned value is not its whole effect. A known result cannot erase
an invocation, allocation, check, atomic operation or completion that must execute.
A helper word uses these same handlers; there is no second evaluator for storage.
`Evaluation.apply` receives saturated supply; the frontend uses `Hosting.supply`
until then. Untyped callbacks can return host values, words and packs through
`CallbackResult`; they are not forced into a native result type. A typed body's
fallthrough is Unit only when its declared result permits Unit. `wait` terminates
the current block with `SourceWait` and returns its resume path; it does not end
the logical invocation. The Nua operation word reads its completed result from
the operation record on that path.

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
5. For owner/reference components, create one `JoinRelation` with whole incoming
   rows. Rebind each block argument to its row's actual holding and loans. Do not
   merge their metadata independently. Apply required conditional-move cleanup
   on the nonmoving edge before that edge enters the join.
6. Establish missing-initialization/moved facts conservatively: another edge's
   initialized/live state is not permission to read. Check future observations
   against every feasible incoming row.
7. Adopt arm fragments, terminate their live tails with the constructed edges,
   and return the joined `Path`. No live predecessor returns `NoContinuation`.

`facts.agree` decides from captured facts; it does not emit stores or evaluate
source. `branching` owns establishment of that decision, including edge stores,
loan effects and cleanup, and rejects the whole construction if establishment fails.

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
   merely discovering a write/participant does not force a retry. Normalize current
   owner/loan relations using the epoch substitution in §2.4.
5. On `Weaken`, discard that child draft and its contributions, update only the
   named assumptions, and reconstruct that body. Known scalar agreement weakens to
   a typed dynamic value on disagreement; it does not accumulate all encountered
   constants. Reference information weakens by the existing conservative alias and
   stable/shared rules, never by a physical root-count limit.
6. On `Holds`, establish simultaneous edge captures/stores, add the required budget
   point on each residual cycling edge, and seal the backedges. Complete exiting
   paths at their own continuations. Exit-only changes do not alter the next header.

The analysis domain contains native types, finite source/parameter component paths,
known-or-dynamic contents, stable/shared guarantees, initialization/move states,
and current/ended loan relations. Unknown array indices use `AnyElement`; runtime
cohort sizes are not enumerated. Each header weakening removes an assumption rather
than allocating a new concrete epoch. Known host unfolding can still fail to
terminate; that does not justify a placement-based rejection of a residual program.

### 6.3 Definition requests, captures and recursive agreement

```text
DefinitionKey   { word: WordId, supply: List SpecializationInput,
                  captures: List CaptureRequirement, abi: NativeABI, wait_mode: WaitMode }
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

request requester application argument_info abi wait_mode -> DefinitionId
require_capture definition binding mode -> Parameter
agree_group definitions -> List DefinitionResult
```

The key contains no caller-local place, absolute allocation index or concrete loan
identity. `InterfaceInfo` carries the native reference/storage guarantees. A
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
2. Evaluate with fresh formal native parameters, parameter-relative holdings/loans
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
    -> wait for separately legal protectors / joins
    -> transfer complete result to the receiver
    -> end remaining local holdings
    -> apply pending caller-side native cuts at caller completion
    -> validate returned borrows
    -> continue caller, or emit native Return
```

For a native boundary, callee-side transfer/local completion precede its `Return`;
the pending cuts and returned-borrow validation are caller-side operations. The
sequence above is across both sides of that boundary, not code placed after a
terminator in the callee. Inline completion has no native ABI return.

The receiver exists before a native callee's frame disappears. Complete holdings
survive legal waits. A frozen source cannot move early; a legal capture cannot be
delayed past a mutation that would change its value. The caller-side cut remains
at caller completion even if physical retirement earlier moved no payload.

## 7. Realization, task planning and backend readiness

### 7.1 Realization work and protocol checks

```text
RealizationSite = AtInstruction(instruction: InstructionId) | AtTerminator(block: BlockId)
RealizationWork { input_revision: U64, writer: GraphWriter,
                  pending: List RealizationSite, completed: Map RealizationSite Realization,
                  definitions: Set DefinitionId }
Realization     { source: RealizationSite, origin: OriginId, word: WordId,
                  entry: BlockId, exits: Set BlockId,
                  generated: Set InstructionId, protocol: Option StorageProtocol }
StorageProtocol { prepare: Set BlockId, ready: Set EdgeId,
                  commit: Set BlockId, retire: Set BlockId,
                  operation_record: Operand, current_custody: List Operand }

realizing program analysis bindings -> (Program, Analysis)
```

The worklist starts with reachable `Storage`, `StartTask` and `SourceWait` sites.
For each site, use the already captured operands to evaluate its selected Nua word
or generate its typed step/frame control. Adopt the resulting blocks and definition
requests into the same program. Enqueue newly introduced logical sites. Type schema
recursion visits owning fields/active sums/initialized ranges; runtime lengths
remain native loops. Raw metadata allocation does not invoke ordinary owner
construction recursively. This is the selected bootstrap boundary.

`StorageProtocol` names real blocks/edges, not a Boolean “trusted” label. Verification
checks all reachable commit instructions and transitive call effects: no allocation,
fallible arithmetic/check, user callback, foreign reentry, wait, budget or runtime-
length loop. Prepared resources are registered before another fallible action;
retirement entries cannot cover one allocation twice. Recovery state/cursors are
in durable native records, not Lua builders or abandoned native frames. Raw-kernel
correctness additionally requires independent runtime ledgers/failure injection;
a graph certificate alone is not a proof of an allocator algorithm.

A realized helper's logical effects remain in its checked call/site contract and
explicit `LoanCut`s. Pure SSA/header transport is not assigned another transfer cut.
The `Realization` source ID is historical provenance; all executable targets in
its generated set resolve in the current graph. Rewriting that region invalidates
its protocol record and requires rechecking it.

### 7.2 Task data and the two continuation kinds

```text
TaskPlan        { id: TaskId, entry: DefinitionId, frame_type: NativeType,
                  captures: List TaskCapture, waits: Map BlockId WaitState,
                  native_stack_bytes: U64, origin: OriginId }
TaskCapture     { field: String, type: NativeType, source: Operand, info: ValueInfo }
WaitState       { number: U32, operation_field: String, resume: BlockId,
                  live_fields: List String }
TaskResume      = Start | SourceResume(state: U32) | BudgetResume
```

These are compiler plans for the approved runtime records. Runtime task state
includes the typed frame, native stack/context, storage context, executor affinity,
run state and resume kind specified in [region completion §7](region-completion.md#7-native-tasks-without-a-second-evaluator).

- `StartTask` captures values in order, constructs/registers frame/control/context/
  stack resources, then publishes the child through ordinary Nua scheduler words.
- In TaskSuspending mode, `SourceWait` assigns a `WaitState`, stores live values
  in the typed frame and returns the waiting step status. Source-resume completion/Slot adoption occurs
  once. PlainBlocking mode instead calls the Nua plain-wait driver, with the approved
  worker/no-worker execution policy. NoSourceWait bodies are rejected at the source
  operation; they are not silently converted to either form.
- `Budget` calls the trusted Nua budget entry. It saves the actual native continuation
  on the nonmoving task stack; it does not store a source state number or replay
  arguments. Nua scheduler policy handles service rounds, seed draws and affinity.
- Every residual Nua cycle has budget coverage. Known recursive native-call SCC
  edges charge after argument capture and before callee entry. Storage walks use
  completed bounded steps; COMMIT has none. Opaque foreign extents defer service.
- Variable-size cleanup finishes on the task stack before DONE. Only fixed release
  after permanent switch-out runs on the scheduler stack. No second step may run
  while a budget continuation remains claimed.

Both C and JIT preserve these distinctions. The context platform port, guard/probe
rules and fatal task trap policy are not replaceable by an OS-thread fallback.

### 7.3 Preparation order and invalidation

```text
prepare program analysis -> Prepared
Prepared { program: Program, analysis: Analysis, certificate: ReadyCertificate }
ReadyCertificate { revision: U64, definitions: Set DefinitionId }
```

The selected driver order is:

1. Close reachable native-definition groups and verify semantic graph/contracts.
2. Realize storage, task construction and source waits; include helper definitions
   in closure and contract checking.
3. Run optional folding, reachability and dead pure-result elimination on this graph.
4. Add/verify budget coverage for the resulting loop and native-call cycles, then
   recompute affected graph/alias/effect/lifetime facts, including switching effects.
   Verify storage publication regions. A newly discovered semantic effect that
   invalidates construction targets its owning attempt; it is not ignored because
   an optimizer already ran.
5. Verify backend readiness and produce `ReadyCertificate` for exactly this revision.

The optional optimizer has eight rounds, stopping earlier on graph-aware equality.
Every round must preserve a valid program. Mandatory agreement/realization has no
“publish at cap” path. A structural change after step 5 invalidates the certificate.
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
| `types` | Operand/result/native ABI rules; initialized/tag/index proofs; no raw owner Store |
| `lifetimes` | Use/kill order, explicit lifetime starts/ends, correlated joins, unique custody, current loan relations, complete exits |
| `task_access` | Reachable task/blocking/callback accesses; global policy, pointer origins and sendability |
| `publication` | PREPARE/READY/COMMIT/RETIRE regions, transitive effects, recovery records, budget exclusion |
| `ready` | All preceding checks; no Storage/StartTask/SourceWait; closed helper graph; budget coverage; target mechanisms available |

`LifetimeStart`, `LifetimeEnd`, `Borrow` and `LoanCut` remain checked zero-machine-code
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
| `realize_instruction` | GraphFragment | Realization-owned pending sites and definitions |
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
`request` to evaluation and the evaluation function back to definition/control/
realization activities. Hosting collects the actual export requests. The root
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

The first source situation selects an ordering of two independent owners A/B.
A header alias must not retarget when A moves; an earlier scalar observation must
not change. The following loop then exercises replacement through a persistent H.
The schema below omits only native type spelling, not the choice/custody edges. It is an architectural trace, not a test-run report.

```text
entry facts:
    A -> Tracked(Owned(type=T, header=%a, holding=ha, endpoint=InPlace(A)))
    B -> Tracked(Owned(type=T, header=%b, holding=hb, endpoint=InPlace(B)))
    ha.endpoint = InPlace(A); hb.endpoint = InPlace(B)
    epochs[A] = EntryEpoch(A); epochs[B] = EntryEpoch(B)

body:
    %before = Load A.count
    %alias  = Address A
    Branch %choice -> choose_a(), choose_b()

choose_a:
    capture actual A; transfer ha -> InCapture(%left_a)
    capture actual B; transfer hb -> InCapture(%right_a)
    Jump join(%left_a, %right_a)

choose_b:
    capture actual B; transfer hb -> InCapture(%left_b)
    capture actual A; transfer ha -> InCapture(%right_b)
    Jump join(%left_b, %right_b)

join(%left, %right):
    JoinRelation rows are:
      choose_a edge: left owns ha; right owns hb
      choose_b edge: left owns hb; right owns ha
    ... use/end left; observe right ...
```

The alias to A still names A, not whichever joined result owns ha. The count
observation still means `%before`, not a fresh read through `%alias`. Actual owner
moves end their old contents loans on their edges. The selected result transports
its actual region handle; no header comparison reconstructs the branch. An empty
owner has the same custody requirements as a nonempty one.

For replacement of a separate live H in a loop, these interfaces produce:

```text
header(%current_header, %refreshed_view):
    H.epoch = HeaderEpoch(header, H)
    view.loan.subject = ContentsOf(H, position, HeaderEpoch(header, H))
    ... observe view ...
    Storage TransferOwner(source=next_holding, destination=InPlace(H), kind=SourceTransfer)
    LoanCut(H, position, OwningTransfer)
    H.epoch = CutEpoch(transfer_site, H)
    view2 = borrow(H, position)       -- new loan of that current epoch
    Budget LoopEdge
    Jump header(H.header, view2)
```

The backedge verifies `view2` against its current H before renaming both to the
header relation. Supplying the earlier view instead fails: its HeaderEpoch is not
the backedge's CutEpoch. Reusing that printed site on another runtime iteration
never revives the earlier loan.

Realization replaces the `Storage` site with `regions.transfer T SourceTransfer` through
`Evaluation`. Its result has recorded prepare/commit/retire blocks; current custody
is published before old exclusive blocks retire. The existing `LoanCut` is linked
to that source transition, not duplicated for helper copies. C/JIT receive the same
verified blocks. Plain recovery uses the operation/domain records; task traps stay
fatal. No completed replacement retains obsolete blocks merely because a later
owner happened to allocate after them.

## 9. Acceptance and implementation boundary

The first replacement milestone must connect actual Mua hosting, these evaluation
interfaces, owner/reference/partial-move facts, control agreement, Nua storage
realization and one backend product. A scalar-only evaluator or a family declaration
library is not that milestone. Task/platform implementation follows the same selected
interfaces; it is not grounds to weaken the architectural contract meanwhile.

The concrete acceptance set is:

1. Load every family/pass with contracts enabled; reject missing handlers, unknown
   fields, sparse node lists and malformed graph/owner/loan facts.
2. Host real Nua source for partial/known/mixed supply, earlier observations, branch
   correlation, partial moves, current-header replacement and refreshed/stale loops.
3. Repeat and nest factories; reject stale writers; accept child then reject parent;
   verify independent prior output and surviving prefix/sibling state are unchanged.
4. Exercise definition capture, argument/fresh results, recursive forwarding and
   combination, ordered aliased kill/use, and nonreturning call prefixes.
5. Independently account for raw acquisition, current custody, preparation failure,
   publication, obsolete retirement, shared-fragment escape and surviving globals.
6. Verify task source/budget resume separation, single executing continuation,
   foreign fencing, long storage work, cleanup-before-DONE and seeded service rounds.
7. Compare known results, unoptimized/optimized prepared execution and C/JIT against
   independent expected values/effect/resource traces. Agreement between shared
   handlers/backends alone is not an independent oracle.

Positive partners must accompany refusals: refreshed versus stale loan; stable
independent growth versus genuinely shared invalidation; valid large/late target
cohorts versus an actual lifetime violation. An optimizer limit may reduce
optimization, not accepted source coverage or correctness.

The historical [activities](compiler-activities-experiment.md),
[completion](compiler-completion-experiment.md), [native-boundary](compiler-boundary-experiment.md),
[join](compiler-join-experiment.md) and [regional](compiler-region-experiment.md)
experiments remain unchanged evidence. Their fixed positions/ports and counts do
not implement or validate this region architecture. Their raw failures remain
preserved. This document replaces the earlier deferred constructor/API descriptions;
it does not rewrite their reports or claim their probes implement these schemas.

The method is Mua's [compiler guide](https://github.com/cperion/mua/blob/b93e36fa75c9d23cc1e68c70bdb5834e8c17b476/docs/writing-compilers.md):
name the data, list the operations, give each activity its state and completion.
The concrete Nua contracts above are this design's choices, not the toy compiler's.

**No replacement implementation, dependency change or native test run accompanies
this specification.** The design now names its data and operations; implementation
and independent acceptance still have to establish that those contracts hold.
