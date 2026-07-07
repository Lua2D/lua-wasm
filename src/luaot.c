/*
 * Lua bytecode-to-C compiler
 */

// This luac-derived code is incompatible with lua_assert because it calls the
// GETARG macros even for opcodes where it is not appropriate to do so.
#undef LUAI_ASSERT

#include <ctype.h>
#include <errno.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"

#include "ldebug.h"
#include "lgc.h"
#include "lobject.h"
#include "lopcodes.h"
#include "lopnames.h"
#include "lstate.h"
#include "lstring.h"
#include "lundump.h"

//
// Command-line arguments and main function
// ----------------------------------------
//
// This part should not depend much on the Lua version
//

static const char *program_name    = "luaot";
static char *input_filename  = NULL;
static char *output_filename = NULL;
static char *module_name     = NULL;
static char *chunkname_override = NULL;

static FILE * output_file = NULL;
static int nfunctions = 0;
static TString **tmname;

int executable = 0;
static
void usage()
{
    fprintf(stderr,
          "usage: %s [options] [filename]\n"
          "Available options are:\n"
          "  -o name            output to file 'name'\n"
          "  -m name            generate code with `name` function as main function\n"
          "  -e                 add a main symbol for executables\n"
          "  -c chunkname       bake 'chunkname' as the module's debug identity\n"
          "                     (default: '@' + the input path as given, which\n"
          "                     differs from what a runtime loadfile of the same\n"
          "                     file would report unless the build runs from the\n"
          "                     same directory -- see issue #31)\n",
          program_name);
}

static
void fatal_error(const char *msg)
{
    fprintf(stderr, "%s: %s\n", program_name, msg);
    exit(1);
}

static
__attribute__ ((format (printf, 1, 2)))
void print(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vfprintf(output_file, fmt, args);
    va_end(args);
}

static
__attribute__ ((format (printf, 1, 2)))
void println(const char *fmt, ...)
{
    va_list args;
    va_start(args, fmt);
    vfprintf(output_file, fmt, args);
    va_end(args);
    fprintf(output_file, "\n");
}

static
void printnl()
{
    // This separate function avoids Wformat-zero-length warnings with println
    fprintf(output_file, "\n");
}


static void doargs(int argc, char **argv)
{
    // I wonder if I should just use getopt instead of parsing options by hand
    program_name = argv[0];

    int do_opts = 1;
    int npos = 0;
    for (int i = 1; i < argc; i++) {
        char *arg = argv[i];
        if (do_opts && arg[0] == '-') {
            if (0 == strcmp(arg, "--")) {
                do_opts = 0;
            } else if (0 == strcmp(arg, "-h")) {
                usage();
                exit(0);
            } else if (0 == strcmp(arg, "-m")) {
                i++;
                if (i >= argc) { fatal_error("missing argument for -m"); }
                module_name = argv[i];
            } else if (0 == strcmp(arg, "-e")) {
                executable = 1;
            } else if (0 == strcmp(arg, "-o")) {
                i++;
                if (i >= argc) { fatal_error("missing argument for -o"); }
                output_filename = argv[i];
            } else if (0 == strcmp(arg, "-c")) {
                i++;
                if (i >= argc) { fatal_error("missing argument for -c"); }
                chunkname_override = argv[i];
            } else {
                fprintf(stderr, "unknown option %s\n", arg);
                exit(1);
            }
        } else {
            switch (npos) {
                case 0:
                    input_filename = arg;
                    break;
                default:
                    fatal_error("too many positional arguments");
                    break;
            }
            npos++;
        }
    }

    if (output_filename == NULL) {
        usage();
        exit(1);
    }
}

static char *get_module_name_from_filename(const char *);
static void check_module_name(const char *);
static void replace_dots(char *);
static void print_functions();
static void print_source_code(lua_State *L);

// Rewrite the debug identity of the whole Proto tree (issue #31).
// The generated module embeds a BYTECODE DUMP of the input, and the
// dump serializes each Proto's source string -- so the chunkname the
// runtime sees comes from here, not from the loadbuffer chunkname
// argument (which only applies where the dump carries none). Setting
// the top-level source is enough for the dump's compactness trick
// (children sharing the parent's source dump NULL and inherit at
// load), but children hold their own pointers, so walk them all.
static void rebake_source(lua_State *L, Proto *p, TString *src)
{
    p->source = src;
    luaC_objbarrier(L, p, src);
    for (int i = 0; i < p->sizep; i++) {
        rebake_source(L, p->p[i], src);
    }
}

int main(int argc, char **argv)
{
    // Process input arguments

    doargs(argc, argv);

    if (!module_name) {
        module_name = get_module_name_from_filename(output_filename);
    }
    check_module_name(module_name);
    replace_dots(module_name);

    // Read the input

    lua_State *L = luaL_newstate();
    if (luaL_loadfile(L, input_filename) != LUA_OK) {
        fatal_error(lua_tostring(L,-1));
    }
    Proto *proto = getproto(s2v(L->top.p-1));
    tmname = G(L)->tmname;

    if (chunkname_override != NULL) {
        rebake_source(L, proto, luaS_new(L, chunkname_override));
    }

    // Generate the file

    output_file = fopen(output_filename, "w");
    if (output_file == NULL) { fatal_error(strerror(errno)); }

    println("#include \"luaot_header.c\"");
    printnl();
    print_functions(proto);
    printnl();
    print_source_code(L);
    printnl();
    println("#define LUAOT_MODULE_NAME \"%s\"", module_name);
    println("#define LUAOT_LUAOPEN_NAME luaopen_%s", module_name);
    {
        // The chunkname baked into the module, so the loaded chunk
        // carries a chosen debug identity (source, short_src). By
        // default this is "@" + the input path AS PASSED ON THE
        // COMMAND LINE -- a build-machine detail: an AOT'd chunk then
        // reports a different short_src than a runtime loadfile of
        // the same file (issue #31). -c rewrites the Proto tree's
        // source above (rebake_source), which is what actually
        // reaches the runtime -- the bytecode dump below serializes
        // it; this #define only covers protos the dump leaves bare.
        // (The Makefile pins -c "@" + basename so the AOT and
        // loadfile identities agree in the suite's layout.)
        const char *chunkname = getstr(proto->source);
        print("#define LUAOT_MODULE_CHUNKNAME \"");
        for (const char *p = chunkname; *p != '\0'; p++) {
            if (*p == '\\' || *p == '"') { print("\\%c", *p); }
            else { print("%c", *p); }
        }
        println("\"");
    }
    printnl();
    println("#include \"luaot_footer.c\"");
    if (executable) {
      printnl();
      printnl();
      println("int main(int argc, char *argv[]) {");
      println(" lua_State *L = luaL_newstate();");
      println(" luaL_openlibs(L);");
      println(" int i;");
      println(" lua_createtable(L, argc + 1, 0);");
      println(" for (i = 0; i < argc; i++) {");
      println("   lua_pushstring(L, argv[i]);");
      println("   lua_rawseti(L, -2, i);");
      println(" }");
      println(" lua_setglobal(L, \"arg\");");
      println(" lua_pushcfunction(L, LUAOT_LUAOPEN_NAME);");
      println("i = lua_pcall(L, 0, 0, 0);");
      println(" if (i != LUA_OK) {");
      println("   fprintf(stderr, \"%%s\\n\", lua_tostring(L, -1));");
      println("   return 1;");
      println(" }");
      println("lua_close(L);");
      println(" return 0;");
      println("}");
    }

    return 0;
}

// Deduce the Lua module name given the file name
// Example:  ./foo/bar/baz.c -> foo.bar.baz
static
char *get_module_name_from_filename(const char *filename)
{
    size_t n = strlen(filename);

    int has_extension = 0;
    size_t sep = 0;
    for (size_t i = 0; i < n; i++) {
        if (filename[i] == '.') {
            has_extension = 1;
            sep = i;
        }
    }

    if (!has_extension || 0 != strcmp(filename + sep, ".c")) {
        fatal_error("output file does not have a \".c\" extension");
    }

    char *module_name = malloc(sep+1);
    for (size_t i = 0; i < sep; i++) {
        int c = filename[i];
        if (c == '/') {
            module_name[i] = '.';
        } else {
            module_name[i] = c;
        }
    }
    module_name[sep] = '\0';

    return module_name;
}

// Check if a module name contains only allowed characters
static
void check_module_name(const char *module_name)
{
    for (size_t i = 0; module_name[i] != '\0'; i++) {
        int c = module_name[i];
        if (!isalnum(c) && c != '_' && c != '.') {
            fatal_error("output module name must contain only letters, numbers, or '.'");
        }
    }
}

// Convert a module name to the internal "luaopen" name
static
void replace_dots(char *module_name)
{
    for (size_t i = 0; module_name[i] != '\0'; i++) {
        if (module_name[i] == '.') {
            module_name[i] = '_';
        }
    }
}


//
// Printing bytecode information
// -----------------------------
//
// These functions are copied from luac.c (and reindented)
//

#define UPVALNAME(x) ((f->upvalues[x].name) ? getstr(f->upvalues[x].name) : "-")
#define VOID(p) ((const void*)(p))
#define eventname(i) (getstr(tmname[i]))

static
void PrintString(const TString* ts)
{
    const char* s = getstr(ts);
    size_t i,n = tsslen(ts);
    print("\"");
    for (i=0; i<n; i++) {
        int c=(int)(unsigned char)s[i];
        switch (c) {
            case '"':
                print("\\\"");
                break;
            case '\\':
                print("\\\\");
                break;
            case '\a':
                print("\\a");
                break;
            case '\b':
                print("\\b");
                break;
            case '\f':
                print("\\f");
                break;
            case '\n':
                print("\\n");
                break;
            case '\r':
                print("\\r");
                break;
            case '\t':
                print("\\t");
                break;
            case '\v':
                print("\\v");
                break;
            default:
                if (isprint(c)) {
                    print("%c",c);
                } else {
                    print("\\%03d",c);
                }
                break;
        }
    }
    print("\"");
}

static
void PrintConstant(const Proto* f, int i)
{
    const TValue* o=&f->k[i];
    switch (ttypetag(o)) {
        case LUA_VNIL:
            print("nil");
            break;
        case LUA_VFALSE:
            print("false");
            break;
        case LUA_VTRUE:
            print("true");
            break;
        case LUA_VNUMFLT:
            {
                char buff[100];
                sprintf(buff,LUA_NUMBER_FMT,fltvalue(o));
                print("%s",buff);
                if (buff[strspn(buff,"-0123456789")]=='\0') print(".0");
                break;
            }
        case LUA_VNUMINT:
            print(LUA_INTEGER_FMT, ivalue(o));
            break;
        case LUA_VSHRSTR:
        case LUA_VLNGSTR:
            PrintString(tsvalue(o));
            break;
        default: /* cannot happen */
            print("?%d",ttypetag(o));
            break;
    }
}

#define COMMENT		"\t; "
#define EXTRAARG	GETARG_Ax(code[pc+1])
#define EXTRAARGC	(EXTRAARG*(MAXARG_C+1))
#define ISK		(isk ? "k" : "")

static
void luaot_PrintOpcodeComment(Proto *f, int pc)
{
    // Adapted from the PrintCode function of luac.c
    const Instruction *code = f->code;
    const Instruction i = code[pc];
    OpCode o = GET_OPCODE(i);
    int a=GETARG_A(i);
    int b=GETARG_B(i);
    int c=GETARG_C(i);
    int ax=GETARG_Ax(i);
    int bx=GETARG_Bx(i);
    int sb=GETARG_sB(i);
    int sc=GETARG_sC(i);
    int sbx=GETARG_sBx(i);
    int isk=GETARG_k(i);
    int line=luaG_getfuncline(f,pc);

    print("  //");
    print(" %d\t", pc);
    if (line > 0) {
        print("[%d]\t", line);
    } else {
        print("[-]\t");
    }
    print("%-9s\t", opnames[o]);
    switch (o) {
        case OP_MOVE:
            print("%d %d",a,b);
            break;
        case OP_LOADI:
            print("%d %d",a,sbx);
            break;
        case OP_LOADF:
            print("%d %d",a,sbx);
            break;
        case OP_LOADK:
            print("%d %d",a,bx);
            print(COMMENT); PrintConstant(f,bx);
            break;
        case OP_LOADKX:
            print("%d",a);
            print(COMMENT); PrintConstant(f,EXTRAARG);
            break;
        case OP_LOADFALSE:
            print("%d",a);
            break;
        case OP_LFALSESKIP:
            print("%d",a);
            break;
        case OP_LOADTRUE:
            print("%d",a);
            break;
        case OP_LOADNIL:
            print("%d %d",a,b);
            print(COMMENT "%d out",b+1);
            break;
        case OP_GETUPVAL:
            print("%d %d",a,b);
            print(COMMENT "%s", UPVALNAME(b));
            break;
        case OP_SETUPVAL:
            print("%d %d",a,b);
            print(COMMENT "%s", UPVALNAME(b));
            break;
        case OP_GETTABUP:
            print("%d %d %d",a,b,c);
            print(COMMENT "%s", UPVALNAME(b));
            print(" "); PrintConstant(f,c);
            break;
        case OP_GETTABLE:
            print("%d %d %d",a,b,c);
            break;
        case OP_GETI:
            print("%d %d %d",a,b,c);
            break;
        case OP_GETFIELD:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_SETTABUP:
            print("%d %d %d%s",a,b,c,ISK);
            print(COMMENT "%s",UPVALNAME(a));
            print(" "); PrintConstant(f,b);
            if (isk) { print(" "); PrintConstant(f,c); }
            break;
        case OP_SETTABLE:
            print("%d %d %d%s",a,b,c,ISK);
            if (isk) { print(COMMENT); PrintConstant(f,c); }
            break;
        case OP_SETI:
            print("%d %d %d%s",a,b,c,ISK);
            if (isk) { print(COMMENT); PrintConstant(f,c); }
            break;
        case OP_SETFIELD:
            print("%d %d %d%s",a,b,c,ISK);
            print(COMMENT); PrintConstant(f,b);
            if (isk) { print(" "); PrintConstant(f,c); }
            break;
        case OP_NEWTABLE:
            print("%d %d %d",a,b,c);
            print(COMMENT "%d",c+EXTRAARGC);
            break;
        case OP_SELF:
            print("%d %d %d%s",a,b,c,ISK);
            if (isk) { print(COMMENT); PrintConstant(f,c); }
            break;
        case OP_ADDI:
            print("%d %d %d",a,b,sc);
            break;
        case OP_ADDK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_SUBK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_MULK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_MODK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_POWK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_DIVK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_IDIVK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_BANDK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_BORK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_BXORK:
            print("%d %d %d",a,b,c);
            print(COMMENT); PrintConstant(f,c);
            break;
        case OP_SHRI:
            print("%d %d %d",a,b,sc);
            break;
        case OP_SHLI:
            print("%d %d %d",a,b,sc);
            break;
        case OP_ADD:
            print("%d %d %d",a,b,c);
            break;
        case OP_SUB:
            print("%d %d %d",a,b,c);
            break;
        case OP_MUL:
            print("%d %d %d",a,b,c);
            break;
        case OP_MOD:
            print("%d %d %d",a,b,c);
            break;
        case OP_POW:
            print("%d %d %d",a,b,c);
            break;
        case OP_DIV:
            print("%d %d %d",a,b,c);
            break;
        case OP_IDIV:
            print("%d %d %d",a,b,c);
            break;
        case OP_BAND:
            print("%d %d %d",a,b,c);
            break;
        case OP_BOR:
            print("%d %d %d",a,b,c);
            break;
        case OP_BXOR:
            print("%d %d %d",a,b,c);
            break;
        case OP_SHL:
            print("%d %d %d",a,b,c);
            break;
        case OP_SHR:
            print("%d %d %d",a,b,c);
            break;
        case OP_MMBIN:
            print("%d %d %d",a,b,c);
            print(COMMENT "%s",eventname(c));
            break;
        case OP_MMBINI:
            print("%d %d %d %d",a,sb,c,isk);
            print(COMMENT "%s",eventname(c));
            if (isk) print(" flip");
            break;
        case OP_MMBINK:
            print("%d %d %d %d",a,b,c,isk);
            print(COMMENT "%s ",eventname(c)); PrintConstant(f,b);
            if (isk) print(" flip");
            break;
        case OP_UNM:
            print("%d %d",a,b);
            break;
        case OP_BNOT:
            print("%d %d",a,b);
            break;
        case OP_NOT:
            print("%d %d",a,b);
            break;
        case OP_LEN:
            print("%d %d",a,b);
            break;
        case OP_CONCAT:
            print("%d %d",a,b);
            break;
        case OP_CLOSE:
            print("%d",a);
            break;
        case OP_TBC:
            print("%d",a);
            break;
        case OP_JMP:
            print("%d",GETARG_sJ(i));
            print(COMMENT "to %d",GETARG_sJ(i)+pc+2);
            break;
        case OP_EQ:
            print("%d %d %d",a,b,isk);
            break;
        case OP_LT:
            print("%d %d %d",a,b,isk);
            break;
        case OP_LE:
            print("%d %d %d",a,b,isk);
            break;
        case OP_EQK:
            print("%d %d %d",a,b,isk);
            print(COMMENT); PrintConstant(f,b);
            break;
        case OP_EQI:
            print("%d %d %d",a,sb,isk);
            break;
        case OP_LTI:
            print("%d %d %d",a,sb,isk);
            break;
        case OP_LEI:
            print("%d %d %d",a,sb,isk);
            break;
        case OP_GTI:
            print("%d %d %d",a,sb,isk);
            break;
        case OP_GEI:
            print("%d %d %d",a,sb,isk);
            break;
        case OP_TEST:
            print("%d %d",a,isk);
            break;
        case OP_TESTSET:
            print("%d %d %d",a,b,isk);
            break;
        case OP_CALL:
            print("%d %d %d",a,b,c);
            print(COMMENT);
            if (b==0) print("all in "); else print("%d in ",b-1);
            if (c==0) print("all out"); else print("%d out",c-1);
            break;
        case OP_TAILCALL:
            print("%d %d %d",a,b,c);
            print(COMMENT "%d in",b-1);
            break;
        case OP_RETURN:
            print("%d %d %d",a,b,c);
            print(COMMENT);
            if (b==0) print("all out"); else print("%d out",b-1);
            break;
        case OP_RETURN0:
            break;
        case OP_RETURN1:
            print("%d",a);
            break;
        case OP_FORLOOP:
            print("%d %d",a,bx);
            print(COMMENT "to %d",pc-bx+2);
            break;
        case OP_FORPREP:
            print("%d %d",a,bx);
            print(COMMENT "to %d",pc+bx+2);
            break;
        case OP_TFORPREP:
            print("%d %d",a,bx);
            print(COMMENT "to %d",pc+bx+2);
            break;
        case OP_TFORCALL:
            print("%d %d",a,c);
            break;
        case OP_TFORLOOP:
            print("%d %d",a,bx);
            print(COMMENT "to %d",pc-bx+2);
            break;
        case OP_SETLIST:
            print("%d %d %d",a,b,c);
            break;
        case OP_CLOSURE:
            print("%d %d",a,bx);
            // luac.c prints the child Proto's ADDRESS here; that made
            // the generated file differ between runs of the same input
            // (ASLR), defeating content-keyed object caching (issue
            // #33). The child's index carries the same information,
            // deterministically.
            print(COMMENT "proto %d",bx);
            break;
        case OP_VARARG:
            print("%d %d",a,c);
            print(COMMENT);
            if (c==0) print("all out"); else print("%d out",c-1);
            break;
        case OP_VARARGPREP:
            print("%d",a);
            break;
        case OP_EXTRAARG:
            print("%d",ax);
            break;
    }
    print("\n");
}

#include "luaot_gotos.c"

static
void create_functions(Proto *p)
{
    // luaot_footer.c should use the same traversal order as this.
    create_function(p);
    for (int i = 0; i < p->sizep; i++) {
        create_functions(p->p[i]);
    }
}

static
void print_functions(Proto *p)
{
    create_functions(p);

    println("static AotCompiledFunction LUAOT_FUNCTIONS[] = {");
    for (int i = 0; i < nfunctions; i++) {
        println("  magic_implementation_%02d,", i);
    }
    println("  NULL");
    println("};");
}

static int dump_writer(lua_State *L, const void *p, size_t size, void *ud)
{
    (void)L;
    int *col = (int *)ud;
    const unsigned char *b = (const unsigned char *)p;
    for (size_t i = 0; i < size; i++) {
        if (*col == 0) {
            print(" ");
        }
        print(" %3d,", b[i]);
        (*col)++;
        if (*col == 16) {
            print("\n");
            *col = 0;
        }
    }
    return 0;
}

static
void print_source_code(lua_State *L)
{
    // Since the code we are generating is lifted from lvm.c, we need it to use
    // Lua functions instead of C functions. To create them, the module `load`s
    // an embedded copy of the chunk -- and that copy must be the *compiled*
    // chunk (string.dump format), not the source text. The runtime has to
    // execute exactly the Proto this compiler translated, and re-parsing the
    // source on the target does not guarantee that: Lua 5.4.3's integer
    // constant cache keys through size_t, so a 32-bit target (wasm32) lays
    // out constant tables differently from the 64-bit build machine for the
    // same source, shifting every constant index the generated code baked in.
    // Dumped chunks are portable across pointer widths (they fix only the
    // sizes of Instruction, lua_Integer and lua_Number), so the embedded
    // bytecode loads identically everywhere this VM runs.
    //
    // A big C string literal would be more readable, but C compilers have
    // limits on string literal length, so we use a plain char array.

    println("static const char LUAOT_MODULE_SOURCE_CODE[] = {");

    int col = 0;
    if (lua_dump(L, dump_writer, &col, 0) != 0) {
        fatal_error("could not dump the compiled chunk");
    }
    if (col != 0) {
        print("\n");
    }
    println("  0");
    println("};");
}
