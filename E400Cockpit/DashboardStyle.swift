import Foundation
import SwiftUI

// MARK: - 仪表样式

/// 三套仪表骨架。连接逻辑（CockpitCentral / BmsCentral）与 UI 完全解耦，
/// 所以换样式只是换一个 View，不影响任何蓝牙行为。
///
/// 0.5.0 收敛成霓虹（圆盘 + 进度弧，默认）与红黑（斜梯 + 巨字，全屏特效）两套；
/// 0.5.1 加上粉黑（顶弧刻度 + 粉光核心）。
/// 赛道 / 液态 / 示波 / 轨道已经删掉——同一份数据做四套近似画法，维护成本高、
/// 实际只会用一套，不如把两套打磨到位。
enum DashboardStyle: String, CaseIterable, Identifiable {
    case neon
    case redline
    case pink

    var id: String { rawValue }

    var title: String {
        switch self {
        case .neon:    return "霓虹"
        case .redline: return "红黑"
        case .pink:    return "粉黑"
        }
    }

    /// 设置里样式卡片下面那行小字
    var caption: String {
        switch self {
        case .neon:    return "圆盘表 · 发光进度弧"
        case .redline: return "斜梯 + 巨字 · 加速整屏冲击"
        case .pink:    return "顶弧刻度 · 粉光核心"
        }
    }

    /// 旧版本存下来的样式名（race / liquid / scope / orbit）读出来会失败，
    /// 统一退回霓虹，不至于开机白屏。
    static func stored(_ raw: String) -> DashboardStyle {
        DashboardStyle(rawValue: raw) ?? .neon
    }
}

enum StyleStore {
    static let key = "dashboard_style"
}

/// 仪表页入口：按设置里的样式分发
struct DashboardRoot: View {
    @AppStorage("dashboard_style") private var styleRaw = DashboardStyle.neon.rawValue

    var body: some View {
        switch DashboardStyle.stored(styleRaw) {
        case .neon:    NeonDashboard()
        case .redline: RedlineDashboard()
        case .pink:    PinkDashboard()
        }
    }
}

// MARK: - 设计稿铺满容器

/// 1280×720 设计稿「铺满」容器的唯一正确姿势。
///
/// 之前每个仪表都写了一遍 `s = min(h/720, w/1280)` + `.scaleEffect(s)`，
/// 结果真机上一整块内容只占屏幕中间、左右各留一条黑边——原因是三件事叠在一起：
/// 1. `.scaleEffect` 只改「画出来」的大小，不改布局大小。宽 1456 的画布缩到 0.54，
///    在布局里仍然算 1456 宽，父视图按 1456 排版，缩放后再以**中心**为锚缩回去，
///    整块内容就被推到右下方，左边留黑；
/// 2. 画布 `w` 大于容器，ZStack 跟着变大，再被外层 `.frame(容器)` 一居中，又偏一次；
/// 3. 横屏时左右还有一条安全区，没人去吃掉它。
///
/// 这里把三件事一次解决：缩放只按高度算、宽度反推（永远够宽）、锚点钉在左上角、
/// 最外面再套一个刚好等于容器的 frame 并裁掉溢出。
struct FullBleedCanvas<Content: View>: View {
    var design: CGSize = CGSize(width: 1280, height: 720)
    @ViewBuilder var content: (_ canvasWidth: CGFloat, _ scale: CGFloat) -> Content

    var body: some View {
        GeometryReader { geo in
            // 正常情况下（横屏 iPhone 比 16:9 宽）按高度定缩放，宽度反推，
            // 一个像素黑边都不剩；比 16:9 更窄的容器（iPad）才退回按宽度缩放，
            // 宁可上下留黑，也不把内容裁掉。
            let s = max(min(geo.size.height / design.height,
                            geo.size.width / design.width), 0.01)
            let w = max(design.width, geo.size.width / s)
            let ox = max(0, (geo.size.width - w * s) / 2)
            let oy = max(0, (geo.size.height - design.height * s) / 2)

            content(w, s)
                .frame(width: w, height: design.height, alignment: .topLeading)
                .scaleEffect(s, anchor: .topLeading)
                .offset(x: ox, y: oy)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
                .clipped()
        }
        .ignoresSafeArea(edges: [.horizontal, .top])
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - 一份数据，两种画法

/// 把两个 Central 的实时数据摘成纯值。
/// 各样式自己决定怎么排版、用什么精度，这里只做搬运，不做字符串拼装。
struct DashData {
    var name = "LBMC"
    var online = false
    var speed = 0.0
    var trip = 0.0
    var source = "—"
    var gpsText = "——"
    var gpsOk = false

    var watts = 0.0
    var busV = 0.0
    var busA = 0.0
    var phaseA = 0.0
    var ctrlT: Double?
    var motorT: Double?
    var rpm = 0
    var fault: UInt32 = 0

    var hasBms = false
    var soc = 0
    var packV = 0.0
    var packA = 0.0
    var packT = 0
    var deltaV = 0.0
    var cells = 0
    var soh = 0

    init() {}

    init(central: CockpitCentral, bms: BmsCentral) {
        name = central.connectedName ?? "LBMC"
        online = central.phase == .online
        speed = central.speedKmh
        trip = central.tripKm
        source = central.speedSourceLabel
        gpsOk = central.gpsActive
        if central.gpsAccuracyM > 0 {
            gpsText = String(format: "%.0f m", central.gpsAccuracyM)
        } else {
            gpsText = central.gpsActive ? "——" : "搜索中"
        }
        if let t = central.telemetry {
            watts = t.busVoltage * t.busCurrent
            busV = t.busVoltage
            busA = t.busCurrent
            phaseA = t.phaseCurrentInferred
            ctrlT = t.controllerTemp
            motorT = t.motorTemp
            rpm = t.rpm
            fault = t.fault
        }
        if let b = bms.telemetry {
            hasBms = true
            soc = b.soc
            packV = b.packVoltage
            packA = b.current
            packT = b.temps.first ?? b.mosTemp
            deltaV = b.deltaV
            cells = b.cellCount
            soh = b.soh
        }
    }
}

// MARK: - 公共色

enum Dash {
    static let ok   = Color(red: 0.20, green: 0.95, blue: 0.55)
    static let warn = Color(red: 1.00, green: 0.62, blue: 0.20)
    static let bad  = Color(red: 1.00, green: 0.28, blue: 0.30)

    /// 控制器 / 电机温度的分级
    static func tempColor(_ v: Double?) -> Color {
        guard let v else { return .white.opacity(0.85) }
        if v >= 90 { return bad }
        if v >= 70 { return warn }
        return .white
    }

    static func socColor(_ v: Int) -> Color {
        if v <= 15 { return bad }
        if v <= 30 { return warn }
        return ok
    }

    /// 电量条、温度条这类「有上限」的量的比例
    static func ratio(_ v: Double, _ maxV: Double) -> CGFloat {
        guard maxV > 0 else { return 0 }
        return CGFloat(min(max(v / maxV, 0), 1))
    }
}

// MARK: - 装饰动画时钟

/// 液面波动、星体公转这类纯装饰动画用它驱动，30Hz 足够顺，比 60Hz 省电。
/// 只改自己的 @State，不碰 Central，所以不会引起整页重排。
final class DashClock: ObservableObject {
    @Published private(set) var tick = 0
    private var timer: Timer?
    private let hz: Double

    init(hz: Double = 30) { self.hz = hz }

    var dt: Double { 1.0 / hz }

    func start() {
        guard timer == nil else { return }
        let iv = 1.0 / hz
        timer = Timer.scheduledTimer(withTimeInterval: iv, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tick &+= 1
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}

// MARK: - 小工具

extension View {
    /// 斜切（赛道样式那种平行四边形观感）。SwiftUI 没有 skew，用仿射变换顶一下。
    func skew(_ amount: CGFloat) -> some View {
        transformEffect(CGAffineTransform(a: 1, b: 0, c: amount, d: 1, tx: 0, ty: 0))
    }
}

/// 顶部一条极细的分隔线
struct HairLine: View {
    var body: some View {
        Rectangle()
            .fill(Color.white.opacity(0.09))
            .frame(height: 1)
    }
}
