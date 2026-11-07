import Foundation

/// 全局数值格式。默认两位小数，设置里可改 0–3 位。
/// 速度例外：固定整数（110.00 km/h 没有信息量，还挤占仪表空间）。
enum Fmt {

    static let decimalsKey = "value_decimals"

    static var decimals: Int {
        let v = UserDefaults.standard.object(forKey: decimalsKey) as? Int ?? 2
        return min(max(v, 0), 3)
    }

    /// 通用数值 + 单位，如 "81.00 V"
    static func num(_ v: Double, _ unit: String = "") -> String {
        let s = String(format: "%.\(decimals)f", v)
        return unit.isEmpty ? s : "\(s) \(unit)"
    }

    /// 无单位纯数字
    static func raw(_ v: Double) -> String {
        String(format: "%.\(decimals)f", v)
    }

    /// 温度，跟随全局精度
    static func temp(_ v: Double?) -> String {
        guard let v else { return "——" }
        return String(format: "%.\(decimals)f ℃", v)
    }

    /// 速度：整数，不带小数
    static func speed(_ v: Double) -> String {
        String(format: "%.0f", v)
    }

    /// 带符号数值，用于电流（回充为负）
    static func signed(_ v: Double, _ unit: String = "") -> String {
        let s = String(format: "%.\(decimals)f", v)
        let body = v > 0 ? "+\(s)" : s
        return unit.isEmpty ? body : "\(body) \(unit)"
    }

    /// 整数显示（挡位、RPM 等）
    static func int(_ v: Double) -> String {
        String(format: "%.0f", v)
    }

    static func int(_ v: Int) -> String {
        String(v)
    }

    /// 百分比，跟随全局精度
    static func percent(_ v: Double) -> String {
        String(format: "%.\(decimals)f %%", v)
    }

    /// 只显示整数部分，用于 RPM 这种大数
    static func rpm(_ v: Int) -> String {
        String(format: "%d", v)
    }
}
