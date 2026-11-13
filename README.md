# Cockpit

凌博 E400 控制器蓝牙直连仪表 App（九号 E80c MK2），现同样支持远驱（Fardriver / VOTOL / YuanQuFOC）。

- **凌博协议**：UART 透传帧 `AA 55 LEN CMD data SUM8`，BLE 服务 FFF0（写 FFF2 / 通知 FFF1），500ms 轮询
- **握手**：`AA 55 02 20 21` 读标定（换算分母）→ `AA 55 02 22 23` 读实时（rpm / 母线电压电流 / 双温度 / 故障 / 转把 / 挡位）
- **远驱协议**：FFE0 / FFEC 纯通知（不发请求），固定 16 字节帧 `AA | id | 12B 数据 | CRC16`（poly 0xA001，初值 0x7F3C）
- **构建**：xcodegen 生成工程，GitHub Actions（macOS）编译 unsigned → ad-hoc 签名 → IPA Release

## 支持范围（能连谁）

内置蓝牙只是物理层，"能不能用"取决于协议。当前状态：

| 控制器 | 能否使用 | 说明 |
|---|---|---|
| 凌博全系（LBMC + FFF0/FFF1/FFF2 + AA55） | **直接可用** | 电压/电流换算分母是运行时从 `0x60` 帧读的，不写死，所以 E300/E400 各电压平台都通用 |
| 远驱 Fardriver / VOTOL（含广播名 `YuanQuFOC…` 的机器） | **直接可用** | FFE0/FFEC 只订阅不发请求；电压/电流/双温度/SOC/档位直读，转速按极对数换算（默认 20，可用「转速校准」微调） |
| 其他走 FFF0 / FFE0 / Nordic UART 透传的设备 | **能连、能看字节** | GATT 自动探测可配对通道，原始帧在「数据台」可见；要显示数值必须新增一个协议驱动 |
| 私有或加密协议（九号原厂中控、小牛、博世等） | 通常不行 | 能建立 BLE 连接，但请求无有效应答 |

### 三层结构（换品牌只动最上面一层）

```
传输层  CockpitCentral      FFF0 优先；未命中则全量枚举服务，自动配对 notify+write
驱动层  ControllerDriver    协议接口。LingboParser（凌博 AA55）、FardriverParser（远驱 16B AA 帧）已实现
应用层  Dashboard/Console/Settings   与品牌无关，只消费 Telemetry
```

加一个新品牌 = 新建一个 `XxxDriver.swift` 实现 `ControllerDriver`（五个成员：`displayName` / `isCalibrated` / `calibrationSummary` / `nextRequestFrame()` / `feed()`），再把 `ControllerDrivers.makeDefault()` 换成它。蓝牙层和三个页面一行都不用改。

连上后驱动按**首帧嗅探**自动选择：16 字节 + `0xAA` + `0x7F3C` 校验通过判远驱，`AA 55` 长帧标定成功判凌博；一边标定成功就锁死，不会误切。

调试未知控制器时：扫描列表默认显示全部蓝牙设备（认得出的控制器排前面）→ 连接 → 看「数据台」里的服务/特征清单与十六进制流，照真实帧写驱动。

## 车速标定：轮胎受压模型

不用手量周长也能算准。填轮胎规格、胎压、车重、人重，App 自己估下沉量：

```
自由外径   D₀ = 轮辋(inch)×25.4 + 2×(胎宽 × 扁平比)
静态下沉   δ  = δ₀ × (实际轴荷 / 单胎额定载荷)^0.70 × (2.2bar / 实际胎压)^0.45
滚动半径   R_roll = D₀/2 − 0.62 × δ
车速       v = rpm × (2π·R_roll) × 60 ÷ 1,000,000   [km/h]
```

要点：

- **载荷不是纯气压承担的**。只用 `F = p·A` 算接地印痕会把下沉量低估 5 倍（算出 2mm，实际 10mm），因为胎体和胎侧刚度扛了一大半载荷。所以模型对标**载重指数**（90/90-12 44J → 单胎 160kg 额定）而不是压强。
- **速度用滚动半径，不是静态半径**。滚动时前缘压缩、后缘恢复，实际吃掉的半径约为静态下沉的 62%。
- **轴荷要分配**。踏板车电池电机偏后，后轮默认 58%，可在设置里 40–75% 调。

标定值（90/90-12 44J，总质量 175kg，后轴 58%，2.2bar）：

| 项 | 值 |
|---|---|
| 自由外径 | 467 mm |
| 自由周长 | 1466 mm |
| 静态下沉 | 10.4 mm |
| 滚动周长 | **1426 mm** |
| 相对自由周长 | −2.8% |

也就是说：若直接拿自由周长 1466mm 当滚动周长，表显速度会**虚高 2.8%**（1000rpm 时差 2.4 km/h）。带人后轴荷升到 129kg 时周长缩到 1419mm，还会再差 0.5%。

模型误差约 ±2%；想要更高精度走滚动法实测并在设置里勾选「用实测周长覆盖」，或在装车后用 GPS 匀速段核对一次。模型的价值在于**参数一变周长自动跟着变**（换胎、加人、改胎压都不用重新量）。

## 构建

本地：装 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 后 `xcodegen generate`，再用 Xcode 打开 `Cockpit.xcodeproj`。
云端：push 即触发 `.github/workflows/build.yml`（`runs-on: macos-15`，macos-14 免费额度不支持），产物自动发到 Release。

IPA 为 ad-hoc 签名，越狱机经 TrollStore / AppSync / Sideloadly 安装。

协议参考：凌博协议基线来自开源逆向（Motexa 2.7.0 APK 反编译），远驱协议参考公开的 ESP32-Fardriver-BLE-Reader 实现。

## License

[MIT](LICENSE)
