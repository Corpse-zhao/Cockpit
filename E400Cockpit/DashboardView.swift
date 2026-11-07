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

struct ScanView: View {
    @EnvironmentObject var central: CockpitCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""
    @AppStorage("scan_all_devices") private var scanAllDevices = false

    var body: some View {
        HStack(alignment: .center, spacing: 26) {
            VStack(spacing: 10) {
                Spacer()
                Image(systemName: "speedometer")
                    .font(.system(size: 52))
                    .foregroundColor(.red)
                Text("E400 Cockpit")
                    .font(.system(size: 28, weight: .bold))
                Text(vehicleLabel.isEmpty ? "未设置车型" : vehicleLabel)
                    .font(.footnote)
                    .foregroundColor(.secondary)

                Button {
                    central.startScan()
                } label: {
                    Label(central.phase == .scanning ? "扫描中…" : (scanAllDevices ? "扫描全部设备" : "扫描 LBMC 设备"),
                          systemImage: "dot.radiowaves.left.and.right")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 13)
                        .background(Capsule().fill(Color.red))
                        .foregroundColor(.white)
                }
                .disabled(central.phase == .scanning)
                .padding(.top, 6)

                if central.phase == .connecting {
                    ProgressView("正在连接…")
                        .foregroundColor(.orange)
                        .scaleEffect(0.9)
                }
                Spacer()
            }
            .frame(width: 268)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("附近的设备")
                        .font(.headline)
                    Text("\(central.devices.count)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(scanAllDevices ? "全部" : "仅凌博")
                        .font(.caption2)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.red.opacity(0.18)))
                        .foregroundColor(.red)
                }

                List(central.devices) { d in
                    Button {
                        central.connect(d)
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(d.name)
                                        .font(.system(.body, design: .monospaced).bold())
                                        .foregroundColor(.white)
                                    if d.isKnown {
                                        Text("凌博")
                                            .font(.caption2)
                                            .padding(.horizontal, 5)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color.red.opacity(0.25)))
                                            .foregroundColor(.red)
                                    }
                                }
                                Text("信号 \(d.rssi) dBm")
                                    .font(.caption)
                                    .foregroundColor(.gray)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption)
                                .foregroundColor(.gray)
                        }
                    }
                    .listRowBackground(Color.black)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }
}
