import SwiftUI

/// 内置主题色。
///
/// 每套主题只改「强调色」这一条主轴：进度弧、发光圈、关键数值、按钮 tint 全部跟着走，
/// 毛玻璃卡片、白色刻度、红色指针这类结构性元素保持不变，保证换色之后仍然是同一台仪表，
/// 而不是换了个 App。
enum ThemePreset: String, CaseIterable, Identifiable {
    case pink
    case cyan
    case lime
    case amber
    case violet
    case ice

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pink:   return "霓虹粉"
        case .cyan:   return "电光青"
        case .lime:   return "荧光绿"
        case .amber:  return "日落橙"
        case .violet: return "电光紫"
        case .ice:    return "冰川蓝"
        }
    }

    /// 主色：进度弧、发光、强调文字
    var accent: Color {
        switch self {
        case .pink:   return Color(red: 0.859, green: 0.051, blue: 0.420)
        case .cyan:   return Color(red: 0.000, green: 0.760, blue: 1.000)
        case .lime:   return Color(red: 0.157, green: 0.878, blue: 0.443)
        case .amber:  return Color(red: 1.000, green: 0.478, blue: 0.094)
        case .violet: return Color(red: 0.545, green: 0.361, blue: 1.000)
        case .ice:    return Color(red: 0.310, green: 0.780, blue: 0.960)
        }
    }

    /// 浅色端：渐变高光、次级强调文字
    var accentLight: Color {
        switch self {
        case .pink:   return Color(red: 1.000, green: 0.360, blue: 0.660)
        case .cyan:   return Color(red: 0.420, green: 0.900, blue: 1.000)
        case .lime:   return Color(red: 0.520, green: 1.000, blue: 0.700)
        case .amber:  return Color(red: 1.000, green: 0.720, blue: 0.380)
        case .violet: return Color(red: 0.740, green: 0.620, blue: 1.000)
        case .ice:    return Color(red: 0.620, green: 0.900, blue: 1.000)
        }
    }

    /// 深色端：无壁纸时的背景渐变中段
    var deep: Color {
        switch self {
        case .pink:   return Color(red: 0.400, green: 0.020, blue: 0.240)
        case .cyan:   return Color(red: 0.010, green: 0.220, blue: 0.340)
        case .lime:   return Color(red: 0.020, green: 0.260, blue: 0.140)
        case .amber:  return Color(red: 0.340, green: 0.150, blue: 0.020)
        case .violet: return Color(red: 0.180, green: 0.080, blue: 0.360)
        case .ice:    return Color(red: 0.030, green: 0.200, blue: 0.300)
        }
    }

    /// 背景渐变的起始/结束（近黑）
    var baseDark: Color {
        switch self {
        case .pink:   return Color(red: 0.090, green: 0.010, blue: 0.060)
        case .cyan:   return Color(red: 0.010, green: 0.040, blue: 0.060)
        case .lime:   return Color(red: 0.010, green: 0.040, blue: 0.025)
        case .amber:  return Color(red: 0.060, green: 0.030, blue: 0.010)
        case .violet: return Color(red: 0.040, green: 0.020, blue: 0.070)
        case .ice:    return Color(red: 0.010, green: 0.030, blue: 0.050)
        }
    }

    /// 指针颜色：粉色主题保留视频里那根红针，其余主题跟主色走，避免撞色
    var needle: Color {
        switch self {
        case .pink: return Color(red: 1.0, green: 0.18, blue: 0.22)
        default:    return accentLight
        }
    }

    var gradientColors: [Color] { [accent, accentLight] }
}

enum ThemeStore {
    static let key = "theme_id"

    static var current: ThemePreset {
        let raw = UserDefaults.standard.string(forKey: key) ?? ""
        return ThemePreset(rawValue: raw) ?? .pink
    }

    static func preset(for raw: String) -> ThemePreset {
        ThemePreset(rawValue: raw) ?? .pink
    }
}

/// 原来写死品红的地方统一从这里取，改主题只需要改这一处
enum NeonTheme {
    static var pink: Color { ThemeStore.current.accent }
    static var pinkLight: Color { ThemeStore.current.accentLight }

    static let cardTop = Color.white.opacity(0.10)
    static let cardBottom = Color.black.opacity(0.34)
    static let hairline = Color.white.opacity(0.14)
}
