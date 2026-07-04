# Makefile for installing Lua
# See doc/readme.html for installation and customization instructions.

# == CHANGE THE SETTINGS BELOW TO SUIT YOUR ENVIRONMENT =======================

# Your platform. See PLATS for possible values.
PLAT= none

# Where to install. The installation starts in the src and doc directories,
# so take care if INSTALL_TOP is not an absolute path. See the local target.
# You may want to make INSTALL_LMOD and INSTALL_CMOD consistent with
# LUA_ROOT, LUA_LDIR, and LUA_CDIR in luaconf.h.
INSTALL_TOP= /usr/local
INSTALL_BIN= $(INSTALL_TOP)/bin
INSTALL_INC= $(INSTALL_TOP)/include
INSTALL_LIB= $(INSTALL_TOP)/lib
INSTALL_MAN= $(INSTALL_TOP)/man/man1
INSTALL_LMOD= $(INSTALL_TOP)/share/lua/$V
INSTALL_CMOD= $(INSTALL_TOP)/lib/lua/$V

# How to install. If your install program does not support "-p", then
# you may have to run ranlib on the installed liblua.a.
INSTALL= install -p
INSTALL_EXEC= $(INSTALL) -m 0755
INSTALL_DATA= $(INSTALL) -m 0644
#
# If you don't have "install" you can use "cp" instead.
# INSTALL= cp -p
# INSTALL_EXEC= $(INSTALL)
# INSTALL_DATA= $(INSTALL)

# Other utilities.
MKDIR= mkdir -p
RM= rm -f

# == END OF USER SETTINGS -- NO NEED TO CHANGE ANYTHING BELOW THIS LINE =======

# Convenience platforms targets.
PLATS= aix bsd c89 freebsd generic guess linux linux-readline macosx mingw posix solaris

# What to install.
TO_BIN= lua luac
TO_INC= lua.h luaconf.h lualib.h lauxlib.h lua.hpp
TO_LIB= liblua.a
TO_MAN= lua.1 luac.1

# Lua version and release.
V= 5.4
R= $V.0

# Targets start here.
all:	$(PLAT)

$(PLATS) clean:
	cd src && $(MAKE) $@

test:	dummy
	src/lua -v

install: dummy
	cd src && $(MKDIR) $(INSTALL_BIN) $(INSTALL_INC) $(INSTALL_LIB) $(INSTALL_MAN) $(INSTALL_LMOD) $(INSTALL_CMOD)
	cd src && $(INSTALL_EXEC) $(TO_BIN) $(INSTALL_BIN)
	cd src && $(INSTALL_DATA) $(TO_INC) $(INSTALL_INC)
	cd src && $(INSTALL_DATA) $(TO_LIB) $(INSTALL_LIB)
	cd doc && $(INSTALL_DATA) $(TO_MAN) $(INSTALL_MAN)

uninstall:
	cd src && cd $(INSTALL_BIN) && $(RM) $(TO_BIN)
	cd src && cd $(INSTALL_INC) && $(RM) $(TO_INC)
	cd src && cd $(INSTALL_LIB) && $(RM) $(TO_LIB)
	cd doc && cd $(INSTALL_MAN) && $(RM) $(TO_MAN)

local:
	$(MAKE) install INSTALL_TOP=../install

none:
	@echo "Please do 'make PLATFORM' where PLATFORM is one of these:"
	@echo "   $(PLATS)"
	@echo "See doc/readme.html for complete instructions."

# make may get confused with test/ and install/
dummy:

# echo config parameters
echo:
	@cd src && $(MAKE) -s echo
	@echo "PLAT= $(PLAT)"
	@echo "V= $V"
	@echo "R= $R"
	@echo "TO_BIN= $(TO_BIN)"
	@echo "TO_INC= $(TO_INC)"
	@echo "TO_LIB= $(TO_LIB)"
	@echo "TO_MAN= $(TO_MAN)"
	@echo "INSTALL_TOP= $(INSTALL_TOP)"
	@echo "INSTALL_BIN= $(INSTALL_BIN)"
	@echo "INSTALL_INC= $(INSTALL_INC)"
	@echo "INSTALL_LIB= $(INSTALL_LIB)"
	@echo "INSTALL_MAN= $(INSTALL_MAN)"
	@echo "INSTALL_LMOD= $(INSTALL_LMOD)"
	@echo "INSTALL_CMOD= $(INSTALL_CMOD)"
	@echo "INSTALL_EXEC= $(INSTALL_EXEC)"
	@echo "INSTALL_DATA= $(INSTALL_DATA)"

# echo pkg-config data
pc:
	@echo "version=$R"
	@echo "prefix=$(INSTALL_TOP)"
	@echo "libdir=$(INSTALL_LIB)"
	@echo "includedir=$(INSTALL_INC)"

# == WASM ======================================================================
# The wasm atom: the whole interpreter as one translation unit, one artifact.
# Compiled as C++ so Lua's error handling rides the wasm exception-handling
# proposal (see src/onelua.c for why the C sjlj route is blocked today).
# Toolchain: clang with a wasm32-wasi sysroot (Ubuntu: apt install clang-19
# wasi-libc libclang-rt-19-dev-wasm32 lld-19). Run under any WASI host with
# wasm EH support, e.g.: node scripts/wasm-run.mjs lua.wasm script.lua
#
# AOT: pass WASM_AOT="path/to/mod.lua ..." to compile Lua modules ahead of
# time with luaot (built natively on demand) and link them into the same
# artifact. Each module lands in package.preload as "aot_<name>", so
# require("aot_<name>") runs it at AOT speed. luaot-generated units are
# partial evaluations of lvm.c and are inherently their own translation
# units; the build stays one compiler invocation, one artifact.

WASM_CLANGXX= clang++-19
WASM_SYSROOT= /usr
WASM_STACK= 8388608
WASM_O= lua.wasm
WASM_AOT=
WASM_AOT_DIR= wasm-aot

# -fno-strict-aliasing: at -O2, clang 19's wasm backend reorders the
# GC-stop flag store in lgc.c's GCTM across the finalizer call under
# type-based aliasing analysis (witnessed by 5.4.8's gc reentrancy
# test; correct at -O1/-Os and with this flag). The standard mitigation,
# same as SQLite and the kernel ship with.
WASM_FLAGS= --target=wasm32-wasi --sysroot=$(WASM_SYSROOT) -O2 -fno-strict-aliasing \
	  -fwasm-exceptions -nostdlib++ \
	  -Isrc/wasi -Isrc \
	  -D_WASI_EMULATED_SIGNAL -D_WASI_EMULATED_PROCESS_CLOCKS \
	  -DLUA_USE_JUMPTABLE=0 \
	  -Wl,-z,stack-size=$(WASM_STACK) \
	  -lwasi-emulated-signal -lwasi-emulated-process-clocks

# The deepest witness: a native debug interpreter with upstream's
# ltests instrumentation (checked allocator, internal assertions, the
# T library that unlocks the suite's C-API battery). Witness-only.
# Run: cd tests && ../lua-debug all.lua   (expect zero 'testC not
# active' skips and 'final OK !!!')
lua-debug:
	$(CC) -O1 -g -DLUA_USE_LINUX -DLUA_USE_READLINE \
	  -DLUA_LTESTS '-DLUA_USER_H="ltests.h"' -Itests/ltests -Isrc \
	  -o lua-debug src/onelua.c tests/ltests/ltests.c \
	  -Wl,-E -lm -ldl -lreadline

# The embeddable artifact: a wasm reactor (library, not command) whose
# host interface is WASI plus the luaw_* exports defined in onelua.c.
# Same WASM_AOT knob as the 'wasm' target.
WASM_LIB_O= lua-lib.wasm

wasm-lib: WASM_EXTRA= -DMAKE_LIB -mexec-model=reactor -Wl,--export-dynamic
wasm-lib: WASM_O= $(WASM_LIB_O)
wasm-lib: wasm

wasm:
ifeq ($(strip $(WASM_AOT)),)
	$(WASM_CLANGXX) $(WASM_FLAGS) $(WASM_EXTRA) -o $(WASM_O) -x c++ src/onelua.c
else
	@test -x src/luaot || $(MAKE) -C src guess
	rm -rf $(WASM_AOT_DIR) && mkdir -p $(WASM_AOT_DIR)
	set -e; \
	names=""; \
	for f in $(WASM_AOT); do \
	  n=$$(basename $$f .lua | tr '.-' '__'); \
	  ./src/luaot $$f -o $(WASM_AOT_DIR)/$$n.c -m aot_$$n; \
	  names="$$names $$n"; \
	done; \
	{ echo '#include "lua.h"'; \
	  echo '#include "lauxlib.h"'; \
	  for n in $$names; do echo "int luaopen_aot_$$n(lua_State *L);"; done; \
	  echo 'void luaot_preload(lua_State *L) {'; \
	  echo '  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);'; \
	  for n in $$names; do \
	    echo "  lua_pushcfunction(L, luaopen_aot_$$n);"; \
	    echo "  lua_setfield(L, -2, \"aot_$$n\");"; \
	  done; \
	  echo '  lua_pop(L, 1);'; \
	  echo '}'; } > $(WASM_AOT_DIR)/registry.c
	$(WASM_CLANGXX) $(WASM_FLAGS) $(WASM_EXTRA) -DLUA_AOT -o $(WASM_O) \
	  -x c++ src/onelua.c -x c $(WASM_AOT_DIR)/*.c
endif

# list targets that do not create files (but not all makes understand .PHONY)
.PHONY: all $(PLATS) clean test install uninstall local none dummy echo pc wasm

# (end of Makefile)
