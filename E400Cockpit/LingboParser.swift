import Foundation

/// 凌博控制器协议（帧格式移植自开源逆向基线 Motexa 2.7.0 / esp32BMSGPS）
/// 帧结构: AA | 55 | LEN | CMD | 数据(LEN-1字节) | SUM8   总长 = LEN + 3
/// SUM8 = 前 N-1 字节算术和的低 8 位
enum Lingbo {
    /// 读标定参数（握手，必须先拿到换算分母）
    static let calibrationRequest: [UInt8] = [0xAA, 0x55, 0x02, 0x20, 0x21]
    /// 读实时数据
    static let realtimeRequest: [UInt8] = [0xAA, 0x55, 0x02, 0x22, 0x23]
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

    private(set) var calibration = Calibration()
    private var stream: [UInt8] = []
    private static let capacity = 512

    func reset() {
        calibration = Calibration()
        stream.removeAll()
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
    /// @14 控制器温度 @16 电机温度(推断) @18 32位故障位图 @22 转把电压(0.01V) @27 挡位
    private func parseRealtime(_ f: [UInt8]) -> Telemetry {
        var t = Telemetry()
        t.date = Date()
        t.raw = f

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

        if f.count >= 25 {
            let volts = Double(u16le(f, 22)) * 0.01
            if volts >= 0 && volts <= 4.95 {
                t.throttleVolts = volts
                let pct = (volts - 0.85) / (4.2 - 0.85) * 100.0
                t.throttlePercent = min(100.0, max(0.0, pct))
            }
        }
        if f.count >= 29 {
            t.gear = Int(f[27] & 0x0F)
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
