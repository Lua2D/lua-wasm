/*
** embed.c -- a minimal downstream that links Lua *into* its own
** wasm32-wasi artifact (issue #11's recommended source-drop path).
**
** It is plain C, uses only the public lua.h / lauxlib.h / lualib.h API,
** and proves the two things the embed contract must guarantee:
**
**   (1) AOT composition -- it drives a module that was AOT-compiled by
**       ./src/luaot and linked in (game.add), i.e. luaot-generated code
**       binds correctly against the embedded core; and
**   (2) error unwinding across the boundary -- a Lua error() raised
**       inside that AOT-compiled module travels out through the wasm-EH
**       machinery and is caught here as a lua_pcall status, with the
**       message intact. In the wasm target this is the wasm exception
**       path; the same source witnesses it natively too.
**
** The luaw_* reactor exports are deliberately absent: an embedder owns
** its own control flow and speaks lua.h, not the artifact's reactor
** interface. (Build without -DMAKE_REACTOR; see the Makefile.)
*/
#include <stdio.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"

/* The AOT module's entry point, emitted by ./src/luaot game.lua -m aot_game
   and compiled into this program (see build.sh). */
int luaopen_aot_game(lua_State *L);

/* Register the AOT module under package.preload, the same wiring the
   whole-artifact build's generated registry does, but by hand -- a
   downstream with N modules writes this loop once. */
static void preload_aot_modules(lua_State *L) {
  luaL_getsubtable(L, LUA_REGISTRYINDEX, LUA_PRELOAD_TABLE);
  lua_pushcfunction(L, luaopen_aot_game);
  lua_setfield(L, -2, "aot_game");
  lua_pop(L, 1);
}

int main(void) {
  lua_State *L = luaL_newstate();
  if (L == NULL) { fprintf(stderr, "cannot create Lua state\n"); return 1; }
  luaL_openlibs(L);
  preload_aot_modules(L);

  /* (1) drive AOT-compiled code */
  if (luaL_dostring(L,
        "local g = require('aot_game')\n"
        "assert(g.add(2, 3) == 5, 'AOT add returned the wrong value')\n"
        "print('aot game.add(2,3) =', g.add(2, 3))")) {
    fprintf(stderr, "FAIL (aot drive): %s\n", lua_tostring(L, -1));
    return 1;
  }

  /* (2) raise a Lua error inside the AOT module and catch it here */
  lua_getglobal(L, "require");
  lua_pushstring(L, "aot_game");
  if (lua_pcall(L, 1, 1, 0) != LUA_OK) {
    fprintf(stderr, "FAIL (require): %s\n", lua_tostring(L, -1));
    return 1;
  }
  lua_getfield(L, -1, "boom");        /* game.boom */
  int status = lua_pcall(L, 0, 0, 0); /* call it, protected */
  if (status != LUA_OK) {
    const char *msg = lua_tostring(L, -1);
    printf("caught Lua error across the boundary: %s\n", msg);
    if (msg == NULL || strstr(msg, "kaboom") == NULL) {
      fprintf(stderr, "FAIL: error message did not survive the unwind\n");
      return 1;
    }
    lua_pop(L, 1);
  } else {
    fprintf(stderr, "FAIL: game.boom() did not raise\n");
    return 1;
  }

  lua_close(L);
  printf("EMBED WITNESS OK\n");
  return 0;
}
