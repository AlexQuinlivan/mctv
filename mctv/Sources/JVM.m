// JVM launch for tvOS, after Amethyst-iOS Natives/JavaLauncher.m.
//
// On TXM devices (A15 Apple TV 4K and later, tvOS 26+) JIT needs a debugger.
//   1. A debugger attaches. Either jitd (server/jitd) does it when the app asks
//      over HTTP (MCTVJITServer in Info.plist, or -jitserver URL), or
//      tools/jit26.py does it after scripts/mc-device.sh launches the app stopped.
//   2. A brk #0x69 probe answered with 0x690000E0 confirms the universal protocol.
//   3. The app sends "script" (Amethyst's extension semantics) and asks the
//      debugger to detach after the first request.
//   4. libjvm (-XX:+MirrorMappedCodeCache) asks for its code cache with brk #0x69.
//      The debugger prepares every page, returns the address and detaches.
//   5. The JVM then runs with JIT and no debugger.

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#include <dirent.h>
#include <dlfcn.h>
#include <mach/mach.h>
#include <os/proc.h>
#include <malloc/malloc.h>
#include <signal.h>
#include <sys/sysctl.h>
#include <unistd.h>

#include "JVM.h"
#include "jit26_calls.h"

typedef unsigned char jboolean;
typedef int jint;
typedef int JLI_Launch_func(int argc, const char **argv, int jargc, const char **jargv, int appclassc,
                            const char **appclassv, const char *fullversion, const char *dotversion,
                            const char *pname, const char *lname, jboolean javaargs, jboolean cpwildcard,
                            jboolean javaw, jint ergo);

static void (^gSink)(NSString *, MCLogKind);
static FILE *gLog;

// On Darwin, JLI starts Java by calling the process's main() again on a new
// thread (dlsym "main"). main.m checks this and re-enters JLI_Launch.
JLI_Launch_func *gJLI_Launch;

int MCMainReentry(int argc, char *argv[]) {
    return gJLI_Launch(argc, (const char **)argv, 0, NULL, 0, NULL, "1.8.0-internal", "1.8", "java", "openjdk", 0, 1, 0, 1);
}

BOOL MCIsJLIReentry(void) { return gJLI_Launch != NULL; }

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
    } else if ([line hasPrefix:@"input"] || [line hasPrefix:@"bridge:"] || [line hasPrefix:@"  #"]) {
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

#pragma mark - TXM

static BOOL gHasTXM;

__attribute__((visibility("default"), used)) BOOL DeviceHasTXM(void) { return gHasTXM; }

static BOOL DetectTXM(void) {
    const char *override = getenv("MCTV_TXM");
    if (override) return atoi(override) != 0;
#if TARGET_OS_SIMULATOR
    return NO;
#else
    DIR *d = opendir("/private/preboot");
    if (d) {
        char path[PATH_MAX] = {0};
        struct dirent *e;
        while ((e = readdir(d))) {
            if (strlen(e->d_name) == 96) {
                snprintf(path, sizeof(path),
                         "/private/preboot/%s/usr/standalone/firmware/FUD/Ap,TrustedExecutionMonitor.img4", e->d_name);
                break;
            }
        }
        closedir(d);
        if (path[0]) return access(path, F_OK) == 0;
    }
    int64_t (*MGGetSInt64Answer)(CFStringRef) = dlsym(RTLD_DEFAULT, "MGGetSInt64Answer");
    int64_t chip = MGGetSInt64Answer ? MGGetSInt64Answer(CFSTR("ChipID")) : 0;
    switch (chip) {
        case 0x8011:  // A10X (Apple TV 4K 1st gen)
        case 0x8020:  // A12 (2nd gen)
            return NO;
        default:      // A15 (3rd gen) and newer
            return YES;
    }
#endif
}

static BOOL IsTraced(void) {
    struct kinfo_proc info = {0};
    size_t size = sizeof(info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) return NO;
    return (info.kp_proc.p_flag & P_TRACED) != 0;
}

// jitd's address or token. A launch argument (-jitserver, -jittoken) wins over Info.plist.
static NSString *JITSetting(NSString *arg, NSString *plistKey) {
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    NSUInteger i = [args indexOfObject:arg];
    if (i != NSNotFound && i + 1 < args.count) return args[i + 1];
    NSString *value = [NSBundle.mainBundle objectForInfoDictionaryKey:plistKey];
    return [value isKindOfClass:NSString.class] && value.length && ![value hasPrefix:@"$("] ? value : nil;
}

// Asks jitd to attach. It answers once it's attached and the app is running
// again, so the handshake below can start straight away.
static BOOL RequestJIT(NSString *server, NSString *token) {
    NSURL *url = [[NSURL URLWithString:server] URLByAppendingPathComponent:@"jit"];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url
                                                       cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                   timeoutInterval:120];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    req.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"pid": @(getpid()), @"token": token ?: @""}
                                                   options:0 error:nil];
    __block NSInteger status = 0;
    __block NSString *message = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    CFAbsoluteTime start = CFAbsoluteTimeGetCurrent();
    [[NSURLSession.sharedSession dataTaskWithRequest:req
                                   completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        status = [resp isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        message = [json isKindOfClass:NSDictionary.class] ? json[@"message"] : err.localizedDescription;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    double secs = CFAbsoluteTimeGetCurrent() - start;
    if (status == 200) MCStatus(MCLogOK, @"JIT from %@ in %.1f s", url.host, secs);
    else MCStatus(MCLogFail, @"JIT server %@: %@", url.host, message.length ? message : [NSString stringWithFormat:@"HTTP %ld", (long)status]);
    return status == 200;
}

// Returns NO if JIT can't work (the JVM would die on its first generated code).
static BOOL PrepareJIT(void) {
    gHasTXM = DetectTXM();
    MCLog(@"TXM: %@", gHasTXM ? @"yes (JIT26 handshake needed)" : @"no");
    if (!gHasTXM) return YES;

    NSString *server = JITSetting(@"-jitserver", @"MCTVJITServer");
    if (!IsTraced() && server) {
        MCLog(@"Asking %@ for JIT", [NSURL URLWithString:server].host ?: server);
        if (!RequestJIT(server, JITSetting(@"-jittoken", @"MCTVJITToken"))) {
            MCLog(@"ERROR: no JIT, so Java can't start. Is the JIT server up, and jitd paired with this TV? (server/README.md)");
            return NO;
        }
    }
    for (int i = 0; i < 100 && !IsTraced(); i++) usleep(100000);
    if (!IsTraced()) {
        MCLog(@"ERROR: no debugger attached. On this device the JVM needs JIT at launch:"
              @" set up jitd (server/README.md) or run scripts/mc-device.sh on your build Mac.");
        return NO;
    }
    void *magic = JIT26CreateRegionLegacy(vm_page_size);
    if ((uintptr_t)magic != JIT26_LEGACY_UNIVERSAL_MAGIC) {
        MCLog(@"ERROR: debugger answered the legacy probe with %p, so it isn't running jit26.py or a universal script", magic);
        return NO;
    }
    const char *ext = "// mctv: Amethyst UniversalJIT26Extension semantics";
    BreakSendJITScript(ext, strlen(ext));
    JIT26SetDetachAfterFirstBr(getenv("MCTV_JIT_STAY_ATTACHED") ? 0 : 1);
    // Keep HotSpot's SIGSEGV/SIGBUS handling away from the debugger, as Amethyst does.
    // The tvOS SDK marks this MIG call unavailable, so look it up at runtime.
    kern_return_t (*set_ports)(task_t, exception_mask_t, mach_port_t, exception_behavior_t, thread_state_flavor_t) =
        dlsym(RTLD_DEFAULT, "task_set_exception_ports");
    if (set_ports) {
        kern_return_t kr = set_ports(mach_task_self(), EXC_MASK_BAD_ACCESS, MACH_PORT_NULL, EXCEPTION_DEFAULT,
                                     MACHINE_THREAD_STATE);
        if (kr != KERN_SUCCESS) MCLog(@"task_set_exception_ports: %d", kr);
    } else {
        MCLog(@"task_set_exception_ports not found, so JVM faults round-trip through the debugger until it detaches");
    }
    MCStatus(MCLogOK, @"JIT handshake done");
    return YES;
}

#pragma mark - launch

int MCLaunchJVM(NSArray<NSString *> *jvmArgs, NSString *mainClass, NSArray<NSString *> *appArgs) {
    NSString *javaHome = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"java/java-25"];
    NSString *dataDir = MCDataDir();
    NSString *home = [dataDir stringByAppendingPathComponent:@"home"];
    [NSFileManager.defaultManager createDirectoryAtPath:home withIntermediateDirectories:YES attributes:nil error:nil];

    if (!PrepareJIT()) return 1;

    setenv("JAVA_HOME", javaHome.fileSystemRepresentation, 1);
    // Leave HOME alone. UIKit and BackBoard services started later read it.
    setenv("LD_LIBRARY_PATH", "", 1);
    setenv("HACK_IGNORE_START_ON_FIRST_THREAD", "1", 1);  // run Java main on its own thread

    NSString *libjliPath = [javaHome stringByAppendingPathComponent:@"lib/libjli.dylib"];
    void *libjli = dlopen(libjliPath.fileSystemRepresentation, RTLD_GLOBAL);
    if (!libjli) {
        MCLog(@"ERROR: dlopen libjli: %s", dlerror());
        return 1;
    }
    JLI_Launch_func *JLI_Launch = dlsym(libjli, "JLI_Launch");
    if (!JLI_Launch) {
        MCLog(@"ERROR: JLI_Launch not found");
        return 1;
    }

    NSMutableArray<NSString *> *argv = [NSMutableArray new];
    [argv addObject:[javaHome stringByAppendingPathComponent:@"bin/java"]];
    [argv addObjectsFromArray:@[
        @"-XX:+UnlockExperimentalVMOptions",
        @"-XX:+DisablePrimordialThreadGuardPages",  // avoids random stack guard crashes (Amethyst)
        @"-XX:+MirrorMappedCodeCache",              // RW/RX mirrored code cache for JIT26 (Amethyst's JDK)
        @"-XX:-UseCompressedClassPointers",          // Java 25 needs this without extended VA (Amethyst)
        [NSString stringWithFormat:@"-Duser.home=%@", home],
        [NSString stringWithFormat:@"-Djava.io.tmpdir=%@", NSTemporaryDirectory()],
        [NSString stringWithFormat:@"-Djava.library.path=%@/Frameworks", NSBundle.mainBundle.bundlePath],
    ]];
    [argv addObjectsFromArray:jvmArgs];
    [argv addObject:mainClass];
    [argv addObjectsFromArray:appArgs];
    MCStatus(MCLogQuiet, @"JLI_Launch: %@", [argv componentsJoinedByString:@" "]);
    WatchMemory();
    MCLog(@"Starting Java 25: %@", mainClass);

    // Java's stdout and stderr go to java.log. Both must append, or each writes
    // at its own offset and overwrites the other.
    NSString *javaLog = [dataDir stringByAppendingPathComponent:@"java.log"];
    fclose(fopen(javaLog.fileSystemRepresentation, "w"));
    freopen(javaLog.fileSystemRepresentation, "a", stdout);
    freopen(javaLog.fileSystemRepresentation, "a", stderr);
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    // Let the JVM install its own handlers.
    signal(SIGSEGV, SIG_DFL);
    signal(SIGBUS, SIG_DFL);
    signal(SIGILL, SIG_DFL);
    signal(SIGFPE, SIG_DFL);
    signal(SIGPIPE, SIG_IGN);

    int argc = (int)argv.count;
    const char **cargv = calloc(argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) cargv[i] = strdup(argv[i].UTF8String);
    gJLI_Launch = JLI_Launch;
    return JLI_Launch(argc, cargv, 0, NULL, 0, NULL, "1.8.0-internal", "1.8", "java", "openjdk", 0, 1, 0, 1);
}
