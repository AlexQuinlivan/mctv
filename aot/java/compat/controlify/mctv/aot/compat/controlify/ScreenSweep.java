package mctv.aot.compat.controlify;

import java.util.List;

import dev.isxander.controlify.gui.screen.ControlifySettingsScreen;
import dev.isxander.controlify.gui.screen.GlobalSettingsScreenFactory;
import mctv.aot.Sweep;

/** Controlify's screens for a chaos run's screen sweep (mctv.aot.Sweep), its global settings built with YACL. */
public final class ScreenSweep {
    private ScreenSweep() {}

    public static List<Sweep.Step> steps() {
        return List.of(
                new Sweep.Step("controlify settings", ControlifySettingsScreen::new),
                new Sweep.Step("controlify global settings", GlobalSettingsScreenFactory::createGlobalSettingsScreen));
    }
}
