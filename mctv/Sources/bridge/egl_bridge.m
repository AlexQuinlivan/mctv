// The GLFW fork's window and context calls (pojav*), which lwjgl.jar's
// GLFW.Functions looks up with dlsym(RTLD_DEFAULT).
// Derived from Amethyst-iOS (GPLv3) Natives/egl_bridge.m, OpenGL ES path only.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "bridge.h"
#import "../JVM.h"


static int clientAPI = GLFW_OPENGL_API;

// The library LWJGL loads GL functions from (org.lwjgl.opengl.libname).
const char *MCRendererLibrary(void) {
    const char *r = getenv("MCTV_RENDERER");
    return (r && !strcmp(r, "angle")) ? "libtinygl4angle.dylib" : "libmobileglues.dylib";
}

static bool initOpenGL(void) {
    const char *lib = MCRendererLibrary();
    setenv("RENDERER", lib, 1);
    MCLog(@"bridge: renderer %s", lib);
    // Preload the renderer so LWJGL's dlopen by name finds it already loaded.
    char path[256];
    snprintf(path, sizeof(path), "@rpath/%s", lib);
    if (!dlopen(path, RTLD_GLOBAL)) MCLog(@"bridge: dlopen %s failed: %s", lib, dlerror());
    return gl_init();
}

MC_EXPORT int pojavInit(bool useStackQueue) {
    clientAPI = GLFW_OPENGL_API;
    isInputReady = true;
    isUseStackQueueCall = useStackQueue;
    MCLog(@"bridge: glfwInit (stack queue %d)", useStackQueue);
    return JNI_TRUE;
}

MC_EXPORT void pojavTerminate(void) {
    CallbackBridge_nativeSetInputReady(false);
    gl_terminate();
}

MC_EXPORT void *pojavGetCurrentContext(void) {
    return gl_get_current();
}

MC_EXPORT void pojavSetWindowHint(int hint, int value) {
    if (hint == GLFW_CLIENT_API) clientAPI = value;
}

MC_EXPORT void *pojavCreateContext(void *share) {
    if (clientAPI == GLFW_NO_API) {
        MCLog(@"bridge: the game asked for Vulkan, which this path doesn't support");
        return NULL;
    }
    static bool inited;
    if (!inited) {
        inited = true;
        if (!initOpenGL()) {
            MCLog(@"bridge: OpenGL init failed");
            return NULL;
        }
    }
    return gl_init_context(share);
}

MC_EXPORT void pojavMakeCurrent(void *window) {
    gl_make_current(window);
}

MC_EXPORT void pojavSwapBuffers(void) {
    gl_swap_buffers();
}

MC_EXPORT void pojavSwapInterval(int interval) {
    gl_swap_interval(interval);
}
