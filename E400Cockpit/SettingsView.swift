import SwiftUI
import PhotosUI

struct SettingsView: View {
    @EnvironmentObject var central: CockpitCentral

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

    @AppStorage("gauge_max_rpm") private var maxRPM = 9000.0
    @AppStorage("boot_animation") private var bootAnimation = true
    @State private var pickedWallpaper: PhotosPickerItem?
    @State private var hasWallpaper = WallpaperStore.url != nil

    @State private var showAdvanced = false

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
            connectionSection
            vehicleSection
            sensorSection
            rearTireSection
            estimateSection
            frontTireSection
            overrideSection
            rpmSection
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
                   WallpaperStore.save(data) {
                    hasWallpaper = true
                }
                pickedWallpaper = nil
            }
        }
    }

    // MARK: 外观

    private var appearanceSection: some View {
        Section {
            PhotosPicker(selection: $pickedWallpaper, matching: .images, photoLibrary: .shared()) {
                Label(hasWallpaper ? "更换壁纸" : "选择壁纸图片", systemImage: "photo.on.rectangle.angled")
            }
            if hasWallpaper {
                Button(role: .destructive) {
                    WallpaperStore.clear()
                    hasWallpaper = false
                } label: {
                    Label("移除壁纸，用默认渐变", systemImage: "trash")
                }
            }
            Toggle("开机自检动画", isOn: $bootAnimation)
            Picker("圆环满量程", selection: $maxRPM) {
                Text("6000 rpm").tag(6000.0)
                Text("9000 rpm").tag(9000.0)
                Text("12000 rpm").tag(12000.0)
            }
        } header: {
            Text("外观")
        } footer: {
            Text("壁纸用横屏图片效果最好，左侧会自动压暗保证数据可读。开机自检动画在连上控制器那一刻播放：指针扫满量程再回落，随后数据卡片逐个浮现。圆环满量程要与你的车实际最高转速匹配，指针才不会长期贴顶。")
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
            Text("速度 = 转速 × 滚动周长 × 60 ÷ 1,000,000。下沉 10mm 意味着周长短 2.5% 左右——这正是空转时表显虚高的来源。")
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
            LabeledContent("版本", value: "0.2.1")
            LabeledContent("协议", value: "凌博 AA55 / FFF0·FFF1·FFF2")
            LabeledContent("通道发现", value: "FFF0 优先，否则自动探测")
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
