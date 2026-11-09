import Foundation

/// 蚂蚁 BMS（ANT BMS）协议
///
/// 帧结构：7E A1 | 功能码 | 地址(2) | 数据长度(1) | 数据域 | CRC16(2, 小端) | AA 55
/// 总长 = 6 + 数据长度 + 4；CRC16 = Modbus（poly 0xA001，初值 0xFFFF），
/// 校验范围 = 帧内 [1 .. len-5]。
///
/// 状态请求帧固定为 `7E A1 01 00 00 BE 18 55 AA 55`，
/// 应答功能码 0x11，数据域按「单体数 / 温度数」动态偏移，全部小端。
final class AntBmsParser {

    enum Function {
        static let status: UInt8 = 0x11
    }

    /// 读一次状态
    static let statusRequest: [UInt8] = [0x7E, 0xA1, 0x01, 0x00, 0x00, 0xBE, 0x18, 0x55, 0xAA, 0x55]

    struct Telemetry {
        var date = Date()
        var cellCount = 0
        var cellVoltages: [Double] = []      // V
        var temps: [Int] = []                // 电芯温度 ℃
        var mosTemp = 0
        var balancerTemp = 0
        var packVoltage = 0.0                // V
        var current = 0.0                    // A，正=充电 负=放电
        var soc = 0                          // %
        var soh = 0                          // %
        var capacityAh = 0.0                 // 额定容量
        var remainingAh = 0.0                // 剩余容量
        var cycles = 0.0                     // 循环容量 Ah
        var power = 0.0                      // W
        var maxCellV = 0.0
        var minCellV = 0.0
        var deltaV = 0.0                     // 压差 V
        var avgCellV = 0.0
        var maxCellIndex = 0
        var minCellIndex = 0
        var chargeMosOn = false
        var dischargeMosOn = false
        var balancerOn = false
        var batteryStatus = 0                // 0未知 1静置 2充电 3放电 4待机 5故障
        var protection: UInt64 = 0
        var warning: UInt64 = 0
        var balancing: UInt64 = 0
        /// 已经翻译成中文的保护 / 告警条目（协议里定义了名字的那几位）
        var protectionItems: [String] = []
        var warningItems: [String] = []
        /// 厂家自定义 / 保留位。蚂蚁协议只定义了 bit0–15，高位各固件的写法不一样，
        /// 有的板子会往里塞状态位——单独列出来，不再当成「有告警」吓人。
        var protectionReserved: [Int] = []
        var warningReserved: [Int] = []
    }

    /// 一条按位的保护 / 告警定义
    struct Flag {
        let bit: Int
        let name: String
    }

    /// 告警位（bit0–15 是协议里有名字的，6/7 保留）
    static let warningFlags: [Flag] = [
        Flag(bit: 0, name: "单体过压告警"),
        Flag(bit: 1, name: "单体欠压告警"),
        Flag(bit: 2, name: "总压过压告警"),
        Flag(bit: 3, name: "总压欠压告警"),
        Flag(bit: 4, name: "充电过流告警"),
        Flag(bit: 5, name: "放电过流告警"),
        Flag(bit: 8, name: "充电高温告警"),
        Flag(bit: 9, name: "放电高温告警"),
        Flag(bit: 10, name: "充电低温告警"),
        Flag(bit: 11, name: "放电低温告警"),
        Flag(bit: 12, name: "环境高温告警"),
        Flag(bit: 13, name: "环境低温告警"),
        Flag(bit: 14, name: "MOS 高温告警"),
        Flag(bit: 15, name: "电量低告警"),
    ]

    /// 保护位
    static let protectionFlags: [Flag] = [
        Flag(bit: 0, name: "单体过压"),
        Flag(bit: 1, name: "单体欠压"),
        Flag(bit: 2, name: "总压过压"),
        Flag(bit: 3, name: "总压欠压"),
        Flag(bit: 4, name: "充电过流"),
        Flag(bit: 5, name: "放电过流"),
        Flag(bit: 6, name: "短路"),
        Flag(bit: 7, name: "充电器过压"),
        Flag(bit: 8, name: "充电高温"),
        Flag(bit: 9, name: "放电高温"),
        Flag(bit: 10, name: "充电低温"),
        Flag(bit: 11, name: "放电低温"),
        Flag(bit: 12, name: "MOS 高温"),
        Flag(bit: 13, name: "环境高温"),
        Flag(bit: 14, name: "环境低温"),
    ]

    /// 把 8 字节位图拆成「有名字的条目」+「没有名字的位号」
    static func decode(_ value: UInt64, _ table: [Flag]) -> (names: [String], reserved: [Int]) {
        guard value != 0 else { return ([], []) }
        var names: [String] = []
        var reserved: [Int] = []
        for i in 0..<64 where (value >> UInt64(i)) & 1 == 1 {
            if let f = table.first(where: { $0.bit == i }) {
                names.append(f.name)
            } else {
                reserved.append(i)
            }
        }
        return (names, reserved)
    }

    private(set) var telemetry: Telemetry?
    private(set) var lastFrameLength = 0
    /// 最近一帧原始字节（数据台用）
    private(set) var lastFrame: [UInt8] = []
    private var stream: [UInt8] = []
    private static let capacity = 2048

    func reset() {
        stream.removeAll()
        telemetry = nil
        lastFrameLength = 0
        lastFrame = []
    }

    // MARK: 收帧

    func feed(_ chunk: [UInt8]) -> Telemetry? {
        guard !chunk.isEmpty else { return nil }
        stream.append(contentsOf: chunk)
        if stream.count > AntBmsParser.capacity {
            stream.removeFirst(stream.count - AntBmsParser.capacity)
        }

        var result: Telemetry?
        var idx = 0
        while stream.count - idx >= 6 {
            guard stream[idx] == 0x7E, stream[idx + 1] == 0xA1 else {
                idx += 1
                continue
            }
            let dataLen = Int(stream[idx + 5])
            let frameLen = 6 + dataLen + 4
            if frameLen < 12 || frameLen > 512 {
                idx += 1
                continue
            }
            if stream.count - idx < frameLen { break }

            let frame = Array(stream[idx..<(idx + frameLen)])
            let computed = AntBmsParser.crc16(frame, from: 1, count: frameLen - 5)
            let remote = UInt16(frame[frameLen - 4]) | (UInt16(frame[frameLen - 3]) << 8)
            guard computed == remote else {
                idx += 1
                continue
            }

            lastFrameLength = frameLen
            lastFrame = frame
            if frame[2] == Function.status, let t = parseStatus(frame) {
                telemetry = t
                result = t
            }
            idx += frameLen
        }
        if idx > 0 { stream.removeFirst(idx) }
        return result
    }

    // MARK: 解析

    private func parseStatus(_ f: [UInt8]) -> Telemetry? {
        guard f.count >= 34 else { return nil }

        func u16(_ i: Int) -> UInt16 {
            guard i + 1 < f.count else { return 0 }
            return UInt16(f[i]) | (UInt16(f[i + 1]) << 8)
        }
        func i16(_ i: Int) -> Int { Int(Int16(bitPattern: u16(i))) }
        func u32(_ i: Int) -> UInt32 {
            UInt32(u16(i)) | (UInt32(u16(i + 2)) << 16)
        }

        var t = Telemetry()
        t.date = Date()
        t.batteryStatus = Int(f[7])
        let tempCount = min(Int(f[8]), 8)
        let cellCount = min(Int(f[9]), 32)
        guard cellCount > 0 else { return nil }
        t.cellCount = cellCount

        t.protection = bytesToU64(f, 10)
        t.warning = bytesToU64(f, 18)
        t.balancing = bytesToU64(f, 26)
        let pFlags = AntBmsParser.decode(t.protection, AntBmsParser.protectionFlags)
        t.protectionItems = pFlags.names
        t.protectionReserved = pFlags.reserved
        let wFlags = AntBmsParser.decode(t.warning, AntBmsParser.warningFlags)
        t.warningItems = wFlags.names
        t.warningReserved = wFlags.reserved

        for i in 0..<cellCount {
            let v = Double(u16(34 + i * 2)) * 0.001
            if v > 0.5 && v < 5.0 { t.cellVoltages.append(v) }
        }

        var offset = cellCount * 2
        for i in 0..<tempCount {
            t.temps.append(i16(34 + offset + i * 2))
        }
        offset += tempCount * 2

        t.mosTemp = i16(34 + offset)
        t.balancerTemp = i16(36 + offset)
        t.packVoltage = Double(u16(38 + offset)) * 0.01
        t.current = Double(i16(40 + offset)) * 0.1
        t.soc = min(100, max(0, Int(u16(42 + offset))))
        t.soh = min(100, max(0, Int(u16(44 + offset))))

        if f.count > 48 + offset {
            t.chargeMosOn = f[46 + offset] == 0x01
            t.dischargeMosOn = f[47 + offset] == 0x01
            t.balancerOn = f[48 + offset] == 0x04
        }
        if f.count >= 54 + offset {
            t.capacityAh = Double(u32(50 + offset)) * 0.000001
            t.remainingAh = Double(u32(54 + offset)) * 0.000001
            t.cycles = Double(u32(58 + offset)) * 0.001
            t.power = Double(Int32(bitPattern: u32(62 + offset)))
        }
        if f.count >= 86 + offset {
            t.maxCellV = Double(u16(74 + offset)) * 0.001
            t.maxCellIndex = Int(u16(76 + offset))
            t.minCellV = Double(u16(78 + offset)) * 0.001
            t.minCellIndex = Int(u16(80 + offset))
            t.deltaV = Double(u16(82 + offset)) * 0.001
            t.avgCellV = Double(u16(84 + offset)) * 0.001
        }

        // 兜底：BMS 没给统计值时自己算
        if let mx = t.cellVoltages.max(), let mn = t.cellVoltages.min() {
            if t.maxCellV <= 0 { t.maxCellV = mx }
            if t.minCellV <= 0 { t.minCellV = mn }
            if t.deltaV <= 0 { t.deltaV = mx - mn }
            if t.avgCellV <= 0 {
                t.avgCellV = t.cellVoltages.reduce(0, +) / Double(t.cellVoltages.count)
            }
        }
        return t
    }

    private func bytesToU64(_ f: [UInt8], _ start: Int) -> UInt64 {
        guard start + 7 < f.count else { return 0 }
        var v: UInt64 = 0
        for i in 0..<8 {
            v |= UInt64(f[start + i]) << (8 * UInt64(i))
        }
        return v
    }

    // MARK: CRC

    static func crc16(_ frame: [UInt8], from: Int, count: Int) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        let end = min(frame.count, from + count)
        guard from < end else { return crc }
        for i in from..<end {
            crc ^= UInt16(frame[i])
            for _ in 0..<8 {
                if crc & 1 != 0 {
                    crc = (crc >> 1) ^ 0xA001
                } else {
                    crc >>= 1
                }
            }
        }
        return crc
    }
}
