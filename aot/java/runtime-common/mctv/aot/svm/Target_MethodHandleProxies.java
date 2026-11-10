package mctv.aot.svm;

import java.lang.invoke.MethodHandle;

import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

/**
 * Native image only. The JDK's MethodHandleProxies defines a class at run
 * time, which an image can't, so InterfaceProxies does the same with a
 * java.lang.reflect.Proxy, which an image can make for an interface
 * registered at build time (the bake registers Fabric's method-reference
 * entrypoints' interfaces).
 */
@TargetClass(className = "java.lang.invoke.MethodHandleProxies")
final class Target_MethodHandleProxies {
    @Substitute
    public static <T> T asInterfaceInstance(Class<T> intf, MethodHandle target) {
        return InterfaceProxies.create(intf, target);
    }
}
