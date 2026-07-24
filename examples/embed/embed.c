/*
** embed.c -- a minimal downstream that links Lua *into* its own
** wasm32-wasi artifact (issue #11's recommended source-drop path).
**
** It is plain C, uses only the public lua.h / lauxlib.h / lualib.h API,
** and proves the two things the embed contract must guarantee:
**
**   (1) driving embedded Lua -- it loads and runs a Lua module through
**       the linked-in core; and
**   (2) error unwinding across the boundary -- a Lua error() raised
**       inside that module travels out through the wasm-EH machinery and
**       is caught here as a lua_pcall status, with the message intact. In
**       the wasm target this is the wasm exception path; the same source
**       witnesses it natively too.
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

/* A stand-in downstream module, loaded and run through the embedded core.
   Its point is only to exercise the embed contract: drive Lua, and raise
   an error that must cross the C boundary intact. */
static const char *GAME_MODULE =
  "local M = {}\n"
  "function M.add(a, b) return a + b end\n"
  "function M.boom() error('kaboom from an embedded Lua module') end\n"
  "return M\n";

int main(void) {
  lua_State *L = luaL_newstate();
  if (L == NULL) { fprintf(stderr, "cannot create Lua state\n"); return 1; }
  luaL_openlibs(L);

  /* Load the module once; keep its table on the stack. */
  if (luaL_loadstring(L, GAME_MODULE) != LUA_OK ||
      lua_pcall(L, 0, 1, 0) != LUA_OK) {
    fprintf(stderr, "FAIL (load module): %s\n", lua_tostring(L, -1));
    return 1;
  }

  /* (1) drive embedded Lua: game.add(2, 3) == 5 */
  lua_getfield(L, -1, "add");
  lua_pushinteger(L, 2);
  lua_pushinteger(L, 3);
  if (lua_pcall(L, 2, 1, 0) != LUA_OK) {
    fprintf(stderr, "FAIL (add): %s\n", lua_tostring(L, -1));
    return 1;
  }
  if (lua_tointeger(L, -1) != 5) {
    fprintf(stderr, "FAIL: add returned the wrong value\n");
    return 1;
  }
  printf("game.add(2,3) = %lld\n", (long long)lua_tointeger(L, -1));
  lua_pop(L, 1);                       /* drop the result, leaving the module */

  /* (2) raise a Lua error inside the module and catch it here */
  lua_getfield(L, -1, "boom");         /* game.boom */
  int status = lua_pcall(L, 0, 0, 0);  /* call it, protected */
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
