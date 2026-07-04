//
// Most of what we need is copied verbatim from lvm.c
//

// Get access to static functions from lvm.c, but be careful to not
// re-define the functions that are already exported by liblua.a
#define LUAOT_IS_MODULE 1
#include "lvm.c"

//
// Our modified version of vmfetch(). Since instr and index are compile time
// constants, the C compiler should be able to optimize the code in many cases.
//

#undef  vmfetch
#define aot_vmfetch(instr)	{ \
  if (l_unlikely(trap)) {  /* stack reallocation or hooks? */ \
    trap = luaG_traceexec(L, pc);  /* handle hooks */ \
    updatebase(ci);  /* correct stack */ \
  } \
  i = instr; pc++; \
  ra = RA(i); /* WARNING: any stack reallocation invalidates 'ra' */ \
}

#undef  vmdispatch
#undef  vmcase
#undef  vmbreak
