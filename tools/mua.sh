#!/usr/bin/env bash
# Mua, pinned by tools/mua.lock: fetch the pinned commit, install its Lua modules, check them.
# No system installation. MUA_URL in the environment overrides the lock's URL (a local clone
# while Mua is being developed); the commit must still match the pin.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
cd "$root"
source tools/mua.lock
url=${MUA_URL_OVERRIDE:-$MUA_URL}
mode=${1:-}
case "$mode" in fetch|install|check|all) ;; *) echo 'usage: bash tools/mua.sh fetch|install|check|all' >&2; exit 2 ;; esac
src=$root/build/deps/src/mua
dest=$root/.local/share/lua/5.1/mua
mark=$dest/.mua-commit
if [[ $mode == check ]]; then
    [[ -f $mark && $(<"$mark") == "$MUA_COMMIT" && -f $dest/init.lua ]] || {
        echo "Mua $MUA_COMMIT is not installed; run make mua." >&2; exit 2;
    }
    exit 0
fi
if [[ $mode == fetch || $mode == all ]]; then
    mkdir -p "$src"
    [[ -d $src/.git ]] || git init -q "$src"
    if [[ $(git -C "$src" rev-parse -q --verify HEAD 2>/dev/null || true) != "$MUA_COMMIT" ]]; then
        git -C "$src" fetch -q "$url" "$MUA_COMMIT"
        git -C "$src" checkout -q --detach "$MUA_COMMIT"
    fi
    [[ $(git -C "$src" rev-parse HEAD) == "$MUA_COMMIT" ]] || { echo 'Mua checkout does not match tools/mua.lock.' >&2; exit 1; }
    git -C "$src" diff --quiet HEAD -- || { echo 'Mua checkout is modified; move it aside and fetch again.' >&2; exit 1; }
fi
if [[ $mode == install || $mode == all ]]; then
    [[ -d $src/mua ]] || { echo 'Mua is not fetched; run bash tools/mua.sh fetch.' >&2; exit 1; }
    rm -rf "$dest"; mkdir -p "$dest"
    install -m 644 "$src"/mua/*.lua "$dest"/
    printf '%s\n' "$MUA_COMMIT" > "$mark"
    echo "Mua $MUA_COMMIT installed in .local/share/lua/5.1/mua."
fi
