# E400Cockpit

凌博 E400 控制器蓝牙直连仪表 App（九号 E80c MK2）。

- **协议**：凌博 UART 透传帧 `AA 55 LEN CMD data SUM8`，BLE 服务 FFF0（写 FFF2 / 通知 FFF1），500ms 轮询
- **握手**：`AA 55 02 20 21` 读标定（换算分母）→ `AA 55 02 22 23` 读实时（rpm / 母线电压电流 / 双温度 / 故障 / 转把 / 挡位）
- **车速**：由 rpm × 轮周长换算，轮周长在 App 设置页按实测填写
- **构建**：xcodegen 生成工程，GitHub Actions（macOS）编译 unsigned → ad-hoc 签名 → IPA Release

协议参考：开源逆向基线（Motexa 2.7.0 APK 反编译）移植。
