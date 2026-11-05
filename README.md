# mi-ptkb-keepalive

**小米便携双模键盘（Mi PTKB / XMBXJP01YM）macOS 蓝牙休眠根治与零盲区闪连引擎**

针对小米便携双模键盘（蓝牙名称 `Mi PTKB`，`VendorID = 0x2717`，`ProductID = 0x507C`）在 macOS 蓝牙（BLE）模式下“休眠极快、唤醒极慢、吞首字、停手几秒再打字明显粘滞”的顽疾，通过逆向分析 macOS `/usr/sbin/bluetoothd` 与键盘 HID 报告描述符，提供一套在 **2 倍电池功耗预算内** 运行的双引擎根治方案：

1. **智能三级甜点保活与鼠标联动预唤醒（`keepalive.py`）**：将原厂锁死的 **2 分 38 秒（150 秒）深休眠断连** 精准延长至 **20 分钟甜点值**（可调），并在手握鼠标滑动时抢先将键盘从 `300ms ~ 640ms` 浅休眠拉回 `~29ms` 满血活跃态；人离开座位超 20 分钟或锁屏/熄屏后立即停止发包，释放键盘进入原厂深休眠（离座 0 额外功耗）。
2. **CoreBluetooth 深睡眠零盲区闪连引擎（`cb_fast_reconnect.swift`）**：当键盘已进入深睡眠（断连）或切往 Windows 2.4G 模式时，利用 `CBCentralManager` 每 5.2 秒刷新一次连接请求，强制 macOS `bluetoothd` 持续锁定在 `LeConnectionScanHigh`（`30ms/30ms`，**100% 占空比零盲区全速扫描**），砍掉原本 `1 ~ 3.5 秒` 的广播漏检等待，且对睡眠中的键盘 **0 电量消耗**。

---

## 一、 根因逆向诊断（基于 macOS `bluetoothd` 与 `IORegistry` 实测）

### 1. 硬件与 GATT 拓扑画像
从 macOS `IORegistry` 与 `bluetoothd` `statedump` 提取的硬件参数：

- **型号**：小米便携双模键盘 `XMBXJP01YM`（BLE 广播名 `Mi PTKB`）
- **标识**：`VID = 0x2717` / `PID = 0x507C` / `Appearance = 0x03C1 (Keyboard)`
- **主控方案**：泰凌微（Telink Semiconductor）BLE SoC（包含私有 OTA 服务 `00010203-0405-0607-0809-0A0B0C0D1912`）
- **GATT 关键句柄**：
  - `0x001D (valueHandle 0x001E)`：`0x2A4D` Keyboard Input Report（`ReportID = 1`，8 字节按键输入）
  - `0x0021 (valueHandle 0x0022)`：`0x2A4D` Keyboard Output Report（`ReportID = 1`，1 字节 LED 状态，支持 `read / write / responseless-writes`）
  - `0x002F (valueHandle 0x0030)`：`0x2A19` Battery Level（电池电量百分比）

### 2. 为什么“睡得极快”？（两段式激进省电策略）

```text
[打字活跃态: RTT ~29ms]
   │
   ├─(停手 0.5s ~ 3.0s)──> [第一段：浅休眠 Slave Latency = 22]
   │                        跳过 22 个 15ms 周期，首包 RTT 暴涨至 215ms ~ 642ms
   │
   └─(停手 2m38s / 150s)─> [第二段：深休眠 STATUS 719 断连]
                            键盘主动发送 Remote User Terminated Connection 切断蓝牙射频
```

- **浅休眠（0.5 ~ 3 秒触发）**：macOS 为 `Mi PTKB` 分配 `LEHID-15ms` 档位（`interval = 15ms, peripheralLatency = 22`）。实测停手仅 1~3 秒后，键盘进入跳帧浅休眠，单次 GATT 往返延迟（RTT）从 `29.0ms` 飙升至 `215ms ~ 642.9ms`。
- **深休眠（2 分 38 秒触发）**：`bluetoothd` 日志实测显示，最后一次按键后仅 **158 秒**（例如 `11:43:18` 停手 -> `11:45:56.803`），键盘即主动发起 `STATUS 719 (0x13 Remote User Terminated Connection)` 彻底断开 BLE 链路并关闭射频，且唤醒那一下按键仅作 GPIO 中断唤醒 MCU，不做离线缓存（必吞首字）。

### 3. 为什么“鼠标秒醒，而键盘唤醒重连极慢”？（macOS 6 秒高速扫描生死线）

对比同机连接的雷蛇蓝牙鼠标（`Basilisk X HyperSpeed`，Appearance `0x03C2`）与 `Mi PTKB`（Appearance `0x03C1`）在 `bluetoothd` 中的处理逻辑：

```text
11:45:56.805  Device "63F7CCA4-..." (Mi PTKB) does not require low latency
11:45:56.815  Added device to filter accept list: connectionInterval min:10ms max:30ms, LowLatency NO
11:45:56.816  Arming Fast connection scan Timer with interval 5.999000 seconds -> LeConnectionScanHigh (window 0x30 / interval 0x30 = 100% 占空比)
11:46:02.819  Fast connection scan Timer expired! -> shouldEnableFastConnectionScan:0 (exp:80776.454, reached:1)
```

1. **6 秒后痛失全速扫描**：键盘断开后的前 **6.0 秒**，`bluetoothd` 开启 `LeConnectionScanHigh`（扫描窗口 `30ms` / 扫描周期 `30ms`，即 **100% 占空比全速监听**）；**6 秒一过，计时器过期（`reached: 1`），扫描降级为 `30ms / 300ms`（仅 10% 占空比，每 300ms 中有 270ms 盲区）**。当你几分钟后按键盘唤醒时，键盘发出的短促广播极大概率撞在 90% 的盲区里，白白耗费 `1 ~ 3.5 秒`。
2. **建连初始间隔慢 4 倍**：鼠标被 `bluetoothd` 判定为 `needs low latency`，享受 `LEHID-7.5msCE4 (7.5ms)` 极速连接间隔；而键盘被判定为 `LowLatency NO`，重连初期以 `30ms` 慢速间隔握手，光完成 SMP 加密与 GATT 初始化就要额外花掉 `836ms ~ 1.3s`。

---

## 二、 核心技术突破

### 1. 穿透 IOKit 缓存的无感虚拟 LED 同步空中脉冲
解析 `Mi PTKB` 的原始 `ReportDescriptor`：

```text
05 01 09 06 a1 01 85 01 ... 95 05 75 01 05 08 19 01 29 05 91 02 ...
```

虽然这把 85 键紧凑键盘物理上只有 `CapsLock` 一颗状态灯，但固件在 `ReportID = 1` 的 Output Report（`UsagePage = 0x08`）中声明了完整的 5 个 LED 位（`1=NumLock, 2=CapsLock, 3=ScrollLock, 4=Compose, 5=Kana`）。

- **为什么不能用 `IOHIDDeviceSetValue`**：macOS 的 `IOHIDLibUserClient` 会对未跨层改变的元素值做本地缓存，不产生真实射频包。
- **同步 `GetReport + SetReport` 穿透**：通过调用 `IOHIDDeviceGetReport(Output, ID=1)` 同步读取当前 LED 字节 `cur_leds`（耗时等于真实 BLE RTT），紧接着调用 `IOHIDDeviceSetReport(Output, ID=1)` 翻转第 4 位 `Kana (0x10)` 并立即还原为 `cur_leds`：
  - 穿透内核缓存，强制 `bluetoothd` 向键盘句柄 `0x0022` 发送空中 `ATT_READ_REQ/RSP` 与 `ATT_WRITE_REQ/RSP`；
  - **完全无感**：键盘无物理 `Kana` 灯珠（**绝不闪灯**）、不注入任何按键事件、100% 保持原 `CapsLock` 状态；
  - **实测效果**：不仅将浅休眠 RTT 从 `642ms` 压回 `29ms`，而且 **100% 重置键盘固件的 150 秒深休眠断连计时器**。

### 2. 三级甜点休眠状态机（严格控制在 2 倍功耗预算内）

| 档位 | 判定条件（通过 `CoreGraphics` 实时检测键鼠与显示器状态） | 脉冲周期 | 作用 |
| :--- | :--- | :--- | :--- |
| **Tier 1：热态与鼠标预唤醒** (`TIER1_HOT`) | `key_idle < 15s` 或 **正在移动/点击/滚动鼠标 (`mouse_idle < 3s`)** | **3.5 秒**（鼠标微动 **0.25 秒内立即抢先触发**） | 手握鼠标移动时后台已完成键盘唤醒（RTT 压至 `~30ms`），手移到键盘按第一下零延迟 |
| **Tier 2：甜点保活态** (`TIER2_SWEET_SPOT`) | 人在电脑前阅读/思考，距离最后一次键鼠动作 **`< 20 分钟`** 且屏幕未休眠 | **35 秒**（卡在原厂 150 秒断连红线内） | 将原厂 **2.5 分钟断连** 延长至 **20 分钟甜点值**，在位期间 0 断连、绝不吞字 |
| **Tier 3：离座深休眠释放** (`DEEP_SLEEP_ALLOWED`) | 键鼠无操作 **`≥ 20 分钟`** 或 **锁屏 / 熄屏 / 合盖** | **完全停止发包** | 2.5 分钟后键盘自然进入原厂深休眠（`STATUS 719`），夜间与离座期间 **0 额外耗电** |

> **功耗预算核算**：该键盘原厂状态使用 328 天仅耗电 `32%`（日均 `0.097%/天`）。开启三级状态机后，按每天在 Mac 前工作 8 小时计，日均额外耗电约 `+0.085%/天`，总功耗约为原厂的 **1.85 倍**（完全在 2 倍预算内，剩余 `68%` 电量仍可续航约 1 年）。

### 3. 深睡眠零盲区闪连引擎（`cb_fast_reconnect.swift` + `bluetoothd` 内核参数）
- **用户态自动重挂 `LeConnectionScanHigh`**：`cb_fast_reconnect` 监听 `Mi PTKB` 连接状态。一旦键盘进入深睡眠断开，只要 Mac 屏幕亮着，每隔 **5.2 秒**（赶在 6.0 秒超时前）刷新一次 `CBCentralManager.connect(peripheral)`，强制 Mac 蓝牙控制器保持 **100% 占空比全速监听（`30ms/30ms`，0ms 盲区）**。因仅使用 Mac 侧接收机，**对睡眠中的键盘 0 耗电**。
- **系统级隐藏参数覆盖（`enable_bt_fastscan_system.sh`）**：基于对 `/usr/sbin/bluetoothd`（地址 `0x10076b10c`、`0x1007a35f0`、`0x1003d27d4`）的反汇编，提供一键写入 `/Library/Preferences/com.apple.MobileBluetooth.debug.plist` 的脚本，将 `ConnScanTimeoutExtendPercent` 设为 `60000`（6 秒全速扫描延长 600 倍至 1 小时），并将常规连接扫描占空比从 `10%` 提升至 `50%`。

---

## 三、 45 分钟连续实测日志

以下为部署后在真实办公场景下连续运行 45 分钟的实测日志（`/tmp/mi-ptkb-keepalive.log`）：

```text
[mi-ptkb-keepalive] smart daemon started: sweet_spot=20m, hot_interval=3.5s, warm_interval=35.0s
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=51.3s, mouse_idle=0.8s, rtt=642.9ms->32.9ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=153.3s, mouse_idle=34.8s, rtt=294.4ms->30.0ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=198.1s, mouse_idle=0.1s, rtt=178.2ms->30.1ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=75.0s, mouse_idle=36.5s, rtt=261.2ms->30.1ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=194.7s, mouse_idle=0.7s, rtt=158.3ms->30.2ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=69.7s, mouse_idle=37.2s, rtt=87.9ms->31.1ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=77.0s, mouse_idle=0.5s, rtt=23.9ms->30.3ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=145.6s, mouse_idle=38.1s, rtt=275.4ms->28.0ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=361.6s, mouse_idle=0.6s, rtt=248.9ms->30.5ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=463.7s, mouse_idle=37.7s, rtt=219.9ms->29.8ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=562.6s, mouse_idle=0.6s, rtt=129.4ms->29.9ms)
[mi-ptkb-keepalive] -> TIER2_SWEET_SPOT (interval=35.0s, key_idle=72.0s, mouse_idle=37.0s, rtt=23.4ms->30.0ms)
[mi-ptkb-keepalive] -> TIER1_HOT (interval=3.5s, key_idle=91.7s, mouse_idle=0.7s, rtt=328.3ms->29.8ms)
[cb-fast-reconnect] bound to Mi PTKB (63F7CCA4-...), initial state=0
[cb-fast-reconnect] Mi PTKB connected! Triggering immediate GATT read to wake link
[cb-fast-reconnect] GATT battery read complete: 68%
```

- 在 `key_idle=562.6s`（长达 **9 分 22 秒** 未按键盘，接近原厂 150 秒断连阈值的 4 倍）时，键盘依然 **100% 保持连接未断开**；
- 在鼠标微动（`mouse_idle=0.6s`）瞬间，守护进程立即将键盘从浅休眠唤醒，空中 RTT 从 `642.9ms / 328.3ms / 248.9ms` 稳定压回 **`29.8ms ~ 32.9ms`**。

---

## 四、 文件结构与安装使用

```text
mi-ptkb-keepalive/
├── keepalive.py                  # 三级甜点休眠状态机与鼠标联动预唤醒守护进程
├── cb_fast_reconnect.swift       # CoreBluetooth 深睡眠 100% 占空比零盲区闪连引擎源码
├── install_launchagent.sh        # 一键编译、部署并启动双引擎服务
├── uninstall_launchagent.sh      # 一键停止并彻底卸载全部服务
├── enable_bt_fastscan_system.sh  # (可选) 写入 bluetoothd 隐藏高速重连扫描参数 (需 sudo)
└── README.md
```

### 1. 一键安装与启动
```bash
./install_launchagent.sh
```

### 2. （可选）开启 macOS `bluetoothd` 系统级高速扫描覆盖
```bash
./enable_bt_fastscan_system.sh
```

### 3. 单次脉冲测试与延迟诊断
```bash
./keepalive.py --once
```

### 4. 自定义甜点睡眠时长
编辑 `install_launchagent.sh` 中的参数即可调整：
- `--sweet-spot-minutes 20`：甜点保活时长（默认 `20` 分钟）
- `--hot-interval 3.5`：键鼠活跃期脉冲间隔（默认 `3.5` 秒）
- `--warm-interval 35`：阅读/静置期保活脉冲间隔（默认 `35` 秒）

### 5. 卸载服务
```bash
./uninstall_launchagent.sh
```
