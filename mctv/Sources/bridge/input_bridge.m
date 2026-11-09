// GLFW callbacks and input queue for lwjgl.jar's GLFW fork, plus the JNI
// natives it (and launcher.jar) declare.
// Derived from Amethyst-iOS (GPLv3) Natives/input_bridge_v3.m, environ.h and
// ios_uikit_bridge.m, without the iOS file/URL/clipboard integrations.
#import <Foundation/Foundation.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stdlib.h>
#include <string.h>
#include "bridge.h"
#import "../JVM.h"

// --- shared state ------------------------------------------------------------
void *MCGameLayer;
int windowWidth, windowHeight;

JavaVM *runtimeJavaVMPtr;
JNIEnv *runtimeJNIEnvPtr;
jclass vmGlfwClass;
jmethodID method_internalWindowSizeChanged;
jbyte *keyDownBuffer;
atomic_size_t eventCounter;
GLFWInputEvent events[8000];
double cursorX, cursorY, cLastX, cLastY;
jboolean isGrabbing;
long showingWindow;
bool isInputReady, isUseStackQueueCall;

#define DEFINE_CALLBACK(NAME) GLFW_invoke_##NAME##_func *GLFW_invoke_##NAME;
DEFINE_CALLBACK(Char)
DEFINE_CALLBACK(CharMods)
DEFINE_CALLBACK(CursorEnter)
DEFINE_CALLBACK(CursorPos)
DEFINE_CALLBACK(FramebufferSize)
DEFINE_CALLBACK(Key)
DEFINE_CALLBACK(MouseButton)
DEFINE_CALLBACK(Scroll)
DEFINE_CALLBACK(WindowPos)
DEFINE_CALLBACK(WindowSize)
#undef DEFINE_CALLBACK

// --- JNI_OnLoad (lwjgl.jar's GLFW does System.load($POJAV_NATIVE_LIB)) ------
MC_EXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    runtimeJavaVMPtr = vm;
    JNIEnv *env;
    (*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_4);
    runtimeJNIEnvPtr = env;
    jclass glfw = (*env)->FindClass(env, "org/lwjgl/glfw/GLFW");
    if (!glfw) {
        (*env)->ExceptionClear(env);
        MCLog(@"bridge: JNI_OnLoad without org.lwjgl.glfw.GLFW");
        return JNI_VERSION_1_4;
    }
    vmGlfwClass = (*env)->NewGlobalRef(env, glfw);
    method_internalWindowSizeChanged = (*env)->GetStaticMethodID(env, vmGlfwClass, "internalWindowSizeChanged", "(JII)V");
    jfieldID f = (*env)->GetStaticFieldID(env, vmGlfwClass, "keyDownBuffer", "Ljava/nio/ByteBuffer;");
    jobject buf = (*env)->GetStaticObjectField(env, vmGlfwClass, f);
    keyDownBuffer = (*env)->GetDirectBufferAddress(env, buf);
    MCLog(@"bridge: JNI_OnLoad done (window %dx%d)", windowWidth, windowHeight);
    return JNI_VERSION_1_4;
}

// --- GLFW callback registration ---------------------------------------------
#define ADD_CALLBACK_WWIN(NAME) \
MC_EXPORT JNIEXPORT jlong JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSet##NAME##Callback(JNIEnv *env, jclass cls, jlong window, jlong callbackptr) { \
    void *old = (void *)GLFW_invoke_##NAME; \
    GLFW_invoke_##NAME = (GLFW_invoke_##NAME##_func *)(uintptr_t)callbackptr; \
    if (!old != !callbackptr) MCStatus(MCLogQuiet, @"bridge: %s callback %s (window %p)", #NAME, callbackptr ? "set" : "cleared", (void *)(uintptr_t)window); \
    return (jlong)(uintptr_t)old; \
}
ADD_CALLBACK_WWIN(Char)
ADD_CALLBACK_WWIN(CharMods)
ADD_CALLBACK_WWIN(CursorEnter)
ADD_CALLBACK_WWIN(CursorPos)
ADD_CALLBACK_WWIN(FramebufferSize)
ADD_CALLBACK_WWIN(Key)
ADD_CALLBACK_WWIN(MouseButton)
ADD_CALLBACK_WWIN(Scroll)
ADD_CALLBACK_WWIN(WindowPos)
ADD_CALLBACK_WWIN(WindowSize)
#undef ADD_CALLBACK_WWIN

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwSetShowingWindow(JNIEnv *env, jclass clazz, jlong window) {
    showingWindow = (long)window;
}

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPos(JNIEnv *env, jclass clazz, jlong window, jobject xpos, jobject ypos) {
    *(double *)(*env)->GetDirectBufferAddress(env, xpos) = cursorX;
    *(double *)(*env)->GetDirectBufferAddress(env, ypos) = cursorY;
}

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nglfwGetCursorPosA(JNIEnv *env, jclass clazz, jlong window, jdoubleArray xpos, jdoubleArray ypos) {
    (*env)->SetDoubleArrayRegion(env, xpos, 0, 1, &cursorX);
    (*env)->SetDoubleArrayRegion(env, ypos, 0, 1, &cursorY);
}

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_glfwSetCursorPos(JNIEnv *env, jclass clazz, jlong window, jdouble xpos, jdouble ypos) {
    cLastX = cursorX = xpos;
    cLastY = cursorY = ypos;
}

// --- gamepad for Java (patched GLFW.java: nmctvGamepad*) ----------------------
static os_unfair_lock gPadLock = OS_UNFAIR_LOCK_INIT;
static MCGamepadState gPad;
static bool gPadConnected;
static char gPadName[96], gPadGUID[40];
static _Atomic double gPadReadAt;

void MCGamepadPublish(bool connected, const MCGamepadState *state, const char *name, const char *guid) {
    os_unfair_lock_lock(&gPadLock);
    gPadConnected = connected;
    if (state) gPad = *state;
    if (name) strlcpy(gPadName, name, sizeof(gPadName));
    if (guid) strlcpy(gPadGUID, guid, sizeof(gPadGUID));
    os_unfair_lock_unlock(&gPadLock);
}

bool MCSDLPadToMods;

bool MCGamepadReadByJava(void) {
    if (MCSDLMode) return MCSDLPadToMods;
    return CFAbsoluteTimeGetCurrent() - gPadReadAt < 2.0;
}

MC_EXPORT JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadConnected(JNIEnv *env, jclass clazz) {
    return gPadConnected;
}

MC_EXPORT JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadState(JNIEnv *env, jclass clazz, jlong ptr) {
    gPadReadAt = CFAbsoluteTimeGetCurrent();
    os_unfair_lock_lock(&gPadLock);
    bool ok = gPadConnected;
    if (ok && ptr) memcpy((void *)(intptr_t)ptr, &gPad, sizeof(gPad));
    os_unfair_lock_unlock(&gPadLock);
    return ok;
}

static jstring PadString(JNIEnv *env, const char *s) {
    char copy[96];
    os_unfair_lock_lock(&gPadLock);
    bool ok = gPadConnected;
    strlcpy(copy, s, sizeof(copy));
    os_unfair_lock_unlock(&gPadLock);
    return ok ? (*env)->NewStringUTF(env, copy) : NULL;
}

MC_EXPORT JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadName(JNIEnv *env, jclass clazz) {
    return PadString(env, gPadName);
}

MC_EXPORT JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadGUID(JNIEnv *env, jclass clazz) {
    return PadString(env, gPadGUID);
}

// Rumble, from the mctv mod's hook in Controlify's GLFW driver (java/mctv-mod).
MC_EXPORT JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadHasRumble(JNIEnv *env, jclass clazz, jint jid) {
    return jid == 0 && gPadConnected && MCRumbleSupported();
}

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_GLFW_nmctvGamepadRumble(JNIEnv *env, jclass clazz, jint jid, jfloat strong, jfloat weak) {
    if (jid == 0) MCRumbleSet(strong, weak);
}

// --- CallbackBridge natives ---------------------------------------------------
// tvOS has no UIPasteboard, so the clipboard lives in memory.
static NSString *gClipboard = @"";

MC_EXPORT JNIEXPORT jstring JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeClipboard(JNIEnv *env, jclass clazz, jint action, jbyteArray copy) {
    if (action == 2000 /* CLIPBOARD_COPY */ && copy) {
        jsize n = (*env)->GetArrayLength(env, copy);
        jbyte *bytes = (*env)->GetByteArrayElements(env, copy, NULL);
        size_t len = strnlen((const char *)bytes, n);
        gClipboard = [[NSString alloc] initWithBytes:bytes length:len encoding:NSUTF8StringEncoding] ?: @"";
        (*env)->ReleaseByteArrayElements(env, copy, bytes, JNI_ABORT);
        return NULL;
    }
    return (*env)->NewStringUTF(env, gClipboard.UTF8String);
}

MC_EXPORT JNIEXPORT void JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeSetGrabbing(JNIEnv *env, jclass clazz, jboolean grabbing) {
    isGrabbing = grabbing;
    MCLog(@"bridge: mouse %s", grabbing ? "grabbed (in game)" : "released (menu)");
}

MC_EXPORT JNIEXPORT jboolean JNICALL Java_org_lwjgl_glfw_CallbackBridge_nativeIsGrabbing(JNIEnv *env, jclass clazz) {
    return isGrabbing;
}

// launcher.jar: net.kdt.pojavlaunch.uikit.UIKit.showError
MC_EXPORT JNIEXPORT void JNICALL Java_net_kdt_pojavlaunch_uikit_UIKit_showError(JNIEnv *env, jclass clazz, jstring title, jstring message, jboolean exitIfOk) {
    const char *t = title ? (*env)->GetStringUTFChars(env, title, NULL) : "";
    const char *m = message ? (*env)->GetStringUTFChars(env, message, NULL) : "";
    MCLog(@"Java error: %s: %s", t, m);
    if (title) (*env)->ReleaseStringUTFChars(env, title, t);
    if (message) (*env)->ReleaseStringUTFChars(env, message, m);
}

// --- event pump (pojavPumpEvents/pojavRewindEvents, from glfwPollEvents) -----
static void handleFramebufferSizeJava(void *window, int w, int h) {
    if (GLFW_invoke_CursorEnter) GLFW_invoke_CursorEnter(window, 1);
    if (GLFW_invoke_WindowPos) GLFW_invoke_WindowPos(window, 0, 0);
    (*runtimeJNIEnvPtr)->CallStaticVoidMethod(runtimeJNIEnvPtr, vmGlfwClass, method_internalWindowSizeChanged, (jlong)(uintptr_t)window, w, h);
}

// The UI thread queues events and the render thread drains them in
// glfwPollEvents. The pump takes the whole queue under a lock. Amethyst's
// lock-free version could replay or lose events.
static os_unfair_lock gEventLock = OS_UNFAIR_LOCK_INIT;
static GLFWInputEvent gPending[8000];

MC_EXPORT void pojavPumpEvents(void *window) {
    static bool setInputReady;
    if (!setInputReady) {
        setInputReady = true;
        CallbackBridge_nativeSetInputReady(true);
    }
    if ((cLastX != cursorX || cLastY != cursorY) && GLFW_invoke_CursorPos) {
        cLastX = cursorX;
        cLastY = cursorY;
        if (isUseStackQueueCall) GLFW_invoke_CursorPos(window, cursorX, cursorY);
    }
    os_unfair_lock_lock(&gEventLock);
    size_t n = atomic_load_explicit(&eventCounter, memory_order_relaxed);
    memcpy(gPending, events, n * sizeof(GLFWInputEvent));
    atomic_store_explicit(&eventCounter, 0, memory_order_relaxed);
    os_unfair_lock_unlock(&gEventLock);

    for (size_t i = 0; i < n; i++) {
        GLFWInputEvent e = gPending[i];
        switch (e.type) {
            case EVENT_TYPE_CHAR: if (GLFW_invoke_Char) GLFW_invoke_Char(window, e.i1); break;
            case EVENT_TYPE_CHAR_MODS: if (GLFW_invoke_CharMods) GLFW_invoke_CharMods(window, e.i1, e.i2); break;
            case EVENT_TYPE_KEY: if (GLFW_invoke_Key) GLFW_invoke_Key(window, e.i1, e.i2, e.i3, e.i4); break;
            case EVENT_TYPE_MOUSE_BUTTON: if (GLFW_invoke_MouseButton) GLFW_invoke_MouseButton(window, e.i1, e.i2, e.i3); break;
            case EVENT_TYPE_SCROLL: if (GLFW_invoke_Scroll) GLFW_invoke_Scroll(window, e.f1, e.f2); break;
            case EVENT_TYPE_FRAMEBUFFER_SIZE:
                handleFramebufferSizeJava(window, e.i1, e.i2);
                if (GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize(window, e.i1, e.i2);
                break;
            case EVENT_TYPE_WINDOW_SIZE:
                handleFramebufferSizeJava(window, e.i1, e.i2);
                if (GLFW_invoke_WindowSize) GLFW_invoke_WindowSize(window, e.i1, e.i2);
                break;
        }
    }
}

// The queue is emptied by the pump itself.
MC_EXPORT void pojavRewindEvents(void) {}

static void enqueue(GLFWInputEvent e) {
    os_unfair_lock_lock(&gEventLock);
    size_t n = atomic_load_explicit(&eventCounter, memory_order_relaxed);
    if (n < 8000) {
        events[n] = e;
        atomic_store_explicit(&eventCounter, n + 1, memory_order_relaxed);
    }
    os_unfair_lock_unlock(&gEventLock);
}

static void sendData(short type, int i1, int i2, short i3, short i4) {
    GLFWInputEvent e = {.type = type, .i1 = i1, .i2 = i2, .i3 = i3, .i4 = i4};
    enqueue(e);
}

static void sendDataFloat(short type, float f1, float f2) {
    GLFWInputEvent e = {.type = type, .f1 = f1, .f2 = f2};
    enqueue(e);
}

// --- input from the app --------------------------------------------------------
void CallbackBridge_nativeSetInputReady(bool inputReady) {
    isInputReady = inputReady;
    if (!inputReady) return;
    // Minecraft maps mouse positions with the window size and draws with the
    // framebuffer size, so send both. Without the window size it stays at its
    // 854x480 default and clicks miss.
    if (GLFW_invoke_FramebufferSize) GLFW_invoke_FramebufferSize((void *)showingWindow, windowWidth, windowHeight);
    if (GLFW_invoke_WindowSize) GLFW_invoke_WindowSize((void *)showingWindow, windowWidth, windowHeight);
    MCLog(@"bridge: input ready, window and framebuffer %dx%d", windowWidth, windowHeight);
}

bool CallbackBridge_nativeSendChar(jchar codepoint) {
    if (MCSDLMode) { MCSDLChar(codepoint); return true; }
    if (!GLFW_invoke_Char || !isInputReady) return false;
    if (isUseStackQueueCall) sendData(EVENT_TYPE_CHAR, codepoint, 0, 0, 0);
    else GLFW_invoke_Char((void *)showingWindow, codepoint);
    return true;
}

bool CallbackBridge_nativeSendCharMods(jchar codepoint, int mods) {
    if (MCSDLMode) { MCSDLChar(codepoint); return true; }
    if (!GLFW_invoke_CharMods || !isInputReady) return false;
    if (isUseStackQueueCall) sendData(EVENT_TYPE_CHAR_MODS, codepoint, mods, 0, 0);
    else GLFW_invoke_CharMods((void *)showingWindow, codepoint, mods);
    return true;
}

void CallbackBridge_nativeSendCursorPos(char event, double x, double y) {
    if (MCSDLMode) { MCSDLPointer(event, x, y); return; }
    if (!GLFW_invoke_CursorPos || !isInputReady) return;
    switch (event) {
        case ACTION_DOWN:
        case ACTION_UP:
            if (!isGrabbing) { cursorX = x; cursorY = y; }
            break;
        case ACTION_MOVE:
            if (isGrabbing) { cursorX += x - cLastX; cursorY += y - cLastY; }
            else { cursorX = x; cursorY = y; }
            break;
        case ACTION_MOVE_MOTION:
            cursorX += x;
            cursorY += y;
            break;
    }
    if (!isUseStackQueueCall) GLFW_invoke_CursorPos((void *)showingWindow, cursorX, cursorY);
}

static int keyModifiers(int key, int action) {
    static int mods;
    int mod;
    switch (key) {
        case GLFW_KEY_LEFT_SHIFT: mod = GLFW_MOD_SHIFT; break;
        case GLFW_KEY_LEFT_CONTROL: mod = GLFW_MOD_CONTROL; break;
        case GLFW_KEY_LEFT_ALT: mod = GLFW_MOD_ALT; break;
        case GLFW_KEY_CAPS_LOCK: mod = GLFW_MOD_CAPS_LOCK; break;
        case GLFW_KEY_NUM_LOCK: mod = GLFW_MOD_NUM_LOCK; break;
        default: return mods;
    }
    if (action) mods |= mod; else mods &= ~mod;
    return mods;
}

void CallbackBridge_nativeSendKey(int key, int scancode, int action, int mods) {
    if (MCSDLMode) { MCSDLKey(key, scancode, action); return; }
    if (GLFW_invoke_Key && isInputReady) {
        if (keyDownBuffer && action != 2) keyDownBuffer[MAX(0, key - 31)] = (jbyte)action;  // 2 is a repeat, still down
        if (mods == 0) mods = keyModifiers(key, action);
        if (isUseStackQueueCall) sendData(EVENT_TYPE_KEY, key, scancode, action, mods);
        else GLFW_invoke_Key((void *)showingWindow, key, scancode, action, mods);
    }
    // Minecraft on "macOS" expects Command where other platforms use Control.
    if (key == GLFW_KEY_LEFT_CONTROL) CallbackBridge_nativeSendKey(GLFW_KEY_LEFT_SUPER, 0, action, mods);
    else if (key == GLFW_KEY_RIGHT_CONTROL) CallbackBridge_nativeSendKey(GLFW_KEY_RIGHT_SUPER, 0, action, mods);
}

void CallbackBridge_nativeSendMouseButton(int button, int action, int mods) {
    if (MCSDLMode) { MCSDLButton(button, action); return; }
    if (!isInputReady || button < 0 || !GLFW_invoke_MouseButton) return;
    if (mods == 0) mods = keyModifiers(0, action);
    if (isUseStackQueueCall) sendData(EVENT_TYPE_MOUSE_BUTTON, button, action, mods, 0);
    else GLFW_invoke_MouseButton((void *)showingWindow, button, action, mods);
}

void CallbackBridge_nativeSendScreenSize(int width, int height) {
    windowWidth = width;
    windowHeight = height;
    if (MCSDLMode || !isInputReady) return;  // SDL's window always fills the screen
    if (GLFW_invoke_FramebufferSize) {
        if (isUseStackQueueCall) sendData(EVENT_TYPE_FRAMEBUFFER_SIZE, width, height, 0, 0);
        else GLFW_invoke_FramebufferSize((void *)showingWindow, width, height);
    }
    if (GLFW_invoke_WindowSize) {
        if (isUseStackQueueCall) sendData(EVENT_TYPE_WINDOW_SIZE, width, height, 0, 0);
        else GLFW_invoke_WindowSize((void *)showingWindow, width, height);
    }
}

void CallbackBridge_nativeSendScroll(double xoffset, double yoffset) {
    if (MCSDLMode) { MCSDLScroll(xoffset, yoffset); return; }
    if (!GLFW_invoke_Scroll || !isInputReady) return;
    if (isUseStackQueueCall) sendDataFloat(EVENT_TYPE_SCROLL, xoffset, yoffset);
    else GLFW_invoke_Scroll((void *)showingWindow, xoffset, yoffset);
}

void CallbackBridge_pauseGameIfNeed(void) {
    if (isGrabbing) {
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 1, 0);
        CallbackBridge_nativeSendKey(GLFW_KEY_ESCAPE, 0, 0, 0);
    }
}
