.DEFAULT_GOAL := help

# Opt in explicitly, or select the complete toolchain published by make deps.
# LOCAL_DEPS=0 retains the host-toolchain path. Neither mode downloads anything.
LOCAL_DEPS ?= $(if $(wildcard .local/nua-deps.ready),1,0)
ifeq ($(LOCAL_DEPS),1)
DEPS_PREFIX := $(CURDIR)/.local
# Subprocesses in the existing harnesses also invoke luajit by name. Keep
# this PATH target-specific so make deps still finds the host bootstrap GCC.
NUA_TARGETS := doctor runtime test test-macros test-format test-modules test-native test-scheduler direct test-direct run tree-sitter test-tree-sitter dist test-dist test-dist-suite test-canvas test-ui
$(NUA_TARGETS): export PATH := $(DEPS_PREFIX)/bin:$(PATH)
LUA ?= $(DEPS_PREFIX)/bin/luajit
ifeq ($(origin CC),default)
CC := $(DEPS_PREFIX)/bin/gcc
endif
export CC
export LUA_CPATH := $(DEPS_PREFIX)/lib/lua/5.1/?.so;;
export LUA_PATH := $(DEPS_PREFIX)/share/lua/5.1/?.lua;;
export LD_LIBRARY_PATH := $(DEPS_PREFIX)/lib$(if $(LD_LIBRARY_PATH),:$(LD_LIBRARY_PATH))
export NUA_GCCJIT := $(DEPS_PREFIX)/lib/libgccjit.so.0
LUAJIT_INCLUDE ?= $(DEPS_PREFIX)/include/luajit-2.1
DEPS_LDFLAGS := -L$(DEPS_PREFIX)/lib -Wl,-rpath,$(DEPS_PREFIX)/lib
else
LUA ?= luajit
# LuaJIT needs LPeg's Lua 5.1 ABI, not the system Lua's newer ABI.
ROCKS_CPATH := $(shell command -v luarocks >/dev/null 2>&1 && luarocks --lua-version=5.1 path --lr-cpath 2>/dev/null)
ifeq ($(origin LUA_CPATH),undefined)
export LUA_CPATH := $(ROCKS_CPATH);;
endif
endif
export NUA_CACHE ?= $(CURDIR)/build/cache
export TMPDIR ?= $(CURDIR)/build/tmp
export NUA_WORKERS ?= 2
export NUA_TEST_JOBS ?= $(shell nproc 2>/dev/null || echo 16)
ifeq ($(origin NUA_GCCJIT),undefined)
ifneq ($(wildcard $(CURDIR)/.local/lib/libgccjit.so.0),)
export NUA_GCCJIT := $(CURDIR)/.local/lib/libgccjit.so.0
endif
endif

.PHONY: help doctor dirs runtime test test-macros test-format test-modules test-native test-scheduler direct test-direct run tree-sitter test-tree-sitter dist test-dist test-dist-suite deps-fetch deps bootstrap test-build

# Fetching is explicit; deps itself can run with the network disconnected.
deps-fetch:
	bash tools/deps.sh fetch

deps:
	+bash tools/deps.sh build

bootstrap:
	$(MAKE) deps-fetch
	$(MAKE) deps
	$(MAKE) LOCAL_DEPS=1 dist

test-build:
	bash tests/build.sh

TREE_SITTER ?= tree-sitter
NVIM ?= nvim
TS_SOURCE := tools/tree-sitter-nua
TS_BUILD := build/tree-sitter-nua

# Keep generated parser sources and binaries out of the source tree.
tree-sitter: dirs
	mkdir -p $(TS_BUILD)/src
	cp $(TS_SOURCE)/grammar.js $(TS_BUILD)/grammar.js
	cp $(TS_SOURCE)/src/scanner.c $(TS_BUILD)/src/scanner.c
	$(TREE_SITTER) generate --abi 14 $(TS_BUILD)/grammar.js -o $(TS_BUILD)/src
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -Wall -Wextra -Werror -fPIC -shared -I$(TS_BUILD)/src $(TS_BUILD)/src/parser.c $(TS_BUILD)/src/scanner.c $(LDFLAGS) -o $(TS_BUILD)/nua.so

test-tree-sitter: tree-sitter
	$(NVIM) --headless -u NONE -l $(TS_SOURCE)/tests/check.lua
help:
	@printf '%s\n' 'make bootstrap    Fetch pinned sources, build local dependencies and Nua (64-bit Linux)' 'make deps-fetch   Fetch and verify pinned sources only' 'make deps         Build/install fetched dependencies offline under .local/' 'make test-build   Check build setup without downloading or compiling GCC' 'LOCAL_DEPS=0      Use host dependencies instead of a completed local toolchain'
	@printf '%s\n' 'make doctor       Check LuaJIT, LPeg, C compiler and optional libgccjit' 'make test         Macro checks and complete packaged C/JIT test suite' 'make test-macros  Source-module and macro CLI regressions' 'make test-format  Formatter semantics, style and CLI regressions' 'make test-modules Lua require and compilation cache regressions' 'make test-native  Require libgccjit and run in-process checks' 'make run PROGRAM=examples/csv.nua ARGS="examples/data/sales.csv price"' 'make tree-sitter  Build the local Nua parser for Neovim' 'make test-tree-sitter  Check parsing and Neovim highlighting'

dirs:
ifeq ($(LOCAL_DEPS),1)
	@bash tools/deps.sh check
endif
	@mkdir -p "$(TMPDIR)" "$(NUA_CACHE)" build/logs

doctor: dirs
	@$(LUA) tools/doctor.lua
	@$(CC) --version

test-macros: dirs
	$(LUA) tests/macros.lua

test-format: dirs
	$(LUA) tests/formatter_do.lua
	$(LUA) tests/formatter_application.lua
	$(LUA) tests/formatter.lua

test-modules: dirs
	$(LUA) tests/modules.lua

.PHONY: test-canvas test-ui
test-canvas: dirs
	$(LUA) tests/canvas.lua

test-ui: dirs
	$(LUA) tests/ui.lua
	$(LUA) tests/ui_sdl.lua

test: test-build test-macros test-format test-modules
	$(LUA) tests/run.lua

runtime: dirs
	@$(LUA) -e 'print(require("nua.runtime_build").source())'

test-scheduler: dirs
	$(LUA) tests/scheduler.lua

test-native: dirs
	$(LUA) -e 'require("nua.cjit").lib()'
	$(LUA) tests/native.lua

# Explicit build of the register-bank stencil pack and platform gates.
direct: dirs
	bash tools/build_direct.sh

test-direct: direct
	build/direct/test-abi
	CC=/bin/false CLANG=/bin/false $(LUA) tests/direct.lua
	CC=/bin/false CLANG=/bin/false $(LUA) -joff tests/direct.lua
	$(LUA) tests/direct_ir.lua
	$(LUA) -joff tests/direct_ir.lua
	$(LUA) tests/direct_storage.lua
	$(LUA) tests/direct_tasks.lua
	CC=/bin/false CLANG=/bin/false NUA_GCCJIT=/direct/no-gccjit.so $(LUA) tests/direct_standalone.lua
	CC=/bin/false CLANG=/bin/false NUA_GCCJIT=/direct/no-gccjit.so $(LUA) -joff tests/direct_standalone.lua

# The single binary embeds Nua, dynamically links the selected LuaJIT,
# and links the C runtime in (the process exports it for gccjit'd code).
LUAJIT_INCLUDE ?= $(shell ls -d /usr/include/luajit-* 2>/dev/null | head -1)
DIST_RT := build/dist/libnua_rt.a
DIST_POLICY := build/dist/policy.c
dist: dirs
	@test -n '$(LUAJIT_INCLUDE)' || { printf '%s\n' 'Set LUAJIT_INCLUDE to the directory with lua.h'; exit 2; }
	@mkdir -p build/dist
	$(LUA) -e 'package.path = "./?.lua;" .. package.path; local f = assert(io.open(require("nua.runtime_build").source("poll"))); io.write(f:read("*a"))' > $(DIST_POLICY)
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -O2 -Wall -Wextra -Werror -pedantic -pthread -I'./runtime' -c runtime/nua_rt.c -o build/dist/nua_rt.o
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -O2 -Wall -Wextra -Werror -pedantic -pthread -I'./runtime' -c $(DIST_POLICY) -o build/dist/policy.o
	rm -f $(DIST_RT)
	$(AR) rcs $(DIST_RT) build/dist/nua_rt.o build/dist/policy.o
	rm -f build/dist/probe-record.txt
	@for f in examples/*.nua; do \
		NUA_PROBE_RECORD=$(CURDIR)/build/dist/probe-record.txt $(LUA) nua.lua --gccjit -o build/dist/probe.o "$$f" >/dev/null 2>&1 || true; \
	done
	$(LUA) tools/tables.lua $(CURDIR)/build/dist/probe-record.txt
	$(LUA) tools/embed.lua
	$(CC) $(CPPFLAGS) $(CFLAGS) -std=c99 -O2 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L -I'$(LUAJIT_INCLUDE)' tools/launcher.c build/dist/embedded.c \
		-Wl,--whole-archive $(DIST_RT) -Wl,--no-whole-archive -rdynamic $(DEPS_LDFLAGS) $(LDFLAGS) \
		-lluajit-5.1 -lm -ldl -pthread $(LDLIBS) -o build/dist/nua
	@printf '%s\n' 'built build/dist/nua'

test-dist: dist
	rm -rf build/tmp/dist-cache build/tmp/dist-*.c
	NUA_CACHE=$(CURDIR)/build/tmp/dist-cache build/dist/nua run examples/csv.nua examples/data/sales.csv price > build/tmp/dist-run.txt
	@grep -q 'sum 128.29' build/tmp/dist-run.txt || { cat build/tmp/dist-run.txt; printf '%s\n' 'dist run failed'; exit 1; }
	@if test -d build/tmp/dist-cache; then \
		files="$$(find build/tmp/dist-cache -name '*.so')" || exit 1; \
		test -z "$$files" || { printf '%s\n' 'the binary still builds a runtime library'; exit 1; }; \
	fi
	CC=/bin/false build/dist/nua run examples/hello.nua > build/tmp/dist-hello.txt
	@grep -q 'hello from Nua' build/tmp/dist-hello.txt || { cat build/tmp/dist-hello.txt; printf '%s\n' 'probe tables did not cover hello'; exit 1; }
	@CC=/bin/false build/dist/nua run examples/count_lines.nua README.md > build/tmp/dist-io.txt || true
	@grep -q 'lines = ' build/tmp/dist-io.txt || { cat build/tmp/dist-io.txt; printf '%s\n' 'probe tables did not cover io'; exit 1; }
	build/dist/nua check examples/hello.nua
	build/dist/nua version | grep -q '^nua '
	build/dist/nua build examples/hello.nua -o build/tmp/hello
	build/tmp/hello | grep -q 'hello from Nua'
	build/dist/nua test examples/tests.nua | grep -q '3 tests, 0 failed'
	build/dist/nua run examples/project alpha | grep -q 'hello, alpha'
	build/dist/nua build examples/project -o build/tmp/proj
	build/tmp/proj beta | grep -q 'hello, beta'
	build/dist/nua build examples/args.nua -o build/tmp/args
	build/tmp/args one two | grep -q 'args = 3, bytes = 6'
	build/dist/nua fuzz --tasks --quick
	build/dist/nua fuzz --storage --count 4
	build/dist/nua -o build/tmp/dist-arrays.c examples/arrays.nua
	@printf '%s\n' 'dist checks passed (run, build, check, fuzzers)'

# the alpha gate: the whole suite, compiled by the built binary
test-dist-suite: dist
	NUA_BIN=$(CURDIR)/build/dist/nua $(LUA) tests/run.lua

run: dirs
	@test -n "$(PROGRAM)" || { printf '%s\n' 'Set PROGRAM=path/to/program.nua'; exit 2; }
	$(LUA) nua.lua run "$(PROGRAM)" $(ARGS)
