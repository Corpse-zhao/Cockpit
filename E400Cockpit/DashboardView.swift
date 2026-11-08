import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        Group {
            switch central.phase {
            case .idle, .scanning, .connecting:
                ScanView()
            case .connected, .calibrated, .online:
                DashboardRoot()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - 扫描页（横屏）

/// 左边是入口，右边分两栏：控制器（AA55 系）和电池（蚂蚁板 BMS）。
/// 两条 BLE 链路各扫各的，互不干扰，哪个先连上都行。
struct ScanView: View {
    @EnvironmentObject var central: CockpitCentral
    @EnvironmentObject var bms: BmsCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("scan_all_devices") private var scanAllDevices = false
    @AppStorage("bms_only_boards") private var bmsOnlyBoards = true
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }
    private var green: Color { Color(red: 0.2, green: 0.95, blue: 0.55) }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            hero
                .frame(width: 200)

            controllerColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            bmsColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .onAppear {
            // 两条链路各自动连各的：控制器先试上次那台，电池也一样
            central.beginAutoConnect()
            bms.beginAutoConnect()
        }
    }

    // MARK: 左：入口

    private var hero: some View {
        VStack(spacing: 9) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.20))
                    .frame(width: 74, height: 74)
                    .blur(radius: 20)
                Image(systemName: "speedometer")
                    .font(.system(size: 34, weight: .light))
                    .foregroundColor(theme.accentLight)
            }

            Text(AppInfo.name)
                .font(.system(size: 21, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(vehicleLabel.isEmpty ? "未设置车型" : vehicleLabel)
                .font(.system(size: 10))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)

            VStack(spacing: 7) {
                // 控制器
                Button {
                    central.startScan()
                } label: {
                    HStack(spacing: 6) {
                        if central.phase == .scanning {
                            ProgressView().scaleEffect(0.6).tint(.white)
                        } else {
                            Image(systemName: "dot.radiowaves.left.and.right")
                        }
                        Text(central.phase == .scanning ? "扫描中…" : "扫描控制器")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(
                        Capsule().fill(
                            LinearGradient(colors: theme.gradientColors,
                                           startPoint: .leading, endPoint: .trailing)
                        )
                    )
                    .foregroundColor(.white)
                    .shadow(color: theme.accent.opacity(0.40), radius: 9, y: 3)
                }
                .buttonStyle(.plain)
                .disabled(central.phase == .scanning)

                // 电池
                Button {
                    bms.startScan()
                } label: {
                    HStack(spacing: 6) {
                        if bms.phase == .scanning {
                            ProgressView().scaleEffect(0.6).tint(green)
                        } else {
                            Image(systemName: "battery.100.bolt")
                        }
                        Text(bms.phase == .scanning ? "搜索中…" : "搜索电池 BMS")
                            .font(.system(size: 13, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(green.opacity(0.12)))
                    .overlay(Capsule().stroke(green.opacity(0.45), lineWidth: 1))
                    .foregroundColor(green)
                }
                .buttonStyle(.plain)
                .disabled(bms.phase == .scanning)
            }
            .padding(.top, 3)

            Text("控制器 AA55 · 电池 7EA1\n两条链路互不影响")
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.32))
                .multilineTextAlignment(.center)
                .lineLimit(2)

            Spacer(minLength: 0)
        }
    }

    // MARK: 中：控制器

    private var visibleControllers: [CockpitCentral.DiscoveredDevice] {
        scanAllDevices ? central.devices : central.devices.filter { $0.isKnown }
    }

    private var controllerColumn: some View {
        column(
            title: "控制器",
            count: visibleControllers.count,
            accent: theme.accentLight,
            tint: theme.accent.opacity(0.18),
            note: central.phase == .connecting ? "连接中…" : nil,
            noteColor: .orange,
            trailing: {
                Button {
                    scanAllDevices.toggle()
                    if central.phase == .scanning { central.startScan() }
                } label: {
                    Text(scanAllDevices ? "全部蓝牙" : "仅已知")
                        .font(.system(size: 9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(scanAllDevices
                                                   ? Color.white.opacity(0.10)
                                                   : theme.accent.opacity(0.20)))
                        .foregroundColor(scanAllDevices ? .white.opacity(0.7) : theme.accentLight)
                }
                .buttonStyle(.plain)
            }
        ) {
            if visibleControllers.isEmpty {
                if scanAllDevices {
                    emptyHint(icon: "antenna.radiowaves.left.and.right.slash",
                              text: "附近没有蓝牙设备\n确认控制器已上电，且没被官方 App 占用",
                              action: nil)
                } else {
                    emptyHint(icon: "line.3.horizontal.decrease.circle",
                              text: "没有发现已知控制器\n有些固件的广播名不带前缀",
                              action: ("显示全部蓝牙", {
                                  scanAllDevices = true
                                  central.startScan()
                              }))
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(visibleControllers) { d in
                            Button {
                                central.connect(d)
                            } label: {
                                deviceRow(name: d.name,
                                          badge: d.isKnown
                                            ? (ControllerIdentifier.brandName(for: d.name) ?? "已识别")
                                            : nil,
                                          badgeColor: theme.accentLight,
                                          rssi: d.rssi)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    // MARK: 右：电池 BMS

    /// 只留保护板品牌的广播名（蚂蚁 / 极空 / 嘉佰达 / 彦阳 / 达锂…），
    /// 不然耳机、车机、手表全冒出来，翻半天找不到板子。
    private var visibleBms: [BmsCentral.Device] {
        bmsOnlyBoards ? bms.devices.filter { $0.likely } : bms.devices
    }

    private var bmsColumn: some View {
        column(
            title: "电池 BMS",
            count: visibleBms.count,
            accent: green,
            tint: green.opacity(0.16),
            note: bmsNote,
            noteColor: bms.phase == .online ? green : .orange,
            trailing: {
                Button {
                    bmsOnlyBoards.toggle()
                } label: {
                    Text(bmsOnlyBoards ? "仅保护板" : "全部蓝牙")
                        .font(.system(size: 9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(bmsOnlyBoards
                                                   ? green.opacity(0.18)
                                                   : Color.white.opacity(0.10)))
                        .foregroundColor(bmsOnlyBoards ? green : .white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }
        ) {
            VStack(spacing: 0) {
                if let t = bms.telemetry {
                    connectedBmsCard(t)
                        .padding(.horizontal, 8)
                        .padding(.top, 5)
                }

                if visibleBms.isEmpty {
                    if bms.phase == .scanning {
                        emptyHint(icon: "battery.0", text: "正在搜索保护板…", action: nil)
                    } else if bms.devices.isEmpty {
                        emptyHint(icon: "battery.0",
                                  text: "点左边「搜索电池 BMS」\n蚂蚁 / 极空 / 嘉佰达 / 彦阳都会认",
                                  action: ("开始搜索", { bms.startScan() }))
                    } else {
                        emptyHint(icon: "line.3.horizontal.decrease.circle",
                                  text: "搜到 \(bms.devices.count) 个蓝牙设备\n但没有保护板品牌的名字",
                                  action: ("显示全部蓝牙", { bmsOnlyBoards = false }))
                    }
                } else {
                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(visibleBms) { d in
                                Button {
                                    bms.connect(d)
                                } label: {
                                    deviceRow(name: d.name,
                                              badge: d.brand ?? "疑似 BMS",
                                              badgeColor: green,
                                              rssi: d.rssi,
                                              highlighted: bms.phase == .connecting)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                    }
                }

                if let err = bms.lastError {
                    HStack(alignment: .top, spacing: 5) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 8))
                        Text(err)
                            .font(.system(size: 8.5))
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .foregroundColor(.orange)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 6)
                }
            }
        }
    }

    private var bmsNote: String? {
        if bms.phase == .online {
            return bms.telemetry.map { "\($0.soc)% · \($0.cellCount)S" } ?? "已连接"
        }
        if bms.phase == .connected { return "等数据…" }
        if bms.phase == .connecting { return "连接中…" }
        if bms.phase == .scanning { return "搜索中" }
        return nil
    }

    private func connectedBmsCard(_ t: AntBmsParser.Telemetry) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 12))
                .foregroundColor(green)
            VStack(alignment: .leading, spacing: 1) {
                Text(bms.connectedName ?? "电池")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Text(String(format: "%.2f V · %+.2f A · %dS",
                            t.packVoltage, t.current, t.cellCount))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(.white.opacity(0.5))
            }
            Spacer(minLength: 0)
            Button {
                bms.disconnect()
            } label: {
                Text("断开")
                    .font(.system(size: 9))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .foregroundColor(.white.opacity(0.7))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9).fill(green.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(green.opacity(0.30), lineWidth: 0.8))
    }

    // MARK: 通用栏

    private func column<C: View, T: View>(title: String,
                                          count: Int,
                                          accent: Color,
                                          tint: Color,
                                          note: String?,
                                          noteColor: Color,
                                          @ViewBuilder trailing: () -> T,
                                          @ViewBuilder content: () -> C) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(accent)
                    .frame(width: 3, height: 11)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text("\(count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.40))
                if let note {
                    Text(note)
                        .font(.system(size: 9))
                        .foregroundColor(noteColor)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                trailing()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)

            Rectangle()
                .fill(Color.white.opacity(0.07))
                .frame(height: 0.6)

            content()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.045))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(tint, lineWidth: 0.8))
        )
    }

    private func deviceRow(name: String,
                           badge: String?,
                           badgeColor: Color,
                           rssi: Int,
                           highlighted: Bool = false) -> some View {
        HStack(spacing: 7) {
            VStack(alignment: .leading, spacing: 1) {
                Text(name)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if let badge {
                        Text(badge)
                            .font(.system(size: 8))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(badgeColor.opacity(0.20)))
                            .foregroundColor(badgeColor)
                    }
                    Text("\(rssi) dBm")
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundColor(rssiColor(rssi))
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(.white.opacity(0.28))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(highlighted ? Color.white.opacity(0.09) : Color.white.opacity(0.05))
        )
    }

    private func rssiColor(_ rssi: Int) -> Color {
        if rssi >= -70 { return Color(red: 0.2, green: 0.95, blue: 0.55) }
        if rssi >= -85 { return .white.opacity(0.45) }
        return .orange
    }

    private func emptyHint(icon: String,
                           text: String,
                           action: (String, () -> Void)?) -> some View {
        VStack(spacing: 7) {
            Spacer(minLength: 0)
            Image(systemName: icon)
                .font(.system(size: 20))
                .foregroundColor(.white.opacity(0.22))
            Text(text)
                .font(.system(size: 9.5))
                .foregroundColor(.white.opacity(0.40))
                .multilineTextAlignment(.center)
                .lineSpacing(1.5)
            if let action {
                Button(action.0) { action.1() }
                    .font(.system(size: 9.5))
                    .foregroundColor(theme.accentLight)
                    .buttonStyle(.plain)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 10)
    }
}
