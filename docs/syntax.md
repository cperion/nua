# Nua: the language

*What a program means.* This document owns the surface forms, the static rules and
the runtime contracts of a program: what you may write, what it is rejected for,
and what the C it becomes does. [The compiler](architecture.md) owns how those
rules are implemented — the pipeline, the residual IR, memory analysis, the
backends and the runtime. [The guide](designing-and-writing-nua.md) owns how to
design a program with them.

Section numbers are stable and are cited from the sources and the examples as
`syntax §N.M`.

Every C listing here is the compiler's output for a program in
[`examples/`](../examples/), which the test suite compiles, links and runs
(`tests/listings.lua` checks each block against that output). A listing marked
*sketch* is a calling-convention illustration, not output. Where something is
designed and not yet implemented, the text says so; architecture §17.2 lists what is
not.

## 1. The language at a glance

Nua is a small, staged systems-programming language hosted in Lua.

A program is ordinary Lua that runs while compiling. It constructs native type
descriptions, applies **words**, and `export`s the entry points C calls. A word
that declares a result type is native: its body describes runtime computation,
and the specializer evaluates it in place with whatever arguments are known at
that application. What remains — the part that depends on run time — is
residualized as C, checked against a memory model, and emitted.

Five mechanisms carry the language:

1. **Mua provides the surface language.** Typed functions, annotations,
   methods, declarations and control flow look like natural extensions of Lua,
   and typed bodies are parsed with Lua's grammar so that comparisons,
   conditions, `and`/`or`, assignment and `return` can be staged (§2, §4).
2. **LuaJIT executes compile-time computation.** Functions, closures, tables,
   generic types and higher-order generators construct and specialize programs
   (§2, §3).
3. **Native words specialize through application.** Partial application binds
   known arguments; a saturated application evaluates the word's body in place
   with every argument, known or not (§3).
4. **Online partial evaluation constructs residual code.** Known operations
   compute immediately; unknown ones become typed commands. The same word does
   both, and the same result either way (§4, §5, §6).
5. **Goose-style memory analysis assigns native storage.** Lexical ownership,
   borrowed references, stores and data-stack requirements are checked and
   lowered for the residual program (§9). The executable has no LuaJIT
   dependency, no garbage collector, no reference counting and no implicit heap.

The central principle:

> **Lua computes what is known. Commands represent what remains. Words
> progressively specialize computation. Goose determines where the residual
> values live. C executes the result.**

Three things are therefore decided by *when a value is known*, not by its type:

* **A Lua value** — a table, a string, a closure, a host number — exists only
  while compiling. It can hold a description, a generator or a type.
* **A known native value** — `U32 4`, a constant field, a sum with a known tag —
  is computed while compiling. It shapes the C and may vanish from it.
* **A runtime value** — a parameter of an export, a read from a file — is in the
  C.

**Programs are shaped by what they can express in Nua.** Library behavior — text,
map lookup, hashing, scheduling, the I/O vocabulary — is written in ordinary Nua
words, so it specializes and residualizes with the calling program instead of
sitting behind a runtime call. The compiler keeps language machinery and the
platform keeps mechanisms; [the architecture](architecture.md#15-what-stays-in-c-and-lua-and-why)
records that boundary and the reasons for what remains on each side.

The rest of this document follows a program's material from the surface down:
the surface language and application (§2, §3), typed control flow, state and
loops (§4, §5, §6), types and their C semantics (§7), methods (§8), owned and
borrowed storage (§9), activities and opening (§10), sums (§11), pointers and
slices (§12), arrays (§13), text (§14), maps (§15), library-defined types (§16),
foreign C (§17), POSIX (§18), atomics (§19), tasks and I/O (§20), native globals
and function values (§21), what the language deliberately lacks (§22), and the
contracts that define it (§23).

## 2. The surface language

The surface language retains Lua's ordinary vocabulary wherever possible.

It uses:

- `local` and `=` for bindings.
- `:` for type annotations and method syntax.
- `do` for lambdas.
- `function` for named functions and methods.
- `if`, `for` and `while` for control flow.
- Tables for Lua data and native construction syntax.
- Juxtaposition for application.

No source-level `emit`, `set`, `var`, `comptime`, `template` or `specialize` keyword
is required. The macros add two words, `struct` and `export` (with `oneof` as the
sum constructor, §11), and the prelude adds:

* **types and their constructors**: `Ref`, `Store`, `Id`, `Grow`, `Ptr`, `Slice`,
  `Array`, `Atomic`, `Chan`, `Pool`, `Slot`, `Fn`, `Str`, `Text`, `Chars`, `Map`,
  `CString`, `Duration`, and the scalars of §7;
* **the foreign boundary**: `extern`, `opaque`, `cstruct`,
  `cconst`, `cread`, `bytes`, `size_of`, `view_of`, `atomic_ptr`, `null`, `cformat`,
  `fence`, `trap`, `TODO` (a `trap` that marks work not written yet), `rawmember`;
* **binding time and the host**: `host`, `dynamic`, `native`, `global`, `fnptr`,
  `test`, `assert`, `Args`;
* **concurrency**: `tasks`, `first_of`, `recv`, `send`, `after`, `take`, `spawn`,
  `channel`, `pool`, `blocking`, `sleep`, `ns`, `us`, `ms`, `seconds`;
* **bitwise operations**: `band bor bxor shl shr bnot`, which Lua 5.1 has no
  operators for.

`channel` and `pool` are introduced by opening a `tasks` scope (§20.1).

### 2.1 Modules are Lua values

Modules use Lua's actual `require`, not a separate import API. `require "nua.hash"`
loads a bundled Nua vocabulary; `require "model"` loads a project module;
`require "io"`, `require "ffi"` and other Lua modules retain their Lua meaning.
A Nua loader translates `.nua` source and evaluates it in the Nua prelude,
returning ordinary Lua values through the standard module machinery.

During compilation, the program's directory is prepended to the Lua source path
as `?.lua` and `?/init.lua`. The existing preload, Lua, C and custom searchers
keep their order and precedence. An appended Nua searcher checks bundled
`nua.*` names in `lib/`, then follows the current Lua source-path templates with
`.nua` in place of `.lua`. Dots in module names denote directories. A found
module's syntax or evaluation error is an error, not permission to try another
candidate. Lua owns cache hits, no-value results, explicit `package.loaded`
publication, false results, and cycle/previous-load-error diagnostics.

Each compilation uses a fresh `package.loaded` table, also installed as the Lua
registry's loaded table, seeded with existing host modules. Newly loaded Lua,
Nua and C modules remain in that compilation's cache; this includes Lua wrappers
which retain Nua words. Compiler implementation modules have host lifetime.
Host loader/cache tables and source/native paths are restored on success and
failure. This is not a sandbox or a deep copy of host module values: explicit
host-global effects and mutations of existing host modules are shared. The
compiler's staging state is single-context; nested compilation is rejected.

See [the architecture](architecture.md#13-modules-and-the-compilation-scope) for the
search order, the compilation-scope cache and the acceptance checks.

### 2.2 Types are compile-time values

```lua
local Vec2 = struct with
    x: F32
    y: F32
end

local Player = struct with
    position: Vec2
    health: U32
end
```

`Vec2` and `Player` are Lua bindings to native type objects.

The `struct` operation constructs a type description. It does not immediately generate C; a struct is emitted only if residual code uses it.

Annotations appear in exactly five places:

```lua
struct { x: U32 }               -- struct fields
do(x: U32): U32 = ...           -- parameters and result types
function T:m(n: U32): Unit      -- the same, on named functions and methods
local y: U32 = x                -- typed locals
for i: U32 = 1, n do ... end    -- typed (native) loops
```

An ordinary Lua table remains ordinary Lua data:

```lua
local t = { x = U32 }
```

It is not a struct declaration merely because its value happens to be a type.


### 2.3 Generic types are ordinary Lua functions

```lua
local Pair = do(A, B) = struct with
    first: A
    second: B
end

local IntPair = Pair(U32, U32)
local MixedPair = Pair(U32, F64)
```

`Pair` is an ordinary compile-time Lua function.

No native generic representation exists at runtime.

Its result is a specialized native type object.

### 2.4 Application

Application is juxtaposition, as Mua defines it (Mua is the Lua language Nua is a host of; its own
surface rules are in Mua's syntax doc, `docs/syntax.md` of the Mua repository, pinned by
`tools/mua.lock`). This section keeps the rule numbers and says what Nua adds to each:

```lua
local Numbers = Grow U32
local NodeRef = Ref Node
local fifteen = triangular 5
local times8 = choose(true, 8)
```

and constructor-headed arguments:

```lua
self.nodes:add Node with
    value = 42
end
```

which means:

```lua
self.nodes:add(Node { value = 42 })
```

The rules:

1. **What can be an argument.** Mua's rule (Mua's syntax doc, §2 rule 1): numbers, strings, booleans, tables, lambdas, and names on the same line after a name, a literal or a spaced group. Nua adds nothing.
2. **The newline rule.** Mua's (§2 rule 2): a newline ends an application chain before any token that can begin a statement.
3. **What an argument is.** Mua's (§2 rule 3): a primary expression with its postfix chain; a spaced `(` is the next argument group. What Nua adds is the meaning of the groups: on a word they saturate as one supply (rule 7), so `add3 x (y * 2) (twice y)` is `add3(x, y * 2, twice(y))`.
4. **Left associativity.** `f a b` is `f(a)(b)`. Application binds more tightly than infix operators: `f a + 1` is `f(a) + 1`, and `f -1` is subtraction (a word is not a number, so with a word for `f` the compiler says so and suggests `f(-1)` or `f (-1)`).
5. **Brackets** group, delimit argument lists and resolve ambiguity: an empty store is `Store(Node) {}` or `(Store Node) {}`; `Store Node {}` would apply `Store` to `Node {}`. A compound argument is written as a spaced group: `f (x + 1) y`, `f a (b * 2)`.
6. **Loop headers.** Mua's (§2 rule 6).
7. **Saturating chains.** `f(a) do ... end` on a word accumulates arguments until the word is saturated (§10.4).
8. **Statements on one line.** Mua's (§2 rule 7).
9. **Field shorthand.** Mua's `.name` entry (Mua's syntax doc, §4): in a table constructor `.name` is `name = name`. It works in typed bodies and in the plain Lua code around them, and it is only spelling.

10. **Zero-argument call statements.** Mua's (Mua's syntax doc, §2 rule 8): a bare name or qualified name used as a whole statement invokes it with zero arguments. In Nua this applies in native bodies, callbacks and host Lua code; opened-context lookup and lexical shadowing are exactly those of the explicit call, and the rule does not inspect the callee's type or arity. It is statement-only: `local action = refresh` and `return refresh` still refer to the callable.

11. **Trailing colon.** Mua's (Mua's syntax doc, §4): a colon that ends a line, optionally after parameter names, opens an untyped block lambda: `do(..)`, `do(names)` or `do(scope..)`; `=:` assigns a block and `return:` returns one (`return: body` then a block and `end` is `return do(body) … end`): the colon always means a block. The names are untyped; a typed parameter list keeps `do(x: U32)`. `:` alone opens whatever the activity hands over, exactly as `do(..)` does; an activity that hands over nothing opens the empty set, so `spawn:` is `spawn do ... end`. `nua fmt` prints the colon form for every untyped trailing `do(..)` that ends a line; `block_style = "do"` in `.nuafmt.lua` keeps the `do` spelling.

12. **With blocks.** Mua's block (Mua's syntax doc, §4); what Nua adds is the table-shaped forms it takes. `T with entries end` is `T { entries }`: keyed data without commas, closed by `end`. `with` is to data what `do` is to computation: a `with` block supplies keyed data to the expression before it, a `do` block (or its colon form, rule 11) supplies a trailing computation.

```lua
local Point = struct with
    x: F32
    y: F32
end

local p = Point with
    x = 1
    .y
    found =: v  -- a keyed handler is an entry too
        go v
    end
end

local q = Point with x = 1, y = 2 end
local area = s with  -- matching is keyed application: the handlers are the entries
    circle = do(r) = r * r
    rect =: p
        return p.x * p.y
    end
end
```

Every table-shaped form takes it: constructors, `struct`, `oneof`, matches and any constructor-headed argument (`f x with k = 1 end` is `f(x { k = 1 })`, rule 3). Lua's own `{ }` tables are untouched, so no Lua table semantics change; `with` is the Nua spelling for keyed data and `{ }` stays for Lua tables and compact one-liners.

*Contextual `with`.* Where an expression starts (after `return`, `=`, `(`, `,` or `{`), `with` takes no type before it, and the **context supplies the constructor**: a declared result, a typed local, a typed parameter or a field of a record. It is the same construction as `T with`, without repeating `T`.

```lua
local make = do(n: U32): Point
    return with
        x = n
        y = n + 1
    end
end

local pair: Pair = with
    left = with x = 3, y = 4 end  -- a field of a record: its type is Pair's field type
    right = origin
end

total with x = 1, y = 2 end  -- a typed parameter
```

The type is found by the coercion that every typed position already performs, so it works wherever an expected type is known and nowhere else: `local p = with x = 1 end`, with no type in the context, is rejected (`with` here has no type) rather than guessed. A variable named `with` is still a variable (`with + 1`, `t.with`, `pass(with)`); `with` begins a block only before an entry (`name =`, `.name`, `[`, a literal).

*Entries.* Anything a table constructor accepts: `name = value`, `.name` (rule 9), `[key] = value`, positional values, and `name =: params` handlers. *Boundaries.* An entry ends where the next begins: a name followed by `=` or by `:` and a space begins one (so `x = a y = b` is two entries, not `x = a(y)(...)`); on a line of its own, a name or `.name` begins one. A value may continue over several lines (`z = a +` then `b`). `,` and `;` are still accepted and separate entries as in a table, and are needed before an entry that starts with `[`, a literal or a bracket, which would otherwise continue the previous value. *Inside.* The colon is an annotation, never a block opener (`struct with x: F32 end`); use `=:` for handlers. *Reserved.* `with` is a keyword only after an operand, where it would otherwise be an argument: `local with = 3`, `t.with` and `with(x)` are unchanged. The rewrite is a token rewrite below every other rule, like the trailing colon, and line numbers do not move. `nua fmt` keeps a `with` block as `with` (never turns braces into `with`, and drops the commas the reader writes back).

### 2.5 Words and host functions

A lambda is a **native word** exactly when it declares a result type:

```lua
local inc  = do(x: U32): U32 = x + 1        -- a native word
local wrap = do(x) = { value = x }          -- a Lua function
local bad  = do(x: U32) = x + 1             -- error: typed parameters need a result type
```

Inside a typed body, an untyped lambda is a callback, evaluated in place (§10.1).
An untyped lambda with an opened parameter (`do(..)` or `do(ctx..)`) uses that
same callback translation at top level: its opening follows lexical shadowing,
its body supports the ordinary Nua application forms, and its result is inferred.
It does not use a Lua function-environment overlay. Other untyped top-level
lambdas remain ordinary Lua closures.

A word's untyped parameters are compile-time parameters (§10.2), and a word may end with a rest requirement `..args` (§10.8). The same holds for named functions: `function T:m(n: U32): Unit ... end` defines a method word on struct `T`, and `local function f(n: U32): U32 ... end` a word that may name itself.

## 3. Words

The language distinguishes **host computation** from **native computation**, but both are written in familiar Lua syntax.

### 3.1 Ordinary Lua

```lua
local make_multiplier =: k
    return do(x: U32): U32 =
    x * k
end

local double = make_multiplier 2
local triple = make_multiplier 3
```

`make_multiplier` is an ordinary Lua closure. It executes inside LuaJIT.

The returned typed lambdas are native words. The value `k` is captured as a compile-time constant.

### 3.2 Native typed words

```lua
local add = do(a: U32, b: U32): U32 =
a + b
```

The typed lambda constructs a native word with two typed requirements. Its body describes operations in the native type system. A word may be applied to known values, dynamic values, or a mixture of both.

### 3.3 Type annotations identify native semantics

Typing does not automatically mean runtime execution. A typed computation can be completely evaluated during compilation; a typed computation with unknown inputs is partly evaluated, leaving only the dynamic remainder.

> **Types determine native semantics. Knownness determines binding time.**

### 3.4 The word model

A native word contains:

```lua
Word = {
    identity = ...,
    requirements = ...,
    result = ...,
    body = ...,
    supplied = ...,
}
```

This is a conceptual description, not a required object layout.

A word's `body` is a Lua closure produced from the typed body. That closure expresses native computation through staged operations. Its captures are ordinary Lua upvalues.

Its identity is stable across aliases and partial applications.

### 3.5 Autocurrying

```lua
local affine = do(
    a: U32,
    b: U32,
    x: U32
): U32 = a * x + b

local transform = affine(4, 3)
```

The first application supplies two requirements. The word is not saturated, so the result is a word with the static bindings `a = 4`, `b = 3` and the remaining requirement `x: U32`.

No runtime closure is constructed.

### 3.6 Saturated specialization

```lua
local use = do(x: U32): U32 =
affine(4, 3, x)
```

The call to `affine` is saturated, with `a` and `b` known. Application evaluates `affine`'s body with those arguments:

**Every saturated application uses all known arguments, not only those previously captured by partial application.**

```c
uint32_t use(uint32_t x) {
    return 4u * x + 3u;
}
```

### 3.7 Fully known execution

```lua
local answer = affine(4, 3, 10)
```

Applied from host code with every argument known, the body is evaluated entirely at compile time and produces `Known(U32, 43)`. The result remains a typed known value inside the compiler rather than silently losing its native type; `host(answer)` returns the Lua number.

Applying a word from host code with an argument that is not known is an error: there is no native function for the dynamic remainder to live in.

### 3.8 Partial application rules

- Supplying fewer than the remaining requirements produces a word only when the supplied arguments are static (known scalars, or fully known struct values). References are never static.
- A saturated application evaluates the body (architecture §5).
- A dynamic argument cannot be bound into an incomplete word.
- Overapplication is accepted when the result is itself callable: `f(a, b)(c)`.
- Arguments are coerced to the requirement's type at application: a Lua literal takes the requirement's type (with a range check), a place is read, and a `Ref T` requirement takes a place of type `T` by reference.

### 3.9 `call`: a function boundary at one site

`call` before an application makes that application a real C call: a residual
function, specialized on the word, its compile-time parameters and the arguments
known at the site, and shared by every `call` with the same key. It takes the next
application — `call f(x)`, `call m:put(k, v)`, `call f a b` — in a statement or an
expression. `call(x)` is an ordinary application of a binding named `call`: the
keyword counts only before a name on the same line.

It never changes what the program means, only the shape of the C. Two consequences
follow:

* **At compile time it is ignored**, because there is no function to call from: a
  word that uses `call` internally still runs in place on known inputs, so
  `host(hash.sip24(...))` works.
* **`return call f(x)` returns the call**; it is not a tail jump.

`call` needs a native word. An untyped Lua function is an error, and a foreign
function is already a call. Borrows cross a `call` under the callee's derived
summary (§9.7); a foreign or indirect call receives none, since nothing describes
what it keeps.
The boundary is the programmer's; [the architecture]
(architecture.md#57-call-a-function-boundary-at-one-site) says what it costs, what
`nua size` reports, and where the libraries put one.

### 3.10 Named compile-time tests and assertions

A test is ordinary computation during program construction, with a name attached
for diagnostics. Put it beside the word it tests:

```lua
local add = do(a: U32, b: U32): U32 = a + b

test "addition" do(): Unit
    assert(add 2 2 == 4)
    assert(add 40 2 == 42)
end
```

`test` takes a name known as text and a body callable without arguments. It calls
the body immediately. A failed assertion or other error stops compilation, with
the test name and the underlying diagnostic. Nested blocks add their names to the
failure context. Returning a value, including `false`, does not itself assert
anything; assertions are explicit.

There is no test registry, runner, test mode or residual test entry point. Tests
run when reached while evaluating a module, under the ordinary `require` cache
rules (§2.1). Unloaded modules have not had their tests run. Named blocks cannot
be deferred into residual code. `nua check program.nua` evaluates them as part of
ordinary compilation, as do C emission, `build`, `run` and library loading.

The body uses the ordinary lambda rules (§2.5). `do(): Unit` is a native word:
comparisons, local mutation, loops and callbacks are staged, and must finish with
no runtime work. A plain `do ... end` body is Lua, not an implicitly typed test
language; use `host` to inspect native results there, or assert a known native
`Bool` returned by a word. Existing compile-time restrictions still apply:
foreign effects, runtime-only storage and unknown inputs are not made executable
by wrapping them in a test. There is no automatic native compilation or execution
of residual work. Host Lua is not sandboxed.

`assert(condition, ...)` is Lua's assertion extended to native conditions:

* Host conditions keep Lua truthiness and assertion behavior, including returning
  all supplied arguments on success.
* A native condition must be a known `Bool`. Known false raises an assertion
  error; an unknown `Bool` is a compile-time error, not a residual trap. Other
  native types are rejected as conditions. On success, the original native
  condition and the remaining arguments are returned.
* An optional message explains failure. Native assertion failures include the
  source location and active specialization trail.

The same assertion rules apply outside named blocks. A passing compile-time test
checks its examples under native semantics; it does not prove behavior for all
runtime inputs, backend correctness, task scheduling or foreign interactions.
Those need explicit differential, native or integration checks outside this
compile-time assertion mechanism.

## 4. Typed control flow

### 4.1 What the translation stages

Lua cannot overload:

- comparisons (results coerced to booleans; `__eq` between tables only),
- conditions (they need a concrete truth value),
- `and`, `or` and `not`,
- local assignment,
- `return` (it exits the actual Lua function).

A typed body is therefore parsed — a recursive-descent parser with Lua's precedence over Mua's tokens — and translated:

| Source | Staged form |
|---|---|
| `a < b`, `a == b`, ... | `stage.lt(a, b)`, `stage.eq(a, b)`, ... |
| `a and b`, `a or b` | `stage.and_(a, function() return b end)` |
| `not a` | `stage.not_(a)` |
| `if c then A else B end` | `stage.if_(c, function() A end, function() B end)` |
| `while c do B end` | `stage.while_(function() return c end, function() B end)` (a loop, §6.3) |
| `for i: T = a, b do B end` | `stage.for_(T, a, b, step, function(i) B end)` (a loop, §6.3) |
| `break`, `continue` | `stage.loop_break()`, `stage.loop_continue()` |
| `local y: T = e` | `local y = stage.decl(T, e)` |
| `y = e` (typed `y`) | `stage.set(y, e)` |
| `obj.f = e` | `stage.setindex(obj, "f", e)` |
| `local a = e` | `local a = stage.bind(e)` |
| `return e` | `stage.ret(e)`, then leave the closure |
| `return f(args)` | `stage.tail(f, args)`: a tail call (§6.2) |
| `do(x) ... end` (untyped) | `stage.callback(...)`: evaluated in place (§10.1) |
| `f(a)(b)`, `f(a) do ... end` | `stage.chain(f, ...)`: a saturating chain (§10.4) |
| a free name, a bare call or an assignment in an opened region | resolved against the opened contexts (§10.5) |
| `..e`, `T { ..p, x = 1 }` | `stage.expand`, `stage.keyed` (§10.7, §10.8) |
| `oneof { ... }`, `s { alt = handler, ... }` | `stage.oneof`, matching (§11) |
| `p[i]`, `s[i]`, `Ptr(place)`, `Slice(p, n)` | element places and checked reads (§12) |

Arithmetic, calls, field access and constructors stay ordinary Lua expressions; metamethods handle them.

Every staged operation also accepts host values with host semantics: `stage.lt(1, 2)` is `true`, and `stage.and_` keeps Lua's value semantics for host operands. So the same translated body serves generation-time code and native code.

### 4.2 Native conditionals

```lua
local choose = do(
    enabled: Bool,
    k: U32,
    x: U32
): U32

    if enabled then
        return x * k
    end

    return x + k
end
```

The binding time of a condition decides what happens:

- **A host value** (a Lua boolean, a number, a table): plain Lua control flow. Nothing is speculative.
- **A known `Bool`**: only the selected branch is evaluated.
- **A dynamic `Bool`**: both branches are evaluated, each against its own copy of the abstract state, and a residual `if` is emitted.

A native condition must have type `Bool`; native values have no truthiness.

After a branch returns, its path is dead. A conditional whose branches are all dead leaves the rest of the enclosing body dead, and the translation stops evaluating it.

#### Known condition

```lua
local times8 = choose(true, 8)
```

```c
uint32_t times8(uint32_t x) {
    return x * 8u;
}
```

#### Known complete invocation

```lua
local answer = choose(true, 8, 7)  -- Known(U32, 56)
```

#### Unknown condition

```lua
local use = do(flag: Bool, x: U32): U32
    return choose(flag, 8, x)
end
```

```c
uint32_t use(bool flag, uint32_t x) {
    if (flag) {
        return x * 8u;
    }
    return x + 8u;
}
```

`choose` was evaluated in place. Its returns jumped to the end of its application and were then turned into direct returns, because the result was returned immediately (architecture §6.2).

### 4.3 Branch-local state

```lua
local f = do(flag: Bool, x: U32): U32
    local y = x

    if flag then
        y = y * 2
    else
        y = y + 1
    end

    return y
end
```

When `flag` is dynamic, both branches are residualized, each against its own state. At the join, `y` differs between the branches, so each branch writes its pending value (§5.3) and `y` becomes dynamic:

```c
uint32_t f(bool flag, uint32_t x) {
    uint32_t y;
    if (flag) {
        y = x * 2u;
    } else {
        y = x + 1u;
    }
    return y;
}
```

The initial `y = x` never reaches storage: it was pending, and both branches overwrote it.

### 4.4 Boolean operators

`and` and `or` keep short-circuit semantics through a delayed right-hand closure.

- With a known left operand, the right side is evaluated only if the result depends on it.
- With a dynamic left operand, the right side is first evaluated speculatively. If it performs no effects and changes no state, the result is the residual expression `a && b`. Otherwise a real conditional is built into a `Bool` local, so the effect happens only on the path that reaches it.

### 4.5 The staging discipline

Typed bodies must be deterministic and stage-safe: the evaluator may run a closure more than once (both branches of a dynamic condition, a round that is rolled back and redone in general form, an application undone to make a recursive key a function). Therefore:

- A typed body can assign only bindings it declares. Assigning a variable declared outside it (a host upvalue or global) is rejected when the body is translated.
- Rebinding a host binding declared outside the current branch is an error when that branch's condition is dynamic, or inside the body of a residual loop (§5.6).
- Mutating a host table from inside a dynamic branch or a residual loop is an error.
- Arbitrary Lua I/O and opaque FFI effects belong in host code, outside typed bodies.

These are precise rules, checked where the problem can occur, not a blanket ban: host control flow and known branches may rebind host bindings freely.

## 5. Native state

The evaluator distinguishes **values** from **addressable places**.

### 5.1 Local types can be inferred

```lua
local f = do(x: U32): U32
    local k = 4
    local y = x * k

    return y + 1
end
```

`k` is a host number. `y` infers `U32` from its initializer and is a mutable native place, just as with `local y: U32 = x * k`. Inference depends on the initializer's native type, not whether its value is known. Lazy stores still eliminate unnecessary C variables:

```c
uint32_t unannotated(uint32_t x) {
    return x * 4u + 1u;
}
```

Inside staged bodies, `local name = expression` infers native storage whenever the initializer can inhabit a native local. Constructors need no repeated annotation: `local p = Point { x = 1, y = 2 }`, `local count = U32 0`, and `local out = Text {}`. Assignments keep the inferred type, including inside runtime branches and loops. Multiple locals can infer independently; explicit and inferred annotations can be mixed.

Plain Lua values remain host bindings: `local k = 4` does not invent a native integer type. An annotation is still needed to select a different type or declare uninitialized native storage. A later assignment does not retroactively infer a host binding's type. Outside staged evaluation, ordinary Lua bindings are unchanged.

Initializing from a native place takes its value at that point (§5.5), not an alias. References retain write-through behavior. Borrowed views and existing resizable storage retain their existing alias and lifetime rules: inference does not copy them into new storage. Fresh resizable constructors initialize their inferred storage in place.

### 5.2 Typed locals are places

```lua
local f = do(x: U32): U32
    local y = x
    y = y + 1
    return y
end
```

`y` denotes an addressable native place, assignment becomes a staged store, and the abstract state tracks the place's current value:

```c
uint32_t typed_local(uint32_t x) {
    return x + 1u;
}
```

Parameters are immutable values. To modify one, copy it into a typed local.

### 5.3 Lazy stores

For each tracked place the abstract state holds one of:

```text
pending(v)        the value is v; storage need not hold it yet
materialized(n)   storage holds the value (version n); reads read storage
uninitialized     declared, not yet written
```

A store is **pending** when its value depends only on immutable leaves — constants, parameters, temporaries, loop variables — and is small. Otherwise it is emitted at once and the place becomes materialized with a new version.

A pending value is written to storage only when something needs storage to hold it:

- a join where the paths disagree (each path writes its own value),
- entry to a residual loop that writes the place, and every back edge,
- an address that leaves the evaluator (a `Ref` passed to a materialized function or a foreign call),
- a return that jumps out of an inlined application.

Reading a pending place returns its value directly, so private computation through places costs nothing. Reading an uninitialized place is an error.

### 5.4 Structs are tracked field by field

A typed local of struct type is a set of field places, each tracked on its own. A struct value is an aggregate of field values, and a struct constructor stores field by field. A local struct that never has its address taken and is never read as a whole needs no storage at all; this is how `NumberBox` disappears in architecture §10.2.

A struct is materialized as a whole only when C needs the whole: passing it by value to a materialized function, for instance, reads as the place itself when all its fields are in storage, and as a compound literal otherwise.

### 5.5 Snapshots

```lua
local snapshot = do(x: U32): U32
    local y: U32 = x * 3
    if x > 10 then
        y = y + 1
    end
    local a = y
    y = y * 2
    return a + y
end
```

`local a = y` infers a separate `U32` place initialized with `y`'s value. `y` is in storage at that point (it differs between the branches), so initialization snapshots that read. Later writes to `y` do not change `a`:

```c
uint32_t snapshot(uint32_t x) {
    uint32_t y;
    if (x > 10u) {
        y = x * 3u + 1u;
    } else {
        y = x * 3u;
    }
    uint32_t a = y;
    y = y * 2u;
    return a + y;
}
```

If `y` is still a pending value, the inferred local can also remain pending without a C variable. Arguments of inlined applications use lazy snapshots: `counter:add(i)` reads `i` directly unless the callee writes `i` first.

Reads through pointers (untracked storage) are snapshotted at once. As a safety net, every read of a tracked place carries the place's version; a residual statement that would use a read older than the place's current contents is rejected rather than emitted.

### 5.6 Host rebinding

Host bindings may be rebound in generation-time code. Inferred native locals are places, not host bindings. Inside a body:

- rebinding a binding declared **outside a dynamic branch** from inside it is an error: both branches are evaluated, so the Lua variable would end up holding the second branch's value;
- rebinding a binding declared **outside a loop** from its body is an error once the loop is residual: the round may be rolled back and redone, and a Lua variable cannot carry runtime state. Rounds that run at compile time may rebind freely.

Native mutation that must survive such constructs uses a typed place. Known branches and host control flow are not speculative, and rebinding there is fine.

### 5.7 Abstract native state

```text
AbstractState:
    tracked place → pending(v) | materialized(version) | uninitialized
```

Tracked places are typed locals and their fields, while no address of them has escaped. A place whose address leaves the evaluator — passed to a materialized function, or to foreign code — is materialized and becomes ordinary, untracked storage from then on. Places reached through pointers are never tracked.

Unknown branches join their continuing states. Returns that jump out of an inlined application join at its end. A residual loop's state is its parameters (§6.4).

The evaluator performs partial evaluation of local native state without implementing a general-purpose C heap.

## 6. Loops are tail recursion

There is one iteration mechanism: **tail recursion**. `while` and typed `for` are sugar for anonymous tail-recursive loops, and generation-time iteration is ordinary Lua.

### 6.1 Generation-time loops

An untyped `for` is ordinary Lua and runs while the word is being constructed or evaluated:

```lua
local make_sum =: n
    return do(x: U32): U32
        local total = x
        for i = 1, n do
            total = total + i
        end
        return total
    end
end

local add6 = make_sum 3
```

```c
uint32_t add6(uint32_t x) {
    return x + 1u + 2u + 3u;
}
```

Its bounds must be known (host numbers or known integers); a dynamic bound is an error that points to the native form.

### 6.2 Tail calls

`return f(args)` in a word is a **tail call**. Applying a word evaluates its body in place (architecture §5), so a tail call that re-enters the same word with the same *shape* — the same pattern of known and dynamic arguments — is a round of a loop. What happens to it follows one rule:

> **A tail re-entry runs at compile time for as long as each round stays entirely known: no residual statement, and every place it writes still holds a known value. Otherwise the known arguments that changed are generalized, and the re-entry becomes a jump.**

Typed bodies are deterministic and stage-safe, so the round that failed the test can be rolled back and evaluated again in the more general form. Rounds that stayed known before it are kept: their work is done at compile time.

```lua
local function count_down(k: U32, x: U32): U32
    if x == 0 then return k end
    return count_down (k + 1) (x - 1)
end
local walk = do(x: U32): U32 = count_down 0 x
```

The test `x == 0` is dynamic, so the first round is not known; `k`, the known argument that changed (0 → 1), is generalized. `count_down` re-enters only in tail position, so it does not become a function at all: its application turns into a loop in place, with one variable per dynamic parameter:

```c
uint32_t walk(uint32_t x) {
    uint32_t k = 0u;
    uint32_t x2 = x;
    for (;;) {
        if (x2 == 0u) {
            return k;
        }
        x2 = x2 - 1u;
        k = k + 1u;
    }
}
```

The parameters are assigned all at once; a temporary appears only where one new value still needs another variable's old value (a swap).

A word that also re-enters in non-tail position becomes a C function (architecture §5.3), and its tail self-calls become jumps to its top:

```lua
local function gcd(a: U32, b: U32): U32
    if b == 0 then return a end
    return gcd b (a % b)
end
export gcd
```

```c
uint32_t gcd(uint32_t a, uint32_t b) {
    uint32_t t;
    for (;;) {
        if (b == 0u) {
            return a;
        }
        t = a;
        a = b;
        b = t % b;
    }
}
```

Mutual tail recursion forms one loop: the other word is evaluated into each round.

### 6.3 Loops

A loop is a tail-recursive *join point*: it has parameters and rounds like a word, but it is not a word. A `return` inside a loop returns from the enclosing word, `break` leaves the loop, and `continue` starts the next round.

`while c do body end` is the loop

```text
loop():  if c then body; next() else exit end
```

and `for i: T = lo, hi, step do body end` is

```text
if lo <= hi then
    loop(i = lo):  body; if i is the last value then exit else next(i + step)
end
```

where "the last value" is `i == hi` for a step of 1 or -1, and `(UT)hi - (UT)i < step`
in the unsigned type otherwise. The limit is tested after the body, so the variable never steps past it: no wraparound at the edges of the type. The limit is evaluated once.

Loop rounds follow the rule of §6.2. A loop whose control and carried state stay known runs at compile time:

```lua
local triangular = do(n: U32): U32
    local total: U32 = 0
    for i: U32 = 1, n do
        total = total + i
    end
    return total
end

local fifteen = triangular 5  -- Known(U32, 15)
```

With an unknown `n`, the first round is not known and the loop is residualized:

```lua
local runtime_sum = do(n: U32): U32 =
triangular n
```

```c
uint32_t runtime_sum(uint32_t n) {
    uint32_t i;
    uint32_t total = 0u;
    if (1u <= n) {
        i = 1u;
        for (;;) {
            total = total + i;
            if (i == n) break;
            i = i + 1u;
        }
    }
    return total;
}
```

`runtime_sum(UINT32_MAX)` terminates.

A loop whose rounds turn dynamic part way keeps the known rounds before it:

```lua
local mixed_loop = do(x: U32): U32
    local acc: U32 = 1
    for i: U32 = 1, 4 do
        if i == 3 then acc = acc + x else acc = acc * 2 end
    end
    return acc
end
```

```c
uint32_t mixed_loop(uint32_t x) {
    uint32_t i = 3u;
    uint32_t acc = 4u;
    for (;;) {
        if (i == 3u) {
            acc = acc + x;
        } else {
            acc = acc * 2u;
        }
        if (i == 4u) break;
        i = i + 1u;
    }
    return acc;
}
```

`break` and `continue` are the loop's exit and next:

```lua
local sum_until = do(x: U32): U32
    local total: U32 = 0
    local i: U32 = 0
    while true do
        i = i + 1
        if i > x then break end
        if i == 3 then continue end
        total = total + i
    end
    return total
end
```

```c
uint32_t sum_until(uint32_t x) {
    uint32_t i = 0u;
    uint32_t total = 0u;
    for (;;) {
        i = i + 1u;
        if (i > x) break;
        if (i == 3u) continue;
        total = total + i;
    }
    return total;
}
```

A `while` with a host condition runs at compile time as long as its rounds are known, which makes it a generation-time loop; a host binding it rebinds cannot be carried into a residual loop (§5.6).

### 6.4 A loop's state is explicit

A loop is sugar for a tail-recursive word, and a word receives its state as parameters. The sugar does the same: **every typed local of the enclosing word that a loop mentions becomes a parameter of the loop.** In `sum_until`, `total` and `i` are its state.

- Each round works on its own copies, under the same names.
- `next` (a round ending, or `continue`) passes the copies to the next round.
- Leaving the loop (`break`, or the condition failing) stores them back into the word's locals, all at once.
- A `return` inside the loop leaves the word; nothing needs storing back.

So a residual loop's state is exactly its parameters, and no hidden iteration is needed to discover what it carries. In a residual loop a state variable is its own local: nothing else reads it while the loop runs, so the C has one variable, not a copy (`total` in `runtime_sum`).

```lua
local Pair = struct { a: U32, b: U32 }
local fib_pair = do(n: U32): U32
    local p = Pair { a = 0, b = 1 }
    for i: U32 = 1, n do
        p = Pair { a = p.b, b = p.a + p.b }
    end
    return p.a * 1000 + p.b
end
```

```c
uint32_t fib_pair(uint32_t n) {
    Pair p;
    uint32_t i;
    if (1u <= n) {
        i = 1u;
        p = (Pair){ .a = 0u, .b = 1u };
        for (;;) {
            p = (Pair){ .a = p.b, .b = p.a + p.b };
            if (i == n) break;
            i = i + 1u;
        }
    } else {
        p.a = 0u;
        p.b = 1u;
    }
    return p.a * 1000u + p.b;
}
```

**Ordinary records are carried field by field.** A record field that changes between rounds becomes runtime state; an unchanged known field stays known inside the loop and after it. Nested records follow the same rule.

```lua
local Panel = struct { gap: U32, padding: U32, count: U32 }
local panel_extent = do(n: U32): U32
    local panel = Panel { gap = 12, padding = 24, count = 0 }
    local i: U32 = 0
    while i < n do
        panel.count = panel.count + 1
        i = i + 1
    end
    return panel.padding * 2 + panel.count * panel.gap
end
```

```c
uint32_t panel_extent(uint32_t n) {
    Panel panel;
    uint32_t i = 0u;
    panel.count = 0u;
    for (;;) {
        if (i >= n) break;
        panel.count = panel.count + 1u;
        i = i + 1u;
    }
    return 48u + panel.count * 12u;
}
```

**Exits count too.** If a field changes only before `break`, it still needs runtime storage when the possible exits disagree. Its initial value must be available on the condition-false exit, including when the loop executes zero times. Agreement on backedges alone is not sufficient.

Known fields are materialized when storage is needed, for example when the record's address crosses a function boundary (§5.3). Existing reference, ownership, atomic, and string rules still apply; field-wise loop generalization does not bypass them.

A write through a reference taken before the loop, or through a captured local, can change state that the loop's syntax does not name. The outermost affected loop rolls its round back and adopts an initialized, unescaped ordinary local owned by the same native function as loop state. Its unchanged known fields stay known; adoption adds no callback argument and preserves the original place, so direct writes and reference aliases see the same state. If no invariant remains, or the local's address crosses a native boundary, it becomes ordinary memory. Storage is initialized before the affected loop, not on every round. Atomics, owning records and foreign locals retain their existing contracts.

### 6.5 Where unrolling comes from

Non-tail recursion under known control keeps unfolding, as any evaluation does:

```lua
local function pow(x: U32, n: U32): U32
    if n == 0 then return 1 end
    return x * pow x (n - 1)
end
local cube = do(x: U32): U32 = pow x 3
```

```c
uint32_t cube(uint32_t x) {
    return x * (x * x);
}
```

Under dynamic control, a non-tail re-entry with other known arguments generalizes the ones that changed, exactly as a tail re-entry does; it then re-enters with the same key and becomes a function (architecture §5). Deliberate unrolling of statements is the generation-time loop's job (§6.1).

## 7. Types and native semantics

Native types are compile-time Lua values: `U8 U16 U32 U64 I8 I16 I32 I64 F32 F64
Bool Unit`; the constructors `Ref T`, `Store T`, `Id T`, `Grow T`, `Ptr T`, `Slice T`
(§12), `Array(T, n)` (§13), `Chars(n)`, `Str` and `Text` (§14), `Atomic T` (§19),
`Chan T`, `Pool T` and `Slot T` (§20) and `Fn(params): ret` (§21); the `Map` and
`Map(Str, V)` of §15; and structs, sums (§11) and library-defined types (§16).

### 7.1 C semantics

A known operation must produce the result its valid C counterpart produces:

- **8- and 16-bit integers** compute in 32 bits and wrap to their width after every operation. The C backend makes this explicit with casts, so C's integer promotions can never introduce undefined behaviour (`u16 * u16` would overflow `int`).
- **32-bit integers** compute exactly (products of unsigned values in 64-bit) and wrap if unsigned.
- **64-bit integers** are held as LuaJIT `int64_t`/`uint64_t` cdata, which wrap as C does.
- **F32** results are rounded through a C `float` after every operation; F64 is a Lua double.
- **Undefined behaviour is rejected**, never folded: signed overflow, division or remainder by zero, `MIN / -1`, shifts by the width or more, out-of-range float-to-integer conversion. The error names the operation and the source line.
- Division and remainder truncate toward zero, as in C (Lua's `%` floors; the folder uses C's rule).

### 7.2 Literals and conversions

A Lua number literal takes the type of the native operand it meets, with a range check (`a + 300` is an error when `a` is a `U8`). Two typed operands of different types do not meet: convert explicitly with `U32(x)`, which follows C's conversion rules. Integer literals beyond 2^53 are written in LuaJIT's 64-bit form, `6364136223846793005ULL`.

### 7.3 FFI

LuaJIT FFI provides the 64-bit and float representations. It is not the source of truth for native semantics; the folding rules above are.

### 7.4 Compile-time GC

LuaJIT's GC owns compiler objects: types, words, closures, staged values, command graphs and abstract states. The generated program does not inherit it.

## 8. Methods and `self`

```lua
local Counter = struct with
    value: U32
end

function Counter:add(n: U32): Unit
    self.value = self.value + n
end

function Counter:get(): U32
    return self.value
end
```

A method is a native word attached to a struct type, with an implicit first requirement `self: Ref T`. A method name may not equal a field name.

The receiver is passed by reference. Calling a method on a struct value rather than a place gives it a temporary place.

Methods specialize like any word:

```lua
local count3 = do(a: U32, b: U32, c: U32): U32
    local counter = Counter { value = 0 }
    counter:add a
    counter:add b
    counter:add c
    return counter:get()
end
```

```c
uint32_t count3(uint32_t a, uint32_t b, uint32_t c) {
    return a + b + c;
}
```

Materialized, a mutable method takes an explicit receiver pointer:

```lua
export Counter.add as "counter_add"
```

```c
void counter_add(Counter *self, uint32_t n) {
    self->value = self->value + n;
}
```

No vtable, inheritance, hidden header or runtime method registry is involved.

A reference denotes its place, as a C++ reference does: it reads its target wherever a value is expected, and assigning to a name that holds one writes the target. A reference is never re-pointed.

```lua
local bump = do(r: Ref U32, k: U32): Unit
    r = r + k  -- writes through r; parameters are otherwise immutable
end
```

## 9. Owned storage and references

**Memory management happens after residualization**, on the specialized program that remains.

Native memory has exactly two ownership forms:

1. **A lexical scope owns a value.**
2. **A managed store owns an object slot.**

References and IDs never own memory. There is no `Rc`, tracing GC or implicit heap promotion.

### 9.1 Fixed-size values

Scalars, structs without owner fields, references and IDs are fixed-size. They live in registers or the C stack.

### 9.2 Owners

`Grow T`, `Array T`, `Store T`, `Map(K, V)` (including `Map(Str, V)`) and `Text` are owners: they have storage of their own on a data stack. A struct holding owner fields, any number of them and in any order, is an owner too.

- **Created in place.** An owner is constructed where it lives: `local xs = Grow(U32) {}`, a field of an owner struct, or the place a word's owner result is built in. Declared without a value, it starts empty: `local s: Store Node`. An owner struct's omitted owner fields start empty and its omitted value fields start zeroed: `Graph {}`, `Graph { name = Chars(32) "roads" }`.
- **One data stack each.** Creation takes the lowest free data-stack indices of the function: one per stack of the owner, consecutive (an owner holding owners has an arena for each owner position, §9.13). An owner occupies the top of its stack, and no other live owner of the function shares it. A recursion is the exception that keeps the number of stacks fixed: its levels share stack indices, each level's owners above the previous level's (§9.10).
- **Moved at its last use.** Using a named owner as a value moves it: assigning it, passing it to an owner-typed parameter, returning it, or giving it to a field (`Graph { .nodes, .edges }`). Nothing is copied: its storage stays where it is, and the destination takes over releasing it. A move into an element copies the bytes once into the container's arenas (§9.13). A later use is rejected: `'nodes' was moved into 'g.nodes'`. A move on some paths only is exact: the paths that do not move it release it before they join.
- **Moved out through a `Ref` parameter.** A word may move an owner out of a `Ref` argument: in place, the caller's place is moved; compiled on its own (`call`, recursion), its summary says which part of which argument it moves, and the caller's place counts as moved after the call. An exported word may not. Through a `Ref` whose target is not known while compiling (a field, an element, a local chosen at run time), moving out is rejected.
- **Replaced by assignment.** Assigning a new owner to an owner place ends the old one there: its storage returns, and borrows of it end (`'g' was replaced`).
- **Copied only by `copy`.** `copy x` builds a duplicate in its destination: owner structs deeply (owner fields copied, value fields as values), a `Store` with the same token (its `Id`s name the same entities in the copy). `copy` of a `Str` builds a `Text`, of a `Slice T` an `Array T`; `copy` of a value is the value.
- **Passed.** A parameter of an owner type owns its argument: a constructor or call result built in place, a moved owner, or a copy. `Ref T` lends the owner for reading and writing, including growth. Where a `Slice T` or a `Str` is expected, an owner lends its elements read-only with no marker (`total xs`); a `Slice.mut T` takes them for writing, marked at the call: `scale(Ref xs, 2)`.
- **Returned like a value.** A word returning an owner builds it where the caller keeps it: `local xs = squares 10`. Evaluated in place, its returns move into the caller's place. Compiled on its own, it receives its destination: result stacks reserved by the caller, one for each owner allocation the word may return (§9.10).
- **Released when its life ends.** At the latest when the residual block that holds it ends; exactly where a move on another path or a replacement ends it. Its stack's top returns to where it began.
- **Runtime only.** Creating one at compile time is an error. C cannot hand over or take over an owner: an exported word takes `Ref T` or a `Slice`.

### 9.3 Variable-size values

`Array(T, n)` with `n` known while compiling is a value (§13). With `n` known only when the program runs, `Array(T, n) {}` builds the owner `Array T`: `n` zeroed elements, a length fixed when built, indexed and borrowed like a `Grow` (`a[i]`, `a.length`, `a:all()`, `a:sub(i, j)`), with no `push` and no `clear`. `copy` of a `Slice T` builds one.

### 9.4 Borrows

A borrow uses storage someone else owns and never owns it:

* `Ref T` borrows one addressable place.
* `Slice T` and `Str` view a run of elements: `g:all()` and `g:sub(a, b)` of a
  `Grow`, `out:str()` of a `Text`, `c:str()` of a `Chars(n)`, `a:slice()` of an
  array, and the lent view of `view_of` (§12.6).

Both may be held in typed locals, struct fields, sum payloads, array elements and
the elements of a `Store` or a `Grow`, under the lifetime rule (§9.5).

**Assigning to a `Ref`** follows the type of the right-hand side. A `Ref` local,
field or element is rebound by a reference and written through by a value of the
referred type:

```lua
local Holder = struct { r: Ref U32, n: U32 }
local holder = Holder { r = Ref a, n = 2 }
holder.r = holder.r + holder.n    -- writes a
holder.r = Ref b                  -- now refers to b
```

`Ref T` and `T` are different types, so the two never collide; a `Ref` parameter
keeps its meaning (`target = text` writes through). A place holding a reference
stands for its target wherever a place is used: `holder.r.field`, `r[i]`, `r:push v`.
A reference becoming data (stored in a field, an element, a local that becomes
memory) takes its target's address, so the target lives in memory from then on.

The compiler records, for every borrow, the owners it depends on. The program
never writes that down: there is no lifetime syntax.

### 9.5 The lifetime rule

> **A borrow must not outlive the owner it borrows from.**

The rule applies wherever a borrow could escape:

* **Storing.** A borrow may be stored only in a place its owners outlive: a local
  declared after the owner or in the owner's own scope. Storing a view of a word's
  local into the caller's storage is rejected
  (`a borrow of 'bytes' cannot be stored in 'kept', which outlives it`).
* **Returning.** A word may return a borrow of what it received, never of its own
  local (`word first returns a borrow of its own local 'g', which ends with it`):
  return the owner's contents as an owned copy instead.
* **Branches and joins.** A value that may come from several borrows depends on
  all of them.
* **Use.** A borrow used after its owner ended is rejected where it is used.

```lua
local identity = do(r: Ref U32): Ref U32 =
r
```

A Lua string literal is a `Str` of static data and borrows nothing that ends.
`Slice(p, n)` and raw pointers borrow nothing the compiler knows: they are the
programmer's contract (§12.5).

### 9.6 Containers, globals and tasks

An element of a `Store` or a `Grow` is a place of the container: a borrow stored
in it is checked against the container's owner, and a borrow of an element (`Ref
g[i]`, `g:all()`) borrows the container's contents, which `clear` ends. A global
outlives every owner, so it holds only borrows of static data or of other globals.
Values crossing a task boundary (spawn copies, channel messages) hold no borrow at
all (§20.5); a borrow stored in a map value is checked like any stored borrow (§15.1). Store an owned copy (`Chars(n)`, a
`Text`) or an `Id` instead. A long-lived relationship between entities is an `Id`
(§9.8).

### 9.7 Invalidation

Data stacks never move (§9.10), so growing invalidates nothing: a `Grow` or a
`Text` may grow while a borrow of it is live, and the borrow keeps the length it
was taken with. An owner inside an element is the exception: its bytes may move
when it grows (§9.13). Only freeing storage invalidates. `clear` ends every borrow of the
owner's contents taken so far (its views, references to its elements); borrows
taken afterwards are new. A reference to the owner itself (`Ref g`) survives:
the owner still exists. The check is made where a
borrow is used, so a borrow that is not used again is no obstacle:

```lua
local head = xs:sub(0, 3)
xs:push 99  -- fine: head stays valid
local first = head[0]
xs:clear  -- fine: head is not used again
```

Using `head` after the `clear` is rejected
(`a borrow of 'xs' is used after 'xs' was cleared`).

A function compiled on its own (`call`, recursion) is described by a summary
derived from its body: which arguments its result borrows from, and which
arguments it may clear. A call that may clear an owner ends that owner's borrows
at the call; a call that only reads or appends leaves them valid. A function still
being built, within a recursive cycle, is assumed to do both.

A store slot is addressed as a place, `s[id]`, whose address is recomputed and whose ID is checked at every use (§10.6). A removed slot is detected by its generation. A borrow of an element (`Ref s[id]`) ends at `s:remove`: the slot is reused, so a borrow used afterwards is rejected while compiling.

### 9.8 Managed stores and generational IDs

```lua
local Node = struct with
    value: U32
end

local Graph = struct with
    nodes: Store Node
end
```

| Operation | Meaning |
|---|---|
| `s:add(v)` | insert a copy of `v`; returns an `Id T` |
| `s:remove(id)` | remove the object; `false` if `id` is stale or foreign |
| `s:has(id)` | whether `id` identifies a live object of `s` |
| `s[id]` | the object, as a place: read it, assign it or its fields, pass it as a reference; every use checks `id` |
| `s.length` | the number of live objects |
| `a == b`, `a ~= b` | IDs compare by token, slot and generation |

All store operations are runtime effects: they always remain in the residual code.

### 9.9 ID semantics

An ID is a store token, a slot index and a generation. A checked lookup verifies all three plus occupancy, so an old ID never identifies a replacement object in a recycled slot. Generations start at 1 (a zeroed ID is never valid); a slot whose generation would wrap is retired instead of reused. Store tokens come from a 64-bit counter and are never reused.

### 9.10 Store ownership

A store's slots live on its data stack; its header (stack index, base offset, counters, token) lives in its place. A data stack is address space reserved once and committed as it is touched, so it never moves: growth bumps its top after one comparison against the reservation, and exceeding the reservation traps. The reservation is 64 GiB per stack for a thread and 1 GiB per stack for a task by default (`NUA_THREAD_STACK_BYTES`, `NUA_TASK_STACK_BYTES` when building the runtime); there are no guard pages.

### 9.11 Cyclic graphs

Graph edges contain IDs, not owning references:

```lua
local Edge = struct with
    from: Id Node
    to: Id Node
end
```

Cycles are ordinary relationships; they create no ownership cycles. Objects are removed explicitly or with their store.

### 9.12 Grow arrays

Every length is a `U64` (`g.length`, `s.length`, `a.length`, `c.length`, `m.length`), and an index may be any unsigned integer type, checked against it. Operations take any unsigned length where they take one from outside (`Slice(p, n)`, `view_of(p, n, body)`, `Array(T, n)`); the language converts nothing else implicitly, so arithmetic mixing a length with a `U32` converts one side explicitly: `U32 xs.length`.

`Grow T` supports `g:push(v)`, `g[i]` (a place, its index checked at every use), `g.length`, `g:all()` and `g:sub(i, j)` (borrowed slices, §9.4), `g:pop()` (the last element, removed; an empty `Grow` traps), `g:truncate(n)` (keep the first `n`; more than `g.length` traps) and `g:clear()`. `pop`, `truncate` and `clear` free the storage above the new end, so borrows of the contents end there. An element of a `Grow`, an `Array T`, a `Store` or an `Array(T, n)` may be any type that is not an atomic: scalars, records, sums, arrays, references, views, `Id`s, pointers, channels, pools and slots, and owners or values holding them (§9.13).

### 9.13 Owners inside owners

An owner may sit anywhere a value can: an element of a `Grow`, an `Array T`, a `Store` or an `Array(T, n)`, a field of such an element, a map value, a sum payload, a global (design memory.md §5.9, §5.10).

```lua
local Player = struct { score: U32, name: Text, items: Grow Item }
local lines = Grow(Text) {}
local players = Store(Player) {}
local names = Map(U64, Text) {}
local Doc = oneof { empty: Unit, text: Text }
```

- **Positions.** Each place in an owner's type where an owner sits is a position, with one data stack. A position under an element (of a container, of an `Array(T, n)`, a map value) is shared by every element there: it is that position's arena. `Grow Text` holds 2 stacks, `Store Player` 3, `Grow(Grow Text)` 3. The number is fixed while compiling, so a type that contains itself through an owner is rejected; a tree goes through `Id`s into a `Store` (§9.11).
- **Growth.** An owner inside an element grows within its capacity, at its arena's top when it ends there, or by moving its bytes to the top with doubled capacity. A top-level owner never moves.
- **Borrows.** Growing an owner inside an element ends the borrows of its contents (`a text in 'lines' grew, so its bytes may have moved`); when the compiler cannot tell two elements apart (unknown indices), the borrows of the contents of every element at that position. A word compiled on its own says so in its summary (`the call to append, which may grow or clear it`). Borrows of the elements themselves, and of top-level owners, are unaffected.
- **Moving in and out.** Storing a named owner into an element (`lines:push t`, `lines[i] = t`, `players[id].name = t`) copies its bytes once into the arenas and ends it; a constructor (`lines:push(Text {})`) builds the element where it lands. Moving an owner out of an element is rejected; `copy lines[i]` and `lines:pop()` (a new owner) are the ways out.
- **Reclaiming.** Removing, popping, truncating, clearing or replacing an element leaves its owners' bytes dead in the arenas. These operations, which already end borrows, compact an arena when its dead bytes reach its live bytes (and 4096), and compaction ends the borrows of the contents at the root's positions. A word that removes owners inside an argument's elements says so in its summary, and its caller compacts. `clear` of the outermost container empties every arena at once.
- **Elements one at a time.** A container whose elements hold owners offers no `all` or `sub`: a slice would read their headers as values.
- **`copy`** of a container is deep: every element's owners are built anew in the copy's arenas.
- **Sums.** A sum whose payload holds owners is an owner. Its alternatives share its stacks, and it keeps where they began. Its payload is matched by reference (`d { text = do(t: Ref Text) ... end, ... }`); a handler taking it by value is rejected. Assigning another variant ends the old payload. A payload given by a named owner is copied into the sum's stacks; one built by a constructor is built there.
- **Globals.** A global may be an owner (`global(Grow Text, { name = "journal" })`), with only a name. Its stacks are the first of the main thread's, reserved for it; it is set up at its first use, by the thread that uses it first, and a later use by another thread traps. A task may not use one (`a task cannot use the owner global 'journal'`). Trap recovery leaves it.
- **Maps.** A map may sit inside an element or a map value (`Map(U32, Map(U32, U32))`, `Grow(Map(Str, U32))`): each of its stacks (slots, index, keys) is a position. Its slots and keys grow like any owner inside an element, its index is rebuilt at its arena's top, and an insertion ends the borrows of its entries (`a map in 'outer' grew, so its entries may have moved`).
- **Not yet.** A sum holding owners as a global is rejected.

## 10. Activities, opening and spread

> **Entities own what persists. Activities own or borrow what is needed for a purpose. Words express what happens inside.**

An activity is a design role, not a mechanism: an activity word sets up a context, runs a body that opens it and speaks its verbs, and owns completion. It is written with ordinary words, callbacks and opening, and needs no activity type. The pattern comes from Let, where it structured mutation and bounded borrows without reference counting. Nua has no reference counting and no runtime closures at all, so the pattern is its natural shape for bounded mutable work.

The forms below follow Let's `spread.md`, adapted where Nua differs (noted).

### 10.1 Callbacks

An untyped lambda inside a typed body is a **callback**. It is evaluated in place, like a word: its control flow is staged, a `return` leaves only the callback, and its result type comes from its returns (the first return that needs storage fixes it). A callback never becomes a C function or a closure; it exists only while the program is being specialized.

```lua
local apply = do(f, x: U32): U32 = f x
local clamp_cb = do(x: U32): U32
    return apply: v
        if v > 10 then return v - 10 end
        return v
    end x + 1
end
```

```c
uint32_t clamp_cb(uint32_t x) {
    uint32_t r;
    if (x > 10u) {
        r = x - 10u;
        goto L1;
    }
    r = x;
L1:;
    return r + 1u;
}
```

A callback may assign the typed locals of its word (they are places), but not the untyped bindings of its word (§4.5).

### 10.2 Compile-time parameters

A native word may leave a parameter untyped. **An untyped parameter of a native word is a compile-time parameter**: its argument must be a Lua value or a known native value, and it is part of the specialization key (architecture §5). It is how a word receives a callback, a vocabulary table or a generator. Supplying a runtime value is an error. *(Let's unannotated parameters default to `Any`, a dynamic type; Nua's counterpart is compile-time, since Nua has no runtime dynamic values.)*

### 10.3 Activity words

```lua
local Document = struct { length: U32, cursor: U32, edits: U32 }
local Draft = struct { length: U32, cursor: U32, edits: U32 }

function Draft:insert(n: U32): Unit
    self.length = self.length + n
    self.cursor = self.cursor + n
    self.edits = self.edits + 1
end

function Draft:move_left(): Unit
    if self.cursor > 0 then
        self.cursor = self.cursor - 1
    end
end

-- work on a copy, commit at the end
local edit = do(document: Ref Document, body): Unit
    local draft = Draft { ..document }
    body(Ref draft)
    document = Document { ..draft }
end

local type_text = do(doc: Ref Document, n: U32): Unit
    edit doc:
        insert n
        move_left
        if cursor > 3 then
            insert 1
        end
    end
end
```

```c
void type_text(Document *doc, uint32_t n) {
    Draft draft;
    draft.length = doc->length;
    draft.cursor = doc->cursor;
    draft.edits = doc->edits;
    draft.length = draft.length + n;
    draft.cursor = draft.cursor + n;
    draft.edits = draft.edits + 1u;
    if (draft.cursor > 0u) {
        draft.cursor = draft.cursor - 1u;
    }
    if (draft.cursor > 3u) {
        draft.length = draft.length + 1u;
        draft.cursor = draft.cursor + 1u;
        draft.edits = draft.edits + 1u;
    }
    doc->length = draft.length;
    doc->cursor = draft.cursor;
    doc->edits = draft.edits;
}
```

The activity word controls setup and completion; the callback's `return` does not leave the activity; borrowed access cannot outlive its owner. When the entity is private, the activity disappears entirely:

```c
uint32_t fresh_length(uint32_t n) {
    return (n + 2u) * 100u + 2u;
}
```

An activity can own temporary state and return a result. Its body may open the home without naming it (`do(..)`):

```lua
local counting = do(body): U32
    local counting = Counting { count = 0 }
    body(Ref counting)
    return counting.count
end
local evens = do(n: U32): U32 =
counting:
    for i: U32 = 1, n do
        if i % 2 == 0 then
            tick
        end
    end
end
```

```c
uint32_t evens(uint32_t n) {
    Counting counting;
    uint32_t i;
    counting.count = 0u;
    if (1u <= n) {
        i = 1u;
        for (;;) {
            if (i % 2u == 0u) {
                counting.count = counting.count + 1u;
            }
            if (i == n) break;
            i = i + 1u;
        }
    }
    return counting.count;
}
```

(The loop writes the context through the opened reference, which no syntax of the loop shows, so `counting` becomes plain memory before the loop, §6.4.)

Temporary resizable state (a worklist, a change log) created in an activity takes a data stack and gives it back when the activity ends: activity scope is Goose scope.

### 10.4 Saturating chains

`edit(doc) do(draft..) ... end` is the application `edit(doc)(body)`. On its own, `edit(doc)` would be a partial application with a runtime argument, which §3.8 rejects. **A chain of applications on a word accumulates its arguments until the word is saturated**, as in Let; surplus arguments apply to the result. The same holds for method chains (`m:each do(k, v) ... end`) and for library functions with a declared arity. Any other Lua function applies each group in turn.

In a typed body, a native-word chain concatenates its argument groups before
applying the word. A rest requirement receives the remaining arguments from the
whole chain, not just its first group. Regrouping still has to preserve each
list's expansion rules and the separate trailing handler boundary (§11). Ordinary
host Lua calls keep their application groups; their parentheses cannot be removed
on the assumption that every callable is a native word.

### 10.5 Opening

The general rule is Mua's (Mua's syntax doc, §6: an opened Lua table introduces its string keys, under lexical shadowing). This section is what Nua adds: records, places, references and native boundaries.

Nua uses `..` to contribute bindings or values: postfix in opening declarations, prefix in keyed and ordered spreads, and prefix in a rest parameter. `(..)` reads the anonymous home. Infix `a .. b` keeps its concatenation semantics and precedence; for example, `f(a .. b)` passes one concatenated value, while `f(..args)` expands a pack. Ordinary Lua `...` varargs outside typed bodies are unchanged; `...` is not an alternative spelling for Nua opening or expansion.

| Form | Meaning |
|---|---|
| `do(ctx..)`, `do(ctx..: T)` | receive one argument, then open it |
| `do(..)`, `do(..: T)` | the same, without a name; `(..)` reads the home |
| `local ctx..` | open an existing binding |
| `local ctx.. = e` | evaluate once, bind, then open |

One parameter may be opened. What a context introduces:

| Context | Names introduced |
|---|---|
| a record value, place or reference | its field names, as live field places of the retained receiver |
| a Lua table (a vocabulary) | its string keys |

- **Open to work; bind to remember.** An introduced field name denotes the field's place: reading it reads the current value, assigning it stores to the field. `local before = cursor` takes the value at that point.
- **Methods stay attached.** Opening introduces no method names. An otherwise-unbound bare call inside an opened region uses the innermost receiver that has such a member; actual members win over lexical words; locally bound callables stay ordinary calls. `(name)(args)` bypasses the receiver. `call` uses the same resolution, then applies the native boundary to the resolved callable: an outer lexical word is not rejected merely because the call appears in an opened region.
- **Opening follows lexical shadowing.** Introduced names shadow earlier visible bindings, including names from earlier openings, program globals and the prelude. Later declarations and openings can shadow them in turn; leaving a scope restores the enclosing bindings. Initializers resolve names before the new binding is introduced. Opened record fields remain live places, not copied values. The receiver is retained independently of later bindings of its source name. Receiver-method lookup remains separate: methods are not introduced bindings, and locally bound callables remain ordinary calls.
- **An opened context cannot be assigned whole (`context-use`).**

#### Anonymous spread

When a context's name adds nothing, open it unnamed. Its fields are in scope, bare calls go to it, and `(..)` reads the home itself — including to pass it on explicitly with `(f)(.., other)`, which bypasses receiver insertion:

```lua
local squared = do(..: Vec): F64 = x * x + y * y

local session = do(..: Ref Terminal, lines: U32): U32
    draw lines
    (status)(.., 1)
    return width - drawn
end
```

```c
double squared(Vec vec) {
    return vec.x * vec.x + vec.y * vec.y;
}
```

```c
uint32_t session(Terminal *terminal, uint32_t lines) {
    terminal->drawn = terminal->drawn + lines;
    terminal->drawn = terminal->drawn + 1u;
    return terminal->width - terminal->drawn;
}
```

A materialized unnamed home is named after its type in C. A home read where none is opened is `context-required`.

#### Vocabularies

```lua
local units = { kilo = 1000, mega = 1000000 }
local to_base = do(k: U32, m: U32): U32
    local units..
    return k * kilo + m * mega
end
```

### 10.6 Addressing a store slot

`s[id]` is the slot as a place. Opened, its fields are live places too (§10.5):

```lua
local double_node = do(g: Ref Graph, id: Id Node): Unit
    local node.. = g.nodes[id]
    value = value * 2
    weight = weight + 1
end
```

```c
/* sketch */
void double_node(Graph *g, NodeId id) {
    Node *at = NodeStore_borrow(&g->nodes, id);
    at->value = at->value * 2u;
    at->weight = at->weight + 1u;
}
```

Every use is checked, as a slice checks its index, but uses that nothing separates share one check. The compiler keeps the address it found in a temporary and reuses it on the same path until something could change what the lookup would find:

* a structural change: `add`, `remove`, `push`, or a slot moving (`release`, a send);
* a call into a function compiled on its own, or into C;
* the start of a residual loop's round, the end of the loop, and the join after a branch.

Then the next use looks again. The C compiler cannot do this merging itself, because a store to an element may alias the store's header as far as it can tell. The lookup itself is inline: a few loads and compares, with the failure and the growth of the stack set out of line. Looking again is what makes an `Id` safe after a removal: the generation is checked at every use, so a stale `Id` never reaches a recycled slot. This replaces both a borrow checker for §9.7 and the borrow-by-scope activity of earlier versions.

### 10.7 Keyed spread

Spreading tables and `define` are Mua's (Mua's syntax doc, §5); records are Nua's:

```lua
local moved_x = do(p: Point, dx: I32): Point = Point { ..p, x = p.x + dx }
```

A spread contributes a record's data fields (from a value, place or reference); the result is ordinary construction. A spread of a compile-time table contributes its string keys, and when every spread is one, the result is a compile-time table: this is how vocabularies (for DSLs, and for any Lua code) are built and extended. `def` returns its argument, and `define` followed by entries and `end` is `def with … end`, so a definition reads as one:

```lua
local base = define
    add = do(a: U32, b: U32): U32 return a + b end
    scale = 2
end
local more = define
    ..base
    scale = 3
end
```

`{ ..base, extra = true }` works in plain Lua code too. The same rules apply to both forms: explicit fields override spread fields regardless of position; duplicate explicit fields are rejected; two spreads contributing the same field are rejected (`spread-overlap`), even if an explicit field overrides it; unknown fields are rejected, including overridden ones. All operands evaluate in source order.

### 10.8 Rest requirements, packs and ordered spread

A word may end its parameters with one unannotated rest requirement `..args`. Once the fixed requirements are supplied, the rest takes every remaining argument and the application is saturated. The components form a **pack**: a static length and components, second-class. Only three operations exist: `..args` contributes the components to an ordered list, `args.length` is the static length, and `args[i]` is a component (a static, in-range index, from 1). Passing, storing, returning or assigning a pack whole is rejected (`pack-use`); a bad index is `pack-index`.

```lua
local logged = do(f, ..args): U32
    log_call args.length
    return f(..args)
end
local use_logged = do(x: U32, y: U32): U32 = logged twice x + logged add3 x y 1
```

```c
uint32_t use_logged(uint32_t x, uint32_t y) {
    log_call(1u);
    log_call(3u);
    return x * 2u + (x + y + 1u);
}
```

A pack's shape is part of the specialization key, so each shape gets its own residual code; no runtime tuple or variadic call exists.

`..e` may appear at any position of an argument list, a return list or a binding initializer list. It contributes a pack's components, or the several results of a Lua call. Records do not expand positionally (`spread-source`); nor do Lua tables (runtime-length expansion is deferred). Items evaluate once, left to right. A word's `return ..args` must supply exactly one value.

### 10.9 `endall`

`endall` is Mua's (Mua's syntax doc, §4); in Nua the typed word is the function body it stops at.

```lua
local import_rows = do(doc: Ref Document, n: U32): Unit
    traced 1 do
    traced 2 do
    edit doc:
        insert n
    endall
    trace 9
end
```

`endall` closes **every open Nua block** (`do`, colon, `=:` and `with` blocks) back to the nearest enclosing Lua control block or word body: `if`, `while`, `for`, `function`, `repeat`, a bare `do … end`, or the typed word the code sits in. Those keep their own `end`, so the word's body stays open. Nothing may follow `endall` inside the blocks it closes, which is what makes the rule simple: put the deepest handler last, and one closer ends a whole pyramid. It returns nothing, calls nothing and cleans nothing up: its effects are exactly those of the expanded program.

```lua
tasks:
    spawn:
        io.listen(0) with
            failed = do(e) end
            done =: l
                io.accept(l) with
                    failed = do(e) end
                    done =: c
                        go c
                    end
                end
            end
        end
    end
end
return n
```

`endall` there closes seven blocks. It is also how a chain is written flat: the wrappers (`tasks:`, `spawn:`) sit at one indent, the content after them is indented once, the handler chain (`done =: l`, `io.accept(l) with`, `done =: c`) is flat within the content, sibling entries (`failed = …`) are one level in under their `with`, and the innermost body is one level in again. `nua fmt` writes this layout and folds a trailing run of three or more `end` lines that close Nua blocks into an `endall` (a run that holds a `with`; `spine_style = "none"` keeps the staircase).

```c
void import_rows(Document *doc, uint32_t n) {
    Draft draft;
    trace(1u);
    trace(2u);
    draft.length = doc->length;
    draft.cursor = doc->cursor;
    draft.edits = doc->edits;
    draft.length = draft.length + n;
    draft.cursor = draft.cursor + n;
    draft.edits = draft.edits + 1u;
    doc->length = draft.length;
    doc->cursor = draft.cursor;
    doc->edits = draft.edits;
    trace(102u);
    trace(101u);
    trace(9u);
}
```

### 10.10 Not included

Keyed application other than matching (§11), modules and `use` (Lua tables play the vocabulary role), `defer`, rest destructuring, and spreading Lua tables. The forms here work in typed bodies; top-level code is plain Lua.

## 11. Sums and matching

Sums follow Let's `syntax.md` §8.1.

### 11.1 Declaring and constructing

```lua
local Circle = struct { radius: U32 }
local Rect = struct { width: U32, height: U32 }
local Shape = oneof { circle: Circle, rect: Rect, dot: Unit }
```

A sum is a finite set of named alternatives, each with a payload type (`Unit` for none). Alternative order is canonical (by name), so two spellings of the same alternatives are the same type. A `oneof` needs at least one alternative. A payload may hold owners (§9.13), never references (*Let's recursive sums go through `Ref`; in Nua they go through `Id`s into a store, as graphs do*).

Member selection on the sum type names a constructor. A record payload is built by keyed supply, another payload is applied to one value, and a `Unit` alternative to nothing:

```lua
Shape.rect { width = 4, height = 5 }
Opt.some x
Opt.none
```

In C, a sum is a tag and a union of the payloads, with the tags as named constants:

```c
enum { Shape_circle = 0, Shape_dot = 1, Shape_rect = 2 };
typedef struct Shape {
    uint32_t tag;
    union {
        Circle circle;
        Rect rect;
    } as;
} Shape;
```

### 11.2 Matching

Matching is keyed application of a sum value, with one handler per alternative. Each handler receives that alternative's payload, as a copy, or, when the matched sum is a place and the handler declares its parameter `Ref`, as a borrow of the payload in place (`running = do(r: Ref Running): Unit ... end`). Giving the sum another variant ends such a borrow:

```lua
local area = do(s: Shape): U32 = s with
    circle = do(c) = c.radius * c.radius * 3
    rect =: r
        local w = r.width
        return w * r.height
    end
    dot = do() = 0
end
```

`name(params) = body` in a headed supply is `name = do(params) = body`: `o { some(v) = v, none() = d }`.

Every alternative must be handled exactly once, even when the tag is known: a missing, unknown or duplicate handler is rejected. A payload is reached only by matching; selecting it by name is rejected.

An immediately applied handler table, such as `body(Ref draft) { commit() = true, abort(reason) = false }`, can consume the returns of that exact in-place producer directly. Returns with a known tag join at that tag's handler without constructing a runtime sum. Equal known payloads stay known; differing payloads join in a typed slot. The producer's mutations and the handler's result each have their own state join, and only the selected handler executes at runtime. Nested calls cannot take the producer's continuation. Unknown-tag returns, explicit `call` boundaries and materialized recursive calls keep ordinary sum dispatch. A table needed to saturate a word, or consumed by its rest requirement, remains an argument—not a handler continuation.

### 11.3 Binding times of a sum

A sum value is tracked with its tag and payload separately, so a sum whose **tag is known** can carry a payload of any binding time (`Command.insert(n)` with `n` from input). This is the common case in practice.

- **A known tag selects its handler while specializing.** Only that handler runs; the others are never evaluated. `area(Shape.rect { width = k, height = 1 })` is `k`:

```c
uint32_t strip(uint32_t k) {
    return k;
}
```

- **A runtime tag** gives a test per alternative, the payload projected inside its arm. Each arm is evaluated against its own copy of the state, as the branches of a dynamic `if` are, and the result is joined. The handlers must agree on a result type; a Lua number takes its type from the other handlers, so the result does not depend on alternative order, and handlers that agree on one Lua number fold to it. A chain of tests on one tag prints as a `switch`:

```c
uint32_t area(Shape s) {
    switch (s.tag) {
    case Shape_circle: {
        return s.as.circle.radius * s.as.circle.radius * 3u;
    }
    case Shape_dot: {
        return 0u;
    }
    default: /* Shape_rect */ {
        return s.as.rect.width * s.as.rect.height;
    }
    }
}
```

A sum stored in a typed local keeps a known tag through the evaluator (lazy stores, §5.3); paths that disagree make it memory at the join, as any place.

### 11.4 Describe, then run

Commands as data and one interpreter:

```lua
local Direction = oneof { left: Unit, right: Unit }
local Command = oneof { move: Direction, insert: U32, undo: Unit }

local apply = do(e: Ref Editor, c: Command): Unit
    c with
        move =: d
            d with
                left = do
                    if e.cursor > 0 then e.cursor = e.cursor - 1 end
                end
                right = do
                    if e.cursor < e.length then e.cursor = e.cursor + 1 end
                end
            end
        end
        insert =: n
            e.length = e.length + n
            e.cursor = e.cursor + n
        end
        undo = do
            e.undos = e.undos + 1
        end
    end
end
```

Over a script known while specializing, the interpreter dissolves into straight-line code:

```lua
local script = {
    Command.insert 5,
    Command.move(Direction.left()),
    Command.move(Direction.left()),
    Command.undo(),
    Command.insert 2,
}
local run_script = do(e: Ref Editor): Unit
    for i = 1, #script do
        apply(e, script[i])
    end
end
```

```c
void run_script(Editor *e) {
    e->length = e->length + 5u;
    e->cursor = e->cursor + 5u;
    if (e->cursor > 0u) {
        e->cursor = e->cursor - 1u;
    }
    if (e->cursor > 0u) {
        e->cursor = e->cursor - 1u;
    }
    e->undos = e->undos + 1u;
    e->length = e->length + 2u;
    e->cursor = e->cursor + 2u;
}
```

Over a program known only at run time, the same interpreter is a switch inside a loop, a bytecode VM:

```lua
local Program = Grow Command
local run_program = do(e: Ref Editor, prog: Ref Program): Unit
    local i: U32 = 0
    while i < prog.length do
        apply(e, prog[i])
        i = i + 1
    end
end
```

```c
/* sketch */
    for (;;) {
        if (i >= prog.len) break;
        at = CommandGrow_elem(&prog, i);
        t = *at;
        switch (t.tag) {
        case Command_insert: {
            e.length = e.length + t.as.insert;
            e.cursor = e.cursor + t.as.insert;
            break;
        }
        case Command_move: {
            if (t.as.move.tag == Direction_left) {
                if (e.cursor > 0u) {
                    e.cursor = e.cursor - 1u;
                }
            } else if (e.cursor < e.length) {
                e.cursor = e.cursor + 1u;
            }
            break;
        }
        default: /* Command_undo */ {
            e.undos = e.undos + 1u;
            break;
        }
        }
        i = i + 1u;
    }
```

(The printer emits a `switch` only when no arm leaves an enclosing loop, so its `break`s always mean the `switch`.) One implementation, two binding times: this is the guide's "describe, then run", with the interpretive work removed by construction when the description is known.

## 12. Raw pointers and slices

Pointers follow Let's `syntax.md` §8.5 and slices its §8.4. **`Ptr` is the edge of the program; `Slice` is for the work.**

### 12.1 Raw pointers

`Ptr T` is an address the compiler does not track: the explicit foreign boundary, where the programmer is responsible and the compiler offers no rule to break.

| Form | Meaning |
|---|---|
| `p[i]` | the element at index `i` (an unsigned integer): an unchecked place, readable and assignable |
| `p.field` | a field of a record target, readable and assignable |
| `Ptr(place)` | the address of a place: the **only** place a lifetime is dropped |
| `null(T)` | the null `Ptr T` |
| `Ptr(T)(p)` | an explicit unchecked conversion from one raw pointer type to another |
| `p == q`, `p ~= q` | address comparison |

There is no other arithmetic, no ordering and no conversion to or from integers; `p[i]` is the only arithmetic, so one thing has one spelling. `Ref(p)` is rejected: an unchecked address must not become a checked borrow. Pointers may be stored in structs, returned and passed freely.

A `CString` and a raw pointer convert to each other the same way: `(Ptr U8)(s)` reads a C string's address as a byte pointer and `CString(p)` reads a byte pointer's address as text, where a foreign interface needs one for the other. No integer takes part.

`Ptr(T)(p)` accepts only an existing `Ptr U`. It preserves the address and does not copy or reinterpret a value, check alignment or bounds, transfer ownership, extend a lifetime, or create a borrow. The programmer must satisfy the foreign ABI, alignment and aliasing rules before dereferencing the result. Converting back to the original pointer type preserves its address; null stays null. Pointer conversions are never implicit. For example, a POSIX `Ptr sockaddr_in` can explicitly become a `Ptr sockaddr` for `connect`, and a raw operation buffer can explicitly recover its declared slot-pointer type. Both backends lower this through the ordinary prepared-IR conversion operation.

```lua
local brighten = do(px: Ptr Pixel, n: U32, k: U8): Unit
    local i: U32 = 0
    while i < n do
        px[i].r = px[i].r + k
        i = i + 1
    end
end
```

```c
void brighten(Pixel *px, uint32_t n, uint8_t k) {
    uint32_t i = 0u;
    for (;;) {
        if (i >= n) {
            return;
        }
        px[i].r = (uint8_t)((uint32_t)px[i].r + (uint32_t)k);
        i = i + 1u;
    }
}
```

**Pointers and the evaluator.** Pointer operations are always residual: there is no memory at compile time. The evaluator makes no assumptions about memory it does not track, so pointers need no extra rules: `Ptr(place)` treats the place as a `Ref` passed to a materialized call does (its pending values are stored and it is plain memory from then on), values read through pointers are never kept pending, and binding one to a name snapshots it at once. A write through any pointer therefore cannot invalidate anything the evaluator believes. `Ptr(v)[0]` is `v` and `Ptr(s).f` is `s.f`:

```c
uint32_t through_pointer(uint32_t x) {
    uint32_t v = x;
    v = v + 1u;
    return v * 10u;
}
```

A pointer into a store slot or a `Grow` dangles after the storage grows. That is the responsibility §12.5 hands to the programmer: it is documented, not checked.

### 12.2 Slices

`Slice T` is a read-only view: a pointer and a `U64` length. `Slice.mut T` is the same view, writable: `s[i] = v` is checked like a read; its length cannot change. A `Slice.mut` serves where a `Slice` is expected. An owner (a `Grow`, an `Array T`, an `Array(T, n)`) lends its elements to a `Slice.mut` marked at the call, `f(Ref xs)`, and to a `Slice` with no marker. The operations of both:

| Form | Meaning |
|---|---|
| `s[i]` | a checked element read (a copy) |
| `s.length` | the length |
| `s:sub(a, b)` | the view of `[a, b)`, checked |
| `Slice(p, n)` | a view of `n` elements at pointer `p`: the boundary where a length is trusted |
| `g:all()`, `g:sub(a, b)` | a view of a `Grow` (§12.4) |
| `view_of(p, n, body)` | lend a scoped view of foreign elements (§12.6) |

**A check that a branch already proved is dropped.** On each arm of a dynamic branch the compiler records what an integer comparison proves (the loop exit `if (i >= n) break;` proves `i < n` on the path that continues), over values that cannot change behind its back: constants, parameters, temporaries, versioned reads of tracked locals, and a view's length. When `i` changes, its version changes and the fact stops matching. `s[i]` and `a[i]` (§13) emit no check when such a fact proves `i < length`.

A view is read-only: `s[i] = v` is rejected (`not-a-place`); writes go through the storage or a `Ptr`. Slices cannot be compared. Slices are borrows, like `Ref`: a struct field, an element or a payload may hold one, checked by the lifetime rule (§9.4, §9.5).

**Checks and binding times.** Internally a slice is a two-field struct, so the evaluator tracks its length apart from its pointer. A **known index against a known length is checked at compile time** (`index-range`) and costs nothing at run time; anything else is one check when it runs (the `slice.index` word of [lib/slice.nua](../lib/slice.nua), a trap on failure). `s:sub(a, b)` with known bounds produces a slice whose **length is known**, after one range check. So the idiom for formats is to take the whole header once, then read at constant offsets with no further checks.

### 12.3 Describe, then run: a binary format

```lua
local Packet = struct { version: U32, flags: U32, length: U32, id: U32 }
local format = {
    { "version", 0, 1 },
    { "flags", 1, 1 },
    { "length", 2, 2 },
    { "id", 4, 4 },
}
local size = 8
local read_be = do(s: Slice U8, at, width): U32
    local v: U32 = 0
    for k = 0, width - 1 do
        v = v * 256 + U32 s[at + k]
    end
    return v
end
local parse = do(buf: Slice U8): Packet
    local h = buf:sub(0, size)
    local fields = {}
    for _, f in ipairs format do
        fields[f[1]] = read_be h f[2] f[3]
    end
    return Packet fields
end
```

```c
Packet parse(U8Slice buf) {
    if (8ull > buf.len) {
        nua_trap("slice range out of bounds");
    }
    uint32_t v = (uint32_t)buf.ptr[0ull];
    uint32_t v2 = (uint32_t)buf.ptr[1ull];
    uint32_t v3 = (uint32_t)buf.ptr[2ull];
    v3 = v3 * 256u + (uint32_t)buf.ptr[3ull];
    uint32_t v4 = (uint32_t)buf.ptr[4ull];
    v4 = v4 * 256u + (uint32_t)buf.ptr[5ull];
    v4 = v4 * 256u + (uint32_t)buf.ptr[6ull];
    v4 = v4 * 256u + (uint32_t)buf.ptr[7ull];
    return (Packet){ .version = v, .flags = v2, .length = v3, .id = v4 };
}
```

The description, the loop over it and the reader's own loop are gone; one range check remains.

### 12.4 Views of a Grow

`g:all()` is a slice of a `Grow`'s elements, borrowing the `Grow` (§9.4), of the
length it has when the slice is taken; `g:sub(a, b)` is `g:all():sub(a, b)`. The
`Grow` may grow while the slice is used, since its bytes never move; `g:clear()`,
`g:pop()` and `g:truncate(n)` end it (§9.7).

```lua
return sum32 g:all()
```

### 12.5 What is not checked

A check stays when no recorded fact proves it: facts are kept per path, over values that cannot change behind the compiler's back (above), and are not carried through a `Bool` that stored a comparison (`ok = i < n; if ok then ... xs[i]`), nor across loop rounds once a variable changes. Taking a known-length sub-slice first is a way to state a bound the compiler cannot see.

### 12.6 Scoped foreign views

`view_of(p, n, body)` lends a read-only `Slice T` over `n` elements of a `Ptr T`
for the body's evaluation. The pointer and length remain trusted: the wrapper
must ensure the elements stay valid until the body completes. The compiler does
not prevent a foreign API from freeing or invalidating them during the callback.
The primitive neither allocates nor frees the memory. It snapshots the supplied
pointer and length before invoking the body. Use it inside a foreign resource
activity instead of handing the callback an unscoped `Slice(p, n)`:

```lua
local foreign_sum = do(pointer: Ptr U8, length: U32): U32
    return view_of(pointer, length): bytes
        local text = Str.of bytes
        return checksum text
    end
end
```

This excerpt and owned-copy examples are in
[`examples/borrowed_views.nua`](../examples/borrowed_views.nua). Its harnesses read
copied `Chars` and `Text` after the foreign allocation has actually been freed.

The scoped view is a borrow of the activity (§9.4) and follows the lifetime rule:

* Inferred bindings can alias it inside the activity. `Str.of`, subviews,
  `dynamic`, in-place words, sum payloads and joined return paths preserve the
  provenance. A runtime choice between two loans requires both lifetimes.
* A scoped view can be stored only in storage declared inside the activity; a
  typed local declared outside it, or an aggregate that escapes, is rejected.
  Returning this activity's loan is rejected. An outer loan may pass through an
  inner activity without acquiring the inner activity's lifetime.
* After the loan ends, even text length, conversion or comparison through an
  escaped compiler alias is rejected. Copy a scalar during the activity, or copy
  the bytes into owned `Chars(n)` or `Text`, to retain the result.
* A materialized word receives a scoped view under its derived summary (§9.7):
  a scalar-consuming callee is fine, and a callee returning its argument returns
  a value that still borrows the activity. An indirect function call or an
  opaque foreign call receiving one is rejected: nothing describes what it keeps.
* A residual loop may carry a view with the same loan, including subviews of it.
  Changing the loan provenance across a residual backedge is rejected rather
  than discarding it.

The raw boundary remains explicit. `Slice(p, n)`, raw pointers and raw
representation access do not gain a loan merely because a length is present.
Extracting a raw pointer and constructing a new slice deliberately crosses back
into the programmer's trusted foreign-memory contract. A resource wrapper must
establish the scoped loan around the user callback and perform invalidating work
(step/reset/unmap/free) only after that callback completes.

## 13. Fixed-length arrays

`Array(T, n)` holds `n` elements of a fixed-size `T`, with `n` known while compiling. It is a value: a typed local, a struct field, a parameter, a pool's slot type. In C it is a struct wrapping `T e[n]`, so it copies and passes by value as structs do. An `Array(T, n)` whose elements hold owners is an owner instead (§9.13): its elements' owners live in its arenas, it is indexed like a container (`a[i]`, `a.length`), moved and copied like any owner.

```lua
local fixed = do(): U32
    local a = Array(U32, 4) { 10, 20, 30, 40 }
    local b: Array(U32, 4)
    b[0] = a[3]
    b[1] = a[0] + a[1]
    return b[0] + b[1] + a.length
end
```

```c
typedef struct U32x4 { uint32_t e[4]; } U32x4;
```

```c
uint32_t fixed(void) {
    return 74u;
}
```

* `a[i]` is checked like a slice's element (§12.2): at compile time when the index is known (`index-range: index 4 is outside an array of length 4`), otherwise when it runs.
* `a.length` is known. `a:slice()` views the elements as a read-only `Slice T`.
* `Array(T, n)()` is zeroed, `Array(T, n) { ... }` lists every element, and a typed local declared without a value starts zeroed.
* Fully known array contents are immutable aggregate values in the evaluator. A typed local keeps its whole pending value; known-index reads and known writes can fold. Copies keep independent snapshots, including nested arrays and structs. Compact zero contents do not require one compiler cell per element.
* A dynamic write or a read requiring runtime indexing materializes the array conservatively; the implementation does not maintain a partly known element map afterward. Different branch results materialize on their respective paths, and loops widen as other tracked values do. Equal known contents may stay known.
* `a:slice()` is a live read-only view of the owner, not a snapshot of its contents. It can read known elements without creating an address. Once a raw address or foreign boundary requires memory, pending values are written and affected knowledge is invalidated. Explicit `Ptr(...)` remains the runtime boundary of §12.1; this is not a compile-time heap.
* Elements are scalars, structs, sums, arrays, channels, references and views, or owners (§9.13). An array holding a borrow follows the lifetime rule as a whole (§9.5). An array is sendable when its elements are.

## 14. Text

Three types, one per role, each fitting the memory model as it is: views never outlive what they view, resizable storage lives on data stacks, and values are copied.

| Type | Role | Storage | Store in a struct | Send to a task |
|---|---|---|---|---|
| `Str` | a view of text | someone else's bytes | no | no |
| `Text` | text being built | its own data stack (it is `Grow U8`) | as a field created in place | no |
| `Chars(n)` | short text as a value | inline: a length and `n` bytes | yes | yes |

### 14.1 Str

`Str` is to text what `Slice U8` is to bytes: `{ptr, len}` in C, `s.length`, a checked `s[i]` (a `U8`), `s:sub(a, b)`, and the same lifetime rules. A Lua string where a `Str` is expected is a literal, known while compiling, and so are its bytes and its length. Text is compared with words, not operators.

| Word | Gives |
|---|---|
| `s:equals(t)`, `s:starts_with(t)`, `s:ends_with(t)` | `Bool` |
| `s:find(t)` | `oneof { at: U64, missing: Unit }` |
| `s:compare(t)` | `oneof { less, same, greater }` (bytes, then length) |
| `s:trim()` | `Str` without leading and trailing spaces, tabs, CR, LF |
| `s:split(",") do(part) ... end` | each part between one-byte separators |
| `s:lines() do(line) ... end` | each line, without a last empty one |
| `s:parse(T)` | `oneof { value: T, bad: Unit }` for any integer `T`; overflow is `bad` |
| `Str.of(x)` | a view of a `Slice U8` or a `CString` (`strlen` once) |

These words are written in Nua (`lib/str.nua`), so they specialize like any other. Over text known while compiling they run while compiling (`assert(host(word_count("the quick  brown fox")) == 4)`). With a known needle, the method picks a variant that takes the needle as a Lua string, a compile-time parameter, so the loop over it is Lua's and unrolls:

```lua
local is_world = do(name: Str): Bool = name:equals "world"
```

```c
bool is_world(Str name) {
    if (name.len != 5ull) {
        return false;
    }
    bool same = name.ptr[0ull] == 119u;
    same = same && name.ptr[1ull] == 111u;
    same = same && name.ptr[2ull] == 114u;
    same = same && name.ptr[3ull] == 108u;
    same = same && name.ptr[4ull] == 100u;
    return same;
}
```

There are no bounds checks: when an arm of an `if` cannot fall through, what follows is reached only through the other arm, so the facts of that arm hold for the rest of the block. `name.len != 5u` returning makes `name.len >= 5` known, and a constant index below a known lower bound needs no check (the range facts of §12.2, extended to `==`, `>=` and `>` against constants).

### 14.2 Text

`Text` is `Grow U8` with text words, created in place like any `Grow`: `local out: Text = Text {}`.

* `out:write(a, b, ...)` appends each value as text. Known pieces (Lua strings and numbers, known values, known `Str`) are joined while compiling into one literal; each runtime value gets the conversion its type needs: integers in decimal, `Bool` as `true`/`false`, floats as the shortest text that reads back as the same value, `Str` and `CString` as their bytes. No format string exists at run time.
* `out:str()` is the text as a `Str` borrowing `out` (§9.4). The text may grow while the `Str` is used (`out:write out:str()` appends its own bytes); `out:clear()` ends it.
* `out:clear()`, `out:push(byte)`, `out.length`, `out[i]`.

Integer digit generation and Boolean formatting are ordinary Nua words in
[format.nua](../lib/format.nua), not opaque runtime conversions. `Text:write` uses
these same words for known and dynamic operands. Known formatting can disappear
entirely; dynamic formatting residualizes its loops with the caller. For example,
[formatting.nua](../examples/formatting.nua) specializes the length of a formatted
known `U64` to:

```c
uint32_t format_known_length(void) {
    return 20u;
}
```

Decimal formatting is [format.nua](../lib/format.nua): the precision search, the
special values, the `Chars(32)` buffer and the `snprintf`/`strtod` calls are ordinary
Nua words, and libc is an explicit external dependency rather than an irreducible
primitive. The compiler keeps only the fold of a value known while compiling
(`float_is_known` and `float_text` in `nua/strings.lua`).
that algorithm is separate work, not a property claimed for the current prototype.

### 14.3 Chars(n)

`Chars(n)` holds up to `n` bytes inline, with a length: a value like any struct, so it can be a field, a message, a pool slot and a map key (§15.1). `Chars(16)(s)` fills one from text: longer known text is rejected while compiling (`Chars(2) holds 2 bytes; this text has 3`), longer runtime text traps. `c:str()` views it and `c.length` is its length.

Known construction is a value operation: `Chars(n)("abc")` and `Chars(n)()` need no runtime frame, and unused capacity is zero-filled. A typed local initialized from known text can be inspected through `:str()`, compared or parsed while compiling, just like the text operations on literal `Str`. The capacity branch and byte-copy loop live in [chars.nua](../lib/chars.nua): they fold for known text and residualize for dynamic text. Lua supplies the type and compile-time capacity diagnostic, not a separate copy algorithm. The C layout and copy ABI are the same at both binding times.

A `c:str()` view records an owner, offset and the length at creation. It reads the owner's current bytes: reassigning `c` changes what the view sees, but does not change that captured length. A copied `Chars(n)` is independent. The evaluator therefore must not replace a view with a cached string snapshot; taking an address materializes its actual owner, not an unrelated static literal. This does not extend the owner's lifetime or introduce stronger raw-pointer lifetime guarantees than §12.

[The staged-values example](../examples/staged_values.nua) exercises these distinctions across known, split and dynamic inputs, nested fields, joins, loops, raw address escape and task captures. A task's view addresses its own captured value, never the parent's later contents.

A struct field may be a `Str`; the struct then borrows what the `Str` borrows and follows the same lifetime rule (§9.7). A store or Grow element may hold one, checked against the container's owner (§9.6). Globals hold only a `Str` of static data or of another global; maps and channel messages hold none. Store text that must outlive its owner as `Chars(n)` or in a `Text`.

### 14.4 What is implemented

Everything above, on both backends (`examples/strings.nua`, `tests/strings_main.c`), including the UTF-8 words (`s:runes()`, `utf8.valid`, [utf8.nua](../lib/utf8.nua)): an ill-formed sequence decodes as U+FFFD and `valid` applies RFC 3629. `s:cstring()` lends a NUL-terminated copy built with the Text words for text known only when it runs. `s:parse(F64)` checks the decimal grammar in Nua and converts through libc `strtod`; known text folds while compiling. Not yet: `find` faster than the obvious algorithm. Maps are described in §15.

## 15. Maps and known lookup descriptions

### 15.1 Owned mutable storage

`Map(K, V)` owns fixed-size entries in slots that never move (a free list reuses
removed ones) and a hash index of slot numbers, on two Goose data stacks; only the
index is rebuilt when the map grows. `Map(Str, V)` also owns copied arbitrary byte
keys, on a third. Iteration follows slot order. Either is an owner (§9.2):
created in place with `{}`, moved, returned, copied with `copy`, passed by `Ref`,
and never captured by another task. A task may own its own map. A struct may hold
maps among any number of owner fields. Scope exit and trap recovery release its
owned stacks.

Keys of `Map` are integers (including Duration), Bool, Id, Chars, or recursive
structs and sums of these. General arrays, floating keys, pointers and borrowed
views are not keys. A key type, or a type its encoding walks through, may not
define `__eq` (§15.2). A value is any element (§9.12): numeric scalars, Bool, `Id`, Chars,
borrows (`Ref`, `Str`, `Slice`), handles (`Ptr`, `Slot`, `Chan`, `Pool`), and arrays,
structs and sums of these. A borrow stored as a value is checked like any stored
borrow (§9.4): it must not outlive its owner, and it is rejected once its source is
cleared or ends. Standalone Unit, atomics (deferred) and resizable values are not map
values; Unit remains valid as a sum alternative. `Map(Str, V)` accepts Str and ordinary text-to-Str coercions, including
empty keys and embedded NUL bytes.

`Map.borrowing(Str, V)` keeps the caller's `Str` keys instead of copying them into
an arena, and compares them by contents. Each key is a stored borrow (§9.4): it must
not outlive its owner, and the map is rejected once a source is cleared or ends
(`Map.borrowing(Str, V)` operations check the keys they compare against). Tokens keyed
by their text in a source buffer need no copies. `put(k, v)` and `m[k] = v` store the
borrow; `find`, `has`, `remove` and `m[k]` look it up by contents.

```lua
local Counts = Map(U32, U64)
local count = do(n: U32): U64
    local m = Counts {}
    for i: U32 = 1, n do
        local k = i % 17
        m:ensure(k, 0)
        m[k] = m[k] + 1
    end
    local total = U64 0
    m:each do(k, v) total = total + v end
    return total
end
export count
```

- `m[k]` is a borrow of an existing entry. Reading a missing key traps with
  `map-key`; **assigning inserts or replaces**, as in Lua (`m[k] = v` and `put(k, v)`
  are the same operation), while `m[k].x = 1` modifies an entry and so traps on a
  missing key (`ensure` creates one). Aggregate fields of the value are places too.
  An entry lives in a slot that never moves, so a borrow of it survives later
  inserts and rehashing; `remove` ends the borrows of entries it may name (a borrow used afterwards
  is rejected while compiling), because the removed slot is reused. A borrow of key 1
  survives `remove 2` when both keys are known and differ; with any unknown key the
  compiler assumes the two may be equal. (`Store` ends every element borrow: `Id`s are
  runtime values.)
- `find(k)` returns `oneof { found: V, missing: Unit }`, with a found value snapshot.
- `has(k)` returns Bool. `put(k, v)` inserts or replaces and returns Unit.
- `ensure(k, initial)` inserts only if absent. Both arguments evaluate eagerly,
  including when an existing value makes `initial` unnecessary.
- `remove(k)` returns whether an entry was removed. `length` is the live count, a U64.
- `each(activity)` visits an unspecified order. Fixed keys and values are snapshots;
  a `Map(Str, V)` key is a read-only scoped view valid only during that callback. The
  loan's provenance, expiration and native-boundary rules are those of §12.6;
  copy into owned storage to retain the bytes.

**Iteration.** Inside `m:each`, the map's structure is fixed, and the compiler enforces
it: `remove`, `put`, `ensure` and `m[k] = v` are rejected while compiling, except to
replace the entry being visited (`m[k] = v` with the callback's own key `k`). The check
follows the map through references (`Ref m` stored in a local, a parameter) and through
words it is passed to: a call that may insert or remove is rejected, and a word's
summary records which of its `Ref` parameters it may change. Values are modified in
place through `m[k]` borrows, which is not a structural change. Nested iteration of one
map is allowed. There is no runtime guard: a trap-free program cannot change a map's
structure while it is walked, and collecting the keys first (into a `Grow`) is how to
change it afterwards.

### 15.2 Semantic keys and checked references

Equality/hash observe typed values, not object bytes: Id's token/slot/generation,
Chars length and used bytes, declared struct fields, and sum tag/active payload.
Padding, unused Chars capacity and inactive payload do not affect identity.

**One identity per type.** A type with `__eq` (§16) has a second notion of identity:
`a == b` runs that hook, while a map hashes and compares the encoding above. For
the same pair the two can disagree, and then `m:has(a)` and `a == b` answer
differently about values a program treats as equal. The compiler therefore refuses
a key type that defines `__eq`, and refuses a key type that contains one, however
deep — `field 'amount' of Pair is Money, which defines __eq`. The fix is structural:
key the map by the fields that compare structurally, or wrap the type in an `Id`,
which is identity by token, slot and generation.

```lua
local Money = struct { cents: I64 }        -- a map value, not a key
function Money.__eq(a: Money, b: Money): Bool
    return a.cents == b.cents
end

local Prices = Map(U32, Money)             -- fine: the key is the U32
```

The rule is a diagnostic rather than a silent choice between the two equalities,
and it is the same reason `Str` has no `==` (§14): one operation, one meaning.

An entry borrow (`Ref m[k]`, `local r = m[k]` as a place) captures a fixed key by
value; the map's owner must stay alive and no entry may be removed while the
borrow is used. A `Map(Str, V)` entry borrow instead captures a borrowed byte view and its
length; each resolution observes the view's current bytes. It does not silently
allocate an owning key.

### 15.3 Immutable known descriptions

```lua
local numbers = Map.known(U32, U32, { { 1, 10 }, { 2, 20 } })
local keywords = Map.known(Str, U32, { { "if", 1 }, { "while", 2 } })
local classify = do(s: Str): U32
    return keywords:find(s) { found(v) = v, missing() = U32 0 }
end
export classify
```

These are immutable host descriptions, not native map storage. Explicit types
also describe an empty entry list. All keys/values must be known; construction
snapshots inputs and rejects duplicate semantic keys. The API is `find`, `has`,
`length`, checked **value** indexing, and `each` in entry-list order while
specializing. There are no mutable places or mutators and no native/task ABI.

Known queries fold. Known missing checked indexing fails during specialization;
dynamic checked indexing traps with `map-key`. Dynamic queries residualize
ordinary Nua comparisons/branches. Bracket keys do not shadow API members, even
for keys such as `"length"`.

### 15.4 Implementation boundary

[Map algorithms](../lib/map.nua), [semantic key operations](../lib/key.nua), and
[SipHash-2-4](../lib/hash.nua) are ordinary Nua words shared by both backends. The
`__eq` rule of §15.2 is `keys.check_key`, which walks a key type the way the encoding
does; it runs when a map type is built and again when a key encoding begins.
Mutable tables use Robin Hood probing, backward-shift deletion, growth at 7/8
load, and offset-based string arenas with bounded dead-byte compaction. Pending
keys are copied before table movement, and arena aliases are rebased after
allocation. Hashing incorporates a per-process random seed; entropy failure traps.

Compiler hooks provide type/layout projection, scoped storage ownership and
borrow lifetime checks. Native runtime primitives provide allocation, checked
byte spans/copies, relocation offsets, entropy and trapping—not map algorithms.
Mutable maps remain runtime storage even when their arguments are known. Known
descriptions have no mutable compile-time heap.

### 15.5 Design rationale

A map is an owner like `Store` and `Grow`, so the decisions that shaped it
were mostly decisions about the Goose model it already had: two data stacks for a
`Map` (slots and index) and three for a `Map(Str, V)` (slots, index, and an arena of copied key bytes), created in
place, released at the end of the owning block, never captured by a task. Holding
maps in a struct needed no new rule, only the existing ownership accounting. A map value
may hold owners (`Map(U64, Text)`, `Map(Str, Grow U32)`): they live in the map's arenas
(§9.13), `m[k]` reaches them in place, `put` on an existing key replaces the old value's
owners, and `find` is not offered (it would return the value). A map may itself be a map
value or a container element (§9.13).

**Key and value restrictions are recursive, not judged by the outer type's size.** A
key must have semantic equality that ignores padding, and a value must be owned data:
fixed-size, or holding owners (§9.13). That is why `Chars(n)` is a key despite its internal array, why a struct
of allowed keys is a key, and why a borrowed view, a pointer, a channel, an atomic or
a resizable field is refused at any depth. Checking only the outermost type would
admit a struct whose padding makes two equal values hash differently.

**Checked places carry a key, not an entry pointer.** A map place re-resolves its key
after a structural change, a call and each loop round, exactly as a store place
re-checks its `Id`; nothing holds an entry's address across a change, so a table may
grow while its entries are in use. The key identity is deliberately *not* Store's
generational one: removing and reinserting an equal key makes the place address the
new entry.

**Mutable maps are effects; known descriptions are host objects.** No argument being
known turns a mutable map into a compile-time heap. The immutable form has its own
API and takes explicit types and entry lists rather than a Lua table, which avoids
Lua's table-key identity for string keys and its number precision for wide integers,
represents an empty map, and lets duplicate semantic keys be reported instead of
resolved by iteration order. Its contents are snapshotted at construction, and it
exposes lookup, not mutation. A known key folds while specializing; a dynamic key
residualizes the same comparisons a mutable lookup would use.

**The algorithms are Nua (§15.4), so a lookup specializes with its caller.** The
earlier per-type C and generated-C implementations survive only as test oracles; the
model checks in [`tests/map_types.lua`](../tests/map_types.lua) and the storage
fuzzer exercise the Nua table and arena directly, so passing an oracle is not the
acceptance evidence.

**Hashing is keyed once per process.** The seed comes from the runtime's entropy at
first use, and failure to obtain it traps rather than falling back to a predictable
constant. SipHash-2-4 is the only hash policy: it is a keyed PRF, not an
authenticated MAC, and the claim it supports is that untrusted keys do not
reproduce a collision set across processes — not that the mixer is cryptographically
strong.

**A `Map(Str, V)` arena is addressed by offset.** Entries keep byte offsets into their
movable arena, never pointers, so growth can relocate it. Removal marks bytes
reclaimable, and the removal itself compacts the arena once the dead bytes reach the
live bytes (and 4096), so insert/remove churn cannot accumulate historical key storage
without bound; an insertion never moves keys. A key view supplied by the caller is borrowed, never silently copied: the
owner must outlive the lookup, and each resolution observes the current bytes.

The contract is §15.1–§15.4; what each part is checked by is named in the acceptance
slices of the feature: `examples/maps.nua`, `examples/strmaps.nua`,
`examples/known_maps.nua`, `examples/map_models.nua`, and the `map_*` and
`strmap_*` C harnesses in `tests/`.

## 16. Library-defined types

A type is a layout plus what the language's operations mean on it. The layout is
a `struct`. The meaning is a set of **hooks**: Lua functions or native words stored
on the type under `__`-names. A hook runs while specializing and returns staged
values, places or words, so whatever it builds folds and residualizes with the
caller. No runtime dispatch, inheritance or object model is involved (§22).

| Hook | Runs for | Returns |
|---|---|---|
| `__member(x, name)` | `x.name`, `x:name(...)` | a value, place or word; `nil` falls back to fields, then methods |
| `__index(x, key)` | `x[key]` | a value or a place; a word may return a `Ref` |
| `__newindex(x, key, v)` | `x[key] = v` | nothing |
| `__cast(v, T)` | a host value or other-typed value where a `T` is expected, and `T(v)` | a `T`, or `nil` to refuse |
| `__add` `__sub` `__mul` `__div` `__mod` `__unm` | arithmetic | a `T`; the other operand is first converted through `__cast` |
| `__eq` `__lt` `__le` | comparisons; `~=`, `>` and `>=` derive from them | a `Bool` |

`__eq` is the one hook with a restriction outside its own type: a type that
defines it, or a type a key encoding walks through, cannot be a map key (§15.2).

A hook is stored on the type, so it is written with a dot:
`function Fixed.__add(a, b)`. The hooks whose first argument is the receiver,
`__index` and `__newindex`, may also be methods: `function R:__index(i: U32): Ref E`.
The others take no receiver (`__cast` converts a value that is not yet a `T`; an
operator's operands are both `T`, and either may be the converted one), so
writing one as a method is an error.

While a type's hook runs, that type's hooks are not consulted again, so a hook
reads its own representation with ordinary field access; `rawmember(x, name)` does
the same outside a hook. Comparisons are staged only in typed bodies (architecture §3.2, §4),
so a hook that compares is a native word. Assigning to a native field or element
works in plain Lua code as well as in typed bodies.

```lua
local Fixed = struct { raw: I32 }  -- 16 fractional bits

function Fixed.__cast(v)
    if type v == 'number' then return Fixed { raw = I32(v * 65536) } end
end

function Fixed.__mul(a: Fixed, b: Fixed): Fixed
    local wide = I64 a.raw * I64 b.raw
    return Fixed { raw = I32(wide / 65536) }
end

function Fixed.__add(a: Fixed, b: Fixed): Fixed
    return Fixed { raw = a.raw + b.raw }
end

local scale = do(x: Fixed, y: Fixed): Fixed = x * 1.5 + y
```

The literal `1.5` goes through `Fixed.__cast` while compiling, so `scale` is two
integer operations on the representation.

Containers follow the same way. A generic type is a Lua function (§2.3), its
storage is a field of an existing resizable kind (`Grow`, `Store`), and `[]` is a
hook that returns the element's place:

```lua
local Ring =: E capacity
    local R = struct { head: U32, len: U32, items: Grow E }

    function R:push(v: E): Unit
        if self.len < capacity then
            self.items:push v
            self.len = self.len + 1
        else
            self.items[self.head] = v
            self.head = (self.head + 1) % capacity
        end
    end

    function R:__index(i: U32): Ref E
        if i >= self.len then trap "ring index out of range" end
        return self.items[(self.head + i) % capacity]
    end

    return R
end
```

A type that holds a resizable field is itself resizable (§9), so ownership,
creation in place and give-back are the existing rules; nothing is declared
about them. The `Ref` returned by `__index` borrows from `self` (§9.5).

### 16.1 The built-in kinds

`Str`, `Chars(n)` and the `x[k]` places of Store, Grow and Map register
their hooks on their types. `Ptr`, `Slice`, `Atomic`, `Chan`, `Array`, `Pool` and
`Slot` register once per family. Types with computed members and built-in methods
(`properties`, `builtin_methods`) serve them through the same `__member` hook. A
Lua string where a `Str` is expected is `Str.__cast`. What remains outside the
hooks is the default: struct fields, struct methods, and the error for a sum.

### 16.2 What this does not provide

Hooks do not hide a representation: a struct's fields stay visible unless its
`__member` refuses them. There are no declared roles; a type is copyable,
storable or sendable by the rules of the layout it is built from (§9, §9.6,
§20). There is no scalar newtype, no read-only static data and no user-defined
view lifetime; a library view is a `Slice` or `Str`.

§16.3 records where the hooks are registered.

### 16.3 Registration in the compiler

A hook is a Lua function or a native word stored on the type object under its
`__`-name, so it is found by the same member lookup a field would be. Two
consequences follow, and both are easy to observe:

* **A hook runs while specializing**, never at run time. It receives staged values
  and places, and may return a value, a place or a word. Whatever it builds is
  ordinary staged computation from then on: it folds when its arguments are known
  and residualizes when they are not.
* **A hook sees its own representation naively.** While a type's hook runs, that
  type's hooks are not consulted again (`nua/stage.lua` keeps a per-type
  re-entrancy mark), so `a.raw` inside `Fixed.__add` reads the field instead of
  calling `__member` again. `rawmember(x, name)` does the same outside a hook.

The lookup order for `x.name` and `x[key]` is: the type's `__member` — or, for a
kind served per family, the family hook — then the default path, which is the
type's `__index` for an element key, then a struct field, then a method, and
finally the diagnostic that tells a sum's payload to be reached by matching.

**Registration.** `Str`, `Chars(n)` and the `x[k]` places of `Store`, `Grow`, `Map`
register hooks on their own type objects. `Ptr`, `Slice`, `Atomic`,
`Chan`, `Array`, `Pool` and `Slot` register once per family in
`S.family_hooks` (`nua/stage.lua`), because their types are constructed per element
and per length. Types with computed members and built-in methods carry
`properties` and `builtin_methods` tables, which `S.member_tables` serves through
one generated `__member`. A Lua string where a `Str` is expected is `Str.__cast`.

**Comparisons are native words.** Comparisons are staged only in typed bodies
(§4), so a hook that compares must be a word that returns a `Bool`. An
arithmetic or conversion hook may be an untyped Lua function that only builds
values or chooses words.

**Assignment works in plain Lua too.** A native field or element is assignable from
host code (`w.items[k] = v`), where the same hooks apply; a hook does not have to
run inside a typed body to be useful.

**What is not routed yet:** the coercion path `coerce` still knows certain built-in
kinds directly, and struct fields and methods are still the `raw_member` default
rather than hooks. Both are implementation notes, not language rules: a library
type's hooks already cover everything the built-in kinds do.

The examples are [`examples/user_types.nua`](../examples/user_types.nua) — a fixed
point number with `__cast`, `__add`, `__mul` and `__lt`, and a four-element window
with `__index`, `__newindex` and `__member` — and
[`examples/ring.nua`](../examples/ring.nua), a bounded ring buffer written purely
as a library: a struct holding a `Grow`, methods, and a typed `__index` hook that
returns a `Ref`.

## 17. Foreign C and libc

### 17.1 Foreign C interoperability

```lua
local puts_u32 = extern("puts_u32", { U32 }, Unit)
local abs = extern("abs", { I32 }, I32, { header = "<stdlib.h>" })

local dist = do(a: I32, b: I32): I32 = abs(a - b)
```

```c
int32_t dist(int32_t a, int32_t b) {
    return abs(a - b);
}
```

A foreign function is an opaque effect: it is never executed at compile time, whatever its arguments. With a header, the backend includes it; without one, it emits the prototype.

Structs with fixed C layouts cross the boundary directly; exported words taking `Ref T` take `T *`, and `Slice T` is a `{ T *ptr; uint64_t len; }` struct passed by value. Owners cross only by pointer, with their header layout from `nua_rt.h`. Raw pointers (`Ptr T`, §12) are the foreign boundary, not provenance-checked references.

Private records need not retain storage for every declared field. After specialization, a field with no remaining runtime read, write or observable address may be omitted from the native layout. This decision applies across all reachable instances of that type; known configuration values can differ between instances. Source-level fields and their values do not change. Exported and foreign interfaces retain the declared layout, including nested records and types reached through pointers or callbacks. C and libgccjit use the same storage decisions.

libc is C, and Nua emits C, so wrapping it is a matter of externs. What the language adds is the shape: **every libc resource with a lifetime becomes an activity**, and an activity's completion cannot be skipped, because a body's `return` leaves only the body. A file opened by `with_file` is always closed and a buffer from `with_buffer` always freed, short of a trap: RAII without destructors, `defer` without `defer`. Everything is evaluated in place, so the wrappers leave no calls of their own in the C.

### 17.2 What wrapping C needs

| Form | Meaning |
|---|---|
| `opaque "FILE"` | an opaque C type, usable only behind a `Ptr` (`FILE *`) |
| `CString` | `const char *`; a Lua string literal is a known `CString` |
| `extern(name, params, result, { header = "<stdio.h>" })` | a C function from a header (no prototype is emitted) |
| `{ variadic = true }` | a variadic C function; extra arguments must be native scalars, `CString`s or pointers |
| `cformat(...)` | a format string and its arguments, built while specializing |
| `require "nua.libc"` | load `lib/libc.nua` once per compilation and return its vocabulary table (§2.1) |

**Formats are decided by the compiler.** `cformat("n = ", n, ", ratio = ", ratio, "\n")` produces the format `"n = %u, ratio = %g\n"` and the arguments cast to the types those conversions expect, so a format can never disagree with its values. Lua strings and numbers, and known native values, go into the format itself:

```c
void greet(uint32_t times) {
    printf("hello 3 times, then %u (true)\n", (unsigned)times);
}
```

### 17.3 The library

`lib/libc.nua` declares the externs and returns a vocabulary:

```lua
local FILE = opaque "FILE"
local fopen = extern("fopen", { CString, CString }, Ptr FILE, { header = "<stdio.h>" })
local fclose = extern("fclose", { Ptr FILE }, I32, { header = "<stdio.h>" })

local File = struct { handle: Ptr FILE }
function File:write(s: CString): Unit
    fputs(s, self.handle)
end
function File:say(..parts): Unit
    fprintf(self.handle, cformat(..parts))
end

local with_file = do(path: CString, mode: CString, body): Bool
    local h: Ptr FILE = fopen path mode
    if h == null FILE then
        return false
    end
    local file = File { handle = h }
    body(Ref file)
    fclose h
    return true
end
```

It also provides `say` (formatted `printf`), `each_byte(path) do(b) ... end` (an activity built on `with_file`), and `with_buffer(n) do(buffer..) ... end` with `data`, `size` and `fill`.

### 17.4 Using it

```lua
local c = require "nua.libc"

local report = do(path: CString, n: U32, ratio: F64): Bool
    local c..
    return with_file(path, "w"):
        write "report\n"
        say("n = ", n, ", ratio = ", ratio, "\n")
        if n > 10 then
            return  -- leaves the body only: the file is still closed
        end
        say "small\n"
    end
end
```

```c
bool report(const char *path, uint32_t n, double ratio) {
    FILE *t = fopen(path, "w");
    if (t == NULL) {
        return false;
    }
    fputs("report\n", t);
    fprintf(t, "n = %u, ratio = %g\n", (unsigned)n, (double)ratio);
    if (n > 10u) {
        goto L1;
    }
    fprintf(t, "small\n");
L1:;
    fclose(t);
    return true;
}
```

The early `return` jumps to `fclose`; there is no path that leaves the file open. Inside the body, `write` and `say` are the receiver's methods (§10.5), and `say` resolves to `File:say`, not the library's `say`: the innermost receiver's member wins.

A heap buffer, written through its `Ptr`, read through a checked `Slice`:

```lua
local sum_filled = do(n: U32, byte: U8): U32
    local c..
    local total: U32 = 0
    with_buffer n:
        fill byte
        data[0] = 1
        local bytes = Slice(data, size)
        local i: U32 = 0
        while i < bytes.length do
            total = total + U32 bytes[i]
            i = i + 1
        end
    end
    return total
end
```

```c
uint32_t sum_filled(uint32_t n, uint8_t byte) {
    uint32_t total;
    U8Slice bytes;
    uint8_t *t = malloc((uint64_t)n);
    if (t == NULL) {
        total = 0u;
        goto L1;
    }
    memset(t, (int32_t)byte, (uint64_t)n);
    t[0ull] = 1u;
    total = 0u;
    bytes = (U8Slice){ .ptr = t, .len = (uint64_t)n };
    uint64_t i = 0ull;
    for (;;) {
        if (i >= bytes.len) break;
        total = total + (uint32_t)bytes.ptr[i];
        i = i + 1ull;
    }
    free(t);
L1:;
    return total;
}
```

The slice index is checked, and the check is gone: the loop's condition already proved `i < n` on the path that reads `bytes[i]` (§12.2).

The same approach extends to any C API with resources: sockets, locks, directories, a GPU context. The vocabulary is the API, and the activity is its lifetime.

## 18. POSIX and Linux as activities

In Unix everything is a file, and in Linux nearly everything is a file descriptor: files, pipes, sockets, devices, timers, event counters, the epoll set itself. A descriptor has a lifetime, which makes it an activity: open, run the body, close. `lib/posix.nua` wraps the kernel interface this way. The completion guarantee matters more here than anywhere: a leaked descriptor or mapping is a real class of bug, and a body's `return` cannot skip the `close`.

### 18.1 Talking to the kernel correctly

| Form | Meaning |
|---|---|
| `cstruct("struct stat", "<sys/stat.h>", { { "size", I64, "st_size" } })` | a struct whose **layout comes from the header**; only the named fields are seen, each optionally mapped to a C member path |
| `cconst("O_RDONLY", I32, "<fcntl.h>")` | a constant whose **value comes from the header** (a runtime value: platform values are always right) |
| `cread("errno", I32, "<errno.h>")` | a C variable or macro, read where it is called |
| `bytes(place)` | the storage of a place as `Ptr U8` (its lifetime dropped, as with `Ptr(place)`) |
| `size_of(T)` | the C size of a type |
| `view_of(p, n, body)` | lend a scoped read-only view, with escape and native-boundary checks (§12.6) |

Declaring kernel structs by hand risks ABI mismatches (`struct epoll_event` is packed on x86-64; `struct stat` differs between architectures). A `cstruct` emits no definition of its own: the C compiler supplies the real layout, and a field like `{ "fd", I32, "data.fd" }` reaches into nested unions.

For a recursive foreign layout, the fields argument may be a host function. It
receives the type being declared and returns the same field list:

```lua
local Node = cstruct("struct node", '"node.h"', function(Self)
        return { { "next", Ptr Self }, { "value", U32 } }
    end)
```

The callback runs once during type construction, not at runtime. The incomplete
type may occur behind a pointer, not as a by-value field (including an array
element). This describes an existing C layout; it does not introduce shared
references between tasks or change the ownership rules.

### 18.2 The library

- `with_fd(path, flags) do(writing..) ... end` returns an **`Outcome`**, `oneof { done: Unit, failed: I32 }` carrying the errno. Inside, the body has `write_text`, `write_bytes`, `read_bytes`, `size` and `mapped`.
- `mapped(n) do(bytes) ... end` maps the file's first `n` bytes as a read-only `Slice U8` that ends with its `munmap`.
- `with_eventfd do(counter..) ... end` gives a kernel counter that is a descriptor.
- `with_epoll do(poll..) ... end` gives `watch(fd)` and `next_ready(timeout_ms)`.

**Failures are the activity's outcome.** The `Fd` context records the first failed call's errno (every `read` and `write` result is checked, as `warn_unused_result` demands), and `with_fd` reports it as `failed(e)`: the completion policy belongs to the activity.

### 18.3 Using it

```lua
local px = require "nua.posix"

local make_file = do(path: CString): I32
    local px..
    return with_fd(path, bor(O_WRONLY, bor(O_CREAT, O_TRUNC))):
        write_text "NUA1"
        write_text "hello, kernel\n"
    end { done() = 0, failed(e) = e }
end
```

The outcome is matched right where the activity ends: `with_fd(...) do ... end { ... }` is one saturating chain whose surplus argument, the handler table, applies to the result.

```c
int32_t make_file(const char *path) {
    Fd file;
    int32_t payload;
    int32_t t = open(path, O_WRONLY | (O_CREAT | O_TRUNC), 420u);
    if (t < 0) {
        payload = errno;
        goto L1;
    }
    if (write(t, "NUA1", 4ull) < 0ll) {
        file.error = errno;
    } else {
        file.error = 0;
    }
    if (write(t, "hello, kernel\n", 14ull) < 0ll && file.error == 0) {
        file.error = errno;
    }
    close(t);
    if (file.error != 0) {
        payload = file.error;
        file.fd = t;
        goto L1;
    }
    file.fd = t;
    return 0;
L1:;
    return payload;
}
```

Constants are the header's (`O_WRONLY | (O_CREAT | O_TRUNC)`); text known while specializing has a known length (`4ull`); the first write's "no error yet" test folded away, because the evaluator knows the error is still 0 there.

A mapping is a view, so the header format idiom applies (§12.3): one sub-slice of known length, then constant offsets, with no check left:

```lua
mapped 4: bytes
    local h = bytes:sub(0, 4)
    found = U32(h[0]) * 16777216 + U32(h[1]) * 65536 + U32(h[2]) * 256 + U32(h[3])
end
```

```c
        t = mmap(NULL, 4ull, PROT_READ, MAP_PRIVATE, t2, 0ll);
        if (t == MAP_FAILED) {
            found = 0u;
            goto L3;
        }
        found = (uint32_t)t[0ull] * 16777216u + (uint32_t)t[1ull] * 65536u + (uint32_t)t[2ull] * 256u + (uint32_t)t[3ull];
        munmap(t, 4ull);
    L3:;
```

And the kernel's own event machinery, an eventfd watched by epoll, as a spine of activities:

```lua
local ping = do(n: U64): U64
    local px..
    local got: U64 = 0
    with_eventfd:
        local value = n
        write_bytes(bytes value, size_of U64)
        with_epoll:
            watch fd
            if next_ready 100 == fd then
                local back: U64 = 0
                read_bytes(bytes back, size_of U64)
                got = back
            end
        endall
    return got
end
```

Inside `with_epoll`, `fd` is still the counter's field and `watch` the poll's method: nested openings compose with lexical shadowing (naming the activity parameter `fd` would let the opened field shadow that parameter, so a distinct receiver name remains useful for qualification).

### 18.4 What is next

Shared-memory kernel interfaces (io_uring rings, futexes) use the atomics of §19. Arrays of kernel structs (`epoll_wait` filling many events) are fixed-length arrays (§13) of `cstruct` types.

## 19. Atomics

Atomics serve two kinds of sharing: state shared between threads of a program, and memory shared with the kernel (io_uring's rings, futex words).

### 19.1 The type and its operations

`Atomic T`, for an integer, a `Bool` or a pointer, is a struct field or a typed local that is **accessed only by atomic operations**: a plain read or write is rejected, and atomics are never copied (a struct holding one cannot be read as a whole). Its initialization is the one plain store, before anything is shared.

| Operation | Result |
|---|---|
| `a:load(order)` | the value |
| `a:store(v, order)` | — |
| `a:exchange(v, order)` | the value before |
| `a:add(v, order)`, `a:sub(v, order)` (integers) | the value before |
| `a:cas(expected, desired, order)` | `true` when the value was `expected` and is now `desired` |
| `fence(order)` | a memory fence |
| `atomic_ptr(p)` | `Ptr T` viewed as `Ptr (Atomic T)`: the boundary form for shared memory from C or the kernel |

**Memory orders are compile-time arguments**, `"relaxed"`, `"acquire"`, `"release"`, `"acq_rel"` or `"seq_cst"` (the default), and the orders C leaves undefined are rejected while compiling: a load cannot be `release` or `acq_rel`, a store cannot be `acquire` or `acq_rel`. A compare-and-swap derives its failure order from its success order.

**In C**, an atomic is a plain `T` accessed with the GCC/Clang `__atomic` builtins. They work in C99 (`<stdatomic.h>` would need C11), and the layout of a struct holding atomics stays identical to the C caller's or the kernel's.

**In the evaluator**, atomic operations are effects: never folded, never kept pending, never tracked, and emitted in source order. Atomic places are not tracked even inside a local struct whose other fields are.

### 19.2 A spinlock is an activity

```lua
local SpinLock = struct { held: Atomic Bool }
local with_lock = do(lock: Ref SpinLock, body): Unit
    while not lock.held:cas(false, true, "acquire") do
    end
    body
    lock.held:store(false, "release")
end

local Shared = struct { lock: SpinLock, total: U64 }
local add_locked = do(s: Ref Shared, times: U32): Unit
    local i: U32 = 0
    while i < times do
        with_lock(Ref s.lock) do
            s.total = s.total + 1
        end
        i = i + 1
    end
end
```

The release is the activity's completion, so it cannot be skipped by the body's `return`.

```c
void add_locked(Shared *s, uint32_t times) {
    bool t;
    uint32_t i = 0u;
    for (;;) {
        if (i >= times) {
            return;
        }
        for (;;) {
            t = false;
            if (__atomic_compare_exchange_n(&s->lock.held, &t, true, false, __ATOMIC_ACQUIRE, __ATOMIC_ACQUIRE)) break;
        }
        s->total = s->total + 1ull;
        __atomic_store_n(&s->lock.held, false, __ATOMIC_RELEASE);
        i = i + 1u;
    }
}
```

The expected value is reset on every round of the spin, as a compare-and-swap requires (it overwrites `expected` on failure).

### 19.3 A ring shaped like io_uring's

A single-producer single-consumer ring publishes with release stores of its indices and observes with acquire loads:

```lua
local Ring = struct { head: Atomic U32, tail: Atomic U32, mask: U32, slots: Ptr U32 }

local push = do(r: Ref Ring, v: U32): Bool
    local tail: U32 = r.tail:load "relaxed"
    local head: U32 = r.head:load "acquire"
    if tail - head > r.mask then
        return false  -- full
    end
    r.slots[band tail r.mask] = v
    r.tail:store(tail + 1, "release")
    return true
end
```

```c
bool push(Ring *r, uint32_t v) {
    uint32_t t = __atomic_load_n(&r->tail, __ATOMIC_RELAXED);
    uint32_t t2 = __atomic_load_n(&r->head, __ATOMIC_ACQUIRE);
    if (t - t2 > r->mask) {
        return false;
    }
    r->slots[t & r->mask] = v;
    __atomic_store_n(&r->tail, t + 1u, __ATOMIC_RELEASE);
    return true;
}
```

The consumer side returns a sum (`oneof { empty: Unit, value: U32 }`), matched by the draining loop. For io_uring itself, the ring indices live in memory mapped from the kernel: `atomic_ptr` turns the plain pointers `mmap` returns into atomic ones.

### 19.4 Checked with real threads

The C harness drives these words from POSIX threads (four threads bumping a counter, four contending on the lock, a producer and a consumer passing 200 000 values through the ring) and checks exact totals. It also runs under **ThreadSanitizer**, which reports no data races; a deliberately non-atomic version of the counter is reported, so the check has teeth. (The ThreadSanitizer build uses clang, whose runtime models standalone fences.)

## 20. Tasks, channels and I/O

Nua takes Go's concurrency model, communicating sequential tasks, and fits it to a
language with no garbage collector, with words evaluated in place, and with explicit
loop state. Four rules carry the design. Everything else follows from them.

1. **A task owns its memory.** Nothing is shared between tasks. Values cross by
   copy, and slots of a pool cross by move.
2. **Every wait is an operation the compiler can see,** in the task's own body.
3. **Every lifetime is a scope.** Tasks, channels and pools belong to the `tasks`
   scope that made them, and the scope ends only when all its tasks have.
4. **There is one way to wait.** An operation is started and later completes.
   `first_of` chooses among operations the runtime can take back.

What this rules out, on purpose: locks, shared mutable memory, and an ownership type
system to police them. Atomics (§19) remain for memory shared with the kernel and for
library internals; they are not how tasks cooperate.

### 20.1 Scopes

```lua
tasks:
    local jobs = channel(Job, 16)
    spawn do
        for i: U32 = 1, n do jobs:send(Job { id = i, n = i }) end
        jobs:close
    end
    jobs:each(do(j) total = total + U64(j.n) end)
end
```

`tasks` is an activity (§10.3). Its body opens a vocabulary:

| Word | Meaning |
|---|---|
| `spawn do ... end` | start a task running the block |
| `spawn(f, args...)` | sugar for `spawn do f(args...) end` |
| `channel(T, n)` | a channel of `T` with `n` buffered slots; `n = 0` is unbuffered |
| `pool(T, n)` | `n` slots of `T` whose ownership moves between tasks (§20.6) |

**The scope's end is a wait.** It completes when the body has finished and every task spawned in the scope has finished. Then the channels and pools retire. A scope does not cancel anything: it waits. A scope that would wait forever is a deadlock, and the scheduler reports it (§20.8).

**The scope body is the enclosing code, continued.** It runs in sequence with the code around it, so it reads and writes that code's locals freely; `total` above is one. Spawned tasks are not the enclosing code, and the next section says what they can reach.

* *Inside a task*, the body is part of that task. Its waits suspend the task, and so does the scope's end.
* *In plain code*, such as an exported function called from C, the body runs on the calling thread, and its waits **block** that thread instead of suspending it. The compiler emits the same runtime call in both cases. A blocked thread is not idle: it runs tasks from the scheduler's queue until its own wait completes. So a scope in plain code costs no closure conversion, and with no worker threads at all (deterministic mode, §20.8) everything runs on the blocked thread.

Scopes nest. A task may open its own scope. It may also spawn into the scope it belongs to, or make channels and pools in it, because a task carries its scope's handle implicitly. Everything it makes there still ends with that scope.

### 20.2 What a task reaches

```lua
spawn do
    for i: U32 = 1, n do jobs:send(Job { id = i, n = i }) end
    jobs:close
end
```

A spawned block may mention:

* **Runtime names from outside, as copies.** Every outer typed local, parameter or introduced name the block mentions (`n` and `jobs` here) is copied into the task when it is spawned. The set is the one the compiler already computes for loop state (§6.4): the names the block mentions. Each copied name must have a *sendable* type (§20.5), and assigning one inside the block is rejected. A copy that looked like shared state would be the one way to misread the model.
* **Compile-time values, as facts.** Known values, types, words and Lua data are baked into the task's specialization, as in any word (architecture §5). A spawn inside a host loop unrolls.
* **Its own locals,** which nobody else can reach.

`spawn(f, a, b)` evaluates `a` and `b` in the spawning code and copies them; it is exactly `spawn do f(a, b) end`. Either way, the task's result is `Unit`. Results are sent on channels.

### 20.3 What a task compiles to

A task is not a thread. It compiles to a **resumable C function**: a frame struct holding the task's typed locals and its copies, and a step function that runs until the next wait and returns. Two properties of Nua make this both possible and cheap:

* **Words are evaluated in place (architecture §5),** so a `send` inside a word inside a callback lands in the task's own body. No `async` marks the words that may wait: there is no call to mark, so there is no function coloring.
* **Loop state is explicit (§6.4),** so the locals live at each wait are known exactly.

```lua
local square = do(inp: Chan U32, out: Chan U64): Unit
    inp:each: v
        out:send(U64 v * U64 v)
    end
    out:close
end
```

Spawned with `spawn(square, nums, squares)`, it becomes a frame and a step function:

```c
typedef struct square_frame {
    nua_task task;
    nua_op ops[1];
    nua_chan inp;
    nua_chan out;
    bool open;
    uint32_t got;
    int32_t r;
    ReceivedU32 r2;
    uint64_t msg;
} square_frame;
```

```c
static nua_step square_step(nua_task *nua_task_) {
    square_frame *f = (square_frame *)nua_task_;
    switch (f->task.state) {
    case 1: goto resume1;
    case 2: goto resume2;
    case 3: goto resume3;
    default: break;
    }
    f->open = true;
    for (;;) {
        if (nua_budget(&f->task)) {
            f->task.state = 1;
            return NUA_YIELD;
        }
    resume1:;
        if (!f->open) break;
        if (nua_recv(&f->task, f->ops, f->inp, &f->got, "channels.nua:8: recv") == NUA_PENDING) {
            f->task.state = 2;
            return NUA_WAIT;
        }
    resume2:;
        f->r = f->task.result;
        if (f->r == 1) {
            f->r2 = (ReceivedU32){ .tag = ReceivedU32_value, .as.value = f->got };
            goto L1;
        }
        f->r2 = (ReceivedU32){ .tag = ReceivedU32_closed };
    L1:;
        if (f->r2.tag == ReceivedU32_closed) {
            f->open = false;
        } else {
            f->msg = (uint64_t)f->r2.as.value * (uint64_t)f->r2.as.value;
            if (nua_send(&f->task, f->ops, f->out, &f->msg, "channels.nua:9: send") == NUA_PENDING) {
                f->task.state = 3;
                return NUA_WAIT;
            }
        resume3:;
        }
    }
    nua_chan_close(f->out);
    return NUA_DONE;
}
```

The copies are named after the word's parameters, `inp` and `out`. Each wait passes its site, the source line, which a deadlock report prints.

Jumping into a loop body is ordinary C99, so the lowering is portable: no stack switching and no assembly.

* **A wait owns its operation records** (`nua_op`) in the frame: one, or one per case of a `first_of`. Waiting allocates nothing: the record is linked into a channel's queue or handed to the I/O backend, and whoever completes it writes the result into the record and makes the task runnable.
* **Each task has its own data stacks** (architecture §7). They are heap buffers addressed by offset, so a suspended task's stores and Grow arrays stay where they are. A worker switches to a task's stack set when it runs the task, and back to its own afterwards. The frame never moves, so references into the task's own locals stay valid across waits.
* **Loop back-edges count down a budget** and yield when it runs out. The compiler knows every residual loop, because loops are tail calls (§6), so a task that never waits still cannot starve the others. This is cooperative scheduling with the cooperation inserted by the compiler. Only a long call into C goes unchecked.

**The one restriction.** A task cannot wait inside a word that is compiled as its own C function: a recursion re-entered in non-tail position (architecture §5). Plain code may, since it blocks rather than suspends. Such a function has a real C stack frame, which cannot be suspended. Tail recursion is a loop and is fine. Non-tail recursion that waits is written with an explicit stack in a Grow. The design leaves room for a later extension that lays such frames on the task's data stack, which amounts to segmented stacks.

The scope body that spawned it is plain code, an export. Its waits block, and `nua_self()` names the calling thread as a party the runtime can wake:

```c
uint64_t sum_squares(uint32_t n) {
    nua_task *nua_tk = nua_self();
    nua_op nua_ops[1];
    uint64_t got;
    int32_t r;
    ReceivedU64 r2;
    nua_scope *scope = nua_scope_new(nua_tk);
    nua_chan ch = nua_chan_new(scope, (uint64_t)sizeof(uint32_t), 8u);
    nua_chan ch2 = nua_chan_new(scope, (uint64_t)sizeof(uint64_t), 8u);
    { task_frame *nua_t = (task_frame *)nua_spawn(scope, sizeof(task_frame), task_step); nua_t->nums = ch; nua_t->n = n; nua_start(&nua_t->task); }
    { square_frame *nua_t = (square_frame *)nua_spawn(scope, sizeof(square_frame), square_step); nua_t->inp = ch; nua_t->out = ch2; nua_start(&nua_t->task); }
    uint64_t total = 0ull;
    bool open = true;
    for (;;) {
        if (!open) break;
        if (nua_recv(nua_tk, nua_ops, ch2, &got, "channels.nua:28: recv") == NUA_PENDING) nua_block(nua_tk);
        r = nua_tk->result;
        if (r == 1) {
            r2 = (ReceivedU64){ .tag = ReceivedU64_value, .as.value = got };
            goto L1;
        }
        r2 = (ReceivedU64){ .tag = ReceivedU64_closed };
    L1:;
        if (r2.tag == ReceivedU64_closed) {
            open = false;
        } else {
            total = total + r2.as.value;
        }
    }
    if (nua_scope_end(nua_tk, nua_ops, scope, "channels.nua:16: the end of a tasks scope") == NUA_PENDING) nua_block(nua_tk);
    return total;
}
```

A spawn allocates a zeroed frame, fills in the copies (the producer block captured `n` and the channel), and starts the task.

### 20.4 Operations and `first_of`

Every wait is an **operation**: it is started, and later it completes with a result. A single operation suspends the task until it completes:

| Operation | Completes with |
|---|---|
| `c:send(v)` | — (traps if `c` is closed) |
| `c:recv()` | `Received T`: `oneof { value: T, closed: Unit }` |
| `p:take()` | a `Slot T` the task now owns (§20.6) |
| `sleep(d)` | — (`d` is a `Duration`, built with `ns`, `us`, `ms` or `seconds`) |
| I/O (§20.7) | `oneof { done: U32, failed: I32 }`, and `timed_out` with a deadline |
| `blocking do ... end` | — (the block ran on a blocking thread) |
| a scope's end | — |

`c:recv() { value = do(v) ... end, closed = do ... end }` matches the receive directly, without building the sum. `c:each(do(v) ... end)` receives until the channel is closed and drained.

**`blocking do ... end`** is for calls into C that may block (a library that sleeps, a slow `fsync`). In a task, the block runs on a blocking thread while the task waits, so the call never holds a worker; the task's locals are its frame and the task is not running, so the block reads and writes them as they are. It compiles to a function over the frame. A block cannot wait (it runs outside the scheduler). In plain code the thread may block anyway, and the block simply runs in place.

**`first_of`** starts several operations and continues with the first one to complete:

```lua
first_of {
    recv(results) do(r) ... end,
    send(out, x) do ... end,
    take(buffers) do(s) ... end,
    after(ms(100)) do ... end,
    closed = do ... end,
    default = do ... end,
}
```

* Each case is an operation and a handler. `default` runs when no case is ready at once, and then nothing waits.
* A closed channel never fires its `recv` case. `closed` is ready once every `recv` case's channel is closed and drained, which is Go's merge idiom made explicit.
* A `send` case on a closed channel is always ready, and taking it traps, as in Go: it traps when it is the case taken, not merely because it is listed.
* A `first_of` with a `recv` case must have `closed` or `default`, or it is rejected. Otherwise, once its channels close, it could only wait forever. This is the same exhaustiveness rule as matching (§11).
* When one case completes, the others are **withdrawn before the handler runs**, so exactly one case happens. A completing counterpart first claims the waiting task with a compare-and-swap on its selection word, so two senders cannot both deliver to it.
* Ready cases are scanned from a rotating start, for fairness.

The cases are known while compiling, so `first_of` is sequenced where it is written (`lib/select.nua`): the program fills the operation records itself, and a shared function per shape of `first_of` (its kinds in order, and whether it has a default) makes one attempt per case through the runtime's `nua_poll_recv`, `nua_poll_send` and `nua_poll_take`, each one locked edit. Only when nothing is ready and there is no default does it wait, on every record, through `nua_select_arm`. No case array is built, no case kind is looked up at run time, and the clock is read only when a case waits on time: a two-case select over ready channels runs about 2.4 times faster than the interpreter it replaced.

**Why I/O is never a case of `first_of`.** A channel operation, a pool take and a timer belong to the runtime, which can take them back exactly: a withdrawn receive has received nothing. The kernel's work cannot be taken back. A read that loses the race may already have consumed bytes from the socket, and then they are gone. So `first_of` admits only operations the runtime can withdraw, and an I/O case is rejected. The two needs behind such a case have direct forms:

* *I/O with a time limit:* give the operation a deadline. Its result gains `timed_out`, and the result is exact: if bytes were read, the result says `done` with their count, never `timed_out`.
* *I/O raced against something else:* spawn a task that does the I/O and sends the result on a channel, and put that channel in the `first_of`.

### 20.5 Channels

`Chan T` is a value: a handle that is copied freely, stored in structs and sent on channels, including channels of channels. A channel lives as long as the scope that made it.

**Sendable types**, for channel elements and for copies taken at spawn:

* scalars, `Bool`, `Duration`;
* structs and sums made of sendable types;
* `Chan T` and `Pool T`: handles to runtime-synchronized objects of the same scope;
* `Slot T` (§20.6), which moves rather than copies. A slot anywhere inside a message moves with it: the compiler knows where slots sit in the message's layout, and emits the ownership transfer for each one.

Never `Ref`, `Ptr`, `Slice`, `CString`, `Atomic` or a store `Id`, at any depth. Each of those points into memory someone else owns. The diagnostic names the offending field or alternative.

**Semantics**, as in Go:

* A send on a buffered channel waits while the channel is full. A send on an unbuffered channel completes when a receiver has taken the value; the value goes straight from the sender's frame into the receiver's.
* `close` means no more values. Receivers drain what is buffered, then see `closed`.
* Sending on a closed channel, or closing one twice, traps.

**Handles are generational,** like IDs (§9.8). A handle kept past its scope, by storing it in a longer-lived struct or by sending it to an outer task, traps on its next use. It never reaches freed memory. Channel records live in a registry that only grows, so a stale handle always lands on a live record that knows it is stale.

### 20.6 Pools: moving instead of copying

Copying is right for messages and wrong for buffers. A pool moves them instead:

```lua
local Block = struct { n: U32, data: Array(U8, 64) }

local pooled = do(count: U32): U64
    local total: U64 = 0
    tasks:
        local buffers = pool(Block, 4)
        local full = channel(Slot Block, 4)
        spawn do
            local k: U32 = 0
            while k < count do
                local s = buffers:take()  -- waits while all four are out
                fill(buffers[s], k)  -- buffers[s]: checked at every use
                full:send s  -- s now belongs to the receiver
                k = k + 1
            end
            full:close
        end
        full:each: s
            total = total + U64(checksum buffers[s])
            buffers:release s
        endall
    return total
end
```

* `pool(T, n)` reserves `n` slots of the fixed-size, sendable type `T` once, when called. The pool never grows, so slots never move.
* `p:take()` is an operation: it waits for a free slot and returns a `Slot T` owned by the current task. Because a take can be withdrawn, `take(p) do(s) ... end` is a `first_of` case, which gives backpressure among other waits.
* `p[s]` is the slot's contents as a place: read it, assign it or its fields, pass it as a reference, read into it. Every use checks that the current task owns `s`, as a slice checks its index: inline and lock-free, a few atomic loads. Uses that nothing separates share one check (§10.6), and a send or release of any slot ends the stretch, so a name bound to `p[s]` and used after `s` was sent traps at that use.
* Sending a `Slot` on a channel moves it, alone or as a field of a message: the sender gives it before the send, and whoever receives it adopts it. A send case of `first_of` that loses keeps its slots: every other arm takes them back.
* `p:release(s)` gives the slot back to the pool, or straight to a task waiting to take one.

The consumer above compiles to the receive, the adoption, and one checked address per round of the loop:

```c
uint64_t pooled(uint32_t count) {
    nua_task *nua_tk = nua_self();
    nua_op nua_ops[1];
    nua_slot got;
    int32_t r;
    ReceivedSlotBlock r2;
    uint32_t s;
    uint32_t i;
    Block *at;
    nua_scope *scope = nua_scope_new(nua_tk);
    nua_pool pool = nua_pool_new(scope, (uint64_t)sizeof(Block), 4u);
    nua_chan ch = nua_chan_new(scope, (uint64_t)sizeof(nua_slot), 4u);
    { task_11_frame *nua_t = (task_11_frame *)nua_spawn(scope, sizeof(task_11_frame), task_11_step); nua_t->buffers = pool; nua_t->full = ch; nua_t->count = count; nua_start(&nua_t->task); }
    uint64_t total = 0ull;
    bool open = true;
    for (;;) {
        if (!open) break;
        if (nua_recv(nua_tk, nua_ops, ch, &got, "channels.nua:343: recv") == NUA_PENDING) nua_block(nua_tk);
        r = nua_tk->result;
        if (r == 1) {
            nua_slot_adopt(nua_tk, got);
            r2 = (ReceivedSlotBlock){ .tag = ReceivedSlotBlock_value, .as.value = got };
            goto L1;
        }
        r2 = (ReceivedSlotBlock){ .tag = ReceivedSlotBlock_closed };
    L1:;
        if (r2.tag == ReceivedSlotBlock_closed) {
            open = false;
        } else {
            i = 0u;
            s = 0u;
            for (;;) {
                at = (Block *)nua_slot_at(nua_tk, r2.as.value);
                if (i >= at->n) break;
                if ((uint64_t)i >= 64ull) {
                    nua_trap("slice index out of range");
                }
                s = s + (uint32_t)at->data.e[(uint64_t)i];
                i = i + 1u;
            }
            total = total + (uint64_t)s;
            nua_slot_release(nua_tk, r2.as.value);
        }
    }
    if (nua_scope_end(nua_tk, nua_ops, scope, "channels.nua:330: the end of a tasks scope") == NUA_PENDING) nua_block(nua_tk);
    return total;
}
```

**Correctness comes from the runtime, convenience from the compiler.** Every slot records its owner by task id (ids are never reused, unlike frame addresses). Using, giving or releasing a slot the current task does not own traps, as a stale ID does (§9.8), and so does using a slot after it was released (slots are generational). A slot cannot leave its pool's scope: taking from a pool, or receiving one of its slots, outside that scope traps. And a pool's memory is never freed while its record can be named (a retired pool's memory waits for the next pool that fits), so even a stale slot fails its check on memory that is still there. On top of that, the compiler rejects the plain mistake, naming a slot again after it was sent or released on the same path: `this slot was sent at prog.nua:7: send; it no longer belongs to this task` (the site of the send). A mark made in one branch says nothing about the other branch or after the join, where the runtime check decides. A slot that is never released stays out of the pool until the scope ends, when the whole pool is freed: a leak bounded by the scope, never unsafety.

### 20.7 I/O by completion

I/O operations are described by their completion, never by readiness, because completion can be provided everywhere and readiness cannot. **io_uring** is completion-based: you submit an operation, and the kernel says when it is done. **kqueue** (macOS, the BSDs) and **`poll`** (any POSIX system) report readiness; their backends make it a completion by performing the system call once the descriptor is ready. A wait is the same shape on every system, and so is a program. (Windows is out of scope.)

The operations live in a library, `local io = require "nua.io"`, like the libc and POSIX vocabularies (§17–§18):

| Operation | Done with | Notes |
|---|---|---|
| `io.read(f, buf [, n] [, opts])` | the count read (0 at the end) | `buf` is an `Array(U8, N)` itself: a local, a field, a pool slot's field (`pool[s].bytes`) |
| `io.write(f, data [, n] [, opts])` | the count written | `data` is an `Array(U8, N)`, a `Slice U8`, or a string known while compiling |
| `io.open(path, flags [, mode])` | a `File` | flags `io.READ`, `io.WRITE`, `io.READ_WRITE`, `io.CREATE`, `io.TRUNCATE`, `io.APPEND` (from the system's headers) |
| `io.close(f)` | — | |
| `io.accept(listener [, opts])` | a `File` | |
| `io.connect(host, port [, opts])` | a `File` | IPv4 TCP; `io.LOOPBACK`, `io.ANY` |
| `io.pipe()`, `io.listen(host, port)` | a `Pipe`, a `File` | setup that never waits |

* **Options** are `{ at = offset }` for positioned reads and writes, and `{ deadline = d }`. A deadline adds `timed_out` to the result, and the result is exact: on a readiness backend the system call happens only once the descriptor is ready, so `timed_out` means nothing was done; on io_uring the deadline is a linked timeout, and an operation that finished first keeps its result.
* **Results are sums**, `oneof { done: U32, failed: I32 }` and its relatives, matched exhaustively; `failed` carries the system's error code (`io.ENOENT`, `io.ECONNREFUSED`, ... come from the headers). A handler table may follow the call directly: `io.read(f, buf) { done = do(n) ... end, failed = do(e) ... end }`.
* **Suspension is the borrow.** During an operation its task is suspended (plain code: blocked), so nobody but the system touches the buffer. That holds for any memory the task owns, so no extra ownership rule is needed. Reading into a pool slot and then sending the slot is zero-copy I/O between tasks.
* **I/O is never a `first_of` case**: `I/O cannot lose a first_of: give io.read a deadline ({ deadline = d }), or spawn a task that does it and receive its result` (§20.4).
* **Regular files never hold a worker or the poller.** On io_uring a file read is asynchronous in the kernel. A readiness backend hands regular-file reads and writes, and every `open` and `close`, to the blocking threads, since a regular file is always "ready" and the call blocks.

A plain-code example, with a deadline that expires on an empty pipe and then data that arrives:

```c
uint32_t timeout_then_data(void) {
    nua_task *nua_tk = nua_self();
    nua_op nua_ops[1];
    uint32_t outcome;
    int32_t reader;
    int32_t writer;
    int64_t io;
    IoPipe r;
    U8x8 buf;
    int64_t io2;
    int32_t r2;
    IoCountOrTimeout r3;
    int64_t io3;
    int32_t r4;
    int64_t io4;
    int32_t r5;
    IoCountOrTimeout r6;
    int64_t io5;
    int32_t r7;
    int64_t io6;
    int32_t r8;
    if (nua_io_pipe(&reader, &writer, &io) == 0) {
        r = (IoPipe){ .tag = IoPipe_done, .as.done = (Pipe){ .reader = (File){ .fd = reader }, .writer = (File){ .fd = writer } } };
        goto L1;
    }
    r = (IoPipe){ .tag = IoPipe_failed, .as.failed = (int32_t)io };
L1:;
    if (r.tag == IoPipe_done) {
        buf = (U8x8){ .e = { 0 } };
        if (nua_io_read(nua_tk, nua_ops, r.as.done.reader.fd, &buf.e[0u], 8u, -1ll, 20000000ull, &io2, "io.nua:72: read") == NUA_PENDING) nua_block(nua_tk);
        r2 = nua_tk->result;
        if (r2 == 0) {
            r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_done, .as.done = (uint32_t)io2 };
            goto L2;
        }
        if (r2 == 2) {
            r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_timed_out };
            goto L2;
        }
        r3 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_failed, .as.failed = (int32_t)io2 };
    L2:;
        switch (r3.tag) {
        case IoCountOrTimeout_done: {
            outcome = 100u;
            break;
        }
        case IoCountOrTimeout_failed: {
            outcome = 200u;
            break;
        }
        default: /* IoCountOrTimeout_timed_out */ {
            outcome = 1u;
            break;
        }
        }
        if (nua_io_write(nua_tk, nua_ops, r.as.done.writer.fd, "abc", 3u, -1ll, 0ull, &io3, "io.nua:77: write") == NUA_PENDING) nua_block(nua_tk);
        r4 = nua_tk->result;
        if (r4 != 0) {
        }
        if (nua_io_read(nua_tk, nua_ops, r.as.done.reader.fd, &buf.e[0u], 8u, -1ll, 1000000000ull, &io4, "io.nua:78: read") == NUA_PENDING) nua_block(nua_tk);
        r5 = nua_tk->result;
        if (r5 == 0) {
            r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_done, .as.done = (uint32_t)io4 };
            goto L3;
        }
        if (r5 == 2) {
            r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_timed_out };
            goto L3;
        }
        r6 = (IoCountOrTimeout){ .tag = IoCountOrTimeout_failed, .as.failed = (int32_t)io4 };
    L3:;
        if (r6.tag == IoCountOrTimeout_done) {
            outcome = outcome + 10u * r6.as.done;
        }
        if (nua_io_close(nua_tk, nua_ops, r.as.done.reader.fd, &io5, "io.nua:83: close") == NUA_PENDING) nua_block(nua_tk);
        r7 = nua_tk->result;
        if (r7 != 0) {
        }
        if (nua_io_close(nua_tk, nua_ops, r.as.done.writer.fd, &io6, "io.nua:84: close") == NUA_PENDING) nua_block(nua_tk);
        r8 = nua_tk->result;
        if (r8 != 0) {
        }
    } else {
        outcome = 0u;
    }
    return outcome;
}
```

The `failed` arms the program left empty disappeared; the match is the branch on the result.

### 20.8 Deadlocks, determinism, failure

* **Deadlock is detected exactly.** Suppose no task is runnable or running, no plain thread is active in a scope, and no timer or I/O operation is outstanding, yet some task or thread is waiting. Then nothing can ever wake it, because only tasks and scope bodies touch channels and pools. The runtime traps with `deadlock: every task is waiting` and names the wait each party is suspended in. The classic leak, a goroutine blocked forever on a channel nobody closes, becomes this diagnostic at the scope's end.
* **Deterministic mode.** With `NUA_SCHED_SEED=n`, the runtime starts no workers. The blocked plain thread runs every task, with a seeded choice among runnable tasks and ready cases. A failing concurrent test can be replayed exactly, apart from the timing of real I/O and timers.
* **A trap aborts the process,** as an unrecovered panic does in Go: an out-of-range index, a stale handle, a send on a closed channel, a slot used by a task that does not own it.
* **Cancellation is closing a channel.** There is no separate mechanism, so no operation grows a third outcome. A deadline bounds a single I/O operation; a task stops when it observes `closed`.

### 20.9 What is checked, and where

While compiling:

| Rejected | Diagnostic |
|---|---|
| a spawned block mentioning an unsendable runtime name | `a task shares no memory: the outside name 'c' is a Ref C, and a reference points into memory someone else owns; send values, or pass them to spawn` |
| assigning a copied name inside a spawned block | `'count' is a copy taken at spawn; a task cannot assign it (declare a local to change it)` |
| `spawn(f, ...)` with a non-`Unit` result | `a task's result goes nowhere; send it on a channel` |
| `spawn(f, ...)` with an unsendable parameter | `spawn: parameter 'c' of bump is a Ref C; a task shares no memory, ...` |
| an unsendable channel element | `Chan M: values crossing a channel are copies, and its field 'p' is a Ptr U8: ...` |
| a slot inside a oneof on a channel | `Chan M: a Slot inside a oneof cannot move (its ownership would depend on a runtime choice)` |
| a task waiting inside a function compiled on its own | `a wait inside walk, which is compiled as its own C function (...); a task cannot suspend inside it: loop by tail call, or keep an explicit stack` |
| a `first_of` with `recv` cases and neither `closed` nor `default` | ``first_of: when every channel is closed it runs `closed = do ... end`; give it one (or a default)`` |
| a `first_of` with `closed` but no `recv` case | ``first_of: `closed` runs when every received channel is closed, but no case receives`` |
| a receive matched without `closed` | `matching a ReceivedU32: alternative 'closed' has no handler` |
| a channel returned from its scope | `a channel cannot leave its tasks scope: it retires when the scope ends` |
| a slot named again after it was sent or released | `this slot was sent at prog.nua:7: send; it no longer belongs to this task` (the site of the send) |
| reading a slot's contents without its pool | `Slot B is a handle: its contents are addressed through its pool, pool[slot]` |
| a store addressed with something other than its Id | `Id: expected Id N, got U32` |
| an I/O operation as a case of `first_of` | `I/O cannot lose a first_of: give io.read a deadline ({ deadline = d }), or spawn a task that does it and receive its result` |
| a known count larger than its buffer | `io.read: 16 bytes do not fit a buffer of 8` |
| a wait inside `blocking do ... end` | `a blocking block runs outside the scheduler: it cannot wait (send); wait after it` |
| a timed operation matched without `timed_out` | `alternative 'timed_out' has no handler` |

At run time, these trap: a stale channel or pool handle, a send on a closed channel, closing twice, a slot used, given or released by a task that does not own it (including after sending it), a slot used after it was released, a pool used or a slot received outside its scope, a stale store Id or an out-of-range Grow index, a dynamic count larger than its buffer, and a deadlock.

Not checked: memory that C code shares behind an extern's back (§17.1), and a blocking call into C made outside `blocking do ... end`, which holds its worker.

### 20.10 The whole picture

| Need | Form |
|---|---|
| start work | `spawn do ... end`, `spawn(f, args...)` |
| pass a message | `channel(T, n)`, `send`, `recv`, `each`, `close` |
| pass a buffer | `pool(T, n)`, `take`, `pool[slot]`, `release`; send the `Slot` |
| wait for one of several | `first_of { ... }` over channels, pools and timers |
| talk to the system | `require "nua.io"`: operations by completion, optional deadlines |
| bound lifetimes | the `tasks` scope: joins its tasks, retires its channels and pools |
| share memory with the kernel | atomics (§19), inside libraries |

### 20.11 What is implemented

All of this section is built: tasks as state machines, the scheduler, channels, `first_of` over receives, sends, takes and timers, `spawn do`, pools and slots, `blocking` blocks on a blocking thread pool, I/O by completion with the `poll`, io_uring and kqueue backends, deadlock detection and deterministic mode.

The harnesses (`examples/channels.nua`, `examples/io.nua`) cover:

* a pipeline, a fan-out over four workers, `first_of` with `default`, timers, channels of channels, sum messages, nested scopes and a Grow inside a task;
* a pool pipeline, `take` as a case, and a send case that loses and keeps its slot;
* eight `blocking` blocks sleeping 50 ms each, which overlap (the run takes about 50 ms, with one worker or none);
* a pipe between tasks, a file read back at an offset, an exact timeout followed by data, a TCP echo server with twenty concurrent clients, reads straight into pool slots moved between tasks, and a refused connection.

They run in the default mode, with one worker and with seeded schedules. Every I/O check runs on all three backends, each under ThreadSanitizer, and the runtime checks (stale handles, ownership, deadlock reports) run in child processes. Hundreds of repeated runs per backend and mode found no failures.

Two bugs the backends taught, now fixed and kept in the tests:

* A kqueue poller must not touch a descriptor after completing its last operation. The woken task may already have closed it, and its number been reused; registrations are one-shot.
* A connect's error must come from the event (kqueue's `EV_EOF` carries it in `fflags`) or a confirmed peer, because `SO_ERROR` reads only once.

**Not built or not verified here:** work stealing, and kqueue on a BSD or macOS;
architecture §17.2 keeps the full list.

**Performance, measured on two cores.** A three-stage pipeline moves about 1.5 million values per second through two channels with workers, and about 7 million on one thread in deterministic mode; the cost with workers is lock traffic between threads, not waiting.

## 21. Native globals and function values

Two capabilities that the runtime needed and that any native program may use.

### 21.1 Globals

`global(T, opts)` is static storage for the whole program. It is the `Ptr T` of a C object, so `g[0]` is its place (and `g.field` a field of a record), read and written as memory in source order, never kept pending:

```lua
local hits = global(U32, { name = "hits" })
local per_thread = global(U32, { name = "per_thread", thread_local = true })
local seed = global(U32, { name = "seed", init = 100 })

local bump = do(n: U32): U32
    hits[0] = hits[0] + n
    return hits[0]
end
```

```c
static uint32_t hits;
static __thread uint32_t per_thread;
static uint32_t seed = 100u;

uint32_t bump(uint32_t n) {
    hits = hits + n;
    return hits;
}
```

| Option | Meaning |
|---|---|
| `name` | the C name (made unique at file scope); required for `exported` and `imported` |
| `thread_local` | one object per thread (`__thread`) |
| `shared` | permit task writes under the program's own synchronization; not a lock or an atomic conversion |
| `init` | a number the object starts with; otherwise it is zero |
| `exported` | external linkage: another unit, or a header, can name it |
| `imported`, `header` | defined elsewhere and declared by `header`, which the program includes |

A global cannot be Unit, opaque, a reference or a view; an owner global is §9.13's. It may be a channel or a pool: handles are generational, so a stale one traps at its next use and never reaches freed memory. Both backends emit it from the same IR (`gccjit` creates an internal, exported or imported global, with the TLS model for `thread_local`). An imported and an exported global of one name are one object.

Tasks cannot write ordinary globals through compiler-visible addresses. The rule follows aliases, aggregate-held pointers, parameters, returns, known function pointers and blocking bodies. Direct reads and calls proved to read only are permitted. Actual atomic operations, thread-local storage and `global(T, { shared = true })` are exceptions. Declaring an Atomic global does not permit non-atomic writes through a cast.

`shared = true` is an unchecked assertion that the program supplies the required synchronization; it changes neither representation nor scheduling. Declarations of the same imported/exported object must agree on `shared` and `thread_local`. The address analysis conservatively merges aggregate fields and array elements. If a possible writable origin is an ordinary global, the compiler rejects the task. Opaque code receiving such an address is considered able to write it, including through reachable pointer fields or callbacks. Raw pointer fabrication and foreign code's hidden state remain unchecked boundaries: this rule is not a whole-program proof of race freedom.

### 21.2 Function values

`Fn(params): ret` is a C function pointer; `Fn({ U32 }, U32)` takes and returns a `U32`. `fnptr(word)` materializes a native word as a residual function with its declared parameter types and is that function's address. Compile-time parameters are supplied first, by partial application. Calling an `Fn` value calls through it; when the value is a known function the call is direct. `null(Fn(...))` is the null pointer, and `==` and `~=` compare addresses. An `Fn` can be a parameter, result, field, local, global or extern argument (`pthread_create` takes one):

```lua
local Op = Fn({ U32 }, U32)
local double = do(x: U32): U32 = x * 2
local square = do(x: U32): U32 = x * x

local pick = do(which: U32): Op
    if which == 0 then return fnptr double end
    if which == 1 then return fnptr square end
    return null Op
end
```

```c
uint32_t (*pick(uint32_t which))(uint32_t) {
    if (which == 0u) {
        return double_;
    }
    if (which == 1u) {
        return square;
    }
    return NULL;
}
```

A function whose address is taken starts its data stacks at index 0, as an export does, so it takes no hidden base parameter.

## 22. What the language does not have

The core language does not provide:

- Arbitrary Lua-to-C compilation.
- A second complete typed C virtual machine.
- Implicit runtime closure allocation.
- General-purpose heap ownership, reference counting or tracing garbage collection.
- Automatic heap promotion.
- References that outlive their owners: a stored borrow is checked by the lifetime rule (§9.5).
- Arbitrary independently owned objects, or automatic collection of unreachable graph nodes.
- Unrestricted speculation of compile-time side effects.
- A runtime object model for generic types, or dynamic method dispatch by default.
- Shared mutable memory between tasks, and the lock and ownership type disciplines that would police it (tasks communicate over channels and move pool slots, §20).

Not implemented: a sum holding owners as a global (§9.13). Pointer arithmetic beyond
`p[i]` is excluded by design (§12).

## 23. The defining contracts

1. **Ordinary Lua is the compile-time host language.**
2. **A lambda that declares a result type is a native word.**
3. **Saturated application evaluates the word in place, with every argument.**
4. **Partial application binds only static values.**
5. **A C function boundary exists only for an export or a specialization key re-entered in non-tail position.**
6. **Eligible known native computation executes during compilation; a tail re-entry runs at compile time while its rounds stay known, and becomes a jump otherwise.**
7. **Loops are tail recursion; a re-entry under dynamic control generalizes the known arguments that changed.**
8. **Unknown or observable native computation becomes residual commands, in source order.**
9. **Typed bodies are parsed; comparisons, conditions, `and`/`or`, assignment and `return` are staged.**
10. **Unknown branches use isolated states; rebinding host bindings across them is rejected.**
11. **Typed places store lazily; storage is written only when something needs it.**
12. **The C backend receives a specialized residual program, not a translation of the source.**
13. **Goose memory analysis operates on the surviving native operations.**
14. **Scopes own ordinary values; stores own recyclable objects; resizable values are created in place and moved only by reference.**
15. **References borrow, IDs identify, and neither owns storage.**
16. **Data-stack allocation is bounded through lexical scopes and call-graph restrictions.**
17. **No runtime GC, reference counting or implicit heap ownership exists.**
18. **Activities are compile-time: a callback never becomes a closure; opening introduces live field places with lexical shadowing.**
19. **Tasks share no memory: what reaches a task or crosses a channel is a copy or a move, every wait is an operation in the task's own body, and a scope joins every task it started.**
20. **The resulting executable is independent of LuaJIT.**
52