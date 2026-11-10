package mctv.aot.compat.sodium;

import java.util.List;

import mctv.aot.Sweep;
import net.caffeinemc.mods.sodium.client.gui.VideoSettingsScreen;

/** Sodium's screens for a chaos run's screen sweep (mctv.aot.Sweep). */
public final class ScreenSweep {
    private ScreenSweep() {}

    public static List<Sweep.Step> steps() {
        return List.of(new Sweep.Step("sodium video settings", VideoSettingsScreen::createScreen));
    }
}
