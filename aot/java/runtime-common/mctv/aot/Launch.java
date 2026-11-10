package mctv.aot;

/**
 * The main class of a vanilla native image. mctv.aot.fabric.FlatFabric is the
 * Fabric one.
 */
public final class Launch {
    public static void main(String[] args) throws Throwable {
        reportDesktopPlatform();
        Sweep.start(java.util.List::of);  // chaos runs only (-Dmctv.sweep)
        net.minecraft.client.main.Main.main(args);
    }

    /**
     * A native image built for tvOS reports its OS as iOS, which LWJGL refuses
     * ("Unknown platform") and Minecraft doesn't know. The app's JVM reports
     * macOS, so this does too, before either reads it.
     */
    public static void reportDesktopPlatform() {
        if (!System.getProperty("os.name", "").startsWith("Mac")) System.setProperty("os.name", "Mac OS X");
    }
}
