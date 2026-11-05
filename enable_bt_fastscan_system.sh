#!/usr/bin/env bash
# 开启 macOS bluetoothd 底层隐藏的 BLE 高速重连与参数协商宽容开关
# 基于逆向 /usr/sbin/bluetoothd:
#   - 0x10076a370: LE -> AllowAllConnectionParameterUpdates (-int 1)
#     解决小米键盘重连 1.08 秒时请求 (min=12, max=24, lat=44) 被 macOS 拒绝导致的 3.3 秒握手僵持；
#   - 0x10076b10c: LE -> IsConnectionScanOverriden (-bool true), ConnectionScanInterval (-int 60), ConnectionScanWindow (-int 30)
#     将背景重连扫描占空比从 10% (30ms/300ms) 提升至 50% (18.75ms/37.5ms)；
#   - 0x1007a35f0: LE -> ConnScanTimeoutExtendPercent (-int 60000)
#     将断连后的 LeConnectionScanHigh (100% 占空比 30ms/30ms 全速扫描) 默认 6 秒超时延长 600 倍至 1 小时。

set -euo pipefail

sudo defaults write /Library/Preferences/com.apple.MobileBluetooth.debug.plist LE -dict \
    AllowAllConnectionParameterUpdates -int 1 \
    IsConnectionScanOverriden -bool true \
    ConnectionScanInterval -int 60 \
    ConnectionScanWindow -int 30 \
    ConnScanTimeoutExtendPercent -int 60000

sudo chmod 644 /Library/Preferences/com.apple.MobileBluetooth.debug.plist
sudo cp /Library/Preferences/com.apple.MobileBluetooth.debug.plist /var/root/Library/Preferences/com.apple.MobileBluetooth.debug.plist 2>/dev/null || true
sudo notifyutil -p com.apple.bluetooth.prefsChanged
sudo killall bluetoothd

echo "✅ 已写入 /Library/Preferences/com.apple.MobileBluetooth.debug.plist 并重启 bluetoothd 使 LeConnectionManager 立即加载生效！"
