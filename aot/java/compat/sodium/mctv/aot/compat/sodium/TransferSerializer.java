package mctv.aot.compat.sodium;

import com.mojang.renderpearl.api.vertex.VertexFormat;

import net.caffeinemc.mods.sodium.api.memory.MemoryIntrinsics;
import net.caffeinemc.mods.sodium.api.vertex.serializer.VertexSerializer;
import net.caffeinemc.mods.sodium.client.render.vertex.serializers.generated.VertexSerializerFactory;

/**
 * What VertexSerializerFactory.generate writes as bytecode, run as a loop.
 * For each vertex, each of Sodium's transfers is copied in 8, 4, 2 and 1
 * byte steps through MemoryIntrinsics, then both pointers move on by their
 * format's vertex size. The steps are worked out once, here.
 */
final class TransferSerializer implements VertexSerializer {
    private final int[] srcOffsets;
    private final int[] dstOffsets;
    private final byte[] sizes;
    private final long srcStride;
    private final long dstStride;

    private TransferSerializer(int[] srcOffsets, int[] dstOffsets, byte[] sizes, long srcStride, long dstStride) {
        this.srcOffsets = srcOffsets;
        this.dstOffsets = dstOffsets;
        this.sizes = sizes;
        this.srcStride = srcStride;
        this.dstStride = dstStride;
    }

    static VertexSerializer create(VertexFormat src, VertexFormat dst, java.util.List<VertexSerializerFactory.MemoryTransfer> transfers) {
        int steps = 0;
        for (VertexSerializerFactory.MemoryTransfer t : transfers) steps += split(t.length(), null, null, null, 0, t);
        int[] srcOffsets = new int[steps];
        int[] dstOffsets = new int[steps];
        byte[] sizes = new byte[steps];
        int at = 0;
        for (VertexSerializerFactory.MemoryTransfer t : transfers) at += split(t.length(), srcOffsets, dstOffsets, sizes, at, t);
        return new TransferSerializer(srcOffsets, dstOffsets, sizes, src.getVertexSize(), dst.getVertexSize());
    }

    /** The steps one transfer takes, written from {@code at} when there are arrays to write to. */
    private static int split(int length, int[] srcOffsets, int[] dstOffsets, byte[] sizes, int at, VertexSerializerFactory.MemoryTransfer t) {
        int n = 0;
        for (int offset = 0; offset < length; n++) {
            int left = length - offset;
            int size = left >= 8 ? 8 : left >= 4 ? 4 : left >= 2 ? 2 : 1;
            if (sizes != null) {
                srcOffsets[at + n] = t.src() + offset;
                dstOffsets[at + n] = t.dst() + offset;
                sizes[at + n] = (byte) size;
            }
            offset += size;
        }
        return n;
    }

    @Override
    public void serialize(long src, long dst, int vertexCount) {
        int[] srcOffsets = this.srcOffsets, dstOffsets = this.dstOffsets;
        byte[] sizes = this.sizes;
        for (int v = 0; v < vertexCount; v++) {
            for (int i = 0; i < sizes.length; i++) {
                long from = src + srcOffsets[i], to = dst + dstOffsets[i];
                switch (sizes[i]) {
                    case 8 -> MemoryIntrinsics.putLong(to, MemoryIntrinsics.getLong(from));
                    case 4 -> MemoryIntrinsics.putInt(to, MemoryIntrinsics.getInt(from));
                    case 2 -> MemoryIntrinsics.putShort(to, MemoryIntrinsics.getShort(from));
                    default -> MemoryIntrinsics.putByte(to, MemoryIntrinsics.getByte(from));
                }
            }
            src += srcStride;
            dst += dstStride;
        }
    }
}
