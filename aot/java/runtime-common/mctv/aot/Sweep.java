package mctv.aot;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.function.Function;
import java.util.function.Supplier;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.ChatScreen;
import net.minecraft.client.gui.screens.PauseScreen;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.multiplayer.JoinMultiplayerScreen;
import net.minecraft.client.gui.screens.options.AccessibilityOptionsScreen;
import net.minecraft.client.gui.screens.options.ChatOptionsScreen;
import net.minecraft.client.gui.screens.options.LanguageSelectScreen;
import net.minecraft.client.gui.screens.options.OptionsScreen;
import net.minecraft.client.gui.screens.options.SoundOptionsScreen;
import net.minecraft.client.gui.screens.options.VideoSettingsScreen;
import net.minecraft.client.gui.screens.options.controls.ControlsScreen;
import net.minecraft.client.gui.screens.options.controls.KeyBindsScreen;

/**
 * For chaos runs (aot/chaos.py), with -Dmctv.sweep=SECONDS: once the player
 * is in a world, opens each settings screen in turn for that long, the game's
 * and each mod's (compat code adds a mod's, aot/java/compat/MODID/ScreenSweep),
 * and logs "[sweep] NAME: opened CLASS" or "[sweep] NAME: FAILED" with why.
 * A chaos run plays the game but never opens these, and they're where mods
 * reflect most. Without the property it does nothing.
 */
public final class Sweep {
    public record Step(String name, Function<Screen, Screen> open) {}

    private Sweep() {}

    /** Starts the sweep if -Dmctv.sweep is set. modSteps is only asked for once the game is up, so nothing is loaded early. */
    public static void start(Supplier<List<Step>> modSteps) {
        String seconds = System.getProperty("mctv.sweep");
        if (seconds == null) return;
        long dwell = (long) (Double.parseDouble(seconds) * 1000);
        Thread t = new Thread(() -> run(modSteps, dwell), "mctv-sweep");
        t.setDaemon(true);
        t.start();
    }

    private static List<Step> vanilla(Minecraft mc) {
        return List.of(
                new Step("pause", p -> new PauseScreen(true)),
                new Step("options", p -> new OptionsScreen(p, mc.options)),
                new Step("video", p -> new VideoSettingsScreen(p, mc, mc.options)),
                new Step("controls", p -> new ControlsScreen(p, mc.options)),
                new Step("key binds", p -> new KeyBindsScreen(p, mc.options)),
                new Step("chat options", p -> new ChatOptionsScreen(p, mc.options)),
                new Step("sound", p -> new SoundOptionsScreen(p, mc.options)),
                new Step("accessibility", p -> new AccessibilityOptionsScreen(p, mc.options)),
                new Step("language", p -> new LanguageSelectScreen(p, mc.options, mc.getLanguageManager())),
                new Step("chat", p -> new ChatScreen("", false)),
                new Step("multiplayer", p -> new JoinMultiplayerScreen(p)));
    }

    private static void run(Supplier<List<Step>> modSteps, long dwell) {
        Logger log = LoggerFactory.getLogger("mctv-sweep");  // only now, after the game set up its logging
        try {
            Minecraft mc = null;
            for (int i = 0; i < 900 && (mc == null || mc.player == null || mc.level == null); i++) {
                Thread.sleep(1000);
                mc = Minecraft.getInstance();
            }
            if (mc == null || mc.player == null) {
                log.warn("[sweep] never in a world, so no screens");
                return;
            }
            Thread.sleep(10_000);  // let the world settle
            List<Step> steps = new ArrayList<>(vanilla(mc));
            steps.addAll(modSteps.get());
            int opened = 0;
            List<String> failed = new ArrayList<>();
            for (Step step : steps) {
                Minecraft game = mc;
                CompletableFuture<String> shown = new CompletableFuture<>();
                game.execute(() -> {
                    try {
                        Screen screen = step.open().apply(null);
                        game.gui.setScreen(screen);
                        shown.complete(screen.getClass().getName());
                    } catch (Throwable e) {
                        shown.completeExceptionally(e);
                    }
                });
                try {
                    String cls = shown.get(15, TimeUnit.SECONDS);
                    Thread.sleep(dwell);  // drawn for a while, where most of a screen's code runs
                    log.info("[sweep] {}: opened {}", step.name(), cls);
                    opened++;
                } catch (ExecutionException e) {
                    failed.add(step.name());
                    log.error("[sweep] {}: FAILED", step.name(), e.getCause());
                } catch (TimeoutException e) {
                    failed.add(step.name());
                    log.error("[sweep] {}: FAILED, the game didn't get to it in 15 s", step.name());
                }
            }
            Minecraft game = mc;
            game.execute(() -> game.gui.setScreen(null));
            log.info("[sweep] done: {} opened, {} failed {}", opened, failed.size(), failed);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }
}
