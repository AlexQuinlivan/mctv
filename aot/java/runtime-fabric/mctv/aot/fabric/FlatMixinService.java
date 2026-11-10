package mctv.aot.fabric;

import net.fabricmc.loader.impl.launch.knot.MixinServiceKnot;

/**
 * Fabric's Mixin service for a baked game. Mods tell which loader they're on
 * from the service's name, and Fabric's says "Knot/Fabric" only when Knot
 * launched the game. FlatFabric is Knot as far as a mod can tell.
 */
public final class FlatMixinService extends MixinServiceKnot {
    @Override
    public String getName() {
        return "Knot/Fabric";
    }
}
