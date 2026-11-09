package mctv.agent;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.List;

/**
 * Builds a texture atlas on the CPU, the way Minecraft 1.21 did.
 *
 * 26.x's TextureAtlas.uploadInitialContents makes a GPU texture for every
 * sprite (about 4,000 for the block atlas), draws each into the atlas with
 * the animate_sprite_blit shader, then frees them all. tvOS charges about
 * 100 KB of GPU memory per texture object on top of its pixels, so the burst
 * pushes the app past its 2 GB limit. Here each sprite's mip levels, already
 * in CPU memory, are padded into a CPU copy of each atlas mip level, and each
 * level goes to the GPU in one write. Animated sprites are drawn afterwards
 * by uploadAnimationFrames.
 *
 * The shader draws the sprite's padded area, (w + 2p) by (h + 2p) at (x, y),
 * shifted right by the mip level. It samples the sprite's mip with NEAREST
 * filtering and clamp to edge at u = uv * (1 + 2p/w) - p/w, so the border
 * copies edge pixels outwards and neighbouring sprites don't bleed together
 * at lower mip levels. sourceIndex does the same mapping texel by texel.
 */
public final class AtlasUpload {
    private AtlasUpload() {}

    private static volatile boolean failed;

    /** False means build the atlas Minecraft's way, after a failure or with -Dmctv.atlas=gpu. */
    public static boolean upload(Object atlas) {
        if (failed || "gpu".equals(System.getProperty("mctv.atlas"))) return false;
        try {
            uploadSprites(atlas);
            return true;
        } catch (Throwable t) {
            failed = true;
            System.err.println("mctv-agent: building atlases on the CPU failed, using Minecraft's way from now on: " + t);
            t.printStackTrace();
            return false;
        }
    }

    private static void uploadSprites(Object atlas) throws ReflectiveOperationException {
        ClassLoader loader = atlas.getClass().getClassLoader();
        Class<?> atlasClass = Class.forName("net.minecraft.client.renderer.texture.TextureAtlas", false, loader);
        Class<?> spriteClass = Class.forName("net.minecraft.client.renderer.texture.TextureAtlasSprite", false, loader);
        Class<?> contentsClass = Class.forName("net.minecraft.client.renderer.texture.SpriteContents", false, loader);
        Class<?> imageClass = Class.forName("com.mojang.blaze3d.platform.NativeImage", false, loader);
        Class<?> textureClass = Class.forName("com.mojang.renderpearl.api.textures.GpuTexture", false, loader);
        Class<?> deviceClass = Class.forName("com.mojang.renderpearl.api.device.GpuDevice", false, loader);
        Class<?> encoderClass = Class.forName("com.mojang.renderpearl.api.commands.CommandEncoder", false, loader);
        Class<?> renderSystem = Class.forName("com.mojang.blaze3d.systems.RenderSystem", false, loader);

        List<?> sprites = (List<?>) field(atlasClass, "sprites").get(atlas);
        int maxMipLevel = field(atlasClass, "maxMipLevel").getInt(atlas);
        int atlasWidth = field(atlasClass, "width").getInt(atlas);
        int atlasHeight = field(atlasClass, "height").getInt(atlas);
        Object atlasTexture = atlasClass.getMethod("getTexture").invoke(atlas);

        Method isAnimated = spriteClass.getMethod("isAnimated");
        Method contents = spriteClass.getMethod("contents");
        Field spriteX = field(spriteClass, "x");
        Field spriteY = field(spriteClass, "y");
        Field padding = field(spriteClass, "padding");
        Field byMipLevel = field(contentsClass, "byMipLevel");
        Method width = contentsClass.getMethod("width");
        Method height = contentsClass.getMethod("height");

        Constructor<?> newImage = imageClass.getConstructor(int.class, int.class, boolean.class);
        Method imageWidth = imageClass.getMethod("getWidth");
        Method imageHeight = imageClass.getMethod("getHeight");
        Method pointer = imageClass.getMethod("getPointer");
        Method close = imageClass.getMethod("close");
        Method format = imageClass.getMethod("format");

        Object device = renderSystem.getMethod("getDevice").invoke(null);
        Object encoder = deviceClass.getMethod("createCommandEncoder").invoke(device);
        Method write = encoderClass.getMethod("writeToTexture", textureClass, imageClass,
                int.class, int.class, int.class, int.class);

        int written = 0, animated = 0;
        for (Object sprite : sprites) if ((Boolean) isAnimated.invoke(sprite)) animated++;
        for (int mip = 0; mip <= maxMipLevel; mip++) {
            int aw = atlasWidth >> mip, ah = atlasHeight >> mip;
            if (aw <= 0 || ah <= 0) break;
            Object level = newImage.newInstance(aw, ah, false);
            try {
                long levelPtr = (Long) pointer.invoke(level);
                fill(levelPtr, aw, ah, NEW_TEXTURE);
                for (Object sprite : sprites) {
                    if ((Boolean) isAnimated.invoke(sprite)) continue;
                    Object content = contents.invoke(sprite);
                    Object[] mips = (Object[]) byMipLevel.get(content);
                    if (mip >= mips.length) continue;
                    Object src = mips[mip];
                    if (format.invoke(src) != format.invoke(level))
                        throw new IllegalStateException("sprite image format " + format.invoke(src) + ", expected " + format.invoke(level));
                    int x = spriteX.getInt(sprite), y = spriteY.getInt(sprite), p = padding.getInt(sprite);
                    int w = (Integer) width.invoke(content), h = (Integer) height.invoke(content);
                    int sw = (Integer) imageWidth.invoke(src), sh = (Integer) imageHeight.invoke(src);
                    int dw = (w + 2 * p) >> mip, dh = (h + 2 * p) >> mip;
                    if (dw <= 0 || dh <= 0 || sw <= 0 || sh <= 0) continue;
                    pad((Long) pointer.invoke(src), sw, sh, levelPtr, aw, ah, x >> mip, y >> mip, dw, dh, p, w, h);
                    written++;
                }
                write.invoke(encoder, atlasTexture, level, mip, 0, 0, 0);
            } finally {
                close.invoke(level);
            }
        }
        System.err.println("mctv-agent: built " + atlasClass.getMethod("location").invoke(atlas)
                + " on the CPU (" + written + " sprite images, one upload per mip level, then " + animated + " animated ones)");
    }

    /** With -Dmctv.atlas.dump=DIR, saves the finished atlas and its mip levels as PNGs to compare the two ways. */
    public static void dump(Object atlas) {
        String dir = System.getProperty("mctv.atlas.dump");
        if (dir != null) dumpTo(atlas, dir, "");
    }

    /** Saves the atlas as PNGs in DIR/atlas-(cpu|gpu)-animations-(cpu|gpu)SUFFIX. */
    static void dumpTo(Object atlas, String dir, String suffix) {
        try {
            ClassLoader loader = atlas.getClass().getClassLoader();
            Class<?> id = Class.forName("net.minecraft.resources.Identifier", false, loader);
            Object location = atlas.getClass().getMethod("location").invoke(atlas);
            java.nio.file.Path path = java.nio.file.Path.of(dir, "atlas-" + System.getProperty("mctv.atlas", "cpu")
                    + "-animations-" + System.getProperty("mctv.animations", "cpu") + suffix);
            java.nio.file.Files.createDirectories(path);
            atlas.getClass().getMethod("dumpContents", id, java.nio.file.Path.class).invoke(atlas, location, path);
        } catch (Throwable t) {
            System.err.println("mctv-agent: couldn't dump the atlas: " + t);
        }
    }

    /** The shader's mapping from destination texel centre to source texel, clamped to the edge. */
    static int[] sourceIndex(int dst, int src, int pad, int size) {
        int[] out = new int[dst];
        double scale = 1.0 + 2.0 * pad / size, shift = (double) pad / size;
        for (int i = 0; i < dst; i++) {
            double u = (i + 0.5) / dst * scale - shift;
            out[i] = Math.max(0, Math.min(src - 1, (int) Math.floor(u * src)));
        }
        return out;
    }

    /** What a new atlas texture holds where no sprite is drawn, opaque magenta (RGBA bytes FF 00 FF FF). */
    static final int NEW_TEXTURE = 0xFFFF00FF;

    static void fill(long ptr, int w, int h, int pixel) {
        MemorySegment dst = MemorySegment.ofAddress(ptr).reinterpret((long) w * h * 4);
        for (long i = 0, n = (long) w * h; i < n; i++) dst.set(ValueLayout.JAVA_INT_UNALIGNED, i * 4, pixel);
    }

    /**
     * Draws a sprite's padded block, dw x dh at (dx, dy), into a 4-byte-per-pixel
     * atlas level (aw x ah) as the blit shader does, clipped to the level.
     */
    static void pad(long srcPtr, int sw, int sh, long dstPtr, int aw, int ah, int dx, int dy, int dw, int dh, int p, int w, int h) {
        MemorySegment src = MemorySegment.ofAddress(srcPtr).reinterpret((long) sw * sh * 4);
        MemorySegment dst = MemorySegment.ofAddress(dstPtr).reinterpret((long) aw * ah * 4);
        int[] cols = sourceIndex(dw, sw, p, w);
        int[] rows = sourceIndex(dh, sh, p, h);
        for (int j = 0; j < dh; j++) {
            int y = dy + j;
            if (y < 0 || y >= ah) continue;
            long srcRow = (long) rows[j] * sw * 4, dstRow = (long) y * aw * 4;
            for (int i = 0; i < dw; i++) {
                int x = dx + i;
                if (x < 0 || x >= aw) continue;
                dst.set(ValueLayout.JAVA_INT_UNALIGNED, dstRow + x * 4L,
                        src.get(ValueLayout.JAVA_INT_UNALIGNED, srcRow + cols[i] * 4L));
            }
        }
    }

    private static Field field(Class<?> c, String name) throws NoSuchFieldException {
        Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f;
    }
}
