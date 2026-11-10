# How it works

## The app

`mctv/` is a tvOS app. It shows a boot log, signs in with a Microsoft account (`MCAccount.m`), and runs the game, which `aot/aot.py` compiles ahead of time into `libmctvgame.dylib` in the app's Frameworks. tvOS doesn't let an app make executable memory of its own, so the game is machine code from the start. `aot/README.md` has how it's built.

`aot.py` pushes the game's assets, version files and mods into the app's Caches folder. Signed code (the game, LWJGL, SDL, MoltenVK and OpenAL) ships inside the app, since tvOS purges Caches.

## Memory

tvOS jetsams the app at about 2,098 MB, and GPU memory counts. The `increased-memory-limit` entitlement isn't available on tvOS. `extended-virtual-addressing` works.

Minecraft needed four changes to fit, made by the agent in `java/mctv-agent` when the game is baked.

- **Atlases on the CPU.** Minecraft draws every sprite into its atlas through a GPU texture of its own, about 4,000 at once. tvOS charges about 100 KB of GPU memory per texture, so the end of loading went over the limit. The agent pads each sprite's mip levels into a CPU copy of the atlas, as the shader would, and uploads each level once.
- **Animations on the CPU.** Minecraft keeps a GPU texture for every frame of every animated sprite, about 640. The agent draws the current frame into the atlas instead, matching Minecraft's output to within 1/255 in blended frames.
- **Smaller VMA blocks.** Minecraft leaves Vulkan Memory Allocator's block size at 256 MB, and big blocks stay resident however little they hold. 16 MB blocks (`-Dmctv.vma.blockMB`) cut GPU memory in a world by a few hundred MB and made it steady from run to run.
- **A 768 MB heap.** With 1 GB a single-player world came within 60 MB of the limit.

Each has Minecraft's own code as a fallback if it fails. Minecraft also applies its graphics preset at every start, and a missing preset means "fancy" with 16 chunks, so `scripts/mc-profile.py` writes `graphicsPreset:"custom"`.

The game is built with the G1 garbage collector from Oracle GraalVM, which collects in short pauses of under about 20 ms. GraalVM Community Edition only has the Serial collector, whose full collections stop the game for about 300 ms on the Apple TV.

## Minecraft on tvOS

Minecraft uses SDL 3 and LWJGL 3.4.3. `scripts/build-lwjgl-natives.sh`, `build-lwjgl-thirdparty.sh` (FreeType, shaderc, SPIRV-Cross), `build-sdl.sh`, `build-moltenvk.sh` and `build-openal.sh` build them for tvOS, and `prepare-natives.sh` puts them together for the app.

- **SDL.** `mctv/sdl` is an SDL video backend for the app. It offers the game layer as a Vulkan surface, and takes input from the app's own input code (`MCInput.m`, `SDLHost.m`). The window starts at the size Minecraft asks for and grows to the screen on the first event pump, because Minecraft only learns its size from resize events.
- **Vulkan.** MoltenVK 1.4.2 on Metal. There's no OpenGL. Minecraft loads OpenGL at every start, which the image skips (`Target_NativeLibrariesBootstrap`), and falls back to it after a start that didn't finish, so the app writes Vulkan and `startedCleanly:true` to its options at every launch. The simulator's Metal lacks base-instance indirect draws and linear textures on private buffers, so the simulator build of MoltenVK is patched for both (`patches/moltenvk`).
- **Callbacks.** LWJGL makes native callbacks with JNI and libffi, without its classes for Java's foreign function API, and the agent rewrites mods' own upcalls (Controlify's) to go through libffi too.
- **Controlify.** It filters and empties its SDL's event queue every tick, which ate Minecraft's input when they shared one SDL. It gets a renamed copy, `libSDL3_controlify.dylib`, and reads the controller through it, so `MCInput` stops turning the controller into keys and mouse. It also turns on SDL's Steam Controller support, which opens Bluetooth, and tvOS kills an app that does that without a usage description. The app sets `SDL_JOYSTICK_HIDAPI_STEAM=0`, which overrides it.
- **The Siri Remote.** SDL doesn't see it, so `MCInput` turns it into the pointer, arrow keys and clicks.
- **The home screen.** tvOS doesn't let a background app use the GPU, and MoltenVK reports the device lost. The render thread waits in the event pump while the app isn't active. The app asks for the usual background time so a short trip home keeps the server connection, and the agent stops Minecraft from holding back keepalive replies while the pump waits.
