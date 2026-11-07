import SwiftUI
import UIKit
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral

    // 轮胎
    @AppStorage(TireModel.Keys.rearSpec) private var rearSpec = "90/90-12 44J"
    @AppStorage(TireModel.Keys.rearPressure) private var rearPressure = 2.2
    @AppStorage(TireModel.Keys.frontSpec) private var frontSpec = "90/90-12 44J"
    @AppStorage(TireModel.Keys.frontPressure) private var frontPressure = 2.2

    // 载荷
    @AppStorage(TireModel.Keys.vehMass) private var vehMass = 100.0
    @AppStorage(TireModel.Keys.riderMass) private var riderMass = 70.0
    @AppStorage(TireModel.Keys.cargoMass) private var cargoMass = 0.0
    @AppStorage(TireModel.Keys.rearAxleRatio) private var rearAxleRatio = 0.58

    // 覆盖与换算
    @AppStorage(TireModel.Keys.useMeasured) private var useMeasured = false
    @AppStorage(TireModel.Keys.measuredCirc) private var measuredCirc = 1426.0
    @AppStorage("rpm_scale") private var rpmScale = 1.0

    // 高级系数
    @AppStorage(TireModel.Keys.deflectionRatio) private var deflectionRatio = 0.060
    @AppStorage(TireModel.Keys.rollFactor) private var rollFactor = 0.62

    // 连接
    @AppStorage("scan_all_devices") private var scanAllDevices = false
    @AppStorage("last_transport") private var lastTransport = "未连接"
    @AppStorage("controller_label") private var controllerLabel = "未设置"
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("value_decimals") private var decimals = 2
    @AppStorage("show_motor_temp") private var showMotorTemp = true
    @AppStorage("show_bms_strip") private var showBms = true
    @AppStorage("bms_auto_reconnect") private var bmsAuto = true

    @AppStorage("gauge_max_speed") private var maxSpeed = 140.0
    @AppStorage("boot_animation") private var bootAnimation = true
    @AppStorage("speed_source") private var speedSource = "auto"
    @State private var pickedWallpaper: PhotosPickerItem?
    @State private var hasWallpaper = WallpaperStore.url != nil
    @State private var cropSource: UIImage?

    // 主题
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    // 协议字段偏移覆盖
    @AppStorage("throttle_offset") private var throttleOffset = -1
    @AppStorage("gear_offset") private var gearOffset = -1
    @AppStorage("gear_short_fallback") private var gearShortFallback = false
    @AppStorage("long_realtime_request") private var longRealtime = false

    @State private var showAdvanced = false
    @State private var showFieldOffsets = false
    @State private var activeSheet: ActiveSheet?

    /// 同一个视图上挂多个 .sheet 在 iOS 16 会互相顶掉，统一走一个 item 枚举
    private enum ActiveSheet: String, Identifiable {
        case gearFinder
        case crop
        case bmsDetail
        var id: String { rawValue }
    }

    // MARK: 实时估算

    private var config: TireModel.Config {
        var c = TireModel.Config()
        c.rearSpec = rearSpec
        c.rearPressure = rearPressure
        c.frontSpec = frontSpec
        c.frontPressure = frontPressure
        c.vehMass = vehMass
        c.riderMass = riderMass
        c.cargoMass = cargoMass
        c.rearAxleRatio = rearAxleRatio
        c.useMeasured = useMeasured
        c.measuredCirc = measuredCirc
        c.deflectionRatio = deflectionRatio
        c.rollFactor = rollFactor
        return c
    }

    private var rearEst: TireEstimate? { config.rearEstimate }
    private var frontEst: TireEstimate? { config.frontEstimate }

    private var effectiveCirc: Double {
        if useMeasured && measuredCirc > 600 { return measuredCirc }
        return rearEst?.rollCircumferenceMM ?? 1426
    }

    var body: some View {
        Form {
            appearanceSection
            speedSourceSection
            connectionSection
            batterySection
            vehicleSection
            sensorSection
            rearTireSection
            estimateSection
            frontTireSection
            overrideSection
            rpmSection
            fieldOffsetSection
            advancedSection
            aboutSection
        }
        .frame(maxWidth: 920)
        .frame(maxWidth: .infinity)
        .scrollContentBackground(.hidden)
        .background(Color.black.ignoresSafeArea())
        .onChange(of: pickedWallpaper) { item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self),
                   WallpaperStore.saveSource(data),
                   let img = WallpaperStore.sourceImage {
                    cropSource = ImageTools.normalized(img)
                    activeSheet = .crop
                }
                pickedWallpaper = nil
            }
        }
        .sheet(item: $activeSheet) { which in
            switch which {
            case .gearFinder:
                GearFinderView()
                    .environmentObject(central)
            case .crop:
                if let src = cropSource {
                    WallpaperCropView(
                        source: src,
                        onCancel: { activeSheet = nil },
                        onDone: { img in
                            WallpaperStore.saveCropped(img)
                            hasWallpaper = true
                            activeSheet = nil
                        }
                    )
                }
            case .bmsDetail:
                BmsDetailView()
                    .environmentObject(bms)
            }
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section {
            themePicker

            PhotosPicker(selection: $pickedWallpaper, matching: .images, photoLibrary: .shared()) {
                Label(hasWallpaper ? "更换壁纸" : "选择壁纸图片", systemImage: "photo.on.rectangle.angled")
            }
            if hasWallpaper {
                Button {
                    if let img = WallpaperStore.sourceImage {
                        cropSource = ImageTools.normalized(img)
                        activeSheet = .crop
                    }
                } label: {
                    Label("重新裁剪显示区域", systemImage: "crop")
                }
                Button(role: .destructive) {
                    WallpaperStore.clear()
                    hasWallpaper = false
                } label: {
                    Label("移除壁纸，用默认渐变", systemImage: "trash")
                }
            }
            Toggle("开机自检动画", isOn: $bootAnimation)
            Picker("表盘满量程", selection: $maxSpeed) {
                Text("100").tag(100.0)
                Text("120").tag(120.0)
                Text("140").tag(140.0)
                Text("160").tag(160.0)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("壁纸导入后可以拖动、双指缩放来挑显示区域，框内就是仪表页真正显示的范围，原始图会单独留存，随时能重新裁剪而不会越裁越糊。\n\n主题色只改强调色这一条主轴（进度弧、发光、关键数值、按钮），毛玻璃卡片和白色刻度保持不变。圆盘指针指示车速，满量程默认 140 km/h。")
        }
    }

    // MARK: 主题色

    private var themePicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("主题色")
                    .font(.subheadline)
                Spacer()
                Text(ThemeStore.preset(for: themeID).title)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(ThemePreset.allCases) { p in
                        Button {
                            themeID = p.rawValue
                        } label: {
                            VStack(spacing: 5) {
                                Circle()
                                    .fill(LinearGradient(colors: p.gradientColors,
                                                         startPoint: .topLeading,
                                                         endPoint: .bottomTrailing))
                                    .frame(width: 34, height: 34)
                                    .overlay(
                                        Circle().stroke(Color.white,
                                                        lineWidth: themeID == p.rawValue ? 2.5 : 0)
                                    )
                                    .overlay(
                                        Image(systemName: "checkmark")
                                            .font(.system(size: 13, weight: .bold))
                                            .foregroundColor(.white)
                                            .shadow(radius: 2)
                                            .opacity(themeID == p.rawValue ? 1 : 0)
                                    )
                                    .shadow(color: p.accent.opacity(0.6), radius: 6)
                                Text(p.title)
                                    .font(.system(size: 9))
                                    .foregroundColor(themeID == p.rawValue ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
                .padding(.horizontal, 2)
            }
        }
    }

    // MARK: 连接

    private var connectionSection: some View {
        Section {
            Toggle("扫描时显示所有蓝牙设备", isOn: $scanAllDevices)

            HStack {
                Text("控制器")
                Spacer()
                TextField("连接后自动识别", text: $controllerLabel)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .frame(width: 190)
            }

            if let id = central.identity {
                HStack(spacing: 6) {
                    Text("已识别")
                    Text(id.suggestedLabel ?? "—")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                    Text(id.source)
                        .font(.caption2)
                        .foregroundColor(.gray)
                    Spacer()
                    if let s = id.suggestedLabel, s != controllerLabel {
                        Button("采用") { controllerLabel = s }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                    }
                }
            }

            if !central.modelCandidates.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("帧内发现的字符串（点击填入）")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(central.modelCandidates, id: \.self) { c in
                                Button(c) { controllerLabel = c }
                                    .font(.system(.caption2, design: .monospaced))
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                }
            }

            HStack {
                Text("车型")
                Spacer()
                TextField("自己填，如 九号 E80c MK2", text: $vehicleLabel)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .frame(width: 210)
            }

            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text("数值小数位")
                    Spacer()
                    Text("速度固定整数")
                        .font(.caption2)
                        .foregroundColor(.gray)
                }
                Picker("数值小数位", selection: $decimals) {
                    Text("0 位").tag(0)
                    Text("1 位").tag(1)
                    Text("2 位").tag(2)
                    Text("3 位").tag(3)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            LabeledContent("当前通道", value: lastTransport)
            LabeledContent("协议驱动", value: "凌博 Lingbo（AA55）")
        } header: {
            Text("连接与显示")
        } footer: {
            Text("控制器型号连上后从广播名自动识别（LBMC- 后面那串），也会把数据帧里出现的可打印字符串收集成候选。车型和控制器都可以手改，改过之后不再自动覆盖。小数位影响电压/电流/功率/温度/转把，速度保持整数。")
        }
    }

    // MARK: 电池（BMS）

    private var batterySection: some View {
        Section {
            Toggle("仪表页显示电池条", isOn: $showBms)
            Toggle("启动时自动重连上次电池", isOn: $bmsAuto)

            HStack(spacing: 6) {
                Text("状态")
                Spacer()
                Circle()
                    .fill(bmsColor)
                    .frame(width: 7, height: 7)
                Text(bms.phase.rawValue)
                    .foregroundColor(bmsColor)
                if let n = bms.connectedName {
                    Text("· \(n)")
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }

            if let t = bms.telemetry {
                Button {
                    activeSheet = .bmsDetail
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(t.soc)%")
                                .font(.title3.weight(.bold))
                                .monospacedDigit()
                            Text("\(t.cellCount)S · 压差 \(Int((t.deltaV * 1000).rounded())) mV")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(String(format: "%.2f V", t.packVoltage))
                                .monospacedDigit()
                            Text(String(format: "%+.2f A", t.current))
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundColor(t.current < -0.05 ? .green : .primary)
                        }
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                LabeledContent("温感", value: "\(t.temps.count) 路 · MOS \(t.mosTemp)℃")
                LabeledContent("已收帧", value: "\(bms.frameCount)")
            }

            if bms.phase == .scanning {
                Button("停止扫描") { bms.stopScan() }
            } else if bms.phase == .online || bms.phase == .connecting {
                Button("断开电池") { bms.disconnect() }
            } else {
                Button {
                    bms.startScan()
                } label: {
                    Label("扫描电池（蚂蚁板 FFE0）", systemImage: "battery.100.bolt")
                }
                if bms.hasLastDevice {
                    Button {
                        bms.reconnectLast()
                    } label: {
                        Label("重连上次电池", systemImage: "arrow.clockwise")
                    }
                }
            }

            if let err = bms.lastError {
                Label(err, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            if !bms.devices.isEmpty {
                ForEach(bms.devices) { d in
                    Button {
                        bms.connect(d)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: d.likely ? "battery.100.bolt" : "dot.radiowaves.left.and.right")
                                .font(.footnote)
                                .foregroundColor(d.likely ? .green : .secondary)
                            Text(d.name)
                                .lineLimit(1)
                            if d.likely {
                                Text("疑似 BMS")
                                    .font(.caption2)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 1)
                                    .background(Capsule().fill(Color.green.opacity(0.18)))
                                    .foregroundColor(.green)
                            }
                            Spacer()
                            Text("\(d.rssi)")
                                .font(.caption.monospacedDigit())
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            if bms.hasLastDevice {
                Button(role: .destructive) {
                    bms.forgetLast()
                } label: {
                    Label("忘记这块电池", systemImage: "trash")
                        .font(.footnote)
                }
            }
        } header: {
            Text("电池（蚂蚁板 BMS）")
        } footer: {
            Text("电池走完全独立的一条蓝牙链路：FFE0/FFE1/FFE2，读蚂蚁板 7E A1 帧，跟控制器的 FFF0 互不干扰——不接电池，或者电池离线，仪表照常跑。\n\n连上后每秒要一次状态：SOC、总压、电流、单体电压与压差、各探头温度、MOS 开关与均衡状态。仪表页底部会多出一条电池条，点它进详情看单体柱状图和温度。\n\n广播里带 FFE0、或名字含 ANT / BMS / JBD / DALY / JK 的设备会被标成「疑似 BMS」排在最前，其余是普通蓝牙设备，拿不准就看信号强度。")
        }
    }

    private var bmsColor: Color {
        switch bms.phase {
        case .online: return .green
        case .connecting: return .yellow
        case .scanning: return .orange
        case .idle: return .secondary
        }
    }

    // MARK: 测速来源

    private var speedSourceSection: some View {
        Section {
            Picker("测速来源", selection: $speedSource) {
                Text("GPS 优先").tag("auto")
                Text("只用 GPS").tag("gps")
                Text("只用轮速").tag("wheel")
            }
            .pickerStyle(.segmented)

            HStack {
                Text("当前表显")
                Spacer()
                Text(String(format: "%.2f km/h", central.speedKmh))
                    .monospacedDigit()
                    .foregroundColor(sourceColor)
            }
            LabeledContent("GPS 状态", value: central.gpsStatusText)
            LabeledContent("GPS 速度", value: central.gpsActive
                           ? String(format: "%.2f km/h", central.gpsSpeedKmh) : "—")
            LabeledContent("轮速换算", value: String(format: "%.2f km/h", central.wheelSpeedKmh))

            if let dev = wheelDeviation {
                HStack {
                    Text("轮速偏差")
                    Spacer()
                    Text(dev.0)
                        .monospacedDigit()
                        .foregroundColor(abs(dev.1) > 5 ? .orange : .secondary)
                }
            }
        } header: {
            Text("测速来源")
        } footer: {
            Text("默认「GPS 优先」：有 GPS 速度就用 GPS，进隧道/地库失锁时自动退回轮速换算，出隧道再切回来。\n\nGPS 速度来自 CoreLocation 的多普勒解算，精度通常 ±0.5 km/h，不受胎压、载重、磨损、下沉量影响——比轮周长估算可靠得多。下面的「轮速偏差」可以直接告诉你这套轮胎模型差了几个百分点，想校周长就照着改。")
        }
    }

    private var sourceColor: Color {
        central.speedSourceLabel == "GPS" ? .green : .orange
    }

    /// (文案, 百分比偏差)；GPS 与轮速都在动的时候才有意义
    private var wheelDeviation: (String, Double)? {
        guard central.gpsActive,
              central.gpsSpeedKmh > 2,
              central.wheelSpeedKmh > 2 else { return nil }
        let d = central.wheelSpeedKmh - central.gpsSpeedKmh
        let pct = d / max(central.gpsSpeedKmh, 0.1) * 100
        return (String(format: "%+.2f km/h（%+.1f%%）", d, pct), pct)
    }

    // MARK: 车辆与载荷

    private var vehicleSection: some View {
        Section {
            massRow("整车质量", value: $vehMass, unit: "kg")
            massRow("骑手质量", value: $riderMass, unit: "kg")
            massRow("载物/尾箱", value: $cargoMass, unit: "kg")

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("后轮承重比例")
                    Spacer()
                    Text(String(format: "%.0f%%", rearAxleRatio * 100))
                        .foregroundColor(.secondary)
                        .monospacedDigit()
                }
                Slider(value: $rearAxleRatio, in: 0.40...0.75, step: 0.01)
                HStack {
                    Text("后轴 \(String(format: "%.0f", config.rearAxleLoadKg)) kg")
                    Spacer()
                    Text("前轴 \(String(format: "%.0f", config.frontAxleLoadKg)) kg")
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Text("踏板车电池与电机偏后，后轮通常承担 55–62%。不确定就保持 58%，这个值只影响下沉量的两三个百分点。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("车辆与载荷")
        } footer: {
            Text("总质量 \(String(format: "%.0f", vehMass + riderMass + cargoMass)) kg")
        }
    }

    // MARK: 传感器

    private var sensorSection: some View {
        Section {
            Toggle("显示电机温度", isOn: $showMotorTemp)
        } header: {
            Text("传感器")
        } footer: {
            Text("有些车型的电机没有内置温感，协议里这个字段会恒为 0——关掉后仪表页不再显示该格，网格自动重排，也不会留一格永远 0.00 ℃ 的摆设数据。控制器温度始终显示。")
        }
    }

    // MARK: 后轮（驱动轮）
    private var rearTireSection: some View {
        Section {
            HStack {
                Text("规格")
                Spacer()
                TextField("90/90-12 44J", text: $rearSpec)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .frame(width: 150)
            }
            HStack(spacing: 6) {
                ForEach(["90/90-12 44J", "100/90-12", "120/70-12", "3.50-10"], id: \.self) { s in
                    Button(s) { rearSpec = s }
                        .font(.caption2)
                        .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Text("胎压")
                Spacer()
                TextField("bar", value: $rearPressure, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("bar").foregroundColor(.gray)
            }

            if let spec = TireModel.parse(rearSpec) {
                LabeledContent("自由外径", value: spec.diameterText)
                LabeledContent("单胎额定载荷", value: String(format: "%.0f kg", spec.ratedLoadKg))
            } else {
                Label("规格无法识别，请照侧壁抄写，如 90/90-12 44J", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        } header: {
            Text("后轮（驱动轮 · 测速用）")
        } footer: {
            Text("规格看轮胎侧壁；末尾的 44J 是载重指数，能填就填，模型靠它判断这条胎有多硬。")
        }
    }

    // MARK: 估算结果

    private var estimateSection: some View {
        Section {
            if let e = rearEst {
                LabeledContent("静态下沉量", value: Fmt.num(e.staticDeflectionMM, "mm"))
                LabeledContent("滚动半径", value: Fmt.num(e.rollRadiusMM, "mm"))
                LabeledContent("滚动周长", value: Fmt.num(e.rollCircumferenceMM, "mm"))
                LabeledContent("相对自由周长", value: e.shrinkPercentText)

                HStack {
                    Text("当前生效周长")
                        .fontWeight(.semibold)
                    Spacer()
                    Text(Fmt.num(effectiveCirc, "mm"))
                        .fontWeight(.semibold)
                        .monospacedDigit()
                        .foregroundColor(.accentColor)
                    Text(useMeasured ? "实测" : "估算")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }

                // 下沉可视化：自由轮廓 + 压扁后的接地面
                deflectionDiagram(e)
                    .padding(.vertical, 6)
            } else {
                Text("填好轮胎规格后这里显示估算结果")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } header: {
            Text("下沉与周长估算")
        } footer: {
            Text("这一套只在「轮速」模式下影响车速。现在默认用 GPS 测速，这里的估算主要用来给隧道里兜底，以及在「测速来源」里和 GPS 对比偏差。")
        }
    }

    private func deflectionDiagram(_ e: TireEstimate) -> some View {
        let r0 = e.spec.freeRadiusMM
        let rRoll = e.rollRadiusMM
        let delta = e.staticDeflectionMM
        let maxH: CGFloat = 110
        let scale = maxH / CGFloat(max(r0 * 2, 1))

        return HStack(alignment: .bottom, spacing: 26) {
            // 自由状态
            VStack(spacing: 6) {
                ZStack {
                    Circle()
                        .stroke(Color.secondary.opacity(0.55), lineWidth: 2)
                        .frame(width: CGFloat(r0 * 2) * scale, height: CGFloat(r0 * 2) * scale)
                    Circle()
                        .strokeBorder(Color.secondary.opacity(0.25), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .frame(width: CGFloat(r0) * scale, height: CGFloat(r0) * scale)
                }
                .frame(height: maxH)
                Text("自由")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(String(format: "R%.0f", r0))
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
            }

            // 受压状态
            VStack(spacing: 6) {
                ZStack(alignment: .bottom) {
                    Ellipse()
                        .stroke(Color.accentColor, lineWidth: 2)
                        .frame(width: CGFloat(r0 * 2) * scale, height: CGFloat(r0 * 2 - delta) * scale)
                }
                .frame(height: maxH)
                Text("受压")
                    .font(.caption2)
                    .foregroundColor(.accentColor)
                Text(String(format: "R%.0f", rRoll))
                    .font(.caption2.monospaced())
                    .foregroundColor(.accentColor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: 前轮

    private var frontTireSection: some View {
        Section {
            HStack {
                Text("规格")
                Spacer()
                TextField("90/90-12 44J", text: $frontSpec)
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .frame(width: 150)
            }
            HStack {
                Text("胎压")
                Spacer()
                TextField("bar", value: $frontPressure, format: .number.precision(.fractionLength(1)))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 70)
                Text("bar").foregroundColor(.gray)
            }
            if let e = frontEst {
                LabeledContent("前轮下沉", value: Fmt.num(e.staticDeflectionMM, "mm"))
                LabeledContent("前轮滚动周长", value: Fmt.num(e.rollCircumferenceMM, "mm"))
            }
        } header: {
            Text("前轮（仅参考）")
        } footer: {
            Text("E80c 是轮毂电机后驱，测速里程都取后轮。前轮这里只做对比，方便你检查前后磨损与胎压是否一致。")
        }
    }

    // MARK: 实测覆盖

    private var overrideSection: some View {
        Section {
            Toggle("用实测周长覆盖估算", isOn: $useMeasured)
            if useMeasured {
                HStack {
                    Text("实测滚动周长")
                    Spacer()
                    TextField("mm", value: $measuredCirc, format: .number)
                        .keyboardType(.numberPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                    Text("mm").foregroundColor(.gray)
                }
                if let e = rearEst {
                    let diff = measuredCirc - e.rollCircumferenceMM
                    LabeledContent("与估算差", value: String(format: "%+.2f mm（%+.2f%%）",
                                                       diff, diff / max(e.rollCircumferenceMM, 1) * 100))
                }
            }
        } header: {
            Text("实测校准")
        } footer: {
            Text("滚动法：气门嘴对地做记号，向前推整圈再量两个记号的距离。若实测与估算差超过 3%，说明轮胎实际刚度或胎压与假设不同，建议以实测为准。轮轴距和轮胎的滚动周长不相同，需要分开计算。")
        }
    }

    // MARK: 转速

    private var rpmSection: some View {
        Section {
            Picker("RPM 倍率", selection: $rpmScale) {
                Text("×1").tag(1.0)
                Text("×0.1").tag(0.1)
                Text("×0.01").tag(0.01)
                Text("×10").tag(10.0)
            }
            .pickerStyle(.segmented)
            Text("若速度差一个数量级：在「数据台」看原始 rpm，与已知车速对比后选倍率（官方 App 显示过 x100RPM，故留此开关）。")
                .font(.caption)
                .foregroundColor(.secondary)
        } header: {
            Text("转速换算")
        }
    }

    // MARK: 字段布局（挡位 / 转把）

    private var fieldOffsetSection: some View {
        Section {
            Button {
                activeSheet = .gearFinder
            } label: {
                Label("打开挡位定位工具（差分找偏移）", systemImage: "scope")
                    .font(.subheadline)
            }

            HStack {
                Text("最近帧长")
                Spacer()
                Text(central.lastFrameLength == 0 ? "未收到" : "\(central.lastFrameLength) 字节")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(frameLengthColor)
            }

            HStack {
                Text("转把")
                Spacer()
                Text(throttleReadout)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(central.fieldTrace.throttleOffset == nil ? .secondary : .primary)
            }

            HStack {
                Text("挡位")
                Spacer()
                Text(gearReadout)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(central.fieldTrace.gearOffset == nil ? .secondary : .primary)
            }

            DisclosureGroup("手动调整字段偏移", isExpanded: $showFieldOffsets) {
                Toggle("向控制器要「长帧」（AA 55 1A 22 3B）", isOn: $longRealtime)
                    .font(.subheadline)
                Text("默认请求是把 LEN 压到 0x02，你的控制器只回 23 字节的精简帧，转把和挡位就被裁掉了。打开这个开关改成要 29 字节那份完整帧——官方 App 既然能显示转把，控制器里多半是有的。若控制器不认这个请求，3 秒内没有实时数据会自动退回，不会把仪表弄哑。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                offsetStepper("转把电压偏移", value: $throttleOffset, autoLabel: "自动 @22")
                offsetStepper("挡位偏移", value: $gearOffset, autoLabel: "自动 @27")

                Toggle("短帧挡位回退（读 @24 低 4 位）", isOn: $gearShortFallback)
                    .font(.subheadline)

                Text("标准 29 字节帧里挡位在 @27、转把在 @22。若你的控制器只回 24～28 字节，这两个字段就在帧外了——把偏移往前挪，或者打开短帧回退试试。每一步改动下一帧（500ms）立刻生效，改到仪表页的「挡位」出现合理数字为止。")
                    .font(.caption2)
                    .foregroundColor(.secondary)

                Button("全部恢复自动") {
                    throttleOffset = -1
                    gearOffset = -1
                    gearShortFallback = false
                    longRealtime = false
                }
                .font(.caption)
            }

            Button {
                UIPasteboard.general.string = central.diagnosticReport()
            } label: {
                Label("复制协议诊断（发给我就能定位）", systemImage: "doc.on.doc")
                    .font(.footnote)
            }
        } header: {
            Text("挡位与转把")
        } footer: {
            Text("这两格有值的前提是：帧里真的带了这两个字段。帧长 ≥ 25 才有转把，≥ 29 才有标准挡位。仪表页右下角的「帧长」颜色就是判据：绿=字段齐全，黄=缺挡位，橙=基本量。")
        }
    }

    private var frameLengthColor: Color {
        let n = central.lastFrameLength
        if n == 0 { return .secondary }
        if n >= 29 { return .green }
        if n >= 25 { return .yellow }
        return .orange
    }

    private var throttleReadout: String {
        guard let v = central.telemetry?.throttleVolts else { return "无（帧长 \(central.lastFrameLength)）" }
        let off = central.fieldTrace.throttleOffset.map { "@\($0)" } ?? ""
        let pct = central.telemetry?.throttlePercent ?? 0
        return String(format: "%.2f V %@ · %.0f%%", v, off, pct)
    }

    private var gearReadout: String {
        guard let g = central.telemetry?.gear else { return "无（帧长 \(central.lastFrameLength)）" }
        let off = central.fieldTrace.gearOffset.map { "@\($0)" } ?? ""
        let tag = central.fieldTrace.gearFallback ? " · 回退" : ""
        return "P\(g) \(off)\(tag)"
    }

    private func offsetStepper(_ title: String, value: Binding<Int>, autoLabel: String) -> some View {
        HStack {
            Text(title)
                .font(.subheadline)
            Spacer()
            Text(value.wrappedValue < 0 ? autoLabel : "@\(value.wrappedValue)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
            Stepper("", value: value, in: -1...40)
                .labelsHidden()
        }
    }

    // MARK: 高级

    private var advancedSection: some View {
        Section {
            DisclosureGroup("模型系数（懂再动）", isExpanded: $showAdvanced) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("参考下沉率")
                        Spacer()
                        Text(String(format: "%.1f%%", deflectionRatio * 100))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $deflectionRatio, in: 0.035...0.090, step: 0.005)
                    Text("额定载荷下静态下沉占自由半径的比例。硬胎/高胎压取小值，舒适取向软胎取大值。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("滚动有效系数")
                        Spacer()
                        Text(String(format: "%.2f", rollFactor))
                            .monospacedDigit()
                            .foregroundColor(.secondary)
                    }
                    Slider(value: $rollFactor, in: 0.40...0.85, step: 0.01)
                    Text("滚动半径 = 自由半径 − 系数 × 静态下沉。0.62 对应常见的子午/斜交踏板车胎。")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Button("恢复默认（6.0% / 0.62）") {
                    deflectionRatio = 0.060
                    rollFactor = 0.62
                }
                .font(.caption)
            }
        } header: {
            Text("高级")
        }
    }

    // MARK: 关于

    private var aboutSection: some View {
        Section {
            LabeledContent("名称", value: AppInfo.name)
            LabeledContent("版本", value: AppInfo.versionText)
            LabeledContent("协议", value: "凌博 AA55 / FFF0·FFF1·FFF2")
            LabeledContent("电池协议", value: "蚂蚁板 7E A1 / FFE0·FFE1·FFE2")
            LabeledContent("通道发现", value: "FFF0 优先，否则自动探测")
            LabeledContent("测速", value: "GPS（CoreLocation）优先，轮速兜底")
            LabeledContent("屏幕方向", value: "横屏")
        } header: {
            Text("关于")
        }
    }

    // MARK: 小组件

    private func massRow(_ title: String, value: Binding<Double>, unit: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            TextField(unit, value: value, format: .number.precision(.fractionLength(0)))
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.trailing)
                .frame(width: 80)
            Text(unit).foregroundColor(.gray)
        }
    }
}
