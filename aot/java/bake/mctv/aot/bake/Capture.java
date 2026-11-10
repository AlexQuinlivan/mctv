package mctv.aot.bake;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ClassDesc;
import java.lang.constant.MethodTypeDesc;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.nio.charset.StandardCharsets;
import java.security.ProtectionDomain;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Pattern;

/**
 * Java agent for the bake.
 *
 * Records the bytes of every class the game's class loader defines, as the JVM
 * receives them, which is after Fabric's mixins and class tweaks and after any
 * agent listed before this one on the command line (the app's own,
 * java/mctv-agent). JDK proxy classes are left out, since a native image makes
 * its own.
 *
 * With generated=DIR it records classes defined while the game runs
 * instead (Generated), for traced runs.
 *
 * Also fixes Mixin's session id, which it otherwise takes from UUID.randomUUID()
 * and writes into what it merges (@MixinMerged, and the $md$ names of merged
 * members), so the same inputs bake the same classes.
 */
public final class Capture implements ClassFileTransformer {
    static final Map<String, byte[]> CLASSES = new ConcurrentHashMap<>();
    static final UUID SESSION = UUID.nameUUIDFromBytes("mctv-aot".getBytes(StandardCharsets.UTF_8));
    static volatile ClassLoader target;
    static volatile boolean sessionFixed;
    private static final String MIXIN_PROCESSOR = "org/spongepowered/asm/mixin/transformer/MixinProcessor";
    private static final Pattern PROXY = Pattern.compile("(.*/)?\\$Proxy\\d+");

    public static void premain(String args, Instrumentation inst) {
        if (args != null && args.startsWith("generated=")) {
            Generated.start(java.nio.file.Path.of(args.substring("generated=".length())), inst);
            return;
        }
        inst.addTransformer(new Capture(), false);
    }

    /** What MixinProcessor gets instead of a random id. */
    public static UUID session() {
        return SESSION;
    }

    /** Fabric's class loader is recognised by name from the start, a plain one once Bake sets it. */
    static boolean isGameLoader(ClassLoader loader) {
        return loader != null && (loader == target || loader.getClass().getName().startsWith("net.fabricmc.loader.impl.launch.knot."));
    }

    @Override
    public byte[] transform(ClassLoader loader, String name, Class<?> redefining, ProtectionDomain domain, byte[] bytes) {
        if (name == null || redefining != null) return null;
        if (name.equals(MIXIN_PROCESSOR)) return fixSession(bytes);
        if (isGameLoader(loader) && !PROXY.matcher(name).matches()) CLASSES.put(name, bytes.clone());
        return null;
    }

    private static byte[] fixSession(byte[] bytes) {
        ClassDesc uuid = ClassDesc.of("java.util.UUID");
        CodeTransform swap = (code, e) -> {
            if (e instanceof InvokeInstruction i && i.owner().asSymbol().equals(uuid) && i.name().equalsString("randomUUID")) {
                code.invokestatic(ClassDesc.of(Capture.class.getName()), "session", MethodTypeDesc.of(uuid));
                sessionFixed = true;
            } else {
                code.with(e);
            }
        };
        ClassFile cf = ClassFile.of();
        return cf.transformClass(cf.parse(bytes), ClassTransform.transformingMethodBodies(swap));
    }
}
