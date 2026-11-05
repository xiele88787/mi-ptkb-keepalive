#!/usr/bin/env bash
set -euo pipefail

PLIST_PY="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-keepalive.plist"
PLIST_CB="${HOME:?}/Library/LaunchAgents/com.user.mi-ptkb-fast-reconnect.plist"
APP_SUPPORT_DIR="${HOME:?}/Library/Application Support/mi-ptkb-keepalive"

for p in "${PLIST_PY}" "${PLIST_CB}"; do
    if [ -f "${p}" ]; then
        launchctl unload -w "${p}" 2>/dev/null || true
        rm -f "${p}"
    fi
done

pkill -f "mi-ptkb-keepalive/keepalive.py" 2>/dev/null || true
pkill -f "cb_fast_reconnect" 2>/dev/null || true

if [ -d "${APP_SUPPORT_DIR:?}" ]; then
    rm -rf "${APP_SUPPORT_DIR:?}"
fi
echo "✅ 已停止并卸载全部 Mi PTKB 守护服务"
