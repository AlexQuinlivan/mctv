package mctv.aot.bake;

import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.lang.classfile.Annotation;
import java.lang.classfile.AnnotationElement;
import java.lang.classfile.AnnotationValue;
import java.lang.classfile.Attributes;
import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassModel;
import java.lang.classfile.MethodModel;
import java.lang.classfile.attribute.RuntimeVisibleAnnotationsAttribute;
import java.lang.classfile.constantpool.ClassEntry;
import java.lang.classfile.constantpool.PoolEntry;
import java.net.URL;
import java.net.URLClassLoader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.time.LocalDateTime;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.HashSet;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.jar.JarFile;
import java.util.jar.Manifest;
import java.util.stream.Stream;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;
import java.util.zip.ZipOutputStream;


/**
 * Bakes Minecraft, and with Fabric its mods, into plain class files for a
 * native image, which can't load or transform classes while it runs.
 *
 *   java -javaagent:<mctv-agent.jar> -javaagent:<bake.jar> -cp <bake.jar>:<class path> \
 *       mctv.aot.bake.Bake fabric|vanilla <out dir> <Minecraft arguments>
 *
 * fabric starts Fabric's Knot as KnotClient does, and stops where it would
 * launch the game, with the mods found, Mixin ready and preLaunch run. vanilla
 * puts the class path's jars in a plain class loader. Then every class in the
 * game loader's jars is loaded without being initialised, and each class they
 * name that no jar has (Mixin and MixinExtras generate some) is asked for until
 * no new ones turn up. Capture records what the JVM was given for each.
 *
 *   out/jars/NN-name.jar   each jar with a changed class, holding the final bytes,
 *                          less its mixins, which are merged into their targets
 *   out/generated.jar      classes no jar has, and mctv-aot/game.properties
 *   out/bake.json          the image's class path, the mods, what couldn't load
 *
 * Entries keep their jar's order, generated ones are sorted, and every entry is
 * dated 1980-01-01, so the same inputs give the same files.
 */
public final class Bake {
    private static final LocalDateTime EPOCH = LocalDateTime.of(1980, 1, 1, 0, 0);

    public static void main(String[] args) throws Exception {
        boolean fabric = switch (args[0]) {
            case "fabric" -> true;
            case "vanilla" -> false;
            default -> throw new IllegalArgumentException("fabric or vanilla, not " + args[0]);
        };
        Path out = Path.of(args[1]);
        String[] gameArgs = Arrays.copyOfRange(args, 2, args.length);

        // The jars the game's class loader reads, in the order it reads them
        // (aot.py passes them, so the bake's own tools aren't among them).
        Set<Path> sources = new LinkedHashSet<>();
        for (String e : System.getProperty("mctv.bake.sources").split(java.io.File.pathSeparator))
            sources.add(Path.of(e).toAbsolutePath().normalize());
        ClassLoader loader;
        Map<String, Object> facts = new TreeMap<>();
        List<Map<String, Object>> mods = new ArrayList<>();
        if (fabric) {
            loader = FabricSetup.start(gameArgs, sources, facts, mods);
        } else {
            List<URL> urls = new ArrayList<>();
            for (Path p : sources) urls.add(p.toUri().toURL());
            loader = new URLClassLoader(urls.toArray(URL[]::new), ClassLoader.getPlatformClassLoader());
            Capture.target = loader;
        }

        // Every class each jar has, the first jar winning as it does for a class loader.
        Map<String, Path> owner = new LinkedHashMap<>();
        Map<Path, List<String>> entries = new LinkedHashMap<>();
        for (Path jar : sources) {
            List<String> names = list(jar);
            entries.put(jar, names);
            for (String n : names)
                if (isClass(n)) owner.putIfAbsent(n.substring(0, n.length() - 6), jar);
        }
        Map<String, String> failed = new TreeMap<>();
        Set<String> mixins = new TreeSet<>();  // Mixin's own classes: merged into their targets, never loaded themselves
        for (String internal : owner.keySet()) load(loader, internal, failed, mixins);

        // Classes the captured ones name that no jar has: Mixin's and MixinExtras' generated ones.
        Set<String> tried = new HashSet<>(owner.keySet());
        for (;;) {
            Set<String> wanted = new TreeSet<>();
            for (byte[] bytes : Capture.CLASSES.values())
                for (PoolEntry e : ClassFile.of().parse(bytes).constantPool())
                    if (e instanceof ClassEntry c) {
                        String n = c.asInternalName();
                        if (!n.startsWith("[") && !Capture.CLASSES.containsKey(n) && tried.add(n) && !isPlatform(n)) wanted.add(n);
                    }
            if (wanted.isEmpty()) break;
            Map<String, String> ignored = new HashMap<>();  // mostly optional mods that aren't installed
            for (String n : wanted) load(loader, n, ignored, new HashSet<>());
        }

        // Capture fixed Mixin's session id. Check it took, or the bake isn't repeatable.
        if (fabric && !Capture.sessionFixed) throw new IllegalStateException("Mixin's session id wasn't fixed (MixinProcessor changed?)");
        Set<String> sessions = mixinSessions(Capture.CLASSES.values());
        if (!sessions.isEmpty() && !sessions.equals(Set.of(Capture.SESSION.toString())))
            throw new IllegalStateException("merged classes carry Mixin session ids " + sessions + ", not " + Capture.SESSION);

        // What the image needs that the classes say (Analysis), from every class it will have.
        Analysis analysis = new Analysis();
        com.google.gson.JsonObject fixups = com.google.gson.JsonParser.parseString(
                Files.readString(Path.of(System.getProperty("mctv.bake.fixups")))).getAsJsonObject();
        if (fixups.has("reflectsOnParameter")) analysis.declareNeeds(fixups.getAsJsonObject("reflectsOnParameter"));
        if (fixups.has("otherPlatforms")) analysis.otherPlatforms(fixups.getAsJsonObject("otherPlatforms").keySet());
        Path game = Path.of(System.getProperty("mctv.bake.game")).toAbsolutePath().normalize();
        Map<String, byte[]> gameClasses = new TreeMap<>();
        for (String n : entries.get(game))
            if (isClass(n) && Capture.CLASSES.containsKey(n.substring(0, n.length() - 6)))
                gameClasses.put(n.substring(0, n.length() - 6), Capture.CLASSES.get(n.substring(0, n.length() - 6)));
        analysis.gameRules(gameClasses, owner.keySet());
        for (Path jar : sources) {
            for (String n : entries.get(jar)) {
                if (!isClass(n)) continue;
                String internal = n.substring(0, n.length() - 6);
                if (mixins.contains(internal) || !jar.equals(owner.get(internal))) continue;
                byte[] bytes = Capture.CLASSES.containsKey(internal) ? Capture.CLASSES.get(internal) : read(jar, n);
                analysis.hierarchy(bytes);
                if (Analysis.mightUseDynamicFeatures(bytes)) analysis.scan(jar.getFileName().toString(), bytes);
            }
        }
        for (Map.Entry<String, byte[]> e : Capture.CLASSES.entrySet()) {
            if (owner.containsKey(e.getKey())) continue;
            analysis.hierarchy(e.getValue());
            if (Analysis.mightUseDynamicFeatures(e.getValue())) analysis.scan("generated", e.getValue());
        }
        // callers of methods that reflect on a parameter, again while callers that pass on their own are found
        for (boolean grew = analysis.hasNeeds(); grew; ) {
            analysis.liftNeeds();  // needs go up to the methods they override, so calls through those are checked too
            grew = false;
            for (Path jar : sources)
                for (String n : entries.get(jar)) {
                    String internal = n.endsWith(".class") ? n.substring(0, n.length() - 6) : null;
                    if (!isClass(n) || mixins.contains(internal) || !jar.equals(owner.get(internal))) continue;
                    grew |= analysis.scanCalls(jar.getFileName().toString(),
                            Capture.CLASSES.containsKey(internal) ? Capture.CLASSES.get(internal) : read(jar, n));
                }
            for (Map.Entry<String, byte[]> e : Capture.CLASSES.entrySet())
                if (!owner.containsKey(e.getKey())) grew |= analysis.scanCalls("generated", e.getValue());
        }
        analysis.finish();
        Set<String> unresolvedEntrypoints = new TreeSet<>();
        Map<String, byte[]> classBytes = new TreeMap<>();  // read at run time by name, as Knot would give them
        if (fabric) {
            List<byte[]> all = new ArrayList<>(Capture.CLASSES.values());
            for (Path jar : sources)
                for (String n : entries.get(jar))
                    if (isClass(n) && !Capture.CLASSES.containsKey(n.substring(0, n.length() - 6))) all.add(read(jar, n));
            analysis.proxies.addAll(FabricSetup.methodReferenceInterfaces(all, unresolvedEntrypoints));
            for (String name : analysis.bytecodeReads) classBytes.put(name, FabricSetup.preMixinBytes(name));
        }

        // Write the results.
        Files.createDirectories(out.resolve("jars"));
        List<String> classpath = new ArrayList<>();
        Map<String, String> entryOf = new TreeMap<>();  // each source jar's class path entry for the image
        Set<String> used = new HashSet<>();
        int index = 0, changedJars = 0;
        for (Path jar : sources) {
            index++;
            Map<String, byte[]> replace = new HashMap<>();
            Set<String> drop = new HashSet<>();
            for (String n : entries.get(jar)) {
                if (!isClass(n)) continue;
                String internal = n.substring(0, n.length() - 6);
                if (mixins.contains(internal)) {
                    drop.add(n);
                    continue;
                }
                byte[] captured = Capture.CLASSES.get(internal);
                if (captured != null && jar.equals(owner.get(internal))) {
                    used.add(internal);
                    if (!Arrays.equals(captured, read(jar, n))) replace.put(n, captured);
                }
            }
            if (replace.isEmpty() && drop.isEmpty() || !Files.isRegularFile(jar)) {
                classpath.add(jar.toString());
                entryOf.put(jar.toString(), jar.toString());
                continue;
            }
            Path flat = out.resolve("jars").resolve(String.format("%02d-%s", index, jar.getFileName()));
            writeFlat(jar, flat, replace, drop);
            classpath.add(flat.toString());
            entryOf.put(jar.toString(), flat.toString());
            changedJars++;
        }
        TreeMap<String, byte[]> generated = new TreeMap<>();
        Capture.CLASSES.forEach((n, b) -> { if (!used.contains(n)) generated.put(n + ".class", b); });
        StringBuilder props = new StringBuilder();
        facts.forEach((k, v) -> props.append(k).append('=').append(v).append('\n'));
        generated.put("mctv-aot/game.properties", props.toString().getBytes(StandardCharsets.UTF_8));
        classBytes.forEach((name, bytes) -> generated.put("mctv-aot/classes/" + name + ".class", bytes));
        Path generatedJar = out.resolve("generated.jar");
        writeJar(generatedJar, generated);
        classpath.add(generatedJar.toString());

        Map<String, Object> report = new TreeMap<>();
        report.put("unresolvedEntrypoints", unresolvedEntrypoints);
        report.put("mode", fabric ? "fabric" : "vanilla");
        report.put("classpath", classpath);
        report.put("entryOf", entryOf);
        report.put("mods", mods);
        report.put("facts", facts);
        report.put("failed", failed);
        List<Object> reflection = analysis.metadata();
        Map<String, Object> metadata = new TreeMap<>();
        metadata.put("reflection", reflection);
        if (!classBytes.isEmpty()) metadata.put("resources", List.of(Map.of("glob", "mctv-aot/classes/**")));
        Files.createDirectories(out.resolve("metadata"));
        Files.writeString(out.resolve("metadata/reachability-metadata.json"), Json.write(metadata) + "\n");
        List<Map<String, String>> sites = new ArrayList<>(analysis.sites);
        sites.sort(java.util.Comparator.comparing((Map<String, String> m) -> m.get("jar")).thenComparing(m -> m.get("site")).thenComparing(m -> m.get("api")));
        Files.writeString(out.resolve("audit.json"), Json.write(Map.of("sites", new ArrayList<>(new java.util.LinkedHashSet<>(sites)))) + "\n");
        report.put("counts", Map.of("classes", owner.size(), "captured", Capture.CLASSES.size(),
                "changedJars", changedJars, "generated", generated.size() - 1 - classBytes.size(), "failed", failed.size(),
                "mixins", mixins.size(), "registered", reflection.size(), "sites", new java.util.LinkedHashSet<>(sites).size(),
                "bytecodeReads", classBytes.size()));
        Files.writeString(out.resolve("bake.json"), Json.write(report) + "\n");
        System.out.printf("[bake] %d classes, %d captured, %d jars changed, %d generated, %d mixins left out, %d couldn't load%n",
                owner.size(), Capture.CLASSES.size(), changedJars, generated.size() - 1, mixins.size(), failed.size());
        System.exit(0);  // mods may have started threads
    }

    private static boolean isClass(String entry) {
        return entry.endsWith(".class") && !entry.startsWith("META-INF/")
                && !entry.endsWith("module-info.class") && !entry.endsWith("package-info.class");
    }

    private static boolean isPlatform(String internal) {
        try {
            Class.forName(internal.replace('/', '.'), false, ClassLoader.getPlatformClassLoader());
            return true;
        } catch (Throwable t) {
            return false;
        }
    }

    private static void load(ClassLoader loader, String internal, Map<String, String> failed, Set<String> mixins) {
        try {
            Class.forName(internal.replace('/', '.'), false, loader);
        } catch (Throwable t) {
            Throwable root = t;
            while (root.getCause() != null && root.getCause() != root) root = root.getCause();
            // Mixin refuses to load its own classes, and anything else in a mixin package
            if (root.getClass().getName().equals("org.spongepowered.asm.mixin.transformer.throwables.IllegalClassLoadError")) {
                mixins.add(internal);
                return;
            }
            String why = describe(t) + (root != t ? " <- " + describe(root) : "");
            failed.put(internal.replace('/', '.'), why);
        }
    }

    private static final String MIXIN_MERGED = "Lorg/spongepowered/asm/mixin/transformer/meta/MixinMerged;";

    /** The session ids in Mixin's @MixinMerged marks, to check they're Capture's. */
    private static Set<String> mixinSessions(java.util.Collection<byte[]> classes) {
        Set<String> sessions = new TreeSet<>();
        byte[] marker = MIXIN_MERGED.getBytes(StandardCharsets.US_ASCII);
        for (byte[] bytes : classes) {
            if (indexOf(bytes, marker, 0) < 0) continue;
            ClassModel model = ClassFile.of().parse(bytes);
            List<java.lang.classfile.AttributedElement> members = new ArrayList<>(model.methods());
            members.addAll(model.fields());
            for (java.lang.classfile.AttributedElement m : members)
                for (RuntimeVisibleAnnotationsAttribute a : m.findAttributes(Attributes.runtimeVisibleAnnotations()))
                    for (Annotation an : a.annotations())
                        if (an.className().equalsString(MIXIN_MERGED))
                            for (AnnotationElement el : an.elements())
                                if (el.name().equalsString("sessionId") && el.value() instanceof AnnotationValue.OfString v)
                                    sessions.add(v.stringValue());
        }
        for (String session : sessions)
            if (session.length() != 36) throw new IllegalStateException("unexpected Mixin session id " + session);
        return sessions;
    }

    private static int indexOf(byte[] haystack, byte[] needle, int from) {
        outer:
        for (int i = from; i <= haystack.length - needle.length; i++) {
            for (int j = 0; j < needle.length; j++) if (haystack[i + j] != needle[j]) continue outer;
            return i;
        }
        return -1;
    }

    private static String describe(Throwable t) {
        String msg = t.getMessage() == null ? "" : t.getMessage().lines().findFirst().orElse("");
        return t.getClass().getSimpleName() + ": " + msg;
    }

    private static List<String> list(Path source) throws IOException {
        if (Files.isDirectory(source)) {
            try (Stream<Path> s = Files.walk(source)) {
                return s.filter(Files::isRegularFile).map(p -> source.relativize(p).toString().replace('\\', '/')).sorted().toList();
            }
        }
        if (!Files.isRegularFile(source)) return List.of();
        try (ZipFile z = new ZipFile(source.toFile())) {
            return Collections.list(z.entries()).stream().map(ZipEntry::getName).toList();
        }
    }

    private static byte[] read(Path source, String entry) throws IOException {
        if (Files.isDirectory(source)) return Files.readAllBytes(source.resolve(entry));
        try (ZipFile z = new ZipFile(source.toFile()); InputStream s = z.getInputStream(z.getEntry(entry))) {
            return s.readAllBytes();
        }
    }

    /**
     * The jar with its classes replaced. Signatures go, since the classes
     * changed, and so do nested jars, which Fabric reads from the original.
     */
    private static void writeFlat(Path jar, Path flat, Map<String, byte[]> replace, Set<String> drop) throws IOException {
        Path tmp = flat.resolveSibling(flat.getFileName() + ".part");
        try (ZipFile z = new ZipFile(jar.toFile()); OutputStream f = Files.newOutputStream(tmp); ZipOutputStream o = new ZipOutputStream(f)) {
            for (ZipEntry e : Collections.list(z.entries())) {
                String n = e.getName();
                if (drop.contains(n) || n.startsWith("META-INF/jars/") || n.matches("META-INF/[^/]+\\.(SF|RSA|EC|DSA)")) continue;
                byte[] bytes;
                if (n.equals(JarFile.MANIFEST_NAME)) {
                    Manifest m = new Manifest(z.getInputStream(e));
                    m.getEntries().clear();  // per-entry digests
                    java.io.ByteArrayOutputStream b = new java.io.ByteArrayOutputStream();
                    m.write(b);
                    bytes = b.toByteArray();
                } else if (replace.containsKey(n)) {
                    bytes = replace.get(n);
                } else if (e.isDirectory()) {
                    bytes = null;
                } else {
                    try (InputStream s = z.getInputStream(e)) { bytes = s.readAllBytes(); }
                }
                put(o, n, bytes);
            }
        }
        Files.move(tmp, flat, StandardCopyOption.REPLACE_EXISTING);
    }

    private static void writeJar(Path jar, TreeMap<String, byte[]> files) throws IOException {
        Path tmp = jar.resolveSibling(jar.getFileName() + ".part");
        try (OutputStream f = Files.newOutputStream(tmp); ZipOutputStream o = new ZipOutputStream(f)) {
            for (Map.Entry<String, byte[]> e : files.entrySet()) put(o, e.getKey(), e.getValue());
        }
        Files.move(tmp, jar, StandardCopyOption.REPLACE_EXISTING);
    }

    private static void put(ZipOutputStream o, String name, byte[] bytes) throws IOException {
        ZipEntry e = new ZipEntry(name);
        e.setTimeLocal(EPOCH);
        o.putNextEntry(e);
        if (bytes != null) o.write(bytes);
        o.closeEntry();
    }
}
