/*
 * MCTV's SDL video backend, for Minecraft 26.x on tvOS 27.
 *
 * One full-screen window on the app's game layer. SDL's own UIKit backend
 * would make its own window and view, take presses and focus from the app's
 * Siri Remote and controller handling, and call UIKit from Minecraft's
 * thread. This backend asks the app (mctv_sdl.h) for everything instead. That
 * covers the screen size, input events from MCInput, an OpenGL context from
 * the app's MobileGlues-on-ANGLE code, and the CAMetalLayer that MoltenVK
 * draws Vulkan into.
 *
 * scripts/build-sdl.sh copies this file into src/video/uikit/, so SDL's tvOS
 * build compiles it with the UIKit sources, and registers MCTV_bootstrap
 * ahead of UIKit's. If the app has no mctv_sdl_host(), the backend reports
 * itself unavailable and SDL carries on with UIKit's.
 *
 * The Vulkan loading follows SDL_uikitvulkan.m (zlib licence, as SDL).
 */
#include "SDL_internal.h"

#if defined(SDL_VIDEO_DRIVER_UIKIT) && defined(SDL_PLATFORM_TVOS)

#include "../SDL_sysvideo.h"
#include "../../events/SDL_keyboard_c.h"
#include "../../events/SDL_mouse_c.h"
#include "../../events/SDL_windowevents_c.h"
#include "mctv_sdl.h"

#ifdef SDL_VIDEO_VULKAN
#include "../SDL_vulkan_internal.h"
#endif

#include <dlfcn.h>

static const MCTVSDLHost *host;

static void Log(const char *fmt, ...)
{
    char buf[512];
    va_list ap;
    va_start(ap, fmt);
    SDL_vsnprintf(buf, sizeof(buf), fmt, ap);
    va_end(ap);
    if (host) {
        host->log(buf);
    }
}

// -- display and window ---------------------------------------------------------

static bool MCTV_VideoInit(SDL_VideoDevice *_this);
static void MCTV_VideoQuit(SDL_VideoDevice *_this);

static void ScreenSize(int *w, int *h, float *hz)
{
    *w = 1920;
    *h = 1080;
    *hz = 60.0f;
    host->screen(w, h, hz);
}

static bool MCTV_SetDisplayMode(SDL_VideoDevice *_this, SDL_VideoDisplay *display, SDL_DisplayMode *mode)
{
    return true;
}

static bool MCTV_CreateWindow(SDL_VideoDevice *_this, SDL_Window *window, SDL_PropertiesID create_props)
{
    int w, h;
    float hz;
    ScreenSize(&w, &h, &hz);
    // The TV has one screen and the game always fills it. The window keeps the
    // size the game asked for until the first event pump resizes it (FitWindow),
    // so the game hears a resize and lays out its menus and mouse for the screen.
    window->x = 0;
    window->y = 0;
    Log("SDL: window \"%s\" %dx%d, resized to %dx%d", window->title ? window->title : "", window->w, window->h, w, h);
    return true;
}

static void MCTV_ShowWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    SDL_SetMouseFocus(window);
    SDL_SetKeyboardFocus(window);
}

// Sends a resize when the window isn't the screen's size (SDL drops it when it is).
static void FitWindow(SDL_Window *window)
{
    int w, h;
    float hz;
    ScreenSize(&w, &h, &hz);
    if (window->w != w || window->h != h) {
        SDL_SendWindowEvent(window, SDL_EVENT_WINDOW_RESIZED, w, h);
    }
}

static void MCTV_SetWindowSize(SDL_VideoDevice *_this, SDL_Window *window)
{
    FitWindow(window);
}

static void MCTV_GetWindowSizeInPixels(SDL_VideoDevice *_this, SDL_Window *window, int *w, int *h)
{
    *w = window->w;
    *h = window->h;
}

static SDL_FullscreenResult MCTV_SetWindowFullscreen(SDL_VideoDevice *_this, SDL_Window *window, SDL_VideoDisplay *display, SDL_FullscreenOp fullscreen)
{
    return SDL_FULLSCREEN_SUCCEEDED;
}

static void MCTV_DestroyWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
}

static bool MCTV_SuspendScreenSaver(SDL_VideoDevice *_this)
{
    return true;  // MCInput keeps the TV awake while there's input
}

// -- input --------------------------------------------------------------------------

// With MCTV_SDL_DEBUG=1, logs the mouse and keyboard events SDL hands the game.
static bool SDLCALL DebugWatch(void *userdata, SDL_Event *event)
{
    switch (event->type) {
    case SDL_EVENT_MOUSE_MOTION:
        Log("SDL debug: motion window %u at %.0f,%.0f by %.0f,%.0f", (unsigned)event->motion.windowID,
            event->motion.x, event->motion.y, event->motion.xrel, event->motion.yrel);
        break;
    case SDL_EVENT_MOUSE_BUTTON_DOWN:
    case SDL_EVENT_MOUSE_BUTTON_UP:
        Log("SDL debug: button %d %s window %u at %.0f,%.0f", event->button.button,
            event->button.down ? "down" : "up", (unsigned)event->button.windowID, event->button.x, event->button.y);
        break;
    case SDL_EVENT_KEY_DOWN:
    case SDL_EVENT_KEY_UP:
        Log("SDL debug: key %d %s window %u", event->key.scancode, event->key.down ? "down" : "up", (unsigned)event->key.windowID);
        break;
    case SDL_EVENT_WINDOW_FOCUS_GAINED:
    case SDL_EVENT_WINDOW_FOCUS_LOST:
    case SDL_EVENT_WINDOW_MOUSE_ENTER:
    case SDL_EVENT_WINDOW_MOUSE_LEAVE:
        Log("SDL debug: window event 0x%x window %u", event->type, (unsigned)event->window.windowID);
        break;
    default:
        break;
    }
    return true;
}

static void DebugState(SDL_Window *window, const char *what)
{
    float x = 0, y = 0;
    SDL_MouseButtonFlags b = SDL_GetMouseState(&x, &y);
    SDL_Window *mf = SDL_GetMouseFocus(), *kf = SDL_GetKeyboardFocus();
    Log("SDL debug: %s, window %u %dx%d flags 0x%llx, mouse focus %u, keyboard focus %u, mouse %.0f,%.0f buttons 0x%x",
        what, (unsigned)window->id, window->w, window->h, (unsigned long long)window->flags,
        mf ? (unsigned)mf->id : 0, kf ? (unsigned)kf->id : 0, x, y, (unsigned)b);
}

static void MCTV_PumpEvents(SDL_VideoDevice *_this)
{
    SDL_Window *window = _this->windows;
    MCTVSDLEvent e;
    if (!window) {
        while (host->poll(&e)) {  // nothing to send it to yet
        }
        return;
    }
    FitWindow(window);
    if (SDL_GetKeyboardFocus() != window) {
        SDL_SetKeyboardFocus(window);
    }
    if (SDL_GetMouseFocus() != window) {
        SDL_SetMouseFocus(window);
    }
    static int debug = -1;
    if (debug < 0) {
        debug = SDL_getenv("MCTV_SDL_DEBUG") != NULL;
        if (debug) {
            SDL_AddEventWatch(DebugWatch, NULL);
            DebugState(window, "first pump");
        }
    }
    while (host->poll(&e)) {
        if (debug && e.type == MCTV_SDL_BUTTON) {
            DebugState(window, e.down ? "before button down" : "before button up");
        }
        switch (e.type) {
        case MCTV_SDL_KEY:
            SDL_SendKeyboardKey(0, SDL_DEFAULT_KEYBOARD_ID, e.code, (SDL_Scancode)e.code, e.down != 0);
            break;
        case MCTV_SDL_TEXT:
            e.text[sizeof(e.text) - 1] = '\0';
            SDL_SendKeyboardText(e.text);
            break;
        case MCTV_SDL_MOVE:
            SDL_SendMouseMotion(0, window, SDL_DEFAULT_MOUSE_ID, false, e.x, e.y);
            break;
        case MCTV_SDL_MOVE_BY:
            SDL_SendMouseMotion(0, window, SDL_DEFAULT_MOUSE_ID, true, e.x, e.y);
            break;
        case MCTV_SDL_BUTTON:
            SDL_SendMouseButton(0, window, SDL_DEFAULT_MOUSE_ID, (Uint8)e.code, e.down != 0);
            break;
        case MCTV_SDL_WHEEL:
            SDL_SendMouseWheel(0, window, SDL_DEFAULT_MOUSE_ID, e.x, e.y, SDL_MOUSEWHEEL_NORMAL);
            break;
        default:
            break;
        }
    }
}

static bool MCTV_StartTextInput(SDL_VideoDevice *_this, SDL_Window *window, SDL_PropertiesID props)
{
    host->text_input(true);
    return true;
}

static bool MCTV_StopTextInput(SDL_VideoDevice *_this, SDL_Window *window)
{
    host->text_input(false);
    return true;
}

// The app draws its own pointer, so cursors are placeholders.
static SDL_Cursor *NewCursor(void)
{
    return (SDL_Cursor *)SDL_calloc(1, sizeof(SDL_Cursor));
}

static SDL_Cursor *MCTV_CreateCursor(SDL_Surface *surface, int hot_x, int hot_y)
{
    return NewCursor();
}

static SDL_Cursor *MCTV_CreateSystemCursor(SDL_SystemCursor id)
{
    return NewCursor();
}

static bool MCTV_ShowCursor(SDL_Cursor *cursor)
{
    return true;
}

static void MCTV_FreeCursor(SDL_Cursor *cursor)
{
    SDL_free(cursor);
}

static bool MCTV_WarpMouse(SDL_Window *window, float x, float y)
{
    host->warp(x, y);
    SDL_SendMouseMotion(0, window, SDL_GLOBAL_MOUSE_ID, false, x, y);
    return true;
}

static bool MCTV_SetRelativeMouseMode(bool enabled)
{
    host->relative_mouse(enabled);
    return true;
}

// -- OpenGL (MobileGlues on ANGLE, through the app) -------------------------------------

// Minecraft checks that SDL and LWJGL resolve glGetError to the same address.
// LWJGL on "macOS" asks the GL library's own eglGetProcAddress first (or
// OSMesaGetProcAddress), then falls back to the symbol, so this does too.
typedef SDL_FunctionPointer (*GetProcAddressFunction)(const char *name);
static GetProcAddressFunction libraryGetProcAddress;

static bool MCTV_GL_LoadLibrary(SDL_VideoDevice *_this, const char *path)
{
    if (!path) {
        path = host->gl_library();
    }
    if (!path) {
        return SDL_SetError("the app has no OpenGL library");
    }
    _this->gl_config.dll_handle = SDL_LoadObject(path);
    if (!_this->gl_config.dll_handle) {
        Log("SDL: couldn't load OpenGL from %s: %s", path, SDL_GetError());
        return false;
    }
    SDL_strlcpy(_this->gl_config.driver_path, path, sizeof(_this->gl_config.driver_path));
    libraryGetProcAddress = (GetProcAddressFunction)SDL_LoadFunction(_this->gl_config.dll_handle, "eglGetProcAddress");
    if (!libraryGetProcAddress) {
        libraryGetProcAddress = (GetProcAddressFunction)SDL_LoadFunction(_this->gl_config.dll_handle, "OSMesaGetProcAddress");
    }
    SDL_ClearError();  // a missing lookup function isn't an error
    Log("SDL: OpenGL from %s", path);
    return true;
}

static SDL_FunctionPointer MCTV_GL_GetProcAddress(SDL_VideoDevice *_this, const char *proc)
{
    SDL_FunctionPointer f = NULL;
    if (!_this->gl_config.dll_handle) {
        return NULL;
    }
    if (libraryGetProcAddress) {
        f = libraryGetProcAddress(proc);
    }
    return f ? f : SDL_LoadFunction(_this->gl_config.dll_handle, proc);
}

static void MCTV_GL_UnloadLibrary(SDL_VideoDevice *_this)
{
    if (_this->gl_config.dll_handle) {
        SDL_UnloadObject(_this->gl_config.dll_handle);
        _this->gl_config.dll_handle = NULL;
    }
    libraryGetProcAddress = NULL;
}

static SDL_GLContext MCTV_GL_CreateContext(SDL_VideoDevice *_this, SDL_Window *window)
{
    void *context = host->gl_create();
    if (!context) {
        SDL_SetError("the app couldn't make an OpenGL context");
        return NULL;
    }
    if (!host->gl_make_current(context)) {
        host->gl_destroy(context);
        SDL_SetError("the app couldn't make its OpenGL context current");
        return NULL;
    }
    return (SDL_GLContext)context;
}

static bool MCTV_GL_MakeCurrent(SDL_VideoDevice *_this, SDL_Window *window, SDL_GLContext context)
{
    return host->gl_make_current((void *)context) ? true : SDL_SetError("couldn't make the OpenGL context current");
}

static int swapInterval = 1;

static bool MCTV_GL_SetSwapInterval(SDL_VideoDevice *_this, int interval)
{
    swapInterval = interval;
    host->gl_swap_interval(interval);
    return true;
}

static bool MCTV_GL_GetSwapInterval(SDL_VideoDevice *_this, int *interval)
{
    *interval = swapInterval;
    return true;
}

static bool MCTV_GL_SwapWindow(SDL_VideoDevice *_this, SDL_Window *window)
{
    host->gl_swap();
    return true;
}

static bool MCTV_GL_DestroyContext(SDL_VideoDevice *_this, SDL_GLContext context)
{
    host->gl_destroy((void *)context);
    return true;
}

// -- Vulkan (MoltenVK on the app's Metal layer) -------------------------------------------

#ifdef SDL_VIDEO_VULKAN

static bool MCTV_Vulkan_LoadLibrary(SDL_VideoDevice *_this, const char *path)
{
    VkExtensionProperties *extensions = NULL;
    Uint32 count = 0;
    bool surface = false, metal = false;
    PFN_vkGetInstanceProcAddr getProc;

    if (_this->vulkan_config.loader_handle) {
        return SDL_SetError("Vulkan is already loaded");
    }
    if (!path) {
        path = SDL_GetHint(SDL_HINT_VULKAN_LIBRARY);
    }
    if (!path) {
        path = "libMoltenVK.dylib";  // in the app's Frameworks, found through @rpath
    }
    _this->vulkan_config.loader_handle = SDL_LoadObject(path);
    if (!_this->vulkan_config.loader_handle) {
        return SDL_SetError("couldn't load %s", path);
    }
    SDL_strlcpy(_this->vulkan_config.loader_path, path, SDL_arraysize(_this->vulkan_config.loader_path));
    getProc = (PFN_vkGetInstanceProcAddr)SDL_LoadFunction(_this->vulkan_config.loader_handle, "vkGetInstanceProcAddr");
    if (!getProc) {
        SDL_SetError("%s has no vkGetInstanceProcAddr", path);
        goto fail;
    }
    _this->vulkan_config.vkGetInstanceProcAddr = (void *)getProc;
    _this->vulkan_config.vkEnumerateInstanceExtensionProperties =
        (void *)getProc(VK_NULL_HANDLE, "vkEnumerateInstanceExtensionProperties");
    if (!_this->vulkan_config.vkEnumerateInstanceExtensionProperties) {
        SDL_SetError("no vkEnumerateInstanceExtensionProperties");
        goto fail;
    }
    extensions = SDL_Vulkan_CreateInstanceExtensionsList(
        (PFN_vkEnumerateInstanceExtensionProperties)_this->vulkan_config.vkEnumerateInstanceExtensionProperties,
        &count);
    if (!extensions) {
        goto fail;
    }
    for (Uint32 i = 0; i < count; i++) {
        if (SDL_strcmp(VK_KHR_SURFACE_EXTENSION_NAME, extensions[i].extensionName) == 0) {
            surface = true;
        } else if (SDL_strcmp(VK_EXT_METAL_SURFACE_EXTENSION_NAME, extensions[i].extensionName) == 0) {
            metal = true;
        }
    }
    SDL_free(extensions);
    if (!surface || !metal) {
        SDL_SetError("%s lacks " VK_KHR_SURFACE_EXTENSION_NAME " or " VK_EXT_METAL_SURFACE_EXTENSION_NAME, path);
        goto fail;
    }
    Log("SDL: Vulkan from %s", path);
    return true;

fail:
    SDL_UnloadObject(_this->vulkan_config.loader_handle);
    _this->vulkan_config.loader_handle = NULL;
    return false;
}

static void MCTV_Vulkan_UnloadLibrary(SDL_VideoDevice *_this)
{
    if (_this->vulkan_config.loader_handle) {
        SDL_UnloadObject(_this->vulkan_config.loader_handle);
        _this->vulkan_config.loader_handle = NULL;
    }
}

static char const *const *MCTV_Vulkan_GetInstanceExtensions(SDL_VideoDevice *_this, Uint32 *count)
{
    static const char *const extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME, VK_EXT_METAL_SURFACE_EXTENSION_NAME
    };
    if (count) {
        *count = SDL_arraysize(extensions);
    }
    return extensions;
}

static bool MCTV_Vulkan_CreateSurface(SDL_VideoDevice *_this, SDL_Window *window, VkInstance instance,
                                      const struct VkAllocationCallbacks *allocator, VkSurfaceKHR *surface)
{
    PFN_vkGetInstanceProcAddr getProc = (PFN_vkGetInstanceProcAddr)_this->vulkan_config.vkGetInstanceProcAddr;
    PFN_vkCreateMetalSurfaceEXT create;
    VkMetalSurfaceCreateInfoEXT info;
    VkResult result;
    void *layer;

    if (!_this->vulkan_config.loader_handle) {
        return SDL_SetError("Vulkan is not loaded");
    }
    create = (PFN_vkCreateMetalSurfaceEXT)getProc(instance, "vkCreateMetalSurfaceEXT");
    if (!create) {
        return SDL_SetError(VK_EXT_METAL_SURFACE_EXTENSION_NAME " is not enabled in the Vulkan instance");
    }
    layer = host->metal_layer();
    if (!layer) {
        return SDL_SetError("the app has no Metal layer");
    }
    SDL_zero(info);
    info.sType = VK_STRUCTURE_TYPE_METAL_SURFACE_CREATE_INFO_EXT;
    info.pLayer = (__bridge const CAMetalLayer *)layer;
    result = create(instance, &info, allocator, surface);
    if (result != VK_SUCCESS) {
        return SDL_SetError("vkCreateMetalSurfaceEXT failed: %s", SDL_Vulkan_GetResultString(result));
    }
    Log("SDL: Vulkan surface on the game layer");
    return true;
}

static void MCTV_Vulkan_DestroySurface(SDL_VideoDevice *_this, VkInstance instance, VkSurfaceKHR surface,
                                       const struct VkAllocationCallbacks *allocator)
{
    if (_this->vulkan_config.loader_handle) {
        SDL_Vulkan_DestroySurface_Internal(_this->vulkan_config.vkGetInstanceProcAddr, instance, surface, allocator);
    }
}

#endif // SDL_VIDEO_VULKAN

// -- setup ------------------------------------------------------------------------------------

static bool MCTV_VideoInit(SDL_VideoDevice *_this)
{
    SDL_DisplayMode mode;
    SDL_Mouse *mouse;
    int w, h;
    float hz;

    ScreenSize(&w, &h, &hz);
    SDL_zero(mode);
    mode.format = SDL_PIXELFORMAT_XRGB8888;
    mode.w = w;
    mode.h = h;
    mode.refresh_rate = hz;
    if (SDL_AddBasicVideoDisplay(&mode) == 0) {
        return false;
    }
    SDL_AddKeyboard(SDL_DEFAULT_KEYBOARD_ID, "MCTV keyboard");
    SDL_AddMouse(SDL_DEFAULT_MOUSE_ID, "MCTV pointer");

    mouse = SDL_GetMouse();
    mouse->CreateCursor = MCTV_CreateCursor;
    mouse->CreateSystemCursor = MCTV_CreateSystemCursor;
    mouse->ShowCursor = MCTV_ShowCursor;
    mouse->FreeCursor = MCTV_FreeCursor;
    mouse->WarpMouse = MCTV_WarpMouse;
    mouse->SetRelativeMouseMode = MCTV_SetRelativeMouseMode;
    SDL_SetDefaultCursor(NewCursor());

    Log("SDL: MCTV video backend, %dx%d at %.0f Hz", w, h, hz);
    return true;
}

static void MCTV_VideoQuit(SDL_VideoDevice *_this)
{
}

static void MCTV_DeleteDevice(SDL_VideoDevice *device)
{
    SDL_free(device);
}

static bool FindHost(void)
{
    MCTVSDLHostFunction find;
    if (host) {
        return true;
    }
    find = (MCTVSDLHostFunction)dlsym(RTLD_DEFAULT, "mctv_sdl_host");
    if (!find) {
        return false;
    }
    host = find();
    if (!host || host->version != MCTV_SDL_HOST_VERSION) {
        host = NULL;
        return false;
    }
    return true;
}

static SDL_VideoDevice *MCTV_CreateDevice(void)
{
    SDL_VideoDevice *device;

    if (!FindHost()) {
        return NULL;  // not inside MCTV, so let UIKit's backend run
    }
    device = (SDL_VideoDevice *)SDL_calloc(1, sizeof(SDL_VideoDevice));
    if (!device) {
        return NULL;
    }
    device->VideoInit = MCTV_VideoInit;
    device->VideoQuit = MCTV_VideoQuit;
    device->SetDisplayMode = MCTV_SetDisplayMode;
    device->PumpEvents = MCTV_PumpEvents;
    device->SuspendScreenSaver = MCTV_SuspendScreenSaver;
    device->CreateSDLWindow = MCTV_CreateWindow;
    device->ShowWindow = MCTV_ShowWindow;
    device->SetWindowSize = MCTV_SetWindowSize;
    device->GetWindowSizeInPixels = MCTV_GetWindowSizeInPixels;
    device->SetWindowFullscreen = MCTV_SetWindowFullscreen;
    device->DestroyWindow = MCTV_DestroyWindow;
    device->StartTextInput = MCTV_StartTextInput;
    device->StopTextInput = MCTV_StopTextInput;

    device->GL_LoadLibrary = MCTV_GL_LoadLibrary;
    device->GL_GetProcAddress = MCTV_GL_GetProcAddress;
    device->GL_UnloadLibrary = MCTV_GL_UnloadLibrary;
    device->GL_CreateContext = MCTV_GL_CreateContext;
    device->GL_MakeCurrent = MCTV_GL_MakeCurrent;
    device->GL_SetSwapInterval = MCTV_GL_SetSwapInterval;
    device->GL_GetSwapInterval = MCTV_GL_GetSwapInterval;
    device->GL_SwapWindow = MCTV_GL_SwapWindow;
    device->GL_DestroyContext = MCTV_GL_DestroyContext;

#ifdef SDL_VIDEO_VULKAN
    device->Vulkan_LoadLibrary = MCTV_Vulkan_LoadLibrary;
    device->Vulkan_UnloadLibrary = MCTV_Vulkan_UnloadLibrary;
    device->Vulkan_GetInstanceExtensions = MCTV_Vulkan_GetInstanceExtensions;
    device->Vulkan_CreateSurface = MCTV_Vulkan_CreateSurface;
    device->Vulkan_DestroySurface = MCTV_Vulkan_DestroySurface;
#endif

    device->free = MCTV_DeleteDevice;
    return device;
}

// Message boxes go to the log and answer with the default button, since
// there's nobody to click them and UIKit's would come from the wrong thread.
static bool MCTV_ShowMessageBox(const SDL_MessageBoxData *data, int *buttonID)
{
    int choice = data->numbuttons > 0 ? data->buttons[0].buttonID : -1;
    if (!FindHost()) {
        return false;
    }
    for (int i = 0; i < data->numbuttons; i++) {
        if (data->buttons[i].flags & SDL_MESSAGEBOX_BUTTON_RETURNKEY_DEFAULT) {
            choice = data->buttons[i].buttonID;
        }
    }
    Log("SDL message box: %s: %s", data->title ? data->title : "", data->message ? data->message : "");
    if (buttonID) {
        *buttonID = choice;
    }
    return true;
}

// SDL on Apple platforms refuses SDL_Init unless the app used SDL_main or
// called SDL_SetMainReady(). Minecraft does neither, so inside MCTV the
// library marks itself ready as it loads. LWJGL loads it on Minecraft's
// render thread, which then serves as SDL's main thread.
__attribute__((constructor)) static void MCTV_MarkMainReady(void)
{
    if (FindHost()) {
        SDL_SetMainReady();
    }
}

VideoBootStrap MCTV_bootstrap = {
    "mctv", "MCTV, the Apple TV app's game layer",
    MCTV_CreateDevice,
    MCTV_ShowMessageBox,
    false  // "preferred" entries are skipped when SDL_VIDEO_DRIVER names a driver
};

#endif // SDL_VIDEO_DRIVER_UIKIT && SDL_PLATFORM_TVOS
