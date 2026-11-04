#!/usr/bin/env bash
# Offline build-environment regressions. Never downloads or compiles dependencies.
set -euo pipefail
# Test toolchain selection independently of the parent make's exported settings.
unset MAKEFLAGS MAKEOVERRIDES MFLAGS MAKELEVEL LOCAL_DEPS CC LUA NUA_GCCJIT LUA_CPATH LUA_PATH LD_LIBRARY_PATH
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
bash -n tools/deps.sh
mkdir -p build/tmp
fixture=$(mktemp -d "$root/build/tmp/build-check.XXXXXX")
# Retain the small fixture on failure for diagnosis, like other build evidence.
cp Makefile "$fixture/Makefile"
mkdir -p "$fixture/tools"
cp tools/deps.sh tools/deps.lock tools/mua.sh tools/mua.lock "$fixture/tools/"
# Mua is installed beside the toolchain (tools/mua.sh check wants its pinned commit)
mkdir -p "$fixture/.local/share/lua/5.1/mua"
touch "$fixture/.local/share/lua/5.1/mua/init.lua"
(source tools/mua.lock; printf '%s\n' "$MUA_COMMIT" > "$fixture/.local/share/lua/5.1/mua/.mua-commit")
bash -n tools/mua.sh
mkdir -p "$fixture/.local/bin" "$fixture/.local/lib/lua/5.1"
printf '#!/usr/bin/env bash\nprintf "LUA_CPATH=%%s\\nCC=%%s\\nNUA_GCCJIT=%%s\\nLUA_BIN=%%s\\n" "$LUA_CPATH" "${CC:-}" "${NUA_GCCJIT:-}" "$(command -v luajit)"\n' > "$fixture/.local/bin/luajit"
printf '#!/usr/bin/env bash\necho fixture-cc\n' > "$fixture/.local/bin/gcc"
chmod +x "$fixture/.local/bin/luajit" "$fixture/.local/bin/gcc"
if make --no-print-directory -s -C "$fixture" LOCAL_DEPS=1 doctor > "$fixture/incomplete.log" 2>&1; then
    echo 'incomplete local toolchain unexpectedly accepted' >&2; exit 1
fi
[[ $(<"$fixture/incomplete.log") == *'Local dependencies are incomplete'* ]]
inputs=$(cd "$fixture" && sha256sum tools/deps.lock tools/deps.sh | sha256sum)
printf '%s\n' "${inputs%% *}" > "$fixture/.local/nua-deps.ready"
touch "$fixture/.local/lib/libgccjit.so.0"
make --no-print-directory -s -C "$fixture" doctor > "$fixture/local.log"
local_output=$(<"$fixture/local.log")
[[ $local_output == *"LUA_CPATH=$fixture/.local/lib/lua/5.1/?.so;;"* ]]
[[ $local_output == *"CC=$fixture/.local/bin/gcc"* ]]
[[ $local_output == *"LUA_BIN=$fixture/.local/bin/luajit"* ]]
[[ $local_output == *"NUA_GCCJIT=$fixture/.local/lib/libgccjit.so.0"* ]]
LUA_CPATH=host-marker make --no-print-directory -s -C "$fixture" LOCAL_DEPS=0 \
    LUA="$fixture/.local/bin/luajit" CC="$fixture/.local/bin/gcc" doctor > "$fixture/host.log"
[[ $(<"$fixture/host.log") == *'LUA_CPATH=host-marker'* ]]
make --no-print-directory -n -C "$fixture" dist LDFLAGS=-Wl,--as-needed > "$fixture/dist.log"
dist_output=$(<"$fixture/dist.log")
[[ $dist_output == *'-o build/dist/nua_rt.o'* ]]
[[ $dist_output == *'-o build/dist/policy.o'* ]]
[[ $dist_output == *"-L$fixture/.local/lib -Wl,-rpath,$fixture/.local/lib -Wl,--as-needed"* ]]
[[ $dist_output != *'ar rcs build/dist/libnua_rt.a nua_rt.o'* ]]
printf '\n# changed pin file\n' >> "$fixture/tools/deps.lock"
if make --no-print-directory -s -C "$fixture" doctor > "$fixture/stale.log" 2>&1; then
    echo 'stale local toolchain unexpectedly accepted' >&2; exit 1
fi
[[ $(<"$fixture/stale.log") == *'incomplete or stale'* ]]
if DEPS_JOBS=0 bash tools/deps.sh build > "$fixture/jobs.log" 2>&1; then
    echo 'invalid dependency job count unexpectedly accepted' >&2; exit 1
fi
[[ $(<"$fixture/jobs.log") == *'DEPS_JOBS must be a positive integer'* ]]
mkdir -p "$fixture/build/deps/lock"
if bash "$fixture/tools/deps.sh" fetch > "$fixture/lock.log" 2>&1; then
    echo 'concurrent dependency operation unexpectedly accepted' >&2; exit 1
fi
[[ $(<"$fixture/lock.log") == *'Dependency operation already active'* ]]
# This lock belongs to this fixture; it contains no files or running builder.
rmdir "$fixture/build/deps/lock"
if bash "$fixture/tools/deps.sh" build > "$fixture/offline.log" 2>&1; then
    echo 'offline build unexpectedly accepted missing archives' >&2; exit 1
fi
[[ $(<"$fixture/offline.log") == *'run make deps-fetch first'* ]]
printf 'corrupt archive\n' > "$fixture/build/deps/downloads/gcc-15.2.0.tar.xz"
if bash "$fixture/tools/deps.sh" build > "$fixture/corrupt.log" 2>&1; then
    echo 'corrupt source archive unexpectedly accepted' >&2; exit 1
fi
[[ $(<"$fixture/corrupt.log") == *'FAILED'* ]]
echo 'build setup checks passed (tool selection, stale/incomplete installs, dist flags/paths, jobs, locking, offline and checksum failures)'
