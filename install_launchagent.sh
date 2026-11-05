#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_PY="${SCRIPT_DIR:?}/keepalive.py"
SRC_SWIFT="${SCRIPT_DIR:?}/cb_fast_reconnect.swift"
APP_SUPPORT_DIR="${HOME:?}/Library/Application Support/mi-ptkb-keepalive"
INSTALLED_PY="${APP_SUPPORT_DIR:?}/keepalive.py"
INSTALLED_CB="${APP_SUPPORT_DIR:?}/cb_fast_reconnect"
PLIST_PY="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-keepalive.plist"
PLIST_CB="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-fast-reconnect.plist"

mkdir -p "${APP_SUPPORT_DIR:?}"
cp "${SRC_PY:?}" "${INSTALLED_PY:?}"
chmod +x "${INSTALLED_PY:?}" "${SRC_PY:?}"

cat > /tmp/cb_info.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.user.mi-ptkb-fast-reconnect</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Keep Mi PTKB fast reconnection scan active</string>
</dict>
</plist>
EOF

swiftc -O -module-cache-path /tmp/swift-cache \
    -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker /tmp/cb_info.plist \
    "${SRC_SWIFT:?}" -o "${INSTALLED_CB:?}"
rm -f /tmp/cb_info.plist

cat > "${PLIST_CB:?}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.mi-ptkb-fast-reconnect</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALLED_CB}</string>
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

launchctl unload "${PLIST_CB:?}" 2>/dev/null || true
launchctl load -w "${PLIST_CB:?}"

if ! pgrep -f "mi-ptkb-keepalive/keepalive.py" >/dev/null 2>&1; then
    nohup /usr/bin/python3 "${INSTALLED_PY:?}" --sweet-spot-minutes 20 --hot-interval 3.5 --warm-interval 35 >> /tmp/mi-ptkb-keepalive.log 2>> /tmp/mi-ptkb-keepalive.err < /dev/null &
    disown
fi

echo "✅ 已部署并启动 Mi PTKB 双引擎服务 (三级甜点休眠守护 + CoreBluetooth 深睡眠零盲区闪连引擎)"
