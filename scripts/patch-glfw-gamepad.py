#!/usr/bin/env python3
"""Replace Amethyst's stubbed GLFW joystick and gamepad functions in GLFW.java,
so joystick 0 is the TV's game controller.

    python3 -I scripts/patch-glfw-gamepad.py <GLFW.java>

The native bridge (nmctvGamepad* in mctv/Sources/bridge/input_bridge.m) fills
in GLFWgamepadstate's layout, so glfwGetGamepadState copies it straight into
LWJGL's struct.
"""
import sys

path = sys.argv[1]
src = open(path).read()

start = src.index("    public static boolean glfwJoystickPresent(int jid) {")
tail = "    public static boolean glfwGetGamepadState(int jid, GLFWGamepadState state) {\n        return false;\n    }\n"
end = src.index(tail) + len(tail)

replacement = '''    // mctv: joystick 0 is the TV's game controller (mctv/Sources/MCInput.m).
    private static native boolean nmctvGamepadConnected();
    private static native boolean nmctvGamepadState(long statePtr);
    private static native String nmctvGamepadName();
    private static native String nmctvGamepadGUID();
    // Rumble on that controller (mctv/Sources/MCRumble.m), for the mctv mod's
    // hook in Controlify (java/mctv-mod). Levels are 0 to 1, each held up to 5 s.
    public static native boolean nmctvGamepadHasRumble(int jid);
    public static native void nmctvGamepadRumble(int jid, float strong, float weak);
    private static boolean mctvPresent;
    private static GLFWGamepadState mctvState;
    private static final FloatBuffer mctvAxes = BufferUtils.createFloatBuffer(6);
    private static final ByteBuffer mctvButtons = BufferUtils.createByteBuffer(15);
    private static final ByteBuffer mctvHats = BufferUtils.createByteBuffer(1);

    private static GLFWGamepadState mctvRead() {
        if (mctvState == null) mctvState = GLFWGamepadState.create();
        return nmctvGamepadState(mctvState.address()) ? mctvState : null;
    }

    private static void mctvPollConnection() {
        boolean present = nmctvGamepadConnected();
        if (present == mctvPresent) return;
        mctvPresent = present;
        if (mGLFWJoystickCallback != null) mGLFWJoystickCallback.invoke(0, present ? GLFW_CONNECTED : GLFW_DISCONNECTED);
    }

    public static boolean glfwJoystickPresent(int jid) {
        return jid == 0 && nmctvGamepadConnected();
    }
    public static String glfwGetJoystickName(int jid) {
        return jid == 0 ? nmctvGamepadName() : null;
    }
    public static FloatBuffer glfwGetJoystickAxes(int jid) {
        GLFWGamepadState s = jid == 0 ? mctvRead() : null;
        if (s == null) return null;
        mctvAxes.clear();
        for (int i = 0; i < 6; i++) mctvAxes.put(i, s.axes(i));
        return mctvAxes;
    }
    public static ByteBuffer glfwGetJoystickButtons(int jid) {
        GLFWGamepadState s = jid == 0 ? mctvRead() : null;
        if (s == null) return null;
        mctvButtons.clear();
        for (int i = 0; i < 15; i++) mctvButtons.put(i, s.buttons(i));
        return mctvButtons;
    }
    public static ByteBuffer glfwGetJoystickHats(int jid) {
        GLFWGamepadState s = jid == 0 ? mctvRead() : null;
        if (s == null) return null;
        int hat = (s.buttons(GLFW_GAMEPAD_BUTTON_DPAD_UP) != 0 ? GLFW_HAT_UP : 0)
                | (s.buttons(GLFW_GAMEPAD_BUTTON_DPAD_RIGHT) != 0 ? GLFW_HAT_RIGHT : 0)
                | (s.buttons(GLFW_GAMEPAD_BUTTON_DPAD_DOWN) != 0 ? GLFW_HAT_DOWN : 0)
                | (s.buttons(GLFW_GAMEPAD_BUTTON_DPAD_LEFT) != 0 ? GLFW_HAT_LEFT : 0);
        mctvHats.put(0, (byte) hat);
        return mctvHats;
    }
    public static ByteBuffer glfwGetjoystickHats(int jid) {  // Amethyst's spelling, kept for its callers
        return glfwGetJoystickHats(jid);
    }
    public static boolean glfwJoystickIsGamepad(int jid) {
        return glfwJoystickPresent(jid);
    }
    public static String glfwGetJoystickGUID(int jid) {
        return jid == 0 ? nmctvGamepadGUID() : null;
    }
    public static long glfwGetJoystickUserPointer(int jid) {
        return 0;
    }
    public static void glfwSetJoystickUserPointer(int jid, long pointer) {
    }
    public static boolean glfwUpdateGamepadMappings(ByteBuffer string) {
        return true;  // the controller is already mapped (GameController framework)
    }
    public static String glfwGetGamepadName(int jid) {
        return glfwGetJoystickName(jid);
    }
    public static boolean glfwGetGamepadState(int jid, GLFWGamepadState state) {
        GLFWGamepadState s = jid == 0 ? mctvRead() : null;
        if (s == null) return false;
        org.lwjgl.system.MemoryUtil.memCopy(s.address(), state.address(), GLFWGamepadState.SIZEOF);
        return true;
    }
'''
src = src[:start] + replacement + src[end:]

poll = "    public static void glfwPollEvents() {\n"
assert src.count(poll) == 1
src = src.replace(poll, poll + "        mctvPollConnection();\n")
open(path, "w").write(src)
print("[glfw] gamepad API patched")
