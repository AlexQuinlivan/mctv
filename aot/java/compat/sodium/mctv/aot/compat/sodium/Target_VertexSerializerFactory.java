package mctv.aot.compat.sodium;

import java.util.List;

import com.mojang.renderpearl.api.vertex.VertexFormat;
import com.oracle.svm.core.annotate.Alias;
import com.oracle.svm.core.annotate.TargetClass;

import net.caffeinemc.mods.sodium.client.render.vertex.serializers.generated.VertexSerializerFactory;

/** Sodium's own list of what to copy, as its generated classes use it. */
@TargetClass(className = "net.caffeinemc.mods.sodium.client.render.vertex.serializers.generated.VertexSerializerFactory")
final class Target_VertexSerializerFactory {
    @Alias
    static native List<VertexSerializerFactory.MemoryTransfer> createMemoryTransferList(VertexFormat src, VertexFormat dst);
}
