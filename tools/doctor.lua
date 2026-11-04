-- Dependency checks only: no downloads or system package changes.
print(jit and jit.version or _VERSION)
assert(jit, 'Nua requires LuaJIT')
local ok, mua = pcall(require, 'mua.init')
assert(ok, 'Mua is not installed; run make mua (tools/mua.lock pins it)')
print('Mua: version ' .. tostring(mua.version))
local c = require 'nua.cjit'
local available, lib = pcall(c.lib)
if available then
    print(('libgccjit: %d.%d.%d'):format(lib.gcc_jit_version_major(), lib.gcc_jit_version_minor(), lib.gcc_jit_version_patchlevel()))
else
    print('libgccjit: unavailable (optional for C output; required for JIT)')
    print('Set NUA_GCCJIT to its shared library path, or install libgccjit 13+.')
end
print('Test workers: ' .. (os.getenv('NUA_WORKERS') or 'runtime default'))
print('Generated files: ' .. (os.getenv('TMPDIR') or '/tmp'))
