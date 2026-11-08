import Foundation
import SwiftUI

/// 轨道：中央一列轻体重的大字，外面两圈细轨道，一颗星按车速公转——
/// 车速越高转得越快（静止约 7 秒一圈，满速约 2 秒一圈）。
/// 内圈弧长 = 车速占满量程的比例，超过 85% 转暖色。
struct OrbitDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("show_motor_temp") private var showMotorTemp = false
    @AppStorage("show_bms_strip") private var showBms = true

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        let d = DashData(central: central, bms: bms)

        ZStack {
            WallpaperBackground()
            Color.black.opacity(0.42)

            VStack(spacing: 0) {
                topBar(d)

                GeometryReader { geo in
                    let side = min(geo.size.height - 4, geo.size.width * 0.46)

                    ZStack {
                        OrbitRing(side: side,
                                  accent: theme.accent,
                                  accentLight: theme.accentLight,
                                  warn: Dash.warn)
                            .frame(width: side, height: side)

                        VStack(spacing: 0) {
                            Text(Fmt.speed(d.speed))
                                .font(.system(size: side * 0.31, weight: .light))
                                .foregroundColor(.white)
                                .lineLimit(1)
                                .minimumScaleFactor(0.5)
                                .shadow(color: theme.accent.opacity(0.55), radius: 22)
                            Text("KM/H")
                                .font(.system(size: 9, weight: .heavy))
                                .tracking(2.6)
                                .foregroundColor(.white.opacity(0.42))
                            Text(d.busV > 0 ? String(format: "%.1f V · %@", d.busV, tempText(d)) : "——")
                                .font(.system(size: 8.5, design: .monospaced))
                                .foregroundColor(.white.opacity(0.36))
                                .padding(.top, 3)
                        }

                        HStack {
                            sideStats(d, leading: true)
                            Spacer(minLength: 0)
                            sideStats(d, leading: false)
                        }
                    }
                }
                .frame(maxHeight: .infinity)

                footBar(d)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 6)
        }
    }

    private func tempText(_ d: DashData) -> String {
        d.ctrlT.map { String(format: "%.1f ℃", $0) } ?? "——"
    }

    // MARK: 顶栏

    private func topBar(_ d: DashData) -> some View {
        HStack(spacing: 7) {
            Circle()
                .fill(d.online ? theme.accent : .orange)
                .frame(width: 5, height: 5)
                .shadow(color: (d.online ? theme.accent : .orange).opacity(0.8), radius: 4)

            Text(d.name)
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.52))
                .lineLimit(1)

            Spacer(minLength: 0)

            Text(d.hasBms ? "电池 \(d.soc)% · \(d.cells)S" : "电池未连接")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.40))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 5)
    }

    // MARK: 两侧

    @ViewBuilder
    private func sideStats(_ d: DashData, leading: Bool) -> some View {
        VStack(alignment: leading ? .leading : .trailing, spacing: 12) {
            if leading {
                item("功率", d.watts > 0 ? String(format: "%.0f", d.watts) : "——", "W")
                if showMotorTemp {
                    item("电机温度", d.motorT.map { String(format: "%.0f", $0) } ?? "——", "℃")
                } else {
                    item("相电流", d.phaseA > 0 ? String(format: "%.0f", d.phaseA) : "——", "A")
                }
            } else {
                if showBms && d.hasBms {
                    item("电量", "\(d.soc)", "%")
                    item("总压", String(format: "%.2f", d.packV), "V")
                } else {
                    item("转速", d.rpm > 0 ? "\(d.rpm)" : "——", "rpm")
                    item("定位精度", d.gpsText.replacingOccurrences(of: " m", with: ""), "m")
                }
            }
        }
    }

    private func item(_ key: String, _ value: String, _ unit: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(key)
                .font(.system(size: 7.5))
                .tracking(1.0)
                .foregroundColor(.white.opacity(0.36))
            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 17, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8))
                        .foregroundColor(theme.accentLight)
                }
            }
        }
    }

    // MARK: 底栏

    private func footBar(_ d: DashData) -> some View {
        HStack(spacing: 12) {
            Text("GPS \(d.gpsText)")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(d.gpsOk ? Dash.ok.opacity(0.8) : .white.opacity(0.34))

            Text("本次")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.32))
            Text(String(format: "%.2f km", d.trip))
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.9))

            Spacer(minLength: 0)

            Text(d.hasBms ? "压差 \(Int((d.deltaV * 1000).rounded())) mV · \(d.packT)℃" : "")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.32))
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - 轨道环

private struct OrbitRing: View {
    var side: CGFloat
    var accent: Color
    var accentLight: Color
    var warn: Color

    @EnvironmentObject var central: CockpitCentral
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0

    @StateObject private var clock = DashClock(hz: 30)
    @State private var angle: Double = 0

    private var ratio: Double {
        min(max(central.speedKmh / max(maxSpeed, 1), 0), 1)
    }

    /// 一圈耗时：静止约 7 秒，满速约 2 秒
    private var period: Double {
        max(1.6 + 5.4 * pow(1 - ratio, 0.8), 1.2)
    }

    private var rOuter: CGFloat { side / 2 - 1 }
    private var rInner: CGFloat { side / 2 - 14 }

    var body: some View {
        ZStack {
            // 外圈：淡到几乎看不见的底，加一圈点线
            Circle()
                .stroke(accent.opacity(0.14), lineWidth: 1)
                .frame(width: side - 2, height: side - 2)
            Circle()
                .stroke(accent.opacity(0.28),
                        style: StrokeStyle(lineWidth: 1, dash: [1, 9.5]))
                .frame(width: side - 2, height: side - 2)

            // 内圈：底环 + 进度弧
            Circle()
                .stroke(accent.opacity(0.28), lineWidth: 1.2)
                .frame(width: rInner * 2, height: rInner * 2)

            Circle()
                .trim(from: 0, to: CGFloat(ratio))
                .stroke(ratio > 0.85 ? warn : accent,
                        style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .frame(width: rInner * 2, height: rInner * 2)
                .shadow(color: (ratio > 0.85 ? warn : accent).opacity(0.8), radius: 6)

            // 公转的星
            Circle()
                .fill(accentLight.opacity(0.25))
                .frame(width: 20, height: 20)
                .offset(x: CGFloat(cos(angle)) * rOuter, y: CGFloat(sin(angle)) * rOuter)
            Circle()
                .fill(accentLight)
                .frame(width: 7, height: 7)
                .offset(x: CGFloat(cos(angle)) * rOuter, y: CGFloat(sin(angle)) * rOuter)
                .shadow(color: accentLight.opacity(0.9), radius: 8)
        }
        .onAppear { clock.start() }
        .onDisappear { clock.stop() }
        .onReceive(clock.$tick) { _ in
            angle += clock.dt * 2 * .pi / period
            if angle > 2 * .pi { angle -= 2 * .pi }
        }
    }
}
