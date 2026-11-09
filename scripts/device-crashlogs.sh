#!/usr/bin/env bash
# Copy recent crash/jetsam reports from the Apple TV into out/crashlogs/.
#   scripts/device-crashlogs.sh            everything
#   scripts/device-crashlogs.sh MCTV       only names containing MCTV (also try JitProbe, JetsamEvent)
source "$(dirname "$0")/lib.sh"
DEVICE="${DEVICE:-}"
[ -f "$ROOT/config/signing.env" ] && source "$ROOT/config/signing.env"
DEV=$(find_tv)
FILTER="${1:-}"
mkdir -p "$OUT/crashlogs"
xcrun devicectl device info files --device "$DEV" --domain-type systemCrashLogs --json-output "$OUT/crashlogs/list.json" >/dev/null
/usr/bin/python3 -I - "$OUT/crashlogs/list.json" "$FILTER" <<'PY' | while IFS= read -r f; do
import json, sys
filt = sys.argv[2]
files = json.load(open(sys.argv[1]))["result"]["files"]
for f in files:
    path = f.get("relativePath") or f.get("name") or ""
    if filt in path:
        print(path)
PY
    say "copying $f"
    xcrun devicectl device copy from --device "$DEV" --domain-type systemCrashLogs \
        --source "$f" --destination "$OUT/crashlogs/$(basename "$f")" >/dev/null || true
done
ls -lt "$OUT/crashlogs" | head -20
