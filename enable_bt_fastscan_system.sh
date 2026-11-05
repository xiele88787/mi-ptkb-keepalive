#!/usr/bin/env bash
# 开启 macOS bluetoothd 底层隐藏的 BLE 高速重连扫描参数 (基于逆向 /usr/sbin/bluetoothd 0x10076b10c & 0x1007a35f0)
# 作用：
#   1. ConnScanTimeoutExtendPercent = 60000: 将键盘断开后的 LeConnectionScanHigh (100% 占空比 30ms/30ms 全速扫描)
#      默认 6 秒超时延长 600 倍至 1 小时；
#   2. IsConnectionScanOverriden = true, ConnectionScanInterval = 60 (37.5ms), ConnectionScanWindow = 30 (18.75ms):
#      将常规重连扫描占空比从 10% (30ms/300ms) 提升至 50% (18.75ms/37.5ms)，最大广播捕获盲区从 270ms 缩短至 18.75ms；
#   3. 通过 notifyutil -p com.apple.bluetooth.prefsChanged 通知 bluetoothd 热加载配置，无需重启蓝牙。

set -euo pipefail

sudo defaults write /Library/Preferences/com.apple.MobileBluetooth.debug.plist LE -dict \
    IsConnectionScanOverriden -bool true \
    ConnectionScanInterval -int 60 \
    ConnectionScanWindow -int 30 \
    ConnScanTimeoutExtendPercent -int 60000

sudo chmod 644 /Library/Preferences/com.apple.MobileBluetooth.debug.plist
sudo notifyutil -p com.apple.bluetooth.prefsChanged

echo "✅ 已写入 /Library/Preferences/com.apple.MobileBluetooth.debug.plist 并通知 bluetoothd 热加载！"
