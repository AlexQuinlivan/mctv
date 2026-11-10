package mctv.aot.fabric;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.io.InputStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Collection;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.jar.JarFile;
import java.util.jar.Manifest;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import mctv.aot.Launch;
import net.fabricmc.api.EnvType;
import net.fabricmc.loader.api.entrypoint.PreLaunchEntrypoint;
import net.fabricmc.loader.impl.FabricLoaderImpl;
import net.fabricmc.loader.impl.ModContainerImpl;
import net.fabricmc.loader.impl.FormattedException;
import net.fabricmc.loader.impl.launch.FabricLauncherBase;
import net.fabricmc.loader.impl.util.log.Log;
import net.fabricmc.loader.impl.util.log.LogCategory;
import org.spongepowered.asm.launch.MixinBootstrap;
import org.spongepowered.asm.mixin.extensibility.IMixinConfigPlugin;

/**
 * Starts Fabric for a baked game, the main class of a Fabric native image.
 *
 * It is Knot (net.fabricmc.loader.impl.launch.knot.Knot) without what a native
 * image can't do and doesn't need: its class loader, class tweaks, Mixin and
 * transformers were all applied when the game was baked (mctv.aot.bake), and
 * mixin config plugins are started without applying anything. Fabric
 * still finds the mods in the game folder's mods/, resolves them, reads their
 * metadata and resources from their jars, and runs their entrypoints, from the
 * classes compiled in.
 */
public final class FlatFabric extends FabricLauncherBase {
    /** Where the pipeline puts Fabric Loader's jar, which Fabric reads its own metadata from. */
    static final String LOADER_JAR = ".mctv-aot/fabric-loader.jar";
    private static volatile Path loaderJar;
    private final Map<String, Object> properties = new HashMap<>();
    private final ClassLoader classLoader = FlatFabric.class.getClassLoader();
    private FlatGameProvider provider;

    public static void main(String[] args) {
        Launch.reportDesktopPlatform();
        setupUncaughtExceptionHandler();
        mctv.aot.Sweep.start(ModSweeps::all);  // chaos runs only (-Dmctv.sweep): the game's screens and each mod's
        try {
            FlatFabric fabric = new FlatFabric();
            ClassLoader cl = fabric.init(args);
            fabric.provider.launch(cl);
        } catch (FormattedException e) {
            handleFormattedException(e);
        }
    }

    private ClassLoader init(String[] args) {
        setProperties(properties);
        provider = new FlatGameProvider();
        provider.locateGame(this, args);
        loaderJar = provider.getLaunchDirectory().resolve(LOADER_JAR).toAbsolutePath().normalize();
        Log.finishBuiltinConfig();
        Log.info(LogCategory.GAME_PROVIDER, "Loading %s %s with Fabric Loader %s, compiled ahead of time",
                provider.getGameName(), provider.getRawGameVersion(), FabricLoaderImpl.VERSION);
        Thread.currentThread().setContextClassLoader(classLoader);

        FabricLoaderImpl loader = FabricLoaderImpl.INSTANCE;
        loader.setGameProvider(provider);
        provider.initialize(this);
        discoverMods(loader);
        loader.freeze();
        startMixinConfigPlugins(loader);
        provider.unlockClassPath(this);
        try {
            loader.invokeEntrypoints("preLaunch", PreLaunchEntrypoint.class, PreLaunchEntrypoint::onPreLaunch);
        } catch (RuntimeException e) {
            throw FormattedException.ofLocalized("exception.initializerFailure", e);
        }
        return classLoader;
    }

    /**
     * Fabric's mod discovery. It makes the built-in "java" mod from java.home,
     * which a native image doesn't set, so for the length of discovery only it
     * points at an empty folder. Nothing else sees it.
     */
    private void discoverMods(FabricLoaderImpl loader) {
        if (System.getProperty("java.home") != null) {
            loader.load();
            return;
        }
        Path home = provider.getLaunchDirectory().resolve(".fabric/java-home");
        try {
            Files.createDirectories(home);
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        }
        System.setProperty("java.home", home.toAbsolutePath().toString());
        try {
            loader.load();
        } finally {
            System.clearProperty("java.home");
        }
    }

    /**
     * What Mixin's start-up does with mixin config plugins, less applying
     * mixins, which happened at bake time. Mods use a plugin's onLoad to load
     * their settings. Configs come in the order Mixin uses: each mod's, in
     * Fabric's mod order (FabricMixinBootstrap), then by priority. Mixin isn't
     * given the configs, since preparing them reads mixin classes' bytes, which
     * an image doesn't have.
     */
    private void startMixinConfigPlugins(FabricLoaderImpl loader) {
        // Plugins may ask Mixin for its service. As FabricMixinBootstrap does,
        // so Mixin doesn't pick the LaunchWrapper one it also carries.
        System.setProperty("mixin.bootstrapService", "net.fabricmc.loader.impl.launch.knot.MixinServiceKnotBootstrap");
        System.setProperty("mixin.service", FlatMixinService.class.getName());
        // Mixin itself, as Knot starts it, but with no configs added and no
        // transformer made, so it never reads or changes a class. Plugins
        // (MixinExtras') expect it to be there.
        MixinBootstrap.init();
        finishMixinBootstrapping();
        record Config(String name, int priority, int order, String pkg, String plugin) { }
        List<Config> configs = new java.util.ArrayList<>();
        for (ModContainerImpl mod : loader.getModsInternal()) {
            for (String name : mod.getMetadata().getMixinConfigs(EnvType.CLIENT)) {
                Path file = mod.findPath(name).orElse(null);
                if (file == null) continue;
                JsonObject json;
                try {
                    json = JsonParser.parseString(Files.readString(file)).getAsJsonObject();
                } catch (IOException e) {
                    throw new UncheckedIOException(e);
                }
                if (!json.has("plugin")) continue;
                configs.add(new Config(name, json.has("priority") ? json.get("priority").getAsInt() : 1000, configs.size(),
                        json.has("package") ? json.get("package").getAsString() : "", json.get("plugin").getAsString()));
            }
        }
        configs.sort(java.util.Comparator.comparingInt(Config::priority).thenComparingInt(Config::order));
        for (Config c : configs) {
            try {
                IMixinConfigPlugin plugin = (IMixinConfigPlugin) Class.forName(c.plugin(), true, classLoader).getDeclaredConstructor().newInstance();
                plugin.onLoad(c.pkg());
            } catch (ReflectiveOperationException | LinkageError e) {
                throw new RuntimeException("couldn't start the mixin config plugin " + c.plugin() + " of " + c.name(), e);
            }
        }
        Log.debug(LogCategory.MIXIN, "Started %d mixin config plugins", configs.size());
    }

    /**
     * A class's jar in a native image, for Target_UrlUtil. Classes there report
     * the executable as their code source, so Fabric's own classes get the jar
     * the pipeline put beside the game, and any other class gets null, which
     * is what Fabric's UrlUtil returns when it doesn't know.
     */
    static Path imageCodeSource(Class<?> cls) {
        return cls.getName().startsWith("net.fabricmc.loader.") ? loaderJar : null;
    }

    // Classes are compiled in, so there's no class path to change.
    @Override public void addToClassPath(Path path, String... allowedPrefixes) { }
    @Override public void setAllowedPrefixes(Path path, String... prefixes) { }
    @Override public void setValidParentClassPath(Collection<Path> paths) { }
    @Override public List<Path> getClassPath() { return List.of(); }
    @Override public EnvType getEnvironmentType() { return EnvType.CLIENT; }
    @Override public ClassLoader getTargetClassLoader() { return classLoader; }
    @Override public InputStream getResourceAsStream(String name) { return classLoader.getResourceAsStream(name); }
    @Override public String getEntrypoint() { return provider.getEntrypoint(); }
    /**
     * Some code reads a class's bytes at run time (Fabric's tooltip order reads
     * ItemStack's). The bake finds which and ships them as Knot would give
     * them, under mctv-aot/classes. Any other class has none.
     */
    @Override
    public byte[] getClassByteArray(String name, boolean runTransformers) throws IOException {
        try (InputStream in = classLoader.getResourceAsStream("mctv-aot/classes/" + name.replace('.', '/') + ".class")) {
            return in == null ? null : in.readAllBytes();
        }
    }

    @Override
    public boolean isClassLoaded(String name) {
        try {
            Class.forName(name, false, classLoader);
            return true;
        } catch (ClassNotFoundException | LinkageError e) {
            return false;
        }
    }

    @Override
    public Class<?> loadIntoTarget(String name) throws ClassNotFoundException {
        return Class.forName(name, false, classLoader);
    }

    @Override
    public Manifest getManifest(Path origin) {
        try {
            if (Files.isDirectory(origin)) {
                Path m = origin.resolve(JarFile.MANIFEST_NAME);
                if (!Files.exists(m)) return null;
                try (InputStream in = Files.newInputStream(m)) { return new Manifest(in); }
            }
            try (JarFile jar = new JarFile(origin.toFile())) { return jar.getManifest(); }
        } catch (IOException e) {
            return null;
        }
    }
}
