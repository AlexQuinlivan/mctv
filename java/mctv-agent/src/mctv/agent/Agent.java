package mctv.agent;

import java.lang.classfile.ClassFile;
import java.lang.classfile.ClassHierarchyResolver;
import java.lang.classfile.ClassModel;
import java.lang.classfile.ClassTransform;
import java.lang.classfile.CodeTransform;
import java.lang.classfile.MethodModel;
import java.lang.classfile.Opcode;
import java.lang.classfile.instruction.InvokeInstruction;
import java.lang.constant.ClassDesc;
import java.lang.instrument.ClassFileTransformer;
import java.lang.instrument.Instrumentation;
import java.lang.reflect.AccessFlag;
import java.nio.charset.StandardCharsets;
import java.security.ProtectionDomain;

/**
 * Patches Minecraft's classes for tvOS 27 as they load, when aot/aot.py bakes
 * the game. Every class load goes through the transformer, so this works for
 * vanilla and Fabric alike. Uses java.lang.classfile (Java 24 and later).
 *
 * MacosUtil. The JVM reports macOS, so Minecraft runs its macOS code, and
 * MacosUtil reaches AppKit through JNA, which can't load on tvOS. Its methods
 * (the Close menu item, the full-screen menu, Ctrl-click) mean nothing on a
 * TV, so they return straight away.
 *
 * TextureAtlas and AnimatedTexture. Minecraft makes a GPU texture for every sprite
 * and every animation frame, thousands at once, and tvOS charges heavily for
 * each texture object. Atlases are built and animations drawn on the CPU
 * instead (AtlasUpload, AnimationUpload), with Minecraft's code as the fallback.
 *
 * VulkanBackend. Minecraft leaves VMA's block size at its 256 MB default, so
 * GPU memory grows in blocks of up to 256 MB that stay resident however
 * little they hold, and Sodium's growing chunk arenas leave blocks behind.
 * 16 MB blocks keep the slack small, and VMA gives anything over half a block
 * its own memory. -Dmctv.vma.blockMB sets the size, 0 for Minecraft's.
 *
 * RenderSystem.isFrozenAtPollEvents. Minecraft holds back keepalive replies
 * once its event pump has been blocked for 200 ms, and the server drops it
 * within 30 s. On the TV the pump only blocks while the app is in the
 * background (SDLHost.m), where the connection should stay up for as long
 * as tvOS lets the app run. So this always answers false.
 *
 * Linker.upcallStub. Calls to it outside the JDK go to FfiUpcalls, which
 * makes them with libffi through LWJGL, as LWJGL's own callbacks are made.
 * Controlify's SDL event filter needs one.
 */
public final class Agent {
    private static final String MACOS_UTIL = "com/mojang/blaze3d/platform/MacosUtil";
    private static final String TEXTURE_ATLAS = "net/minecraft/client/renderer/texture/TextureAtlas";
    private static final String ANIMATED_TEXTURE = "net/minecraft/client/renderer/texture/SpriteContents$AnimatedTexture";
    private static final ClassDesc ANIMATION_UPLOAD = ClassDesc.of("mctv.agent.AnimationUpload");
    private static final String RENDER_SYSTEM = "com/mojang/blaze3d/systems/RenderSystem";
    private static final String VULKAN_BACKEND = "com/mojang/renderpearl/backend/vulkan/VulkanBackend";
    private static final ClassDesc VMA_CREATE_INFO = ClassDesc.of("org.lwjgl.util.vma.VmaAllocatorCreateInfo");
    private static final byte[] UPCALL_STUB = "upcallStub".getBytes(StandardCharsets.US_ASCII);
    private static final ClassDesc LINKER = ClassDesc.of("java.lang.foreign.Linker");
    private static final ClassDesc FFI_UPCALLS = ClassDesc.of("mctv.agent.FfiUpcalls");

    public static void premain(String args, Instrumentation inst) {
        inst.addTransformer(new ClassFileTransformer() {
            @Override
            public byte[] transform(ClassLoader loader, String name, Class<?> redefining,
                                    ProtectionDomain domain, byte[] bytes) {
                if (name == null) return null;
                try {
                    if (MACOS_UTIL.equals(name)) return emptyStaticVoidMethods(bytes);
                    if (TEXTURE_ATLAS.equals(name)) return atlasOnCpu(bytes, loader);
                    if (ANIMATED_TEXTURE.equals(name)) return animationStatesOnCpu(bytes, loader);
                    if (VULKAN_BACKEND.equals(name)) return smallerVmaBlocks(bytes, loader);
                    if (RENDER_SYSTEM.equals(name)) return neverFrozen(bytes);
                    if (!name.startsWith("java/") && !name.startsWith("jdk/") && !name.startsWith("sun/")
                            && !name.startsWith("mctv/") && !name.startsWith("org/lwjgl/") && contains(bytes, UPCALL_STUB))
                        return redirectUpcalls(bytes, loader);
                } catch (Throwable t) {
                    System.err.println("mctv-agent: couldn't patch " + name + ": " + t);
                }
                return null;
            }
        });
    }

    /** Every static method returning void, other than the static initialiser, returns at once. */
    static byte[] emptyStaticVoidMethods(byte[] bytes) {
        ClassFile cf = ClassFile.of();
        ClassModel model = cf.parse(bytes);
        return cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel m
                    && m.flags().has(AccessFlag.STATIC)
                    && m.methodTypeSymbol().returnType().descriptorString().equals("V")
                    && !m.methodName().equalsString("<clinit>")) {
                builder.withMethod(m.methodName(), m.methodType(), m.flags().flagsMask(),
                        mb -> mb.withCode(code -> code.return_()));
                System.err.println("mctv-agent: " + model.thisClass().asInternalName() + "." + m.methodName().stringValue() + " does nothing on the TV");
            } else {
                builder.with(element);
            }
        });
    }

    /** RenderSystem.isFrozenAtPollEvents() returns false. */
    static byte[] neverFrozen(byte[] bytes) {
        ClassFile cf = ClassFile.of();
        ClassModel model = cf.parse(bytes);
        boolean[] found = {false};
        byte[] out = cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel m && m.methodName().equalsString("isFrozenAtPollEvents")
                    && m.methodType().equalsString("()Z")) {
                builder.withMethod(m.methodName(), m.methodType(), m.flags().flagsMask(),
                        mb -> mb.withCode(code -> code.iconst_0().ireturn()));
                found[0] = true;
            } else {
                builder.with(element);
            }
        });
        if (!found[0]) return null;
        System.err.println("mctv-agent: keepalive replies go out while the game waits in the background");
        return out;
    }

    /**
     * TextureAtlas.uploadInitialContents becomes
     *   if (AtlasUpload.upload(this)) uploadAnimationFrames(); else uploadInitialContents$mctv();
     *   AtlasUpload.dump(this);  // only with -Dmctv.atlas.dump
     * and uploadAnimationFrames becomes
     *   if (!AnimationUpload.upload(this)) uploadAnimationFrames$mctv();
     * where the $mctv methods are Minecraft's originals, renamed. Anything the
     * helpers throw is caught, a LinkageError for a missing class included, and
     * a throw from upload() counts as false.
     */
    static byte[] atlasOnCpu(byte[] bytes, ClassLoader loader) {
        ClassHierarchyResolver resolver = ClassHierarchyResolver.defaultResolver()
                .orElse(ClassHierarchyResolver.ofResourceParsing(loader != null ? loader : ClassLoader.getSystemClassLoader()));
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver));
        ClassModel model = cf.parse(bytes);
        ClassDesc self = model.thisClass().asSymbol();
        java.lang.constant.MethodTypeDesc voidType = java.lang.constant.MethodTypeDesc.ofDescriptor("()V");
        boolean[] found = {false};
        byte[] out = cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel m && m.methodName().equalsString("uploadInitialContents")
                    && m.methodType().equalsString("()V")) {
                found[0] = true;
                builder.withMethod("uploadInitialContents$mctv", m.methodTypeSymbol(), m.flags().flagsMask(),
                        mb -> m.forEach(mb::with));
                builder.withMethod(m.methodName(), m.methodType(), m.flags().flagsMask(), mb -> mb.withCode(code -> {
                    ClassDesc helper = ClassDesc.of("mctv.agent.AtlasUpload");
                    int ok = code.allocateLocal(java.lang.classfile.TypeKind.INT);
                    java.lang.classfile.Label fallback = code.newLabel();
                    java.lang.classfile.Label done = code.newLabel();
                    code.iconst_0().istore(ok);
                    code.trying(
                        b -> b.aload(0)
                              .invokestatic(helper, "upload", java.lang.constant.MethodTypeDesc.ofDescriptor("(Ljava/lang/Object;)Z"))
                              .istore(ok),
                        c -> c.catchingAll(h -> h.pop()));
                    code.iload(ok).ifeq(fallback)
                        .aload(0)
                        .invokevirtual(self, "uploadAnimationFrames", voidType)
                        .goto_(done)
                        .labelBinding(fallback)
                        .aload(0)
                        .invokevirtual(self, "uploadInitialContents$mctv", voidType)
                        .labelBinding(done);
                    code.trying(
                        b -> b.aload(0)
                              .invokestatic(helper, "dump", java.lang.constant.MethodTypeDesc.ofDescriptor("(Ljava/lang/Object;)V")),
                        c -> c.catchingAll(h -> h.pop()));
                    code.return_();
                }));
            } else if (element instanceof MethodModel m && m.methodName().equalsString("uploadAnimationFrames")
                    && m.methodType().equalsString("()V")) {
                builder.withMethod("uploadAnimationFrames$mctv", m.methodTypeSymbol(), m.flags().flagsMask(),
                        mb -> m.forEach(mb::with));
                builder.withMethod(m.methodName(), m.methodType(), m.flags().flagsMask(), mb -> mb.withCode(code -> {
                    int done = code.allocateLocal(java.lang.classfile.TypeKind.INT);
                    java.lang.classfile.Label end = code.newLabel();
                    code.iconst_0().istore(done);
                    code.trying(
                        b -> b.aload(0)
                              .invokestatic(ANIMATION_UPLOAD, "upload", java.lang.constant.MethodTypeDesc.ofDescriptor("(Ljava/lang/Object;)Z"))
                              .istore(done),
                        c -> c.catchingAll(h -> h.pop()));
                    code.iload(done).ifne(end)
                        .aload(0)
                        .invokevirtual(self, "uploadAnimationFrames$mctv", voidType)
                        .labelBinding(end)
                        .return_();
                }));
            } else {
                builder.with(element);
            }
        });
        if (!found[0]) {
            System.err.println("mctv-agent: TextureAtlas has no uploadInitialContents(), so atlases are built Minecraft's way");
            return null;
        }
        System.err.println("mctv-agent: TextureAtlas builds its atlases on the CPU");
        return out;
    }

    /**
     * SpriteContents$AnimatedTexture.createAnimationState(slice, size) becomes
     *   state = AnimationUpload.createState(this, slice, size);  // null if it throws
     *   return state != null ? (AnimationState) state : createAnimationState$mctv(slice, size);
     */
    static byte[] animationStatesOnCpu(byte[] bytes, ClassLoader loader) {
        ClassHierarchyResolver resolver = ClassHierarchyResolver.defaultResolver()
                .orElse(ClassHierarchyResolver.ofResourceParsing(loader != null ? loader : ClassLoader.getSystemClassLoader()));
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver));
        ClassModel model = cf.parse(bytes);
        ClassDesc self = model.thisClass().asSymbol();
        boolean[] found = {false};
        byte[] out = cf.transformClass(model, (builder, element) -> {
            if (element instanceof MethodModel m && m.methodName().equalsString("createAnimationState")
                    && m.methodTypeSymbol().parameterCount() == 2) {
                found[0] = true;
                java.lang.constant.MethodTypeDesc type = m.methodTypeSymbol();
                builder.withMethod("createAnimationState$mctv", type, m.flags().flagsMask(), mb -> m.forEach(mb::with));
                builder.withMethod(m.methodName(), m.methodType(), m.flags().flagsMask(), mb -> mb.withCode(code -> {
                    int state = code.allocateLocal(java.lang.classfile.TypeKind.REFERENCE);
                    java.lang.classfile.Label original = code.newLabel();
                    code.aconst_null().astore(state);
                    code.trying(
                        b -> b.aload(0).aload(1).iload(2)
                              .invokestatic(ANIMATION_UPLOAD, "createState", java.lang.constant.MethodTypeDesc.ofDescriptor(
                                      "(Ljava/lang/Object;Ljava/lang/Object;I)Ljava/lang/Object;"))
                              .astore(state),
                        c -> c.catchingAll(h -> h.pop()));
                    code.aload(state).ifnull(original)
                        .aload(state).checkcast(type.returnType()).areturn()
                        .labelBinding(original)
                        .aload(0).aload(1).iload(2)
                        .invokevirtual(self, "createAnimationState$mctv", type)
                        .areturn();
                }));
            } else {
                builder.with(element);
            }
        });
        if (!found[0]) {
            System.err.println("mctv-agent: AnimatedTexture has no createAnimationState(), so sprite animations are Minecraft's way");
            return null;
        }
        System.err.println("mctv-agent: sprite animations are drawn on the CPU");
        return out;
    }

    /**
     * In VulkanBackend.createVma, VmaAllocatorCreateInfo.calloc(stack) becomes
     * VmaAllocatorCreateInfo.calloc(stack).preferredLargeHeapBlockSize(N).
     */
    static byte[] smallerVmaBlocks(byte[] bytes, ClassLoader loader) {
        long mb = Long.getLong("mctv.vma.blockMB", 16);
        if (mb <= 0) return null;
        ClassHierarchyResolver resolver = ClassHierarchyResolver.defaultResolver()
                .orElse(ClassHierarchyResolver.ofResourceParsing(loader != null ? loader : ClassLoader.getSystemClassLoader()));
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver));
        ClassModel model = cf.parse(bytes);
        int[] count = {0};
        CodeTransform setBlockSize = (code, element) -> {
            code.with(element);
            if (element instanceof InvokeInstruction i && i.opcode() == Opcode.INVOKESTATIC
                    && i.owner().asSymbol().equals(VMA_CREATE_INFO) && i.name().equalsString("calloc")) {
                code.loadConstant(mb << 20)
                    .invokevirtual(VMA_CREATE_INFO, "preferredLargeHeapBlockSize",
                            java.lang.constant.MethodTypeDesc.of(VMA_CREATE_INFO, java.lang.constant.ConstantDescs.CD_long));
                count[0]++;
            }
        };
        byte[] out = cf.transformClass(model, ClassTransform.transformingMethodBodies(
                m -> m.methodName().equalsString("createVma"), setBlockSize));
        if (count[0] != 1) {
            System.err.println("mctv-agent: VulkanBackend.createVma isn't as expected, so VMA keeps its block size");
            return null;
        }
        System.err.println("mctv-agent: VMA allocates GPU memory in blocks of " + mb + " MB");
        return out;
    }

    /** linker.upcallStub(target, function, arena, options) becomes FfiUpcalls.upcallStub(linker, ...). */
    static byte[] redirectUpcalls(byte[] bytes, ClassLoader loader) {
        // Rebuilding stack maps needs the class's supertypes, so they're read
        // through the loader defining it (Fabric's, for mods).
        ClassHierarchyResolver resolver = ClassHierarchyResolver.defaultResolver()
                .orElse(ClassHierarchyResolver.ofResourceParsing(loader != null ? loader : ClassLoader.getSystemClassLoader()));
        ClassFile cf = ClassFile.of(ClassFile.ClassHierarchyResolverOption.of(resolver));
        ClassModel model = cf.parse(bytes);
        int[] count = {0};
        CodeTransform redirect = (code, element) -> {
            if (element instanceof InvokeInstruction i && i.opcode() == Opcode.INVOKEINTERFACE
                    && i.owner().asSymbol().equals(LINKER) && i.name().equalsString("upcallStub")) {
                code.invokestatic(FFI_UPCALLS, "upcallStub", i.typeSymbol().insertParameterTypes(0, LINKER));
                count[0]++;
            } else {
                code.with(element);
            }
        };
        byte[] out = cf.transformClass(model, ClassTransform.transformingMethodBodies(redirect));
        if (count[0] == 0) return null;
        System.err.println("mctv-agent: " + model.thisClass().asInternalName() + " makes its upcalls with libffi (" + count[0] + ")");
        return out;
    }

    private static boolean contains(byte[] haystack, byte[] needle) {
        outer:
        for (int i = 0, end = haystack.length - needle.length; i <= end; i++) {
            for (int j = 0; j < needle.length; j++)
                if (haystack[i + j] != needle[j]) continue outer;
            return true;
        }
        return false;
    }
}
