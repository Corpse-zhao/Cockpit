import SwiftUI
import UIKit

// MARK: - 粉黑配色

/// 参考图那套「黑底 + 冷白 + 血红 + 粉光」的固定配色。
/// 和红黑一样不吃主题色——这套的味道全在粉黑对比上，换色就散了。
enum PN {
    static let red    = Color(red: 1.00, green: 0.13, blue: 0.20)   // #ff2233
    static let hot    = Color(red: 1.00, green: 0.20, blue: 0.27)   // NOS 亮起
    static let green  = Color(red: 0.24, green: 1.00, blue: 0.39)   // READY
    static let pink   = Color(red: 1.00, green: 0.43, blue: 0.61)
    static let pinkHi = Color(red: 1.00, green: 0.82, blue: 0.90)
    static let ink    = Color(red: 0.98, green: 0.98, blue: 0.98)

    static func num(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - 弧线几何

/// 参考图的顶弧很浅：刻度的**底端**贴着椭圆，数字在刻度的上方。
/// 半径跟着画面宽度走，所以宽屏上这条弧会自然拉开，而不是整体缩放。
private struct PinkArc {
    var width: CGFloat
    var cx: CGFloat { width / 2 }
    var cy: CGFloat = 252
    var ry: CGFloat = 93
    var rx: CGFloat { width / 2 - 20 }

    /// 弧上 x 处的点（只取上半支）
    func point(_ x: CGFloat) -> CGPoint {
        let c = min(max((x - cx) / max(rx, 1), -1), 1)
        return CGPoint(x: x, y: cy - ry * sqrt(max(0, 1 - c * c)))
    }

    var tickStart: CGFloat { 26 }
    var tickEnd: CGFloat { width - 26 }
    var redStart: CGFloat { width * 0.505 }
}

// MARK: - 主视图

struct PinkDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage(PortraitStore.versionKey) private var portraitVersion = 0.0
    @AppStorage(WeatherCenter.enabledKey) private var weatherOn = true

    /// 冲击模型和红黑共用一套（见 RedlineDashboard.swift 里的 RedlineEngine）：
    /// 车速差分出加速度 → E 指数衰减，屏幕上的抖动/闪光都由它驱动。
    @State private var engine = RedlineEngine()
    @ObservedObject private var weather = WeatherCenter.shared

    @State private var appear = false
    @State private var portrait: UIImage?

    var body: some View {
        FullBleedCanvas(backdrop: { w in backdrop(w: w) }) { w, _ in
            let arc = PinkArc(width: w)
            // 横屏 2.37:1，画布按高度缩放到 720，宽度自然涨到 1700 左右。
            // 以前是把各块按 k = w/1280 等比摊开，结果每一块仍然很小、
            // 中间还空出一大片。改成：所有块以画面中线 cx 为基准摆，
            // 左列（logo / 控制器）、中列（立绘 / 菜单）、右列（车速 / 功率）、
            // 底行（电量 / 续航）各自贴着自己的位置，字与块整体放大 ~15%，
            // 左右留白对称，看起来就是「整组放大居中」。
            let cx = w / 2

            ZStack(alignment: .topLeading) {
                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    let f = engine.step(at: ctx.date, speed: speed, maxSpeed: arcMax)

                    ZStack(alignment: .topLeading) {
                        PinkArcCanvas(arc: arc, vn: f.vn, E: f.E, t: f.t)
                            .frame(width: w, height: 720)

                        scaleNumbers(arc: arc, vn: f.vn)
                        coreBlock(f: f, cx: cx)
                        clockView()
                        weatherBadge(w: w)
                        nosTag(f: f, cx: cx)
                        logoView(cx: cx)
                        menuBlock(f: f, cx: cx)
                        speedBlock(f: f, cx: cx)
                        controllerBlock(cx: cx)
                        batteryBlock(cx: cx)
                        powerBlock(cx: cx)
                        impactFlash(w: w, E: f.E)
                    }
                    .frame(width: w, height: 720)
                    .offset(x: f.shakeX * 0.36, y: f.shakeY * 0.36)
                    // 锚点钉左上，撞一下不会整块往右下飘
                    .scaleEffect(1 + f.E * 0.012, anchor: .topLeading)
                }
                .frame(width: w, height: 720)
            }
            .frame(width: w, height: 720, alignment: .topLeading)
        }
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appear = true }
            // 演示模式下别真去连蓝牙，假数据由 DemoPlayer 喂
            if !central.demoMode { bms.beginAutoConnect() }
            portrait = PortraitStore.image ?? UIImage(named: "portrait_default")
            weather.start()
        }
        .onDisappear { weather.stop() }
        .onChange(of: portraitVersion) { _ in
            portrait = PortraitStore.image ?? UIImage(named: "portrait_default")
        }
    }

    // MARK: 数据

    private var speed: Double { central.speedKmh }
    private var online: Bool { central.phase == .online || central.demoMode }

    /// 顶部 0–9 刻度的满量程。这台车实际跑不到 160，量程一拉到 160
    /// 整条弧就有 1/8 永远点不亮、0–120 全挤在左边，所以弧线固定按 140 走。
    /// 设置里 160 那个选项仍旧保留（红黑 / 霓虹按用户选的量程走）。
    private var arcMax: Double { min(maxSpeed, 140) }

    /// 弧线下面那一行（LOGO / 菜单 / 车速）共用的对齐带。
    /// 之前三块各自按自己的高度从顶部往下排，中线差了 20~30，看着是歪的；
    /// 现在统一塞进同一条 180 高的带子里垂直居中，三块的中线就齐了。
    private static let bandTop: CGFloat = 246
    private static let bandH: CGFloat = 180

    private var busV: Double { central.telemetry?.busVoltage ?? 0 }
    private var busA: Double { central.telemetry?.busCurrent ?? 0 }
    private var watts: Double { max(0, busV * busA) }
    private var ctrlT: Double? { central.telemetry?.controllerTemp }
    private var motorT: Double? { central.telemetry?.motorTemp }
    private var rpm: Int { central.telemetry?.rpm ?? 0 }

    private var soc: Int { bms.telemetry?.soc ?? 0 }

    /// 预估续航按用户口径：剩余容量 Ah × 1.5km。
    /// BMS 没给剩余容量就退回「额定容量 × SOC」，两个都没有就显示 --。
    private var rangeKm: Int? {
        var ah: Double?
        if let a = bms.telemetry?.remainingAh, a > 0 {
            ah = a
        } else if let cap = bms.telemetry?.capacityAh, cap > 0 {
            ah = cap * Double(soc) / 100.0
        }
        guard let v = ah else { return nil }
        return Int((v * 1.5).rounded())
    }

    private func tempText(_ v: Double?) -> String {
        guard let v = v else { return "--" }
        return String(format: "%.0f", v)
    }

    // MARK: 冲击闪光

    private func impactFlash(w: CGFloat, E: Double) -> some View {
        let cols: [Color] = [PN.pink.opacity(0.55), PN.red.opacity(0.20), Color.clear]
        return Rectangle()
            .fill(RadialGradient(colors: cols,
                                 center: UnitPoint(x: 0.52, y: 0.62),
                                 startRadius: 4, endRadius: 520))
            .frame(width: w, height: 720)
            .opacity(E * 0.13)
            .blendMode(.screen)
            .allowsHitTesting(false)
    }

    // MARK: 底

    private func backdrop(w: CGFloat) -> some View {
        ZStack {
            RadialGradient(colors: [Color(red: 1.0, green: 0.27, blue: 0.51).opacity(0.13), .clear],
                           center: UnitPoint(x: 0.52, y: 0.66),
                           startRadius: 10, endRadius: 520)
            RadialGradient(colors: [Color(red: 1.0, green: 0.16, blue: 0.35).opacity(0.10), .clear],
                           center: UnitPoint(x: 0.5, y: 1.12),
                           startRadius: 20, endRadius: 700)
            Canvas { ctx, size in
                var p = Path()
                var y: CGFloat = 0
                while y < size.height {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    y += 3
                }
                ctx.stroke(p, with: .color(.white.opacity(0.035)), lineWidth: 1)
            }
            .blendMode(.overlay)

            RadialGradient(colors: [.clear, .black.opacity(0.92)],
                           center: .center, startRadius: 210, endRadius: 760)
        }
        .frame(width: w, height: 720)
        .clipped()
    }

    // MARK: 左上角时间

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private func clockView() -> some View {
        TimelineView(.everyMinute) { ctx in
            Text(Self.clockFormatter.string(from: ctx.date))
                .font(PN.num(46))
                .foregroundColor(.white)
                .fixedSize()
        }
        .offset(x: 34, y: 18)
    }

    // MARK: 右上角天气

    @ViewBuilder
    private func weatherBadge(w: CGFloat) -> some View {
        if weatherOn {
            HStack(spacing: 9) {
                Image(systemName: WeatherCenter.symbol(for: weather.code))
                    .font(.system(size: 24, weight: .regular))
                    .foregroundColor(.white.opacity(weather.code == nil ? 0.35 : 0.92))
                Text(weather.tempText)
                    .font(PN.num(36, .bold))
                    .foregroundColor(.white.opacity(weather.temp == nil ? 0.40 : 1))
            }
            .frame(width: 200, alignment: .trailing)
            .offset(x: w - 34 - 200, y: 20)
        }
    }

    // MARK: 0–9 刻度数字

    private func scaleNumbers(arc: PinkArc, vn: Double) -> some View {
        let cur = vn * 9
        return ForEach(0..<10, id: \.self) { k in
            let t = Double(k) / 9.0
            let x = arc.width * 0.078 + CGFloat(t) * (arc.width * 0.849 - arc.width * 0.078)
            let p = arc.point(x)
            let red = x > arc.redStart
            let near = abs(Double(k) - cur) < 0.5
            Text("\(k)")
                .font(.system(size: 33, weight: .heavy))
                .italic()
                .foregroundColor(near ? (red ? PN.hot : .white) : (red ? PN.red : .white))
                .opacity(near ? 1 : (Double(k) < cur ? 0.78 : 0.34))
                .position(x: x, y: p.y - 44)
        }
    }

    // MARK: 中央立绘 / 核心

    @ViewBuilder
    private func coreBlock(f: RedlineFrame, cx: CGFloat) -> some View {
        if let img = portrait {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(width: 330, height: 396)
                .shadow(color: PN.pink.opacity(0.30), radius: 26)
                .opacity(0.94)
                .offset(x: cx - 20,
                        y: 204 - CGFloat(sin(f.t * 1.6)) * 2 - CGFloat(f.E) * 5)
        } else {
            PinkCoreCanvas(vn: f.vn, E: f.E, t: f.t)
                .frame(width: 330, height: 330)
                .offset(x: cx - 165, y: 250)
        }
    }

    // MARK: NOS

    private func nosTag(f: RedlineFrame, cx: CGFloat) -> some View {
        let on = watts > 1500 || f.jolt > 0.5
        return Text("NOS")
            .font(.system(size: 21, weight: .heavy))
            .tracking(8)
            .foregroundColor(on ? PN.hot : .white.opacity(0.42))
            .shadow(color: on ? PN.hot.opacity(0.9) : .clear, radius: 10)
            .offset(x: cx - 262, y: 196)
    }

    // MARK: 左下 logo

    private func logoView(cx: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("PINK")
                    .font(.system(size: 54, weight: .heavy))
                    .italic()
                flag
            }
            Text("OVERBOOST.")
                .font(.system(size: 54, weight: .heavy))
                .italic()
        }
        .foregroundColor(.white)
        .frame(width: 380, height: Self.bandH, alignment: .leading)
        .skew(-0.14)
        .offset(x: cx - 685, y: Self.bandTop)
    }

    private var flag: some View {
        VStack(spacing: 0) {
            ForEach(0..<3, id: \.self) { r in
                HStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { c in
                        Rectangle()
                            .fill((r + c) % 2 == 0 ? Color.white : Color.black)
                            .frame(width: 9, height: 8)
                    }
                }
            }
        }
        .frame(width: 37, height: 24)
    }

    // MARK: 菜单

    private func menuBlock(f: RedlineFrame, cx: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 14))
                Text("DASHBOARD")
                    .font(.system(size: 21, weight: .heavy))
                    .tracking(2)
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
            }
            .foregroundColor(PN.red)
            .shadow(color: PN.red.opacity(0.7), radius: 8)

            row("时间", rideText(f))
            row("里程", String(format: "%.1fkm", central.tripKm))
        }
        .frame(width: 300, height: Self.bandH, alignment: .leading)
        .offset(x: cx - 340, y: Self.bandTop)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(label)
                    .font(.system(size: 17))
                    .tracking(1)
                    .foregroundColor(.white.opacity(0.55))
                    .shadow(color: .black.opacity(0.95), radius: 4, y: 1)
                    .frame(width: 72, alignment: .leading)
                Text(value)
                    .font(PN.num(31, .heavy))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.95), radius: 5, y: 1)
                Spacer(minLength: 0)
            }
            .padding(.top, 18)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(height: 1)
        }
    }

    private func rideText(_ f: RedlineFrame) -> String {
        let total = Int(f.ride) / 60
        return "\(total / 60)小时\(total % 60)分"
    }

    // MARK: 车速（右上）

    private func speedBlock(f: RedlineFrame, cx: CGFloat) -> some View {
        VStack(spacing: 0) {
            Text("\(Int(speed.rounded()))")
                .font(PN.num(124))
                .italic()
                .foregroundColor(.white)
                .shadow(color: .black.opacity(0.80), radius: 10, y: 2)
                .scaleEffect(1 + f.E * 0.05)

            Text("km/h")
                .font(.system(size: 23, weight: .bold))
                .tracking(3)
                .foregroundColor(.white.opacity(0.50))
                .padding(.top, 4)
        }
        .frame(width: 250, height: Self.bandH)
        .offset(x: cx + 415, y: Self.bandTop)
    }

    // MARK: 右下：功率 / 转速

    /// 底行右侧那一格。以前和速度挤在一列，右下一大片是空的；
    /// 拆出来之后底行从左到右读过去是「电气 → 电池 → 功率」，和参考图一致。
    private func powerBlock(cx: CGFloat) -> some View {
        HStack(spacing: 0) {
            pair("功率", "\(Int(watts.rounded()))", "W")
            pair("转速", "\(rpm)", "r/min")
        }
        .frame(width: 250)
        .offset(x: cx + 415, y: 598)
    }

    private func pair(_ label: String, _ value: String, _ unit: String) -> some View {
        VStack(spacing: 3) {
            Text(label)
                .font(.system(size: 14))
                .tracking(1)
                .foregroundColor(.white.opacity(0.66))
                .shadow(color: .black.opacity(0.95), radius: 4, y: 1)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(PN.num(38))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.90), radius: 5, y: 1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                Text(unit)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(.white.opacity(0.62))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: 左下控制器

    private func controllerBlock(cx: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                cell("电压", String(format: "%.1f", busV), "V")
                cell("电流", String(format: "%.1f", busA), "A")
            }
            HStack(alignment: .firstTextBaseline, spacing: 30) {
                cell("控温", tempText(ctrlT), "°c")
                cell("电机", tempText(motorT), "°c")
            }
        }
        .skew(-0.12)
        .offset(x: cx - 675, y: 578)
    }

    private func cell(_ label: String, _ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(label)
                .font(.system(size: 15))
                .tracking(1)
                .foregroundColor(.white.opacity(0.55))
            Text(value)
                .font(PN.num(42))
                .foregroundColor(.white)
            if !unit.isEmpty {
                Text(unit)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(.white.opacity(0.60))
            }
        }
    }

    // MARK: 底栏：电量 + 续航

    private func batteryBlock(cx: CGFloat) -> some View {
        HStack(alignment: .bottom, spacing: 16) {
            VStack(alignment: .leading, spacing: 1) {
                Text("电量")
                    .font(.system(size: 13))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.50))
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("\(soc)")
                        .font(PN.num(54))
                        .foregroundColor(.white)
                    Text("%")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundColor(.white.opacity(0.55))
                }
            }

            segmentBar

            VStack(alignment: .leading, spacing: 1) {
                Text("续航")
                    .font(.system(size: 13))
                    .tracking(2)
                    .foregroundColor(.white.opacity(0.50))
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text(rangeKm.map { "\($0)" } ?? "--")
                        .font(PN.num(74))
                        .italic()
                        .foregroundColor(.white)
                        .shadow(color: .white.opacity(0.24), radius: 18)
                    Text("km")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(.white.opacity(0.55))
                }
            }
        }
        .offset(x: cx - 185, y: 602)
    }

    private var segmentBar: some View {
        HStack(spacing: 3) {
            ForEach(0..<20, id: \.self) { i in
                let lit = i < litSegments
                let hot = i >= 17
                RoundedRectangle(cornerRadius: 1)
                    .fill(lit ? (hot ? PN.hot : Color.white) : Color.white.opacity(0.15))
                    .frame(width: 11, height: 23)
                    .shadow(color: lit ? (hot ? PN.hot : Color.white).opacity(0.45) : Color.clear,
                            radius: 4)
            }
        }
    }

    private var litSegments: Int {
        Int((20.0 * Double(soc) / 100.0).rounded())
    }
}

// MARK: - 顶弧（刻度 + 罩形 + 彗星）

private struct PinkArcCanvas: View {
    var arc: PinkArc
    var vn: Double
    var E: Double
    var t: Double

    private static let count = 132

    var body: some View {
        Canvas { ctx, _ in
            let n = Self.count
            for i in 0..<n {
                let k = Double(i) / Double(n - 1)
                let x = arc.tickStart + (arc.tickEnd - arc.tickStart) * CGFloat(k)
                let p = arc.point(x)
                var len: CGFloat = 26 + 7 * CGFloat(sin(Double.pi * k))
                if i % 4 == 0 { len += 5 }

                let lit = k <= vn
                let lead = abs(k - vn) < 0.010
                var op = lit ? (0.62 + k * 0.34) : (0.16 + k * 0.08)
                if lead { op = 1 }
                op = min(1, op + E * 0.2)

                let red = x > arc.redStart
                let color: Color = lead ? .white : (red ? PN.red : .white)

                var path = Path()
                path.move(to: p)
                path.addLine(to: CGPoint(x: p.x, y: p.y - len))
                ctx.stroke(path, with: .color(color.opacity(op)), lineWidth: 2.6)
            }

            // 左罩形：沿刻度底走，收在 NOS
            var canopy = Path()
            let tail = arc.point(56)
            canopy.move(to: CGPoint(x: 10, y: tail.y + 74))
            canopy.addLine(to: CGPoint(x: 22, y: tail.y + 37))
            var x: CGFloat = 56
            while x <= 392 {
                canopy.addLine(to: CGPoint(x: x, y: arc.point(x).y + 9))
                x += 14
            }
            ctx.stroke(canopy, with: .color(.white.opacity(0.95)),
                       style: StrokeStyle(lineWidth: 4.6, lineCap: .round, lineJoin: .round))

            var canopy2 = Path()
            var x2: CGFloat = 56
            canopy2.move(to: CGPoint(x: 10, y: tail.y + 88))
            while x2 <= 330 {
                canopy2.addLine(to: CGPoint(x: x2, y: arc.point(x2).y + 22))
                x2 += 14
            }
            ctx.stroke(canopy2, with: .color(.white.opacity(0.42)), lineWidth: 1.8)

            // 右罩形：红，末端下垂
            var redLine = Path()
            let r0 = arc.point(arc.redStart)
            let r1 = arc.point(min(1010, arc.width - 40))
            let r2 = CGPoint(x: min(1170, arc.width - 30),
                             y: arc.point(min(1170, arc.width - 30)).y + 94)
            redLine.move(to: CGPoint(x: r0.x, y: r0.y + 18))
            redLine.addLine(to: CGPoint(x: r1.x, y: r1.y + 20))
            redLine.addCurve(to: r2,
                             control1: CGPoint(x: r1.x + 70, y: r1.y + 24),
                             control2: CGPoint(x: r2.x - 40, y: r2.y - 42))
            ctx.stroke(redLine, with: .color(PN.red.opacity(0.62)), lineWidth: 3.2)

            // 底部托弧
            var footL = Path()
            footL.move(to: CGPoint(x: 46, y: 486))
            footL.addCurve(to: CGPoint(x: 322, y: 520),
                           control1: CGPoint(x: 140, y: 512),
                           control2: CGPoint(x: 240, y: 520))
            ctx.stroke(footL, with: .color(.white.opacity(0.5)), lineWidth: 2.4)

            var footR = Path()
            footR.move(to: CGPoint(x: arc.width - 46, y: 486))
            footR.addCurve(to: CGPoint(x: arc.width - 322, y: 520),
                           control1: CGPoint(x: arc.width - 140, y: 512),
                           control2: CGPoint(x: arc.width - 240, y: 520))
            ctx.stroke(footR, with: .color(.white.opacity(0.5)), lineWidth: 2.4)

            // 彗星
            let cx = min(max(arc.tickStart + CGFloat(vn) * (arc.tickEnd - arc.tickStart),
                             arc.tickStart), arc.tickEnd)
            let cp = arc.point(cx)
            var comet = Path()
            comet.addEllipse(in: CGRect(x: cp.x - 4, y: cp.y - 10, width: 8, height: 8))
            ctx.fill(comet, with: .color(.white.opacity(0.3 + vn * 0.7)))
        }
        .frame(width: arc.width, height: 720)
        .allowsHitTesting(false)
    }
}

// MARK: - 中央全息核心

/// 没设立绘时的替身：转得越快、加速越猛，它越亮越大。
private struct PinkCoreCanvas: View {
    var vn: Double
    var E: Double
    var t: Double

    var body: some View {
        Canvas { ctx, _ in
            let c = CGPoint(x: 160, y: 160)
            let spin = t * (24 + vn * 110)

            // 光圈
            var halo = Path()
            halo.addEllipse(in: CGRect(x: c.x - 150, y: c.y - 150, width: 300, height: 300))
            ctx.fill(halo, with: .radialGradient(
                Gradient(colors: [PN.pink.opacity(0.30), PN.red.opacity(0)]),
                center: c, startRadius: 40, endRadius: 150))

            // 底盘
            var disc = Path()
            disc.addEllipse(in: CGRect(x: c.x - 124, y: c.y - 124, width: 248, height: 248))
            ctx.fill(disc, with: .radialGradient(
                Gradient(colors: [Color(red: 0.16, green: 0.02, blue: 0.07).opacity(0.94),
                                  Color(red: 0.08, green: 0.01, blue: 0.04).opacity(0.88),
                                  Color(red: 0.04, green: 0.00, blue: 0.02).opacity(0.55)]),
                center: c, startRadius: 0, endRadius: 124))

            // 三层六边形
            hex(ctx, center: c, r: 128 + CGFloat(E * 7), rot: spin * 0.22,
                color: PN.pink.opacity(0.85), width: 1.8)
            hex(ctx, center: c, r: 108 + CGFloat(sin(t * 1.8)) * 4, rot: -spin * 0.36,
                color: PN.pink.opacity(0.30 + 0.35 * abs(sin(t * 2.0))), width: 1.2)
            hex(ctx, center: c, r: 145 + CGFloat(cos(t * 1.1)) * 5, rot: spin * 0.10,
                color: PN.pink.opacity(0.35), width: 1.2, dashed: true)

            // 辐条
            for i in 0..<12 {
                let a = (spin * 0.8 + Double(i) * 30) * .pi / 180
                var p = Path()
                p.move(to: CGPoint(x: c.x + 74 * CGFloat(cos(a)), y: c.y + 74 * CGFloat(sin(a))))
                p.addLine(to: CGPoint(x: c.x + 118 * CGFloat(cos(a)), y: c.y + 118 * CGFloat(sin(a))))
                ctx.stroke(p, with: .color(PN.pink.opacity(0.10 + 0.22 * abs(sin(t * 1.6 + Double(i) * 0.5)))),
                           lineWidth: 1)
            }

            // 核心球
            let br = 56 + CGFloat(E * 7) + CGFloat(sin(t * 2.4)) * 1.6
            var ball = Path()
            ball.addEllipse(in: CGRect(x: c.x - br, y: c.y - br, width: br * 2, height: br * 2))
            ctx.fill(ball, with: .radialGradient(
                Gradient(colors: [PN.pinkHi, PN.pink, PN.red.opacity(0)]),
                center: c, startRadius: 0, endRadius: br))
            ctx.stroke(ball, with: .color(PN.pink.opacity(0.55)), lineWidth: 1)

            // 轨道粒子
            for i in 0..<14 {
                let a = (spin * 0.9 + Double(i) * (360.0 / 14.0)) * .pi / 180
                let rr = 96 + 26 * sin(t * 1.3 + Double(i) * 0.7)
                var p = Path()
                p.addEllipse(in: CGRect(x: c.x + CGFloat(rr * cos(a)) - 1.8,
                                        y: c.y + CGFloat(rr * sin(a)) - 1.8,
                                        width: 3.6, height: 3.6))
                ctx.fill(p, with: .color(PN.pinkHi.opacity(0.2 + 0.55 * abs(sin(t * 2 + Double(i))))))
            }
        }
        .allowsHitTesting(false)
    }

    private func hex(_ ctx: GraphicsContext, center: CGPoint, r: CGFloat,
                     rot: Double, color: Color, width: CGFloat, dashed: Bool = false) {
        var p = Path()
        for i in 0..<6 {
            let a = (Double(i) * 60 - 90 + rot) * .pi / 180
            let pt = CGPoint(x: center.x + r * CGFloat(cos(a)), y: center.y + r * CGFloat(sin(a)))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        p.closeSubpath()
        ctx.stroke(p, with: .color(color),
                   style: StrokeStyle(lineWidth: width,
                                      lineCap: .round,
                                      dash: dashed ? [5, 9] : []))
    }
}
