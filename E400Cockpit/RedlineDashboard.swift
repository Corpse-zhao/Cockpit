import SwiftUI
import Foundation

// MARK: - 红黑配色

/// 红黑 HUD 用的是「固定色」，不吃主题色。
/// 这套样式的卖点就是那一抹血红 + 冷白巨字，换色反而会散掉，所以这里全部写死。
enum RL {
    static let red     = Color(red: 1.00, green: 0.20, blue: 0.28)   // #ff3348
    static let redSoft = Color(red: 1.00, green: 0.42, blue: 0.50)
    static let green   = Color(red: 0.26, green: 0.94, blue: 0.51)   // #43f07e
    static let cyan    = Color(red: 0.26, green: 0.89, blue: 0.95)
    static let amber   = Color(red: 1.00, green: 0.63, blue: 0.16)
    static let violet  = Color(red: 0.92, green: 0.25, blue: 1.00)
    static let ink     = Color(red: 0.98, green: 0.96, blue: 0.95)

    /// 大数字用的字体：SF Rounded Heavy 最接近参考片里的 Bahnschrift 粗斜体
    static func num(_ size: CGFloat, _ weight: Font.Weight = .heavy) -> Font {
        .system(size: size, weight: weight, design: .rounded).monospacedDigit()
    }
}

// MARK: - 确定性伪随机

/// 残影线 / 放射粒子每帧都要算位置，随机种子必须稳定，
/// 不然每帧重新随机一次，画面会变成雪花噪点而不是「线」。
private func rlRand(_ i: Int, _ salt: Int) -> Double {
    var x = UInt64(bitPattern: Int64(i &* 1103515245 &+ salt &* 12345 &+ 1))
    x = (x ^ (x >> 30)) &* 0xbf58476d1ce4e5b9
    x = (x ^ (x >> 27)) &* 0x94d049bb133111eb
    x = x ^ (x >> 31)
    return Double(x % 1_000_000) / 1_000_000.0
}

// MARK: - 一帧的冲击状态

/// 每帧算一次、全页共用。纯值，方便传给各个 Canvas。
struct RedlineFrame {
    var t: Double = 0
    var speed: Double = 0
    var vn: Double = 0          // 车速 / 满量程
    var accel: Double = 0       // km/h per s（正=加速）
    var jolt: Double = 0        // 0…1 瞬时冲击
    var E: Double = 0           // 冲击能量（τ≈0.20s）
    var E2: Double = 0          // 撕裂能量（τ≈0.055s）
    var D: Double = 0           // 减速能量
    var shakeX: Double = 0
    var shakeY: Double = 0
    var zoom: Double = 1
    var sweep: Double = 0       // 雷达扫描角
    var ride: Double = 0        // 骑行秒数
    var shockAges: [Double] = [9, 9]
}

/// 冲击模型。核心就一句：对车速做差分得到瞬时加速度，
/// 加速度越大「冲击能量」越高，然后按指数衰减——屏幕上所有抖动、撕裂、
/// 冲击波、粒子扩散都由这一个 E 驱动，所以才会「一起炸、一起散」。
final class RedlineEngine {
    private var lastSpeed = 0.0
    private var lastTime: Date?
    private var accelEMA = 0.0
    private var E = 0.0
    private var E2 = 0.0
    private var D = 0.0
    private var sweep = 0.0
    private var ride = 0.0
    private var shockCool = 0.0
    private var shocks: [Double] = [9, 9]
    private var cached: RedlineFrame?

    func step(at date: Date, speed: Double, maxSpeed: Double) -> RedlineFrame {
        let t = date.timeIntervalSinceReferenceDate
        let raw = lastTime.map { t - $0.timeIntervalSinceReferenceDate } ?? (1.0 / 60.0)
        let dt = min(max(raw, 0.0), 0.1)

        // 同一帧里 body 可能被算好几次（数据刷新也会触发重算）。
        // dt 太小时 dv/dt 会被放大成假加速度，这里直接吐上一帧，只等下一个真正的刷新点。
        if dt < 0.010, let cached = cached {
            return cached
        }
        lastTime = date

        // 控制器帧大概 7～10 Hz，直接差分会有锯齿，用指数平滑压一下
        let dv = speed - lastSpeed
        lastSpeed = speed
        let inst = dt > 0.0001 ? dv / dt : 0
        let clamped = min(max(inst, -140.0), 140.0)
        accelEMA = accelEMA * 0.62 + clamped * 0.38
        let a = accelEMA

        // 30 km/h/s ≈ 满格冲击：0→50 三秒的车，中段就能吃到 0.8 以上
        let jolt = min(max(a / 30.0, 0.0), 1.0)
        let slam = min(max(-a / 45.0, 0.0), 1.0)

        E  = max(E  * exp(-dt / 0.20), jolt)
        D  = max(D  * exp(-dt / 0.28), slam)
        E2 = max(E2 * exp(-dt / 0.055), jolt > 0.55 ? 1.0 : 0.0)

        shockCool -= dt
        if jolt > 0.42 && shockCool <= 0 {
            shockCool = 0.18
            let slot = shocks[0] > shocks[1] ? 0 : 1
            shocks[slot] = 0
        }
        for i in 0..<2 { shocks[i] += dt }

        sweep = (sweep + dt * (150 + E * 300)).truncatingRemainder(dividingBy: 360)
        if speed > 1.0 { ride += dt }

        let shakeX = sin(t * 71) * E * 7.2 + (Double.random(in: -0.5...0.5)) * E2 * 5.0
        let shakeY = cos(t * 59) * E * 5.2

        let frame = RedlineFrame(
            t: t,
            speed: speed,
            vn: min(max(speed / max(maxSpeed, 1), 0), 1),
            accel: a,
            jolt: jolt,
            E: E,
            E2: E2,
            D: D,
            shakeX: shakeX,
            shakeY: shakeY,
            zoom: 1 + E * 0.034,
            sweep: sweep,
            ride: ride,
            shockAges: shocks
        )
        cached = frame
        return frame
    }
}

// MARK: - 斜梯几何

/// 参考片里那根「速度楼梯」：左下往右上斜 24.4°，26 根横档，顶端红色压条。
private enum RLLad {
    static let bx: CGFloat = 50
    static let by: CGFloat = 320
    static let len: CGFloat = 290
    static let width: CGFloat = 56
    static let count = 26
    static let angle = 24.4 * Double.pi / 180

    static var top: CGPoint {
        CGPoint(x: bx + CGFloat(sin(angle)) * len,
                y: by - CGFloat(cos(angle)) * len)
    }

    /// 沿梯子某个比例处的中心点
    static func point(_ f: Double) -> CGPoint {
        CGPoint(x: bx + (top.x - bx) * CGFloat(f),
                y: by + (top.y - by) * CGFloat(f))
    }
}

// MARK: - 主视图

struct RedlineDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    /// 车名。空着就显示「我的车」，设置页 → 车型 里改
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0

    @State private var engine = RedlineEngine()
    @State private var appear = false
    @State private var sheet: RedlineSheet?

    private enum RedlineSheet: String, Identifiable {
        case bms, console, settings
        var id: String { rawValue }
    }

    private var speed: Double { central.speedKmh }
    private var phaseOnline: Bool { central.phase == .online }

    var body: some View {
        // 铺满逻辑统一收进 FullBleedCanvas：设计稿 1280×720，
        // 画布宽度按容器反推（横屏 iPhone 比 16:9 宽，硬缩放就会左右留黑边）。
        FullBleedCanvas { w, _ in
            let dx = (w - 1280) / 2          // 中间那一组（斜梯+巨字+雷达）居中
            let rx = w - 1280                // 右列贴右边

            ZStack(alignment: .topLeading) {
                Color.black

                RedlineBackdrop(width: w)
                    .frame(width: w, height: 720)

                TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { ctx in
                    let f = engine.step(at: ctx.date, speed: speed, maxSpeed: maxSpeed)

                    ZStack(alignment: .topLeading) {
                        // —— 动起来的背景 ——
                        StreakCanvas(f: f, width: w)
                        bloom(f: f, dx: dx)
                        sweepBand(t: f.t, width: w)

                        // —— 内容 ——
                        topBar(f: f, width: w)
                        batteryBlock(f: f)
                        ladderBlock(f: f, dx: dx)
                        speedBlock(f: f, dx: dx)
                        radarBlock(f: f, dx: dx)
                        powerRing(f: f, rx: rx)
                        tempRing(f: f, rx: rx)
                        gRow(f: f, width: w)
                        dataRow(f: f)
                        tabStrip(rx: rx)

                        // —— 冲击特效（盖在最上层）——
                        impactLayers(f: f, width: w)
                    }
                    .frame(width: w, height: 720)
                    .offset(x: f.shakeX, y: f.shakeY)
                    // 缩放锚点也在左上：以中心为锚的话，撞一下整块画面会往右下飘
                    .scaleEffect(f.zoom, anchor: .topLeading)
                }
                .frame(width: w, height: 720)
            }
            .frame(width: w, height: 720, alignment: .topLeading)
        }
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.30)) { appear = true }
            bms.beginAutoConnect()
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .bms:
                BmsDetailView().environmentObject(bms)
            case .console:
                ConsoleView()
                    .environmentObject(central)
                    .environmentObject(bms)
            case .settings:
                SettingsView()
                    .environmentObject(central)
                    .environmentObject(bms)
            }
        }
    }

    // MARK: 数据摘取

    private var busV: Double { central.telemetry?.busVoltage ?? 0 }
    private var busA: Double { central.telemetry?.busCurrent ?? 0 }
    private var phaseA: Double { central.telemetry?.phaseCurrentInferred ?? 0 }
    private var rpm: Double { Double(central.telemetry?.rpm ?? 0) }
    private var kw: Double { max(0, busV * busA / 1000.0) }
    private var ctrlT: Double? { central.telemetry?.controllerTemp }
    private var motorT: Double? { central.telemetry?.motorTemp }

    private var soc: Int { bms.telemetry?.soc ?? 0 }
    private var packV: Double { bms.telemetry?.packVoltage ?? 0 }
    private var remainAh: Double { bms.telemetry?.remainingAh ?? 0 }
    private var deltaMV: Double { (bms.telemetry?.deltaV ?? 0) * 1000 }
    private var packW: Double { abs(bms.telemetry?.power ?? 0) }

    // MARK: 顶栏

    private func topBar(f: RedlineFrame, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            HStack(spacing: 9) {
                Circle()
                    .fill(phaseOnline ? RL.green : RL.red)
                    .frame(width: 8, height: 8)
                    .shadow(color: (phaseOnline ? RL.green : RL.red).opacity(0.8), radius: 5)

                Text(vehicleLabel.isEmpty ? "我的车" : vehicleLabel)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.trailing, 2)

                pill("已连接", color: RL.redSoft, bg: RL.red, on: phaseOnline)
                pill("保护板", color: RL.green, bg: RL.green, on: bms.telemetry != nil)

                Spacer(minLength: 12)

                signalBars
                purpleBar(fill: f.vn)
            }
            .frame(width: max(width - 50, 400), height: 24)
            .offset(x: 26, y: 14)

            // 第二行导航：参考片里是固定的几项，这里保留原样，只有「仪表」是亮的
            HStack(spacing: 0) {
                ForEach(["仪表", "设置", "数据", "导航", "能量回收", "其他"], id: \.self) { item in
                    Text(item)
                        .font(.system(size: 11))
                        .tracking(1.5)
                        .foregroundColor(item == "仪表"
                                         ? Color.white.opacity(0.95)
                                         : Color.white.opacity(0.24))
                        .padding(.horizontal, 16)
                }
            }
            .frame(width: width, height: 22)
            .offset(y: 45)
        }
    }

    private func pill(_ text: String, color: Color, bg: Color, on: Bool) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .bold))
            .tracking(0.8)
            .foregroundColor(on ? color : Color.white.opacity(0.26))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Rectangle().fill(on ? bg.opacity(0.26) : Color.white.opacity(0.05)))
            .overlay(Rectangle().stroke(on ? color.opacity(0.90) : Color.white.opacity(0.12),
                                        lineWidth: 1))
            .shadow(color: on ? color.opacity(0.35) : .clear, radius: 6)
    }

    private var signalBars: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(0..<5, id: \.self) { i in
                let tall: CGFloat = [4, 6, 8.5, 11, 13][i]
                let c = i == 4 ? RL.green : RL.amber
                RoundedRectangle(cornerRadius: 0.7)
                    .fill(c)
                    .frame(width: 3.4, height: tall)
                    .opacity(phaseOnline ? 1 : 0.28)
                    .shadow(color: c.opacity(0.7), radius: 3)
            }
        }
        .frame(height: 13)
    }

    private func purpleBar(fill: Double) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 3)
                .fill(RL.violet.opacity(0.26))
                .overlay(RoundedRectangle(cornerRadius: 3)
                    .stroke(RL.violet.opacity(0.95), lineWidth: 1))
            RoundedRectangle(cornerRadius: 2)
                .fill(RL.violet)
                .frame(width: 44, height: 15)
                .offset(x: 2 + CGFloat(fill) * 100)
                .shadow(color: RL.violet.opacity(0.9), radius: 8)
        }
        .frame(width: 150, height: 19)
        .opacity(0.55 + fill * 0.45)
        .shadow(color: RL.violet.opacity(0.45), radius: 8)
    }

    // MARK: 左：电池环

    private func batteryBlock(f: RedlineFrame) -> some View {
        let socText = bms.telemetry == nil ? "--" : "\(soc)"

        return ZStack(alignment: .topLeading) {
            RLBatteryRing(soc: soc, t: f.t)
                .frame(width: 210, height: 210)

            HStack(alignment: .firstTextBaseline, spacing: 1) {
                Text(socText)
                    .font(RL.num(52))
                    .foregroundColor(bms.telemetry == nil ? RL.ink.opacity(0.35) : RL.green)
                    .shadow(color: RL.green.opacity(0.65), radius: 14)
                Text("%")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(RL.green.opacity(0.9))
            }
            .skew(-0.10)
            .frame(width: 210, height: 62)
            .offset(y: 52)

            Text(String(format: "%.1f Ah", remainAh))
                .font(.system(size: 16))
                .foregroundColor(RL.ink)
                .frame(width: 210, height: 20)
                .offset(y: 138)

            Text("电 池")
                .font(.system(size: 13))
                .tracking(5)
                .foregroundColor(RL.ink.opacity(0.82))
                .frame(width: 210, height: 18)
                .offset(y: 200)

            HStack(spacing: 6) {
                Text(String(format: "%.1f V", packV))
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundColor(RL.ink)
                Text("压差")
                    .font(.system(size: 11.5))
                    .foregroundColor(RL.ink.opacity(0.5))
                Text(String(format: "%.0f mV", deltaMV))
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(RL.amber)
                    .shadow(color: RL.amber.opacity(0.45), radius: 5)
            }
            .frame(width: 258, height: 18)
            .offset(x: -24, y: 226)

            // 电池环点一下看明细
            Color.clear
                .frame(width: 210, height: 210)
                .contentShape(Rectangle())
                .onTapGesture { sheet = .bms }
        }
        .frame(width: 210, height: 250)
        .offset(x: 82, y: 172)
    }

    // MARK: 斜梯

    private func ladderBlock(f: RedlineFrame, dx: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RLLadderCanvas(vn: f.vn, E: f.E, t: f.t)
                .frame(width: 240, height: 350)

            // 刻度：跟随满量程设置（默认 0 / 35 / 70 / 105 / 140）
            ForEach(0..<5, id: \.self) { i in
                let fr = Double(i) / 4.0
                let p = RLLad.point(fr)
                let x = p.x + CGFloat(cos(RLLad.angle)) * 43
                let y = p.y + CGFloat(sin(RLLad.angle)) * 43 + 3.5
                Text("\(Int((maxSpeed * fr).rounded()))")
                    .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                    .foregroundColor(RL.ink.opacity(0.55))
                    .position(x: x, y: y)
            }
        }
        .frame(width: 240, height: 350)
        .offset(x: 250 + dx, y: 100)
    }

    // MARK: 车速巨字

    private func speedBlock(f: RedlineFrame, dx: CGFloat) -> some View {
        VStack(spacing: 14) {
            ZStack {
                // 背后那团红光
                Ellipse()
                    .fill(RadialGradient(colors: [RL.red.opacity(0.36), .clear],
                                         center: .center, startRadius: 4, endRadius: 150))
                    .frame(width: 300, height: 150)
                    .blur(radius: 14)
                    .opacity(0.28 + f.vn * 0.55 + f.E * 0.7)
                    .scaleEffect(0.80 + f.vn * 0.40 + f.E * 0.45)

                // 加速时从数字背后拉出来的横向光带
                Rectangle()
                    .fill(RadialGradient(colors: [.white.opacity(0.90),
                                                  RL.redSoft.opacity(0.55),
                                                  .clear],
                                         center: .center, startRadius: 0, endRadius: 190))
                    .frame(width: 420, height: 46)
                    .blur(radius: 14)
                    .opacity(f.E * 0.85)
                    .scaleEffect(x: 0.55 + f.E * 0.75, y: 1)
                    .blendMode(.screen)

                number(f).foregroundColor(RL.red).opacity(f.E * 0.34).offset(x: f.E * 12)
                number(f).foregroundColor(RL.cyan).opacity(f.E * 0.22).offset(x: -f.E * 9)

                number(f)
                    .foregroundColor(.white)
                    .shadow(color: RL.red.opacity(0.85), radius: 26)

                // 数字横向撕裂：上下两片反向错位
                number(f).foregroundColor(.white)
                    .offset(x: f.E2 * 9)
                    .mask(alignment: .top) { Rectangle().frame(height: 84) }
                number(f).foregroundColor(.white)
                    .offset(x: -f.E2 * 7)
                    .mask(alignment: .bottom) { Rectangle().frame(height: 66) }
            }
            .frame(width: 330, height: 150)

            modeBadge(f: f)
        }
        .frame(width: 330)
        .offset(x: 501 + dx, y: 130)
    }

    private func number(_ f: RedlineFrame) -> some View {
        let text = "\(Int(f.speed.rounded()))"
        // 横向压缩跟着位数走。之前一律压 0.74，三个数字正好铺满 330 宽；
        // 可只有一个「0」的时候，压完就成了一根细长椭圆，和预览视频里差得远。
        // 现在一位数不压、两位数轻压，三位数才收到参考图那个比例。
        let squash: CGFloat = text.count >= 3 ? 0.80 : (text.count == 2 ? 0.92 : 1.00)

        return Text(text)
            .font(RL.num(175))
            .kerning(-12)
            .lineLimit(1)
            .frame(width: 330, height: 160)
            .scaleEffect(x: squash, y: 1)
            .skew(-0.16)
    }

    /// 参考片里这里是写死的 SPORT。换成真实状态更有用：
    /// 等红灯（待机）和全油门（加速）一眼就分得出来。
    private func modeBadge(f: RedlineFrame) -> some View {
        let text: String
        let color: Color
        if f.speed < 1.0 {
            text = "待机"; color = RL.red.opacity(0.55)
        } else if f.accel > 2.5 {
            text = "加速"; color = RL.red
        } else if f.accel < -3.0 {
            text = "制动"; color = RL.cyan
        } else if f.accel < -0.8 {
            text = "滑行"; color = RL.redSoft
        } else {
            text = "巡航"; color = RL.redSoft
        }

        return HStack(spacing: 11) {
            Text(text)
                .font(.system(size: 18, weight: .heavy, design: .rounded))
                .tracking(2.5)
                .foregroundColor(color)
                .padding(.horizontal, 13)
                .padding(.vertical, 3)
                .overlay(Rectangle().stroke(color, lineWidth: 1.8))
                .shadow(color: color.opacity(0.5), radius: 7)

            Text("km/h")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(RL.ink.opacity(0.85))
        }
        .frame(width: 330, height: 30)   // 钉死宽度，才会和上面的大字同一条中轴
    }

    // MARK: 雷达

    private func radarBlock(f: RedlineFrame, dx: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            RLRadarCanvas(sweep: f.sweep, t: f.t)
                .frame(width: 200, height: 200)

            Text("0")
                .font(.system(size: 8))
                .foregroundColor(RL.ink.opacity(0.7))
                .frame(width: 15, height: 15)
                .overlay(Circle().stroke(RL.ink.opacity(0.4), lineWidth: 1))
                .offset(x: 173, y: 10)
        }
        .frame(width: 200, height: 200)
        .offset(x: 717 + dx, y: 206)
    }

    // MARK: 右：动力输出

    private func powerRing(f: RedlineFrame, rx: CGFloat) -> some View {
        let frac = min(max(kw / 5.0, 0), 1)

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: 8)
                .frame(width: 144, height: 144)
            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: 126, height: 126)
            Circle()
                .trim(from: 0, to: CGFloat(frac))
                .stroke(RL.redSoft.opacity(0.6),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 144, height: 144)
                .rotationEffect(.degrees(-90))
                .shadow(color: RL.redSoft.opacity(0.55), radius: 8)

            VStack(spacing: 1) {
                Text(String(format: "%.2f", kw))
                    .font(RL.num(32))
                    .foregroundColor(RL.ink)
                    .shadow(color: Color(red: 1, green: 0.6, blue: 0.4).opacity(0.55), radius: 9)
                Text("kW")
                    .font(.system(size: 10.5))
                    .tracking(1.6)
                    .foregroundColor(RL.ink.opacity(0.8))
            }

            VStack {
                Capsule().fill(RL.ink.opacity(0.55)).frame(width: 4, height: 13)
                Spacer()
                Capsule().fill(RL.ink.opacity(0.16)).frame(width: 4, height: 13)
            }
            .frame(height: 160)
        }
        .frame(width: 160, height: 160)
        .overlay(alignment: .top) {
            Text("动力输出")
                .font(.system(size: 13.5))
                .tracking(1.5)
                .foregroundColor(RL.ink.opacity(0.92))
                .offset(y: 168)
        }
        .overlay(alignment: .top) {
            HStack(spacing: 5) {
                Text(String(format: "母线 %.0fA", busA))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(RL.green)
                Text("·")
                    .font(.system(size: 11))
                    .foregroundColor(RL.ink.opacity(0.45))
                Text(String(format: "相线 %.0fA", phaseA))
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1.5)
                    .background(RoundedRectangle(cornerRadius: 2).fill(RL.violet.opacity(0.8)))
                    .shadow(color: RL.violet.opacity(0.7), radius: 6)
            }
            .offset(y: 194)
        }
        .offset(x: 1000 + rx, y: 82)
    }

    // MARK: 右：温度

    private func tempRing(f: RedlineFrame, rx: CGFloat) -> some View {
        let t1 = ctrlT ?? 0
        let t2 = motorT ?? 0
        let frac1 = min(max(t1 / 100.0, 0), 1)
        let frac2 = min(max(t2 / 120.0, 0), 1)
        let hot = t2 >= 90

        return ZStack {
            Circle()
                .stroke(Color.white.opacity(0.06), lineWidth: 8)
                .frame(width: 144, height: 144)
            Circle()
                .stroke(Color.white.opacity(0.05), lineWidth: 1)
                .frame(width: 126, height: 126)

            Circle()
                .trim(from: 0, to: CGFloat(frac1 * 0.30))
                .stroke(RL.cyan.opacity(0.9), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 144, height: 144)
                .rotationEffect(.degrees(148))

            Circle()
                .trim(from: 0, to: CGFloat(frac2 * 0.38))
                .stroke(RL.amber.opacity(0.92), style: StrokeStyle(lineWidth: 8, lineCap: .round))
                .frame(width: 144, height: 144)
                .rotationEffect(.degrees(24))

            VStack(spacing: 1) {
                Text(ctrlT == nil ? "--" : String(format: "%.0f℃", t1))
                    .font(RL.num(21))
                    .foregroundColor(RL.cyan)
                    .shadow(color: RL.cyan.opacity(0.7), radius: 8)
                Text(motorT == nil ? "--" : String(format: "%.0f℃", t2))
                    .font(RL.num(21))
                    .foregroundColor(RL.amber)
                    .shadow(color: RL.amber.opacity(0.7), radius: 8)
            }
        }
        .frame(width: 160, height: 160)
        .overlay(alignment: .top) {
            Text("温度监控")
                .font(.system(size: 13.5))
                .tracking(1.5)
                .foregroundColor(RL.ink.opacity(0.92))
                .offset(y: 168)
        }
        .overlay(alignment: .top) {
            Text(hot ? "温度偏高" : "温度正常")
                .font(.system(size: 11.5))
                .tracking(1.5)
                .foregroundColor(hot ? RL.amber : RL.green)
                .shadow(color: (hot ? RL.amber : RL.green).opacity(0.55), radius: 6)
                .offset(y: 194)
        }
        .offset(x: 1000 + rx, y: 300)
    }

    // MARK: 底部 G 行

    private func gRow(f: RedlineFrame, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: RL.red.opacity(0.45), location: 0.12),
                    .init(color: RL.red.opacity(0.45), location: 0.88),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)

            Rectangle()
                .fill(LinearGradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: RL.red.opacity(0.20), location: 0.20),
                    .init(color: RL.red.opacity(0.20), location: 0.80),
                    .init(color: .clear, location: 1)
                ], startPoint: .leading, endPoint: .trailing))
                .frame(height: 1)
                .offset(y: 31)

            HStack(spacing: 0) {
                HStack(spacing: 6) {
                    Text("◀")
                        .font(.system(size: 11))
                        .foregroundColor(RL.redSoft.opacity(0.9))
                    Text(String(format: "相线 %.0f A", phaseA))
                        .font(.system(size: 12.5, weight: .bold))
                        .foregroundColor(RL.redSoft)
                        .tracking(0.6)
                    Text("▶")
                        .font(.system(size: 11))
                        .foregroundColor(RL.redSoft.opacity(0.9))
                }

                Spacer(minLength: 8)

                Text("纵向 \(String(format: "%+.2f", f.accel / 3.6 / 9.81)) G")
                    .font(.system(size: 13))
                    .foregroundColor(RL.ink.opacity(0.95))
                    .tracking(0.8)

                Spacer(minLength: 8)

                HStack(spacing: 5) {
                    Text(String(format: "%.0f", rpm))
                        .font(.system(size: 13, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundColor(RL.redSoft)
                    Text("RPM")
                        .font(.system(size: 10))
                        .foregroundColor(RL.redSoft.opacity(0.85))
                }
            }
            .frame(height: 32)
        }
        .frame(width: max(width - 246 - 150, 300), height: 33)
        .offset(x: 246, y: 512)
    }

    // MARK: 底栏数据

    private func dataRow(f: RedlineFrame) -> some View {
        HStack(spacing: 0) {
            dataColumn("骑行时间", clock(f.ride), color: RL.red,
                       fill: min(f.ride / 3600, 1))
            dataColumn("本次里程", String(format: "%.1f km", central.tripKm), color: RL.cyan,
                       fill: min(central.tripKm / 50, 1))
            dataColumn("电池功率", String(format: "%.0f W", packW), color: RL.amber,
                       fill: min(packW / 800, 1))
        }
        .frame(width: 588, alignment: .leading)
        .offset(x: 52, y: 640)
    }

    private func dataColumn(_ title: String, _ value: String, color: Color, fill: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11))
                .tracking(1.4)
                .foregroundColor(RL.ink.opacity(0.52))

            Text(value)
                .font(RL.num(26))
                .foregroundColor(color)
                .shadow(color: color.opacity(0.45), radius: 9)
                .skew(-0.12)
                .lineLimit(1)

            LinearGradient(colors: [RL.red, RL.red.opacity(0.10)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(width: CGFloat(0.35 + fill * 0.65) * 190, height: 2)
                .shadow(color: RL.red.opacity(0.5), radius: 4)
                .padding(.top, 3)
        }
        .frame(width: 196, alignment: .leading)
    }

    private func clock(_ seconds: Double) -> String {
        let total = Int(seconds)
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%02d:%02d", m, s)
    }

    // MARK: 右下角 Tab

    private func tabStrip(rx: CGFloat) -> some View {
        HStack(spacing: 14) {
            tabIcon("仪表", "gauge", active: true, action: nil)
            tabIcon("设备", "slider.horizontal.3", active: false, action: { sheet = .bms })
            tabIcon("记录", "list.bullet", active: false, action: { sheet = .console })
            tabIcon("设置", "gearshape", active: false, action: { sheet = .settings })
        }
        .frame(width: 274, height: 66)
        .offset(x: 972 + rx, y: 634)
    }

    private func tabIcon(_ title: String, _ symbol: String,
                         active: Bool, action: (() -> Void)?) -> some View {
        Button {
            action?()
        } label: {
            VStack(spacing: 5) {
                ZStack {
                    Circle()
                        .fill(active ? RL.red.opacity(0.14) : Color.white.opacity(0.03))
                    Circle()
                        .stroke(active ? RL.red : Color.white.opacity(0.12),
                                lineWidth: active ? 1.6 : 1)
                    Image(systemName: symbol)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundColor(active ? RL.red : RL.ink.opacity(0.42))
                }
                .frame(width: 38, height: 38)
                .shadow(color: active ? RL.red.opacity(0.6) : .clear, radius: 9)

                Text(title)
                    .font(.system(size: 10.5))
                    .tracking(1)
                    .foregroundColor(active ? RL.red : RL.ink.opacity(0.42))
            }
            .frame(width: 58)
        }
        .buttonStyle(.plain)
    }

    // MARK: 背景动效

    private func bloom(f: RedlineFrame, dx: CGFloat) -> some View {
        Ellipse()
            .fill(RadialGradient(colors: [RL.red.opacity(0.42), .clear],
                                 center: .center, startRadius: 6, endRadius: 190))
            .frame(width: 620, height: 300)
            .blur(radius: 22)
            .opacity(0.20 + f.vn * 0.60 + f.E * 0.80)
            .scaleEffect(0.85 + f.vn * 0.30 + f.E * 0.35)
            .offset(x: 301 + dx, y: 200)
    }

    private func sweepBand(t: Double, width: CGFloat) -> some View {
        Rectangle()
            .fill(LinearGradient(colors: [.clear, RL.red.opacity(0.10), .clear],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: width, height: 120)
            .offset(y: CGFloat((t * 300).truncatingRemainder(dividingBy: 900)) - 140)
    }

    // MARK: 冲击特效

    private func impactLayers(f: RedlineFrame, width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            SparkCanvas(E: f.E, width: width)

            // 白光闪一下
            Rectangle()
                .fill(Color.white)
                .frame(width: width, height: 720)
                .opacity(f.E2 * 0.07)
                .blendMode(.screen)

            // 冲击红闪
            RadialGradient(colors: [RL.redSoft.opacity(0.92),
                                    RL.red.opacity(0.38),
                                    .clear],
                           center: UnitPoint(x: 0.5, y: 0.44),
                           startRadius: 4, endRadius: 520)
                .frame(width: width, height: 720)
                .opacity(f.E * 0.21 + f.D * 0.12)
                .blendMode(.screen)

            // 两条红色扫描线
            rollLine(t: f.t, E: f.E, width: width, shift: 0)
            rollLine(t: f.t, E: f.E, width: width, shift: 260)

            // 扩散光圈
            shockRing(age: f.shockAges[0], E: f.E, width: width)
            shockRing(age: f.shockAges[1], E: f.E, width: width)

            // 暗角
            RadialGradient(colors: [.clear, .black.opacity(0.86)],
                           center: UnitPoint(x: 0.5, y: 0.46),
                           startRadius: 200, endRadius: 720)
                .frame(width: width, height: 720)
                .opacity(0.10 + f.vn * 0.18 + f.E * 0.28)
        }
        .frame(width: width, height: 720)
        .allowsHitTesting(false)
    }

    private func rollLine(t: Double, E: Double, width: CGFloat, shift: Double) -> some View {
        Rectangle()
            .fill(LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: RL.redSoft.opacity(0.95), location: 0.30),
                .init(color: .white.opacity(0.90), location: 0.50),
                .init(color: RL.redSoft.opacity(0.95), location: 0.70),
                .init(color: .clear, location: 1)
            ], startPoint: .leading, endPoint: .trailing))
            .frame(width: width, height: 2)
            .opacity(E * 0.55)
            .offset(y: CGFloat((t * 1800 + shift).truncatingRemainder(dividingBy: 900)) - 60)
    }

    @ViewBuilder
    private func shockRing(age: Double, E: Double, width: CGFloat) -> some View {
        let p = min(age / 0.85, 1)
        if p < 1 {
            let r = 60 + p * 700
            Circle()
                .stroke(RL.redSoft.opacity((1 - p) * 0.55 * (0.4 + E * 0.6)),
                        lineWidth: max(0.2, 2.2 - p * 1.8))
                .frame(width: r, height: r)
                .shadow(color: RL.redSoft.opacity((1 - p) * 0.6), radius: 12)
                .position(x: width / 2, y: 720 * 0.44)
        }
    }
}

// MARK: - 背景（静态层）

/// 底色 + 红光 + 蜂窝纹 + 扫描线 + 边框暗角。
/// 全部静态，放在时间轴外面——每帧重画一遍纯属浪费。
private struct RedlineBackdrop: View {
    var width: CGFloat

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.090, green: 0.020, blue: 0.035),
                                    Color(red: 0.060, green: 0.012, blue: 0.024),
                                    Color(red: 0.024, green: 0.004, blue: 0.008)],
                           startPoint: .top, endPoint: .bottom)

            RadialGradient(colors: [Color(red: 0.42, green: 0.03, blue: 0.07).opacity(0.95), .clear],
                           center: UnitPoint(x: 0.47, y: 0.58),
                           startRadius: 8, endRadius: 560)

            RadialGradient(colors: [Color(red: 0.48, green: 0.03, blue: 0.06).opacity(0.80), .clear],
                           center: UnitPoint(x: 0.50, y: 1.20),
                           startRadius: 20, endRadius: 820)

            RadialGradient(colors: [RL.red.opacity(0.11), .clear],
                           center: UnitPoint(x: 0.03, y: 0.46),
                           startRadius: 10, endRadius: 520)

            RadialGradient(colors: [RL.red.opacity(0.10), .clear],
                           center: UnitPoint(x: 0.98, y: 0.54),
                           startRadius: 10, endRadius: 520)

            // 蜂窝斜纹
            Canvas { ctx, size in
                var p = Path()
                var x: CGFloat = -size.height
                while x < size.width + size.height {
                    p.move(to: CGPoint(x: x, y: 0))
                    p.addLine(to: CGPoint(x: x + size.height * 0.58, y: size.height))
                    p.move(to: CGPoint(x: x, y: size.height))
                    p.addLine(to: CGPoint(x: x + size.height * 0.58, y: 0))
                    x += 28
                }
                ctx.stroke(p, with: .color(RL.redSoft.opacity(0.055)), lineWidth: 1)
            }
            .mask(RadialGradient(colors: [.white, .clear],
                                 center: UnitPoint(x: 0.5, y: 0.52),
                                 startRadius: 60, endRadius: 640))

            // 扫描线
            Canvas { ctx, size in
                var p = Path()
                var y: CGFloat = 0
                while y < size.height {
                    p.move(to: CGPoint(x: 0, y: y))
                    p.addLine(to: CGPoint(x: size.width, y: y))
                    y += 3
                }
                ctx.stroke(p, with: .color(.white.opacity(0.045)), lineWidth: 1)
            }
            .blendMode(.overlay)

            // 四周压黑
            RadialGradient(colors: [.clear, .black.opacity(0.92)],
                           center: .center, startRadius: 210, endRadius: 780)

            // 边框
            RoundedRectangle(cornerRadius: 16)
                .stroke(RL.red.opacity(0.30), lineWidth: 1)
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(RL.red.opacity(0.085), lineWidth: 1)
                    .padding(4))
                .padding(8)
                .shadow(color: RL.red.opacity(0.20), radius: 18)
        }
        .frame(width: width, height: 720)
        .clipped()
    }
}

// MARK: - 残影线

/// 从画面中心往外飞的白/红细线，车速越高越长越亮，加速度一上来就被拉成激光。
private struct StreakCanvas: View {
    var f: RedlineFrame
    var width: CGFloat

    private struct Line {
        var ang: Double
        var r0: Double
        var spd: Double
        var len: Double
        var warm: Bool
        var base: Double
    }

    private var lines: [Line] {
        (0..<44).map { i in
            Line(ang: -112 + rlRand(i, 1) * 224,
                 r0: 130 + rlRand(i, 2) * 320,
                 spd: 120 + rlRand(i, 3) * 520,
                 len: 22 + rlRand(i, 4) * 240,
                 warm: rlRand(i, 5) > 0.46,
                 base: 0.10 + rlRand(i, 6) * 0.36)
        }
    }

    var body: some View {
        Canvas { ctx, _ in
            let cx = width * 0.47
            let cy: CGFloat = 720 * 0.57
            let boost = 1 + f.E * 4.2

            for s in lines {
                let travel = (f.t * s.spd * boost * (0.35 + f.vn))
                    .truncatingRemainder(dividingBy: 700)
                let r = s.r0 + travel
                let len = s.len * (0.35 + f.vn * 1.6) * (1 + f.E * 1.4)
                let a = s.ang * .pi / 180
                let dx = cos(a), dy = sin(a)

                var p = Path()
                p.move(to: CGPoint(x: cx + CGFloat(dx * r), y: cy + CGFloat(dy * r)))
                p.addLine(to: CGPoint(x: cx + CGFloat(dx * (r + len)),
                                      y: cy + CGFloat(dy * (r + len))))

                let op = min(1, s.base * (0.35 + f.vn * 1.5) * (1 + f.E * 1.2))
                let color = s.warm ? Color.white : RL.red
                ctx.stroke(p, with: .color(color.opacity(op)), lineWidth: 1)
            }
        }
        .frame(width: width, height: 720)
        .allowsHitTesting(false)
    }
}

// MARK: - 放射粒子

private struct SparkCanvas: View {
    var E: Double
    var width: CGFloat

    var body: some View {
        Canvas { ctx, _ in
            let op = max(0, E - 0.2) * 0.72
            guard op > 0.01 else { return }

            let cx = width * 0.5
            let cy: CGFloat = 720 * 0.43
            let d = 60 + (1 - E) * 190
            let tail = 30 * (0.35 + E * 1.1)

            for i in 0..<14 {
                let ang = (360.0 / 14.0) * Double(i) + (rlRand(i, 7) * 14 - 7)
                let a = ang * .pi / 180
                let dx = cos(a), dy = sin(a)
                let p0 = CGPoint(x: cx + CGFloat(dx * d), y: cy + CGFloat(dy * d))
                let p1 = CGPoint(x: cx + CGFloat(dx * (d + tail)),
                                 y: cy + CGFloat(dy * (d + tail)))
                var p = Path()
                p.move(to: p0)
                p.addLine(to: p1)
                ctx.stroke(p, with: .linearGradient(
                    Gradient(colors: [.white.opacity(op), RL.red.opacity(0)]),
                    startPoint: p0, endPoint: p1), lineWidth: 1.6)
            }
        }
        .frame(width: width, height: 720)
        .allowsHitTesting(false)
    }
}

// MARK: - 斜梯

private struct RLLadderCanvas: View {
    var vn: Double
    var E: Double
    var t: Double

    var body: some View {
        Canvas { ctx, _ in
            let ang = RLLad.angle
            let top = RLLad.top
            let nx = CGFloat(cos(ang)) * RLLad.width / 2
            let ny = CGFloat(sin(ang)) * RLLad.width / 2

            // 两根侧轨围出来的框
            var rail = Path()
            rail.move(to: CGPoint(x: RLLad.bx - nx, y: RLLad.by - ny))
            rail.addLine(to: CGPoint(x: top.x - nx, y: top.y - ny))
            rail.addLine(to: CGPoint(x: top.x + nx, y: top.y + ny))
            rail.addLine(to: CGPoint(x: RLLad.bx + nx, y: RLLad.by + ny))
            rail.closeSubpath()
            ctx.stroke(rail, with: .linearGradient(
                Gradient(colors: [RL.red.opacity(0.25), RL.redSoft.opacity(0.85)]),
                startPoint: CGPoint(x: 0, y: RLLad.by),
                endPoint: CGPoint(x: 0, y: top.y)), lineWidth: 1.2)

            // 横档
            for i in 0..<RLLad.count {
                let fr = Double(i) / Double(RLLad.count - 1)
                let c = RLLad.point(fr)
                var rung = Path()
                rung.addRect(CGRect(x: -RLLad.width / 2 + 2, y: -2.2,
                                    width: RLLad.width - 4, height: 4.4))
                rung = rung.applying(CGAffineTransform(translationX: c.x, y: c.y)
                    .rotated(by: CGFloat(ang)))

                let lit = fr <= vn
                let travel = max(0, 1 - abs(fr - fmod(t * 0.7, 1)) * 7)
                let base = lit ? (0.48 + fr * 0.50) : (0.10 + fr * 0.07)
                let op = min(1, base + travel * 0.32 + (lit ? 0.10 : 0) + E * 0.18)
                let lead = abs(fr - vn) < 0.06

                if lit && E > 0.25 {
                    ctx.fill(rung, with: .color(RL.redSoft.opacity(op * E * 0.45)))
                }
                if lead {
                    ctx.fill(rung, with: .color(.white.opacity(min(1, op + 0.25))))
                } else if lit && fr > 0.88 {
                    ctx.fill(rung, with: .color(RL.redSoft.opacity(op)))
                } else {
                    ctx.fill(rung, with: .color(RL.ink.opacity(op)))
                }
            }

            // 顶端红区
            var cap = Path()
            cap.addRoundedRect(in: CGRect(x: -RLLad.width / 2 + 1, y: -22,
                                          width: RLLad.width - 2, height: 20),
                               cornerSize: CGSize(width: 2, height: 2))
            cap = cap.applying(CGAffineTransform(translationX: top.x, y: top.y)
                .rotated(by: CGFloat(ang)))
            let capOp = 0.55 + 0.45 * abs(sin(t * 3.1)) + E * 0.4
            ctx.fill(cap, with: .color(RL.red.opacity(min(1, capOp))))
        }
        .frame(width: 240, height: 350)
        .allowsHitTesting(false)
    }
}

// MARK: - 电池环

private struct RLBatteryRing: View {
    var soc: Int
    var t: Double

    private let count = 34
    private let radius: CGFloat = 88
    private let thickness: CGFloat = 16
    private let startDeg = -60.0
    private let sweepDeg = 320.0

    var body: some View {
        Canvas { ctx, _ in
            let cx: CGFloat = 105
            let cy: CGFloat = 105
            let lit = Int((Double(count) * Double(soc) / 100.0).rounded())
            let pulse = 0.62 + 0.38 * abs(sin(t * 1.6))

            // 外圈细环
            var ring = Path()
            ring.addEllipse(in: CGRect(x: cx - 100, y: cy - 100, width: 200, height: 200))
            ctx.stroke(ring, with: .color(.white.opacity(0.045)), lineWidth: 1)

            for i in 0..<count {
                let deg = startDeg + (Double(i) / Double(count - 1)) * sweepDeg
                let a = deg * .pi / 180
                let ca = CGFloat(cos(a))
                let sa = CGFloat(sin(a))
                let c = CGPoint(x: cx - radius * ca, y: cy - radius * sa)

                let on = i < lit
                let color: Color = on
                    ? (i > lit - 5 ? Color(red: 0.55, green: 1.0, blue: 0.74) : RL.green)
                    : Color.white.opacity(0.085)

                // 假发光：先垫一圈更宽更薄的同色块
                if on {
                    ctx.fill(segment(center: c, ca: ca, sa: sa,
                                     hu: thickness * 0.95, hv: 7.6),
                             with: .color(color.opacity(0.10 + pulse * 0.10)))
                }
                ctx.fill(segment(center: c, ca: ca, sa: sa,
                                 hu: thickness / 2, hv: 5.6),
                         with: .color(color))
            }
        }
        .frame(width: 210, height: 210)
        .allowsHitTesting(false)
    }

    /// 一段环：径向厚 2*hu、切向宽 2*hv 的四边形
    private func segment(center: CGPoint, ca: CGFloat, sa: CGFloat,
                         hu: CGFloat, hv: CGFloat) -> Path {
        let ux = -ca, uy = -sa      // 径向
        let vx = -sa, vy = ca       // 切向
        var p = Path()
        p.move(to: CGPoint(x: center.x - ux * hu - vx * hv, y: center.y - uy * hu - vy * hv))
        p.addLine(to: CGPoint(x: center.x + ux * hu - vx * hv, y: center.y + uy * hu - vy * hv))
        p.addLine(to: CGPoint(x: center.x + ux * hu + vx * hv, y: center.y + uy * hu + vy * hv))
        p.addLine(to: CGPoint(x: center.x - ux * hu + vx * hv, y: center.y - uy * hu + vy * hv))
        p.closeSubpath()
        return p
    }
}

// MARK: - 雷达

private struct RLRadarCanvas: View {
    var sweep: Double
    var t: Double

    var body: some View {
        Canvas { ctx, _ in
            let cx: CGFloat = 100
            let cy: CGFloat = 100
            let center = CGPoint(x: cx, y: cy)

            for r in [CGFloat(91), 61, 31] {
                var p = Path()
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                ctx.stroke(p, with: .color(RL.redSoft.opacity(0.20)), lineWidth: 1)
            }

            // 虚线内环
            for r in [CGFloat(76), 46] {
                var p = Path()
                p.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                ctx.stroke(p, with: .color(RL.redSoft.opacity(0.09)),
                           style: StrokeStyle(lineWidth: 1, dash: [1, 6]))
            }

            var cross = Path()
            cross.move(to: CGPoint(x: 9, y: cy))
            cross.addLine(to: CGPoint(x: 191, y: cy))
            cross.move(to: CGPoint(x: cx, y: 9))
            cross.addLine(to: CGPoint(x: cx, y: 191))
            ctx.stroke(cross, with: .color(RL.redSoft.opacity(0.18)), lineWidth: 1)

            // 扫描扇形
            let half = 19.0
            let a0 = (sweep - half) * .pi / 180
            let a1 = (sweep + half) * .pi / 180
            let r: CGFloat = 91
            var wedge = Path()
            wedge.move(to: center)
            wedge.addLine(to: CGPoint(x: cx + r * CGFloat(cos(a0)), y: cy + r * CGFloat(sin(a0))))
            wedge.addArc(center: center, radius: r,
                         startAngle: .radians(a0), endAngle: .radians(a1), clockwise: false)
            wedge.closeSubpath()
            ctx.fill(wedge, with: .linearGradient(
                Gradient(colors: [RL.red.opacity(0), RL.red.opacity(0.55)]),
                startPoint: center,
                endPoint: CGPoint(x: cx + r * CGFloat(cos(a1)),
                                  y: cy + r * CGFloat(sin(a1)))))

            // 目标点
            let rx = cx + CGFloat(sin(t * 1.1)) * 16
            let ry = cy - CGFloat(cos(t * 0.9)) * 12
            let dotR: CGFloat = 22
            var halo = Path()
            halo.addEllipse(in: CGRect(x: rx - dotR, y: ry - dotR, width: dotR * 2, height: dotR * 2))
            ctx.fill(halo, with: .radialGradient(
                Gradient(colors: [RL.red.opacity(0.55), RL.red.opacity(0)]),
                center: CGPoint(x: rx, y: ry), startRadius: 0, endRadius: dotR))

            var dot = Path()
            dot.addEllipse(in: CGRect(x: rx - 5, y: ry - 5, width: 10, height: 10))
            ctx.fill(dot, with: .color(Color(red: 1, green: 0.27, blue: 0.34)))
        }
        .frame(width: 200, height: 200)
        .allowsHitTesting(false)
    }
}
