import SwiftUI

// MARK: - 数据台：BMS 原始帧

struct BmsFrameCard: View {
    @EnvironmentObject var bms: BmsCentral

    private var frame: [UInt8] { bms.lastFrame }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("最近 BMS 帧")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(frame.isEmpty ? "—" : "len \(frame.count)")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundColor(frame.isEmpty ? .gray : .green)
                Spacer()
                if let g = bms.gattInfo {
                    Text(g)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(1)
                }
                Text(bms.phase.rawValue)
                    .font(.system(size: 10))
                    .foregroundColor(bms.phase == .online ? .green : .orange)
            }

            if frame.isEmpty {
                Text("未连接电池，或还没收到 7E A1 应答。蚂蚁板走 FFE0/FFE1/FFE2，1 秒要一次状态。")
                    .font(.system(size: 10))
                    .foregroundColor(.white.opacity(0.5))
            } else {
                Text(frame.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.green)
                    .textSelection(.enabled)
                    .lineLimit(4)

                HStack(spacing: 12) {
                    item("单体", "\(bms.telemetry?.cellCount ?? 0)S")
                    item("总压", String(format: "%.2f V", bms.telemetry?.packVoltage ?? 0))
                    item("电流", String(format: "%+.2f A", bms.telemetry?.current ?? 0))
                    item("SOC", "\(bms.telemetry?.soc ?? 0)%")
                    item("压差", "\(Int(((bms.telemetry?.deltaV ?? 0) * 1000).rounded())) mV")
                    Spacer()
                    Text("已收 \(bms.frameCount) 帧")
                        .font(.system(size: 9))
                        .foregroundColor(.white.opacity(0.45))
                }
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.white.opacity(0.05))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.8))
        )
    }

    private func item(_ k: String, _ v: String) -> some View {
        VStack(spacing: 0) {
            Text(k)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.5))
            Text(v)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }
}

// MARK: - 电池详情（单体电压 + 温度）

struct BmsDetailView: View {
    @EnvironmentObject var bms: BmsCentral
    @Environment(\.dismiss) private var dismiss
    @AppStorage("theme_id") private var themeID = ThemePreset.pink.rawValue

    private var theme: ThemePreset { ThemeStore.preset(for: themeID) }

    var body: some View {
        NavigationStack {
            Group {
                if let t = bms.telemetry {
                    // 横屏左右分栏：左边概要+温度+开关，右边单体（两列）
                    HStack(alignment: .top, spacing: 12) {
                        ScrollView {
                            VStack(spacing: 12) {
                                summary(t)
                                temps(t)
                                mos(t)
                            }
                        }
                        .frame(width: 320)

                        ScrollView {
                            cells(t)
                        }
                    }
                    .padding(16)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "battery.0")
                            .font(.system(size: 30))
                            .foregroundColor(.white.opacity(0.35))
                        Text("还没有收到 BMS 数据")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                        Text("在「设置 → 电池（蚂蚁板 BMS）」里扫描并连接")
                            .font(.caption2)
                            .foregroundColor(.white.opacity(0.35))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("电池 " + (bms.connectedName ?? "BMS"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }

    private func summary(_ t: AntBmsParser.Telemetry) -> some View {
        VStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("\(t.soc)")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                Text("%")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(String(format: "%.2f V", t.packVoltage))
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                    Text(String(format: "%+.2f A", t.current))
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(t.current < 0 ? Color(red: 0.2, green: 0.95, blue: 0.55) : theme.accentLight)
                }
            }
            HStack(spacing: 14) {
                info("剩余", String(format: "%.2f Ah", t.remainingAh))
                info("额定", String(format: "%.2f Ah", t.capacityAh))
                info("健康", t.soh > 0 ? "\(t.soh)%" : "—")
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private func cells(_ t: AntBmsParser.Telemetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("单体电压 · \(t.cellCount)S")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(String(format: "压差 %.0f mV", t.deltaV * 1000))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(t.deltaV > 0.05 ? .orange : .secondary)
            }

            let lo = max(2.5, t.minCellV - 0.05)
            let hi = min(4.5, t.maxCellV + 0.05)
            // 横屏宽度够，两列排——20 串一列要滚半天
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14),
                                GridItem(.flexible(), spacing: 14)],
                      spacing: 5) {
                ForEach(Array(t.cellVoltages.enumerated()), id: \.offset) { idx, v in
                    HStack(spacing: 7) {
                        Text("\(idx + 1)")
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.45))
                            .frame(width: 16, alignment: .trailing)
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.white.opacity(0.10))
                                Capsule()
                                    .fill(v >= t.avgCellV ? theme.accent : theme.accentLight.opacity(0.75))
                                    .frame(width: max(2, geo.size.width * CGFloat((v - lo) / max(hi - lo, 0.001))))
                            }
                        }
                        .frame(height: 7)
                        Text(String(format: "%.3f", v))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.white.opacity(0.8))
                            .frame(width: 38, alignment: .trailing)
                    }
                    .frame(height: 13)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private func temps(_ t: AntBmsParser.Telemetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("温度")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                ForEach(Array(t.temps.enumerated()), id: \.offset) { idx, v in
                    chip("探头\(idx + 1)", "\(v)℃", tempColor(v))
                }
                chip("MOS", "\(t.mosTemp)℃", tempColor(t.mosTemp))
                chip("均衡", "\(t.balancerTemp)℃", tempColor(t.balancerTemp))
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private func mos(_ t: AntBmsParser.Telemetry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开关状态")
                .font(.system(size: 13, weight: .semibold))
            HStack(spacing: 10) {
                chip("充电 MOS", t.chargeMosOn ? "导通" : "断开", t.chargeMosOn ? .green : .secondary)
                chip("放电 MOS", t.dischargeMosOn ? "导通" : "断开", t.dischargeMosOn ? .green : .secondary)
                chip("均衡", t.balancerOn ? "开启" : "关闭", t.balancerOn ? theme.accentLight : .secondary)
                chip("保护", t.protection == 0 ? "无" : "有", t.protection == 0 ? .green : .red)
                chip("告警", t.warning == 0 ? "无" : "有", t.warning == 0 ? .green : .orange)
                Spacer()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private func info(_ k: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(k).font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
            Text(v).font(.system(size: 11, weight: .medium, design: .monospaced))
        }
    }

    private func chip(_ k: String, _ v: String, _ c: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(k).font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
            Text(v).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(c)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(0.06)))
    }

    private func tempColor(_ v: Int) -> Color {
        if v >= 55 { return .red }
        if v >= 45 { return .orange }
        return .white
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8))
    }
}
