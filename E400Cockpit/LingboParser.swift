import Foundation

/// 凌博控制器协议（帧格式移植自开源逆向基线 Motexa 2.7.0 / esp32BMSGPS）
/// 帧结构: AA | 55 | LEN | CMD | 数据(LEN-1字节) | SUM8   总长 = LEN + 3
/// SUM8 = 前 N-1 字节算术和的低 8 位
enum Lingbo {
    /// 读标定参数（握手，必须先拿到换算分母）
    static let calibrationRequest: [UInt8] = [0xAA, 0x55, 0x02, 0x20, 0x21]
    /// 读实时数据
    static let realtimeRequest: [UInt8] = [0xAA, 0x55, 0x02, 0x22, 0x23]
    /// 读实时数据——「长帧」变体：把 LEN 从 0x02 抬到 0x1A，
    /// 等价于告诉控制器「我要 29 字节那份完整数据」。
    /// 部分固件会据此返回带转把 / 挡位的长帧，部分固件直接不理——
    /// 所以它是个可开关的实验项，3 秒收不到实时帧就自动回退。
    static let realtimeRequestLong: [UInt8] = [0xAA, 0x55, 0x1A, 0x22, 0x3B]
}

final class LingboParser {

    struct Calibration {
        var calibrated = false
        var phaseCurrentBase: UInt16 = 0
        var phaseVoltageBase: UInt16 = 0
        var busCurrentDiv: UInt16 = 0
        var busVoltageDiv: UInt16 = 0
        var controlMode: UInt8 = 0
        var torqueMax: UInt16 = 0
    }

    struct Telemetry {
        var date = Date.distantPast
        var rpm = 0
        var phaseCurrentInferred = 0.0
        var busVoltage = 0.0
        var busCurrent = 0.0
        var powerW = 0.0
        var controllerTemp: Double?
        var motorTemp: Double?
        var throttleVolts: Double?
        var throttlePercent: Double?
        var gear: Int?
        var fault: UInt32 = 0
        var raw: [UInt8] = []
    }

    /// 字段偏移覆盖。
    ///
    /// 标准 29 字节实时帧里：转把电压在 @22（u16，0.01V）、挡位在 @27（低 4 位）。
    /// 但不同固件会裁掉尾部字段——E400Max-CAN 实际只回 23～24 字节，
    /// 于是这两个字段落在了帧外。这里留出手动覆盖口子，配合「数据台」的
    /// 逐字节视图，可以按真实固件对齐偏移，而不是靠猜。
    struct Layout {
        /// nil = 自动（标准 @22）
        var throttleOffset: Int?
        /// nil = 自动（标准 @27）
        var gearOffset: Int?
        /// 短帧（25…28 字节）时是否把 @24 状态标志的低 4 位当挡位
        var shortFrameGearFallback = false
    }

    /// 实际取用的字段位置，供数据台显示「这格数据是从第几字节读的」
    struct FieldTrace {
        var throttleOffset: Int?
        var gearOffset: Int?
        var gearFallback = false
    }

    private(set) var calibration = Calibration()
    /// 最近一帧的完整长度（含帧头与校验），用于诊断字段偏移
    private(set) var lastFrameLength = 0
    /// 最近一帧实时帧（0x62）的原始字节，供数据台逐字节查看
    private(set) var lastRealtimeFrame: [UInt8] = []
    /// 最近一次解析用了哪些偏移
    private(set) var trace = FieldTrace()
    var layout = Layout()
    /// 实时请求是否用「长帧」变体（实验项，见 Lingbo.realtimeRequestLong）
    private(set) var useLongRequest = false

    private var stream: [UInt8] = []
    private static let capacity = 512

    func reset() {
        calibration = Calibration()
        stream.removeAll()
        lastFrameLength = 0
        lastRealtimeFrame = []
        trace = FieldTrace()
    }

    /// 从设置页读取偏移覆盖（每次轮询调用，改设置即时生效）
    func applyLayoutFromDefaults() {
        let d = UserDefaults.standard
        let t = d.object(forKey: "throttle_offset") as? Int ?? -1
        let g = d.object(forKey: "gear_offset") as? Int ?? -1
        layout.throttleOffset = (t >= 0 && t <= 40) ? t : nil
        layout.gearOffset = (g >= 0 && g <= 40) ? g : nil
        layout.shortFrameGearFallback = d.bool(forKey: "gear_short_fallback")
        useLongRequest = d.bool(forKey: "long_realtime_request")
    }

    /// 外部（自动回退逻辑）关掉长帧请求
    func disableLongRequest() {
        useLongRequest = false
        UserDefaults.standard.set(false, forKey: "long_realtime_request")
    }

    /// 喂入 BLE 收到的字节块，返回本块中最后一帧有效实时数据（若有）
    func feed(_ chunk: [UInt8]) -> Telemetry? {
        guard !chunk.isEmpty else { return nil }
        stream.append(contentsOf: chunk)
        if stream.count > LingboParser.capacity {
            stream.removeFirst(stream.count - LingboParser.capacity)
        }
        var result: Telemetry?
        var idx = 0
        while stream.count - idx >= 5 {
            if stream[idx] != 0xAA || stream[idx + 1] != 0x55 {
                idx += 1
                continue
            }
            let declared = Int(stream[idx + 2])
            let frameLen = declared + 3
            if declared < 2 || frameLen > 160 {
                idx += 1
                continue
            }
            if stream.count - idx < frameLen { break }
            let frame = Array(stream[idx..<(idx + frameLen)])
            lastFrameLength = frameLen
            let sum = frame.dropLast().reduce(UInt32(0)) { $0 &+ UInt32($1) }
            if UInt8(truncatingIfNeeded: sum) != frame[frameLen - 1] {
                idx += 1
                continue
            }
            switch frame[3] {
            case 0x60:
                applyCalibration(frame)
            case 0x62:
                if calibration.calibrated, frame.count >= 23 {
                    result = parseRealtime(frame)
                }
            default:
                break
            }
            idx += frameLen
        }
        if idx > 0 { stream.removeFirst(idx) }
        return result
    }

    /// 0x60 标定帧: @4 相电流基准 @6 相电压基准 @8 母线电流分母 @10 母线电压分母 @12 控制模式 @13 扭矩上限
    private func applyCalibration(_ f: [UInt8]) {
        guard f.count >= 16 else { return }
        let divI = u16le(f, 8)
        let divV = u16le(f, 10)
        guard divI > 0, divV > 0 else {
            calibration.calibrated = false
            return
        }
        calibration.phaseCurrentBase = u16le(f, 4)
        calibration.phaseVoltageBase = u16le(f, 6)
        calibration.busCurrentDiv = divI
        calibration.busVoltageDiv = divV
        calibration.controlMode = f[12]
        calibration.torqueMax = u16le(f, 13)
        calibration.calibrated = true
    }

    /// 0x62 实时帧: @4 转速(有符号) @6 相电流²(推断) @10 母线电压原始值 @12 母线电流原始值(有符号)
    /// @14 控制器温度 @16 电机温度(推断) @18 32位故障位图 @22 转把电压(0.01V) @24 状态标志 @27 挡位
    private func parseRealtime(_ f: [UInt8]) -> Telemetry {
        var t = Telemetry()
        t.date = Date()
        t.raw = f
        lastRealtimeFrame = f
        trace = FieldTrace()

        let rawRpm = i16le(f, 4)
        t.rpm = abs(Int(rawRpm))

        let phaseRaw = u16le(f, 6)
        if phaseRaw > 0 { t.phaseCurrentInferred = Double(phaseRaw).squareRoot() }

        let divV = Double(calibration.busVoltageDiv)
        let divI = Double(calibration.busCurrentDiv)
        t.busVoltage = Double(u16le(f, 10)) / divV
        let rawCurrent = Double(i16le(f, 12))
        t.busCurrent = rawCurrent / divI
        t.powerW = t.busVoltage * t.busCurrent

        let tc = Int(i16le(f, 14))
        t.controllerTemp = (tc >= -60 && tc <= 200) ? Double(tc) : nil
        let tm = Int(i16le(f, 16))
        t.motorTemp = (tm >= -60 && tm <= 200) ? Double(tm) : nil

        t.fault = u32le(f, 18)

        // 转把：默认 @22（u16，需帧长 ≥ 24）；手动指定偏移时优先用指定的
        let tOff = layout.throttleOffset ?? 22
        if f.count >= tOff + 2 {
            let volts = Double(u16le(f, tOff)) * 0.01
            if volts >= 0 && volts <= 4.95 {
                t.throttleVolts = volts
                let pct = (volts - 0.85) / (4.2 - 0.85) * 100.0
                t.throttlePercent = min(100.0, max(0.0, pct))
                trace.throttleOffset = tOff
            }
        }

        // 挡位：三种来源，优先级 手动偏移 > 标准 @27 > 短帧回退 @24
        if let go = layout.gearOffset, f.count > go {
            t.gear = Int(f[go] & 0x0F)
            trace.gearOffset = go
        } else if f.count >= 29 {
            t.gear = Int(f[27] & 0x0F)
            trace.gearOffset = 27
        } else if layout.shortFrameGearFallback, f.count >= 25 {
            t.gear = Int(f[24] & 0x0F)
            trace.gearOffset = 24
            trace.gearFallback = true
        }
        return t
    }

    private func u16le(_ f: [UInt8], _ o: Int) -> UInt16 {
        UInt16(f[o]) | (UInt16(f[o + 1]) << 8)
    }
    private func i16le(_ f: [UInt8], _ o: Int) -> Int16 {
        Int16(bitPattern: u16le(f, o))
    }
    private func u32le(_ f: [UInt8], _ o: Int) -> UInt32 {
        UInt32(f[o]) | (UInt32(f[o + 1]) << 8) | (UInt32(f[o + 2]) << 16) | (UInt32(f[o + 3]) << 24)
    }
}
