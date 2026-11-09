#pragma once
#import <Foundation/Foundation.h>

// How a line shows on the boot screen (MCBootScreen).
typedef NS_ENUM(NSInteger, MCLogKind) {
    MCLogPlain,  // [    3.141593] text
    MCLogDim,    // the same, greyed
    MCLogOK,     // [  OK  ] text
    MCLogWarn,   // [ WARN ] text
    MCLogFail,   // [FAILED] text
    MCLogQuiet,  // log file only
};

// Appends a line to Library/Caches/mctv/mctv.log, NSLog and the boot screen.
// MCLog picks the kind from the text ("ERROR: " fails, "input" and "bridge:"
// are dim). MCStatus takes it as an argument.
void MCLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void MCStatus(MCLogKind kind, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
void MCSetLogSink(void (^sink)(NSString *line, MCLogKind kind));

// Library/Caches/mctv, for logs and game data. tvOS may purge it.
NSString *MCDataDir(void);

// Starts HotSpot through JLI_Launch on the calling thread. JLI calls exit()
// when Java's main returns, so this normally doesn't return.
// Java's stdout/stderr go to MCDataDir()/java.log.
int MCLaunchJVM(NSArray<NSString *> *jvmArgs, NSString *mainClass, NSArray<NSString *> *appArgs);

// JLI calls main() again on a new thread to run Java. main() must hand that
// call straight back to JLI instead of starting UIKit a second time.
BOOL MCIsJLIReentry(void);
int MCMainReentry(int argc, char *argv[]);

// Exported for Amethyst's libjvm, which looks it up with dlsym.
BOOL DeviceHasTXM(void);
