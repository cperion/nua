# Third-party source

## Pinned build dependencies

The optional local bootstrap downloads source into ignored `build/deps/` and installs
under `.local/`. These are external build dependencies, not imported Nua source.
[`tools/deps.lock`](tools/deps.lock) records exact versions/revisions and archive
checksums; [the build guide](docs/building.md) describes verification and updates.
Keep the upstream copyright notices, licence files and corresponding source when
redistributing any resulting dependency binaries; this list is not a relicensing.

- **GCC 15.2.0 / libgccjit**: <https://gcc.gnu.org/>. GCC is GPL-3.0-or-later;
  individual components have their upstream terms. The GCC Runtime Library
  Exception applies to designated runtime components, **not** to libgccjit itself.
  GCC archive hashes are pinned from the upstream release checksum manifest.
- **GMP 6.2.1**: <https://gmplib.org/>, dual LGPL-3.0-or-later / GPL-2.0-or-later.
- **MPFR 4.1.0**: <https://www.mpfr.org/>, LGPL-3.0-or-later.
- **MPC 1.2.1**: <https://www.multiprecision.org/>, LGPL-3.0-or-later.
  The three prerequisite hashes match GCC 15.2.0's `contrib/prerequisites.sha512`.
- **LuaJIT 2.1**, exact commit in the lock: <https://github.com/LuaJIT/LuaJIT>,
  MIT; see its `COPYRIGHT` for attribution and included third-party notices.
- **Mua** (the Lua language Nua is a host of): <https://github.com/cperion/mua>, the commit in
  `tools/mua.lock`; the same project terms, GPL-3.0-or-later (its `COPYING`). Not part of this
  repository: `make mua` fetches and installs it under `.local/`.

LuaMacro (MIT, Steve Donovan) and LPeg (MIT, Roberto Ierusalimschy) were used by earlier
versions and are no longer part of this project: Mua's lexer, parser and emitter are
written fresh and do not derive from them (design: `docs/design/macro-layer.md`, M3).

No changes are made to Nua's runtime exception below.

## Project licensing

The incoming prototype declares Nua GPL version 3 or later (`COPYING`). Its runtime
and generated runtime/header helpers additionally carry GCC Runtime Library
Exception 3.1 (`COPYING.RUNTIME`), reflected in the runtime's SPDX notices and the
alpha design. The third-party components above keep their own notices and permissions. Historical statements about the
previous importing repository's license are not Nua's licensing authority.
