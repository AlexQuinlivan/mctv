package mctv.aot.bake;

import java.util.ArrayList;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.TreeMap;
import java.util.TreeSet;
import java.util.regex.Pattern;

import org.objectweb.asm.ClassReader;
import org.objectweb.asm.Handle;
import org.objectweb.asm.Opcodes;
import org.objectweb.asm.Type;
import org.objectweb.asm.tree.AbstractInsnNode;
import org.objectweb.asm.tree.ClassNode;
import org.objectweb.asm.tree.FieldInsnNode;
import org.objectweb.asm.tree.IntInsnNode;
import org.objectweb.asm.tree.InvokeDynamicInsnNode;
import org.objectweb.asm.tree.LdcInsnNode;
import org.objectweb.asm.tree.MethodInsnNode;
import org.objectweb.asm.tree.MethodNode;
import org.objectweb.asm.tree.VarInsnNode;
import org.objectweb.asm.tree.analysis.Analyzer;
import org.objectweb.asm.tree.analysis.AnalyzerException;
import org.objectweb.asm.tree.analysis.Frame;
import org.objectweb.asm.tree.analysis.SourceInterpreter;
import org.objectweb.asm.tree.analysis.SourceValue;

/**
 * What the image needs that the classes themselves say, found by dataflow
 * over every method that uses a dynamic feature (ASM's SourceInterpreter
 * tells where each argument came from, and Flow follows that back through
 * locals, casts, dups, Class.forName, ClassLoader.loadClass and javac 1.4's
 * class$ caches).
 *
 * A reflective lookup whose class and member name are each one constant,
 * with the class a literal or Class.forName of a constant, needs nothing,
 * since GraalVM folds it. One GraalVM can't fold (a dynamic name, a class
 * from loadClass, or one of several constants) gets every member of that
 * kind of each class registered.
 *
 * A method that only reflects on what it's given (a Class parameter, or a
 * class name it passes to Class.forName, like Minecraft's VulkanPNextStruct
 * and Sodium's DependencyInjection), or proxies a given interface, or makes
 * a Fabric event of a given type, is checked at its callers instead: each
 * constant passed gets what the method needs (a Need). A caller passing on
 * its own parameter takes on the same need, and the callers pass repeats
 * (Bake) until no new one turns up.
 *
 * What's left is a site, written to audit.json with where its values come
 * from, for aot.py audit to check against aot/reviewed.json: a lookup on a
 * class that isn't known, a method whose callers pass something that isn't
 * constant (or refer to it as a method reference), a class defined or its
 * bytes read at run time, and native code, meaning a library loaded or a
 * call through FFM, which needs a library built for tvOS.
 *
 * Also found: Fabric events (a proxy of the event's interface for its empty
 * invoker, and an array of it for its listeners) and classes whose bytes
 * are read by a constant name (Mixin's getClassNode, Fabric's
 * getClassByteArray). Classes for other operating systems (aot/fixups.json,
 * otherPlatforms) are skipped, so nothing they'd reflect on is registered.
 */
final class Analysis {
    final Map<String, Map<String, Object>> reflection = new TreeMap<>();  // type -> what's registered
    final Set<String> bytecodeReads = new TreeSet<>();
    final Set<String> proxies = new TreeSet<>();  // Fabric events and method-reference entrypoints: a proxy and an array
    final Set<List<String>> interfaceProxies = new HashSet<>();  // Proxy.newProxyInstance's interface lists
    final List<Map<String, String>> sites = new ArrayList<>();

    /**
     * What a method needs for one of its parameters, met at its callers.
     * byName: the argument is a class's name (for Class.forName) rather than
     * a Class. what: "type" (only that Class.forName finds it), "kind" (arg
     * is a registration such as allPublicMethods), "field" (arg is its name),
     * "fieldAt" (arg is the parameter holding its name), "event" (a Fabric
     * event's proxy and array) or "interface" (a proxy of it).
     */
    record Need(boolean byName, String what, String arg) implements Comparable<Need> {
        public int compareTo(Need o) {
            return toString().compareTo(o.toString());
        }
    }

    // "owner.name desc" -> parameter -> needs, where the method was found, and why a caller left it a site
    private final Map<String, Map<Integer, Set<Need>>> needs = new TreeMap<>();
    private final Map<String, Map<String, String>> needSites = new TreeMap<>();
    private final Map<String, Set<String>> dynamicCallers = new TreeMap<>();
    private final List<Pattern> otherPlatforms = new ArrayList<>();
    private final Map<String, List<String>> supertypes = new java.util.HashMap<>();  // class -> its superclass and interfaces

    private static final Map<String, String> MEMBER_KIND = Map.ofEntries(
            Map.entry("getDeclaredField", "allDeclaredFields"), Map.entry("getField", "allPublicFields"),
            Map.entry("getDeclaredMethod", "allDeclaredMethods"), Map.entry("getMethod", "allPublicMethods"),
            Map.entry("getDeclaredConstructor", "allDeclaredConstructors"), Map.entry("getConstructor", "allPublicConstructors"),
            Map.entry("getDeclaredFields", "allDeclaredFields"), Map.entry("getFields", "allPublicFields"),
            Map.entry("getDeclaredMethods", "allDeclaredMethods"), Map.entry("getMethods", "allPublicMethods"),
            Map.entry("getDeclaredConstructors", "allDeclaredConstructors"), Map.entry("getConstructors", "allPublicConstructors"),
            Map.entry("newInstance", "allDeclaredConstructors"), Map.entry("getRecordComponents", "allDeclaredMethods"));
    private static final Map<String, String> LOOKUP_KIND = Map.of(
            "findVirtual", "allDeclaredMethods", "findStatic", "allDeclaredMethods", "findSpecial", "allDeclaredMethods",
            "findConstructor", "allDeclaredConstructors", "findGetter", "allDeclaredFields", "findSetter", "allDeclaredFields",
            "findStaticGetter", "allDeclaredFields", "findStaticSetter", "allDeclaredFields", "findVarHandle", "allDeclaredFields",
            "findStaticVarHandle", "allDeclaredFields");

    /** The calls the analysis looks at. */
    private enum Api { MEMBER, BY_NAME, LOOKUP, DEFINE, PROXY, BYTES, EVENT, LIBRARY, FOREIGN }

    private static Api api(MethodInsnNode c) {
        String o = c.owner, n = c.name;
        if (o.equals("java/lang/Class") && MEMBER_KIND.containsKey(n)) return Api.MEMBER;
        if (o.equals("java/lang/Class") && n.equals("forName") || isLoadClass(c)) return Api.BY_NAME;
        if (o.equals("java/lang/invoke/MethodHandles$Lookup") && LOOKUP_KIND.containsKey(n)) return Api.LOOKUP;
        if ((n.equals("defineClass") || n.equals("defineHiddenClass")) && (o.equals("java/lang/ClassLoader")
                || o.equals("java/lang/invoke/MethodHandles$Lookup") || o.endsWith("/Unsafe"))) return Api.DEFINE;
        if (o.equals("java/lang/reflect/Proxy") && n.equals("newProxyInstance")) return Api.PROXY;
        if ((n.equals("getClassNode") || n.equals("getClassByteArray")) && c.desc.startsWith("(Ljava/lang/String;")) return Api.BYTES;
        if (o.equals("net/fabricmc/fabric/api/event/EventFactory") && n.equals("createArrayBacked")
                && c.desc.equals("(Ljava/lang/Class;Ljava/util/function/Function;)Lnet/fabricmc/fabric/api/event/Event;")) return Api.EVENT;
        if ((o.equals("java/lang/System") || o.equals("java/lang/Runtime")) && (n.equals("load") || n.equals("loadLibrary"))
                || o.equals("java/lang/foreign/SymbolLookup") && n.equals("libraryLookup")) return Api.LIBRARY;
        if (o.equals("java/lang/foreign/Linker") && (n.equals("downcallHandle") || n.equals("upcallStub"))) return Api.FOREIGN;
        return null;
    }

    /** ClassLoader.loadClass, on any loader. */
    private static boolean isLoadClass(MethodInsnNode c) {
        return c.name.equals("loadClass") && c.getOpcode() != Opcodes.INVOKESTATIC
                && (c.desc.equals("(Ljava/lang/String;)Ljava/lang/Class;") || c.desc.equals("(Ljava/lang/String;Z)Ljava/lang/Class;"));
    }

    // --- set up ---------------------------------------------------------------

    /**
     * Every class literal in these classes gets its constructors, and every
     * class is registered, which in GraalVM 25 lets all its members be
     * queried (getDeclaredMethod and the like, as Lithium does) but not invoked.
     */
    void gameRules(Map<String, byte[]> gameClasses, Set<String> known) {
        for (Map.Entry<String, byte[]> e : gameClasses.entrySet()) {
            type(e.getKey());
            ClassNode node = parse(e.getValue());
            for (MethodNode m : node.methods)
                for (AbstractInsnNode i : m.instructions)
                    if (i instanceof LdcInsnNode ldc && ldc.cst instanceof Type t && t.getSort() == Type.OBJECT
                            && gameClasses.containsKey(t.getInternalName()))
                        register(t.getInternalName(), "allDeclaredConstructors");
        }
    }

    /** Classes for other operating systems (aot/fixups.json, otherPlatforms), as globs over class names where * spans dots. */
    void otherPlatforms(java.util.Collection<String> globs) {
        for (String g : globs) otherPlatforms.add(Pattern.compile(Pattern.quote(g).replace("*", "\\E.*\\Q")));
    }

    /**
     * Needs stated in aot/fixups.json (reflectsOnParameter), for methods whose
     * reflection the dataflow can't follow: "owner.name desc" -> parameter ->
     * registrations, or "field:NAME".
     */
    void declareNeeds(com.google.gson.JsonObject declared) {
        for (String key : declared.keySet()) {
            com.google.gson.JsonObject byParam = declared.getAsJsonObject(key);
            for (String param : byParam.keySet()) {
                if (param.equals("why")) continue;
                for (var kind : byParam.getAsJsonArray(param)) {
                    String k = kind.getAsString();
                    need(key, Integer.parseInt(param), k.startsWith("field:") ? new Need(false, "field", k.substring(6)) : new Need(false, "kind", k));
                }
            }
            needSites.putIfAbsent(key, siteOf("fixups.json", key, "reflectsOnParameter", "declared in aot/fixups.json"));
        }
    }

    /** Code that never runs on macOS or tvOS: nothing it reflects on is registered, and it has no sites. */
    private boolean otherPlatform(ClassNode node) {
        String name = node.name.replace('/', '.');
        for (Pattern p : otherPlatforms) if (p.matcher(name).matches()) return true;
        return false;
    }

    // --- first pass -------------------------------------------------------------

    private static final byte[][] MARKERS;
    static {
        List<byte[]> markers = new ArrayList<>();
        for (String m : List.of("getDeclared", "getMethod", "getField", "getConstructor", "forName", "loadClass", "newInstance",
                "getRecordComponents", "MethodHandles$Lookup", "newProxyInstance", "defineClass", "defineHiddenClass",
                "getClassNode", "getClassByteArray", "createArrayBacked", "loadLibrary", "libraryLookup", "downcallHandle", "upcallStub"))
            markers.add(m.getBytes(java.nio.charset.StandardCharsets.US_ASCII));
        markers.add(new byte[] {1, 0, 4, 'l', 'o', 'a', 'd'});  // a constant that's exactly "load" (System.load)
        MARKERS = markers.toArray(byte[][]::new);
    }

    /** A cheap look at the constant pool, so most classes needn't be parsed. */
    static boolean mightUseDynamicFeatures(byte[] bytes) {
        for (byte[] m : MARKERS) {
            outer:
            for (int i = 0; i <= bytes.length - m.length; i++) {
                for (int j = 0; j < m.length; j++) if (bytes[i + j] != m[j]) continue outer;
                return true;
            }
        }
        return false;
    }

    /** One call to an API the analysis looks at, with what's on the stack for it. */
    private record Call(String jar, ClassNode node, MethodNode m, MethodInsnNode insn, Frame<SourceValue> frame, Flow flow) {
        int args() { return Type.getArgumentCount(insn.desc); }
        SourceValue arg(int i) { return frame.getStack(frame.getStackSize() - args() + i); }
        SourceValue receiver() { return frame.getStack(frame.getStackSize() - args() - 1); }
        String key() { return node.name + "." + m.name + " " + m.desc; }
        String site() { return node.name.replace('/', '.') + "#" + m.name; }
        String api() { return insn.owner.substring(insn.owner.lastIndexOf('/') + 1) + "." + insn.name; }
    }

    void scan(String jar, byte[] bytes) {
        ClassNode node = parse(bytes);
        if (otherPlatform(node)) return;
        for (MethodNode m : node.methods) {
            boolean interesting = false;
            for (AbstractInsnNode i : m.instructions) if (i instanceof MethodInsnNode c && api(c) != null) interesting = true;
            if (!interesting) continue;
            Frame<SourceValue>[] frames;
            try {
                frames = new Analyzer<>(new SourceInterpreter()).analyze(node.name, m);
            } catch (AnalyzerException | RuntimeException ex) {
                sites.add(siteOf(jar, node.name.replace('/', '.') + "#" + m.name, "unanalysable method", String.valueOf(ex.getMessage())));
                continue;
            }
            Flow flow = new Flow(m, frames);
            for (int idx = 0; idx < m.instructions.size(); idx++) {
                if (!(m.instructions.get(idx) instanceof MethodInsnNode insn) || frames[idx] == null) continue;
                Api api = api(insn);
                if (api == null) continue;
                Call c = new Call(jar, node, m, insn, frames[idx], flow);
                switch (api) {
                    case MEMBER -> member(c);
                    case BY_NAME -> byName(c);
                    case LOOKUP -> lookup(c);
                    case DEFINE -> site(c, "defines a class while running");
                    case PROXY -> proxy(c);
                    case BYTES -> bytes(c);
                    case EVENT -> event(c);
                    case LIBRARY -> site(c, "loads native library " + flow.describe(c.arg(0)));
                    case FOREIGN -> site(c, insn.name.equals("upcallStub") ? "makes a native callback through FFM" : "calls native code through FFM");
                }
            }
        }
    }

    /** Class.getDeclaredMethod and the like. */
    private void member(Call c) {
        Flow flow = c.flow();
        SourceValue receiver = c.receiver();
        String lookup = c.insn().name;
        boolean isField = lookup.matches("get(Declared)?Field");
        String name = c.args() > 0 ? flow.stringConstant(c.arg(0)) : "";
        int nameParam = name == null && c.args() > 0 ? flow.parameter(c.arg(0)) : -1;
        Set<String> classes = flow.constantClasses(receiver);
        if (flow.allClasses(receiver)) {
            // one class and a constant name GraalVM folds; anything less it can't
            if (classes.size() > 1 || name == null || c.args() == 0 || !flow.folds(receiver))
                for (String cls : classes) member(cls, lookup, name, isField);
            return;
        }
        for (String cls : classes) member(cls, lookup, name, isField);  // the constant ones, whatever else it can be
        String what = isField && name != null ? "field" : isField && nameParam >= 0 ? "fieldAt" : "kind";
        String arg = what.equals("field") ? name : what.equals("fieldAt") ? String.valueOf(nameParam) : MEMBER_KIND.get(lookup);
        if (!onParameter(c, receiver, what, arg))
            site(c, "class from " + flow.describe(receiver) + (c.args() > 0 && name == null ? ", name from " + flow.describe(c.arg(0)) : ""));
    }

    /** Class.forName and ClassLoader.loadClass. */
    private void byName(Call c) {
        Flow flow = c.flow();
        SourceValue arg = c.arg(c.insn().desc.startsWith("(Ljava/lang/Module;") ? 1 : 0);
        Set<String> names = flow.stringConstants(arg);
        boolean all = flow.allConstant(arg);
        if (names.size() > 1 || !all || isLoadClass(c.insn()))  // Class.forName of one constant GraalVM folds
            for (String n : names) type(n);
        if (all) return;
        int param = names.isEmpty() ? flow.parameter(arg) : -1;
        if (param >= 0) need(c, param, new Need(true, "type", null), "looks up a class named by its parameter " + param);
        else site(c, "name from " + flow.describe(arg));
    }

    /** MethodHandles.Lookup.findVirtual and the like. */
    private void lookup(Call c) {
        Flow flow = c.flow();
        SourceValue receiver = c.arg(0);
        String kind = LOOKUP_KIND.get(c.insn().name);
        Set<String> classes = flow.constantClasses(receiver);
        boolean all = flow.allClasses(receiver);
        String name = c.insn().name.equals("findConstructor") ? "" : flow.stringConstant(c.arg(1));
        if (!all || classes.size() > 1 || name == null || !flow.folds(receiver))
            for (String cls : classes) register(cls, kind);
        if (!all && !onParameter(c, receiver, "kind", kind)) site(c, "class from " + flow.describe(receiver));
    }

    /**
     * A lookup on a class the method was given, as a Class or as the name of
     * one it passes to Class.forName: a need, met at its callers. False if
     * the class came from anywhere else.
     */
    private boolean onParameter(Call c, SourceValue classValue, String what, String arg) {
        int param = c.flow().parameter(classValue);
        if (param >= 0) {
            need(c, param, new Need(false, what, arg), c.api() + " on the class in its parameter " + param);
            return true;
        }
        param = c.flow().nameParameter(classValue);
        if (param >= 0) {
            need(c, param, new Need(true, what, arg), c.api() + " on the class named by its parameter " + param);
            return true;
        }
        return false;
    }

    /** Proxy.newProxyInstance. */
    private void proxy(Call c) {
        Flow flow = c.flow();
        List<SourceValue> elements = flow.arrayElements(c.arg(1));
        List<String> interfaces = new ArrayList<>();
        for (SourceValue e : elements == null ? List.<SourceValue>of() : elements) interfaces.add(flow.classConstant(e));
        if (elements != null && !elements.isEmpty() && !interfaces.contains(null)) {
            interfaceProxies.add(interfaces.stream().map(i -> i.replace('/', '.')).toList());
            return;
        }
        int param = elements != null && elements.size() == 1 ? flow.parameter(elements.get(0)) : -1;
        if (param >= 0) need(c, param, new Need(false, "interface", null), "proxies the interface in its parameter " + param);
        else site(c, "proxies " + (elements == null ? "interfaces from " + flow.describe(c.arg(1))
                : elements.stream().map(flow::describe).toList()));
    }

    /** Mixin's getClassNode and Fabric's getClassByteArray. */
    private void bytes(Call c) {
        String cls = c.flow().stringConstant(c.arg(0));
        if (cls != null) bytecodeReads.add(cls.replace('.', '/'));
        else site(c, "reads the bytes of a class named by " + c.flow().describe(c.arg(0)));
    }

    /** EventFactory.createArrayBacked. */
    private void event(Call c) {
        String cls = c.flow().classConstant(c.arg(0));
        int param = cls == null ? c.flow().parameter(c.arg(0)) : -1;
        if (cls != null) proxies.add(cls.replace('/', '.'));
        else if (param >= 0) need(c, param, new Need(false, "event", null), "makes a Fabric event of the type in its parameter " + param);
        else site(c, "makes a Fabric event of type " + c.flow().describe(c.arg(0)));
    }

    /** What a Class.getX lookup on a known class needs: the named field, or every member of its kind. */
    private void member(String cls, String lookup, String name, boolean isField) {
        if (isField && name != null) field(cls, name);
        else register(cls, MEMBER_KIND.get(lookup));
    }

    // --- callers pass ------------------------------------------------------------

    /** Records a class's superclass and interfaces, for liftNeeds. Every class goes through here. */
    void hierarchy(byte[] bytes) {
        ClassReader r = new ClassReader(bytes);
        List<String> up = new ArrayList<>(List.of(r.getInterfaces()));
        if (r.getSuperName() != null) up.add(0, r.getSuperName());
        supertypes.put(r.getClassName(), up);
    }

    /**
     * A method with needs may be called through a superclass or interface
     * method it overrides (Xaero's IObfuscatedReflection), so each need goes
     * on those too, where its callers are checked the same way. True if any
     * is new.
     */
    boolean liftNeeds() {
        boolean grew = false;
        for (String key : List.copyOf(needs.keySet())) {
            int dot = key.indexOf('.');
            String owner = key.substring(0, dot), method = key.substring(dot);
            if (method.startsWith(".<init> ") || method.startsWith(".<clinit> ")) continue;
            Set<String> seen = new HashSet<>();
            List<String> todo = new ArrayList<>(supertypes.getOrDefault(owner, List.of()));
            while (!todo.isEmpty()) {
                String up = todo.remove(todo.size() - 1);
                if (up.equals("java/lang/Object") || !seen.add(up)) continue;
                todo.addAll(supertypes.getOrDefault(up, List.of()));
                for (Map.Entry<Integer, Set<Need>> w : needs.get(key).entrySet())
                    for (Need n : w.getValue()) grew |= need(up + method, w.getKey(), n);
                Map<String, String> s = needSites.get(key);
                needSites.putIfAbsent(up + method, siteOf(s.get("jar"), s.get("site"), s.get("api"),
                        s.get("detail") + ", called through " + up.replace('/', '.')));
            }
        }
        return grew;
    }

    /** Whether any class calls a method that reflects on its parameters (cheap, for scanCalls). */
    boolean hasNeeds() {
        return !needs.isEmpty();
    }

    /**
     * Callers of methods with needs. A constant argument gets what the method
     * needs. A caller passing on its own parameter takes on the need, so Bake
     * repeats this pass until no caller like that is new: true if this class
     * had one.
     */
    boolean scanCalls(String jar, byte[] bytes) {
        ClassNode node = parse(bytes);
        if (otherPlatform(node)) return false;
        boolean grew = false;
        for (MethodNode m : node.methods) {
            String where = node.name.replace('/', '.') + "#" + m.name;
            boolean calls = false;
            for (AbstractInsnNode i : m.instructions) {
                if (i instanceof MethodInsnNode c && needs.containsKey(c.owner + "." + c.name + " " + c.desc)) calls = true;
                // a method reference or handle: its arguments come from wherever it's called, so they're unknown
                for (Object cst : i instanceof InvokeDynamicInsnNode indy ? indy.bsmArgs : i instanceof LdcInsnNode ldc ? new Object[] {ldc.cst} : new Object[0])
                    if (cst instanceof Handle h && needs.containsKey(h.getOwner() + "." + h.getName() + " " + h.getDesc()))
                        dynamic(h.getOwner() + "." + h.getName() + " " + h.getDesc(), where + " refers to it as a method reference");
            }
            if (!calls) continue;
            Frame<SourceValue>[] frames;
            try {
                frames = new Analyzer<>(new SourceInterpreter()).analyze(node.name, m);
            } catch (AnalyzerException | RuntimeException ex) {
                for (AbstractInsnNode i : m.instructions)
                    if (i instanceof MethodInsnNode c && needs.containsKey(c.owner + "." + c.name + " " + c.desc))
                        dynamic(c.owner + "." + c.name + " " + c.desc, where + " couldn't be analysed");
                continue;
            }
            Flow flow = new Flow(m, frames);
            String self = node.name + "." + m.name + " " + m.desc;
            for (int idx = 0; idx < m.instructions.size(); idx++) {
                if (!(m.instructions.get(idx) instanceof MethodInsnNode call) || frames[idx] == null) continue;
                String key = call.owner + "." + call.name + " " + call.desc;
                Map<Integer, Set<Need>> want = needs.get(key);
                if (want == null) continue;
                Frame<SourceValue> f = frames[idx];
                int first = f.getStackSize() - Type.getArgumentCount(call.desc);
                for (Map.Entry<Integer, Set<Need>> w : List.copyOf(want.entrySet())) {
                    SourceValue arg = f.getStack(first + w.getKey());
                    int passed = flow.parameter(arg);
                    if (passed >= 0 && !self.equals(key)) {  // the caller's own parameter: its callers decide
                        for (Need n : List.copyOf(w.getValue())) {
                            Need carried = carry(n, f, first, flow);
                            if (carried == null) dynamic(key, where + " passes a field name that isn't constant");
                            else if (need(self, passed, carried)) grew = true;
                        }
                        Map<String, String> callee = needSites.get(key);
                        needSites.putIfAbsent(self, siteOf(jar, where, callee.get("api"),
                                "passes its parameter " + passed + " on to " + callee.get("site") + ", which " + callee.get("detail")));
                        continue;
                    }
                    for (Need n : List.copyOf(w.getValue())) {
                        Set<String> classes = n.byName() ? (flow.allConstant(arg) ? flow.stringConstants(arg) : null)
                                : (flow.allClasses(arg) ? flow.constantClasses(arg) : null);
                        if (classes == null) {
                            dynamic(key, where + " passes " + flow.describe(arg));
                            continue;
                        }
                        for (String cls : classes) {
                            String internal = cls.replace('.', '/');
                            if (n.byName()) type(internal);
                            if (!apply(n, internal, f, first, flow)) dynamic(key, where + " passes a field name that isn't constant");
                        }
                    }
                }
            }
        }
        return grew;
    }

    /** A need as it is for a caller that passes the argument on as its own parameter, or null if it can't be. */
    private static Need carry(Need n, Frame<SourceValue> f, int first, Flow flow) {
        if (!n.what().equals("fieldAt")) return n;
        SourceValue name = f.getStack(first + Integer.parseInt(n.arg()));
        int param = flow.parameter(name);
        if (param >= 0) return new Need(n.byName(), "fieldAt", String.valueOf(param));
        String constant = flow.stringConstant(name);
        return constant == null ? null : new Need(n.byName(), "field", constant);
    }

    /** Meets a need for one class, false if it names a field that isn't a constant. */
    private boolean apply(Need n, String cls, Frame<SourceValue> f, int first, Flow flow) {
        switch (n.what()) {
            case "type" -> type(cls);
            case "kind" -> register(cls, n.arg());
            case "field" -> field(cls, n.arg());
            case "fieldAt" -> {
                String name = flow.stringConstant(f.getStack(first + Integer.parseInt(n.arg())));
                if (name == null) return false;
                field(cls, name);
            }
            case "event" -> proxies.add(cls.replace('/', '.'));
            case "interface" -> interfaceProxies.add(List.of(cls.replace('/', '.')));
            default -> throw new IllegalStateException(n.toString());
        }
        return true;
    }

    /** After the callers pass: a method a caller doesn't pass constants to is a site, saying which caller. */
    void finish() {
        dynamicCallers.forEach((key, why) -> {
            Map<String, String> s = needSites.get(key);
            List<String> first = why.stream().limit(3).toList();
            String more = why.size() > 3 ? ", and " + (why.size() - 3) + " more" : "";
            sites.add(siteOf(s.get("jar"), s.get("site"), s.get("api"), s.get("detail") + ". " + String.join(", ", first) + more));
        });
    }

    private void need(Call c, int param, Need n, String detail) {
        need(c.key(), param, n);
        needSites.put(c.key(), siteOf(c.jar(), c.site(), c.api(), detail));
    }

    private boolean need(String key, int param, Need n) {
        return needs.computeIfAbsent(key, k -> new TreeMap<>()).computeIfAbsent(param, k -> new TreeSet<>()).add(n);
    }

    private void dynamic(String key, String why) {
        dynamicCallers.computeIfAbsent(key, k -> new LinkedHashSet<>()).add(why);
    }

    // --- results -----------------------------------------------------------------

    private void site(Call c, String detail) {
        sites.add(siteOf(c.jar(), c.site(), c.api(), detail));
    }

    private static Map<String, String> siteOf(String jar, String site, String api, String detail) {
        return Map.of("jar", jar, "site", site, "api", api, "detail", detail);
    }

    @SuppressWarnings("unchecked")
    private void field(String internal, String name) {
        Map<String, Object> e = reflection.computeIfAbsent(internal.replace('/', '.'), k -> new TreeMap<>());
        List<Object> fields = (List<Object>) e.computeIfAbsent("fields", k -> new ArrayList<>());
        if (!fields.contains(Map.of("name", name))) fields.add(Map.of("name", name));
    }

    /** A class Class.forName can find, and whose members can be queried. */
    private void type(String name) {
        reflection.computeIfAbsent(name.replace('/', '.'), k -> new TreeMap<>());
    }

    private void register(String internal, String what) {
        reflection.computeIfAbsent(internal.replace('/', '.'), k -> new TreeMap<String, Object>()).put(what, true);
    }

    private static ClassNode parse(byte[] bytes) {
        ClassNode node = new ClassNode();
        new ClassReader(bytes).accept(node, ClassReader.SKIP_DEBUG);
        return node;
    }

    /** reachability-metadata.json's reflection entries for what was found. */
    List<Object> metadata() {
        List<Object> out = new ArrayList<>();
        reflection.forEach((type, what) -> {
            Map<String, Object> e = new TreeMap<>(what);
            e.put("type", type);
            out.add(e);
        });
        for (String p : proxies) {  // an event's empty invoker, and the array its listeners are kept in
            out.add(Map.of("type", Map.of("proxy", List.of(p))));
            out.add(Map.of("type", p, "allPublicMethods", true));
            out.add(Map.of("type", p + "[]"));
        }
        interfaceProxies.stream().map(l -> String.join(",", l)).sorted().forEach(joined -> {
            List<String> l = List.of(joined.split(","));
            out.add(Map.of("type", Map.of("proxy", l)));
            for (String i : l) out.add(Map.of("type", i, "allPublicMethods", true));
        });
        return out;
    }

    // --- dataflow within one method -----------------------------------------------

    /** Where values in one method come from. */
    private static final class Flow {
        private final MethodNode m;
        private final Frame<SourceValue>[] frames;

        Flow(MethodNode m, Frame<SourceValue>[] frames) {
            this.m = m;
            this.frames = frames;
        }

        private Frame<SourceValue> at(AbstractInsnNode i) {
            return frames[m.instructions.indexOf(i)];
        }

        /**
         * The instructions a value can have come from, looking through locals,
         * casts, dups and javac 1.4's class caches. A parameter shows up as a
         * load of a local the method never writes. A parameter slot the method
         * also writes shows up as its load too, so it's neither a constant nor
         * a parameter.
         */
        Set<AbstractInsnNode> origins(SourceValue v) {
            Set<AbstractInsnNode> out = new LinkedHashSet<>();
            if (v != null) origins(v, out, new HashSet<>());
            return out;
        }

        private void origins(SourceValue v, Set<AbstractInsnNode> out, Set<AbstractInsnNode> seen) {
            for (AbstractInsnNode i : v.insns) {
                if (!seen.add(i)) continue;
                Frame<SourceValue> f = at(i);
                int op = i.getOpcode();
                if (f == null) {
                    out.add(i);
                } else if (i instanceof VarInsnNode load && op >= Opcodes.ILOAD && op <= Opcodes.ALOAD) {
                    SourceValue local = f.getLocal(load.var);
                    if (local.insns.isEmpty() || load.var < parameterSlots()) out.add(i);
                    else origins(local, out, seen);
                } else if (i instanceof VarInsnNode && op >= Opcodes.ISTORE && op <= Opcodes.ASTORE
                        || op == Opcodes.CHECKCAST || op == Opcodes.DUP) {
                    origins(f.getStack(f.getStackSize() - 1), out, seen);
                } else if (i instanceof FieldInsnNode get && op == Opcodes.GETSTATIC && get.name.startsWith("class$")
                        && get.desc.equals("Ljava/lang/Class;")) {
                    // javac 1.4's class literals: a static class$N field filled by class$("name") in the same method
                    boolean found = false;
                    for (AbstractInsnNode j : m.instructions)
                        if (j instanceof FieldInsnNode put && j.getOpcode() == Opcodes.PUTSTATIC && put.owner.equals(get.owner)
                                && put.name.equals(get.name) && at(j) != null) {
                            origins(at(j).getStack(at(j).getStackSize() - 1), out, seen);
                            found = true;
                        }
                    if (!found) out.add(i);
                } else {
                    out.add(i);
                }
            }
        }

        private int parameterSlots() {
            return (Type.getArgumentsAndReturnSizes(m.desc) >> 2) - ((m.access & Opcodes.ACC_STATIC) != 0 ? 1 : 0);
        }

        /** Which parameter (0-based, not counting this) a value is, unchanged since the method began, or -1. */
        int parameter(SourceValue v) {
            Set<AbstractInsnNode> from = origins(v);
            if (from.size() != 1 || !(from.iterator().next() instanceof VarInsnNode load) || load.getOpcode() > Opcodes.ALOAD) return -1;
            Frame<SourceValue> f = at(load);
            if (f == null || !f.getLocal(load.var).insns.isEmpty()) return -1;  // the method writes it
            int slot = (m.access & Opcodes.ACC_STATIC) != 0 ? 0 : 1;
            Type[] params = Type.getArgumentTypes(m.desc);
            for (int i = 0; i < params.length; i++) {
                if (slot == load.var) return i;
                slot += params[i].getSize();
            }
            return -1;
        }

        /** The parameter holding the name a Class value was looked up by (Class.forName, loadClass, class$), or -1. */
        int nameParameter(SourceValue classValue) {
            Set<AbstractInsnNode> from = origins(classValue);
            if (from.size() != 1 || !(from.iterator().next() instanceof MethodInsnNode c) || !byName(c)) return -1;
            return parameter(nameArgument(c));
        }

        private static boolean byName(MethodInsnNode c) {
            return (c.owner.equals("java/lang/Class") && c.name.equals("forName")
                    || c.getOpcode() == Opcodes.INVOKESTATIC && c.name.equals("class$") || isLoadClass(c))
                    && (c.desc.startsWith("(Ljava/lang/String;") || c.desc.startsWith("(Ljava/lang/Module;Ljava/lang/String;"));
        }

        private SourceValue nameArgument(MethodInsnNode c) {
            Frame<SourceValue> f = at(c);
            if (f == null) return null;
            int first = f.getStackSize() - Type.getArgumentCount(c.desc);
            return f.getStack(c.desc.startsWith("(Ljava/lang/Module;") ? first + 1 : first);
        }

        /** The class a constant origin names (a class literal, or a lookup by a constant name), or null. */
        String classOf(AbstractInsnNode i) {
            if (i instanceof LdcInsnNode ldc && ldc.cst instanceof Type t && t.getSort() == Type.OBJECT) return t.getInternalName();
            if (i instanceof MethodInsnNode c && byName(c)) {
                SourceValue arg = nameArgument(c);
                String name = arg == null ? null : stringConstant(arg);
                return name == null ? null : name.replace('.', '/');
            }
            return null;
        }

        /** Whether GraalVM folds lookups on this class value: a class literal, or Class.forName of a constant. */
        boolean folds(SourceValue v) {
            for (AbstractInsnNode i : origins(v))
                if (!(i instanceof LdcInsnNode) && !(i instanceof MethodInsnNode c && c.owner.equals("java/lang/Class") && c.name.equals("forName")))
                    return false;
            return true;
        }

        /** The internal name of a Class value that's always the same constant class, or null. */
        String classConstant(SourceValue v) {
            return allClasses(v) && constantClasses(v).size() == 1 ? constantClasses(v).iterator().next() : null;
        }

        /** The constant classes among a Class value's origins. */
        Set<String> constantClasses(SourceValue v) {
            Set<String> classes = new TreeSet<>();
            for (AbstractInsnNode i : origins(v)) {
                String c = classOf(i);
                if (c != null) classes.add(c);
            }
            return classes;
        }

        /** Whether every origin of a Class value is a constant class. */
        boolean allClasses(SourceValue v) {
            Set<AbstractInsnNode> from = origins(v);
            for (AbstractInsnNode i : from) if (classOf(i) == null) return false;
            return !from.isEmpty();
        }

        /** A String value that's always the same constant, or a constant class's name, or null. */
        String stringConstant(SourceValue v) {
            Set<String> all = stringConstants(v);
            return all.size() == 1 && allConstant(v) ? all.iterator().next() : null;
        }

        /** The constant strings among a String value's origins. */
        Set<String> stringConstants(SourceValue v) {
            Set<String> out = new TreeSet<>();
            for (AbstractInsnNode i : origins(v)) {
                String s = stringOf(i);
                if (s != null) out.add(s);
            }
            return out;
        }

        boolean allConstant(SourceValue v) {
            Set<AbstractInsnNode> from = origins(v);
            for (AbstractInsnNode i : from) if (stringOf(i) == null) return false;
            return !from.isEmpty();
        }

        private String stringOf(AbstractInsnNode i) {
            if (i instanceof LdcInsnNode ldc && ldc.cst instanceof String s) return s;
            if (i instanceof MethodInsnNode c && (c.owner.equals("org/objectweb/asm/Type") && c.name.equals("getInternalName")
                    || c.owner.equals("java/lang/Class") && c.name.equals("getName"))) {
                Frame<SourceValue> f = at(i);
                String cls = f == null ? null : classConstant(f.getStack(f.getStackSize() - 1));
                return cls == null ? null : c.name.equals("getName") ? cls.replace('/', '.') : cls;
            }
            return null;
        }

        /** The values stored in an array that's made here with a constant length and filled at constant indexes, in order, or null. */
        List<SourceValue> arrayElements(SourceValue array) {
            Set<AbstractInsnNode> from = origins(array);
            if (from.size() != 1 || from.iterator().next().getOpcode() != Opcodes.ANEWARRAY) return null;
            AbstractInsnNode made = from.iterator().next();
            Frame<SourceValue> f0 = at(made);
            Integer length = f0 == null ? null : intConstant(f0.getStack(f0.getStackSize() - 1));
            if (length == null) return null;
            SourceValue[] out = new SourceValue[length];
            for (AbstractInsnNode i : m.instructions) {
                if (i.getOpcode() != Opcodes.AASTORE) continue;
                Frame<SourceValue> f = at(i);
                if (f == null || !origins(f.getStack(f.getStackSize() - 3)).contains(made)) continue;
                Integer index = intConstant(f.getStack(f.getStackSize() - 2));
                if (index == null || index < 0 || index >= length || out[index] != null) return null;
                out[index] = f.getStack(f.getStackSize() - 1);
            }
            for (SourceValue v : out) if (v == null) return null;
            return List.of(out);
        }

        private Integer intConstant(SourceValue v) {
            Set<AbstractInsnNode> from = origins(v);
            if (from.size() != 1) return null;
            AbstractInsnNode i = from.iterator().next();
            int op = i.getOpcode();
            if (op >= Opcodes.ICONST_0 && op <= Opcodes.ICONST_5) return op - Opcodes.ICONST_0;
            if (i instanceof IntInsnNode n && (op == Opcodes.BIPUSH || op == Opcodes.SIPUSH)) return n.operand;
            if (i instanceof LdcInsnNode ldc && ldc.cst instanceof Integer n) return n;
            return null;
        }

        /** Where a value comes from, for a person reading audit.json. */
        String describe(SourceValue v) {
            List<String> parts = new ArrayList<>();
            for (AbstractInsnNode i : origins(v)) {
                String d = describe(i);
                if (!parts.contains(d)) parts.add(d);
            }
            return parts.isEmpty() ? "nowhere it can tell" : String.join(" or ", parts);
        }

        private String describe(AbstractInsnNode i) {
            String cls = classOf(i);
            if (cls != null) return cls.substring(cls.lastIndexOf('/') + 1) + ".class";
            if (i instanceof LdcInsnNode ldc) {
                String s = String.valueOf(ldc.cst);
                return "\"" + (s.length() > 60 ? s.substring(0, 57) + "..." : s) + "\"";
            }
            if (i instanceof VarInsnNode load) {
                if (load.var == 0 && (m.access & Opcodes.ACC_STATIC) == 0) return "this";
                int p = parameter(new SourceValue(1, load));
                return p >= 0 ? "parameter " + p : "a local it assigns more than once";
            }
            if (i instanceof FieldInsnNode f) return "field " + simple(f.owner) + "." + f.name;
            if (i instanceof MethodInsnNode c) return simple(c.owner) + "." + c.name + "()";
            if (i instanceof InvokeDynamicInsnNode indy)
                return indy.name.equals("makeConcatWithConstants") ? "a string it builds" : "a lambda";
            if (i.getOpcode() == Opcodes.AALOAD) return "an array element";
            return "a computed value";
        }

        private static String simple(String internal) {
            return internal.substring(internal.lastIndexOf('/') + 1);
        }
    }
}
