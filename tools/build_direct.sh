#!/usr/bin/env bash
# Explicit offline build. Run from the repository root; outputs stay under build/.
set -euo pipefail
clang=${CLANG:-clang}
out=${1:-build/direct}
mkdir -p "$out"
common=(-std=c11 -O2 -g -Wall -Wextra -Werror -fcf-protection=none -fstack-clash-protection)
"$clang" "${common[@]}" -Inua/direct nua/direct/offsets.c -o "$out/offsets"
"$out/offsets" > "$out/offsets.inc"
"$clang" "${common[@]}" -fPIC -shared -Inua/direct -I"$out" \
    nua/direct/abi.c nua/direct/gates.S -pthread -o "$out/libnua_direct.so"
${LUA:-luajit} tools/direct_stencils.lua "$out/generated.c"
for part in fixtures generated; do
    source=nua/direct/stencils.c
    if [[ $part == generated ]]; then source="$out/generated.c"; fi
    "$clang" "${common[@]}" -fno-pic -fno-pie -fno-stack-protector \
        -fno-asynchronous-unwind-tables -ffunction-sections -Inua/direct \
        -c "$source" -o "$out/$part.o"
done
ld -r "$out/fixtures.o" "$out/generated.o" -o "$out/stencils.o"
python3 nua/direct/pack.py "$out/stencils.o" "$out/stencils.lua"
"$clang" "${common[@]}" -Inua/direct -I"$out" tests/direct_abi.c tests/direct_abi.S \
    -L"$out" -lnua_direct '-Wl,-rpath,$ORIGIN' -pthread -o "$out/test-abi"
"$clang" "${common[@]}" -shared -fPIC -Inua/direct -I"$out" tests/direct_abi.c tests/direct_abi.S \
    -L"$out" -lnua_direct '-Wl,-rpath,$ORIGIN' -pthread -o "$out/libdirect_fixture.so"
objdump -dr "$out/stencils.o" > "$out/stencils.dis"
"$clang" --version > "$out/compiler.txt"
${LUA:-luajit} tools/direct_runtime.lua "$out/runtime-layout.c" "$out/runtime-access.c"
"${CC:-cc}" -std=c11 -O2 -Wall -Wextra -Werror -Iruntime "$out/runtime-layout.c" -o "$out/runtime-layout"
"$out/runtime-layout" > "$out/runtime-meta.lua"
"${CC:-cc}" -std=c11 -O2 -fPIC -shared -Iruntime "$out/runtime-access.c" -o "$out/libnua_direct_rt.so"
# Shared runtime algorithms remain ordinary Nua, compiled only in this explicit
# offline build. The direct loader never calls runtime_build on a cache miss.
backend=${NUA_IO:-poll}
if [[ $backend == kqueue ]]; then
    printf '%s\n' 'direct: kqueue is not supported by this Linux build' >&2
    exit 1
fi
policy=$(${LUA:-luajit} -e 'print(require("nua.runtime_build").source())')
runtime_sources=(runtime/nua_rt.c "$policy")
if [[ $backend == uring ]]; then runtime_sources+=(runtime/nua_io_uring.c); fi
"${CC:-cc}" -std=c99 -O2 -fPIC -shared -pthread -Iruntime \
    "${runtime_sources[@]}" -o "$out/libnua_rt-$backend.so"
