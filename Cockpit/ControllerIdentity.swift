import Foundation

/// 控制器身份：品牌 + 型号码 + 来源
struct ControllerIdentity {
    var brand: String?
    var code: String?
    var source: String

    /// 建议填入"控制器"字段的文本，如 "凌博 A70814"
    var suggestedLabel: String? {
        switch (brand, code) {
        case let (b?, c?): return "\(b) \(c)"
        case let (b?, nil): return b
        case let (nil, c?): return c
        default: return nil
        }
    }
}

/// 控制器型号识别。只做"有把握"的推断，宁可返回 nil 也不瞎猜。
enum ControllerIdentifier {

    /// 已知品牌前缀（广播名里出现即认）
    private static let brandPrefixes: [(String, String)] = [
        ("LBMC", "凌博"),
        ("LINGBO", "凌博"),
        ("VOTOL", "远驱"),
        ("SABVOTON", "Sabvoton"),
        ("KELLY", "Kelly"),
        ("SIAECOSYS", "晶汇"),
        ("NINGBO", "宁波")
    ]

    /// 广播名是否属于已知控制器品牌（用于扫描过滤，不再是"仅凌博"）
    static func isKnownName(_ name: String) -> Bool {
        let upper = name.uppercased()
        return brandPrefixes.contains { upper.contains($0.0) }
    }

    /// 品牌名（仅用于界面标注）
    static func brandName(for name: String) -> String? {
        let upper = name.uppercased()
        return brandPrefixes.first { upper.contains($0.0) }?.1
    }

    /// 从设备广播名识别，如 "LBMC-A70814" → 凌博 / A70814
    static func fromName(_ name: String?) -> ControllerIdentity? {
        guard let name, !name.isEmpty else { return nil }
        let upper = name.uppercased()
        for (prefix, brand) in brandPrefixes {
            guard let r = upper.range(of: prefix) else { continue }
            var code = String(name[r.upperBound...])
                .trimmingCharacters(in: CharacterSet(charactersIn: " -_"))
            if code.count > 18 { code = String(code.prefix(18)) }
            return ControllerIdentity(brand: brand,
                                      code: code.isEmpty ? nil : code,
                                      source: "广播名")
        }
        return nil
    }

    /// 从帧字节里扫连续可打印 ASCII，型号字符串常藏在版本帧里。
    /// 例："E400Max-CAN" 这类。
    static func asciiCandidates(in bytes: [UInt8]) -> [String] {
        var out: [String] = []
        var buf: [UInt8] = []

        func flush() {
            defer { buf.removeAll() }
            guard buf.count >= 4, buf.count <= 24,
                  let s = String(bytes: buf, encoding: .ascii) else { return }
            let letters = s.filter { $0.isLetter }.count
            let digits = s.filter { $0.isNumber }.count
            // 至少 2 个字母，且（含数字 或 长度 ≥ 6），排除 "OK"、"AT" 这类噪声
            guard letters >= 2, digits >= 1 || s.count >= 6 else { return }
            guard !s.contains("  "), !s.hasPrefix("AT") else { return }
            if !out.contains(s) { out.append(s) }
        }

        for b in bytes {
            if b >= 0x20, b <= 0x7E {
                buf.append(b)
            } else {
                flush()
            }
        }
        flush()
        return out
    }
}
