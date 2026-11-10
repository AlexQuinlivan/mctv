package mctv.aot.svm;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

/**
 * Native image only. Minecraft loads LWJGL's OpenGL at every start, whichever
 * renderer it then uses, and LWJGL fails without an OpenGL library. The app
 * has none. It renders only with Vulkan, through MoltenVK.
 */
@TargetClass(className = "com.mojang.blaze3d.platform.NativeLibrariesBootstrap")
final class Target_NativeLibrariesBootstrap {
    @Substitute
    private static void loadOpenGL() {
    }
}
