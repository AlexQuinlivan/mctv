package mctv.aot.compat.sodium;

import com.mojang.renderpearl.api.vertex.VertexFormat;
import com.oracle.svm.core.annotate.Substitute;
import com.oracle.svm.core.annotate.TargetClass;

import net.caffeinemc.mods.sodium.api.vertex.serializer.VertexSerializer;

/**
 * Sodium generates a class to copy vertices between each pair of formats,
 * which an image can't define. This copies the same bytes the same way,
 * with no new class (TransferSerializer).
 */
@TargetClass(className = "net.caffeinemc.mods.sodium.client.render.vertex.serializers.VertexSerializerRegistryImpl")
final class Target_VertexSerializerRegistryImpl {
    @Substitute
    private static VertexSerializer createSerializer(VertexFormat src, VertexFormat dst) {
        return TransferSerializer.create(src, dst, Target_VertexSerializerFactory.createMemoryTransferList(src, dst));
    }
}
