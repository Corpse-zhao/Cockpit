import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        Group {
            switch central.phase {
            case .idle, .scanning, .connecting:
                ScanView()
            case .connected, .calibrated, .online:
                NeonDashboard()
            }
        }
        .background(Color.black.ignoresSafeArea())
    }
}

// MARK: - 扫描页（横屏）

/// 不绑定任何具体型号：标题读 App 名，扫描按钮和过滤徽标都是通用文案，
/// 过滤器只是在「全部蓝牙设备」和「按已知前缀过滤」之间切，不再是「仅凌博」。
struct ScanView: View {
    @EnvironmentObject var central: CockpitCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("scan_all_devices") private var scanAllDevices = false
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        HStack(spacing: 24) {
            hero
                .frame(width: 300)

            devicePanel
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: 左侧

    private var hero: some View {
        VStack(spacing: 12) {
            Spacer(minLength: 0)

            ZStack {
                Circle()
                    .fill(theme.accent.opacity(0.20))
                    .frame(width: 96, height: 96)
                    .blur(radius: 22)
                Image(systemName: "speedometer")
                    .font(.system(size: 46, weight: .light))
                    .foregroundColor(theme.accentLight)
            }

            Text(AppInfo.name)
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundColor(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)

            Text(vehicleLabel.isEmpty ? "未设置车型" : vehicleLabel)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(1)

            Button {
                central.startScan()
            } label: {
                HStack(spacing: 7) {
                    if central.phase == .scanning {
                        ProgressView()
                            .scaleEffect(0.7)
                            .tint(.white)
                    } else {
                        Image(systemName: "dot.radiowaves.left.and.right")
                    }
                    Text(scanTitle)
                        .font(.system(size: 16, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(
                    Capsule().fill(
                        LinearGradient(colors: theme.gradientColors,
                                       startPoint: .leading, endPoint: .trailing)
                    )
                )
                .foregroundColor(.white)
                .shadow(color: theme.accent.opacity(0.45), radius: 12, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(central.phase == .scanning)
            .padding(.top, 4)

            if central.phase == .connecting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("正在连接…")
                        .font(.caption)
                }
                .foregroundColor(.orange)
            }

            Text("支持凌博 / 远驱 / Sabvoton / Kelly 等 AA55 系控制器；其他品牌会自动探测通道")
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.35))
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .padding(.horizontal, 8)

            Spacer(minLength: 0)
        }
    }

    private var scanTitle: String {
        if central.phase == .scanning { return "扫描中…" }
        return scanAllDevices ? "扫描全部蓝牙设备" : "扫描控制器"
    }

    // MARK: 右侧

    private var devicePanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("附近的设备")
                    .font(.headline)
                    .foregroundColor(.white)
                Text("\(central.devices.count)")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.45))

                Spacer()

                // 过滤器直接点，不用回设置页翻
                Button {
                    scanAllDevices.toggle()
                    if central.phase == .scanning { central.startScan() }
                } label: {
                    Text(scanAllDevices ? "全部蓝牙设备" : "仅已知控制器")
                        .font(.system(size: 10))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            Capsule().fill(scanAllDevices
                                           ? Color.white.opacity(0.10)
                                           : theme.accent.opacity(0.20))
                        )
                        .foregroundColor(scanAllDevices ? .white.opacity(0.7) : theme.accentLight)
                }
                .buttonStyle(.plain)
            }

            if central.devices.isEmpty {
                emptyState
            } else {
                List(central.devices) { d in
                    Button {
                        central.connect(d)
                    } label: {
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(d.name)
                                        .font(.system(.body, design: .monospaced).bold())
                                        .foregroundColor(.white)
                                    if d.isKnown {
                                        Text("已知")
                                            .font(.system(size: 9))
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(theme.accent.opacity(0.25)))
                                            .foregroundColor(theme.accentLight)
                                    }
                                }
                                Text("信号 \(d.rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(.white.opacity(0.4))
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.3))
                        }
                    }
                    .listRowBackground(Color.black)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: scanAllDevices ? "antenna.radiowaves.left.and.right.slash" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 26))
                .foregroundColor(.white.opacity(0.25))
            Text(emptyTitle)
                .font(.footnote)
                .foregroundColor(.white.opacity(0.45))
                .multilineTextAlignment(.center)
            if !scanAllDevices {
                Button("换成显示全部蓝牙设备") {
                    scanAllDevices = true
                    central.startScan()
                }
                .font(.caption)
                .foregroundColor(theme.accentLight)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyTitle: String {
        if central.phase == .scanning {
            return scanAllDevices ? "正在搜索附近的蓝牙设备…" : "正在搜索已知控制器…"
        }
        if scanAllDevices { return "附近没有发现蓝牙设备\n确认控制器已上电，且没有被官方 App 占用" }
        return "没有发现已知控制器\n有些固件的广播名不带前缀，换个过滤器试试"
    }
}
