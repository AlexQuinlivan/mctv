# JIT server

Optional. jitd gives the app JIT at launch on tvOS 27, in about 6 seconds, so the TV doesn't need your build Mac nearby. It runs on any always-on computer on the TV's network with SSH and python3. It has only been tested on macOS. On Linux it should work as is, because pymobiledevice3 does, but I haven't tried it.

When the app starts it posts its pid to jitd. jitd opens a tunnel to the TV with pymobiledevice3, attaches the TV's debugger to the app, prepares the JVM's code cache and detaches.

## Install

1. Put the JIT server's details in `config/server.env` (`scripts/setup.sh` asks for them, or copy `config/server.env.example`). You need its SSH host name, the name the TV uses for it, and the TV's IP address.
2. Run `scripts/deploy-server.sh` on your build machine. It copies `jitd/` and the tvOS developer disk image from Xcode to `~/.local/share/mctv-jitd`, writes `~/.config/mctv-jitd/jitd.env` and checks jitd answers. It runs as a systemd service on Linux or a LaunchDaemon on macOS, as your user. The first time, and when the service changes, it prints one `sudo` command to run yourself.
3. Pair the server with the TV, once. On the TV open Settings, Remotes and Devices, Remote App and Devices. On the server run this, and type the PIN the TV shows.

   ```sh
   ~/.local/share/mctv-jitd/venv/bin/pymobiledevice3 remote pair --name "Apple TV"
   ```

4. Run `scripts/mc-device.sh --jitd` on your build Mac. It builds the server's address and token into the app, pushes the game and launches it.

From then on, open the app from the TV's home screen.

## Security

The TV only lets a paired computer start a debug session, so the pairing record in `~/.pymobiledevice3` on the server is the real secret. Treat it like an SSH key. A paired computer can debug development-signed apps only, never system processes.

jitd answers only the addresses in `TV_ADDRESSES`. Every request needs the token from `config/jit.env`, which is built into the app. It attaches only to a pid the TV reports for the app's bundle IDs, checks the executable is `MCTV.app/MCTV`, and offers nothing but the JIT handshake. Don't forward its port or put it on the internet.

## Starting something with the TV

`JITD_ON_JIT` in `config/server.env` is a command jitd runs whenever the TV asks for JIT, for example `docker start minecraft` to have a game server ready when the game is. With `JITD_HOOK_TOKEN` and `JITD_HOOK_ALLOW` set, another program on the server can run the same command with `POST /hook`.

## Checks

```sh
curl http://$SERVER_NAME:25566/health          # "not allowed" unless you're in TV_ADDRESSES, which still means it's up
ssh $SERVER_HOST journalctl -u mctv-jitd       # Linux
ssh $SERVER_HOST tail ~/Library/Logs/mctv-jitd.log   # macOS
```

If jitd logs "no paired TV answered over bonjour", check the TV is awake and on the same network, and that pairing finished. The first launch after the TV restarts also mounts the developer disk image and takes a few seconds longer.
