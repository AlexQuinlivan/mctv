// App side of the JIT26 debugger protocol, the same calls Amethyst makes
// (Natives/utils.m). tools/jit26.py serves them from lldb on your build Mac.
//
// Each call stops at a brk. The debugger services it, puts any return value
// in x0 and moves pc past the brk. A brk with no debugger attached crashes
// the process, so callers must check that one is attached first.

#include "jit26_calls.h"

// Universal protocol. brk #0xf00d with the command number in x16.
__attribute__((noinline, optnone, naked))
void JIT26Detach(void) {
    __asm__("mov x16, #0 \n"
            "brk #0xf00d \n"
            "ret");
}

__attribute__((noinline, optnone, naked))
void *JIT26PrepareRegion(void *addr, size_t len) {
    __asm__("mov x16, #1 \n"
            "brk #0xf00d \n"
            "ret");
}

__attribute__((noinline, optnone, naked))
void BreakSendJITScript(const char *script, size_t len) {
    __asm__("mov x16, #2 \n"
            "brk #0xf00d \n"
            "ret");
}

// Amethyst extension commands (UniversalJIT26Extension.js)
__attribute__((noinline, optnone, naked))
void JIT26SetDetachAfterFirstBr(long value) {
    __asm__("mov x16, #3 \n"
            "brk #0xf00d \n"
            "ret");
}

__attribute__((noinline, optnone, naked))
void JIT26PrepareRegionForPatching(void *addr, size_t size) {
    __asm__("mov x16, #4 \n"
            "brk #0xf00d \n"
            "ret");
}

// Legacy brk #0x69. With only the universal script it returns 0x690000E0.
// Once the Amethyst extension is loaded it allocates a region of len bytes.
// Amethyst's patched libjvm makes this call for its code cache.
__attribute__((noinline, optnone, naked))
void *JIT26CreateRegionLegacy(size_t len) {
    __asm__("brk #0x69 \n"
            "ret");
}
