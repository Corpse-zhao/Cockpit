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

// MARK: - 扫描页

struct ScanView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "speedometer")
                .font(.system(size: 64))
                .foregroundColor(.red)
            Text("E400 Cockpit")
                .font(.largeTitle.bold())
            Text("凌博 E400 · 蓝牙直连仪表")
                .foregroundColor(.secondary)
            Button {
                central.startScan()
            } label: {
                Label(central.phase == .scanning ? "扫描中…" : "扫描 LBMC 设备",
                      systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Capsule().fill(Color.red))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 40)
            .disabled(central.phase == .scanning)
            if central.phase == .connecting {
                ProgressView("正在连接…")
                    .foregroundColor(.orange)
            }
            List(central.devices) { d in
                Button {
                    central.connect(d)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(d.name)
                                .font(.body.monospaced().bold())
                                .foregroundColor(.white)
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
            }
            .listStyle(.plain)
            .frame(maxHeight: 320)
            Spacer()
        }
    }
}

// MARK: - 仪表面板

struct GaugePanel: View {
    @EnvironmentObject var central: CockpitCentral
    private let cols = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                speedBlock
                LazyVGrid(columns: cols, spacing: 12) {
                    ForEach(cardData.indices, id: \.self) { i in
                        let c = cardData[i]
                        card(c.0, c.1, color: c.2)
                    }
                }
            }
            .padding()
        }
        .background(Color.black.ignoresSafeArea())
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(central.connectedName ?? "LBMC")
                    .font(.headline.monospaced())
                HStack(spacing: 6) {
                    Circle()
                        .fill(central.phase == .online ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                    Text(central.phase.rawValue)
                        .font(.caption)
                        .foregroundColor(central.phase == .online ? .green : .orange)
                }
            }
            Spacer()
            Button {
                central.disconnect()
            } label: {
                Label("断开", systemImage: "xmark.circle")
            }
            .foregroundColor(.red)
        }
    }

    private var speedBlock: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f", central.speedKmh))
                .font(.system(size: 104, weight: .heavy, design: .rounded))
                .foregroundColor(.red)
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text("km/h")
                .font(.title3)
                .foregroundColor(.gray)
            HStack(spacing: 24) {
                Text("RPM \(central.telemetry?.rpm ?? 0)")
                Text(String(format: "本次 %.2f km", central.tripKm))
            }
            .font(.footnote.monospaced())
            .foregroundColor(.secondary)
            .padding(.top, 6)

            Text(String(format: "周长 %.0f mm · %@", central.wheelCircMM, central.wheelCircSource))
                .font(.caption2.monospaced())
                .foregroundColor(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .background(RoundedRectangle(cornerRadius: 16).stroke(Color.red.opacity(0.35), lineWidth: 1))
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
            ("母线电压", String(format: "%.1f V", t.busVoltage), .white),
            ("母线电流", String(format: "%.1f A", t.busCurrent),
             t.busCurrent < -0.5 ? .green : (t.busCurrent > 1.0 ? .red : .white)),
            ("功率", String(format: "%.2f kW", t.busVoltage * t.busCurrent / 1000.0), .white),
            ("控制器温度", t.controllerTemp.map { String(format: "%.0f ℃", $0) } ?? "——",
             tempColor(t.controllerTemp)),
            ("电机温度", t.motorTemp.map { String(format: "%.0f ℃", $0) } ?? "——",
             tempColor(t.motorTemp)),
            ("转把", t.throttlePercent.map { String(format: "%.0f %%", $0) } ?? "——", .white),
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
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundColor(.gray)
            Text(value)
                .font(.title3.monospaced().bold())
                .foregroundColor(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(white: 0.09)))
    }
}
