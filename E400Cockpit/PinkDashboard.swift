import SwiftUI
import Foundation

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
    @AppStorage(TireModel.Keys.frontPressure) private var frontBar = 2.2
    @AppStorage(TireModel.Keys.rearPressure) private var rearBar = 2.2
    @AppStorage("odo_km") private var odoKm = 0.0

    /// 冲击模型和红黑共用一套（见 RedlineDashboard.swift 里的 RedlineEngine）：
    /// 车速差分出加速度 → E 指数衰减，屏幕上的抖动/闪光都由它驱动。
    @State private var engine = RedlineEngine()
    @State private var appear = false
    @State private var sheet: PinkSheet?
    @State private var lastTrip = 0.0
    @State private var clockText = ""

    private enum PinkSheet: String, Identifiable {
        case bms, console, settings
        var id: String { rawValue }
    }

    private var speed: Double { central.speedKmh }
    private var online: Bool { central.phase == .online }

    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.height / 720, geo.size.width / 1280)
            let w = max(1280, geo.size.width / max(s, 0.001))
            let arc = PinkArc(width: w)

            ZStack {
                Color.black
                backdrop(w: w)

                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    let f = engine.step(at: ctx.date, speed: speed, maxSpeed: maxSpeed)

                    ZStack(alignment: .topLeading) {
                        PinkArcCanvas(arc: arc, vn: f.vn, E: f.E, t: f.t)
                            .frame(width: w, height: 720)

                        scaleNumbers(arc: arc, vn: f.vn)
                        core(f: f, w: w)
                        topBar(f: f, w: w)
                        nosTag(f: f)
                        gearTag(f: f, w: w)
                        logo()
                        menu(f: f)
                        powerBlock(f: f, w: w)
                        tireBlock()
                        batteryBlock(f: f, w: w)
                        odoBlock(w: w)

                        // 冲击：一层粉闪，抖动与缩放在容器上做
                        impactFlash(w: w, E: f.E)
                    }
                    .frame(width: w, height: 720)
                    .offset(x: f.shakeX * 0.36, y: f.shakeY * 0.36)
                    .scaleEffect(s * (1 + f.E * 0.012))
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(Color.black.ignoresSafeArea())
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.3)) { appear = true }
            bms.beginAutoConnect()
            lastTrip = central.tripKm
            tickClock()
        }
        .task {
            // ODO 每 10 秒把「本次里程」的增量并进总里程，避免每帧写 UserDefaults
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let delta = central.tripKm - lastTrip
                if delta > 0.001 {
                    odoKm += delta
                    lastTrip = central.tripKm
                } else if delta < -0.001 {
                    lastTrip = central.tripKm      // 里程被清零
                }
                tickClock()
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .bms:
                BmsDetailView().environmentObject(bms)
            case .console:
                ConsoleView().environmentObject(central).environmentObject(bms)
            case .settings:
                SettingsView().environmentObject(central).environmentObject(bms)
            }
        }
    }

    // MARK: 数据

    private var busV: Double { central.telemetry?.busVoltage ?? 0 }
    private var busA: Double { central.telemetry?.busCurrent ?? 0 }
    private var watts: Double { max(0, busV * busA) }
    private var ctrlT: Double? { central.telemetry?.controllerTemp }
    private var motorT: Double? { central.telemetry?.motorTemp }
    private var gear: String {
        if let g = central.telemetry?.gear, g > 0 { return "\(g)" }
        return speed > 1 ? "F" : "N"
    }

    private var soc: Int { bms.telemetry?.soc ?? 0 }
    private var packTemp: Int { bms.telemetry?.temps.first ?? bms.telemetry?.mosTemp ?? 0 }

    private func tickClock() {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        clockText = f.string(from: Date())
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

    // MARK: 顶栏

    private func topBar(f: RedlineFrame, w: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 0) {
                Text(clockText.isEmpty ? "--:--" : clockText)
                    .font(PN.num(46))
                    .foregroundColor(.white)
                    .fixedSize()

                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(0..<4, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.white.opacity(online ? 0.92 : 0.30))
                            .frame(width: 4.5, height: CGFloat([8, 13, 18, 23][i]))
                    }
                }
                .frame(height: 24)
                .padding(.leading, 32)

                HStack(spacing: 13) {
                    Image(systemName: "bolt.slash")
                        .font(.system(size: 17))
                        .foregroundColor(Color.white.opacity(0.75))
                    Image(systemName: "iphone")
                        .font(.system(size: 18))
                        .foregroundColor(Color(red: 0.30, green: 0.49, blue: 1.0))
                }
                .padding(.leading, 22)

                Spacer(minLength: 12)

                HStack(spacing: 9) {
                    Image(systemName: "cloud")
                        .font(.system(size: 26, weight: .regular))
                        .foregroundColor(.white.opacity(0.9))
                    Text("\(Int(packTemp))°c")
                        .font(PN.num(38, .bold))
                        .foregroundColor(.white)
                }
            }
            .frame(width: max(w - 64, 600), height: 52)
            .offset(x: 34, y: 20)

            Text("READY")
                .font(.system(size: 42, weight: .heavy))
                .tracking(3)
                .foregroundColor(online ? PN.green : Color(red: 0.20, green: 0.31, blue: 0.23))
                .shadow(color: online ? PN.green.opacity(0.55) : .clear, radius: 10)
                .frame(width: 220)
                .position(x: w * 0.39, y: 46)
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

    // MARK: 中央核心

    private func core(f: RedlineFrame, w: CGFloat) -> some View {
        PinkCoreCanvas(vn: f.vn, E: f.E, t: f.t)
            .frame(width: 320, height: 320)
            .offset(x: w / 2 + 72 - 160, y: 308)
    }

    // MARK: NOS / GEAR

    private func nosTag(f: RedlineFrame) -> some View {
        let on = watts > 1500 || f.jolt > 0.5
        return Text("NOS")
            .font(.system(size: 19, weight: .heavy))
            .tracking(8)
            .foregroundColor(on ? PN.hot : .white.opacity(0.42))
            .shadow(color: on ? PN.hot.opacity(0.9) : .clear, radius: 10)
            .offset(x: 396, y: 188)
    }

    private func gearTag(f: RedlineFrame, w: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 9) {
            Text("GEAR")
                .font(.system(size: 15, weight: .bold))
                .tracking(2)
                .foregroundColor(.white.opacity(0.45))
            Text(gear)
                .font(.system(size: 46, weight: .heavy))
                .italic()
                .foregroundColor(PN.red)
                .shadow(color: PN.red.opacity(0.8), radius: 10)
        }
        .offset(x: w - 294, y: 284)
    }

    // MARK: 左下 logo

    private func logo() -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                Text("PINK")
                    .font(.system(size: 50, weight: .heavy))
                    .italic()
                flag
            }
            Text("OVERBOOST.")
                .font(.system(size: 50, weight: .heavy))
                .italic()
        }
        .foregroundColor(.white)
        .skew(-0.14)
        .offset(x: 104, y: 352)
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
        .frame(width: 36, height: 24)
    }

    // MARK: 菜单

    private func menu(f: RedlineFrame) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "circle.circle.fill")
                    .font(.system(size: 13))
                Text("DASHBOARD")
                    .font(.system(size: 19, weight: .heavy))
                    .tracking(2)
                Image(systemName: "play.fill")
                    .font(.system(size: 10))
            }
            .foregroundColor(Color(red: 1.0, green: 0.14, blue: 0.22))
            .shadow(color: PN.red.opacity(0.7), radius: 8)

            row("Time", rideText(f))
            row("Trip", String(format: "%.1fkm", central.tripKm))
        }
        .frame(width: 268, alignment: .leading)
        .offset(x: 420, y: 292)
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.system(size: 15))
                    .foregroundColor(.white.opacity(0.45))
                    .frame(width: 86, alignment: .leading)
                Text(value)
                    .font(PN.num(24, .heavy))
                    .foregroundColor(.white)
                Spacer(minLength: 0)
            }
            .padding(.top, 15)
            .padding(.bottom, 8)

            Rectangle()
                .fill(Color.white.opacity(0.20))
                .frame(height: 1)
        }
    }

    private func rideText(_ f: RedlineFrame) -> String {
        let m = Int(f.ride) / 60
        return "\(m / 60)h \(m % 60)min"
    }

    // MARK: 功率

    private func powerBlock(f: RedlineFrame, w: CGFloat) -> some View {
        VStack(spacing: 2) {
            Text("\(Int(watts.rounded()))")
                .font(PN.num(96))
                .italic()
                .foregroundColor(.white)
                .shadow(color: .white.opacity(0.30), radius: 14)
            Text("W")
                .font(.system(size: 18))
                .tracking(3)
                .foregroundColor(.white.opacity(0.5))
        }
        .frame(width: 190)
        .position(x: w / 2 + 339, y: 424)
    }

    // MARK: 胎压

    private func tireBlock() -> some View {
        HStack(spacing: 52) {
            tire("F", bar: frontBar,
                 temp: ctrlT == nil ? "--" : String(format: "%.0f", ctrlT!))
            tire("R", bar: rearBar,
                 temp: motorT == nil ? "--" : String(format: "%.0f", motorT!))
        }
        .skew(-0.12)
        .frame(width: 420, alignment: .leading)
        .offset(x: 40, y: 618)
    }

    private func tire(_ tag: String, bar: Double, temp: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(tag)
                .font(.system(size: 26, weight: .heavy))
                .foregroundColor(.white)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(String(format: "%.1f", bar))
                        .font(PN.num(33))
                        .foregroundColor(.white)
                    Text("bar")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white.opacity(0.72))
                }
                HStack(alignment: .firstTextBaseline, spacing: 1) {
                    Text(temp)
                        .font(PN.num(19, .regular))
                    Text("°c")
                        .font(.system(size: 12))
                }
                .foregroundColor(.white.opacity(0.60))
            }
        }
    }

    // MARK: 电量 + 车速

    private func batteryBlock(f: RedlineFrame, w: CGFloat) -> some View {
        HStack(spacing: 14) {
            Text("\(soc)%")
                .font(PN.num(44))
                .foregroundColor(.white)

            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    let on = i < Int((Double(20) * Double(soc) / 100).rounded())
                    RoundedRectangle(cornerRadius: 1)
                        .fill(on ? (i >= 17 ? PN.hot : .white) : Color.white.opacity(0.15))
                        .frame(width: 9, height: 19)
                        .shadow(color: on ? (i >= 17 ? PN.hot : .white).opacity(0.45) : .clear,
                                radius: 4)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("\(Int(speed.rounded()))")
                    .font(PN.num(78))
                    .italic()
                    .foregroundColor(.white)
                    .shadow(color: .white.opacity(0.26), radius: 12)
                Text("km")
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
            }
        }
        .offset(x: w / 2 - 194, y: 614)
    }

    // MARK: ODO

    private func odoBlock(w: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("ODO")
                .font(.system(size: 33, weight: .bold))
                .foregroundColor(.white.opacity(0.55))
            Text("\(Int((odoKm + max(0, central.tripKm - lastTrip)).rounded()))")
                .font(PN.num(33, .heavy))
                .foregroundColor(.white)
            Text("km")
                .font(.system(size: 21))
                .foregroundColor(.white.opacity(0.75))
        }
        .frame(width: 320, alignment: .trailing)
        .offset(x: w - 34 - 320, y: 636)
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
            let r2 = CGPoint(x: min(1170, arc.width - 30), y: arc.point(min(1170, arc.width - 30)).y + 94)
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
            let cx = min(max(arc.tickStart + CGFloat(vn) * (arc.tickEnd - arc.tickStart), arc.tickStart), arc.tickEnd)
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

/// 参考图中间是立绘；这里换成一颗全息核心——转得越快、加速越猛，它越亮越大。
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
