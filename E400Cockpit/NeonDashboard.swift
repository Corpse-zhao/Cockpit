import SwiftUI
import UIKit
import PhotosUI

// MARK: - 壁纸存储

enum WallpaperStore {
    static let key = "wallpaper_file"
    /// 原图（未裁剪）：留着它才能反复重新裁剪而不掉画质
    static let sourceName = "wallpaper_source.jpg"
    static let croppedName = "wallpaper.jpg"

    private static var dir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var url: URL? {
        guard let name = UserDefaults.standard.string(forKey: key), !name.isEmpty else { return nil }
        let u = dir.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    static var image: UIImage? {
        guard let u = url else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    /// 未经裁剪的原图
    static var sourceImage: UIImage? {
        let u = dir.appendingPathComponent(sourceName)
        guard FileManager.default.fileExists(atPath: u.path) else { return nil }
        return UIImage(contentsOfFile: u.path)
    }

    /// 保存原图（只在「选新壁纸」时调用）。裁剪另走 saveCropped。
    @discardableResult
    static func saveSource(_ data: Data) -> Bool {
        let u = dir.appendingPathComponent(sourceName)
        do {
            if let img = UIImage(data: data), let jpg = img.jpegData(compressionQuality: 0.94) {
                try jpg.write(to: u, options: .atomic)
            } else {
                try data.write(to: u, options: .atomic)
            }
            return true
        } catch {
            return false
        }
    }

    /// 保存裁剪结果，并 bump 版本号让仪表页刷新
    @discardableResult
    static func saveCropped(_ image: UIImage) -> Bool {
        let u = dir.appendingPathComponent(croppedName)
        guard let jpg = image.jpegData(compressionQuality: 0.88) else { return false }
        do {
            try jpg.write(to: u, options: .atomic)
            UserDefaults.standard.set(croppedName, forKey: key)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaper_version")
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(croppedName))
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(sourceName))
        UserDefaults.standard.removeObject(forKey: key)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: "wallpaper_version")
    }
}

// MARK: - 背景

struct WallpaperBackground: View {
    @AppStorage("wallpaper_version") private var version = 0.0
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

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
                    // 主题色叠色，统一色调
                    theme.accent.opacity(0.16)
                } else {
                    LinearGradient(
                        colors: [theme.baseDark, theme.deep, theme.baseDark],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                    Circle()
                        .fill(theme.accent.opacity(0.45))
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
    var powerKW: Double
    var temp: Double?
    var voltage: Double
    var maxSpeed: Double        // 满量程车速，默认 140

    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue
    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    private let sweep: Double = 270
    /// 主刻度数量：0,20,40…140 共 8 个
    private var majorCount: Int { 8 }

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
                    .stroke(theme.accent.opacity(0.75), lineWidth: 2)
                    .frame(width: side * 0.64, height: side * 0.64)
                    .blur(radius: 5)
                Circle()
                    .stroke(theme.accent.opacity(0.35), lineWidth: 1)
                    .frame(width: side * 0.64, height: side * 0.64)

                // 轨道（270° 白弧）
                Circle()
                    .trim(from: 0, to: sweep / 360)
                    .stroke(Color.white.opacity(0.94), style: StrokeStyle(lineWidth: ring, lineCap: .butt))
                    .rotationEffect(.degrees(90))
                    .frame(width: R * 2, height: R * 2)

                // 进度（品红填充）——跟指针同步，表示车速占满量程的比例
                if p > 0.001 {
                    Circle()
                        .trim(from: 0, to: sweep / 360 * p)
                        .stroke(
                            LinearGradient(colors: theme.gradientColors,
                                           startPoint: .leading, endPoint: .trailing),
                            style: StrokeStyle(lineWidth: ring, lineCap: .butt)
                        )
                        .rotationEffect(.degrees(90))
                        .frame(width: R * 2, height: R * 2)
                }

                // 主刻度数字：0 / 20 / … / 140
                ForEach(0..<majorCount, id: \.self) { i in
                    let deg = 90 + sweep * Double(i) / Double(majorCount - 1)
                    let rad = deg * .pi / 180
                    let rr = R - ring * 0.95
                    Text("\(Int(maxSpeed) * i / (majorCount - 1))")
                        .font(.system(size: side * 0.046, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .position(x: cx + cos(rad) * rr, y: cy + sin(rad) * rr)
                }

                // 次刻度（每个主刻度分 4 格）
                ForEach(0..<(majorCount * 4 - 3), id: \.self) { i in
                    let total = majorCount * 4 - 4
                    let deg = 90 + sweep * Double(i) / Double(total)
                    let rad = deg * .pi / 180
                    let r1 = R + ring * 0.52
                    let r2 = R + ring * 0.78
                    Path { path in
                        path.move(to: CGPoint(x: cx + cos(rad) * r1, y: cy + sin(rad) * r1))
                        path.addLine(to: CGPoint(x: cx + cos(rad) * r2, y: cy + sin(rad) * r2))
                    }
                    .stroke(Color.white.opacity(i % 4 == 0 ? 0.55 : 0.22),
                            lineWidth: i % 4 == 0 ? 1.6 : 1)
                }

                // 指针（按车速）
                Path { path in
                    let rad = (90 + sweep * p) * .pi / 180
                    path.move(to: CGPoint(x: cx, y: cy))
                    path.addLine(to: CGPoint(x: cx + cos(rad) * (R - ring * 0.2),
                                             y: cy + sin(rad) * (R - ring * 0.2)))
                }
                .stroke(theme.needle,
                        style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                Circle()
                    .fill(theme.needle)
                    .frame(width: side * 0.028, height: side * 0.028)

                // 中心读数：速度为主，下面补功率与电压/温度（不再显示转速）
                VStack(spacing: 0) {
                    Text(Fmt.speed(speed))
                        .font(.system(size: side * 0.150, weight: .bold, design: .rounded))
                        .foregroundColor(.white)
                        .minimumScaleFactor(0.5)
                        .lineLimit(1)
                    Text("km/h")
                        .font(.system(size: side * 0.042))
                        .foregroundColor(.white.opacity(0.62))
                        .padding(.top, -side * 0.008)

                    divider(side: side)

                    Text(String(format: "%.2f", powerKW))
                        .font(.system(size: side * 0.082, weight: .semibold, design: .rounded))
                        .foregroundColor(.white.opacity(0.92))
                        .minimumScaleFactor(0.6)
                        .lineLimit(1)
                    Text("kW")
                        .font(.system(size: side * 0.036))
                        .foregroundColor(.white.opacity(0.55))

                    divider(side: side)

                    HStack(spacing: side * 0.045) {
                        Text(String(format: "%.1fV", voltage))
                        Text(tempText)
                    }
                    .font(.system(size: side * 0.042, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.88))
                }
                .frame(width: side * 0.56)
            }
        }
    }

    private var tempText: String {
        guard let t = temp else { return "—" }
        return String(format: "%.0f℃", t)
    }

    private func divider(side: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.42))
            .frame(width: side * 0.30, height: 1)
            .padding(.vertical, side * 0.026)
    }
}

// MARK: - 左侧状态面板

struct NeonStatusPanel: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("show_motor_temp") private var showMotorTemp = true
    @AppStorage("show_bms_strip") private var showBms = true
    @AppStorage("gear_manual") private var manualGear = 0
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    @State private var showBmsDetail = false

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            // 第一、二层：控制器
            block(title: "控制器",
                  note: central.lastFrameLength == 0 ? "未连接" : "帧长 \(central.lastFrameLength)",
                  noteColor: frameLengthColor,
                  accent: Color.white.opacity(0.50),
                  rows: controllerRows)
                .frame(maxHeight: .infinity)

            // 第三、四层：电池（BMS）。没接上就只留一条占位，控制器单独铺满
            if showBms {
                if bms.telemetry != nil {
                    block(title: "电池",
                          note: bmsNote,
                          noteColor: bmsNoteColor,
                          accent: Color(red: 0.2, green: 0.95, blue: 0.55),
                          rows: bmsRows,
                          onTap: { showBmsDetail = true })
                        .frame(maxHeight: .infinity)
                } else {
                    bmsOfflineRow
                }
            }

            footer
        }
        .sheet(isPresented: $showBmsDetail) {
            BmsDetailView().environmentObject(bms)
        }
    }

    // MARK: 电池未连接

    private var bmsOfflineRow: some View {
        Button {
            showBmsDetail = true
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "battery.0")
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.38))
                Text("电池未连接")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.white.opacity(0.50))
                Text(bms.phase == .scanning ? "扫描中…" : "设置 → 电池（蚂蚁板 BMS）")
                    .font(.system(size: 9))
                    .foregroundColor(.white.opacity(0.30))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundColor(.white.opacity(0.25))
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(Color.white.opacity(0.13),
                                  style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: 一组两层

    private func block(title: String,
                       note: String?,
                       noteColor: Color,
                       accent: Color,
                       rows: [[TileSpec]],
                       onTap: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3, height: 9)
                Text(title)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(.white.opacity(0.55))
                if let note {
                    Text(note)
                        .font(.system(size: 8.5))
                        .foregroundColor(noteColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if onTap != nil {
                    Text("详情")
                        .font(.system(size: 8.5))
                        .foregroundColor(.white.opacity(0.35))
                }
            }

            VStack(spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: 8) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, spec in
                            tile(spec)
                        }
                    }
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap?() }
    }

    /// 一格数据
    private struct TileSpec {
        var key: String
        var value: String
        var color: Color
        /// 挡位格：可点、可长按
        var gear: Bool = false
    }

    // MARK: 挡位

    private func cycleGear() {
        manualGear = manualGear >= 4 ? 0 : manualGear + 1
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
                .foregroundColor(theme.accentLight)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .glassCard()
    }

    private var footer: some View {
        HStack(spacing: 10) {
            // 速度来源：GPS / 轮速，各带一个图标一眼分清
            HStack(spacing: 5) {
                Image(systemName: sourceIcon)
                    .font(.system(size: 9))
                Text(central.speedSourceLabel)
                    .font(.system(size: 10, weight: .semibold))
            }
            .foregroundColor(sourceColor)

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

    private var sourceIcon: String {
        central.speedSourceLabel == "GPS" ? "location.fill" : "arrow.triangle.2.circlepath"
    }

    private var sourceColor: Color {
        central.speedSourceLabel == "GPS"
            ? Color(red: 0.2, green: 0.95, blue: 0.55)
            : Color(red: 1.0, green: 0.72, blue: 0.35)
    }

    /// 29 字节为标准长帧（转把+挡位齐全）；24～28 缺字段；<24 只剩基础量
    private var frameLengthColor: Color {
        let n = central.lastFrameLength
        if n == 0 { return .white.opacity(0.35) }
        if n >= 29 { return Color(red: 0.2, green: 0.95, blue: 0.55) }
        if n >= 25 { return .yellow }
        return Color(red: 1.0, green: 0.55, blue: 0.25)
    }

    // MARK: 控制器数据（第 1、2 层）

    private var controllerRows: [[TileSpec]] {
        let t = central.telemetry
        let faultColor: Color = (t?.fault ?? 0) == 0
            ? Color(red: 0.2, green: 0.95, blue: 0.55)
            : Color(red: 1.0, green: 0.28, blue: 0.30)

        var first: [TileSpec] = [
            TileSpec(key: "挡位", value: gearText(t), color: .white, gear: true),
            TileSpec(key: "转速", value: t.map { "\($0.rpm)" } ?? "——", color: .white),
            TileSpec(key: "控制器温度", value: Fmt.temp(t?.controllerTemp),
                     color: tempColor(t?.controllerTemp))
        ]
        if showMotorTemp {
            first.append(TileSpec(key: "电机温度", value: Fmt.temp(t?.motorTemp),
                                  color: tempColor(t?.motorTemp)))
        } else {
            first.append(TileSpec(key: "故障码",
                                  value: (t?.fault ?? 0) == 0
                                    ? "无"
                                    : String(format: "0x%04X", (t?.fault ?? 0) & 0xFFFF),
                                  color: faultColor))
        }

        let second: [TileSpec] = [
            TileSpec(key: "母线电压", value: t.map { Fmt.num($0.busVoltage, "V") } ?? "——", color: .white),
            TileSpec(key: "母线电流", value: t.map { Fmt.num($0.busCurrent, "A") } ?? "——",
                     color: (t?.busCurrent ?? 0) < -0.005
                       ? Color(red: 0.2, green: 0.95, blue: 0.55)
                       : ((t?.busCurrent ?? 0) > 0.005 ? theme.accentLight : .white)),
            TileSpec(key: "功率",
                     value: t.map { Fmt.num($0.busVoltage * $0.busCurrent / 1000.0, "kW") } ?? "——",
                     color: .white),
            TileSpec(key: "定位精度", value: gpsText, color: gpsColor)
        ]
        return [first, second]
    }

    // MARK: 电池数据（第 3、4 层）

    private var bmsRows: [[TileSpec]] {
        guard let b = bms.telemetry else {
            let dim = Color.white.opacity(0.30)
            return [
                [TileSpec(key: "电量", value: "——", color: dim),
                 TileSpec(key: "总压", value: "——", color: dim),
                 TileSpec(key: "电池电流", value: "——", color: dim),
                 TileSpec(key: "电池功率", value: "——", color: dim)],
                [TileSpec(key: "压差", value: "——", color: dim),
                 TileSpec(key: "电池温度", value: "——", color: dim),
                 TileSpec(key: "剩余容量", value: "——", color: dim),
                 TileSpec(key: "健康 SOH", value: "——", color: dim)]
            ]
        }

        let green = Color(red: 0.2, green: 0.95, blue: 0.55)
        let powerKW = b.packVoltage * b.current / 1000.0
        let first: [TileSpec] = [
            TileSpec(key: "电量", value: "\(b.soc)%", color: socColor(b.soc)),
            TileSpec(key: "总压", value: String(format: "%.2f V", b.packVoltage), color: .white),
            TileSpec(key: "电池电流", value: String(format: "%+.2f A", b.current),
                     color: b.current > 0.05 ? green : (b.current < -0.05 ? theme.accentLight : .white)),
            TileSpec(key: "电池功率", value: String(format: "%+.2f kW", powerKW), color: .white)
        ]
        let second: [TileSpec] = [
            TileSpec(key: "压差", value: "\(Int((b.deltaV * 1000).rounded())) mV",
                     color: b.deltaV > 0.05 ? .orange : .white),
            TileSpec(key: "电池温度", value: "\(b.temps.first ?? b.mosTemp)℃",
                     color: cellTempColor(b.temps.first ?? b.mosTemp)),
            TileSpec(key: "剩余容量", value: String(format: "%.2f Ah", b.remainingAh), color: .white),
            // 有些蚂蚁板固件不填 SOH 字段，恒为 0，别让它看起来像坏了
            TileSpec(key: "健康 SOH", value: b.soh > 0 ? "\(b.soh)%" : "——",
                     color: b.soh > 0 ? .white : Color.white.opacity(0.30))
        ]
        return [first, second]
    }

    private var bmsNote: String {
        guard let b = bms.telemetry else {
            return bms.phase == .scanning ? "扫描中" : "未连接"
        }
        return "\(b.cellCount)S · \(b.temps.count) 温感"
    }

    private var bmsNoteColor: Color {
        guard bms.telemetry != nil else {
            return bms.phase == .scanning ? .orange : .white.opacity(0.35)
        }
        return Color(red: 0.2, green: 0.95, blue: 0.55)
    }

    private func socColor(_ soc: Int) -> Color {
        if soc <= 15 { return Color(red: 1.0, green: 0.28, blue: 0.30) }
        if soc <= 30 { return .orange }
        return Color(red: 0.2, green: 0.95, blue: 0.55)
    }

    private func cellTempColor(_ v: Int) -> Color {
        if v >= 55 { return Color(red: 1.0, green: 0.28, blue: 0.30) }
        if v >= 45 { return .orange }
        return .white
    }

    /// 挡位：解析值优先；解析不到就用「手动挡位」，点格子循环切换
    private func gearText(_ t: LingboParser.Telemetry?) -> String {
        if let g = t?.gear { return "P\(g)" }
        if manualGear > 0 { return "P\(manualGear)" }
        return "——"
    }

    private var gpsText: String {
        if central.gpsActive {
            return String(format: "%.0f m", central.gpsAccuracyM)
        }
        if central.gpsAccuracyM > 0 {
            return String(format: "%.0f m", central.gpsAccuracyM)
        }
        return "搜索中"
    }

    private var gpsColor: Color {
        central.gpsActive ? Color(red: 0.2, green: 0.95, blue: 0.55)
            : Color(red: 1.0, green: 0.62, blue: 0.25)
    }

    private func tempColor(_ v: Double?) -> Color {
        guard let v else { return .white }
        if v >= 90 { return Color(red: 1.0, green: 0.28, blue: 0.30) }
        if v >= 70 { return .orange }
        return .white
    }

    @ViewBuilder
    private func tile(_ s: TileSpec) -> some View {
        let card = VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(s.key)
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.60))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                if s.gear && manualGear > 0 {
                    Text("手动")
                        .font(.system(size: 7.5, weight: .semibold))
                        .padding(.horizontal, 3.5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(theme.accent.opacity(0.30)))
                        .foregroundColor(theme.accentLight)
                }
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
            Text(s.value)
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundColor(s.color)
                .lineLimit(1)
                .minimumScaleFactor(0.42)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .glassCard()

        if s.gear {
            card
                .contentShape(Rectangle())
                .onTapGesture { cycleGear() }
                .onLongPressGesture(minimumDuration: 0.6) { manualGear = 0 }
        } else {
            card
        }
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
    @EnvironmentObject var bms: BmsCentral
    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("boot_animation") private var bootAnimation = true

    @State private var hasBooted = false
    @State private var booting = false
    @State private var bootProgress: Double = 0
    @State private var bootSpeed: Double = 0
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
                    speed: booting ? bootSpeed : central.speedKmh,
                    powerKW: booting
                        ? 0
                        : (central.telemetry?.busVoltage ?? 0) * (central.telemetry?.busCurrent ?? 0) / 1000.0,
                    temp: booting ? nil : central.telemetry?.controllerTemp,
                    voltage: booting ? 0 : (central.telemetry?.busVoltage ?? 0),
                    maxSpeed: maxSpeed
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
            bms.autoReconnectIfNeeded()
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
        return min(max(central.speedKmh / max(maxSpeed, 1), 0), 1)
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
            bootSpeed = 0
            revealCards = false
        default:
            break
        }
    }

    /// 开机自检：指针按车速刻度 0→满 → 回零 → 0→满 → 回零，走完一个轮回后数据卡片浮现
    private func runBootSequence() {
        bootTimer?.invalidate()
        booting = true
        revealCards = false
        bootProgress = 0
        bootSpeed = 0

        let seg = 0.42          // 每段时长
        let total = seg * 4     // 0→满 → 满→0 → 0→满 → 满→0，一个完整轮回
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
                bootSpeed = maxSpeed * v
            } else {
                // 第四段结束时已经回到 0，直接收尾
                timer.invalidate()
                bootProgress = 0
                bootSpeed = 0
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

