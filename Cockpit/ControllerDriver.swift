import Foundation

/// 控制器协议驱动接口。
///
/// 蓝牙传输层（CockpitCentral）只认这个接口，不认具体品牌。
/// 要支持新控制器（远驱 / 晶汇 / Sabvoton / Kelly…），新增一个遵循本协议的文件即可，
/// 蓝牙层、仪表页、数据台、设置页都不用改。
protocol ControllerDriver: AnyObject {
    /// 显示在设置页 / 数据台的驱动名称
    var displayName: String { get }
    /// 是否已完成握手（拿到换算分母）
    var isCalibrated: Bool { get }
    /// 标定结果摘要，未标定为 nil
    var calibrationSummary: String? { get }
    /// 连接的设备名前缀提示，用于扫描列表排序（可为空）
    var nameHint: String { get }

    /// 最近一帧的总长度，0 表示尚无有效帧
    var lastFrameLength: Int { get }
    /// 最近一帧实时帧的原始字节（供数据台逐字节核对布局）
    var lastRealtimeFrame: [UInt8] { get }
    /// 最近一帧标定/配置帧（0x60）的原始字节
    var lastConfigFrame: [UInt8] { get }
    /// 最近一次解析实际取用的字段偏移
    var trace: LingboParser.FieldTrace { get }

    /// 清空状态，连接新设备时调用
    func reset()

    /// 从设置读取字段偏移覆盖（用户改了偏移要即时生效）
    func applyLayoutFromDefaults()

    /// 关掉「长帧请求」实验开关（自动回退时用）
    func disableLongRequest()

    /// 下一条要发出的请求帧。轮询器每 500ms 取一次。
    func nextRequestFrame() -> [UInt8]

    /// 喂入一帧通知数据，解析成功返回遥测
    func feed(_ bytes: [UInt8]) -> LingboParser.Telemetry?
}

// MARK: - 凌博 Lingbo（AA55 帧，E300/E400 系列）

extension LingboParser: ControllerDriver {

    var displayName: String { "凌博 Lingbo（AA55）" }

    var isCalibrated: Bool { calibration.calibrated }

    var calibrationSummary: String? {
        guard calibration.calibrated else { return nil }
        return "电流分母=\(calibration.busCurrentDiv) 电压分母=\(calibration.busVoltageDiv)"
    }

    var nameHint: String { "LBMC" }

    func nextRequestFrame() -> [UInt8] {
        if !calibration.calibrated { return Lingbo.calibrationRequest }
        return useLongRequest ? Lingbo.realtimeRequestLong : Lingbo.realtimeRequest
    }
}

// MARK: - 驱动注册表

enum ControllerDrivers {

    /// 全部内置驱动。默认凌博。
    static func makeDefault() -> ControllerDriver {
        LingboParser()
    }

    /// 连接后按"是否有可写 + 可通知特征"推断通道，
    /// 这里给出已知设备的服务/特征对照，用于日志提示与优先级排序。
    struct TransportHint {
        var label: String
        var service: String
        var notify: String
        var write: String
    }

    static let knownTransports: [TransportHint] = [
        TransportHint(label: "凌博 / 通用 FFF0", service: "FFF0", notify: "FFF1", write: "FFF2"),
        TransportHint(label: "通用 FFE0", service: "FFE0", notify: "FFE1", write: "FFE1"),
        TransportHint(label: "Nordic UART",
                      service: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E",
                      notify: "6E400003-B5A3-F393-E0A9-E50E24DCCA9E",
                      write: "6E400002-B5A3-F393-E0A9-E50E24DCCA9E")
    ]
}
