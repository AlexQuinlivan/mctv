#!/bin/sh
# Forced command for jitd's localhost SSH key.
#
# macOS Local Network privacy keeps launchd jobs off the LAN, but not SSH
# sessions. So jitd runs tvlink.py through `ssh 127.0.0.1`, with a key that
# authorized_keys restricts to loopback and to this script. It accepts only
# "tvlink <pid>" and takes everything else from jitd.env.
set -eu
set -f
here=$(cd "$(dirname "$0")" && pwd)
# shellcheck disable=SC2086
set -- ${SSH_ORIGINAL_COMMAND:-}
if [ "$#" -ne 2 ] || [ "$1" != tvlink ]; then
    echo "ERROR refused: only 'tvlink <pid>' is allowed"
    exit 1
fi
case "$2" in
    ''|*[!0-9]*) echo "ERROR refused: bad pid"; exit 1 ;;
esac
# shellcheck disable=SC1091
. "$HOME/.config/mctv-jitd/jitd.env"
exec "$here/venv/bin/python" -I "$here/tvlink.py" --pid "$2" \
    --bundle "$JITD_BUNDLE_ID" \
    ${JITD_DDI_DIR:+--ddi "$JITD_DDI_DIR"} \
    ${JITD_TV_IDENTIFIER:+--identifier "$JITD_TV_IDENTIFIER"}
