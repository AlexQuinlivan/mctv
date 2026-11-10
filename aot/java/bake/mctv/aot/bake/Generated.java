package mctv.aot.bake;

import java.io.IOException;
import java.io.UncheckedIOException;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.Method;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.ProtectionDomain;
import java.util.ArrayList;
import java.util.List;
import java.util.Map;
import java.util.TreeMap;
import java.util.concurrent.ConcurrentHashMap;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * Java agent mode for traced runs (aot.py run --trace): records classes a mod
 * defines while the game runs, which no jar on the class path has, such as
 * Sodium's vertex serializers. An image can't define classes, but it can serve
 * ones it was given as predefined classes, matched by a digest of their bytes.
 * At exit they're added to out/predefined-classes-config.json and
 * out/agent-extracted-predefined-classes/HASH.classdata, the format native-image
 * reads, hashed with Graal's own Digest.
 *
 *   java -javaagent:bake.jar=generated=<out dir> --add-modules jdk.graal.compiler
 *       --add-exports jdk.graal.compiler/jdk.graal.compiler.util=ALL-UNNAMED ...
 */
final class Generated implements ClassFileTransformer {
    private static final Pattern PROXY = Pattern.compile("(.*/)?\\$Proxy\\d+");
    private final Map<String, byte[]> classes = new ConcurrentHashMap<>();

    static void start(Path out, Instrumentation inst) {
        Generated g = new Generated();
        inst.addTransformer(g, false);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> g.write(out)));
    }

    @Override
    public byte[] transform(ClassLoader loader, String name, Class<?> redefining, ProtectionDomain domain, byte[] bytes) {
        if (name != null && redefining == null && loader != null && !PROXY.matcher(name).matches()
                && loader.getResource(name + ".class") == null) classes.put(name, bytes.clone());
        return null;
    }

    private void write(Path out) {
        try {
            Method digest = Class.forName("jdk.graal.compiler.util.Digest").getMethod("digest", byte[].class, int.class, int.class);
            Path data = out.resolve("agent-extracted-predefined-classes");
            Files.createDirectories(data);
            Path config = out.resolve("predefined-classes-config.json");
            Map<String, String> all = new TreeMap<>();  // hash -> name, with what earlier runs recorded
            if (Files.exists(config)) {
                Matcher m = Pattern.compile("\"hash\"\\s*:\\s*\"([^\"]+)\"\\s*,\\s*\"nameInfo\"\\s*:\\s*\"([^\"]+)\"").matcher(Files.readString(config));
                while (m.find()) all.put(m.group(1), m.group(2));
            }
            for (Map.Entry<String, byte[]> e : classes.entrySet()) {
                byte[] b = e.getValue();
                String hash = (String) digest.invoke(null, b, 0, b.length);
                Files.write(data.resolve(hash + ".classdata"), b);
                all.put(hash, e.getKey().replace('/', '.'));
            }
            List<Object> list = new ArrayList<>();
            all.forEach((hash, name) -> list.add(Map.of("hash", hash, "nameInfo", name)));
            Files.writeString(config, Json.write(List.of(Map.of("type", "agent-extracted", "classes", list))) + "\n");
            System.err.println("[generated] " + classes.size() + " classes defined at run time, " + all.size() + " recorded in all");
        } catch (IOException e) {
            throw new UncheckedIOException(e);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("needs --add-modules jdk.graal.compiler --add-exports jdk.graal.compiler/jdk.graal.compiler.util=ALL-UNNAMED", e);
        }
    }
}
