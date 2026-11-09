// Native side of Amethyst's LWJGL/GLFW fork, ported to tvOS.
// Derived from Amethyst-iOS (GPLv3): Natives/environ.h, input_bridge_v3.m,
// egl_bridge.m, ctxbridges/gl_bridge.m. Trimmed to the OpenGL ES path
// (MobileGlues over ANGLE/Metal) and without Amethyst's launcher UI.
//
// Java (lwjgl.jar) System.load()s the MCTV executable from $POJAV_NATIVE_LIB
// and reaches this code in two ways.
//   - JNI natives (Java_org_lwjgl_glfw_*), registered via exported symbols
//   - pojav* C functions looked up with dlsym(RTLD_DEFAULT)
#pragma once

#include <stdatomic.h>
#include <stdbool.h>
#include "jni.h"
#include "glfw_keycodes.h"

#define MC_EXPORT __attribute__((visibility("default"), used))

// CallbackBridge.java event types
#define EVENT_TYPE_CHAR 1000
#define EVENT_TYPE_CHAR_MODS 1001
#define EVENT_TYPE_CURSOR_ENTER 1002
#define EVENT_TYPE_CURSOR_POS 1003
#define EVENT_TYPE_FRAMEBUFFER_SIZE 1004
#define EVENT_TYPE_KEY 1005
#define EVENT_TYPE_MOUSE_BUTTON 1006
#define EVENT_TYPE_SCROLL 1007
#define EVENT_TYPE_WINDOW_POS 1008
#define EVENT_TYPE_WINDOW_SIZE 1009

#define ACTION_DOWN 0
#define ACTION_UP 1
#define ACTION_MOVE 2
#define ACTION_MOVE_MOTION 3

typedef struct {
    short type;
    union { int i1; float f1; };
    union { int i2; float f2; };
    short i3;
    short i4;
} GLFWInputEvent;

typedef void GLFW_invoke_Char_func(void *window, unsigned int codepoint);
typedef void GLFW_invoke_CharMods_func(void *window, unsigned int codepoint, int mods);
typedef void GLFW_invoke_CursorEnter_func(void *window, int entered);
typedef void GLFW_invoke_CursorPos_func(void *window, double xpos, double ypos);
typedef void GLFW_invoke_FramebufferSize_func(void *window, int width, int height);
typedef void GLFW_invoke_Key_func(void *window, int key, int scancode, int action, int mods);
typedef void GLFW_invoke_MouseButton_func(void *window, int button, int action, int mods);
typedef void GLFW_invoke_Scroll_func(void *window, double xoffset, double yoffset);
typedef void GLFW_invoke_WindowPos_func(void *window, int x, int y);
typedef void GLFW_invoke_WindowSize_func(void *window, int width, int height);

// --- set by the app before the JVM starts ---------------------------------
// The CAMetalLayer ANGLE renders into (a CALayer *, bridged).
extern void *MCGameLayer;
// Minecraft 26.x runs on SDL (sdl_bridge.m), so input goes to SDL's queue instead of GLFW's.
extern bool MCSDLMode;
extern bool MCSDLPadToMods;  // Controlify reads the controller through SDL itself
extern int MCSDLRefreshRate;
void MCSDLKey(int glfwKey, int scancode, int action);
void MCSDLChar(unsigned int codepoint);
void MCSDLPointer(char event, double x, double y);
void MCSDLButton(int glfwButton, int action);
void MCSDLScroll(double x, double y);
// Game framebuffer size in pixels.
extern int windowWidth, windowHeight;
// Called once, on the render thread, after the first frame is presented.
extern void (*MCOnFirstFrame)(void);
// Set once the first frame has been presented.
extern volatile bool MCFirstFrameSeen;

// --- shared state (input_bridge.m) -----------------------------------------
extern JavaVM *runtimeJavaVMPtr;
extern JNIEnv *runtimeJNIEnvPtr;
extern jclass vmGlfwClass;
extern jmethodID method_internalWindowSizeChanged;
extern jbyte *keyDownBuffer;
extern atomic_size_t eventCounter;
extern GLFWInputEvent events[8000];
extern double cursorX, cursorY, cLastX, cLastY;
extern jboolean isGrabbing;
extern long showingWindow;
extern bool isInputReady, isUseStackQueueCall;

#define DECLARE_CALLBACK(NAME) extern GLFW_invoke_##NAME##_func *GLFW_invoke_##NAME;
DECLARE_CALLBACK(Char)
DECLARE_CALLBACK(CharMods)
DECLARE_CALLBACK(CursorEnter)
DECLARE_CALLBACK(CursorPos)
DECLARE_CALLBACK(FramebufferSize)
DECLARE_CALLBACK(Key)
DECLARE_CALLBACK(MouseButton)
DECLARE_CALLBACK(Scroll)
DECLARE_CALLBACK(WindowPos)
DECLARE_CALLBACK(WindowSize)
#undef DECLARE_CALLBACK

// --- input, called from the app (any thread) -------------------------------
// The TV's game controller as GLFW gamepad 0, for controller mods (Controlify)
// that read it through the patched GLFW.java. Same layout as GLFWgamepadstate.
typedef struct {
    unsigned char buttons[15];  // GLFW_GAMEPAD_BUTTON_*
    float axes[6];              // GLFW_GAMEPAD_AXIS_*: sticks -1..1 (y down), triggers -1..1
} MCGamepadState;
void MCGamepadPublish(bool connected, const MCGamepadState *state, const char *name, const char *guid);
// True if Java read the gamepad in the last 2 s, i.e. a mod drives it.
bool MCGamepadReadByJava(void);
// Rumble on that controller (MCRumble.m). Levels 0..1, strong for the
// low-frequency motor and weak for the high one. Each holds for up to 5 s.
bool MCRumbleSupported(void);
void MCRumbleSet(float strong, float weak);

void CallbackBridge_nativeSetInputReady(bool inputReady);
bool CallbackBridge_nativeSendChar(jchar codepoint);
bool CallbackBridge_nativeSendCharMods(jchar codepoint, int mods);
void CallbackBridge_nativeSendCursorPos(char event, double x, double y);
void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods);
void CallbackBridge_nativeSendMouseButton(int button, int action, int mods);
void CallbackBridge_nativeSendScreenSize(int width, int height);
void CallbackBridge_nativeSendScroll(double xoffset, double yoffset);
void CallbackBridge_pauseGameIfNeed(void);

// "libmobileglues.dylib" or "libtinygl4angle.dylib", from $MCTV_RENDERER (mobileglues|angle).
const char *MCRendererLibrary(void);

// --- GL context (gl_bridge.m) -----------------------------------------------
typedef struct gl_render_window gl_render_window_t;
bool gl_init(void);
gl_render_window_t *gl_init_context(gl_render_window_t *share);
void gl_make_current(gl_render_window_t *bundle);
gl_render_window_t *gl_get_current(void);
void gl_swap_buffers(void);
void gl_swap_interval(int interval);
void gl_terminate(void);
