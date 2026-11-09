#!/usr/bin/env bash
# Installs or updates jitd, the JIT server, on SERVER_HOST in config/server.env.
# Any always-on computer on the TV's network with SSH and Python 3 will do,
# Linux or macOS. It gets server/jitd and the tvOS disk image from this Mac's
# Xcode, its config in ~/.config/mctv-jitd/jitd.env, and a service that starts
# at boot and runs as you.
#
#   scripts/deploy-server.sh
source "$(dirname "$0")/lib.sh"

[ -n "${SERVER_HOST:-}" ] || die "set SERVER_HOST in config/server.env (config/server.env.example)"
[ -n "${TV_ADDRESSES:-}" ] || die "set TV_ADDRESSES in config/server.env to your Apple TV's IP address"
HOST="$SERVER_HOST"
LABEL="${JITD_LABEL:-local.mctv.jitd}"
load_jit_config
[ -n "${JIT_SERVER:-}" ] || die "config/jit.env has no JIT_SERVER. Set SERVER_NAME in config/server.env and delete config/jit.env to remake it"

os=$(ssh "$HOST" uname -s)
remote_home=$(ssh "$HOST" 'echo $HOME')
remote_user=$(ssh "$HOST" 'id -un')
APP="$remote_home/.local/share/mctv-jitd"
CONFDIR="$remote_home/.config/mctv-jitd"
CONF="$CONFDIR/jitd.env"

say "jitd -> $HOST:$APP ($os)"
ssh "$HOST" "mkdir -p '$APP' '$CONFDIR'"
rsync -a "$ROOT"/server/jitd/{jitd.py,gdbremote.py,session.py,tvlink.py,tvlink-ssh.sh,requirements.txt} "$HOST:$APP/"
DDI=/Library/Developer/DeveloperDiskImages/tvOS_DDI/Restore
[ -d "$DDI" ] || die "no $DDI. Open Xcode once so it installs the tvOS developer disk image"
rsync -a --delete "$DDI/" "$HOST:$APP/ddi/tvOS_DDI/Restore/"
ssh "$HOST" "set -e; cd '$APP'
    py=\$(command -v /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12 python3.14 python3.13 python3.12 python3 2>/dev/null | head -1)
    [ -n \"\$py\" ] || { echo 'no python3 on $HOST'; exit 1; }
    [ -x venv/bin/python ] || \"\$py\" -m venv venv
    venv/bin/pip install -q --disable-pip-version-check --require-hashes -r requirements.txt"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
(umask 077; {
    echo "JITD_LISTEN=${SERVER_LISTEN:-0.0.0.0}:25566"
    echo "JITD_ALLOW=$TV_ADDRESSES"
    echo "JITD_TOKEN=$JIT_TOKEN"
    echo "JITD_TV_PYTHON=$APP/venv/bin/python"
    echo "JITD_BUNDLE_ID=$BUNDLE_PREFIX.app,$BUNDLE_PREFIX.app26"
    echo "JITD_DDI_DIR=$APP/ddi/tvOS_DDI/Restore"
    [ "$os" = Darwin ] && echo "JITD_TV_SSH=$remote_user@127.0.0.1" && echo "JITD_TV_SSH_KEY=$CONFDIR/tvlink_ed25519"
    # Optional JITD_ON_JIT, JITD_HOOK_TOKEN and JITD_HOOK_ALLOW from config/server.env.
    for key in JITD_ON_JIT JITD_HOOK_TOKEN JITD_HOOK_ALLOW; do
        [ -n "${!key:-}" ] && echo "$key=${!key}"
    done
    true
} > "$TMP/jitd.env")
ssh "$HOST" "umask 077 && cat > '$CONF' && chmod 600 '$CONF'" < "$TMP/jitd.env"

if [ "$os" = Darwin ]; then
    # macOS Local Network privacy keeps launchd jobs off the LAN but not SSH
    # sessions, so jitd reaches the TV through ssh to 127.0.0.1. Its key can
    # only run tvlink-ssh.sh, and only from loopback. Needs Remote Login on.
    ssh "$HOST" bash -s -- "$APP" "$CONFDIR" <<'REMOTE'
set -eu
app=$1 conf=$2
key="$conf/tvlink_ed25519"
chmod 755 "$app/tvlink-ssh.sh"
[ -f "$key" ] || ssh-keygen -q -t ed25519 -N '' -C 'mctv-jitd tvlink' -f "$key"
chmod 600 "$key"
line="restrict,from=\"127.0.0.1,::1\",command=\"$app/tvlink-ssh.sh\" $(cat "$key.pub")"
ak="$HOME/.ssh/authorized_keys"
if ! grep -qxF "$line" "$ak" 2>/dev/null; then
    cp -p "$ak" "$ak.bak-mctv" 2>/dev/null || true
    { grep -v 'mctv-jitd tvlink$' "$ak" 2>/dev/null || true; echo "$line"; } > "$ak.new"
    chmod 600 "$ak.new"
    mv "$ak.new" "$ak"
    echo "authorized_keys: installed the restricted mctv-jitd tvlink key"
fi
REMOTE
    SERVER_PATH="${SERVER_PATH:+${SERVER_PATH//\$HOME/$remote_home}}"
    UNIT="$LABEL.plist"
    INSTALLED="/Library/LaunchDaemons/$UNIT"
    INSTALL="install -m 644 -o root -g wheel $APP/$UNIT /Library/LaunchDaemons/ && (launchctl bootout system/$LABEL 2>/dev/null; launchctl bootstrap system $INSTALLED)"
    LOGS="tail ~/Library/Logs/mctv-jitd.log"
    # A LaunchDaemon that runs as you. A login agent would need Local Network
    # approval, which nobody is there to give.
    cat > "$TMP/$UNIT" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>UserName</key><string>$remote_user</string>
    <key>GroupName</key><string>staff</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/venv/bin/python</string>
        <string>-I</string>
        <string>$APP/jitd.py</string>
        <string>--config</string>
        <string>$CONF</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key><string>$remote_home</string>
        <key>PATH</key><string>${SERVER_PATH:-/usr/local/bin}:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><true/>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>StandardOutPath</key><string>$remote_home/Library/Logs/mctv-jitd.log</string>
    <key>StandardErrorPath</key><string>$remote_home/Library/Logs/mctv-jitd.log</string>
</dict>
</plist>
EOF
else
    UNIT=mctv-jitd.service
    INSTALLED="/etc/systemd/system/$UNIT"
    INSTALL="install -m 644 $APP/$UNIT /etc/systemd/system/ && systemctl daemon-reload && systemctl enable mctv-jitd && systemctl restart mctv-jitd"
    LOGS="journalctl -u mctv-jitd"
    cat > "$TMP/$UNIT" <<EOF
[Unit]
Description=MCTV JIT server
Wants=network-online.target
After=network-online.target

[Service]
User=$remote_user
ExecStart=$APP/venv/bin/python -I $APP/jitd.py --config $CONF
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
fi
rsync -a "$TMP/$UNIT" "$HOST:$APP/"
if ! ssh "$HOST" "cmp -s '$APP/$UNIT' '$INSTALLED'"; then
    say "jitd's service needs installing or updating, which takes sudo. Run this in a terminal:"
    echo "  ssh -t $HOST \"sudo sh -c '$INSTALL'\""
    exit 0
fi
ssh "$HOST" "pkill -f '$APP/jitd.py' || true"  # the service starts it again with the new files
sleep 3
say "health check"
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${JIT_SERVER%/}/health" || true)
case "$code" in
    200) say "jitd answers" ;;
    403) say "jitd answers (this Mac isn't in TV_ADDRESSES, so it refused the check, as it should)" ;;
    *) die "jitd didn't answer at $JIT_SERVER. See '$LOGS' on $HOST" ;;
esac
