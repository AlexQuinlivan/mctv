// The app's side of SDL, which Minecraft uses for its window and input. MCTV's
// SDL video backend (mctv/sdl, built into libSDL3) finds mctv_sdl_host() with
// dlsym and does everything through it. MCInput's keys, buttons and pointer
// come in here and wait in a queue until Minecraft pumps events.
#pragma once

#include <stdbool.h>
#include "glfw_keycodes.h"  // MCInput's key and button codes, turned into SDL's here

// Set by the app before the game starts.
extern void *MCGameLayer;              // the CAMetalLayer MoltenVK draws into
extern int MCScreenWidth, MCScreenHeight;  // in pixels
extern int MCRefreshRate;
extern bool MCControllerToMods;        // Controlify reads the controller through SDL itself
extern void (*MCOnFirstFrame)(void);   // called once, on the render thread

// The game's state, for MCInput.
extern volatile bool MCFirstFrameSeen;
extern bool MCInputReady;              // SDL has started
extern bool MCMouseGrabbed;            // captured for playing, rather than a pointer for menus
extern double MCPointerX, MCPointerY;  // the pointer, in pixels

// Input from MCInput, in GLFW's key and button codes. A keyboard's own HID
// usage, when there is one, goes in scancode.
void MCSDLKey(int key, int scancode, bool down);
void MCSDLChar(unsigned int codepoint);  // UTF-16 code units
void MCSDLPointerTo(double x, double y);
void MCSDLPointerBy(double dx, double dy);  // while the mouse is grabbed
void MCSDLButton(int button, bool down);
void MCSDLScroll(double x, double y);
