/*
** embed-eh.cpp -- the external-EH witness for issue #11: a downstream
** whose own C++ throws and catches a *typed* exception, linked with Lua
** built under -DLUAW_EXTERNAL_EH (the bundled catch(...)-only micro-shim
** suppressed) and a real libc++abi built with -fwasm-exceptions.
**
** It proves the two halves of "full C++ EH survives the link":
**
**   (1) typed catches and exception-object destructors work -- exactly
**       the semantics the micro-shim cannot provide (it does no type
**       matching and runs no destructors); and
**   (2) Lua's own errors still travel the same external runtime -- a
**       Lua error() is caught as a lua_pcall status with its message
**       intact, and the VM stays usable. One coherent EH domain.
**
** A silent fallback to the shim is impossible for this program: typed
** catch sites emit calls to _Unwind_CallPersonality/__wasm_lpad_context,
** which only the real runtime provides -- without it the LINK fails
** (witnessed). The fingerprint gate in build-eh.sh is belt to that
** suspenders. See build-eh.sh for how the wasm-EH libc++abi is built.
*/
#include <stdio.h>
#include <string.h>

#include "lua.hpp"

struct HostError {
  int code;
  static int live;                 /* counts ctor/dtor balance */
  explicit HostError(int c) : code(c) { ++live; }
  HostError(const HostError &o) : code(o.code) { ++live; }
  ~HostError() { --live; }
};
int HostError::live = 0;

int main(void) {
  /* (1) typed catch of the downstream's own exception, destructor run */
  bool typed = false;
  try { throw HostError(42); }
  catch (HostError &e) { typed = (e.code == 42); }
  if (!typed) { fprintf(stderr, "FAIL: typed catch missed\n"); return 1; }
  if (HostError::live != 0) {
    fprintf(stderr, "FAIL: exception dtor did not run (live=%d)\n", HostError::live);
    return 1;
  }
  printf("typed catch + dtor OK\n");

  /* (2) Lua's own errors travel the same external runtime */
  lua_State *L = luaL_newstate();
  if (L == NULL) { fprintf(stderr, "FAIL: cannot create Lua state\n"); return 1; }
  luaL_openlibs(L);
  int st = luaL_dostring(L, "error('lua error through external EH')");
  if (st == LUA_OK) { fprintf(stderr, "FAIL: error() did not raise\n"); return 1; }
  const char *msg = lua_tostring(L, -1);
  if (msg == NULL || strstr(msg, "external EH") == NULL) {
    fprintf(stderr, "FAIL: error message did not survive the unwind\n");
    return 1;
  }
  printf("lua error caught: %s\n", msg);
  lua_pop(L, 1);
  if (luaL_dostring(L, "print('lua still alive:', 2+3)")) {
    fprintf(stderr, "FAIL: VM unusable after the error\n");
    return 1;
  }
  lua_close(L);

  printf("EXTERNAL-EH WITNESS OK\n");
  return 0;
}
