import Foundation
import SwiftUI

/// 示波：车速就是一条实时波形，从右往左推。曲线抬得多高 = 车速多快，
/// 起伏多密 = 变化多急。虚线是这 6 秒的均值，右端亮点是当前值。
struct ScopeDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("show_motor_temp") private var showMotorTemp = false
    @AppStorage("show_bms_strip") private var showBms = true

    /// 6.4 秒 × 10Hz
    private let sampleCount = 64

    @StateObject private var clock = DashClock(hz: 10)
    @State private var samples: [Double] = []
    @State private var primed = false

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        let d = DashData(central: central, bms: bms)

        ZStack {
            WallpaperBackground()
            // 波形要压在底色上才看得清，这里比别的样式压得更黑一点
            Color.black.opacity(0.55)

            VStack(spacing: 0) {
                topBar(d)
                plot(d)
                    .frame(maxHeight: .infinity)
                statsStrip(d)
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
        .onAppear {
            if !primed {
                samples = Array(repeating: central.speedKmh, count: sampleCount)
                primed = true
            }
            clock.start()
        }
        .onDisappear { clock.stop() }
        .onReceive(clock.$tick) { _ in
            samples.append(central.speedKmh)
            if samples.count > sampleCount {
                samples.removeFirst(samples.count - sampleCount)
            }
        }
    }

    // MARK: 顶栏

    private func topBar(_ d: DashData) -> some View {
        HStack(spacing: 8) {
            Text("TRACE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(2.0)
                .foregroundColor(theme.accentLight)

            Text(d.name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("SPD \(Fmt.speed(d.speed)) · 峰值 \(Int(peak)) · 均值 \(Int(mean))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.42))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    private var peak: Double { samples.max() ?? 0 }
    private var mean: Double { samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count) }

    // MARK: 波形区

    private func plot(_ d: DashData) -> some View {
        GeometryReader { g in
            let w = g.size.width
            let h = g.size.height

            ZStack(alignment: .topLeading) {
                grid(w: w, h: h)

                // 均值虚线
                Path { p in
                    let y = yFor(mean, h)
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: w, y: y))
                }
                .stroke(theme.accent.opacity(0.30),
                        style: StrokeStyle(lineWidth: 0.8, dash: [3, 5]))

                // 曲线下的渐变
                areaPath(w: w, h: h)
                    .fill(LinearGradient(colors: [theme.accent.opacity(0.28), theme.accent.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))

                // 曲线
                linePath(w: w, h: h)
                    .stroke(theme.accent,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: theme.accent.opacity(0.7), radius: 5)

                // 当前值亮点
                if let last = lastPoint(w: w, h: h) {
                    Circle()
                        .fill(theme.accent.opacity(0.22))
                        .frame(width: 16, height: 16)
                        .position(last)
                    Circle()
                        .fill(theme.accentLight)
                        .frame(width: 6, height: 6)
                        .position(last)
                }

                // 大数字压在左上
                VStack(alignment: .leading, spacing: 0) {
                    Text(Fmt.speed(d.speed))
                        .font(.system(size: 54, weight: .bold, design: .monospaced))
                        .foregroundColor(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .shadow(color: theme.accent.opacity(0.5), radius: 14)
                    Text("KM/H")
                        .font(.system(size: 9, weight: .heavy))
                        .tracking(2.0)
                        .foregroundColor(theme.accentLight)
                }
                .padding(.leading, 6)
                .padding(.top, 2)

                // 右上三行
                VStack(alignment: .trailing, spacing: 1) {
                    statLine("功率", d.watts > 0 ? String(format: "%.0f W", d.watts) : "—— W")
                    statLine("母线", d.busV > 0 ? String(format: "%.1f V", d.busV) : "—— V")
                    statLine("电流", d.busA != 0 ? String(format: "%.1f A", d.busA) : "—— A")
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
                .padding(.top, 4)
            }
        }
    }

    private func statLine(_ key: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundColor(.white.opacity(0.40))
            Text(value)
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
        }
    }

    // MARK: 网格与路径

    private func grid(w: CGFloat, h: CGFloat) -> some View {
        Path { p in
            var x: CGFloat = 0
            while x < w {
                p.move(to: CGPoint(x: x, y: 0))
                p.addLine(to: CGPoint(x: x, y: h))
                x += 34
            }
            var y: CGFloat = 0
            while y < h {
                p.move(to: CGPoint(x: 0, y: y))
                p.addLine(to: CGPoint(x: w, y: y))
                y += 34
            }
        }
        .stroke(theme.accent.opacity(0.11), lineWidth: 1)
    }

    private func yFor(_ v: Double, _ h: CGFloat) -> CGFloat {
        let top: CGFloat = 62          // 给大数字和右上读数留出净空
        let bot = h - 6
        let r = CGFloat(min(max(v / max(maxSpeed, 1), 0), 1))
        return bot - (bot - top) * r
    }

    private func points(w: CGFloat, h: CGFloat) -> [CGPoint] {
        guard samples.count > 1 else { return [] }
        let n = samples.count
        return samples.enumerated().map { i, v in
            CGPoint(x: w * CGFloat(i) / CGFloat(n - 1) * 0.985,
                    y: yFor(v, h))
        }
    }

    private func linePath(w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        let pts = points(w: w, h: h)
        guard let first = pts.first else { return p }
        p.move(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        return p
    }

    private func areaPath(w: CGFloat, h: CGFloat) -> Path {
        var p = Path()
        let pts = points(w: w, h: h)
        guard let first = pts.first, let last = pts.last else { return p }
        p.move(to: CGPoint(x: first.x, y: h))
        p.addLine(to: first)
        for pt in pts.dropFirst() { p.addLine(to: pt) }
        p.addLine(to: CGPoint(x: last.x, y: h))
        p.closeSubpath()
        return p
    }

    private func lastPoint(w: CGFloat, h: CGFloat) -> CGPoint? {
        points(w: w, h: h).last
    }

    // MARK: 底部五格

    private func statsStrip(_ d: DashData) -> some View {
        let lead: (String, String) = showMotorTemp
            ? ("控制器温度", d.ctrlT.map { String(format: "%.1f", $0) } ?? "——")
            : ("相电流", d.phaseA > 0 ? String(format: "%.0f", d.phaseA) : "——")

        return HStack(spacing: 0) {
            stripCell(lead.0, lead.1, showMotorTemp ? "℃" : "A", .white)
            stripCell("转速", d.rpm > 0 ? "\(d.rpm)" : "——", "rpm", .white)
            if showBms && d.hasBms {
                stripCell("电池", "\(d.soc)", "%", Dash.socColor(d.soc))
                stripCell("总压", String(format: "%.2f", d.packV), "V", .white)
            } else {
                stripCell("定位精度", d.gpsText.replacingOccurrences(of: " m", with: ""), "m",
                          d.gpsOk ? Dash.ok : Dash.warn)
                stripCell("本次", String(format: "%.2f", d.trip), "km", .white)
            }
            stripCell("故障码",
                      d.fault == 0 ? "状态良好" : String(format: "%04X", d.fault & 0xFFFF),
                      "", d.fault == 0 ? Dash.ok : Dash.bad)
        }
        .padding(.top, 5)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(theme.accent.opacity(0.22))
                .frame(height: 1)
        }
    }

    private func stripCell(_ key: String, _ value: String, _ unit: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key)
                .font(.system(size: 7.5))
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1)
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 7.5))
                        .foregroundColor(theme.accentLight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, 8)
        .padding(.trailing, 2)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accent.opacity(0.30))
                .frame(width: 1, height: 18)
        }
    }
}
