#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PY="${SCRIPT_DIR:?}/keepalive.py"
APP_SUPPORT_DIR="${HOME:?}/Library/Application Support/mi-ptkb-keepalive"
INSTALLED_PY="${APP_SUPPORT_DIR:?}/keepalive.py"
PLIST_PY="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-keepalive.plist"
PLIST_CB="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-fast-reconnect.plist"

# Remove legacy cb_fast_reconnect which conflicted with BTLEServer SMP LinkReady handshake
if [ -f "${PLIST_CB}" ]; then
    launchctl unload -w "${PLIST_CB}" 2>/dev/null || true
    rm -f "${PLIST_CB}"
fi
pkill -f "cb_fast_reconnect" 2>/dev/null || true
rm -f "${APP_SUPPORT_DIR}/cb_fast_reconnect"

mkdir -p "${APP_SUPPORT_DIR:?}"
cp "${SRC_PY:?}" "${INSTALLED_PY:?}"
chmod +x "${INSTALLED_PY:?}" "${SRC_PY:?}"

cat > "${PLIST_PY:?}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mi-ptkb-keepalive</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/python3</string>
        <string>${INSTALLED_PY}</string>
        <string>--sweet-spot-minutes</string>
        <string>20</string>
        <string>--hot-interval</string>
        <string>3.5</string>
        <string>--warm-interval</string>
        <string>8.0</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/mi-ptkb-keepalive.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/mi-ptkb-keepalive.err</string>
</dict>
</plist>
EOF

launchctl unload "${PLIST_PY:?}" 2>/dev/null || true
pkill -f "mi-ptkb-keepalive/keepalive.py" 2>/dev/null || true
rm -f /tmp/mi-ptkb-keepalive.log /tmp/mi-ptkb-keepalive.err

nohup /usr/bin/python3 "${INSTALLED_PY:?}" --sweet-spot-minutes 20 --hot-interval 3.5 --warm-interval 8.0 > /tmp/mi-ptkb-keepalive.log 2> /tmp/mi-ptkb-keepalive.err < /dev/null &
disown

echo "✅ 已移除冲突的 cb_fast_reconnect 并启动优化后的 Mi PTKB 甜点保活服务 (hot=3.5s, warm=8.0s, sweet_spot=20m)"
