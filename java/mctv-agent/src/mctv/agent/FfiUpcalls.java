package mctv.agent;

import java.lang.foreign.AddressLayout;
import java.lang.foreign.Arena;
import java.lang.foreign.FunctionDescriptor;
import java.lang.foreign.Linker;
import java.lang.foreign.MemoryLayout;
import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.invoke.MethodHandle;
import java.lang.invoke.MethodHandles;

import org.lwjgl.system.APIUtil;
import org.lwjgl.system.Callback;
import org.lwjgl.system.CallbackI;
import org.lwjgl.system.MemoryUtil;
import org.lwjgl.system.libffi.FFICIF;
import org.lwjgl.system.libffi.FFIType;
import org.lwjgl.system.libffi.LibFFI;

/**
 * Linker.upcallStub, made with LWJGL's libffi closures instead of the JDK's
 * upcall stubs, so every native callback in the game is made the one way.
 * Agent sends calls to Linker.upcallStub from any class outside the JDK here.
 * Controlify's SDL event filter is the one that matters.
 *
 * Arguments and returns are primitives and pointers. Structs by value aren't
 * supported (SDL's callbacks don't use them). An exception in the target is
 * logged and the callback returns zero, where the JDK would stop the VM.
 */
public final class FfiUpcalls {
    private FfiUpcalls() {}

    public static MemorySegment upcallStub(Linker linker, MethodHandle target, FunctionDescriptor function,
                                           Arena arena, Linker.Option... options) {
        MemoryLayout[] args = function.argumentLayouts().toArray(new MemoryLayout[0]);
        MemoryLayout ret = function.returnLayout().orElse(null);
        FFIType[] types = new FFIType[args.length];
        for (int i = 0; i < args.length; i++) types[i] = type(args[i]);
        FFICIF cif = APIUtil.apiCreateCIF(LibFFI.FFI_DEFAULT_ABI, ret == null ? LibFFI.ffi_type_void : type(ret), types);
        Closure closure = new Closure(new Callback.Descriptor(Closure.class, MethodHandles.lookup(), cif),
                target.asSpreader(Object[].class, args.length), args, ret);
        long address = closure.address();
        // Freed with its arena, as the JDK's stubs are.
        return MemorySegment.ofAddress(address).reinterpret(0, arena, s -> Callback.free(address));
    }

    private static FFIType type(MemoryLayout l) {
        if (l instanceof AddressLayout) return LibFFI.ffi_type_pointer;
        if (l instanceof ValueLayout.OfBoolean) return LibFFI.ffi_type_uint8;
        if (l instanceof ValueLayout.OfByte) return LibFFI.ffi_type_sint8;
        if (l instanceof ValueLayout.OfShort) return LibFFI.ffi_type_sint16;
        if (l instanceof ValueLayout.OfChar) return LibFFI.ffi_type_uint16;
        if (l instanceof ValueLayout.OfInt) return LibFFI.ffi_type_sint32;
        if (l instanceof ValueLayout.OfLong) return LibFFI.ffi_type_sint64;
        if (l instanceof ValueLayout.OfFloat) return LibFFI.ffi_type_float;
        if (l instanceof ValueLayout.OfDouble) return LibFFI.ffi_type_double;
        throw new UnsupportedOperationException("mctv-agent: upcalls can't take " + l + " by value");
    }

    private static Object read(MemoryLayout l, long p) {
        if (l instanceof AddressLayout a) {
            MemorySegment s = MemorySegment.ofAddress(MemoryUtil.memGetAddress(p));
            return a.targetLayout().map(t -> s.reinterpret(t.byteSize())).orElse(s);
        }
        if (l instanceof ValueLayout.OfBoolean) return MemoryUtil.memGetByte(p) != 0;
        if (l instanceof ValueLayout.OfByte) return MemoryUtil.memGetByte(p);
        if (l instanceof ValueLayout.OfShort) return MemoryUtil.memGetShort(p);
        if (l instanceof ValueLayout.OfChar) return (char) MemoryUtil.memGetShort(p);
        if (l instanceof ValueLayout.OfInt) return MemoryUtil.memGetInt(p);
        if (l instanceof ValueLayout.OfLong) return MemoryUtil.memGetLong(p);
        if (l instanceof ValueLayout.OfFloat) return MemoryUtil.memGetFloat(p);
        return MemoryUtil.memGetDouble(p);
    }

    // libffi wants small integer returns widened to a full register.
    private static void write(MemoryLayout l, long p, Object v) {
        if (l instanceof AddressLayout) MemoryUtil.memPutAddress(p, v == null ? 0 : ((MemorySegment) v).address());
        else if (l instanceof ValueLayout.OfBoolean) APIUtil.apiClosureRet(p, v != null && (Boolean) v);
        else if (l instanceof ValueLayout.OfByte) APIUtil.apiClosureRet(p, v == null ? 0 : (Byte) v);
        else if (l instanceof ValueLayout.OfShort) APIUtil.apiClosureRet(p, v == null ? 0 : (Short) v);
        else if (l instanceof ValueLayout.OfChar) APIUtil.apiClosureRet(p, (short) (v == null ? 0 : (Character) v));
        else if (l instanceof ValueLayout.OfInt) APIUtil.apiClosureRet(p, v == null ? 0 : (Integer) v);
        else if (l instanceof ValueLayout.OfLong) MemoryUtil.memPutLong(p, v == null ? 0 : (Long) v);
        else if (l instanceof ValueLayout.OfFloat) MemoryUtil.memPutFloat(p, v == null ? 0 : (Float) v);
        else if (l instanceof ValueLayout.OfDouble) MemoryUtil.memPutDouble(p, v == null ? 0 : (Double) v);
    }

    private static final class Closure implements CallbackI {
        private final Callback.Descriptor descriptor;
        private final MethodHandle target;
        private final MemoryLayout[] args;
        private final MemoryLayout ret;

        Closure(Callback.Descriptor descriptor, MethodHandle target, MemoryLayout[] args, MemoryLayout ret) {
            this.descriptor = descriptor;
            this.target = target;
            this.args = args;
            this.ret = ret;
        }

        @Override
        public Callback.Descriptor getDescriptor() {
            return descriptor;
        }

        @Override
        public void callback(long ret, long args) {
            Object[] values = new Object[this.args.length];
            for (int i = 0; i < values.length; i++)
                values[i] = read(this.args[i], MemoryUtil.memGetAddress(args + (long) i * Long.BYTES));
            Object result = null;
            try {
                result = target.invoke(values);
            } catch (Throwable t) {
                System.err.println("mctv-agent: an upcall threw " + t);
                t.printStackTrace();
            }
            if (this.ret != null) write(this.ret, ret, result);
        }
    }
}
