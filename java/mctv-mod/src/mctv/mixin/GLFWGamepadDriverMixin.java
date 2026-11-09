package mctv.mixin;

import dev.isxander.controlify.controller.ControllerEntity;
import dev.isxander.controlify.controller.rumble.RumbleComponent;
import dev.isxander.controlify.driver.glfw.GLFWGamepadDriver;
import org.lwjgl.glfw.GLFW;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/**
 * Rumble for game controllers on tvOS. Controlify only rumbles through
 * SDL, which can't load on tvOS, so it uses its GLFW driver, which has no
 * rumble. This gives that driver Controlify's rumble component and hands each
 * level to the app (GLFW.nmctvGamepadRumble, then Core Haptics in
 * mctv/Sources/MCRumble.m), the way Controlify's SDL driver calls SDL.
 */
@Mixin(value = GLFWGamepadDriver.class, remap = false)
public abstract class GLFWGamepadDriverMixin {
    @Shadow @Final private int jid;
    @Unique private RumbleComponent mctv$rumble;

    @Inject(method = "addComponents", at = @At("TAIL"))
    private void mctv$addRumble(ControllerEntity entity, CallbackInfo ci) {
        try {
            if (!GLFW.nmctvGamepadHasRumble(jid)) return;
        } catch (LinkageError e) {
            return;  // an older app without the rumble natives
        }
        mctv$rumble = new RumbleComponent();
        entity.setComponent(mctv$rumble);
    }

    @Inject(method = "update", at = @At("TAIL"))
    private void mctv$sendRumble(ControllerEntity entity, boolean outOfFocus, CallbackInfo ci) {
        if (mctv$rumble != null) {
            mctv$rumble.consumeRumble().ifPresent(state -> GLFW.nmctvGamepadRumble(jid, state.strong(), state.weak()));
        }
    }

    @Inject(method = "close", at = @At("HEAD"))
    private void mctv$stopRumble(CallbackInfo ci) {
        if (mctv$rumble != null) GLFW.nmctvGamepadRumble(jid, 0, 0);
    }
}
