# Third-party source

## LuaMacro 2.5.0

Nua includes LuaMacro as ordinary project source: `macro.lua`, the upstream modules
under `macro/` (including `macro/lib/`), and the `luam` CLI. These are not loaded from
a generated bundle. Nua's `macro/let.lua` and `macro/nua.lua` are separate language
extensions; they are not upstream LuaMacro modules.

Upstream: <https://github.com/stevedonovan/LuaMacro>.
The imported source was identified by archive SHA-256
`8c9ca9eba01364a26032f9ec34e86b489a52fe1f475bf463c43e181cfb3e4b14`.
The engine/modules match the 18 modules embedded in prototype package (9).
The CLI includes the previously documented traceback/exit-status fixes and now gives
this project's source modules precedence on its search path.

LuaMacro is MIT/X11 licensed:

> Copyright (c) 2011 Steve Donovan
>
> Permission is hereby granted, free of charge, to any person obtaining a copy
> of this software and associated documentation files (the "Software"), to deal
> in the Software without restriction, including without limitation the rights
> to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
> copies of the Software, and to permit persons to whom the Software is
> furnished to do so, subject to the following conditions:
>
> The above copyright notice and this permission notice shall be included in
> all copies or substantial portions of the Software.
>
> THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
> IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
> FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
> AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
> LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
> OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
> THE SOFTWARE.

The lexer by Peter Odding retains its copyright disclaimer/blessing in
`macro/lexer.lua`.

The original provenance and CLI patch record are retained under `docs/luamacro/`;
references there to the earlier repository/layout are historical, not dependencies
of Nua. See `docs/luamacro/INTEGRATION.md` for the active layout.

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
- **LPeg 1.1.0**: <https://www.inf.puc-rio.br/~roberto/lpeg/>, MIT;
  the source archive retains the licence in `lpeg.html`.

No changes are made to the existing LuaMacro attribution above or to Nua's runtime
exception below.

## Project licensing

The incoming prototype declares Nua GPL version 3 or later (`COPYING`). Its runtime
and generated runtime/header helpers additionally carry GCC Runtime Library
Exception 3.1 (`COPYING.RUNTIME`), reflected in the runtime's SPDX notices and the
alpha design. This does not relicense the LuaMacro/lexer sources above: their
original notices and permissions remain in force. Historical statements about the
previous importing repository's license are not Nua's licensing authority.
