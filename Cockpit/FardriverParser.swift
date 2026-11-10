import Foundation

/// 南京远驱（Fardriver / VOTOL 系）控制器协议。
///
/// 和凌博完全不同的玩法：**不用发请求帧**，模块连上就自己往通知通道推。
/// 帧结构（参考 ESP32-Fardriver-BLE-Reader 实测，固定 16 字节）：
///
///     AA | id(低 6 位) + flags(高 2 位) | 12 字节数据 | CRC16(低 高)
///
/// - CRC16：poly 0xA001、**初值 0x7F3C**、范围前 14 字节（Modbus 同族，但初值不同，
///   所以凌博那套 0xFFFF 的校验在这里一律不过——这也是首帧嗅探能安全区分两者的原因）
/// - id 查 `addressTable` 得到 flash 地址，真正有用的只有四个：
///   0xE2 转速/档位、0xE8 电压/电流、0xD6 控制器温度、0xF4 电机温度 + SOC
/// - 电压 = u16/10（0…100 V 范围内才采纳）、电流 = i16/4（负值 = 回充）
///
/// 转速换算：`rpm = rawRpm × 4 ÷ 极对数`，极对数默认 20，可在设置里改。
/// 车速沿用全局那条公式（rpm × 周长 × 60 ÷ 1e6），所以这里只交「已换算的 rpm」，
/// 里程/轮速那一套完全复用，不另起一套。
final class FardriverParser: ControllerDriver {

    // MARK: 常量

    /// id(0…55) → flash 地址。只用来查表，值本身不参与换算。
    private static let addressTable: [UInt8] = [
        0xE2, 0xE8, 0xEE, 0xE4, 0x06, 0x0C, 0x12, 0xE2, 0xE8, 0xEE, 0x18, 0x1E, 0x24, 0x2A,
        0xE2, 0xE8, 0xEE, 0x30, 0x5D, 0x63, 0x69, 0xE2, 0xE8, 0xEE, 0x7C, 0x82, 0x88, 0x8E,
        0xE2, 0xE8, 0xEE, 0x94, 0x9A, 0xA0, 0xA6, 0xE2, 0xE8, 0xEE, 0xAC, 0xB2, 0xB8, 0xBE,
        0xE2, 0xE8, 0xEE, 0xC4, 0xCA, 0xD0, 0xE2, 0xE8, 0xEE, 0xD6, 0xDC, 0xF4, 0xFA
    ]

    private static let crcSeed: UInt16 = 0x7F3C
    private static let frameLength = 16

    // MARK: 状态（协议是「一个地址一帧」，所以要自己攒）

    private var voltage = 0.0
    private var current = 0.0
    private var rawRpm = 0
    private var gear = 0
    private var controllerTemp = 0
    private var motorTemp = 0
    private var soc = 0
    private var hasFrame = false
    private var lastFrame: [UInt8] = []

    /// 极对数 / 轮周长：给用户留的口子，默认值取参考实现
    private var polePairs: Int {
        let v = UserDefaults.standard.integer(forKey: "fardriver_pole_pairs")
        return v > 0 ? v : 20
    }

    // MARK: ControllerDriver

    var displayName: String { "远驱 Fardriver（AA…16B）" }

    var isCalibrated: Bool { hasFrame }

    var calibrationSummary: String? {
        hasFrame ? "远驱直读，无需标定（\(polePairs) 极对）" : nil
    }

    /// 扫描列表靠这个前缀把远驱排前面
    var nameHint: String { "VOTOL" }

    var lastFrameLength: Int { lastFrame.isEmpty ? 0 : lastFrame.count }

    var lastRealtimeFrame: [UInt8] { lastFrame }

    /// 远驱没有配置帧概念
    var lastConfigFrame: [UInt8] { [] }

    /// 字段位置不在固定偏移上（按地址分帧），数据台的偏移列留空
    var trace: LingboParser.FieldTrace { LingboParser.FieldTrace() }

    func reset() {
        voltage = 0
        current = 0
        rawRpm = 0
        gear = 0
        controllerTemp = 0
        motorTemp = 0
        soc = 0
        hasFrame = false
        lastFrame = []
    }

    /// 极对数是实时从 defaults 读的，这里不用做事（接口要求留着）
    func applyLayoutFromDefaults() {}

    /// 远驱没有「长帧请求」这种实验开关
    func disableLongRequest() {}

    /// 远驱**不主动发请求**：订阅上就等它自己推。返回空数组，
    /// 传输层见到空帧会直接跳过写入（写通道可能根本不存在）。
    func nextRequestFrame() -> [UInt8] { [] }

    func feed(_ bytes: [UInt8]) -> LingboParser.Telemetry? {
        guard FardriverParser.looksLike(bytes),
              let address = FardriverParser.address(of: bytes) else { return nil }

        let d = Array(bytes[2..<14])          // 12 字节数据域
        lastFrame = bytes
        hasFrame = true

        switch address {
        case 0xE2:
            gear = Int((d[0] >> 2) & 0b11) + 1
            rawRpm = Int(Int16(bitPattern: UInt16(d[7]) << 8 | UInt16(d[6])))
        case 0xE8:
            let v = Double(UInt16(d[1]) << 8 | UInt16(d[0])) / 10.0
            if v >= 0, v <= 100 { voltage = v }
            let a = Double(Int16(bitPattern: UInt16(d[5]) << 8 | UInt16(d[4]))) / 4.0
            if a >= -100, a <= 300 { current = a }
        case 0xD6:
            let temp = Int(Int16(bitPattern: UInt16(d[11]) << 8 | UInt16(d[10])))
            if temp > -20, temp < 100 { controllerTemp = temp }
        case 0xF4:
            let temp = Int(Int16(bitPattern: UInt16(d[1]) << 8 | UInt16(d[0])))
            if temp > -20, temp < 200 { motorTemp = temp }
            soc = Int(d[3])
        default:
            return nil
        }

        // 轮上转速（÷极对数），车速那条公式在 publish() 里统一算
        let rpm = max(0, rawRpm) * 4 / max(polePairs, 1)

        var t = LingboParser.Telemetry()
        t.date = Date()
        t.rpm = rpm
        t.busVoltage = voltage
        t.busCurrent = current
        t.powerW = voltage * current
        t.controllerTemp = controllerTemp > -20 && controllerTemp < 100 ? Double(controllerTemp) : nil
        t.motorTemp = motorTemp > -20 && motorTemp < 200 ? Double(motorTemp) : nil
        t.gear = gear > 0 ? gear : nil
        t.raw = bytes
        return t
    }

    // MARK: 首帧嗅探

    /// 是不是一帧远驱数据。三个条件同时成立才算：
    /// 16 字节 + 0xAA 开头 + 初值 0x7F3C 的 CRC 对得上。
    /// 凌博的 AA55 帧长度是 23/29，且校验初值不同，几乎不可能同时满足。
    static func looksLike(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == frameLength, bytes[0] == 0xAA else { return false }
        guard let _ = address(of: bytes) else { return false }
        return true
    }

    /// 查表拿地址；id 越界或 CRC 不对返回 nil
    private static func address(of bytes: [UInt8]) -> UInt8? {
        guard bytes.count == frameLength, bytes[0] == 0xAA else { return nil }
        let id = Int(bytes[1] & 0x3F)
        guard id < addressTable.count else { return nil }
        let computed = crc16(bytes)
        let remote = UInt16(bytes[15]) << 8 | UInt16(bytes[14])
        guard computed == remote else { return nil }
        return addressTable[id]
    }

    private static func crc16(_ frame: [UInt8]) -> UInt16 {
        var crc = crcSeed
        for i in 0..<14 {
            crc ^= UInt16(frame[i])
            for _ in 0..<8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xA001 : crc >> 1
            }
        }
        return crc
    }
}
