import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        Group {
            switch central.phase {
            case .idle, .scanning, .connecting:
                ScanView()
            case .connected, .calibrated, .online:
                GaugePanel()
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

// MARK: - 仪表面板（横屏：左速度 / 右数据网格）

struct GaugePanel: View {
    @EnvironmentObject var central: CockpitCentral
    @AppStorage("vehicle_label") private var vehicleLabel = ""

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            leftColumn
                .frame(width: 232)
            LazyVGrid(columns: cols, spacing: 10) {
                ForEach(cardData.indices, id: \.self) { i in
                    let c = cardData[i]
                    card(c.0, c.1, color: c.2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(central.connectedName ?? "LBMC")
                        .font(.system(size: 13, weight: .bold, design: .monospaced))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(central.phase == .online ? Color.green : Color.orange)
                            .frame(width: 6, height: 6)
                        Text(central.phase.rawValue)
                            .font(.system(size: 10))
                            .foregroundColor(central.phase == .online ? .green : .orange)
                    }
                }
                Spacer(minLength: 4)
                Button {
                    central.disconnect()
                } label: {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 17))
                }
                .foregroundColor(.red)
            }

            Spacer(minLength: 2)

            VStack(spacing: 1) {
                Text(Fmt.speed(central.speedKmh))
                    .font(.system(size: 76, weight: .heavy, design: .rounded))
                    .foregroundColor(.red)
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                Text("km/h")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                HStack(spacing: 12) {
                    Text("RPM \(central.telemetry?.rpm ?? 0)")
                    Text(String(format: "%.2f km", central.tripKm))
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .padding(.top, 5)
                Text("周长 \(Fmt.int(central.wheelCircMM)) mm · \(central.wheelCircSource)")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.gray)
                    .padding(.top, 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .stroke(Color.red.opacity(0.35), lineWidth: 1)
            )

            Spacer(minLength: 2)

            Text(vehicleLabel.isEmpty ? "未设置车型" : vehicleLabel)
                .font(.system(size: 9))
                .foregroundColor(.gray)
                .lineLimit(1)
        }
    }

    private var cardData: [(String, String, Color)] {
        guard let t = central.telemetry else {
            return [
                ("母线电压", "——", .white),
                ("母线电流", "——", .white),
                ("功率", "——", .white),
                ("控制器温度", "——", .white),
                ("电机温度", "——", .white),
                ("转把", "——", .white),
                ("挡位", "——", .white),
                ("故障码", "无", .green)
            ]
        }
        let faultColor: Color = t.fault == 0 ? .green : .red
        return [
            ("母线电压", Fmt.num(t.busVoltage, "V"), .white),
            ("母线电流", Fmt.num(t.busCurrent, "A"),
             t.busCurrent < -0.005 ? .green : (t.busCurrent > 0.005 ? .red : .white)),
            ("功率", Fmt.num(t.busVoltage * t.busCurrent / 1000.0, "kW"), .white),
            ("控制器温度", Fmt.temp(t.controllerTemp), tempColor(t.controllerTemp)),
            ("电机温度", Fmt.temp(t.motorTemp), tempColor(t.motorTemp)),
            ("转把", t.throttlePercent.map { Fmt.percent($0) } ?? "——", .white),
            ("挡位", t.gear.map { "P\($0)" } ?? "——", .white),
            ("故障码", t.fault == 0 ? "无" : String(format: "0x%04X", t.fault & 0xFFFF), faultColor)
        ]
    }

    private func tempColor(_ v: Double?) -> Color {
        guard let v else { return .white }
        if v >= 90 { return .red }
        if v >= 70 { return .orange }
        return .white
    }

    private func card(_ title: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10))
                .foregroundColor(.gray)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .monospaced))
                .foregroundColor(color)
                .lineLimit(1)
                .minimumScaleFactor(0.55)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color(white: 0.09)))
    }
}
