# LuaMacro is Nua source

The full LuaMacro runtime source tree is integrated directly:

- `macro.lua`: the macro engine.
- `macro/{Getter,TokenList,lexer,clexer,builtin,...}.lua`: the upstream modules.
- `macro/lib/`: the upstream class/test helpers.
- `luam`: the standalone, locally repaired CLI.
- `macro/let.lua`, `macro/nua.lua`: Nua's current extensions, preserved from its package.

The 18 upstream modules were byte-identical to those embedded in Nua prototype
package (9). They were brought over as source, not regenerated or reimplemented.
Nua's driver now uses ordinary `require` calls relative to its own module location.
The runtime bundle bootstrap and generated `luam.lua` are retired. Neither Nua nor
its macro CLI needs a neighboring checkout or a bundle-generation step.

`make test-macros` checks source loading, CLI errors/tracebacks, expression lambdas,
currying, optional vocabulary loading, and embedding with unrelated host arguments.
The complete Nua tests additionally cover the typed parser, application forms,
source diagnostics, C listings and JIT execution. Macro fixtures came from the
original experiment; bundle-only distribution tests are not an active contract.

`readme.md` is upstream LuaMacro's manual. `NOTICE.md` and `PATCHES.md` are the
original import/patch records; their old layout and license-context references
are historical. `THIRD_PARTY.md` at the project root is the current attribution.
The only additional CLI change is to prefer its own source tree over other modules
on the caller's search path.
