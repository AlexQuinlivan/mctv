// The OpenGL library Minecraft 26.x loads on tvOS, in front of
// MobileGlues.
//
// LWJGL decides which OpenGL functions exist from glGetIntegerv with
// GL_MAJOR_VERSION and GL_MINOR_VERSION. MobileGlues 1.3.3 passes those to
// OpenGL ES, which answers 3.0, although its version string says 4.0. LWJGL
// then fills every OpenGL 3.1 to 3.3 function with a stub that aborts, and
// Minecraft dies at its first sampler (glGenSamplers). This library answers
// 3.3, which is what Minecraft asks for, and hands everything else to
// MobileGlues.
//
// LWJGL and SDL both look functions up through the GL library's
// eglGetProcAddress, and Minecraft checks that they get the same glGetError,
// so that's the only entry point. scripts/prepare-26.sh builds it.
#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define GL_MAJOR_VERSION 0x821B
#define GL_MINOR_VERSION 0x821C

typedef void (*Function)(void);

static void *mobileglues;
static Function (*mgGetProcAddress)(const char *name);
static void (*mgGetIntegerv)(unsigned int pname, int *data);

__attribute__((constructor)) static void Load(void)
{
    mobileglues = dlopen("@loader_path/libmobileglues.dylib", RTLD_NOW | RTLD_GLOBAL);
    if (!mobileglues) return;
    mgGetProcAddress = (Function (*)(const char *))dlsym(mobileglues, "eglGetProcAddress");
    mgGetIntegerv = (void (*)(unsigned int, int *))dlsym(mobileglues, "glGetIntegerv");
}

// With MCTV_GL_LOG_SHADERS=1, prints the start of each shader source.
static void (*mgShaderSource)(unsigned int shader, int count, const char *const *strings, const int *lengths);

static void ShaderSource(unsigned int shader, int count, const char *const *strings, const int *lengths)
{
    for (int i = 0; i < count && i < 4; i++) {
        int n = lengths && lengths[i] >= 0 ? lengths[i] : (int)strlen(strings[i]);
        fprintf(stderr, "mctv-gl: shader %u part %d/%d, %d bytes: %.*s\n----\n", shader, i + 1, count, n, n < 400 ? n : 400, strings[i]);
    }
    mgShaderSource(shader, count, strings, lengths);
}

static void GetIntegerv(unsigned int pname, int *data)
{
    mgGetIntegerv(pname, data);
    if (pname == GL_MAJOR_VERSION) *data = 3;
    else if (pname == GL_MINOR_VERSION) *data = 3;
}

__attribute__((visibility("default"))) Function eglGetProcAddress(const char *name)
{
    Function f = NULL;
    if (!mobileglues || !name) return NULL;
    if (!strcmp(name, "glGetIntegerv")) return mgGetIntegerv ? (Function)GetIntegerv : NULL;
    if (!strcmp(name, "glShaderSource") && getenv("MCTV_GL_LOG_SHADERS")) {
        mgShaderSource = (void (*)(unsigned int, int, const char *const *, const int *))dlsym(mobileglues, "glShaderSource");
        return mgShaderSource ? (Function)ShaderSource : NULL;
    }
    if (mgGetProcAddress) f = mgGetProcAddress(name);
    return f ? f : (Function)dlsym(mobileglues, name);
}
