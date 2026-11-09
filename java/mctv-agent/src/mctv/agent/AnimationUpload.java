package mctv.agent;

import java.lang.foreign.MemorySegment;
import java.lang.foreign.ValueLayout;
import java.lang.reflect.Array;
import java.lang.reflect.Constructor;
import java.lang.reflect.Field;
import java.lang.reflect.Method;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.WeakHashMap;

/**
 * Draws animated sprites on the CPU, the way Minecraft 1.21 did.
 *
 * 26.x gives every frame of every animated sprite its own GPU texture (about
 * 640 in vanilla) and draws the current frame into the atlas with the
 * animate_sprite shaders. Here createAnimationState makes Minecraft's own
 * AnimationState with no frame textures, and uploadAnimationFrames writes the
 * current frame of each sprite that needs drawing into every mip level of the
 * atlas, blended and padded exactly as the shaders do it. tick() and
 * needsToDraw() still decide what's drawn, so Sodium's mixins there (only
 * animate what's on screen) still work.
 *
 * -Dmctv.animations=gpu keeps Minecraft's way.
 */
public final class AnimationUpload {
    private AnimationUpload() {}

    /** Set once a state without frame textures exists. From then on only this class can draw animations. */
    private static volatile boolean active;
    private static volatile boolean failed;

    // Resolved on first use from Minecraft's own class loader.
    private static Constructor<?> newState, newIntMap, newImage;
    private static Class<?> sliceClass;
    private static Field stateFrame, stateSubFrame, stateInfo, infoFrames, infoRowSize, infoInterpolate, infoContents;
    private static Field frameIndex, frameTime, contentsMips, contentsWidth, contentsHeight;
    private static Field atlasStates, atlasSprites, atlasMaxMip, spriteX, spriteY, spritePadding, spriteContents;
    private static Method needsToDraw, getTexture, imageWidth, imageHeight, imagePointer, imageClose, write;
    private static Object device;
    private static Method createEncoder;
    private static final Map<Object, Map<Object, Object>> spritesByContents = new WeakHashMap<>();

    /** For AnimatedTexture.createAnimationState. Minecraft's AnimationState with no frame textures, or null for Minecraft's way. */
    public static Object createState(Object animated, Object uboSlice, int mipCount) {
        if (failed || "gpu".equals(System.getProperty("mctv.animations"))) return null;
        try {
            resolve(animated.getClass().getClassLoader());
            // An inner class, so the outer SpriteContents comes first. Sodium's mixin hooks this constructor too.
            Object state = newState.newInstance(infoContents.get(animated), animated, newIntMap.newInstance(), Array.newInstance(sliceClass, 0));
            active = true;
            return state;
        } catch (Throwable t) {
            failed = true;
            System.err.println("mctv-agent: CPU sprite animation unavailable, using Minecraft's way: " + t);
            return null;
        }
    }

    /**
     * For TextureAtlas.uploadAnimationFrames. False lets Minecraft's original run,
     * which only happens while every state still has its frame textures.
     */
    public static boolean upload(Object atlas) {
        dumpAfterTicks(atlas);
        if (!active) return false;
        if (failed) return true;  // animations stop rather than crash
        try {
            draw(atlas);
        } catch (Throwable t) {
            failed = true;
            System.err.println("mctv-agent: CPU sprite animation failed, animations stop here: " + t);
            t.printStackTrace();
        }
        return true;
    }

    private static final Map<Object, int[]> uploads = new WeakHashMap<>();

    /**
     * With -Dmctv.animations.dump=DIR, saves each atlas as it stands after N
     * animation uploads (-Dmctv.animations.dumpAt, 200 by default). That compares
     * frames drawn here with Minecraft's mid-animation, interpolated ones included.
     */
    private static void dumpAfterTicks(Object atlas) {
        String dir = System.getProperty("mctv.animations.dump");
        if (dir == null) return;
        int[] n;
        synchronized (uploads) { n = uploads.computeIfAbsent(atlas, a -> new int[1]); }
        if (n[0]++ == Integer.getInteger("mctv.animations.dumpAt", 200)) AtlasUpload.dumpTo(atlas, dir, "-after" + (n[0] - 1));
    }

    private static void draw(Object atlas) throws ReflectiveOperationException {
        List<?> states = (List<?>) atlasStates.get(atlas);
        if (states == null || states.isEmpty()) return;
        List<?> sprites = (List<?>) atlasSprites.get(atlas);
        Map<Object, Object> byContents = spritesByContents.get(sprites);
        if (byContents == null) {
            byContents = new IdentityHashMap<>();
            for (Object sprite : sprites) byContents.put(spriteContents.get(sprite), sprite);
            spritesByContents.put(sprites, byContents);
        }
        int maxMip = atlasMaxMip.getInt(atlas);
        Object texture = getTexture.invoke(atlas);
        Object encoder = createEncoder.invoke(device);
        for (Object state : states) {
            if (!(Boolean) needsToDraw.invoke(state)) continue;
            Object info = stateInfo.get(state);
            Object contents = infoContents.get(info);
            Object sprite = byContents.get(contents);
            if (sprite == null) continue;
            List<?> frames = (List<?>) infoFrames.get(info);
            int frame = stateFrame.getInt(state), subFrame = stateSubFrame.getInt(state);
            Object current = frames.get(frame);
            int cur = frameIndex.getInt(current);
            int next = cur;
            float t = 0;
            if (infoInterpolate.getBoolean(info)) {
                next = frameIndex.getInt(frames.get((frame + 1) % frames.size()));
                t = (int) ((float) subFrame / frameTime.getInt(current) * 1000.0F) / 1000.0F;
            }
            int rowSize = infoRowSize.getInt(info);
            int w = contentsWidth.getInt(contents), h = contentsHeight.getInt(contents);
            int x = spriteX.getInt(sprite), y = spriteY.getInt(sprite), p = spritePadding.getInt(sprite);
            Object[] mips = (Object[]) contentsMips.get(contents);
            for (int mip = 0; mip <= maxMip && mip < mips.length; mip++) {
                Object src = mips[mip];
                int sw = (Integer) imageWidth.invoke(src), sh = (Integer) imageHeight.invoke(src);
                int fw = w >> mip, fh = h >> mip;
                int dw = (w + 2 * p) >> mip, dh = (h + 2 * p) >> mip;
                if (fw <= 0 || fh <= 0 || dw <= 0 || dh <= 0) continue;
                int ax = ((cur % rowSize) * w) >> mip, ay = ((cur / rowSize) * h) >> mip;
                int bx = ((next % rowSize) * w) >> mip, by = ((next / rowSize) * h) >> mip;
                Object dst = newImage.newInstance(dw, dh, false);
                try {
                    frame((Long) imagePointer.invoke(src), sw, sh, ax, ay, bx, by, t, fw, fh,
                          (Long) imagePointer.invoke(dst), dw, dh, p, w, h);
                    write.invoke(encoder, texture, dst, mip, 0, x >> mip, y >> mip);
                } finally {
                    imageClose.invoke(dst);
                }
            }
        }
    }

    /**
     * One frame (fw x fh at (ax, ay) in the source), blended towards another at (bx, by)
     * by t, padded into dst as the animate_sprite shaders draw it (AtlasUpload.sourceIndex).
     */
    static void frame(long srcPtr, int sw, int sh, int ax, int ay, int bx, int by, float t, int fw, int fh,
                      long dstPtr, int dw, int dh, int p, int w, int h) {
        MemorySegment src = MemorySegment.ofAddress(srcPtr).reinterpret((long) sw * sh * 4);
        MemorySegment dst = MemorySegment.ofAddress(dstPtr).reinterpret((long) dw * dh * 4);
        int[] cols = AtlasUpload.sourceIndex(dw, fw, p, w);
        int[] rows = AtlasUpload.sourceIndex(dh, fh, p, h);
        for (int j = 0; j < dh; j++) {
            long dstRow = (long) j * dw * 4;
            long aRow = (long) Math.min(sh - 1, ay + rows[j]) * sw * 4, bRow = (long) Math.min(sh - 1, by + rows[j]) * sw * 4;
            for (int i = 0; i < dw; i++) {
                int a = src.get(ValueLayout.JAVA_INT_UNALIGNED, aRow + Math.min(sw - 1, ax + cols[i]) * 4L);
                int pixel = a;
                if (t > 0) {
                    int b = src.get(ValueLayout.JAVA_INT_UNALIGNED, bRow + Math.min(sw - 1, bx + cols[i]) * 4L);
                    pixel = 0;
                    for (int shift = 0; shift < 32; shift += 8) {
                        int ca = (a >>> shift) & 0xFF, cb = (b >>> shift) & 0xFF;
                        pixel |= Math.round(ca + (cb - ca) * t) << shift;
                    }
                }
                dst.set(ValueLayout.JAVA_INT_UNALIGNED, dstRow + i * 4L, pixel);
            }
        }
    }

    private static synchronized void resolve(ClassLoader loader) throws ReflectiveOperationException {
        if (newState != null) return;
        Class<?> contentsClass = Class.forName("net.minecraft.client.renderer.texture.SpriteContents", false, loader);
        Class<?> infoClass = Class.forName("net.minecraft.client.renderer.texture.SpriteContents$AnimatedTexture", false, loader);
        Class<?> stateClass = Class.forName("net.minecraft.client.renderer.texture.SpriteContents$AnimationState", false, loader);
        Class<?> frameClass = Class.forName("net.minecraft.client.renderer.texture.SpriteContents$FrameInfo", false, loader);
        Class<?> atlasClass = Class.forName("net.minecraft.client.renderer.texture.TextureAtlas", false, loader);
        Class<?> spriteClass = Class.forName("net.minecraft.client.renderer.texture.TextureAtlasSprite", false, loader);
        Class<?> imageClass = Class.forName("com.mojang.blaze3d.platform.NativeImage", false, loader);
        Class<?> textureClass = Class.forName("com.mojang.renderpearl.api.textures.GpuTexture", false, loader);
        Class<?> encoderClass = Class.forName("com.mojang.renderpearl.api.commands.CommandEncoder", false, loader);
        Class<?> deviceClass = Class.forName("com.mojang.renderpearl.api.device.GpuDevice", false, loader);
        Class<?> renderSystem = Class.forName("com.mojang.blaze3d.systems.RenderSystem", false, loader);
        sliceClass = Class.forName("com.mojang.renderpearl.api.buffers.GpuBufferSlice", false, loader);
        Class<?> intMap = Class.forName("it.unimi.dsi.fastutil.ints.Int2ObjectMap", false, loader);
        newIntMap = Class.forName("it.unimi.dsi.fastutil.ints.Int2ObjectOpenHashMap", false, loader).getConstructor();

        Constructor<?> c = stateClass.getDeclaredConstructor(contentsClass, infoClass, intMap, sliceClass.arrayType());
        c.setAccessible(true);
        stateFrame = field(stateClass, "frame");
        stateSubFrame = field(stateClass, "subFrame");
        stateInfo = field(stateClass, "animationInfo");
        needsToDraw = stateClass.getMethod("needsToDraw");
        infoFrames = field(infoClass, "frames");
        infoRowSize = field(infoClass, "frameRowSize");
        infoInterpolate = field(infoClass, "interpolateFrames");
        infoContents = field(infoClass, "this$0");
        frameIndex = field(frameClass, "index");
        frameTime = field(frameClass, "time");
        contentsMips = field(contentsClass, "byMipLevel");
        contentsWidth = field(contentsClass, "width");
        contentsHeight = field(contentsClass, "height");
        atlasStates = field(atlasClass, "animatedTexturesStates");
        atlasSprites = field(atlasClass, "sprites");
        atlasMaxMip = field(atlasClass, "maxMipLevel");
        getTexture = atlasClass.getMethod("getTexture");
        spriteX = field(spriteClass, "x");
        spriteY = field(spriteClass, "y");
        spritePadding = field(spriteClass, "padding");
        spriteContents = field(spriteClass, "contents");
        newImage = imageClass.getConstructor(int.class, int.class, boolean.class);
        imageWidth = imageClass.getMethod("getWidth");
        imageHeight = imageClass.getMethod("getHeight");
        imagePointer = imageClass.getMethod("getPointer");
        imageClose = imageClass.getMethod("close");
        write = encoderClass.getMethod("writeToTexture", textureClass, imageClass, int.class, int.class, int.class, int.class);
        device = renderSystem.getMethod("getDevice").invoke(null);
        createEncoder = deviceClass.getMethod("createCommandEncoder");
        newState = c;
    }

    private static Field field(Class<?> c, String name) throws NoSuchFieldException {
        Field f = c.getDeclaredField(name);
        f.setAccessible(true);
        return f;
    }
}
