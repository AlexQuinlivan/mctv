// The interface between MCTV and its SDL video backend (SDL_mctvvideo.m), for
// Minecraft 26.x, which uses SDL 3 instead of GLFW.
//
// scripts/build-sdl.sh copies the backend and this header into SDL's source
// and builds libSDL3 for tvOS. When SDL starts its video subsystem, the
// backend looks up mctv_sdl_host() in the app with dlsym and does everything
// through the table it returns. That covers the screen, input from MCInput,
// the OpenGL context (MobileGlues on ANGLE) and the Metal layer for Vulkan
// (MoltenVK).
#pragma once

#include <stdbool.h>

#define MCTV_SDL_HOST_VERSION 1

enum {
    MCTV_SDL_KEY = 1,   // code: SDL scancode (USB HID usage), down
    MCTV_SDL_TEXT,      // text: UTF-8
    MCTV_SDL_MOVE,      // x, y: pointer position in pixels
    MCTV_SDL_MOVE_BY,   // x, y: change, while the mouse is captured for playing
    MCTV_SDL_BUTTON,    // code: 1 left, 2 middle, 3 right, and down
    MCTV_SDL_WHEEL,     // x, y: scroll amount
};

typedef struct {
    int type;
    int code;
    int down;
    float x, y;
    char text[16];
} MCTVSDLEvent;

typedef struct {
    int version;
    void (*screen)(int *w, int *h, float *hz);
    bool (*poll)(MCTVSDLEvent *event);
    void *(*metal_layer)(void);            // CAMetalLayer *
    const char *(*gl_library)(void);       // the desktop GL library LWJGL also uses
    void *(*gl_create)(void);
    bool (*gl_make_current)(void *context);
    void (*gl_swap)(void);
    void (*gl_swap_interval)(int interval);
    void (*gl_destroy)(void *context);
    void (*relative_mouse)(bool on);       // captured for playing, or a pointer for menus
    void (*warp)(float x, float y);        // Minecraft moved the pointer
    void (*text_input)(bool on);
    void (*log)(const char *message);
} MCTVSDLHost;

typedef const MCTVSDLHost *(*MCTVSDLHostFunction)(void);
