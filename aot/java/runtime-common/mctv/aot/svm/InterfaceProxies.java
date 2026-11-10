package mctv.aot.svm;

import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodType;
import java.lang.reflect.InvocationHandler;
import java.lang.reflect.Method;
import java.lang.reflect.Modifier;
import java.lang.reflect.Proxy;

/**
 * MethodHandleProxies.asInterfaceInstance as its documentation describes it,
 * on java.lang.reflect.Proxy, for Target_MethodHandleProxies. The single
 * abstract method calls the handle. Object's methods and default methods
 * behave as they would on the JDK's.
 */
public final class InterfaceProxies {
    private InterfaceProxies() { }

    @SuppressWarnings("unchecked")
    public static <T> T create(Class<T> intf, MethodHandle target) {
        if (!intf.isInterface() || !Modifier.isPublic(intf.getModifiers()))
            throw new IllegalArgumentException("not a public interface: " + intf.getName());
        Method sam = null;
        for (Method m : intf.getMethods()) {
            if (!Modifier.isAbstract(m.getModifiers()) || isObjectMethod(m)) continue;
            if (sam != null && !(sam.getName().equals(m.getName()) && sam.getParameterCount() == m.getParameterCount()))
                throw new IllegalArgumentException("not a single-method interface: " + intf.getName());
            sam = m;
        }
        if (sam == null) throw new IllegalArgumentException("no abstract method: " + intf.getName());
        String name = sam.getName();
        MethodHandle checked = target.asType(MethodType.methodType(sam.getReturnType(), sam.getParameterTypes()))
                .asSpreader(Object[].class, sam.getParameterCount());
        InvocationHandler handler = (proxy, method, args) -> {
            if (method.getDeclaringClass() == Object.class) {
                return switch (method.getName()) {
                    case "equals" -> proxy == args[0];
                    case "hashCode" -> System.identityHashCode(proxy);
                    case "toString" -> intf.getName() + "@" + Integer.toHexString(System.identityHashCode(proxy));
                    default -> throw new UnsupportedOperationException(method.toString());
                };
            }
            if (method.isDefault()) return InvocationHandler.invokeDefault(proxy, method, args);
            if (!method.getName().equals(name)) throw new UnsupportedOperationException(method.toString());
            return checked.invoke(args == null ? new Object[0] : args);
        };
        return (T) Proxy.newProxyInstance(intf.getClassLoader(), new Class<?>[] {intf}, handler);
    }

    private static boolean isObjectMethod(Method m) {
        try {
            Object.class.getMethod(m.getName(), m.getParameterTypes());
            return true;
        } catch (NoSuchMethodException e) {
            return false;
        }
    }
}
