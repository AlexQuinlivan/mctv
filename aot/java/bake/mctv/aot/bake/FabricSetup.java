package mctv.aot.bake;

import java.lang.classfile.ClassFile;
import java.lang.classfile.CodeModel;
import java.lang.classfile.Instruction;
import java.lang.classfile.MethodModel;
import java.lang.classfile.instruction.ConstantInstruction;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ClassDesc;
import java.nio.charset.StandardCharsets;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;

import net.fabricmc.api.EnvType;
import net.fabricmc.loader.api.metadata.ModDependency;
import net.fabricmc.loader.impl.FabricLoaderImpl;
import net.fabricmc.loader.impl.ModContainerImpl;
import net.fabricmc.loader.impl.game.GameProvider;
import net.fabricmc.loader.impl.launch.knot.Knot;
import net.fabricmc.loader.impl.metadata.EntrypointMetadata;

/** The bake's Fabric half, kept apart so a vanilla bake needs no Fabric on its class path. */
final class FabricSetup {
    /**
     * Starts Knot as KnotClient would, up to launching the game, and returns its
     * class loader. Adds each mod's jars to sources, and records the mods and
     * what Fabric learned about the game, for mctv.aot.fabric.FlatGameProvider.
     */
    static ClassLoader start(String[] gameArgs, Set<Path> sources, Map<String, Object> facts, List<Map<String, Object>> mods) {
        ClassLoader loader = new Knot(EnvType.CLIENT).init(gameArgs);
        for (ModContainerImpl mod : FabricLoaderImpl.INSTANCE.getModsInternal()) {
            List<String> paths = new ArrayList<>();
            boolean builtin = mod.getMetadata().getType().equals("builtin");  // the game (already a source) and java (the JDK)
            for (Path p : mod.getCodeSourcePaths()) {
                Path n = p.toAbsolutePath().normalize();
                if (!builtin) sources.add(n);
                paths.add(n.toString());
            }
            Map<String, Object> m = new TreeMap<>();
            m.put("id", mod.getMetadata().getId());
            m.put("version", mod.getMetadata().getVersion().getFriendlyString());
            m.put("type", mod.getMetadata().getType());
            m.put("codeSource", paths);
            mods.add(m);
        }
        GameProvider game = FabricLoaderImpl.INSTANCE.getGameProvider();
        facts.put("game.id", game.getGameId());
        facts.put("game.name", game.getGameName());
        facts.put("game.rawVersion", game.getRawGameVersion());
        facts.put("game.normalizedVersion", game.getNormalizedGameVersion());
        facts.put("game.entrypoint", game.getEntrypoint());
        for (GameProvider.BuiltinMod b : game.getBuiltinMods())
            for (ModDependency d : b.metadata.getDependencies())
                if (d.getModId().equals("java")) facts.put("game.java", d.getVersionRequirements().iterator().next().toString());
        return loader;
    }

    /** A class's bytes as Knot gives them to code that asks (Mixin's getClassNode): before Mixin. */
    static byte[] preMixinBytes(String internal) {
        try {
            byte[] b = net.fabricmc.loader.impl.launch.FabricLauncherBase.getLauncher().getClassByteArray(internal.replace('/', '.'), true);
            if (b == null) throw new IllegalStateException("Knot has no bytes for " + internal);
            return b;
        } catch (java.io.IOException e) {
            throw new java.io.UncheckedIOException(e);
        }
    }

    private static final Set<String> ENTRYPOINT_CALLS = Set.of("getEntrypoints", "getEntrypointContainers", "invokeEntrypoints", "invoke");

    /**
     * The interfaces Fabric's method-reference entrypoints ("Class::method")
     * become. Fabric makes those with MethodHandleProxies, which in an image is
     * a java.lang.reflect.Proxy (mctv.aot.svm.Target_MethodHandleProxies) and
     * needs its interface registered. A key's interface is found where it's
     * asked for, getEntrypoints("key", Type.class) and the like, in any class
     * given. Keys used with no such call are added to unresolved.
     */
    static Set<String> methodReferenceInterfaces(Iterable<byte[]> classes, Set<String> unresolved) {
        Set<String> keys = new TreeSet<>();
        for (ModContainerImpl mod : FabricLoaderImpl.INSTANCE.getModsInternal())
            for (String key : mod.getMetadata().getEntrypointKeys())
                for (EntrypointMetadata e : mod.getMetadata().getEntrypoints(key))
                    if (e.getAdapter().equals("default") && e.getValue().contains("::")) keys.add(key);
        Map<String, Set<String>> types = new TreeMap<>();
        byte[] marker = "Entrypoint".getBytes(StandardCharsets.US_ASCII);
        for (byte[] bytes : classes) {
            if (!contains(bytes, marker) && !contains(bytes, "getEntrypoints".getBytes(StandardCharsets.US_ASCII))) continue;
            for (MethodModel m : ClassFile.of().parse(bytes).methods()) {
                CodeModel code = m.code().orElse(null);
                if (code == null) continue;
                String key = null;
                ClassDesc type = null;
                int sinceType = 0;
                for (var element : code) {
                    if (!(element instanceof Instruction i)) continue;
                    sinceType++;
                    if (i instanceof ConstantInstruction c && c.constantValue() instanceof String str) {
                        key = str;
                        type = null;
                    } else if (i instanceof ConstantInstruction c && c.constantValue() instanceof ClassDesc cd && key != null) {
                        type = cd;
                        sinceType = 0;
                    } else if (i instanceof InvokeInstruction inv && type != null && sinceType <= 3
                            && ENTRYPOINT_CALLS.contains(inv.name().stringValue())
                            && inv.typeSymbol().descriptorString().startsWith("(Ljava/lang/String;Ljava/lang/Class;")) {
                        types.computeIfAbsent(key, k -> new TreeSet<>()).add(type.descriptorString().replace('/', '.').substring(1, type.descriptorString().length() - 1));
                        key = null;
                        type = null;
                    }
                }
            }
        }
        Set<String> out = new TreeSet<>();
        for (String key : keys) {
            Set<String> t = types.get(key);
            if (t == null) unresolved.add(key);
            else out.addAll(t);
        }
        return out;
    }

    private static boolean contains(byte[] haystack, byte[] needle) {
        outer:
        for (int i = 0; i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) if (haystack[i + j] != needle[j]) continue outer;
            return true;
        }
        return false;
    }
}
