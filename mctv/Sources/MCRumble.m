#import "MCRumble.h"
#import <CoreHaptics/CoreHaptics.h>
#import <QuartzCore/QuartzCore.h>
#import "JVM.h"
#include "bridge/bridge.h"
#include <stdatomic.h>

// Controlify sends two levels, as SDL's rumble does. Strong is for the
// low-frequency motor (left grip on Xbox controllers) and weak for the
// high-frequency one (right grip). Each motor is a Core Haptics engine on that
// part of the controller, playing one long continuous event whose strength
// follows the level. A level lasts until the next one or for 5 s, as with
// SDL_RumbleGamepad, so a stalled game can't leave it buzzing.

static const double kHold = 5.0;      // seconds a level lasts without a new one
static const double kEventLength = 30.0;
static dispatch_queue_t gQueue;
static dispatch_source_t gHoldTimer;
static GCController *gPad;
static NSArray *gMotors;              // [strong, weak] MCMotors, or one for both
static atomic_bool gSupported;
static BOOL gLoggedFirst;

@interface MCMotor : NSObject
- (instancetype)initWithHaptics:(GCDeviceHaptics *)haptics locality:(GCHapticsLocality)locality;
- (void)setLevel:(float)level;
- (void)shutDown;
@end

@implementation MCMotor {
    GCDeviceHaptics *_haptics;
    GCHapticsLocality _locality;
    CHHapticEngine *_engine;
    id<CHHapticPatternPlayer> _player;
    float _level;                     // what the motor plays now
    float _base;                      // the playing event's own intensity
    CFTimeInterval _startedAt, _retryAt;
    BOOL _noLiveChange;               // sendParameters failed once, so restart at each new level
    int _errors;
}

- (instancetype)initWithHaptics:(GCDeviceHaptics *)haptics locality:(GCHapticsLocality)locality {
    if ((self = [super init])) {
        _haptics = haptics;
        _locality = locality;
    }
    return self;
}

- (void)fail:(NSString *)what error:(NSError *)err {
    if (++_errors <= 4) {
        MCLog(@"rumble: %@ on %@ failed: %@ (%@ %ld)%@", what, _locality, err.localizedDescription, err.domain, (long)err.code,
              _errors == 4 ? @". Quiet about it from now on" : @"");
    }
    [_engine stopWithCompletionHandler:nil];
    _engine = nil;
    _player = nil;
    _level = 0;
    _retryAt = CACurrentMediaTime() + 2;
}

- (BOOL)makeEngine {
    if (_engine) return YES;
    if (CACurrentMediaTime() < _retryAt) return NO;
    _engine = [_haptics createEngineWithLocality:_locality];
    if (!_engine) {
        [self fail:@"making the engine" error:[NSError errorWithDomain:CoreHapticsErrorDomain code:CHHapticErrorCodeNotSupported userInfo:nil]];
        return NO;
    }
    __weak MCMotor *weakSelf = self;
    __weak CHHapticEngine *thisEngine = _engine;  // a late callback mustn't touch a newer engine
    void (^gone)(void) = ^{
        dispatch_async(gQueue, ^{
            MCMotor *m = weakSelf;
            if (m && m->_engine && m->_engine == thisEngine) {
                m->_engine = nil;
                m->_player = nil;
                m->_level = 0;
            }
        });
    };
    _engine.resetHandler = gone;
    _engine.stoppedHandler = ^(CHHapticEngineStoppedReason reason) { gone(); };
    NSError *err = nil;
    if (![_engine startAndReturnError:&err]) {
        [self fail:@"starting the engine" error:err];
        return NO;
    }
    return YES;
}

// A fresh player at `level`, replacing any playing one.
- (BOOL)playAt:(float)level {
    NSError *err = nil;
    if (_player) [_player stopAtTime:CHHapticTimeImmediate error:nil];
    _player = nil;
    if (![self makeEngine]) return NO;
    CHHapticEvent *event = [[CHHapticEvent alloc] initWithEventType:CHHapticEventTypeHapticContinuous parameters:@[
        [[CHHapticEventParameter alloc] initWithParameterID:CHHapticEventParameterIDHapticIntensity value:level],
    ] relativeTime:0 duration:kEventLength];
    CHHapticPattern *pattern = [[CHHapticPattern alloc] initWithEvents:@[event] parameters:@[] error:&err];
    _player = pattern ? [_engine createPlayerWithPattern:pattern error:&err] : nil;
    if (!_player) {
        [self fail:@"making the player" error:err];
        return NO;
    }
    if (![_player startAtTime:CHHapticTimeImmediate error:&err]) {
        [self fail:@"playing" error:err];
        return NO;
    }
    _startedAt = CACurrentMediaTime();
    _level = _base = level;
    _errors = 0;
    return YES;
}

- (void)setLevel:(float)level {
    NSError *err = nil;
    if (level < 0.01f) {
        if (_player) [_player stopAtTime:CHHapticTimeImmediate error:nil];
        _player = nil;
        _level = 0;
        return;
    }
    BOOL expiring = _player && CACurrentMediaTime() - _startedAt > kEventLength - 5;
    if (!_player || expiring) {
        [self playAt:level];
        return;
    }
    if (fabsf(level - _level) < 0.03f) return;
    if (_noLiveChange || level > _base) {
        [self playAt:level];  // louder than the playing event, so start over at the new level
        return;
    }
    // Intensity control scales the playing event's own intensity.
    CHHapticDynamicParameter *p = [[CHHapticDynamicParameter alloc]
        initWithParameterID:CHHapticDynamicParameterIDHapticIntensityControl value:level / _base relativeTime:0];
    if (![_player sendParameters:@[p] atTime:CHHapticTimeImmediate error:&err]) {
        MCLog(@"rumble: live strength changes don't work on %@ (%@ %ld), restarting at each level instead",
              _locality, err.domain, (long)err.code);
        _noLiveChange = YES;
        [self playAt:level];
        return;
    }
    _level = level;
}

- (void)shutDown {
    [self setLevel:0];
    [_engine stopWithCompletionHandler:nil];
    _engine = nil;
}

@end

static void Apply(float strong, float weak) {
    if (gMotors.count == 2) {
        [gMotors[0] setLevel:strong];
        [gMotors[1] setLevel:weak];
    } else if (gMotors.count == 1) {
        [gMotors[0] setLevel:fmaxf(strong, weak)];
    }
}

static void Setup(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gQueue = dispatch_queue_create("mctv.rumble", DISPATCH_QUEUE_SERIAL);
        gHoldTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gQueue);
        dispatch_source_set_event_handler(gHoldTimer, ^{ Apply(0, 0); });
        dispatch_source_set_timer(gHoldTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
        dispatch_resume(gHoldTimer);
    });
}

static void Hold(void) {
    dispatch_source_set_timer(gHoldTimer, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kHold * NSEC_PER_SEC)),
                              DISPATCH_TIME_FOREVER, 100 * NSEC_PER_MSEC);
}

void MCRumbleUseController(GCController *pad) {
    Setup();
    atomic_store(&gSupported, pad.haptics != nil);
    dispatch_async(gQueue, ^{
        if (pad == gPad) return;
        for (MCMotor *m in gMotors) [m shutDown];
        gMotors = nil;
        gPad = pad;
        gLoggedFirst = NO;
        GCDeviceHaptics *haptics = pad.haptics;
        if (!haptics) {
            if (pad) MCLog(@"rumble: \"%@\" has no haptics", pad.vendorName);
            return;
        }
        NSSet *where = haptics.supportedLocalities;
        if ([where containsObject:GCHapticsLocalityLeftHandle] && [where containsObject:GCHapticsLocalityRightHandle]) {
            gMotors = @[[[MCMotor alloc] initWithHaptics:haptics locality:GCHapticsLocalityLeftHandle],
                        [[MCMotor alloc] initWithHaptics:haptics locality:GCHapticsLocalityRightHandle]];
        } else {
            GCHapticsLocality both = [where containsObject:GCHapticsLocalityHandles] ? GCHapticsLocalityHandles : GCHapticsLocalityDefault;
            gMotors = @[[[MCMotor alloc] initWithHaptics:haptics locality:both]];
        }
        MCLog(@"rumble: \"%@\" ready, %lu motor%s", pad.vendorName, (unsigned long)gMotors.count, gMotors.count == 1 ? "" : "s");
    });
}

bool MCRumbleSupported(void) {
    return atomic_load(&gSupported);
}

void MCRumbleSet(float strong, float weak) {
    Setup();
    strong = fminf(fmaxf(strong, 0), 1);
    weak = fminf(fmaxf(weak, 0), 1);
    dispatch_async(gQueue, ^{
        if (!gLoggedFirst && (strong > 0 || weak > 0)) {
            gLoggedFirst = YES;
            MCLog(@"rumble: first effect from the game (strong %.2f, weak %.2f)", strong, weak);
        }
        Apply(strong, weak);
        Hold();
    });
}
