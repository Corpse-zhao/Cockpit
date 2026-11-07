import SwiftUI
import UIKit
import PhotosUI

// MARK: - 主题色

enum NeonTheme {
    /// 主色：品红 #DB0D6B
    static let pink = Color(red: 0.859, green: 0.051, blue: 0.420)
    static let pinkLight = Color(red: 1.0, green: 0.36, blue: 0.66)
    static let cardTop = Color.white.opacity(0.10)
    static let cardBottom = Color.black.opacity(0.34)
    static let hairline = Color.white.opacity(0.14)
}

// MARK: - 壁纸存储

enum WallpaperStore {
    static let key = "wallpaper_file"

    static var url: URL? {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty else { return nil }
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static var image: UIImage? {
        guard let u = url else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    @discardableResult
    static func save(_ data: Data) -> Bool {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let name = "wallpaper.jpg"
        let u = dir.appendingPathComponent(name)
        do {
            if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.86) {
                try jpg.write(to: u, options: .atomic)
            } else {
                try data.write(to: u, options: .atomic)
            }
            UserDefaults.standard.set(name, forKey: key)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaper_version")
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        try? FileManager.default.removeItem(at: dir.appendingPathComponent("wallpaper.jpg"))
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaper_version")
    }
}

// MARK: - 背景

struct WallpaperBackground: View {
    @AppStorage("wallpaper_version") private var version = 0.0

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let img = WallpaperStore.image {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                    // 左侧压暗保证数据可读，右侧保留壁纸亮度
                    LinearGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.78), location: 0.0),
                            .init(color: Color.black.opacity(0.55), location: 0.42),
                            .init(color: Color.black.opacity(0.22), location: 1.0)
                        ],
                        startPoint: .leading, endPoint: .trailing
                    )
                    // 品红叠色，统一色调
                    NeonTheme.pink.opacity(0.16)
                } else {
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.01, blue: 0.06),
                            Color(red: 0.40, green: 0.02, blue: 0.24),
                            Color(red: 0.05, green: 0.01, blue: 0.04)
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(NeonTheme.pink.opacity(0.45))
                        .frame(width: geo.size.height * 1.1)
                        .blur(radius: 100)
                        .offset(x: geo.size.width * 0.28, y: -geo.size.height * 0.18)
                }
            }
            .id(version)
        }
        .ignoresSafeArea()
    }
}

// MARK: - 圆环表盘

struct NeonGauge: View {
    var progress: Double        // 0...1
    var speed: Double
    var rpm: Int
    var powerKW: Double
    var temp: Double?
    var maxRPM: Double

    private let sweep: Double = 270

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let R = side / 2 - side * 0.035
            let ring = side * 0.058
            let cx = geo.size.width / 2
            let cy = geo.size.height / 2
            let p = min(max(progress, 0), 1)

            ZStack {
                // 内圈底盘（深色圆 + 品红描边发光）
                Circle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: side * 0.64, height: side * 0.64)
                Circle()
                    .stroke(NeonTheme.pink.opacity(0.75), lineWidth: 2)
                    .frame(width: side * 0.64, height: side * 0.64)
                    .blur(radius: 5)
                Circle()
                    .stroke(NeonTheme.pink.opacity(0.35), lineWidth: 1)
                    .frame(width: side * 0.64, height: side * 0.64)

                // 轨道（270° 白弧）
                Circle()
                    .trim(from: 0, to: sweep / 360)
                    .stroke(Color.white.opacity(0.94), style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                    .frame(width: R * 2, height: R * 2)

                // 进度（品红填充）
                if p > 0.001 {
                    Circle()
                        .trim(from: 0, to: sweep / 360 * p)
                        .stroke(
                            LinearGradient(colors: [NeonTheme.pink, NeonTheme.pinkLight],
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: ring, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(90))
                        .frame(width: R * 2, height: R * 2)
                }

                // 刻度数字 0...9
                ForEach(0...9, id: \.self) { i in
                    let deg = 90 + sweep * Double(i) / 9
                    let rad = deg * .pi / 180
                    let rr = R - ring * 0.95
                    Text("\(i)")
                        .font(.system(size: side * 0.048, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .position(x: cx + cos(rad) * rr, y: cy + sin(rad) * rr)
                }

                // 次刻度
                ForEach(0..<45, id: \.self) { i in
                    let deg = 90 + sweep * Double(i) / 44
                    let rad = deg * .pi / 180
                    let r1 = R + ring * 0.52
                    let r2 = R + ring * 0.78
                    Path { path in
                        path.move(to: CGPoint(x: cx + cos(rad) * r1, y: cy + sin(rad) * r1))
                        path.addLine(to: CGPoint(x: cx + cos(rad) * r2, y: cy + sin(rad) * r2))
                    }
                    .stroke(Color.white.opacity(i % 5 == 0 ? 0.55 : 0.22),
                            lineWidth: i % 5 == 0 ? 1.6 : 1)
                }

                // 指针
                Path { path in
                    let rad = (90 + sweep * p) * .pi / 180
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + cos(rad) * (R - ring * 0.2),
                                             y: cy + sin(rad) * (R - ring * 0.2)))
                }
                .stroke(Color(red: 1.0, green: 0.18, blue: 0.22),
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                Circle()
                    .fill(Color(red: 1.0, green: 0.18, blue: 0.22))
                    .frame(width: side * 0.028, height: side * 0.028)

                // 中心读数（速度在上，转速在下）
                VStack(spacing: 0) {
                    Text(Fmt.speed(speed))
                        .font(.system(size: side * 0.132, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("km/h")
                        .font(.system(size: side * 0.040))
                        .foregroundColor(.white.opacity(0.62))
                        .padding(.top, -side * 0.005)

                    divider(side: side)

                    Text(rpmLarge)
                        .font(.system(size: side * 0.140, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("×1000 rpm")
                        .font(.system(size: side * 0.040))
                        .foregroundColor(.white.opacity(0.62))
                        .padding(.top, -side * 0.005)

                    divider(side: side)

                    HStack(spacing: side * 0.045) {
                        Text(String(format: "%.0f%%", min(max(powerKW / 5.0, 0), 1) * 100))
                        Text(tempText)
                    }
                    .font(.system(size: side * 0.042, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                }
                .frame(width: side * 0.52)
            }
        }
    }

    private var rpmLarge: String {
        // 超出 10000 直接显示原值，否则按 ×1000 显示一位小数
        if rpm >= 10000 { return "\(rpm)" }
        return String(format: "%.1f", Double(rpm) / 1000.0)
    }

    private var tempText: String {
        guard let t = temp else { return "——" }
        return String(format: "%.0f℃", t)
    }

    private func divider(side: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.42))
            .frame(width: side * 0.30, height: 1)
            .padding(.vertical, side * 0.028)
    }
}

// MARK: - 左侧状态面板

struct NeonStatusPanel: View {
    @EnvironmentObject var central: CockpitCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("show_motor_temp") private var showMotorTemp = true

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            header
            VStack(spacing: 9) {
                tileRow(0..<4)
                tileRow(4..<8)
            }
            .frame(maxHeight: .infinity)
            footer
        }
    }

    private func tileRow(_ range: Range<Int>) -> some View {
        HStack(spacing: 9) {
            ForEach(Array(range), id: \.self) { i in
                let t = tiles[i]
                tile(t.0, t.1, t.2)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(central.connectedName ?? "LBMC")
                    .font(.system(size: 16, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(central.phase == .online ? Color(red: 0.2, green: 0.95, blue: 0.55) : .orange)
                        .frame(width: 6, height: 6)
                    Text(central.phase.rawValue)
                        .font(.system(size: 11))
                        .foregroundColor(central.phase == .online ? Color(red: 0.2, green: 0.95, blue: 0.55) : .orange)
                    if !vehicleLabel.isEmpty {
                        Text("·")
                            .foregroundColor(.white.opacity(0.35))
                        Text(vehicleLabel)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.55))
                            .lineLimit(1)
                    }
                }
            }
            Spacer()
            Button {
                central.disconnect()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "xmark.circle.fill")
                    Text("断开").font(.system(size: 12))
                }
                .foregroundColor(NeonTheme.pinkLight)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glassCard()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.2.circlepath")
                    .font(.system(size: 9))
                Text("周长 \(Fmt.num(central.wheelCircMM, "mm")) · \(central.wheelCircSource)")
                    .font(.system(size: 10, design: .monospaced))
            }
            .foregroundColor(.white.opacity(0.55))

            Spacer()

            // 帧长：挡位/转把 不显示时的第一手线索
            HStack(spacing: 4) {
                Text("帧长")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.42))
                Text(central.lastFrameLength == 0 ? "—" : "\(central.lastFrameLength)")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(frameLengthColor)
            }

            Spacer()

            HStack(spacing: 5) {
                Text("本次")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
                Text(String(format: "%.2f km", central.tripKm))
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCard()
    }

    /// 29 字节为标准长帧（转把+挡位齐全）；24～28 缺字段；<24 只剩基础量
    private var frameLengthColor: Color {
        let n = central.lastFrameLength
        if n == 0 { return .white.opacity(0.35) }
        if n >= 29 { return Color(red: 0.2, green: 0.95, blue: 0.55) }
        if n >= 25 { return .yellow }
        return Color(red: 1.0, green: 0.55, blue: 0.25)
    }

    private var tiles: [(String, String, Color)] {
        let t = central.telemetry
        let faultColor: Color = (t?.fault ?? 0) == 0
            ? Color(red: 0.2, green: 0.95, blue: 0.55)
            : Color(red: 1.0, green: 0.28, blue: 0.30)

        var rows: [(String, String, Color)] = [
            ("挡位", t?.gear.map { "P\($0)" } ?? "——", .white),
            ("转速", t.map { "\($0.rpm)" } ?? "——", .white),
            ("控制器温度", Fmt.temp(t?.controllerTemp), tempColor(t?.controllerTemp))
        ]
        if showMotorTemp {
            rows.append(("电机温度", Fmt.temp(t?.motorTemp), tempColor(t?.motorTemp)))
        } else {
            rows.append(("故障码", (t?.fault ?? 0) == 0 ? "无" : String(format: "0x%04X", (t?.fault ?? 0) & 0xFFFF), faultColor))
        }
        rows += [
            ("母线电压", t.map { Fmt.num($0.busVoltage, "V") } ?? "——", .white),
            ("母线电流", t.map { Fmt.num($0.busCurrent, "A") } ?? "——",
             (t?.busCurrent ?? 0) < -0.005 ? Color(red: 0.2, green: 0.95, blue: 0.55)
                : ((t?.busCurrent ?? 0) > 0.005 ? NeonTheme.pinkLight : .white)),
            ("功率", t.map { Fmt.num($0.busVoltage * $0.busCurrent / 1000.0, "kW") } ?? "——", .white),
            ("转把", t?.throttlePercent.map { Fmt.percent($0) } ?? "——", .white)
        ]
        return rows
    }

    private func tempColor(_ v: Double?) -> Color {
        guard let v else { return .white }
        if v >= 90 { return Color(red: 1.0, green: 0.28, blue: 0.30) }
        if v >= 70 { return .orange }
        return .white
    }

    private func tile(_ key: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(key)
                .font(.system(size: 10.5))
                .foregroundColor(.white.opacity(0.60))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 23, weight: .bold, design: .rounded))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.45)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .glassCard()
    }
}

// MARK: - 毛玻璃卡片

struct GlassCardModifier: ViewModifier {
    var radius: CGFloat = 11

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: radius)
                            .fill(Color.black.opacity(0.32))
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .stroke(NeonTheme.hairline, lineWidth: 0.8)
            )
    }
}

extension View {
    func glassCard(radius: CGFloat = 11) -> some View {
        modifier(GlassCardModifier(radius: radius))
    }
}

// MARK: - 霓虹主界面

struct NeonDashboard: View {
    @EnvironmentObject var central: CockpitCentral
    @AppStorage("gauge_max_rpm") private var maxRPM = 9000.0
    @AppStorage("boot_animation") private var bootAnimation = true

    @State private var hasBooted = false
    @State private var booting = false
    @State private var bootProgress: Double = 0
    @State private var bootRPM: Double = 0
    @State private var revealCards = false
    @State private var appear = false
    @State private var bootTimer: Timer?

    var body: some View {
        ZStack {
            WallpaperBackground()

            HStack(spacing: 16) {
                NeonStatusPanel()
                    .frame(maxWidth: .infinity)
                    .opacity(revealCards ? 1 : 0)
                    .offset(y: revealCards ? 0 : 10)

                NeonGauge(
                    progress: gaugeProgress,
                    speed: booting ? 0 : central.speedKmh,
                    rpm: booting ? Int(bootRPM) : (central.telemetry?.rpm ?? 0),
                    powerKW: booting
                        ? 0
                        : (central.telemetry?.busVoltage ?? 0) * (central.telemetry?.busCurrent ?? 0) / 1000.0,
                    temp: booting ? nil : central.telemetry?.controllerTemp,
                    maxRPM: maxRPM
                )
                .frame(width: 310)
                .scaleEffect(booting ? 0.985 : 1.0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .opacity(appear ? 1 : 0)
        .onAppear {
            withAnimation(.easeOut(duration: 0.28)) { appear = true }
            handlePhase(central.phase)
        }
        .onChange(of: central.phase) { newPhase in
            handlePhase(newPhase)
        }
        .onDisappear {
            bootTimer?.invalidate()
            bootTimer = nil
        }
    }

    // MARK: 进度

    private var gaugeProgress: Double {
        if booting { return bootProgress }
        let rpm = Double(central.telemetry?.rpm ?? 0)
        return min(max(rpm / max(maxRPM, 1), 0), 1)
    }

    // MARK: 阶段

    private func handlePhase(_ phase: CockpitCentral.Phase) {
        switch phase {
        case .connected, .calibrated, .online:
            guard !hasBooted else {
                // 已开机过，数据来了直接显示卡片
                if !revealCards {
                    withAnimation(.easeOut(duration: 0.3)) { revealCards = true }
                }
                return
            }
            hasBooted = true
            if bootAnimation {
                runBootSequence()
            } else {
                withAnimation(.easeOut(duration: 0.3)) { revealCards = true }
            }
        case .idle:
            bootTimer?.invalidate()
            bootTimer = nil
            hasBooted = false
            booting = false
            bootProgress = 0
            bootRPM = 0
            revealCards = false
        default:
            break
        }
    }

    /// 开机自检：指针从 0 扫到满量程 → 回零 → 数据卡片逐个浮现
    private func runBootSequence() {
        bootTimer?.invalidate()
        booting = true
        revealCards = false
        bootProgress = 0
        bootRPM = 0

        let seg = 0.42          // 每段时长
        let total = seg * 4     // 0→9 → 9→0 → 0→9 → 9→0，一个完整轮回
        let started = Date()

        bootTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            let elapsed = Date().timeIntervalSince(started)

            if elapsed <= total {
                let idx = min(3, Int(elapsed / seg))          // 第几段
                let k = (elapsed - Double(idx) * seg) / seg   // 段内进度
                let eased = 1 - pow(1 - k, 2.0)
                let goingUp = (idx % 2 == 0)
                let v = goingUp ? eased : (1 - eased)
                bootProgress = v
                bootRPM = maxRPM * v
            } else {
                // 第四段结束时已经回到 0，直接收尾
                timer.invalidate()
                bootProgress = 0
                bootRPM = 0
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                    withAnimation(.easeOut(duration: 0.42)) { revealCards = true }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
                    booting = false
                }
            }
        }
    }
}

