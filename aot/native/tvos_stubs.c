// Linked into libmctvgame.dylib for the Apple TV only (aot.py, game_library).
//
// GraalVM's libchelper flushes the instruction cache after installing code at
// run time. A native image never does that, and tvOS never lets an app make
// code, so the Apple TV's compiler runtime has no __clear_cache. The simulator's
// and macOS's do. This one says so if anything ever calls it.
#include <stdio.h>
#include <stdlib.h>

void __clear_cache(void *begin, void *end) {
    (void) begin;
    (void) end;
    fputs("[mctv] __clear_cache called: something tried to install code at run time\n", stderr);
    abort();
}
