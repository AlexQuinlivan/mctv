// The app's side of SDL, for Minecraft 26.x, which uses SDL 3 instead of GLFW.
// MCTV's SDL video backend (mctv/sdl/SDL_mctvvideo.m, built into libSDL3) finds
// mctv_sdl_host() with dlsym and does everything through it. In SDL mode the
// CallbackBridge_nativeSend* functions (input_bridge.m) hand MCInput's events
// here instead of to GLFW, with GLFW keys turned into SDL scancodes.
#import <UIKit/UIKit.h>
#include <os/lock.h>
#include <pthread.h>
#include "bridge.h"
#include "../../sdl/mctv_sdl.h"
#import "../JVM.h"

bool MCSDLMode;
int MCSDLRefreshRate = 60;

// -- the queue SDL drains when Minecraft pumps events --------------------------------

enum { kQueue = 4096 };
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static MCTVSDLEvent gQueue[kQueue];
static size_t gHead, gCount;

static void Push(MCTVSDLEvent e) {
    os_unfair_lock_lock(&gLock);
    if (gCount < kQueue) {
        gQueue[(gHead + gCount) % kQueue] = e;
        gCount++;
    }
    os_unfair_lock_unlock(&gLock);
}

// GLFW key codes (what MCInput sends) to SDL scancodes, which are USB HID usages.
static int ScancodeForGLFW(int key) {
    if (key >= GLFW_KEY_A && key <= GLFW_KEY_Z) return 4 + (key - GLFW_KEY_A);
    if (key >= GLFW_KEY_1 && key <= GLFW_KEY_9) return 30 + (key - GLFW_KEY_1);
    if (key >= GLFW_KEY_F1 && key <= GLFW_KEY_F12) return 58 + (key - GLFW_KEY_F1);
    if (key >= GLFW_KEY_F13 && key <= GLFW_KEY_F24) return 104 + (key - GLFW_KEY_F13);
    if (key >= GLFW_KEY_NUMPAD_1 && key <= GLFW_KEY_NUMPAD_9) return 89 + (key - GLFW_KEY_NUMPAD_1);
    switch (key) {
        case GLFW_KEY_0: return 39;
        case GLFW_KEY_ENTER: return 40;
        case GLFW_KEY_ESCAPE: return 41;
        case GLFW_KEY_BACKSPACE: return 42;
        case GLFW_KEY_TAB: return 43;
        case GLFW_KEY_SPACE: return 44;
        case GLFW_KEY_MINUS: return 45;
        case GLFW_KEY_EQUAL: return 46;
        case GLFW_KEY_LEFT_BRACKET: return 47;
        case GLFW_KEY_RIGHT_BRACKET: return 48;
        case GLFW_KEY_BACKSLASH: return 49;
        case GLFW_KEY_SEMICOLON: return 51;
        case GLFW_KEY_APOSTROPHE: return 52;
        case GLFW_KEY_GRAVE_ACCENT: return 53;
        case GLFW_KEY_COMMA: return 54;
        case GLFW_KEY_PERIOD: return 55;
        case GLFW_KEY_SLASH: return 56;
        case GLFW_KEY_CAPS_LOCK: return 57;
        case GLFW_KEY_PRINT_SCREEN: return 70;
        case GLFW_KEY_SCROLL_LOCK: return 71;
        case GLFW_KEY_PAUSE: return 72;
        case GLFW_KEY_INSERT: return 73;
        case GLFW_KEY_HOME: return 74;
        case GLFW_KEY_PAGE_UP: return 75;
        case GLFW_KEY_DELETE: return 76;
        case GLFW_KEY_END: return 77;
        case GLFW_KEY_PAGE_DOWN: return 78;
        case GLFW_KEY_DPAD_RIGHT: return 79;
        case GLFW_KEY_DPAD_LEFT: return 80;
        case GLFW_KEY_DPAD_DOWN: return 81;
        case GLFW_KEY_DPAD_UP: return 82;
        case GLFW_KEY_NUM_LOCK: return 83;
        case GLFW_KEY_NUMPAD_DIVIDE: return 84;
        case GLFW_KEY_NUMPAD_MULTIPLY: return 85;
        case GLFW_KEY_NUMPAD_SUBTRACT: return 86;
        case GLFW_KEY_NUMPAD_ADD: return 87;
        case GLFW_KEY_NUMPAD_ENTER: return 88;
        case GLFW_KEY_NUMPAD_0: return 98;
        case GLFW_KEY_NUMPAD_DECIMAL: return 99;
        case GLFW_KEY_NUMPAD_EQUAL: return 103;
        case GLFW_KEY_MENU: return 118;
        case GLFW_KEY_LEFT_CONTROL: return 224;
        case GLFW_KEY_LEFT_SHIFT: return 225;
        case GLFW_KEY_LEFT_ALT: return 226;
        case GLFW_KEY_LEFT_SUPER: return 227;
        case GLFW_KEY_RIGHT_CONTROL: return 228;
        case GLFW_KEY_RIGHT_SHIFT: return 229;
        case GLFW_KEY_RIGHT_ALT: return 230;
        case GLFW_KEY_RIGHT_SUPER: return 231;
        default: return 0;
    }
}

void MCSDLKey(int glfwKey, int scancode, int action) {
    // A real keyboard gives its HID usage. The remote and controller give only GLFW keys.
    int code = (scancode >= 4 && scancode <= 231) ? scancode : ScancodeForGLFW(glfwKey);
    if (!code) return;
    Push((MCTVSDLEvent){.type = MCTV_SDL_KEY, .code = code, .down = action != 0});
    // Minecraft on "macOS" expects Command where other platforms use Control.
    if (code == 224 || code == 228) Push((MCTVSDLEvent){.type = MCTV_SDL_KEY, .code = code + 3, .down = action != 0});
}

void MCSDLChar(unsigned int c) {
    static unsigned int high;  // a UTF-16 high surrogate waiting for its pair
    if (c >= 0xD800 && c <= 0xDBFF) { high = c; return; }
    if (c >= 0xDC00 && c <= 0xDFFF) {
        if (!high) return;
        c = 0x10000 + ((high - 0xD800) << 10) + (c - 0xDC00);
    }
    high = 0;
    if (c < 0x20 || c == 0x7F) return;  // control keys arrive as keys
    MCTVSDLEvent e = {.type = MCTV_SDL_TEXT};
    char *t = e.text;
    if (c < 0x80) { t[0] = (char)c; }
    else if (c < 0x800) { t[0] = 0xC0 | (c >> 6); t[1] = 0x80 | (c & 0x3F); }
    else if (c < 0x10000) { t[0] = 0xE0 | (c >> 12); t[1] = 0x80 | ((c >> 6) & 0x3F); t[2] = 0x80 | (c & 0x3F); }
    else { t[0] = 0xF0 | (c >> 18); t[1] = 0x80 | ((c >> 12) & 0x3F); t[2] = 0x80 | ((c >> 6) & 0x3F); t[3] = 0x80 | (c & 0x3F); }
    Push(e);
}

// cursorX/cursorY stay the pointer's position, as MCInput expects.
void MCSDLPointer(char event, double x, double y) {
    if (event == ACTION_MOVE_MOTION) {
        cursorX += x;
        cursorY += y;
        Push((MCTVSDLEvent){.type = MCTV_SDL_MOVE_BY, .x = (float)x, .y = (float)y});
        return;
    }
    if (isGrabbing) return;
    cursorX = x;
    cursorY = y;
    Push((MCTVSDLEvent){.type = MCTV_SDL_MOVE, .x = (float)x, .y = (float)y});
}

void MCSDLButton(int glfwButton, int action) {
    static const int map[] = {1, 3, 2, 4, 5};  // GLFW left, right, middle, 4, 5
    if (glfwButton < 0 || glfwButton > 4) return;
    Push((MCTVSDLEvent){.type = MCTV_SDL_BUTTON, .code = map[glfwButton], .down = action != 0});
}

void MCSDLScroll(double x, double y) {
    Push((MCTVSDLEvent){.type = MCTV_SDL_WHEEL, .x = (float)x, .y = (float)y});
}

// -- the host table ------------------------------------------------------------------------

static bool gWindowSeen, gUsesGL;

static void HostScreen(int *w, int *h, float *hz) {
    if (windowWidth > 0 && windowHeight > 0) {
        *w = windowWidth;
        *h = windowHeight;
    }
    *hz = (float)MCSDLRefreshRate;
}

// -- waiting in the background --------------------------------------------------------
// tvOS doesn't let a background app use the GPU. Metal fails its command
// buffers, MoltenVK reports the device lost, and Minecraft stops with a crash
// report. Minecraft pumps events once a frame on its render thread, so that
// thread waits here while the app is inactive. The frame in flight finishes long
// before the app reaches the background.
// tvOS suspends an app soon after it leaves, which drops its server connection,
// so the app asks for the usual background time (about 30 s). A quick trip to
// the home screen then doesn't disconnect the player. Meanwhile the agent keeps
// Minecraft's keepalive replies going (RenderSystem.isFrozenAtPollEvents).

static pthread_mutex_t gActiveLock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t gActiveCond = PTHREAD_COND_INITIALIZER;
static bool gInactive;

static UIBackgroundTaskIdentifier gBackgroundTask;  // main thread only
static bool gHasBackgroundTask;

static void SetActive(bool active) {
    pthread_mutex_lock(&gActiveLock);
    gInactive = !active;
    pthread_cond_broadcast(&gActiveCond);
    pthread_mutex_unlock(&gActiveLock);
}

static void EndBackgroundTime(void) {  // on the main thread
    if (!gHasBackgroundTask) return;
    [UIApplication.sharedApplication endBackgroundTask:gBackgroundTask];
    gHasBackgroundTask = false;
}

static void WaitWhileInactive(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { SetActive(false); }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { EndBackgroundTime(); SetActive(true); }];
        [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) {
            if (gHasBackgroundTask) return;
            gBackgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"Minecraft connection"
                                                                         expirationHandler:^{
                MCLog(@"SDL: background time is up, tvOS suspends the app");
                EndBackgroundTime();
            }];
            gHasBackgroundTask = gBackgroundTask != UIBackgroundTaskInvalid;
            NSTimeInterval left = UIApplication.sharedApplication.backgroundTimeRemaining;
            if (left < 3600) MCLog(@"SDL: in the background, %.0f s before tvOS suspends the app", left);
            else MCLog(@"SDL: in the background");
        }];
    });
    pthread_mutex_lock(&gActiveLock);
    bool waited = gInactive;
    if (waited) MCLog(@"SDL: the app isn't active, so the game waits");
    while (gInactive) pthread_cond_wait(&gActiveCond, &gActiveLock);
    pthread_mutex_unlock(&gActiveLock);
    if (waited) MCLog(@"SDL: active again, the game carries on");
}

static bool HostPoll(MCTVSDLEvent *out) {
    WaitWhileInactive();
    // Vulkan presents straight to the layer, so there's no swap to watch for
    // the first frame. Minecraft pumps events once a frame, so a second of
    // pumping after the window appears means it's drawing.
    static int polls;
    if (gWindowSeen && !gUsesGL && !MCFirstFrameSeen && ++polls == 60) {
        MCFirstFrameSeen = true;
        MCStatus(MCLogOK, @"Game running: drawing with Vulkan");
        if (MCOnFirstFrame) MCOnFirstFrame();
    }
    bool got = false;
    os_unfair_lock_lock(&gLock);
    if (gCount) {
        *out = gQueue[gHead];
        gHead = (gHead + 1) % kQueue;
        gCount--;
        got = true;
    }
    os_unfair_lock_unlock(&gLock);
    return got;
}

static void *HostMetalLayer(void) {
    gWindowSeen = true;
    MCStatus(MCLogOK, @"Graphics: Vulkan through MoltenVK on Metal");
    return MCGameLayer;
}

// The same file LWJGL loads (org.lwjgl.opengl.libname, found on its library
// path), by full path, so SDL and LWJGL share one handle and one glGetError.
static const char *HostGLLibrary(void) {
    static char path[1024];
    if (!path[0]) {
        const char *lib = MCRendererLibrary();
        if (!strcmp(lib, "libmobileglues.dylib")) lib = "libmctvgl.dylib";  // see mctv/gl/mctv_gl.c
        NSString *p = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@(lib)];
        strlcpy(path, p.fileSystemRepresentation, sizeof(path));
    }
    return path;
}

static void *HostGLCreate(void) {
    static bool ready;
    if (!ready && !(ready = gl_init())) return NULL;
    gWindowSeen = gUsesGL = true;
    return gl_init_context(NULL);
}

static bool HostGLMakeCurrent(void *context) {
    gl_make_current((gl_render_window_t *)context);
    return context == NULL || gl_get_current() == context;
}

static void HostGLSwap(void) { gl_swap_buffers(); }
static void HostGLSwapInterval(int interval) { gl_swap_interval(interval); }
static void HostGLDestroy(void *context) {}

static void HostRelativeMouse(bool on) {
    if (on == (bool)isGrabbing) return;
    isGrabbing = on;
    MCLog(@"bridge: mouse %s", on ? "grabbed (in game)" : "released (menu)");
}

static void HostWarp(float x, float y) {
    cursorX = x;
    cursorY = y;
}

static void HostTextInput(bool on) {
    MCStatus(MCLogQuiet, @"bridge: text input %s", on ? "on" : "off");
}

static void HostLog(const char *message) {
    MCLog(@"%s", message);
}

MC_EXPORT const MCTVSDLHost *mctv_sdl_host(void) {
    static const MCTVSDLHost host = {
        .version = MCTV_SDL_HOST_VERSION,
        .screen = HostScreen,
        .poll = HostPoll,
        .metal_layer = HostMetalLayer,
        .gl_library = HostGLLibrary,
        .gl_create = HostGLCreate,
        .gl_make_current = HostGLMakeCurrent,
        .gl_swap = HostGLSwap,
        .gl_swap_interval = HostGLSwapInterval,
        .gl_destroy = HostGLDestroy,
        .relative_mouse = HostRelativeMouse,
        .warp = HostWarp,
        .text_input = HostTextInput,
        .log = HostLog,
    };
    if (!MCSDLMode) return NULL;  // 1.21.11 never loads SDL, but be sure
    isInputReady = true;
    return &host;
}
