#!/usr/bin/env bash
# Explicit fetch/build only. No system installation or repository history changes.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source tools/deps.lock
mode=${1:-}
case "$mode" in fetch|build|check) ;; *) echo 'usage: bash tools/deps.sh fetch|build|check' >&2; exit 2 ;; esac
inputs=$(sha256sum tools/deps.lock tools/deps.sh | sha256sum)
inputs=${inputs%% *}
if [[ $mode == check ]]; then
    [[ -f .local/nua-deps.ready && $(<.local/nua-deps.ready) == "$inputs" &&
       -x .local/bin/gcc && -x .local/bin/luajit &&
       -f .local/lib/libgccjit.so.0 ]] || {
        echo 'Local dependencies are incomplete or stale; run make deps-fetch && make deps, or select LOCAL_DEPS=0.' >&2; exit 2;
    }
    exit 0
fi
[[ $(uname -s) == Linux && $(getconf LONG_BIT) == 64 ]] || {
    echo 'Local dependency bootstrap currently supports 64-bit Linux only.' >&2; exit 2;
}
base=$root/build/deps
prefix=$root/.local
jobs=${DEPS_JOBS:-4}
[[ $jobs =~ ^[1-9][0-9]*$ ]] || { echo 'DEPS_JOBS must be a positive integer' >&2; exit 2; }
host_cc=${HOST_CC:-gcc}
host_cxx=${HOST_CXX:-g++}
mkdir -p "$base/downloads" "$base/src" "$prefix"
# Concurrent fetch/build invocations must not modify the same source/install tree.
mkdir "$base/lock" 2>/dev/null || { echo 'Dependency operation already active (build/deps/lock).' >&2; exit 2; }
trap 'rmdir "$base/lock"' EXIT

archive() {
    local url=$1 name=$2 hash=$3 algorithm=$4
    local path=$base/downloads/$name
    if [[ ! -f $path ]]; then
        [[ $mode == fetch ]] || { echo "Missing $name; run make deps-fetch first." >&2; exit 1; }
        curl --fail --location --retry 3 --output "$path.part" "$url"
        printf '%s  %s\n' "$hash" "$path.part" | "sha${algorithm}sum" --check -
        mv "$path.part" "$path"
    fi
    printf '%s  %s\n' "$hash" "$path" | "sha${algorithm}sum" --check -
}
archive "$GCC_URL" "gcc-$GCC_VERSION.tar.xz" "$GCC_SHA512" 512
for dep in GMP MPFR MPC; do
    version_var=${dep}_VERSION
    hash_var=${dep}_SHA512
    name=${dep,,}-${!version_var}
    extension=tar.bz2
    [[ $dep != MPC ]] || extension=tar.gz
    archive "https://gcc.gnu.org/pub/gcc/infrastructure/$name.$extension" "$name.$extension" "${!hash_var}" 512
done

luajit_src=$base/src/luajit
if [[ ! -d $luajit_src/.git ]]; then
    [[ $mode == fetch ]] || { echo 'Missing LuaJIT source; run make deps-fetch first.' >&2; exit 1; }
    git init "$luajit_src"
    git -C "$luajit_src" fetch --depth 1 "$LUAJIT_URL" "$LUAJIT_REF"
    git -C "$luajit_src" checkout --detach FETCH_HEAD
fi
[[ $(git -C "$luajit_src" rev-parse HEAD) == "$LUAJIT_COMMIT" ]] || {
    echo 'LuaJIT checkout does not match tools/deps.lock; move it aside and fetch again.' >&2; exit 1;
}
git -C "$luajit_src" diff --exit-code HEAD --
[[ $mode != fetch ]] || { echo 'Pinned dependency sources fetched and verified.'; exit 0; }

# Build never accesses the network. Extract only verified archives, and never
# delete existing sources or builds on a pin change: keep them as evidence.
for name in "gcc-$GCC_VERSION.tar.xz" "gmp-$GMP_VERSION.tar.bz2" "mpfr-$MPFR_VERSION.tar.bz2" "mpc-$MPC_VERSION.tar.gz"; do
    directory=${name%.tar.*}
    if [[ ! -f $base/src/$directory/.nua-extracted ]]; then
        tar -xf "$base/downloads/$name" -C "$base/src"
        touch "$base/src/$directory/.nua-extracted"
    fi
done
gcc_src=$base/src/gcc-$GCC_VERSION
for dep in gmp mpfr mpc; do
    version_var=${dep^^}_VERSION
    ln -sfn "$base/src/$dep-${!version_var}" "$gcc_src/$dep"
done

# Fingerprint inputs and bootstrap compiler, so stale installs are not silently
# reused. New configurations use separate build trees; install prefix is fixed.
fingerprint=$({ sha256sum tools/deps.lock tools/deps.sh; printf '%s\n' "$prefix" "$host_cc" "$host_cxx"; "$host_cc" --version; "$host_cxx" --version; } | sha256sum)
fingerprint=${fingerprint%% *}
work=$base/work/$fingerprint
mkdir -p "$work"
# An interrupted install must not be mistaken for a usable previous toolchain.
printf 'incomplete\n' > "$prefix/nua-deps.ready"
if [[ ! -f $prefix/gcc.build-id || $(<"$prefix/gcc.build-id") != "$fingerprint" || ! -x $prefix/bin/gcc || ! -f $prefix/lib/libgccjit.so.0 ]]; then
    mkdir -p "$work/gcc"
    (
        cd "$work/gcc"
        if [[ ! -f Makefile ]]; then
            # GCC 16 defaults to C++20; GCC 15 needs an older dialect.
            # Keep it on CXX so subprojects can append their own -std flag.
            CC="$host_cc" CXX="$host_cxx -std=gnu++17" CFLAGS='-O2' CXXFLAGS='-O2' "$gcc_src/configure" \
                --prefix="$prefix" --libdir="$prefix/lib" \
                --enable-languages=c,jit --enable-host-shared \
                --disable-bootstrap --disable-multilib --disable-nls \
                --disable-werror --disable-libsanitizer --disable-libquadmath \
                --disable-libgomp --without-isl
        fi
        # Build code, not manuals; release tarballs supply generated sources.
        make -j"$jobs" MAKEINFO=true
        make install MAKEINFO=true
    )
    printf '%s\n' "$fingerprint" > "$prefix/gcc.build-id"
fi
if [[ ! -f $prefix/luajit.build-id || $(<"$prefix/luajit.build-id") != "$fingerprint" || ! -x $prefix/bin/luajit || ! -f $prefix/lib/libluajit-5.1.so ]]; then
    if [[ ! -d $work/luajit ]]; then cp -a "$luajit_src" "$work/luajit"; fi
    make -C "$work/luajit" -j"$jobs" PREFIX="$prefix" CC="$host_cc" LDFLAGS="-Wl,-rpath,$prefix/lib"
    make -C "$work/luajit" install PREFIX="$prefix" LDCONFIG=true
    printf '%s\n' "$fingerprint" > "$prefix/luajit.build-id"
fi
# Publish readiness only after loading the actual installed libraries succeeds.
LD_LIBRARY_PATH="$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" \
    NUA_GCCJIT="$prefix/lib/libgccjit.so.0" "$prefix/bin/luajit" -e \
    'local j = require("nua.cjit").lib(); assert(j.gcc_jit_version_major() >= 13)'
printf '%s\n' "$inputs" > "$prefix/nua-deps.ready"
echo 'Local dependencies ready. Use make LOCAL_DEPS=1 doctor, dist, or test.'
