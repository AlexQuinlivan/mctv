// The tvOS host app. It boots the Minecraft version pushed from your build Mac into
// Library/Caches/mctv/minecraft through Amethyst's launcher.jar, and the game
// renders into a full-screen CAMetalLayer.
//
// Launch arguments:
//   -mc VERSION       Minecraft version (default: minecraft/mctv-version.txt)
//   -xmx MB           Java heap (default 1024, or 768 for 26.x)
//   -renderer R       mobileglues (default, GLES 3 via MobileGlues) or angle
//                     (ANGLE's desktop GL)
//   -graphics API     vulkan or opengl, Minecraft's renderer on 26.x
//   -option KEY:VALUE set any other options.txt value on 26.x
//   -showlog          keep the boot screen up after the first frame
//   -inputtest SCRIPT scripted controller test (see MCInput.m), or "default"
//   -jvmarg ARG       extra JVM argument (repeatable)

#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import "JVM.h"
#import "MCAccount.h"
#import "MCBootScreen.h"
#import "MCInput.h"
#import "MCSignInView.h"
#include "bridge/bridge.h"

@interface MCGameView : UIView
@end

@implementation MCGameView
+ (Class)layerClass { return CAMetalLayer.class; }
@end

// The menu pointer, a white arrow with a dark outline. The view's origin is the tip.
static UIView *MakePointer(void) {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 22, 32)];
    v.userInteractionEnabled = NO;
    v.hidden = YES;
    UIBezierPath *p = [UIBezierPath bezierPath];
    [p moveToPoint:CGPointMake(1, 1)];
    [p addLineToPoint:CGPointMake(1, 27)];
    [p addLineToPoint:CGPointMake(8, 20)];
    [p addLineToPoint:CGPointMake(13, 31)];
    [p addLineToPoint:CGPointMake(17, 29)];
    [p addLineToPoint:CGPointMake(12, 18)];
    [p addLineToPoint:CGPointMake(21, 18)];
    [p closePath];
    CAShapeLayer *s = [CAShapeLayer layer];
    s.path = p.CGPath;
    s.fillColor = UIColor.whiteColor.CGColor;
    s.strokeColor = [UIColor colorWithWhite:0.1 alpha:1].CGColor;
    s.lineWidth = 2;
    [v.layer addSublayer:s];
    return v;
}

// GCEventViewController with controllerUserInteractionEnabled = NO keeps
// controller presses (and the Siri Remote's Menu button) away from UIKit, so
// B/Menu don't leave the app.
@interface MCRootViewController : GCEventViewController
@end

static __weak MCRootViewController *gRoot;
static void hideLogOnFirstFrame(void);
// The signed-in Microsoft account's player name.
static NSString *gSignedInUser;

@implementation MCRootViewController {
    MCGameView *_game;
    UIView *_pointer;
    MCInput *_input;
    MCBootScreen *_boot;
    NSTimer *_tail;
    unsigned long long _javaLogOffset;
    BOOL _javaLogPrimed;
    BOOL _started;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    gRoot = self;
    self.controllerUserInteractionEnabled = NO;
    self.view.backgroundColor = UIColor.blackColor;

    _game = [[MCGameView alloc] initWithFrame:self.view.bounds];
    _game.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _game.layer.opaque = YES;
    // One pixel per point, so 1920x1080 even on a 4K TV.
    _game.layer.contentsScale = 1.0;
    [self.view addSubview:_game];
    _pointer = MakePointer();
    [self.view addSubview:_pointer];

    _boot = [[MCBootScreen alloc] initWithFrame:self.view.bounds];
    _boot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:_boot];

    __weak typeof(self) weakSelf = self;
    MCSetLogSink(^(NSString *line, MCLogKind kind) {
        dispatch_async(dispatch_get_main_queue(), ^{
            MCRootViewController *me = weakSelf;
            if (me) [me->_boot addLine:line kind:kind];
        });
    });
    [self tailJavaLog];  // note where the previous run's log ends, before Java truncates it
    _tail = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *t) { [weakSelf tailJavaLog]; }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (_started) return;
    _started = YES;
    NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
    __weak typeof(self) weakSelf = self;
    [self signInThen:^{ [weakSelf startGame:args]; }];
}

// A saved login is renewed when it's close to running out. Without one, or
// when it can't be renewed, the sign-in screen comes up.
- (void)signInThen:(void (^)(void))go {
    NSString *name = MCAccount.signedInName;
    if (!name) {
        [self showSignIn:go problem:nil];
        return;
    }
    __weak typeof(self) weakSelf = self;
    [MCAccount refreshIfNeeded:^(BOOL usable, NSString *note) {
        if (note) MCLog(@"%@", note);
        if (usable) {
            gSignedInUser = name;
            MCStatus(MCLogOK, @"Signed in as %@", name);
            go();
        } else {
            [weakSelf showSignIn:go problem:@"Your saved sign-in has run out. Please sign in again."];
        }
    }];
}

- (void)showSignIn:(void (^)(void))go problem:(NSString *)problem {
    MCSignInView *view = [[MCSignInView alloc] initWithFrame:self.view.bounds];
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view showProblem:problem];
    [self.view addSubview:view];
    MCLog(@"Sign-in: waiting for a Microsoft sign-in");
    __weak typeof(self) weakSelf = self;
    [MCAccount signInShowing:^(NSString *code, NSURL *url) {
        MCLog(@"Sign-in: enter %@ at microsoft.com/link", code);
        [view showCode:code url:url];
    } done:^(NSString *name, NSString *error) {
        if (name) {
            [view removeFromSuperview];
            gSignedInUser = name;
            MCStatus(MCLogOK, @"Signed in as %@", name);
            go();
            return;
        }
        MCStatus(MCLogWarn, @"Sign-in: %@", error);
        [view showProblem:[error stringByAppendingString:@" Trying again in a moment."]];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            [view removeFromSuperview];
            [weakSelf showSignIn:go problem:error];
        });
    }];
}

- (void)startGame:(NSArray<NSString *> *)args {
    // Window size must be known before Java starts (GLFW reads it at class init).
    CGSize px = CGSizeMake(_game.bounds.size.width * _game.layer.contentsScale,
                           _game.bounds.size.height * _game.layer.contentsScale);
    windowWidth = (int)px.width & ~1;
    windowHeight = (int)px.height & ~1;
    MCGameLayer = (__bridge void *)_game.layer;
    if (![args containsObject:@"-showlog"]) MCOnFirstFrame = hideLogOnFirstFrame;
    _input = [[MCInput alloc] initWithPointer:_pointer scale:_game.layer.contentsScale];
    [_input start];
    NSString *inputTest = [MCRootViewController argValue:@"-inputtest" in:args];
    if (inputTest) [_input runTestScript:inputTest];
    int w = windowWidth, h = windowHeight;
    int fps = (int)self.view.window.windowScene.screen.maximumFramesPerSecond ?: 60;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        [MCRootViewController runMinecraft:args width:w height:h fps:fps];
    });
}

// Keyboards and the Siri Remote, when they reach UIKit as well as or instead of
// the Game Controller framework. Presses MCInput takes are not passed on, so
// Esc and Back never leave the app.
- (void)forwardPresses:(NSSet<UIPress *> *)presses down:(BOOL)down event:(UIPressesEvent *)event {
    NSMutableSet<UIPress *> *rest = [NSMutableSet set];
    for (UIPress *p in presses)
        if (!_input || ![_input handlePress:p down:down]) [rest addObject:p];
    if (!rest.count) return;
    if (down) [super pressesBegan:rest withEvent:event];
    else [super pressesEnded:rest withEvent:event];
}

- (void)pressesBegan:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self forwardPresses:presses down:YES event:event]; }
- (void)pressesEnded:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self forwardPresses:presses down:NO event:event]; }
- (void)pressesCancelled:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event { [self forwardPresses:presses down:NO event:event]; }
- (void)pressesChanged:(NSSet<UIPress *> *)presses withEvent:(UIPressesEvent *)event {}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *t = touches.anyObject;
    CGPoint a = [t locationInView:self.view], b = [t previousLocationInView:self.view];
    [_input touchMovedBy:CGPointMake(a.x - b.x, a.y - b.y)];
}

static void hideLogOnFirstFrame(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        MCRootViewController *root = gRoot;
        if (root) [root->_boot fadeOut];
    });
}

+ (NSString *)argValue:(NSString *)name in:(NSArray<NSString *> *)args {
    NSUInteger i = [args indexOfObject:name];
    return (i != NSNotFound && i + 1 < args.count) ? args[i + 1] : nil;
}

+ (NSMutableArray<NSString *> *)extraJvmArgs:(NSArray<NSString *> *)args {
    NSMutableArray *out = [NSMutableArray new];
    for (NSUInteger i = 1; i + 1 < args.count; i++)
        if ([args[i] isEqualToString:@"-jvmarg"]) [out addObject:args[++i]];
    return out;
}

+ (void)runMinecraft:(NSArray<NSString *> *)args width:(int)w height:(int)h fps:(int)fps {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *bundle = NSBundle.mainBundle.bundlePath;
    NSString *gameDir = [MCDataDir() stringByAppendingPathComponent:@"minecraft"];
    NSString *home = [MCDataDir() stringByAppendingPathComponent:@"home"];
    NSString *version = [self argValue:@"-mc" in:args]
        ?: [[NSString stringWithContentsOfFile:[gameDir stringByAppendingPathComponent:@"mctv-version.txt"]
                                      encoding:NSUTF8StringEncoding error:nil]
            stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *user = gSignedInUser;
    NSString *libs = [bundle stringByAppendingPathComponent:@"java/libs"];
    // Minecraft 26.x uses LWJGL 3.4.3 with SDL 3 instead of Amethyst's GLFW.
    // An lwjgl-sdl jar in java/libs marks such a build.
    BOOL sdl = NO;
    for (NSString *f in [fm contentsOfDirectoryAtPath:libs error:nil]) if ([f hasPrefix:@"lwjgl-sdl"]) sdl = YES;
    // 26.x uses more GPU memory, which counts against the same limit as the
    // heap. With 1024 MB a world came within 60 MB of it. 768 leaves about 200 MB.
    NSString *xmx = [self argValue:@"-xmx" in:args] ?: (sdl ? @"768" : @"1024");

    NSString *versionJson = [NSString stringWithFormat:@"%@/versions/%@/%@.json", gameDir, version, version];
    if (!version.length || ![fm fileExistsAtPath:versionJson]) {
        MCLog(@"ERROR: no Minecraft here yet (%@). Push one from your build Mac with scripts/mc-device.sh", version ?: @"no version");
        return;
    }
    if (![fm fileExistsAtPath:[NSString stringWithFormat:@"%@/accounts/%@.json", home, user]]) {
        MCLog(@"ERROR: no profile %@ in %@/accounts", user, home);
        return;
    }
    MCLog(@"Minecraft %@ for %@ at %dx%d, %@ MB heap", version, user, w, h, xmx);

    // Read by launcher.jar (Tools) and lwjgl.jar (GLFW).
    setenv("BUNDLE_PATH", bundle.fileSystemRepresentation, 1);
    setenv("AME_HOME", home.fileSystemRepresentation, 1);
    setenv("GAME_DIR", gameDir.fileSystemRepresentation, 1);
    setenv("POJAV_NATIVE_LIB", NSBundle.mainBundle.executablePath.fileSystemRepresentation, 1);
    NSString *renderer = [self argValue:@"-renderer" in:args] ?: @"mobileglues";
    setenv("MCTV_RENDERER", renderer.UTF8String, 1);
    NSString *glLib = @(MCRendererLibrary());
    MCLog(@"Renderer %@ (%@)", renderer, glLib);

    if (sdl) [self prepareSDL:args gameDir:gameDir version:version fps:fps];
    // 26.x loads OpenGL through libmctvgl, which fixes the version MobileGlues
    // reports (mctv/gl/mctv_gl.c).
    if (sdl && [glLib isEqualToString:@"libmobileglues.dylib"]) glLib = @"libmctvgl.dylib";
    NSMutableArray *jvmArgs = [@[
        @"-XstartOnFirstThread",
        @"-Djava.system.class.loader=net.kdt.pojavlaunch.PojavClassLoader",
        @"-Xms128M",
        [NSString stringWithFormat:@"-Xmx%@M", xmx],
        // Kept small because every launch on the TV prepares the whole code cache over the network.
        @"-XX:ReservedCodeCacheSize=64M",
        [NSString stringWithFormat:@"-Duser.dir=%@", gameDir],
        [NSString stringWithFormat:@"-Duser.home=%@", home],
        [NSString stringWithFormat:@"-Duser.timezone=%@", NSTimeZone.localTimeZone.name],
        [NSString stringWithFormat:@"-DUIScreen.maximumFramesPerSecond=%d", fps],
        [NSString stringWithFormat:@"-Dcacio.managed.screensize=%dx%d", w, h],  // -> glfw.windowSize
        @"-Dorg.lwjgl.glfw.checkThread0=false",
        @"-Dorg.lwjgl.system.allocator=system",
        [NSString stringWithFormat:@"-Dorg.lwjgl.opengl.libname=%@", glLib],
        @"-Dlog4j2.formatMsgNoLookups=true",
        @"-Dfml.earlyprogresswindow=false",
        @"-Djava.awt.headless=true",
        @"--enable-native-access=ALL-UNNAMED",          // LWJGL and the launcher load natives
        @"--sun-misc-unsafe-memory-access=allow",       // JOML and friends still use Unsafe
        @"-Dminecraft.launcher.brand=mctv",
        [NSString stringWithFormat:@"-javaagent:%@/patchjna_agent.jar=", libs],
    ] mutableCopy];
    if (sdl) {
        // LWJGL 3.4.3 loads its natives, SDL, shaderc, SPIRV-Cross and MoltenVK from the app's Frameworks.
        [jvmArgs addObject:[NSString stringWithFormat:@"-Dorg.lwjgl.librarypath=%@", NSBundle.mainBundle.privateFrameworksPath]];
        // Mojang's jars carry the SHA-1 of their macOS natives, which the tvOS
        // builds never match, so LWJGL would warn for every library.
        [jvmArgs addObject:@"-Dorg.lwjgl.util.NoHashChecks=true"];
        // Fixes to Minecraft's classes as they load (java/mctv-agent).
        [jvmArgs addObject:[NSString stringWithFormat:@"-javaagent:%@/mctv-agent.jar", libs]];
        // Controlify gets its own SDL, as it would on a desktop (scripts/prepare-26.sh).
        [jvmArgs addObject:[NSString stringWithFormat:@"-Ddev.isxander.sdl.library=%@/libSDL3_controlify.dylib", NSBundle.mainBundle.privateFrameworksPath]];
    }
    [jvmArgs addObjectsFromArray:[self extraJvmArgs:args]];
    [jvmArgs addObjectsFromArray:@[@"-cp", [libs stringByAppendingPathComponent:@"*"]]];
    // Mods write config/ and friends through relative paths, which the OS
    // resolves against the working directory ("/", read-only), not user.dir.
    if (chdir(gameDir.fileSystemRepresentation) != 0) MCLog(@"chdir %@ failed: %s", gameDir, strerror(errno));
    int rc = MCLaunchJVM(jvmArgs, @"net.kdt.pojavlaunch.PojavLauncher", @[user, version]);
    MCLog(@"ERROR: Java stopped (JLI_Launch returned %d); details in java.log", rc);
}

// Minecraft 26.x runs on SDL through MCTV's own SDL video backend
// (mctv/sdl/SDL_mctvvideo.m, sdl_bridge.m).
+ (void)prepareSDL:(NSArray<NSString *> *)args gameDir:(NSString *)gameDir version:(NSString *)version fps:(int)fps {
    MCSDLMode = true;
    MCSDLRefreshRate = fps;
    setenv("SDL_VIDEO_DRIVER", "mctv", 1);           // never UIKit's backend
    setenv("SDL_TV_REMOTE_AS_JOYSTICK", "0", 1);     // MCInput handles the Siri Remote
    // Controlify turns on Steam Controller support, which makes SDL open
    // Bluetooth, and tvOS kills an app that does that without a usage
    // description. The environment overrides SDL_SetHint in both copies of SDL.
    setenv("SDL_JOYSTICK_HIDAPI_STEAM", "0", 1);
    // SDL loads Vulkan by path, so name the app's own MoltenVK (a bare name isn't searched for).
    NSString *vk = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libMoltenVK.dylib"];
    setenv("SDL_VULKAN_LIBRARY", vk.fileSystemRepresentation, 1);
    // MoltenVK's info level lists every Vulkan extension. Warnings stay in java.log.
    setenv("MVK_CONFIG_LOG_LEVEL", "2", 0);
    // Controlify unpacks its desktop SDL into tmp on every launch before it falls
    // back to the app's, and the copies pile up.
    for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:NSTemporaryDirectory() error:nil])
        if ([f hasPrefix:@"controlify-native-"])
            [NSFileManager.defaultManager removeItemAtPath:[NSTemporaryDirectory() stringByAppendingPathComponent:f] error:nil];
    // Controlify reads the controller through SDL itself, so MCInput stops
    // translating it. Mods only load when Fabric is what's launched.
    if ([version containsString:@"fabric"])
        for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[gameDir stringByAppendingPathComponent:@"mods"] error:nil])
            if ([f hasPrefix:@"controlify"]) MCSDLPadToMods = true;
    // -graphics and -option write to options.txt.
    NSMutableDictionary<NSString *, NSString *> *options = [NSMutableDictionary dictionary];
    NSString *api = [self argValue:@"-graphics" in:args];
    if (api.length) {
        options[@"preferredGraphicsBackend"] = [NSString stringWithFormat:@"\"%@\"", api];
        // After a failed start Minecraft drops a Vulkan choice back to its default
        // (OpenGL). A renderer picked here is deliberate, so it stays.
        options[@"startedCleanly"] = @"true";
    }
    for (NSUInteger i = 0; i + 1 < args.count; i++) {
        NSRange colon = [args[i + 1] rangeOfString:@":"];
        if ([args[i] isEqualToString:@"-option"] && colon.location != NSNotFound && colon.location > 0)
            options[[args[i + 1] substringToIndex:colon.location]] = [args[i + 1] substringFromIndex:colon.location + 1];
    }
    if (options.count) {
        NSString *path = [gameDir stringByAppendingPathComponent:@"options.txt"];
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
        NSMutableArray *lines = [NSMutableArray array];
        for (NSString *l in [text componentsSeparatedByString:@"\n"]) {
            NSRange colon = [l rangeOfString:@":"];
            if (l.length && !(colon.location != NSNotFound && options[[l substringToIndex:colon.location]])) [lines addObject:l];
        }
        for (NSString *key in options) [lines addObject:[NSString stringWithFormat:@"%@:%@", key, options[key]]];
        [[[lines componentsJoinedByString:@"\n"] stringByAppendingString:@"\n"] writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    MCLog(@"SDL mode: Minecraft 26.x, renderer %@, controller %@", api.length ? api : @"from options.txt",
          MCSDLPadToMods ? @"through Controlify" : @"translated to keys and mouse");
}

- (void)tailJavaLog {
    NSString *path = [MCDataDir() stringByAppendingPathComponent:@"java.log"];
    unsigned long long size = [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize];
    // Skip the previous run's log, which stays until Java truncates it. Then
    // follow the new one from the top.
    if (!_javaLogPrimed) {
        _javaLogPrimed = YES;
        _javaLogOffset = size;
        return;
    }
    if (size < _javaLogOffset) _javaLogOffset = 0;
    NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
    if (!fh) return;
    [fh seekToFileOffset:_javaLogOffset];
    NSData *data = [fh readDataToEndOfFile];
    [fh closeFile];
    if (!data.length) return;
    _javaLogOffset += data.length;
    NSString *text = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]
        ?: [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
    [_boot consumeJavaLog:text];
}
@end

@interface MCSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end

@implementation MCSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [MCRootViewController new];
    [self.window makeKeyAndVisible];
}
@end

@interface MCAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation MCAppDelegate
@end

int main(int argc, char *argv[]) {
    if (MCIsJLIReentry()) return MCMainReentry(argc, argv);
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass(MCAppDelegate.class));
    }
}
