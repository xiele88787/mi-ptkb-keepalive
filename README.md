# mi-ptkb-keepalive

**小米便携双模键盘（Mi PTKB / XMBXJP01YM）macOS 蓝牙休眠根治与鼠标联动预唤醒守护服务**

针对小米便携双模键盘（蓝牙名称 `Mi PTKB`，`VendorID = 0x2717`，`ProductID = 0x507C`）在 macOS 蓝牙（BLE）模式下“休眠极快、唤醒极慢、吞首字、停手几秒再打字明显粘滞”的顽疾，通过逆向分析 macOS `/usr/sbin/bluetoothd` 与键盘 HID 报告描述符，并经过连续 7 小时真实办公压测迭代，提供一套在 **2 倍电池功耗预算内** 稳定运行的根治方案：

1. **智能三级甜点保活与鼠标联动预唤醒（`keepalive.py`）**：将原厂锁死的 **2 分 38 秒（150 秒）深休眠断连** 精准延长至 **20 分钟甜点值**（可调）：在键鼠活跃期以 `3.5s` 周期、阅读静置期以 `8.0s` 周期下发无感虚拟 LED 同步 GATT 脉冲，实现在位期间 **连续数小时 0 断连**，并在鼠标滑动微动 `< 0.25s` 内将键盘从浅休眠拉回 `~29ms` 满血态；人离开座位超 20 分钟或锁屏/熄屏后立即停止发包，释放键盘进入原厂深休眠（离座 0 额外功耗）。
2. **系统级 `bluetoothd` 高速重连扫描覆盖（`enable_bt_fastscan_system.sh`）**：通过逆向 `/usr/sbin/bluetoothd`（地址 `0x10076b10c`、`0x1007a35f0`、`0x1003d27d4`），配置 `/Library/Preferences/com.apple.MobileBluetooth.debug.plist` 下的 `LE` 字典，在不干扰 `BTLEServer` 原生 SMP 加密握手（`LinkReady ~355ms`）的前提下延长高速扫描窗口。

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
- **深休眠（2 分 38 秒触发）**：`bluetoothd` 日志实测显示，最后一次交互后仅 **158 ~ 165 秒**，键盘即主动发起 `STATUS 719 (0x13 Remote User Terminated Connection)` 彻底断开 BLE 链路并关闭射频，且唤醒那一下按键仅作 GPIO 中断唤醒 MCU，不做离线缓存（必吞首字）。

---

## 二、 核心技术方案与 7 小时压测调优结论

### 1. 穿透 IOKit 缓存的无感虚拟 LED 同步空中脉冲
解析 `Mi PTKB` 的原始 `ReportDescriptor`：

```text
05 01 09 06 a1 01 85 01 ... 95 05 75 01 05 08 19 01 29 05 91 02 ...
```

虽然这把 85 键紧凑键盘物理上只有 `CapsLock` 一颗状态灯，但固件在 `ReportID = 1` 的 Output Report（`UsagePage = 0x08`）中声明了完整的 5 个 LED 位（`1=NumLock, 2=CapsLock, 3=ScrollLock, 4=Compose, 5=Kana`）。

- 通过调用 `IOHIDDeviceGetReport(Output, ID=1)` 同步读取当前 LED 字节 `cur_leds`，紧接着调用 `IOHIDDeviceSetReport(Output, ID=1)` 翻转第 4 位 `Kana (0x10)` 并立即还原为 `cur_leds`：
  - 穿透 `IOHIDLibUserClient` 缓存，强制 `bluetoothd` 向键盘句柄 `0x0022` 发送空中 `ATT_READ_REQ/RSP` 与 `ATT_WRITE_REQ/RSP`；
  - **完全无感**：键盘无物理 `Kana` 灯珠（**绝不闪灯**）、不注入任何按键事件、100% 保持原 `CapsLock` 状态。

### 2. 关键压测发现：为什么 `warm_interval` 必须设为 `<= 8.0s` 且严禁用户态调用 `cancelPeripheralConnection`？

在 12:38 至 19:34 连续 7 小时的真实压测中，通过对比 `bluetoothd` 日志发现了两条关键工程规律：

1. **脉冲周期阈值（`8.0s` vs `35.0s`）**：
   - 当脉冲周期 `<= 8.0s` 时，键盘始终不会跨入深度跳帧状态机，实测连续保持连接 **1 小时 51 分钟（12:38 -> 14:30）**、**1 小时 29 分钟（17:22 -> 18:51）** 零断连；
   - 而当静置脉冲周期放宽到 `35.0s` 时（例如 `19:21:11` 鼠标停手切入 `35s` 档位），`35s` 的空隙足以让固件跨入深休眠倒计时，并在 **2 分 45 秒（`19:23:57`）** 后触发 `STATUS 719` 断连。因此将 `TIER2_SWEET_SPOT` 周期收紧至 **`8.0s`** 即可在 20 分钟甜点期内 100% 锁死连接不断开。
2. **严禁在用户态对 HID 设备调用 `cancelPeripheralConnection`**：
   - 当键盘从深休眠唤醒并建立物理连接（`BLE Connection Completed`）到完成 SMP 加密与 GATT 初始化（`LinkReady`）期间，CoreBluetooth 的 `peripheral.state` 仍处于 `.connecting` 而非 `.connected`；
   - 原生 `BTLEServer` 单独处理时，`LinkReady` 仅需 **`355ms ~ 760ms`**（如 `14:32:26 LinkReady took 355ms`）；若第三方进程在此窗口内发起 `CBMsgIdCancelPeripheralConnection` 重置连接，会直接打断 SMP 加密握手并将 `AutoReconnectEnabled` 置 `0`，导致 `LinkReady` 恶化至 **`4446ms ~ 5319ms`**。移除该冲突后，`LinkReady` 立即恢复至毫秒级。

### 3. 三级甜点休眠状态机（`keepalive.py`）

| 档位 | 判定条件（通过 `CoreGraphics` 实时检测键鼠与显示器状态） | 脉冲周期 | 作用 |
| :--- | :--- | :--- | :--- |
| **Tier 1：热态与鼠标预唤醒** (`TIER1_HOT`) | `key_idle < 15s` 或 **正在移动/点击/滚动鼠标 (`mouse_idle < 3s`)** | **3.5 秒**（鼠标微动 **0.25 秒内立即抢先触发**） | 手握鼠标移动时后台已完成键盘唤醒（RTT 压至 `~30ms`），手移到键盘按第一下零延迟 |
| **Tier 2：甜点保活态** (`TIER2_SWEET_SPOT`) | 人在电脑前阅读/思考，距离最后一次键鼠动作 **`< 20 分钟`** 且屏幕未休眠 | **8.0 秒**（彻底阻止固件进入睡眠倒计时） | 将原厂 **2.5 分钟断连** 稳定延长至 **20 分钟甜点值**，在位期间 100% 零断连、绝不吞字 |
| **Tier 3：离座深休眠释放** (`DEEP_SLEEP_ALLOWED`) | 键鼠无操作 **`≥ 20 分钟`** 或 **锁屏 / 熄屏 / 合盖** | **完全停止发包** | 2.5 分钟后键盘自然进入原厂深休眠（`STATUS 719`），夜间与离座期间 **0 额外耗电** |

---

## 三、 文件结构与安装使用

```text
mi-ptkb-keepalive/
├── keepalive.py                  # 三级甜点休眠状态机与鼠标联动预唤醒守护进程 (hot=3.5s, warm=8.0s)
├── install_launchagent.sh        # 一键部署并启动后台保活服务
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
