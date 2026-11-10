#import "MCInput.h"
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import "Game.h"
#include "SDLHost.h"

typedef enum { ActNone, ActKey, ActMouse, ActScroll } ActKind;
typedef struct { ActKind kind; int code; } Action;  // key / mouse button / scroll direction

static const float kDeadzone = 0.12f;
static const float kLookSpeed = 28.0f;     // game pixels per 60 Hz frame at full deflection
static const float kPointerSpeed = 18.0f;  // game pixels per 60 Hz frame at full deflection
static const double kKeepAwake = 15 * 60;  // seconds after the last input that the screensaver stays off
static const float kTouchPointer = 700.0f; // game pixels per unit of Siri Remote touch travel (surface is 2 units wide)
static const float kTouchLook = 450.0f;
static const double kRepeatDelay = 0.45, kRepeatRate = 1.0 / 30;

// Siri Remote buttons. On the 2021+ remote the clickpad's outer ring is a
// digital d-pad (GCInputDirectionalCardinalDpad) and the inner circle a button
// (GCInputDirectionalCenterButton). Older remotes only click as a whole.
typedef enum { RemoteClick, RemotePlayPause, RemoteBack, RemoteUp, RemoteDown, RemoteLeft, RemoteRight, RemoteCount } RemoteButton;

static Action GameBinding(MCButton b) {
    switch (b) {
        case MCButtonA: return (Action){ActKey, GLFW_KEY_SPACE};          // jump
        case MCButtonB: return (Action){ActKey, GLFW_KEY_Q};              // drop
        case MCButtonX: return (Action){ActKey, GLFW_KEY_F};              // swap hands
        case MCButtonY: return (Action){ActKey, GLFW_KEY_E};              // inventory
        case MCButtonLB: return (Action){ActScroll, 1};                   // hotbar left
        case MCButtonRB: return (Action){ActScroll, -1};                  // hotbar right
        case MCButtonLT: return (Action){ActMouse, GLFW_MOUSE_BUTTON_RIGHT};  // use / place
        case MCButtonRT: return (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};   // attack / break
        case MCButtonL3: return (Action){ActKey, GLFW_KEY_LEFT_CONTROL};  // sprint
        case MCButtonR3: return (Action){ActKey, GLFW_KEY_LEFT_SHIFT};    // sneak
        case MCButtonUp: return (Action){ActKey, GLFW_KEY_F5};            // camera
        case MCButtonDown: return (Action){ActKey, GLFW_KEY_T};           // chat
        case MCButtonLeft: return (Action){ActScroll, 1};
        case MCButtonRight: return (Action){ActScroll, -1};
        case MCButtonMenu: return (Action){ActKey, GLFW_KEY_ESCAPE};      // pause
        case MCButtonOptions: return (Action){ActKey, GLFW_KEY_TAB};      // player list
        default: return (Action){ActNone, 0};
    }
}

static Action MenuBinding(MCButton b) {
    switch (b) {
        case MCButtonA: return (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};
        case MCButtonRT: return (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};
        case MCButtonX: return (Action){ActMouse, GLFW_MOUSE_BUTTON_RIGHT};
        case MCButtonLT: return (Action){ActMouse, GLFW_MOUSE_BUTTON_RIGHT};
        case MCButtonY: return (Action){ActKey, GLFW_KEY_LEFT_SHIFT};     // hold + A = quick-move
        case MCButtonB: return (Action){ActKey, GLFW_KEY_ESCAPE};
        case MCButtonMenu: return (Action){ActKey, GLFW_KEY_ESCAPE};
        case MCButtonOptions: return (Action){ActKey, GLFW_KEY_ENTER};
        case MCButtonLB: return (Action){ActScroll, 1};
        case MCButtonRB: return (Action){ActScroll, -1};
        case MCButtonUp: return (Action){ActKey, GLFW_KEY_DPAD_UP};
        case MCButtonDown: return (Action){ActKey, GLFW_KEY_DPAD_DOWN};
        case MCButtonLeft: return (Action){ActKey, GLFW_KEY_DPAD_LEFT};
        case MCButtonRight: return (Action){ActKey, GLFW_KEY_DPAD_RIGHT};
        default: return (Action){ActNone, 0};
    }
}

static Action RemoteBinding(RemoteButton b) {
    switch (b) {
        case RemoteClick: return (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};
        case RemotePlayPause: return (Action){ActMouse, GLFW_MOUSE_BUTTON_RIGHT};
        case RemoteBack: return (Action){ActKey, GLFW_KEY_ESCAPE};
        default: return (Action){ActNone, 0};
    }
}

static NSString *ButtonName(MCButton b) {
    static NSArray *names;
    if (!names) names = @[@"A", @"B", @"X", @"Y", @"LB", @"RB", @"LT", @"RT", @"L3", @"R3",
                          @"Up", @"Down", @"Left", @"Right", @"Menu", @"Options"];
    return b < (NSInteger)names.count ? names[b] : @"?";
}

static MCButton ButtonNamed(NSString *name) {
    for (NSInteger b = 0; b < MCButtonCount; b++)
        if ([ButtonName(b) caseInsensitiveCompare:name] == NSOrderedSame) return b;
    return MCButtonCount;
}

// Dead zone, then a mild curve. It gives fine aim near the centre without the
// sluggish-then-sudden feel of a squared curve.
static CGPoint Curve(CGPoint v) {
    double m = hypot(v.x, v.y);
    if (m < kDeadzone) return CGPointZero;
    double n = MIN(1.0, (m - kDeadzone) / (1.0 - kDeadzone));
    double k = pow(n, 1.5) / m;
    return CGPointMake(v.x * k, v.y * k);
}

// --- keyboard tables ---------------------------------------------------------
// Key codes are HID usages. GCKeyCode and UIKeyboardHIDUsage share the values.

static int GLFWKeyForHID(long u) {
    if (u >= UIKeyboardHIDUsageKeyboardA && u <= UIKeyboardHIDUsageKeyboardZ) return GLFW_KEY_A + (int)(u - UIKeyboardHIDUsageKeyboardA);
    if (u >= UIKeyboardHIDUsageKeyboard1 && u <= UIKeyboardHIDUsageKeyboard9) return GLFW_KEY_1 + (int)(u - UIKeyboardHIDUsageKeyboard1);
    if (u >= UIKeyboardHIDUsageKeyboardF1 && u <= UIKeyboardHIDUsageKeyboardF12) return GLFW_KEY_F1 + (int)(u - UIKeyboardHIDUsageKeyboardF1);
    if (u >= UIKeyboardHIDUsageKeypad1 && u <= UIKeyboardHIDUsageKeypad9) return GLFW_KEY_NUMPAD_1 + (int)(u - UIKeyboardHIDUsageKeypad1);
    switch (u) {
        case UIKeyboardHIDUsageKeyboard0: return GLFW_KEY_0;
        case UIKeyboardHIDUsageKeyboardReturnOrEnter: return GLFW_KEY_ENTER;
        case UIKeyboardHIDUsageKeyboardEscape: return GLFW_KEY_ESCAPE;
        case UIKeyboardHIDUsageKeyboardDeleteOrBackspace: return GLFW_KEY_BACKSPACE;
        case UIKeyboardHIDUsageKeyboardTab: return GLFW_KEY_TAB;
        case UIKeyboardHIDUsageKeyboardSpacebar: return GLFW_KEY_SPACE;
        case UIKeyboardHIDUsageKeyboardHyphen: return GLFW_KEY_MINUS;
        case UIKeyboardHIDUsageKeyboardEqualSign: return GLFW_KEY_EQUAL;
        case UIKeyboardHIDUsageKeyboardOpenBracket: return GLFW_KEY_LEFT_BRACKET;
        case UIKeyboardHIDUsageKeyboardCloseBracket: return GLFW_KEY_RIGHT_BRACKET;
        case UIKeyboardHIDUsageKeyboardBackslash: return GLFW_KEY_BACKSLASH;
        case UIKeyboardHIDUsageKeyboardNonUSPound: return GLFW_KEY_BACKSLASH;
        case UIKeyboardHIDUsageKeyboardSemicolon: return GLFW_KEY_SEMICOLON;
        case UIKeyboardHIDUsageKeyboardQuote: return GLFW_KEY_APOSTROPHE;
        case UIKeyboardHIDUsageKeyboardGraveAccentAndTilde: return GLFW_KEY_GRAVE_ACCENT;
        case UIKeyboardHIDUsageKeyboardComma: return GLFW_KEY_COMMA;
        case UIKeyboardHIDUsageKeyboardPeriod: return GLFW_KEY_PERIOD;
        case UIKeyboardHIDUsageKeyboardSlash: return GLFW_KEY_SLASH;
        case UIKeyboardHIDUsageKeyboardNonUSBackslash: return GLFW_KEY_WORLD_1;
        case UIKeyboardHIDUsageKeyboardCapsLock: return GLFW_KEY_CAPS_LOCK;
        case UIKeyboardHIDUsageKeyboardPrintScreen: return GLFW_KEY_PRINT_SCREEN;
        case UIKeyboardHIDUsageKeyboardScrollLock: return GLFW_KEY_SCROLL_LOCK;
        case UIKeyboardHIDUsageKeyboardPause: return GLFW_KEY_PAUSE;
        case UIKeyboardHIDUsageKeyboardInsert: return GLFW_KEY_INSERT;
        case UIKeyboardHIDUsageKeyboardHome: return GLFW_KEY_HOME;
        case UIKeyboardHIDUsageKeyboardPageUp: return GLFW_KEY_PAGE_UP;
        case UIKeyboardHIDUsageKeyboardDeleteForward: return GLFW_KEY_DELETE;
        case UIKeyboardHIDUsageKeyboardEnd: return GLFW_KEY_END;
        case UIKeyboardHIDUsageKeyboardPageDown: return GLFW_KEY_PAGE_DOWN;
        case UIKeyboardHIDUsageKeyboardRightArrow: return GLFW_KEY_DPAD_RIGHT;
        case UIKeyboardHIDUsageKeyboardLeftArrow: return GLFW_KEY_DPAD_LEFT;
        case UIKeyboardHIDUsageKeyboardDownArrow: return GLFW_KEY_DPAD_DOWN;
        case UIKeyboardHIDUsageKeyboardUpArrow: return GLFW_KEY_DPAD_UP;
        case UIKeyboardHIDUsageKeypadNumLock: return GLFW_KEY_NUM_LOCK;
        case UIKeyboardHIDUsageKeypadSlash: return GLFW_KEY_NUMPAD_DIVIDE;
        case UIKeyboardHIDUsageKeypadAsterisk: return GLFW_KEY_NUMPAD_MULTIPLY;
        case UIKeyboardHIDUsageKeypadHyphen: return GLFW_KEY_NUMPAD_SUBTRACT;
        case UIKeyboardHIDUsageKeypadPlus: return GLFW_KEY_NUMPAD_ADD;
        case UIKeyboardHIDUsageKeypadEnter: return GLFW_KEY_NUMPAD_ENTER;
        case UIKeyboardHIDUsageKeypad0: return GLFW_KEY_NUMPAD_0;
        case UIKeyboardHIDUsageKeypadPeriod: return GLFW_KEY_NUMPAD_DECIMAL;
        case UIKeyboardHIDUsageKeypadEqualSign: return GLFW_KEY_NUMPAD_EQUAL;
        case UIKeyboardHIDUsageKeyboardApplication: return GLFW_KEY_MENU;
        case UIKeyboardHIDUsageKeyboardLeftControl: return GLFW_KEY_LEFT_CONTROL;
        case UIKeyboardHIDUsageKeyboardLeftShift: return GLFW_KEY_LEFT_SHIFT;
        case UIKeyboardHIDUsageKeyboardLeftAlt: return GLFW_KEY_LEFT_ALT;
        case UIKeyboardHIDUsageKeyboardLeftGUI: return GLFW_KEY_LEFT_SUPER;
        case UIKeyboardHIDUsageKeyboardRightControl: return GLFW_KEY_RIGHT_CONTROL;
        case UIKeyboardHIDUsageKeyboardRightShift: return GLFW_KEY_RIGHT_SHIFT;
        case UIKeyboardHIDUsageKeyboardRightAlt: return GLFW_KEY_RIGHT_ALT;
        case UIKeyboardHIDUsageKeyboardRightGUI: return GLFW_KEY_RIGHT_SUPER;
        default: return 0;
    }
}

static int ModifierBit(long u) {
    switch (u) {
        case UIKeyboardHIDUsageKeyboardLeftShift: case UIKeyboardHIDUsageKeyboardRightShift: return GLFW_MOD_SHIFT;
        case UIKeyboardHIDUsageKeyboardLeftControl: case UIKeyboardHIDUsageKeyboardRightControl: return GLFW_MOD_CONTROL;
        case UIKeyboardHIDUsageKeyboardLeftAlt: case UIKeyboardHIDUsageKeyboardRightAlt: return GLFW_MOD_ALT;
        case UIKeyboardHIDUsageKeyboardLeftGUI: case UIKeyboardHIDUsageKeyboardRightGUI: return GLFW_MOD_SUPER;
        default: return 0;
    }
}

// The character a key types on a US layout (0 = none).
static unichar CharForHID(long u, BOOL shift, BOOL caps) {
    if (u >= UIKeyboardHIDUsageKeyboardA && u <= UIKeyboardHIDUsageKeyboardZ) {
        unichar c = 'a' + (unichar)(u - UIKeyboardHIDUsageKeyboardA);
        return shift != caps ? c - 32 : c;
    }
    if (u >= UIKeyboardHIDUsageKeyboard1 && u <= UIKeyboardHIDUsageKeyboard0) {
        long i = u - UIKeyboardHIDUsageKeyboard1;
        return (shift ? "!@#$%^&*()" : "1234567890")[i];
    }
    if (u >= UIKeyboardHIDUsageKeyboardSpacebar && u <= UIKeyboardHIDUsageKeyboardSlash) {
        long i = u - UIKeyboardHIDUsageKeyboardSpacebar;   // space - = [ ] \ # ; ' ` , . /
        return (shift ? " _+{}|~:\"~<>?" : " -=[]\\#;'`,./")[i];
    }
    if (u >= UIKeyboardHIDUsageKeypad1 && u <= UIKeyboardHIDUsageKeypad0)
        return "1234567890"[u - UIKeyboardHIDUsageKeypad1];
    switch (u) {
        case UIKeyboardHIDUsageKeypadSlash: return '/';
        case UIKeyboardHIDUsageKeypadAsterisk: return '*';
        case UIKeyboardHIDUsageKeypadHyphen: return '-';
        case UIKeyboardHIDUsageKeypadPlus: return '+';
        case UIKeyboardHIDUsageKeypadPeriod: return '.';
        case UIKeyboardHIDUsageKeypadEqualSign: return '=';
        default: return 0;
    }
}

@implementation MCInput {
    UIView *_pointer;
    CGFloat _scale;
    CADisplayLink *_link;
    BOOL _pressed[MCButtonCount], _prev[MCButtonCount];
    float _lt, _rt;                  // analog triggers, 0...1
    BOOL _direct;                    // Controlify reads the controller itself, through SDL
    BOOL _focusNav;                  // menus driven by the d-pad, so A presses Enter and the pointer hides
    BOOL _pointerMoved;              // the user has moved the pointer at least once
    BOOL _remotePointer;             // the Siri Remote moved the pointer last (shown even when a mod drives the pad)
    double _touchTravel;             // how far the finger has moved since it touched down
    CFTimeInterval _lastInput, _lastTick;
    BOOL _keptAwake;
    // Menu-type buttons can go down and up between two frames (tvOS reports
    // Back on release), so polling misses them. Their handlers latch presses.
    BOOL _latch[MCButtonCount];
    Action _active[MCButtonCount];   // what each held button sent when pressed
    CGPoint _left, _right;
    BOOL _move[4];                   // W A S D held
    BOOL _wasGrabbing;
    int _scrollRepeat;
    GCController *_controller;
    // Siri Remote
    GCController *_remote;
    GCControllerDirectionPad *_ring;      // nil on remotes without the clickpad ring
    GCControllerButtonInput *_center;
    BOOL _remoteGC[RemoteCount], _remoteUI[RemoteCount], _remotePrev[RemoteCount], _remoteLatch[RemoteCount];
    Action _remoteActive[RemoteCount];
    BOOL _touching;
    CGPoint _touchLast;
    // keyboard
    BOOL _keyDown[256];
    BOOL _gcKeySeen[256];            // keys the Game Controller keyboard delivers (UIKit copies are then ignored)
    int _mods;
    long _repeatKey;
    CFTimeInterval _repeatAt;
    BOOL _loggedGCKey, _loggedUIKey;
    // scripted test
    NSMutableArray<NSString *> *_script;
    CFTimeInterval _scriptStart, _waitUntil;
    int _waitFrames;
    MCButton _tapButton;
    int _stickFrames;
}

- (instancetype)initWithPointer:(UIView *)pointer scale:(CGFloat)scale {
    if ((self = [super init])) {
        _pointer = pointer;
        _scale = scale;
        _tapButton = MCButtonCount;
    }
    return self;
}

- (void)start {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(controllersChanged) name:GCControllerDidDisconnectNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardChanged) name:GCKeyboardDidConnectNotification object:nil];
    [nc addObserver:self selector:@selector(keyboardChanged) name:GCKeyboardDidDisconnectNotification object:nil];
    [self controllersChanged];
    [self keyboardChanged];
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick)];
    _link.preferredFrameRateRange = CAFrameRateRangeMake(60, 60, 60);
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

- (void)controllersChanged {
    GCController *pad = nil, *remote = nil;
    for (GCController *c in GCController.controllers) {
        if (c.extendedGamepad) { if (!pad) pad = c; }
        else if (c.microGamepad) { if (!remote) remote = c; }  // the Siri Remote
    }
    if (pad != _controller) {
        _controller = pad;
        MCLog(@"input: %@", pad ? [NSString stringWithFormat:@"using controller \"%@\"", pad.vendorName] : @"no game controller");
        if (pad) {
            [self latch:pad.extendedGamepad.buttonMenu into:&_latch[MCButtonMenu] name:@"controller Menu"];
            [self latch:pad.extendedGamepad.buttonOptions into:&_latch[MCButtonOptions] name:@"controller Options"];
        }
        if (!pad) {
            memset(_pressed, 0, sizeof(_pressed));
            _left = _right = CGPointZero;
        }
    }
    if (remote != _remote) {
        _remote = remote;
        MCLog(@"input: %@", remote ? [NSString stringWithFormat:@"remote \"%@\"", remote.vendorName] : @"no remote");
        _ring = nil;
        _center = nil;
        if (remote) {
            GCMicroGamepad *m = remote.microGamepad;
            m.reportsAbsoluteDpadValues = YES;  // finger position, for trackpad-style movement
            m.allowsRotation = NO;
            GCPhysicalInputProfile *profile = remote.physicalInputProfile;
            _ring = profile.dpads[GCInputDirectionalCardinalDpad];
            _center = profile.buttons[GCInputDirectionalCenterButton];
            if (_ring && _center) {
                [self latch:_center into:&_remoteLatch[RemoteClick] name:nil];
                [self latch:_ring.up into:&_remoteLatch[RemoteUp] name:nil];
                [self latch:_ring.down into:&_remoteLatch[RemoteDown] name:nil];
                [self latch:_ring.left into:&_remoteLatch[RemoteLeft] name:nil];
                [self latch:_ring.right into:&_remoteLatch[RemoteRight] name:nil];
            } else {
                _ring = nil;
                _center = nil;
                [self latch:m.buttonA into:&_remoteLatch[RemoteClick] name:nil];
            }
            [self latch:m.buttonX into:&_remoteLatch[RemotePlayPause] name:@"remote Play/Pause"];
            [self latch:m.buttonMenu into:&_remoteLatch[RemoteBack] name:@"remote Back"];
            MCLog(@"input: remote %@", _ring ? @"has the clickpad ring (d-pad + centre)" : @"clicks as a whole");
        }
        memset(_remoteGC, 0, sizeof(_remoteGC));
        _touching = NO;
    }
}

// Latch presses from a button's handler so the next tick sees them even if
// the button was already released. `flag` points into this object.
- (void)latch:(GCControllerButtonInput *)button into:(BOOL *)flag name:(NSString *)name {
    if (!button) return;
    button.pressedChangedHandler = ^(GCControllerButtonInput *b, float value, BOOL pressed) {
        if (pressed) *flag = YES;
        if (name) MCLog(@"input: %@ %@", name, pressed ? @"down" : @"up");
    };
}

- (void)keyboardChanged {
    GCKeyboard *kb = GCKeyboard.coalescedKeyboard;
    MCLog(@"input: %@", kb ? @"keyboard connected" : @"no keyboard");
    if (!kb) {
        [self releaseKeys];
        return;
    }
    __weak typeof(self) weakSelf = self;
    kb.keyboardInput.keyChangedHandler = ^(GCKeyboardInput *input, GCDeviceButtonInput *key, GCKeyCode code, BOOL pressed) {
        MCInput *me = weakSelf;
        if (!me) return;
        if (!me->_loggedGCKey) { me->_loggedGCKey = YES; MCLog(@"input: first key from the Game Controller keyboard (0x%lx)", (long)code); }
        if (code == UIKeyboardHIDUsageKeyboardEscape) MCLog(@"input: Esc %@ (Game Controller keyboard)", pressed ? @"down" : @"up");
        if (code >= 0 && code < 256) me->_gcKeySeen[code] = YES;
        [me hidKey:code down:pressed];
    };
}

- (BOOL)handlePress:(UIPress *)press down:(BOOL)down {
    long code = press.key ? (long)press.key.keyCode : -1;
    if (press.type == UIPressTypeMenu || code == UIKeyboardHIDUsageKeyboardEscape)
        MCLog(@"input: UIKit press type %ld key 0x%lx %@", (long)press.type, code, down ? @"down" : @"up");
    if (press.key) {
        if (!_loggedUIKey) { _loggedUIKey = YES; MCLog(@"input: first key from UIKit (0x%lx)", code); }
        // Keyboards reach both UIKit and the Game Controller framework, at
        // slightly different times. Once a key has come through the latter,
        // ignore UIKit's copy so a quick tap isn't sent twice.
        if (code < 0 || code >= 256 || !_gcKeySeen[code]) [self hidKey:code down:down];
        return YES;
    }
    if (_remote && press.type != UIPressTypeMenu) return NO;  // the remote goes through the Game Controller framework
    switch (press.type) {
        case UIPressTypeSelect: _remoteUI[RemoteClick] = down; return YES;
        case UIPressTypeUpArrow: _remoteUI[RemoteUp] = down; if (down) _remoteLatch[RemoteUp] = YES; return YES;
        case UIPressTypeDownArrow: _remoteUI[RemoteDown] = down; if (down) _remoteLatch[RemoteDown] = YES; return YES;
        case UIPressTypeLeftArrow: _remoteUI[RemoteLeft] = down; if (down) _remoteLatch[RemoteLeft] = YES; return YES;
        case UIPressTypeRightArrow: _remoteUI[RemoteRight] = down; if (down) _remoteLatch[RemoteRight] = YES; return YES;
        case UIPressTypePlayPause: _remoteUI[RemotePlayPause] = down; return YES;
        case UIPressTypeMenu:  // never leave the app
            _remoteUI[RemoteBack] = down;
            if (down) _remoteLatch[RemoteBack] = YES;
            return YES;
        default: return NO;
    }
}

- (void)touchMovedBy:(CGPoint)delta {
    if (_remote) return;
    _lastInput = CACurrentMediaTime();
    _focusNav = NO;
    [self nudge:CGPointMake(delta.x * _scale, delta.y * _scale)];
}

- (void)setButton:(MCButton)button pressed:(BOOL)pressed { if (button < MCButtonCount) _pressed[button] = pressed; }
- (void)setLeftStick:(CGPoint)value { _left = value; }
- (void)setRightStick:(CGPoint)value { _right = value; }

- (void)movePointerTo:(CGPoint)p {
    MCSDLPointerTo(p.x, p.y);
}

// Move the pointer (menus) or turn the camera (playing) by d game pixels.
- (void)nudge:(CGPoint)d {
    if (d.x == 0 && d.y == 0) return;
    if (MCMouseGrabbed) {
        MCSDLPointerBy(d.x, d.y);
        return;
    }
    double x = MAX(0, MIN(MCScreenWidth - 1, MCPointerX + d.x));
    double y = MAX(0, MIN(MCScreenHeight - 1, MCPointerY + d.y));
    MCSDLPointerTo(x, y);
    _pointerMoved = YES;
}

- (void)readController {
    GCExtendedGamepad *g = _controller.extendedGamepad;
    if (!g) return;
    _pressed[MCButtonA] = g.buttonA.isPressed;
    _pressed[MCButtonB] = g.buttonB.isPressed;
    _pressed[MCButtonX] = g.buttonX.isPressed;
    _pressed[MCButtonY] = g.buttonY.isPressed;
    _pressed[MCButtonLB] = g.leftShoulder.isPressed;
    _pressed[MCButtonRB] = g.rightShoulder.isPressed;
    _pressed[MCButtonLT] = g.leftTrigger.isPressed;
    _pressed[MCButtonRT] = g.rightTrigger.isPressed;
    _pressed[MCButtonL3] = g.leftThumbstickButton.isPressed;
    _pressed[MCButtonR3] = g.rightThumbstickButton.isPressed;
    _pressed[MCButtonUp] = g.dpad.up.isPressed;
    _pressed[MCButtonDown] = g.dpad.down.isPressed;
    _pressed[MCButtonLeft] = g.dpad.left.isPressed;
    _pressed[MCButtonRight] = g.dpad.right.isPressed;
    _pressed[MCButtonMenu] = g.buttonMenu.isPressed || _latch[MCButtonMenu];
    _pressed[MCButtonOptions] = g.buttonOptions.isPressed || _latch[MCButtonOptions];
    _latch[MCButtonMenu] = _latch[MCButtonOptions] = NO;
    _left = CGPointMake(g.leftThumbstick.xAxis.value, g.leftThumbstick.yAxis.value);
    _right = CGPointMake(g.rightThumbstick.xAxis.value, g.rightThumbstick.yAxis.value);
    _lt = g.leftTrigger.value;
    _rt = g.rightTrigger.value;
}

// Controlify reads the controller through its own SDL. While it does, the key
// and mouse translation below stands down.
- (void)updateDirect {
    BOOL connected = _controller != nil || _script != nil;
    BOOL direct = connected && MCControllerToMods;
    if (direct == _direct) return;
    _direct = direct;
    MCLog(@"input: %@", direct ? @"a mod reads the controller directly, so key and mouse translation is off"
                               : @"controller back to key and mouse translation");
    for (NSInteger b = 0; b < MCButtonCount; b++) {  // let go of anything the translation holds
        if (_prev[b]) [self send:_active[b] down:NO];
        _active[b] = (Action){ActNone, 0};
        _prev[b] = direct ? _prev[b] : _pressed[b];
    }
    [self releaseMovement];
}

// The Siri Remote's touch surface works like a laptop trackpad, with relative
// movement while a finger is down.
- (void)readRemote {
    GCMicroGamepad *m = _remote.microGamepad;
    if (m) {
        _remoteGC[RemoteClick] = _center ? _center.isPressed : m.buttonA.isPressed;
        _remoteGC[RemoteUp] = _ring.up.isPressed;
        _remoteGC[RemoteDown] = _ring.down.isPressed;
        _remoteGC[RemoteLeft] = _ring.left.isPressed;
        _remoteGC[RemoteRight] = _ring.right.isPressed;
        _remoteGC[RemotePlayPause] = m.buttonX.isPressed;
        _remoteGC[RemoteBack] = m.buttonMenu.isPressed;
        CGPoint p = CGPointMake(m.dpad.xAxis.value, m.dpad.yAxis.value);
        BOOL touching = p.x != 0 || p.y != 0;
        if (touching && !_touching) _touchTravel = 0;
        if (touching && _touching) {
            double dx = p.x - _touchLast.x, dy = p.y - _touchLast.y;
            if (fabs(dx) < 0.5 && fabs(dy) < 0.5 && (dx != 0 || dy != 0)) {  // ignore jumps (finger lifted and put down elsewhere)
                double gain = MCMouseGrabbed ? kTouchLook : kTouchPointer;
                [self nudge:CGPointMake(dx * gain, -dy * gain)];
                _lastInput = CACurrentMediaTime();
                _touchTravel += hypot(dx, dy);
                if (_touchTravel > 0.06) { _focusNav = NO; _remotePointer = YES; }  // a swipe, not a click's wobble
            }
        }
        _touching = touching;
        _touchLast = p;
    }
    for (int b = 0; b < RemoteCount; b++) {
        BOOL down = _remoteGC[b] || _remoteUI[b] || _remoteLatch[b];
        _remoteLatch[b] = NO;
        if (down == _remotePrev[b]) continue;
        _remotePrev[b] = down;
        _lastInput = CACurrentMediaTime();
        if (down) {
            _remoteActive[b] = [self remoteAction:b];
            [self send:_remoteActive[b] down:YES];
        } else {
            [self send:_remoteActive[b] down:NO];
            _remoteActive[b] = (Action){ActNone, 0};
        }
    }
}

// What a Siri Remote press does, decided when it goes down. In menus the ring
// sends arrow keys, which move Controlify's highlight too, and the centre
// presses the highlighted button, or clicks at the pointer after a swipe.
- (Action)remoteAction:(RemoteButton)b {
    BOOL dir = b == RemoteUp || b == RemoteDown || b == RemoteLeft || b == RemoteRight;
    if (!dir && b != RemoteClick) return RemoteBinding(b);
    if (MCMouseGrabbed) {
        switch (b) {
            case RemoteLeft: return (Action){ActScroll, 1};                // hotbar
            case RemoteRight: return (Action){ActScroll, -1};
            case RemoteUp: return (Action){ActKey, GLFW_KEY_SPACE};        // jump
            case RemoteDown: return (Action){ActKey, GLFW_KEY_LEFT_SHIFT}; // sneak
            default: return (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};    // attack / break
        }
    }
    if (b == RemoteClick)
        return _focusNav ? (Action){ActKey, GLFW_KEY_ENTER} : (Action){ActMouse, GLFW_MOUSE_BUTTON_LEFT};
    _focusNav = YES;
    static const int key[] = {[RemoteUp] = GLFW_KEY_DPAD_UP, [RemoteRight] = GLFW_KEY_DPAD_RIGHT,
                              [RemoteDown] = GLFW_KEY_DPAD_DOWN, [RemoteLeft] = GLFW_KEY_DPAD_LEFT};
    return (Action){ActKey, key[b]};
}

- (void)send:(Action)a down:(BOOL)down {
    switch (a.kind) {
        case ActKey: MCSDLKey(a.code, 0, down); break;
        case ActMouse: MCSDLButton(a.code, down); break;
        case ActScroll: if (down) MCSDLScroll(0, a.code); break;
        case ActNone: break;
    }
}

// --- keyboard ----------------------------------------------------------------

- (void)hidKey:(long)code down:(BOOL)down {
    if (code < 0 || code >= 256 || _keyDown[code] == down) return;
    _keyDown[code] = down;
    _lastInput = CACurrentMediaTime();
    int bit = ModifierBit(code);
    if (bit) _mods = down ? (_mods | bit) : (_mods & ~bit);
    if (code == UIKeyboardHIDUsageKeyboardCapsLock && down) _mods ^= GLFW_MOD_CAPS_LOCK;
    int key = GLFWKeyForHID(code);
    if (!key) return;
    MCSDLKey(key, (int)code, down);
    if (down) {
        [self typeKey:code];
        if (!bit && code != UIKeyboardHIDUsageKeyboardCapsLock) {
            _repeatKey = code;
            _repeatAt = CACurrentMediaTime() + kRepeatDelay;
        }
    } else if (code == _repeatKey) {
        _repeatKey = 0;
    }
}

// Typed character for text fields (not for shortcuts like Ctrl/Cmd+V).
- (void)typeKey:(long)code {
    if (_mods & (GLFW_MOD_CONTROL | GLFW_MOD_SUPER)) return;
    unichar c = CharForHID(code, (_mods & GLFW_MOD_SHIFT) != 0, (_mods & GLFW_MOD_CAPS_LOCK) != 0);
    if (!c) return;
    MCSDLChar(c);
}

- (void)repeatKeys {
    if (!_repeatKey || MCMouseGrabbed) return;  // repeat is for menus and text fields
    CFTimeInterval now = CACurrentMediaTime();
    if (now < _repeatAt) return;
    _repeatAt = now + kRepeatRate;
    MCSDLKey(GLFWKeyForHID(_repeatKey), (int)_repeatKey, true);
    [self typeKey:_repeatKey];
}

- (void)releaseKeys {
    for (long code = 0; code < 256; code++)
        if (_keyDown[code]) [self hidKey:code down:NO];
    _mods = 0;
    _repeatKey = 0;
}

// Scripted typing (US layout).
- (void)typeText:(NSString *)text {
    for (NSUInteger i = 0; i < text.length; i++) {
        unichar c = [text characterAtIndex:i];
        long code = 0;
        BOOL shift = NO;
        for (long u = UIKeyboardHIDUsageKeyboardA; u <= UIKeyboardHIDUsageKeyboardSlash && !code; u++) {
            if (CharForHID(u, NO, NO) == c) code = u;
            else if (CharForHID(u, YES, NO) == c) { code = u; shift = YES; }
        }
        if (!code) continue;
        if (shift) [self hidKey:UIKeyboardHIDUsageKeyboardLeftShift down:YES];
        [self hidKey:code down:YES];
        [self hidKey:code down:NO];
        if (shift) [self hidKey:UIKeyboardHIDUsageKeyboardLeftShift down:NO];
    }
}

// --- per frame ---------------------------------------------------------------

- (void)releaseMovement {
    const int keys[4] = {GLFW_KEY_W, GLFW_KEY_A, GLFW_KEY_S, GLFW_KEY_D};
    for (int i = 0; i < 4; i++) {
        if (_move[i]) MCSDLKey(keys[i], 0, false);
        _move[i] = NO;
    }
}

- (void)setMove:(int)i key:(int)key amount:(double)v {
    BOOL want = _move[i] ? v > 0.35 : v > 0.5;  // hysteresis
    if (want != _move[i]) {
        _move[i] = want;
        MCSDLKey(key, 0, want);
    }
}

- (void)tick {
    CFTimeInterval now = CACurrentMediaTime();
    double frames = _lastTick ? MIN(4.0, (now - _lastTick) * 60.0) : 1.0;  // stick speeds are per 60 Hz frame
    _lastTick = now;
    if (_script) [self stepScript];
    else if (_controller) [self readController];
    [self updateDirect];

    BOOL grab = MCMouseGrabbed;
    if (grab != _wasGrabbing) {
        [self releaseMovement];
        _wasGrabbing = grab;
    }

    // The binding is chosen at press time, so the release always matches.
    for (NSInteger b = 0; b < MCButtonCount; b++) {
        if (_pressed[b] == _prev[b]) continue;
        _prev[b] = _pressed[b];
        _lastInput = now;
        if (_direct) { _remotePointer = NO; continue; }
        if (_pressed[b]) {
            Action a = grab ? GameBinding(b) : MenuBinding(b);
            if (!grab && (b == MCButtonUp || b == MCButtonDown || b == MCButtonLeft || b == MCButtonRight)) _focusNav = YES;
            if (!grab && b == MCButtonA && _focusNav) a = (Action){ActKey, GLFW_KEY_ENTER};  // press the highlighted button
            _active[b] = a;
            [self send:a down:YES];
        } else {
            [self send:_active[b] down:NO];
            _active[b] = (Action){ActNone, 0};
        }
    }

    CGPoint l = Curve(_left), r = Curve(_right);
    if (l.x || l.y || r.x || r.y || _lt > 0.1 || _rt > 0.1) _lastInput = now;
    if (!_direct) {
        if (grab) {
            [self setMove:0 key:GLFW_KEY_W amount:_left.y];
            [self setMove:1 key:GLFW_KEY_A amount:-_left.x];
            [self setMove:2 key:GLFW_KEY_S amount:-_left.y];
            [self setMove:3 key:GLFW_KEY_D amount:_left.x];
            [self nudge:CGPointMake(r.x * kLookSpeed * frames, -r.y * kLookSpeed * frames)];
        } else {
            if (l.x || l.y) _focusNav = NO;
            [self nudge:CGPointMake(l.x * kPointerSpeed * frames, -l.y * kPointerSpeed * frames)];
            if (fabs(_right.y) > 0.5) {
                if (_scrollRepeat-- <= 0) {
                    MCSDLScroll(0, _right.y > 0 ? 1 : -1);
                    _scrollRepeat = 6;
                }
            } else {
                _scrollRepeat = 0;
            }
        }
    }

    [self readRemote];
    [self repeatKeys];

    // No screensaver while someone is playing (controller input never reaches
    // the system's idle timer), but let it come back after a long idle.
    BOOL awake = _lastInput && now - _lastInput < kKeepAwake;
    if (awake != _keptAwake) {
        _keptAwake = awake;
        UIApplication.sharedApplication.idleTimerDisabled = awake;
    }

    // Minecraft puts the cursor at 0,0 while it starts, so keep the pointer
    // centred until the user moves it. It hides while the d-pad or a
    // controller mod drives the menus.
    if (_direct && (l.x || l.y || r.x || r.y)) _remotePointer = NO;
    BOOL showPointer = !grab && MCInputReady && !_focusNav && (!_direct || _remotePointer);
    if (showPointer && !_pointerMoved && MCPointerX == 0 && MCPointerY == 0)
        [self movePointerTo:CGPointMake(MCScreenWidth / 2, MCScreenHeight / 2)];
    _pointer.hidden = !showPointer;
    if (showPointer) {
        CGRect f = _pointer.frame;
        f.origin = CGPointMake(MCPointerX / _scale, MCPointerY / _scale);
        _pointer.frame = f;
    }
}

// --- scripted test -----------------------------------------------------------
// Steps separated by ';':
//   frame                 wait for the first rendered frame
//   wait SECONDS
//   pointer X Y           move the pointer to game pixel (X, Y)
//   stick L|R X Y FRAMES  hold a stick, then centre it
//   press BUTTON          tap (6 frames down, 6 up), e.g. press A
//   hold BUTTON / release BUTTON
//   type TEXT             type on the keyboard (US layout)
//   key HID               tap a key by HID usage, e.g. key 0x28 (Enter), key 0x29 (Esc)
//   click [right]         click the mouse where the pointer is (works when a mod reads the controller)
//   log TEXT
- (void)runTestScript:(NSString *)script {
    if ([script isEqualToString:@"default"]) {
        script = @"frame; wait 20; log title screen;"
                  " pointer 960 300; stick L 0 -1 11; log pointer on Singleplayer (stick moved it);"
                  " press A; wait 5; log expect the world screen;"
                  " press B; wait 5; log expect the title screen again;"
                  " pointer 960 500; press RT; wait 5; log expect the world screen again (RT click);"
                  " press Menu; wait 4; log expect the title screen; log done";
    }
    _script = [[script componentsSeparatedByString:@";"] mutableCopy];
    _scriptStart = CACurrentMediaTime();
    MCLog(@"input test: %lu steps", (unsigned long)_script.count);
}

- (void)stepScript {
    if (_tapButton < MCButtonCount) {
        if (--_waitFrames == 6) _pressed[_tapButton] = NO;   // release after 6 frames
        if (_waitFrames > 0) return;
        _tapButton = MCButtonCount;
    }
    if (_stickFrames > 0) {
        if (--_stickFrames == 0) _left = _right = CGPointZero;
        return;
    }
    if (_waitFrames > 0) { _waitFrames--; return; }
    if (CACurrentMediaTime() < _waitUntil) return;
    if (!_script.count) {
        _script = nil;
        return;
    }
    NSString *step = [_script.firstObject stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    NSArray<NSString *> *w = [step componentsSeparatedByString:@" "];
    NSString *op = w.firstObject;
    double t = CACurrentMediaTime() - _scriptStart;
    if ([op isEqualToString:@"frame"]) {
        if (!MCFirstFrameSeen) return;  // keep waiting, step stays queued
    } else if ([op isEqualToString:@"wait"] && w.count > 1) {
        _waitUntil = CACurrentMediaTime() + w[1].doubleValue;
    } else if ([op isEqualToString:@"pointer"] && w.count > 2) {
        [self movePointerTo:CGPointMake(w[1].doubleValue, w[2].doubleValue)];
    } else if ([op isEqualToString:@"stick"] && w.count > 4) {
        CGPoint v = CGPointMake(w[2].doubleValue, w[3].doubleValue);
        if ([w[1] isEqualToString:@"R"]) _right = v; else _left = v;
        _stickFrames = w[4].intValue;
    } else if (([op isEqualToString:@"press"] || [op isEqualToString:@"hold"] || [op isEqualToString:@"release"]) && w.count > 1) {
        MCButton b = ButtonNamed(w[1]);
        if (b == MCButtonCount) {
            MCLog(@"input test: unknown button %@", w[1]);
        } else if ([op isEqualToString:@"press"]) {
            _pressed[b] = YES;
            _tapButton = b;
            _waitFrames = 12;
        } else {
            _pressed[b] = [op isEqualToString:@"hold"];
        }
    } else if ([op isEqualToString:@"type"] && step.length > 5) {
        [self typeText:[step substringFromIndex:5]];
    } else if ([op isEqualToString:@"key"] && w.count > 1) {
        long code = strtol(w[1].UTF8String, NULL, 0);
        [self hidKey:code down:YES];
        [self hidKey:code down:NO];
    } else if ([op isEqualToString:@"click"]) {
        int button = w.count > 1 && [w[1] isEqualToString:@"right"] ? GLFW_MOUSE_BUTTON_RIGHT : GLFW_MOUSE_BUTTON_LEFT;
        MCSDLButton(button, true);
        MCSDLButton(button, false);
    } else if ([op isEqualToString:@"log"]) {
        // logged below
    } else if (step.length) {
        MCLog(@"input test: unknown step '%@'", step);
    }
    if (step.length) {
        NSDateFormatter *f = [NSDateFormatter new];
        f.dateFormat = @"HH:mm:ss.S";
        MCLog(@"input test %6.1fs %@: %@ (grabbed %d, pointer %.0f,%.0f)", t, [f stringFromDate:NSDate.date], step, MCMouseGrabbed, MCPointerX, MCPointerY);
    }
    [_script removeObjectAtIndex:0];
}
@end
