# Building Nua

## Pinned local toolchain

The local bootstrap currently targets 64-bit Linux. It builds GCC 15.2.0 with
its C and JIT frontends, libgccjit, and LuaJIT 2.1 for Lua 5.1's ABI.
Mua, the pinned Lua language Nua is a host of, is fetched and installed separately
(`make mua`, `tools/mua.lock`). GCC's GMP 6.2.1, MPFR 4.1.0 and MPC 1.2.1 are also pinned and built
from source, not taken from system development packages.

Required host tools:

- A working GCC/G++ bootstrap toolchain (C++17 support) and libc development files.
- GNU make, binutils (`as`, `ld`, `ar`), Bash, Git, curl and coreutils (including
  `sha256sum`, `sha512sum`, `getconf`, and `install`).
- Tar with gzip, bzip2 and xz support; standard Unix shell utilities.
- POSIX threads and libdl. Optional system compression libraries can affect which
  features GCC detects; this is a pinned-source build, not a hermetic SDK.

GCC's release archive includes generated sources. Flex, Bison, Texinfo, LuaRocks,
a system LuaJIT, and system GMP/MPFR/MPC headers are not needed for this path.
The bootstrap does not build GCC manuals, sanitizer/OpenMP/quadmath runtime
libraries, use GCC's three-stage bootstrap, or provide a cross compiler. Clang's
available sanitizer paths remain usable by the test suite. Allow several GB of
disk space and a substantial first build. Four parallel dependency jobs are the default; reduce this on small hosts.

```sh
make bootstrap DEPS_JOBS=4
make doctor
make test-build
make test-mua
make test
make test-native
make test-dist
```

`bootstrap` performs these steps in order, even under parallel make:

```sh
make deps-fetch                   # the only network step
make deps                         # verify, build and install; no network
make LOCAL_DEPS=1 dist             # build build/dist/nua
```

The fetched archives are checked against hashes recorded in
[`tools/deps.lock`](../tools/deps.lock). LuaJIT is fetched at an exact Git commit;
the checkout's commit and tracked contents are checked before building. Downloads
use HTTPS. GCC hashes come from its release checksum manifest; prerequisite
hashes come from that GCC release's `contrib/prerequisites.sha512`. These checks
pin the reviewed inputs; fetching a checksum is not a substitute for reviewing
upstream provenance when changing a pin.

After fetching, `make deps` can run offline. No ordinary build, diagnostic, or
test target downloads dependencies. An already-built install is reused when its
pins, build script, prefix and bootstrap compiler identity match. A changed build
input creates a separate work tree; old experimental evidence is not removed.
Interrupted builds can be resumed with `make deps`. An interrupted install or
changed lock/script causes local checks to fail rather than silently use host tools.
Concurrent dependency operations are rejected with a lock-directory diagnostic.
After an uncatchable termination, confirm no dependency build is active before
removing the leftover `build/deps/lock` directory.

## Layout and tool selection

| Path | Purpose |
|---|---|
| `tools/deps.lock` | Tracked source URLs, revisions and checksums |
| `tools/deps.sh` | Explicit fetch/build/check entry point |
| `build/deps/downloads/` | Verified upstream archives |
| `build/deps/src/` | Dependency sources, including the pinned LuaJIT Git checkout |
| `build/deps/work/` | Fingerprinted builds and intermediate objects |
| `.local/` | Installed compiler, headers, libraries and readiness metadata |
| `build/dist/` | Nua executable, embedded sources and runtime archive/objects |

Dependency copies and generated files are ignored by both jj and Git. No source
checkout, binary, or machine-specific absolute path is committed. There are no
submodules: jj manages all project history and bookmarks, while Git is used only
to fetch/check the dependency checkout. This avoids jj's lack of submodule
management. The build does not depend on any neighboring repository.

Make automatically selects a local toolchain when `.local/nua-deps.ready` exists.
`LOCAL_DEPS=1` explicitly requires it; `LOCAL_DEPS=0` explicitly selects the original
host-dependency setup. Local mode selects the installed LuaJIT, the Lua 5.1 library path,
libgccjit and (unless `CC` was explicitly overridden) GCC. It exports those paths
to test harnesses and adds the local library directory and rpath to the dist link.
Nua build/test targets also prepend the local binary directory to their subprocess
PATH, so nested `luajit` calls do not need a system installation. Dependency builds
keep the original PATH to avoid accidentally using the newly installed GCC as
their own bootstrap compiler. Native harnesses and fuzzers honour `CC`; failed
fuzzer runtime-archive builds are errors, not ignored failures.
Make never modifies the caller's shell or the system loader configuration.

`HOST_CC` and `HOST_CXX` select bootstrap compiler executables for `make deps`.
`DEPS_JOBS` controls dependency parallelism independently of Nua's test workers.
Changing the prefix is intentionally unsupported; the local install is tied to
this checkout. Move the dependency/build directories aside and rebuild after
moving the checkout. For normal Nua builds, standard `CC`, `AR`, `CPPFLAGS`,
`CFLAGS`, `LDFLAGS` and `LDLIBS` overrides are available.

For direct development commands, use the same environment Make supplies:

```sh
export LUA_CPATH="$PWD/.local/lib/lua/5.1/?.so;;"
export LUA_PATH="$PWD/.local/share/lua/5.1/?.lua;;"
export LD_LIBRARY_PATH="$PWD/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NUA_GCCJIT="$PWD/.local/lib/libgccjit.so.0"
export CC="$PWD/.local/bin/gcc"
.local/bin/luajit nua.lua run examples/hello.nua
```

This produces a **local development toolchain**, not a relocatable or static
package. The dist executable still dynamically links LuaJIT and uses libgccjit,
the host's libc/headers, assembler and linker. Optional SDL, Clang/sanitizers,
Tree-sitter and Neovim are not bootstrapped. Missing optional facilities must be
reported as skips or environment limits, not successful checks.

## Updating dependencies with jj

1. Review the upstream release/commit, notices and source hashes.
2. Update `tools/deps.lock` with jj's normal working-copy workflow.
3. For a changed LuaJIT pin, move the previous ignored checkout aside before
   fetching; the script deliberately refuses to overwrite a mismatched checkout.
4. Run `make deps-fetch`, `make deps`, and the acceptance checks above.
5. Review `jj diff`; only the lock, build code, tests and documentation belong in
   project history. Do not add dependency sources or generated artifacts.

[`THIRD_PARTY.md`](../THIRD_PARTY.md) records upstream licensing/provenance. A local
bootstrap does not change Nua's licence or the runtime exception.
