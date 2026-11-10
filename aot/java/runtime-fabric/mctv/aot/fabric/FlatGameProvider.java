package mctv.aot.fabric;

import java.io.IOException;
import java.io.InputStream;
import java.io.UncheckedIOException;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;
import java.lang.invoke.MethodType;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collection;
import java.util.List;
import java.util.Locale;
import java.util.Properties;
import java.util.Set;

import net.fabricmc.loader.api.metadata.ModDependency;
import net.fabricmc.loader.impl.FormattedException;
import net.fabricmc.loader.impl.game.GameProvider;
import net.fabricmc.loader.impl.game.patch.GameTransformer;
import net.fabricmc.loader.impl.launch.FabricLauncher;
import net.fabricmc.loader.impl.metadata.BuiltinModMetadata;
import net.fabricmc.loader.impl.metadata.ModDependencyImpl;
import net.fabricmc.loader.impl.util.Arguments;
import net.fabricmc.loader.impl.util.log.Log;
import net.fabricmc.loader.impl.util.log.LogHandler;

/**
 * Fabric's Minecraft game provider for a baked game. The real one finds the
 * game jar and patches it. Here the game is already patched (mctv.aot.bake),
 * and what it learned about the game is in mctv-aot/game.properties. Where
 * Fabric or the game can see a difference, this does what MinecraftGameProvider
 * does.
 */
final class FlatGameProvider implements GameProvider {
    private static final Set<String> SENSITIVE_ARGS = Set.of("accesstoken", "clientid", "profileproperties",
            "proxypass", "proxyuser", "username", "userproperties", "uuid", "xuid");

    private final Properties facts = new Properties();
    private Arguments arguments;

    FlatGameProvider() {
        try (InputStream in = FlatGameProvider.class.getClassLoader().getResourceAsStream("mctv-aot/game.properties")) {
            if (in == null) throw new IllegalStateException("no mctv-aot/game.properties. Is this a baked game?");
            facts.load(in);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
    }

    @Override public String getGameId() { return facts.getProperty("game.id"); }
    @Override public String getGameName() { return facts.getProperty("game.name"); }
    @Override public String getRawGameVersion() { return facts.getProperty("game.rawVersion"); }
    @Override public String getNormalizedGameVersion() { return facts.getProperty("game.normalizedVersion"); }
    @Override public String getEntrypoint() { return facts.getProperty("game.entrypoint"); }
    @Override public boolean isEnabled() { return true; }
    @Override public boolean requiresUrlClassLoader() { return false; }
    @Override public Set<BuiltinTransform> getBuiltinTransforms(String className) { return Set.of(); }  // baked
    @Override public GameTransformer getEntrypointTransformer() { return null; }  // baked
    @Override public void unlockClassPath(FabricLauncher launcher) { }
    @Override public Arguments getArguments() { return arguments; }
    // No AWT on tvOS, and Fabric's error window needs it
    @Override public boolean displayCrash(Throwable exception, String context) { return false; }
    @Override public boolean canOpenErrorGui() { return false; }
    @Override public boolean hasAwtSupport() { return false; }

    @Override
    public Collection<BuiltinMod> getBuiltinMods() {
        BuiltinModMetadata.Builder metadata = new BuiltinModMetadata.Builder(getGameId(), getNormalizedGameVersion())
                .setName(getGameName());
        String java = facts.getProperty("game.java");
        if (java != null) {
            try {
                metadata.addDependency(new ModDependencyImpl(ModDependency.Kind.DEPENDS, "java", List.of(java)));
            } catch (Exception e) {
                throw new RuntimeException(e);
            }
        }
        // The game's jar is compiled in, so its mod has an empty folder for a root.
        Path root = getLaunchDirectory().resolve(".fabric/baked-game");
        try {
            Files.createDirectories(root);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        return List.of(new BuiltinMod(List.of(root), metadata.build()));
    }

    @Override
    public Path getLaunchDirectory() {
        return Path.of(arguments == null ? "." : arguments.getOrDefault("gameDir", "."));
    }

    @Override
    public boolean locateGame(FabricLauncher launcher, String[] args) {
        arguments = new Arguments();
        arguments.parse(args);
        // MinecraftGameProvider's client defaults
        if (!arguments.containsKey("accessToken")) arguments.put("accessToken", "FabricMC");
        if (!arguments.containsKey("version")) arguments.put("version", "Fabric");
        String versionType = "";
        if (arguments.containsKey("versionType") && !arguments.get("versionType").equalsIgnoreCase("release"))
            versionType = arguments.get("versionType") + "/";
        arguments.put("versionType", versionType + "Fabric");
        if (!arguments.containsKey("gameDir"))
            arguments.put("gameDir", getLaunchDirectory().toAbsolutePath().normalize().toString());
        return true;
    }

    @Override
    public void initialize(FabricLauncher launcher) {
        System.setProperty("log4j2.formatMsgNoLookups", "true");
        try {
            Class<?> handler = launcher.loadIntoTarget("net.fabricmc.loader.impl.game.minecraft.Log4jLogHandler");
            Log.init((LogHandler) handler.getConstructor().newInstance());
        } catch (ReflectiveOperationException e) {
            throw new RuntimeException(e);
        }
    }

    @Override
    public void launch(ClassLoader loader) {
        MethodHandle main;
        try {
            main = MethodHandles.lookup().findStatic(loader.loadClass(getEntrypoint()), "main",
                    MethodType.methodType(void.class, String[].class));
        } catch (ReflectiveOperationException e) {
            throw FormattedException.ofLocalized("exception.minecraft.invokeFailure", e);
        }
        try {
            main.invokeExact(arguments.toArray());
        } catch (Throwable t) {
            throw FormattedException.ofLocalized("exception.minecraft.generic", t);
        }
    }

    @Override
    public String[] getLaunchArguments(boolean sanitize) {
        if (arguments == null) return new String[0];
        String[] all = arguments.toArray();
        if (!sanitize) return all;
        String[] out = new String[all.length];
        int n = 0;
        for (int i = 0; i < all.length; i++) {
            if (i + 1 < all.length && all[i].startsWith("--") && SENSITIVE_ARGS.contains(all[i].substring(2).toLowerCase(Locale.ENGLISH))) i++;
            else out[n++] = all[i];
        }
        return Arrays.copyOf(out, n);
    }
}
