// Turns controllers, keyboards and the Siri Remote into Minecraft's input
// (keys, mouse buttons, pointer, scroll and typed characters), through SDL.
//
// Game controllers (extended gamepads) have two modes that follow Minecraft's
// mouse grab.
//   playing (mouse grabbed): left stick = WASD, right stick = look,
//     RT attack, LT use, A jump, B drop, X swap hands, Y inventory,
//     LB/RB and d-pad left/right = hotbar, L3 sprint, R3 sneak,
//     d-pad up = camera (F5), d-pad down = chat, Menu = pause, Options = player list.
//   menus (mouse free): left stick moves an on-screen pointer, A/RT click,
//     X/LT right-click, hold Y = Shift (quick-move), B/Menu = back (Esc),
//     d-pad = arrow keys, Options = Enter, right stick / LB / RB = scroll.
//
// Keyboards (Bluetooth on the TV, the Mac's keyboard in the simulator) send
// every key straight to Minecraft, with typed characters (US layout) and key
// repeat in menus and text fields.
//
// The Siri Remote's touch surface moves the pointer in menus and looks around
// while playing. Click = left click, Play/Pause = right click, Back = Esc.
//
// The scripted test (-inputtest) drives a virtual pad and can type.
#pragma once
#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, MCButton) {
    MCButtonA, MCButtonB, MCButtonX, MCButtonY,
    MCButtonLB, MCButtonRB, MCButtonLT, MCButtonRT,
    MCButtonL3, MCButtonR3,
    MCButtonUp, MCButtonDown, MCButtonLeft, MCButtonRight,
    MCButtonMenu, MCButtonOptions,
    MCButtonCount
};

@interface MCInput : NSObject
// `pointer` is shown over the game in menus. `scale` is game pixels per view point.
- (instancetype)initWithPointer:(UIView *)pointer scale:(CGFloat)scale;
- (void)start;  // device discovery + 60 Hz tick on the main thread

// UIKit fallbacks, for keyboards and remotes that reach the view controller
// instead of the Game Controller framework. Returns NO for presses it ignores.
- (BOOL)handlePress:(UIPress *)press down:(BOOL)down;
- (void)touchMovedBy:(CGPoint)delta;   // Siri Remote touch surface, in view points

// The virtual pad for the scripted test. Physical controllers overwrite it every tick.
- (void)setButton:(MCButton)button pressed:(BOOL)pressed;
- (void)setLeftStick:(CGPoint)value;   // x right, y up, -1...1
- (void)setRightStick:(CGPoint)value;
// Puts the pointer at game pixel (x, y).
- (void)movePointerTo:(CGPoint)pixel;

// Runs a scripted input test (see MCInputTest in MCInput.m) once the game is up.
- (void)runTestScript:(NSString *)script;
@end
