import Foundation
import SwiftUI

/// 液态：左边一只竖罐，液面高度 = 车速 / 满量程；液面带两层波纹，
/// 波纹滚动速度跟着车速走（停车时几乎不动，110 时明显起伏）。
/// 接近满量程时液色转暖，提示「到顶了」。
struct LiquidDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("show_motor_temp") private var showMotorTemp = false
    @AppStorage("show_bms_strip") private var showBms = true

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        let d = DashData(central: central, bms: bms)
        let ratio = CGFloat(min(max(d.speed / max(maxSpeed, 1), 0), 1))

        ZStack {
            WallpaperBackground()
            Color.black.opacity(0.30)

            VStack(spacing: 0) {
                header(d)

                HStack(alignment: .center, spacing: 18) {
                    HStack(alignment: .center, spacing: 6) {
                        LiquidTankView(fill: ratio,
                                       accent: theme.accent,
                                       accentLight: theme.accentLight,
                                       hot: ratio > 0.85)
                            .frame(width: 96)
                        VStack(alignment: .leading, spacing: 0) {
                            Text("\(Int(maxSpeed))")
                            Spacer(minLength: 0)
                            Text("\(Int(maxSpeed) / 2)")
                            Spacer(minLength: 0)
                            Text("0")
                        }
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.30))
                        .frame(maxHeight: .infinity)
                        .padding(.vertical, 2)
                    }
                    // 罐子别拉成细长条：高度封顶，宽高比保持在 1:2 左右
                    .frame(maxHeight: 212)

                    VStack(alignment: .leading, spacing: 0) {
                        Text(Fmt.speed(d.speed))
                            .font(.system(size: 78, weight: .heavy))
                            .foregroundColor(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .shadow(color: theme.accent.opacity(0.45), radius: 18)

                        Text("KM/H")
                            .font(.system(size: 10, weight: .heavy))
                            .tracking(2.4)
                            .foregroundColor(ratio > 0.85 ? Dash.warn : theme.accentLight)
                            .padding(.top, 1)

                        VStack(alignment: .leading, spacing: 3) {
                            subLine("功率", d.watts > 0 ? String(format: "%.0f", d.watts) : "——", "W")
                            subLine("母线", d.busV > 0 ? String(format: "%.1f", d.busV) : "——", "V")
                            subLine("控制器", d.ctrlT.map { String(format: "%.1f", $0) } ?? "——", "℃")
                        }
                        .padding(.top, 10)
                    }

                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 6)

                cellsRow(d)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
            }
            .padding(.top, 4)
        }
    }

    // MARK: 顶栏

    private func header(_ d: DashData) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(d.online ? theme.accent : .orange)
                .frame(width: 5, height: 5)
                .shadow(color: (d.online ? theme.accent : .orange).opacity(0.8), radius: 4)

            Text(d.name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.55))

            Text("·")
                .foregroundColor(.white.opacity(0.25))

            Text(d.online ? "在线" : "连接中")
                .font(.system(size: 9))
                .foregroundColor(d.online ? theme.accentLight : .orange)

            Spacer(minLength: 0)

            if d.hasBms {
                Text("电池 \(d.soc)% · \(String(format: "%.2f", d.packV)) V")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
            } else {
                Text("电池未连接")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.28))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 5)
    }

    private func subLine(_ key: String, _ value: String, _ unit: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.36))
            Text("\(value) \(unit)")
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.78))
        }
    }

    // MARK: 底部四格

    private func cellsRow(_ d: DashData) -> some View {
        let lead: (String, String) = showMotorTemp
            ? ("电机温度", d.motorT.map { String(format: "%.0f", $0) } ?? "——")
            : ("相电流", d.phaseA > 0 ? String(format: "%.0f", d.phaseA) : "——")

        return HStack(spacing: 8) {
            cell(lead.0, lead.1, lead.0 == "电机温度" ? "℃" : "A")
            if showBms && d.hasBms {
                cell("电池电流", String(format: "%+.1f", d.packA), "A")
                cell("电池温度", "\(d.packT)", "℃")
                cell("压差", "\(Int((d.deltaV * 1000).rounded()))", "mV")
            } else {
                cell("转速", d.rpm > 0 ? "\(d.rpm)" : "——", "rpm")
                cell("定位精度", d.gpsText.replacingOccurrences(of: " m", with: ""), "m")
                cell("故障码", d.fault == 0 ? "良好" : String(format: "%04X", d.fault & 0xFFFF), "")
            }
        }
    }

    private func cell(_ key: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 8))
                .tracking(0.4)
                .foregroundColor(.white.opacity(0.42))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(theme.accentLight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(theme.accent.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(theme.accent.opacity(0.18), lineWidth: 1)
        )
    }
}

// MARK: - 液罐

private struct LiquidTankView: View {
    var fill: CGFloat
    var accent: Color
    var accentLight: Color
    var hot: Bool

    @EnvironmentObject var central: CockpitCentral
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0

    @StateObject private var clock = DashClock(hz: 30)
    @State private var phase: Double = 0

    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(Color.white.opacity(0.045))

                LiquidShape(fill: min(max(fill, 0.015), 0.95),
                            phase: phase,
                            amp: 1.2 + 3.4 * fill,
                            wavelength: max(24, g.size.width * 0.62))
                    .fill(LinearGradient(colors: hot
                                            ? [Color(red: 1.0, green: 0.86, blue: 0.45).opacity(0.95),
                                               Dash.warn.opacity(0.92)]
                                            : [accentLight.opacity(0.9), accent.opacity(0.92)],
                                         startPoint: .top, endPoint: .bottom))
                    .shadow(color: (hot ? Dash.warn : accent).opacity(0.55), radius: 10, y: -2)

                // 刻度：每 22pt 一道，给液面一个参照
                GeometryReader { gg in
                    Path { p in
                        var y: CGFloat = 22
                        while y < gg.size.height {
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: gg.size.width, y: y))
                            y += 22
                        }
                    }
                    .stroke(Color.white.opacity(0.13), lineWidth: 1)
                }

                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.28), lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(accent.opacity(0.22), lineWidth: 1)
            )
        }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
        .onReceive(clock.$tick) { _ in
            // 速率必须读实时车速：闭包捕获的是快照，所以从 central（类引用）取，才跟得上
            let live = min(max(central.speedKmh / max(maxSpeed, 1), 0), 1)
            phase += clock.dt * (0.35 + 5.2 * live)
        }
    }
}

/// 液面：一条带双频正弦的曲线，往下填满
private struct LiquidShape: Shape {
    var fill: CGFloat
    var phase: Double
    var amp: CGFloat
    var wavelength: CGFloat

    func path(in rect: CGRect) -> Path {
        let level = rect.maxY - rect.height * fill
        var p = Path()
        p.move(to: CGPoint(x: 0, y: rect.maxY))
        p.addLine(to: CGPoint(x: 0, y: level))

        var x: CGFloat = 0
        let step: CGFloat = 2
        let wl = max(wavelength, 12)
        while x <= rect.maxX {
            let y = level
                + sin(Double(x) / Double(wl) * 2 * .pi + phase) * Double(amp)
                + sin(Double(x) / Double(wl) * 3.9 * .pi - phase * 1.4) * Double(amp) * 0.4
            p.addLine(to: CGPoint(x: x, y: min(max(CGFloat(y), rect.minY + 1), rect.maxY)))
            x += step
        }
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}
