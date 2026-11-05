#!/usr/bin/env bash
# 恢复 macOS bluetoothd 默认配置（移除 com.apple.MobileBluetooth.debug.plist 覆盖项，恢复雷蛇鼠标原生 7.5ms latency=0 低延迟保护）
set -euo pipefail

sudo rm -f /Library/Preferences/com.apple.MobileBluetooth.debug.plist /var/root/Library/Preferences/com.apple.MobileBluetooth.debug.plist
sudo notifyutil -p com.apple.bluetooth.prefsChanged
sudo killall bluetoothd

echo "✅ 已清除 MobileBluetooth.debug.plist 覆盖项并重启 bluetoothd，蓝牙鼠标已恢复原厂默认策略！"
