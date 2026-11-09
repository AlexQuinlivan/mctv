# How it works

## The app

`mctv/` is a tvOS app. It shows a boot log, starts HotSpot through JLI with Amethyst's Java 25 runtime, and runs Minecraft through Amethyst's launcher classes. Nothing of Amethyst's launcher UI is used. The scripts download the game, the libraries and the mods, and push them into the app's Caches folder. Signed code (the runtime, natives and jars) ships inside the app, since tvOS purges Caches.

Amethyst's runtime and natives are iOS builds. `scripts/prepare-runtime.sh` and `prepare-natives.sh` relabel them for tvOS and the simulator with `vtool`, as Amethyst's own Makefile does for other platforms.

JLI starts Java by calling `main()` again on a new thread, so `main()` hands that call straight back (`MCIsJLIReentry`). `libjvm` finds `DeviceHasTXM()` with `dlsym`, so the app builds without dead-code stripping or the debug dylib. Changing `HOME` after UIKit starts crashes UIKit's event thread, so `user.home` is passed to Java instead.

## JIT

On tvOS 27 the Apple TV 4K (3rd generation) has TXM so an app can't map executable memory by itself. It can run memory a debugger prepared. At launch the app asks for its code cache through a small protocol of `brk` traps (`shared/jit26_calls.c`). A debugger allocates the regions and writes one page in each 16 KB, then detaches. The JVM then writes code through a second, writable mapping.

There are two debuggers for this.

- `tools/jit26.py` in lldb, from your build Mac. lldb can't write registers over the network, so it sends raw `P` packets. Each page is one round trip, so a 64 MB code cache takes about 75 seconds.
- `server/jitd` on an always-on computer on the TV's network. It talks to the TV's debugserver through pymobiledevice3's userspace tunnel and pipelines the packets, which takes about 0.3 seconds. The app asks for it over HTTP with a token built into the app.


## Memory

tvOS jetsams the app at about 2,098 MB, and GPU memory counts. The `increased-memory-limit` entitlement isn't available on tvOS. `extended-virtual-addressing` works and lets HotSpot reserve what it wants.

Minecraft 26.x needed four changes to fit, made by the Java agent (`java/mctv-agent`) as classes load.

- **Atlases on the CPU.** 26.x draws every sprite into its atlas through a GPU texture of its own, about 4,000 at once. tvOS charges about 100 KB of GPU memory per texture, so the end of loading went over the limit. The agent pads each sprite's mip levels into a CPU copy of the atlas, as the shader would, and uploads each level once.
- **Animations on the CPU.** 26.x keeps a GPU texture for every frame of every animated sprite, about 640. The agent draws the current frame into the atlas instead, matching Minecraft's output to within 1/255 in blended frames.
- **Smaller VMA blocks.** Minecraft leaves Vulkan Memory Allocator's block size at 256 MB, and big blocks stay resident however little they hold. 16 MB blocks (`-Dmctv.vma.blockMB`) cut GPU memory in a world by a few hundred MB and made it steady from run to run.
- **A 768 MB heap.** With 1 GB a single-player world came within 60 MB of the limit.

Each has Minecraft's own code as a fallback if it fails. 26.x also applies its graphics preset at every start, and a missing preset means "fancy" with 16 chunks, so `scripts/mc-profile.py` writes `graphicsPreset:"custom"`.

## Minecraft 26.x

26.x replaced GLFW with SDL 3 and LWJGL 3.4.3. `scripts/build-lwjgl-natives.sh`, `build-lwjgl-thirdparty.sh` (FreeType, shaderc, SPIRV-Cross), `build-sdl.sh` and `build-moltenvk.sh` build them for tvOS, and `prepare-26.sh` assembles the app's natives and jars.

- **SDL.** `mctv/sdl` is an SDL video backend for the app. It offers the game layer as a Vulkan surface, and takes input from the app's own input code. The window starts at the size Minecraft asks for and grows to the screen on the first event pump, because Minecraft only learns its size from resize events.
- **Vulkan.** MoltenVK 1.4.2 on Metal. The OpenGL path through MobileGlues doesn't run 26.x. Minecraft falls back to OpenGL after a start that didn't finish, so choosing Vulkan also writes `startedCleanly:true`. The simulator's Metal lacks base-instance indirect draws and linear textures on private buffers, so the simulator build of MoltenVK is patched for both (`patches/moltenvk`).
- **FFM callbacks.** On Java 25, LWJGL 3.4.3 makes callbacks through Java's foreign function API, and those crash Amethyst's JVM. `prepare-26.sh` strips the core jar's Java 25 classes, so LWJGL uses JNI and libffi. The agent rewrites mods' own upcalls (Controlify's) to go through libffi too.
- **Controlify.** It filters and empties its SDL's event queue every tick, which ate Minecraft's input when they shared one SDL. It gets a renamed copy, `libSDL3_controlify.dylib`. It also turns on SDL's Steam Controller support, which opens Bluetooth, and tvOS kills an app that does that without a usage description. The app sets `SDL_JOYSTICK_HIDAPI_STEAM=0`, which overrides it.
- **The home screen.** tvOS doesn't let a background app use the GPU, and MoltenVK reports the device lost. The render thread waits in the event pump while the app isn't active. The app asks for the usual background time so a short trip home keeps the server connection, and the agent stops Minecraft from holding back keepalive replies while the pump waits.

## Minecraft 1.21.11

The older build uses Amethyst's GLFW fork of LWJGL 3.3.3 over the bridge in `mctv/Sources/bridge`, and OpenGL through MobileGlues on ANGLE's GLES 3 on Metal. The simulator's ANGLE only offers GLES 2, so `prepare-natives.sh` patches its copy to report GLES 3, as ANGLE's own simulator builds do.

Amethyst's GLFW only stubs the gamepad API. `scripts/patch-glfw-gamepad.py` makes the TV's controller GLFW gamepad 0 for Controlify, and `java/mctv-mod` passes Controlify's rumble to Core Haptics. Core Haptics' looping players drop the connection to game controllers on tvOS, so `MCRumble.m` plays one long event and changes its strength live.
