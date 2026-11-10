# MCTV

**NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR ASSOCIATED WITH MOJANG OR MICROSOFT.**

<img src="docs/boot.png" width="500" alt="boot">

A Minecraft: Java Edition launcher on tvOS 27, played with a game controller. Or, if you're so inclined, a keyboard and the Siri Remote. It runs Minecraft 26.3 with Fabric, Sodium and Controlify, compiled ahead of time with GraalVM Native Image, and renders with Vulkan through MoltenVK. There's no JIT, so nothing else is needed at launch.

I just wanted to play Minecraft with my kid. This repository is the culmination of that journey. Whilst this all may work for you and of course, you're welcome to try it, I hold no desire to keep this going further than my personal needs.

The repository holds no game files, code or art from Mojang. There are no prebuilt apps. You build and sign it yourself, for your own Apple TV.

## What you need

- An Apple TV 4K on tvOS 27. It's been tested on a 3rd generation with tvOS 27.2.
- A Mac with Apple silicon, and Xcode 27 with the tvOS 27.2 SDK and simulator.
- An Apple developer account for signing.
- About 10 GB of disk for GraalVM, the native builds and the game.

## Setup

```sh
git clone <this repo> mctv && cd mctv
scripts/setup.sh
```

It checks the tools, asks for your team and a bundle ID, downloads GraalVM and builds LWJGL, SDL, MoltenVK and OpenAL for tvOS.

Then:

```sh
python3 -I aot/aot.py sim --world      # play in the simulator, and sign in there once
python3 -I aot/aot.py pgo              # profile the game, so it builds smaller (optional)
python3 -I aot/aot.py device           # install on the Apple TV, push the game and launch it
```

The first build compiles the game. After that only what changed is rebuilt. Pair the Apple TV in Xcode's Device Hub before the first `device`.

`pgo` plays the game through a test in the simulator, counting what runs, and saves the counts in `aot/pgo`. Builds after that are optimised with them, and the game's code comes out about a quarter of the size, so the app is about 340 MB smaller to install. It needs Oracle GraalVM, and should be run again after changing mods.

The game is built by Oracle GraalVM, whose G1 garbage collector keeps it from stuttering. Setup asks before downloading it, since it comes under Oracle's [GraalVM Free Terms and Conditions](https://www.oracle.com/downloads/licenses/graal-free-license.html). Without it, add `--graal ce` to build with GraalVM Community Edition alone, whose collector now and then pauses the game for about 300 ms.

## Signing in

The app asks for a Microsoft account that owns Minecraft. The TV shows a code and a QR code. Enter the code at microsoft.com/link on your phone and the game starts. After that it goes straight in and renews the login by itself.

The simulator asks too, and keeps its login in a file, since unsigned simulator builds can't use the Keychain. So, be careful.

## Controls

- **Controller.** Any extended gamepad (Xbox, PlayStation, MFi), through the Controlify mod. Menus are driven by the D-pad and sticks, with radial menus, an on-screen keyboard and rumble.
- **Siri Remote.** Swipe to move the pointer or look around. The ring is a D-pad. In menus the centre presses the highlighted button. While playing, left and right change the hotbar slot, up jumps, down sneaks and the centre attacks. Play/Pause is right click and Back is Escape.
- **Keyboard.** A Bluetooth keyboard works as on a computer.

## Mods

The mods are the ones in `scripts/fabric-lock.json`: Sodium, Lithium, FerriteCore, ImmediatelyFast, Controlify and No Chat Reports, with Fabric API and YACL, which they need. `aot/README.md` has how to add others, and what can stop one working.

## Limits

- The app renders at 1920x1080, and tvOS scales it to 4K. tvOS will jetsam you at about 2.1 GB, including GPU memory, so the game gets a 768 MB heap. Render distance 8 and Improved Transparency fit.
- Going to the home screen pauses the game. tvOS suspends the app after about 30 seconds, which drops a server connection.
- Mods that draw with OpenGL, such as Iris, can't work. The app renders only through Vulkan.
- Steam controllers over Bluetooth don't work, because tvOS would need a Bluetooth permission the app doesn't ask for. I also don't own one, so haven't cared to fix.

## Third party components and their licenses

Code in this repository that comes from other projects.

- The sign-in code (`mctv/Sources/MCAccount.m`) follows [Amethyst-iOS](https://github.com/AngelAuraMC/Amethyst-iOS)'s: [GPL-3.0](https://github.com/AngelAuraMC/Amethyst-iOS/blob/main/LICENSE).
- `glfw_keycodes.h` from [GLFW](https://github.com/glfw/glfw): [zlib](https://github.com/glfw/glfw/blob/master/LICENSE.md).
- `mctv/sdl` follows [SDL](https://github.com/libsdl-org/SDL)'s UIKit backend and is built into SDL: [zlib](https://github.com/libsdl-org/SDL/blob/main/LICENSE.txt).
- The patches in `patches/` change SDL, [LWJGL](https://github.com/LWJGL/lwjgl3) (two of them from AngelAuraMC's iOS fork) and [MoltenVK](https://github.com/KhronosGroup/MoltenVK), and keep those projects' licenses.

What setup downloads and builds keeps its own license. That's GraalVM ([GPL-2.0 with the Classpath Exception](https://github.com/oracle/graal/blob/master/LICENSE), or Oracle's GFTC), LWJGL ([BSD-3-Clause](https://github.com/LWJGL/lwjgl3/blob/master/LICENSE.md)) with FreeType, HarfBuzz, shaderc and SPIRV-Cross, SDL ([zlib](https://github.com/libsdl-org/SDL/blob/main/LICENSE.txt)), MoltenVK ([Apache-2.0](https://github.com/KhronosGroup/MoltenVK/blob/main/LICENSE)) and [OpenAL Soft](https://github.com/kcat/openal-soft) ([LGPL-2.1](https://github.com/kcat/openal-soft/blob/master/COPYING), linked as its own library). Fabric and the mods come from their authors under their own licenses.

## License

GPL-3.0 (`LICENSE`), since the sign-in code derives from Amethyst-iOS. `mctv/sdl` is under SDL's zlib license, since it's built into SDL. `glfw_keycodes.h` keeps its own license.

Thanks to Amethyst-iOS and PojavLauncher, and to everyone above.
