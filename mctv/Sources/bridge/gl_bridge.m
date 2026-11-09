// EGL context on ANGLE (Metal), reached through Amethyst's libtinygl4angle,
// which links ANGLE's libEGL/libGLESv2 frameworks. Minecraft's desktop GL calls
// go to libmobileglues (LWJGL's org.lwjgl.opengl.libname), which translates
// them to GLES on this context.
// Derived from Amethyst-iOS (GPLv3) Natives/ctxbridges/gl_bridge.m.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <string.h>
#include "EGL/egl.h"
#include "bridge.h"
#import "../JVM.h"

struct gl_render_window {
    EGLConfig config;
    EGLContext context;
    EGLSurface surface;
};

static struct {
    PFNEGLBINDAPIPROC BindAPI;
    PFNEGLCHOOSECONFIGPROC ChooseConfig;
    PFNEGLCREATECONTEXTPROC CreateContext;
    PFNEGLCREATEWINDOWSURFACEPROC CreateWindowSurface;
    PFNEGLDESTROYCONTEXTPROC DestroyContext;
    PFNEGLDESTROYSURFACEPROC DestroySurface;
    PFNEGLGETDISPLAYPROC GetDisplay;
    PFNEGLGETCONFIGSPROC GetConfigs;
    PFNEGLGETCONFIGATTRIBPROC GetConfigAttrib;
    PFNEGLGETERRORPROC GetError;
    PFNEGLINITIALIZEPROC Initialize;
    PFNEGLMAKECURRENTPROC MakeCurrent;
    PFNEGLQUERYSTRINGPROC QueryString;
    PFNEGLRELEASETHREADPROC ReleaseThread;
    PFNEGLSWAPBUFFERSPROC SwapBuffers;
    PFNEGLSWAPINTERVALPROC SwapInterval;
    PFNEGLTERMINATEPROC Terminate;
} egl;

static EGLDisplay gDisplay;

static void dump_configs(void) {
    EGLConfig configs[64];
    EGLint n = 0;
    egl.GetConfigs(gDisplay, configs, 64, &n);
    MCLog(@"EGL: %d configs available:", n);
    for (EGLint i = 0; i < n; i++) {
        EGLint r, g, b, a, d, s, rt, st;
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_RED_SIZE, &r);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_GREEN_SIZE, &g);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_BLUE_SIZE, &b);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_ALPHA_SIZE, &a);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_DEPTH_SIZE, &d);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_STENCIL_SIZE, &s);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_RENDERABLE_TYPE, &rt);
        egl.GetConfigAttrib(gDisplay, configs[i], EGL_SURFACE_TYPE, &st);
        MCLog(@"  #%d rgba %d%d%d%d depth %d stencil %d renderable 0x%x surface 0x%x", i, r, g, b, a, d, s, rt, st);
    }
}
static __thread gl_render_window_t *gCurrent;

static bool load_egl(void) {
    void *h = dlopen("@rpath/libtinygl4angle.dylib", RTLD_GLOBAL);
    if (!h) {
        MCLog(@"EGL: dlopen libtinygl4angle failed: %s", dlerror());
        return false;
    }
#define SYM(name) egl.name = dlsym(h, "egl" #name); if (!egl.name) { MCLog(@"EGL: missing egl" #name); return false; }
    SYM(BindAPI) SYM(ChooseConfig) SYM(CreateContext) SYM(CreateWindowSurface)
    SYM(DestroyContext) SYM(DestroySurface) SYM(GetDisplay) SYM(GetError) SYM(GetConfigs) SYM(GetConfigAttrib)
    SYM(Initialize) SYM(MakeCurrent) SYM(QueryString) SYM(ReleaseThread)
    SYM(SwapBuffers) SYM(SwapInterval) SYM(Terminate)
#undef SYM
    return true;
}

bool gl_init(void) {
    if (!load_egl()) return false;
    gDisplay = egl.GetDisplay(EGL_DEFAULT_DISPLAY);
    if (gDisplay == EGL_NO_DISPLAY) {
        MCLog(@"EGL: eglGetDisplay returned EGL_NO_DISPLAY");
        return false;
    }
    EGLint major = 0, minor = 0;
    if (!egl.Initialize(gDisplay, &major, &minor)) {
        MCLog(@"EGL: eglInitialize failed: 0x%x", egl.GetError());
        return false;
    }
    MCLog(@"EGL %d.%d: %s / %s", major, minor,
          egl.QueryString(gDisplay, EGL_VENDOR), egl.QueryString(gDisplay, EGL_VERSION));
    return true;
}

gl_render_window_t *gl_init_context(gl_render_window_t *share) {
    if (!MCGameLayer) {
        MCLog(@"EGL: no game layer");
        return NULL;
    }
    gl_render_window_t *w = calloc(1, sizeof(*w));
    // "angle": ANGLE's own desktop-GL front end (Amethyst's tinygl4angle renderer).
    // "mobileglues" (default): a GLES 3 context, with MobileGlues translating desktop GL.
    const char *renderer = getenv("MCTV_RENDERER");
    bool desktopGL = renderer && !strcmp(renderer, "angle");
    const EGLint attribs[] = {
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 24,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT | EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, desktopGL ? EGL_OPENGL_BIT : EGL_OPENGL_ES3_BIT,
        EGL_NONE
    };
    EGLint n = 0;
    if (!egl.ChooseConfig(gDisplay, attribs, &w->config, 1, &n) || n < 1) {
        MCLog(@"EGL: no matching config: 0x%x", egl.GetError());
        dump_configs();
        free(w);
        return NULL;
    }
    if (!egl.BindAPI(desktopGL ? EGL_OPENGL_API : EGL_OPENGL_ES_API)) MCLog(@"EGL: eglBindAPI failed: 0x%x", egl.GetError());

    // Shared contexts (Minecraft's background loaders) render offscreen, but
    // ANGLE accepts a second window surface on the same layer, as on iOS.
    w->surface = egl.CreateWindowSurface(gDisplay, w->config, (EGLNativeWindowType)MCGameLayer, NULL);
    if (!w->surface) {
        MCLog(@"EGL: eglCreateWindowSurface failed: 0x%x", egl.GetError());
        free(w);
        return NULL;
    }
    const EGLint ctx_attribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    w->context = egl.CreateContext(gDisplay, w->config, share ? share->context : EGL_NO_CONTEXT, ctx_attribs);
    if (!w->context) {
        MCLog(@"EGL: eglCreateContext failed: 0x%x", egl.GetError());
        egl.DestroySurface(gDisplay, w->surface);
        free(w);
        return NULL;
    }
    MCStatus(MCLogQuiet, @"EGL: %s context %p created (shared with %p)", desktopGL ? "desktop GL" : "GLES 3", w->context, share ? share->context : NULL);
    static bool announced;
    if (!announced) {
        announced = true;
        MCStatus(MCLogOK, @"Graphics: %s on Metal through ANGLE", desktopGL ? "desktop OpenGL" : "OpenGL via MobileGlues, GLES 3");
    }
    return w;
}

void gl_make_current(gl_render_window_t *w) {
    if (!w) {
        if (egl.MakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT)) gCurrent = NULL;
        return;
    }
    if (egl.MakeCurrent(gDisplay, w->surface, w->surface, w->context)) {
        gCurrent = w;
    } else {
        MCLog(@"EGL: eglMakeCurrent failed: 0x%x", egl.GetError());
    }
}

gl_render_window_t *gl_get_current(void) { return gCurrent; }

void (*MCOnFirstFrame)(void);
volatile bool MCFirstFrameSeen;

void gl_swap_buffers(void) {
    if (!gCurrent) return;
    if (!egl.SwapBuffers(gDisplay, gCurrent->surface)) {
        static int reported;
        if (reported++ < 5) MCLog(@"EGL: eglSwapBuffers failed: 0x%x", egl.GetError());
        return;
    }
    static bool first = true;
    if (first) {
        first = false;
        MCFirstFrameSeen = true;
        MCStatus(MCLogOK, @"Game running: first frame drawn");
        if (MCOnFirstFrame) MCOnFirstFrame();
    }
}

void gl_swap_interval(int interval) {
    egl.SwapInterval(gDisplay, interval);
}

void gl_terminate(void) {
    egl.MakeCurrent(gDisplay, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (gCurrent) {
        egl.DestroySurface(gDisplay, gCurrent->surface);
        egl.DestroyContext(gDisplay, gCurrent->context);
        free(gCurrent);
        gCurrent = NULL;
    }
    egl.Terminate(gDisplay);
    egl.ReleaseThread();
}
