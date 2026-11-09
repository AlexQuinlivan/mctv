#!/usr/bin/env bash
# Writes your team (from Xcode's accounts), the bundle ID prefix and the paired
# Apple TV to config/signing.env. Add your account in Xcode > Settings >
# Accounts first.
#
#   scripts/set-team.sh                          the only paid team Xcode knows
#   scripts/set-team.sh you@example.com          that Apple ID's team
#   scripts/set-team.sh --team ABCDE12345        this team
#   scripts/set-team.sh --prefix com.you.mctv    bundle IDs become com.you.mctv.app and so on
source "$(dirname "$0")/lib.sh"

APPLE_ID=
TEAM=
PREFIX="$BUNDLE_PREFIX"
while [ $# -gt 0 ]; do
    case "$1" in
        --team) TEAM="$2"; shift ;;
        --prefix) PREFIX="$2"; shift ;;
        -*) die "unknown option $1" ;;
        *) APPLE_ID="$1" ;;
    esac
    shift
done

if [ -z "$TEAM" ]; then
    defaults export com.apple.dt.Xcode - > "$BUILD/xcode-prefs.plist" 2>/dev/null || die "can't read Xcode's preferences"
    TEAM=$(/usr/bin/python3 -I - "$BUILD/xcode-prefs.plist" "$APPLE_ID" <<'PY'
import plistlib, sys
accounts = plistlib.load(open(sys.argv[1], "rb")).get("IDEProvisioningTeams", {})
teams = [t for key, ts in accounts.items() if not sys.argv[2] or key == sys.argv[2] for t in ts]
for t in teams:
    print("  %s  %s  %s" % (t["teamID"], "free" if t.get("isFreeProvisioningTeam") else "paid", t.get("teamName", "")), file=sys.stderr)
paid = sorted({t["teamID"] for t in teams if not t.get("isFreeProvisioningTeam")})
if len(paid) == 1:
    print(paid[0])
PY
)
    rm -f "$BUILD/xcode-prefs.plist"
    [ -n "$TEAM" ] || die "pick one of the teams above with --team, or add your account in Xcode > Settings > Accounts"
fi
for t in ${REFUSE_TEAMS:-}; do
    [ "$TEAM" != "$t" ] || die "config/signing.env refuses team $t"
done
[[ "$PREFIX" =~ ^[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+$ ]] || die "bundle prefix '$PREFIX' should look like com.yourname.mctv"
[ "$PREFIX" != com.example.mctv ] || say "bundle prefix is still com.example.mctv. Pass --prefix with a name of your own"

dev=$(find_tv 2>/dev/null || true)
(umask 077; cat > "$ROOT/config/signing.env" <<EOF
DEVELOPMENT_TEAM=$TEAM
BUNDLE_PREFIX=$PREFIX
DEVICE=$dev
REFUSE_TEAMS="${REFUSE_TEAMS:-}"
EOF
)
say "config/signing.env: team $TEAM, bundle prefix $PREFIX, Apple TV ${dev:-auto-detected at each run}"
