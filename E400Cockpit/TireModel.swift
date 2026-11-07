import Foundation

// MARK: - 轮胎规格

/// 由侧壁规格解析出的轮胎几何参数。
/// 支持公制（90/90-12、120/70-12）与英制（3.50-10），可带载重指数（44J / 51J）。
struct TireSpec {
    /// 断面宽度 mm
    var widthMM: Double
    /// 扁平比（%），英制轮胎按 100 处理
    var aspectPct: Double
    /// 轮辋直径 inch
    var rimInch: Double
    /// 载重指数（LI），未知为 nil
    var loadIndex: Int?

    /// 单侧胎壁高度 mm
    var sidewallMM: Double { widthMM * aspectPct / 100.0 }
    /// 自由（未受压）外径 mm
    var freeDiameterMM: Double { rimInch * 25.4 + 2.0 * sidewallMM }
    /// 自由半径 mm
    var freeRadiusMM: Double { freeDiameterMM / 2.0 }
    /// 自由周长 mm（空转/离地时的理论周长，偏大）
    var freeCircumferenceMM: Double { Double.pi * freeDiameterMM }

    /// 单胎额定载荷 kg。没有载重指数时按胎宽粗估（踏板车小轮径经验值）。
    var ratedLoadKg: Double {
        if let li = loadIndex, let kg = TireModel.loadIndexTable[li] { return kg }
        // 无 LI：90mm 量级小胎约 150kg，随胎宽线性放大并封顶
        return min(max(90.0, widthMM * 1.65), 400.0)
    }

    /// 规格描述的规范形式，用于 UI 回显
    var displaySpec: String {
        if abs(aspectPct - 100.0) < 0.5 && widthMM >= 70 {
            return String(format: "%.2f-%.0f", widthMM / 25.4, rimInch)
        }
        return String(format: "%.0f/%.0f-%.0f", widthMM, aspectPct, rimInch)
    }

    var diameterText: String { String(format: "%.0f mm", freeDiameterMM) }
}

// MARK: - 估算结果

struct TireEstimate {
    var spec: TireSpec
    /// 该轮承担的静态载荷 kg
    var axleLoadKg: Double
    var pressureBar: Double
    /// 静态下沉量 mm
    var staticDeflectionMM: Double
    /// 滚动半径 mm（决定速度）
    var rollRadiusMM: Double
    /// 滚动周长 mm（最终用于测速/计程）
    var rollCircumferenceMM: Double
    /// 滚动周长相对自由周长缩短的比例（0.03 = 短 3%）
    var shrinkRatio: Double
    /// 下沉量占自由半径的比例
    var deflectionRatioActual: Double

    var shrinkPercentText: String { String(format: "−%.1f%%", shrinkRatio * 100) }
}

// MARK: - 模型

enum TireModel {

    /// 摩托/踏板车常见载重指数 → 单胎额定载荷（kg）
    static let loadIndexTable: [Int: Double] = [
        26: 95, 27: 97, 28: 100, 29: 103, 30: 106, 31: 109, 32: 112, 33: 115,
        34: 118, 35: 121, 36: 125, 37: 128, 38: 132, 39: 136, 40: 140, 41: 145,
        42: 150, 43: 155, 44: 160, 45: 165, 46: 170, 47: 175, 48: 180, 49: 185,
        50: 190, 51: 195, 52: 200, 53: 206, 54: 212, 55: 218, 56: 224, 57: 230,
        58: 236, 59: 243, 60: 250, 61: 257, 62: 265, 63: 272, 64: 280, 65: 290,
        66: 300, 67: 307, 68: 315, 69: 325, 70: 335, 71: 345, 72: 355, 73: 365,
        74: 375, 75: 387, 76: 400
    ]

    /// 参考胎压 bar
    static let referencePressure = 2.2
    /// 默认参考下沉率（占自由半径）：踏板车小轮径胎在额定载荷下约 6%
    static let defaultDeflectionRatio = 0.060
    /// 默认滚动有效系数：实际吃掉的半径约为静态下沉的 62%
    static let defaultRollFactor = 0.62

    // MARK: 解析

    /// 解析侧壁规格字符串。容忍空格、R 字母、中文全角符号、"44J" 这类载重指数后缀。
    static func parse(_ raw: String) -> TireSpec? {
        let s = raw
            .uppercased()
            .replacingOccurrences(of: "Ｒ", with: "R")
            .replacingOccurrences(of: "／", with: "/")
            .replacingOccurrences(of: "－", with: "-")
            .replacingOccurrences(of: "—", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func numbers(in text: String) -> [Double] {
            var out: [Double] = []
            var buf = ""
            for ch in text {
                if ch.isNumber || ch == "." {
                    buf.append(ch)
                } else if !buf.isEmpty {
                    if let v = Double(buf) { out.append(v) }
                    buf = ""
                }
            }
            if !buf.isEmpty, let v = Double(buf) { out.append(v) }
            return out
        }

        /// 把 "44J" / "44" 这类载重指数夹在尾巴上提取出来。
        /// 注意不能用 \b：44J 里 4 和 J 都是词字符，边界不成立。
        func loadIndexNear(_ text: String, after token: String) -> Int? {
            guard let r = text.range(of: token) else { return nil }
            let tail = String(text[r.upperBound...])
            if let m = tail.range(of: #"^\s*(\d{2})(?![0-9])"#, options: .regularExpression) {
                let digits = numbers(in: String(tail[m]))
                if let v = digits.first, v >= 20, v <= 76 { return Int(v) }
            }
            return nil
        }

        let metricPattern = #"\d{2,3}\s*/\s*\d{2}\s*(?:[-R]\s*)?\d{1,2}(?!\d)(?:\.\d+)?"#
        let inchPattern = #"\d{1,2}(?:\.\d{1,2})?\s*(?:[-R]\s*)?\d{1,2}(?!\d)(?:\.\d+)?"#

        // 公制 90/90-12 / 120/70 R12 / 90/90-12 44J
        if let r = s.range(of: metricPattern, options: .regularExpression) {
            let matched = String(s[r])
            let nums = numbers(in: matched)
            guard nums.count >= 3 else { return nil }
            let li = loadIndexNear(s, after: matched)
            return TireSpec(widthMM: nums[0], aspectPct: nums[1], rimInch: nums[2], loadIndex: li)
        }

        // 双规格（4.10/3.50-10）取斜杠后那一段的宽度，这是实际装车尺寸
        var target = s
        if let slash = s.lastIndex(of: "/") {
            let tail = String(s[s.index(after: slash)...])
            if tail.range(of: inchPattern, options: .regularExpression) != nil {
                target = tail
            }
        }

        // 英制 3.50-10 / 3.00-10 51J
        if let r = target.range(of: inchPattern, options: .regularExpression) {
            let matched = String(target[r])
            let nums = numbers(in: matched)
            guard nums.count >= 2 else { return nil }
            let li = loadIndexNear(target, after: matched)
            return TireSpec(widthMM: nums[0] * 25.4, aspectPct: 100, rimInch: nums[1], loadIndex: li)
        }

        // 只有轮辋号（如 "12"）无法定胎宽，拒绝
        return nil
    }

    // MARK: 估算

    /// 由轮胎规格 + 该轮静态载荷 + 胎压，估算静态下沉与滚动周长。
    ///
    /// 载荷层用幂律缩放而非线性：载荷比 0.5 时下沉约降到 0.61 倍，
    /// 这与充气轮胎的实际刚度曲线（载荷越大越硬）更接近。
    static func estimate(spec: TireSpec,
                         axleLoadKg: Double,
                         pressureBar: Double,
                         deflectionRatio: Double = TireModel.defaultDeflectionRatio,
                         rollFactor: Double = TireModel.defaultRollFactor) -> TireEstimate {
        let r0 = max(spec.freeRadiusMM, 50.0)
        let load = max(axleLoadKg, 1.0)
        let p = pressureBar > 0.3 ? pressureBar : referencePressure

        let loadRatio = load / max(spec.ratedLoadKg, 1.0)
        let pressureRatio = referencePressure / p

        let deltaRef = deflectionRatio * r0
        // 载荷指数 0.70、胎压指数 0.45 —— 工程拟合值，非严格解析解
        let deltaRaw = deltaRef
            * pow(max(loadRatio, 0.02), 0.70)
            * pow(max(pressureRatio, 0.2), 0.45)
        // 物理上限：压到 1/4 半径就是没气了，此时速度怎么算都不准
        let delta = min(max(deltaRaw, 0.3), r0 * 0.25)

        let rr = max(r0 - rollFactor * delta, r0 * 0.80)
        let circ = 2.0 * Double.pi * rr
        let free = spec.freeCircumferenceMM

        return TireEstimate(
            spec: spec,
            axleLoadKg: load,
            pressureBar: p,
            staticDeflectionMM: delta,
            rollRadiusMM: rr,
            rollCircumferenceMM: circ,
            shrinkRatio: free > 1 ? max(0.0, (free - circ) / free) : 0.0,
            deflectionRatioActual: delta / r0
        )
    }

    // MARK: 配置读写

    enum Keys {
        static let rearSpec = "tire_rear_spec"
        static let rearPressure = "tire_rear_pressure"
        static let frontSpec = "tire_front_spec"
        static let frontPressure = "tire_front_pressure"
        static let vehMass = "veh_mass"
        static let riderMass = "rider_mass"
        static let cargoMass = "cargo_mass"
        static let rearAxleRatio = "rear_axle_ratio"
        static let useMeasured = "use_measured_circ"
        static let measuredCirc = "wheel_circ_measured"
        static let deflectionRatio = "deflection_ratio"
        static let rollFactor = "roll_factor"
        /// 兼容旧 key：最终生效周长
        static let effectiveCirc = "wheel_circ_mm"
        static let circSource = "wheel_circ_source"
    }

    struct Config {
        var rearSpec = "90/90-12 44J"
        var rearPressure = 2.2
        var frontSpec = "90/90-12 44J"
        var frontPressure = 2.2
        var vehMass = 100.0
        var riderMass = 70.0
        var cargoMass = 0.0
        var rearAxleRatio = 0.58
        var useMeasured = false
        var measuredCirc = 1426.0
        var deflectionRatio = TireModel.defaultDeflectionRatio
        var rollFactor = TireModel.defaultRollFactor

        static func load(from d: UserDefaults = .standard) -> Config {
            var c = Config()
            if let v = d.string(forKey: Keys.rearSpec), !v.isEmpty { c.rearSpec = v }
            if let v = d.string(forKey: Keys.frontSpec), !v.isEmpty { c.frontSpec = v }
            if let v = d.object(forKey: Keys.rearPressure) as? Double { c.rearPressure = v }
            if let v = d.object(forKey: Keys.frontPressure) as? Double { c.frontPressure = v }
            if let v = d.object(forKey: Keys.vehMass) as? Double { c.vehMass = v }
            if let v = d.object(forKey: Keys.riderMass) as? Double { c.riderMass = v }
            if let v = d.object(forKey: Keys.cargoMass) as? Double { c.cargoMass = v }
            if let v = d.object(forKey: Keys.rearAxleRatio) as? Double { c.rearAxleRatio = v }
            if d.object(forKey: Keys.useMeasured) != nil { c.useMeasured = d.bool(forKey: Keys.useMeasured) }
            if let v = d.object(forKey: Keys.measuredCirc) as? Double { c.measuredCirc = v }
            if let v = d.object(forKey: Keys.deflectionRatio) as? Double { c.deflectionRatio = v }
            if let v = d.object(forKey: Keys.rollFactor) as? Double { c.rollFactor = v }
            return c
        }

        /// 后轴（驱动轮）静态载荷 kg
        var rearAxleLoadKg: Double {
            max(1.0, (vehMass + riderMass + cargoMass) * min(max(rearAxleRatio, 0.3), 0.8))
        }
        /// 前轴静态载荷 kg
        var frontAxleLoadKg: Double {
            max(1.0, (vehMass + riderMass + cargoMass) - rearAxleLoadKg)
        }

        var rearEstimate: TireEstimate? {
            guard let spec = TireModel.parse(rearSpec) else { return nil }
            return TireModel.estimate(spec: spec, axleLoadKg: rearAxleLoadKg,
                                      pressureBar: rearPressure,
                                      deflectionRatio: deflectionRatio, rollFactor: rollFactor)
        }

        var frontEstimate: TireEstimate? {
            guard let spec = TireModel.parse(frontSpec) else { return nil }
            return TireModel.estimate(spec: spec, axleLoadKg: frontAxleLoadKg,
                                      pressureBar: frontPressure,
                                      deflectionRatio: deflectionRatio, rollFactor: rollFactor)
        }
    }

    /// 最终用于测速的周长 mm。实测覆盖优先，否则用后轮模型估算。
    static func effectiveCircumferenceMM(from d: UserDefaults = .standard) -> Double {
        let c = Config.load(from: d)
        if c.useMeasured && c.measuredCirc > 600 && c.measuredCirc < 3000 {
            return c.measuredCirc
        }
        if let e = c.rearEstimate, e.rollCircumferenceMM > 600 {
            return e.rollCircumferenceMM
        }
        return 1426
    }

    static func circumferenceSourceText(from d: UserDefaults = .standard) -> String {
        let c = Config.load(from: d)
        if c.useMeasured && c.measuredCirc > 600 { return "实测" }
        return c.rearEstimate == nil ? "默认" : "估算"
    }
}
