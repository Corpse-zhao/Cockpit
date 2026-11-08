import Foundation
import SwiftUI

/// 赛道运动：去掉圆盘，速度变成超大斜体数字 + 横条；
/// 右半屏全部是「数值 + 横向进度条」，骑行时横扫一眼就知道哪项接近上限。
/// 配色只认主题色：横条渐变 = 主题色 → 浅色端，绿/橙/红只留给状态语义。
struct RaceDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("show_motor_temp") private var showMotorTemp = false
    @AppStorage("show_bms_strip") private var showBms = true

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        let d = DashData(central: central, bms: bms)

        GeometryReader { geo in
            let leftW = geo.size.width * 0.575

            ZStack {
                WallpaperBackground()
                Color.black.opacity(0.36)

                VStack(spacing: 0) {
                    topBar(d)
                    HairLine()

                    HStack(spacing: 0) {
                        leftColumn(d)
                            .frame(width: leftW)
                        Rectangle()
                            .fill(Color.white.opacity(0.08))
                            .frame(width: 1)
                        rightColumn(d)
                            .frame(maxWidth: .infinity)
                    }
                    .frame(maxHeight: .infinity)

                    HairLine()
                    footBar(d)
                }
                .padding(.horizontal, 12)
            }
        }
    }

    // MARK: 顶栏

    private func topBar(_ d: DashData) -> some View {
        HStack(spacing: 9) {
            Text("RACE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.8)
                .foregroundColor(.white)
                .padding(.horizontal, 11)
                .padding(.vertical, 3)
                .background(theme.accent)
                .skew(-0.18)

            Text(d.name)
                .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .lineLimit(1)

            HStack(spacing: 4) {
                Circle()
                    .fill(d.online ? Dash.ok : .orange)
                    .frame(width: 4, height: 4)
                Text(d.online ? "在线" : "连接中")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(d.online ? Dash.ok : .orange)
            }

            Spacer(minLength: 6)

            Text(d.cells > 0 ? "\(d.cells)S · \(d.packT)℃" : "无电池数据")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.40))
        }
        .padding(.vertical, 5)
    }

    // MARK: 左栏

    private func leftColumn(_ d: DashData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("SPEED")
                .font(.system(size: 9, weight: .heavy))
                .tracking(2.6)
                .foregroundColor(.white.opacity(0.34))
                .padding(.top, 6)

            HStack(alignment: .lastTextBaseline, spacing: 7) {
                Text(Fmt.speed(d.speed))
                    .font(.system(size: 68, weight: .heavy))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .skew(-0.09)
                    .shadow(color: Color.white.opacity(0.18), radius: 14)
                Text("km/h")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white.opacity(0.42))
                    .padding(.bottom, 6)
            }
            .padding(.top, -4)

            speedBar(d)
                .padding(.top, 4)

            HStack {
                ForEach(0..<8, id: \.self) { i in
                    Text("\(Int(maxSpeed) * i / 7)")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.white.opacity(0.24))
                    if i < 7 { Spacer(minLength: 0) }
                }
            }
            .padding(.top, 3)

            Spacer(minLength: 6)

            if showBms && d.hasBms {
                batteryBlock(d)
                    .padding(.bottom, 8)
            }

            cells(d)
                .padding(.bottom, 8)
        }
        .padding(.leading, 4)
        .padding(.trailing, 14)
    }

    /// 速度横条：底槽 + 主题色渐变填充 + 等距刻线
    private func speedBar(_ d: DashData) -> some View {
        let p = Dash.ratio(d.speed, maxSpeed)

        return GeometryReader { g in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.white.opacity(0.13))
                Rectangle()
                    .fill(LinearGradient(colors: [theme.accent.opacity(0.55),
                                                  theme.accent,
                                                  theme.accentLight],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(g.size.width * p, 0))
                // 刻线：把整条切成 12 段，骑起来看得出「到哪一格」
                HStack(spacing: 0) {
                    ForEach(0..<12, id: \.self) { _ in
                        Rectangle()
                            .fill(Color.black.opacity(0.55))
                            .frame(width: 1)
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .frame(height: 12)
        .skew(-0.16)
        .clipped()
    }

    /// 电池：电量 + 总压 + 电流 + 温度，下面一条进度
    private func batteryBlock(_ d: DashData) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                Text("电池")
                    .font(.system(size: 8, weight: .heavy))
                    .tracking(1.4)
                    .foregroundColor(.white.opacity(0.34))

                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("\(d.soc)")
                        .font(.system(size: 22, weight: .heavy, design: .rounded))
                        .foregroundColor(Dash.socColor(d.soc))
                    Text("%")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                }
                .skew(-0.06)

                Rectangle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 1, height: 13)

                numberWithUnit(String(format: "%.2f", d.packV), "V",
                               color: .white.opacity(0.88), size: 13)

                numberWithUnit(String(format: "%+.1f", d.packA), "A",
                               color: d.packA < -0.05 ? theme.accentLight : .white.opacity(0.88),
                               size: 13)

                Spacer(minLength: 0)

                Text("压差 \(Int((d.deltaV * 1000).rounded()))mV")
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.32))
            }

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.085))
                    Rectangle()
                        .fill(Dash.socColor(d.soc))
                        .frame(width: g.size.width * CGFloat(min(max(Double(d.soc) / 100.0, 0), 1)))
                }
            }
            .frame(height: 5)
            .skew(-0.16)
            .clipped()
            .padding(.top, 4)
        }
    }

    /// 数值 + 单位（单位小一号、压暗）
    private func numberWithUnit(_ value: String, _ unit: String,
                                color: Color, size: CGFloat) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 1) {
            Text(value)
                .font(.system(size: size, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
            Text(unit)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.38))
        }
    }

    /// 三个斜切小格：功率 / 相电流（或电机温度）/ 母线电压
    private func cells(_ d: DashData) -> some View {
        let lead: (String, String, CGFloat) = showMotorTemp
            ? ("电机温度", Fmt.temp(d.motorT), Dash.ratio(d.motorT ?? 0, 120))
            : ("相电流", d.phaseA > 0 ? String(format: "%.0f", d.phaseA) : "——",
               Dash.ratio(d.phaseA, 300))

        return HStack(spacing: 7) {
            cell("功率", d.watts > 0 ? String(format: "%.0f", d.watts) : "——", "W",
                 Dash.ratio(d.watts, 4000))
            cell(lead.0, lead.1, lead.0 == "电机温度" ? "" : "A", lead.2)
            cell("母线电压", d.busV > 0 ? String(format: "%.1f", d.busV) : "——", "V",
                 Dash.ratio(d.busV, 84))
        }
    }

    private func cell(_ key: String, _ value: String, _ unit: String, _ p: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(key)
                .font(.system(size: 7.5))
                .tracking(0.6)
                .foregroundColor(.white.opacity(0.40))
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            HStack(alignment: .lastTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 18, weight: .heavy, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .skew(-0.06)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
            .padding(.top, 1)

            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.10))
                    Rectangle()
                        .fill(theme.accent)
                        .frame(width: max(g.size.width * p, 0))
                }
            }
            .frame(height: 3)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.05))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(theme.accent)
                .frame(width: 2)
        }
    }

    // MARK: 右栏：五行「数值 + 进度条」

    private func rightColumn(_ d: DashData) -> some View {
        VStack(spacing: 0) {
            row("母线电流",
                value: String(format: "%.1f", d.busA),
                unit: "A",
                p: Dash.ratio(abs(d.busA), 60),
                color: d.busA < -0.05 ? Dash.ok : theme.accent)

            row("控制器温度",
                value: d.ctrlT.map { String(format: "%.1f", $0) } ?? "——",
                unit: "℃",
                p: Dash.ratio(d.ctrlT ?? 0, 100),
                color: Dash.tempColor(d.ctrlT))

            row("转速",
                value: d.rpm > 0 ? "\(d.rpm)" : "——",
                unit: "rpm",
                p: Dash.ratio(Double(d.rpm), 1200),
                color: theme.accentLight)

            row("定位精度",
                value: d.gpsText,
                unit: "",
                p: d.gpsOk ? Dash.ratio(50 - min(central.gpsAccuracyM, 50), 50) : 0,
                color: d.gpsOk ? Dash.ok : Dash.warn)

            row("故障码",
                value: d.fault == 0 ? "状态良好" : String(format: "0x%04X", d.fault & 0xFFFF),
                unit: "",
                p: 1,
                color: d.fault == 0 ? Dash.ok : Dash.bad,
                dimBar: d.fault == 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 2)
    }

    private func row(_ key: String,
                     value: String,
                     unit: String,
                     p: CGFloat,
                     color: Color,
                     dimBar: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(key)
                    .font(.system(size: 8.5))
                    .tracking(0.6)
                    .foregroundColor(.white.opacity(0.40))
                Spacer(minLength: 4)
                Text(value)
                    .font(.system(size: 16, weight: .heavy, design: .monospaced))
                    .foregroundColor(color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .skew(-0.06)
                if !unit.isEmpty {
                    Text(unit)
                        .font(.system(size: 8.5, weight: .semibold))
                        .foregroundColor(.white.opacity(0.40))
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.085))
                    Rectangle()
                        .fill(color.opacity(dimBar ? 0.35 : 1))
                        .frame(width: max(g.size.width * p, 0))
                }
            }
            .frame(height: 5)
            .skew(-0.16)
            .clipped()
            .padding(.top, 3)
            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
    }

    // MARK: 底栏

    private func footBar(_ d: DashData) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                Circle()
                    .fill(d.gpsOk ? Dash.ok : Dash.warn)
                    .frame(width: 4, height: 4)
                Text(d.source)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundColor(d.gpsOk ? Dash.ok : Dash.warn)
                Text(d.gpsText)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.36))
            }

            Text("本次")
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.34))
            Text(String(format: "%.2f km", d.trip))
                .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                .foregroundColor(.white)

            Spacer(minLength: 0)

            Text(d.hasBms ? "\(d.cells)S · \(d.packT)℃ · 压差 \(Int((d.deltaV * 1000).rounded()))mV"
                          : "电池未连接")
                .font(.system(size: 8, design: .monospaced))
                .foregroundColor(.white.opacity(0.34))
        }
        .padding(.vertical, 5)
    }
}
