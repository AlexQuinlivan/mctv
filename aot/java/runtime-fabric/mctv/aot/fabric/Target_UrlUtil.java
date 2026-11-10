package mctv.aot.fabric;

import java.nio.file.Path;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

/**
 * Native image only. Fabric finds its own jar from its classes' code source,
 * which in an image is the executable. FlatFabric knows where the jar was put.
 */
@TargetClass(className = "net.fabricmc.loader.impl.util.UrlUtil")
final class Target_UrlUtil {
    @Substitute
    public static Path getCodeSource(Class<?> cls) {
        return FlatFabric.imageCodeSource(cls);
    }
}
