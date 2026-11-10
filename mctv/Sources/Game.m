// Logging, the data folder, memory reporting, and the game's launch.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <os/proc.h>
#include <pthread.h>
#include <signal.h>

#include "Game.h"

static void (^gSink)(NSString *, MCLogKind);
static FILE *gLog;

void MCSetLogSink(void (^sink)(NSString *line, MCLogKind kind)) { gSink = [sink copy]; }

NSString *MCDataDir(void) {
    static NSString *dir;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *caches = NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject;
        dir = [caches stringByAppendingPathComponent:@"mctv"];
        [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return dir;
}

static void Emit(MCLogKind kind, NSString *line) {
    static const char *tags[] = {"", "", "[  OK  ] ", "[ WARN ] ", "[FAILED] ", ""};
    NSLog(@"[mctv] %s%@", tags[kind], line);
    if (!gLog) gLog = fopen([MCDataDir() stringByAppendingPathComponent:@"mctv.log"].fileSystemRepresentation, "w");
    if (gLog) {
        fprintf(gLog, "%s%s\n", tags[kind], line.UTF8String);
        fflush(gLog);
    }
    if (gSink && kind != MCLogQuiet) gSink(line, kind);
}

void MCLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    MCLogKind kind = MCLogPlain;
    if ([line hasPrefix:@"ERROR: "]) {
        line = [line substringFromIndex:7];
        kind = MCLogFail;
    } else if ([line hasPrefix:@"input"] || [line hasPrefix:@"  #"]) {
        kind = MCLogDim;
    } else if ([line.lowercaseString containsString:@" failed"]) {
        kind = MCLogWarn;
    }
    Emit(kind, line);
}

void MCStatus(MCLogKind kind, NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    Emit(kind, line);
}

#pragma mark - Memory

// The memory jetsam counts against the app (phys_footprint, GPU memory
// included) goes to mctv.log when it moves by 32 MB, or once a minute. A jetsam
// kill leaves no crash report, so this log is the only record of what grew.
// GPU memory (the kernel's graphics ledger) and the C heap are split out so a
// spike shows which kind it is. The Java heap is neither.
static uint64_t FootprintMB(uint64_t *graphicsMB) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS) return 0;
    *graphicsMB = count >= TASK_VM_INFO_REV6_COUNT ? info.ledger_tag_graphics_footprint >> 20 : 0;
    return info.phys_footprint >> 20;
}

// The largest VM tags (IOSurface, IOAccelerator, malloc and so on) by dirty
// plus compressed size, as the footprint counts them. GPU-private memory isn't
// mapped, so it doesn't show here.
static NSString *RegionsByTag(void) {
    static uint64_t bytes[256];
    memset(bytes, 0, sizeof(bytes));
    vm_address_t address = 0;
    natural_t depth = 0;
    for (;;) {
        vm_size_t size = 0;
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t count = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (vm_region_recurse_64(mach_task_self(), &address, &size, &depth, (vm_region_recurse_info_t)&info, &count) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        bytes[info.user_tag & 255] += (uint64_t)(info.pages_dirtied + info.pages_swapped_out) * vm_page_size;
        address += size;
    }
    NSMutableString *out = [NSMutableString string];
    for (int n = 0; n < 5; n++) {
        int best = -1;
        for (int t = 0; t < 256; t++) if (bytes[t] && (best < 0 || bytes[t] > bytes[best])) best = t;
        if (best < 0 || bytes[best] < (16 << 20)) break;
        [out appendFormat:@"%s tag %d %llu MB", out.length ? "," : "", best, bytes[best] >> 20];
        bytes[best] = 0;
    }
    return out;
}

static void WatchMemory(void) {
    static dispatch_source_t timer;
    static uint64_t last, peak;
    static CFAbsoluteTime lastAt;
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / 2, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{
        uint64_t gpu = 0, mb = FootprintMB(&gpu);
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (mb > peak) peak = mb;
        if ((mb > last ? mb - last : last - mb) < 32 && now - lastAt < 60) return;
        last = mb;
        lastAt = now;
        size_t left = os_proc_available_memory() >> 20;
        malloc_statistics_t heap;
        malloc_zone_statistics(NULL, &heap);
        NSString *split = [NSString stringWithFormat:@"GPU %llu, malloc %zu", gpu, heap.size_in_use >> 20];
        // A breakdown of GPU memory from the patched MoltenVK (scripts/build-moltenvk.sh).
        static int (*metalStats)(char *, int);
        if (!metalStats) metalStats = (int (*)(char *, int))dlsym(RTLD_DEFAULT, "mctv_mvk_stats");
        char metal[160];
        if (metalStats && metalStats(metal, sizeof(metal)) > 0) split = [split stringByAppendingFormat:@"; %s", metal];
        split = [split stringByAppendingFormat:@"; regions:%@", RegionsByTag()];
        if (left) MCStatus(MCLogQuiet, @"memory: %llu MB in use (peak %llu; %@), %zu MB left before tvOS's limit", mb, peak, split, left);
        else MCStatus(MCLogQuiet, @"memory: %llu MB in use (peak %llu; %@)", mb, peak, split);
    });
    dispatch_resume(timer);
}

#pragma mark - launch

// The game's stdout and stderr go to java.log. Both must append, or each writes
// at its own offset and overwrites the other.
static void RedirectJavaLog(NSString *dataDir) {
    NSString *javaLog = [dataDir stringByAppendingPathComponent:@"java.log"];
    fclose(fopen(javaLog.fileSystemRepresentation, "w"));
    freopen(javaLog.fileSystemRepresentation, "a", stdout);
    freopen(javaLog.fileSystemRepresentation, "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);
}

// The game, compiled ahead of time by GraalVM Native Image (aot/aot.py).
int run_main(int argc, char **argv);

static int gArgc, gResult;
static char **gArgv;

static void *RunGame(void *unused) {
    gResult = run_main(gArgc, gArgv);
    return NULL;
}

int MCLaunchGame(NSArray<NSString *> *options, NSArray<NSString *> *gameArgs) {
    NSString *dataDir = MCDataDir();
    NSMutableArray<NSString *> *argv = [NSMutableArray arrayWithObject:NSBundle.mainBundle.executablePath];
    [argv addObjectsFromArray:options];
    [argv addObjectsFromArray:gameArgs];
    NSMutableArray *shown = [argv mutableCopy];
    NSUInteger token = [shown indexOfObject:@"--accessToken"];
    if (token != NSNotFound && token + 1 < shown.count) shown[token + 1] = @"(hidden)";
    MCStatus(MCLogQuiet, @"run_main: %@", [shown componentsJoinedByString:@" "]);
    WatchMemory();
    MCLog(@"Starting Minecraft");
    RedirectJavaLog(dataDir);
    signal(SIGPIPE, SIG_IGN);

    gArgc = (int)argv.count;
    gArgv = calloc(gArgc + 1, sizeof(char *));
    for (int i = 0; i < gArgc; i++) gArgv[i] = strdup(argv[i].UTF8String);
    // Minecraft renders on its main thread, which needs more stack than a default thread's.
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 16 << 20);
    pthread_t thread;
    if (pthread_create(&thread, &attr, RunGame, NULL) != 0) return 1;
    pthread_join(thread, NULL);
    return gResult;
}
