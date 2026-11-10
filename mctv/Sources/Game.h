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
// MCLog picks the kind from the text ("ERROR: " fails, "input" is dim).
// MCStatus takes it as an argument.
void MCLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
void MCStatus(MCLogKind kind, NSString *fmt, ...) NS_FORMAT_FUNCTION(2, 3);
void MCSetLogSink(void (^sink)(NSString *line, MCLogKind kind));

// Library/Caches/mctv, for logs and game data. tvOS may purge it.
NSString *MCDataDir(void);

// Runs the game (aot/, linked in as libmctvgame.dylib) on a thread of its own
// and waits for it. options are its -X and -D options, gameArgs Minecraft's
// own arguments. Its output goes to MCDataDir()/java.log.
int MCLaunchGame(NSArray<NSString *> *options, NSArray<NSString *> *gameArgs);
