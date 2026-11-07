import SwiftUI
import UIKit

// MARK: - 帧结构逐字节视图

/// 把最近一帧 0x62 实时帧按字节铺开，标出已知字段的位置。
/// 挡位/转把不显示时，看这里就能知道是「帧里根本没这两个字段」还是「偏移对不上」。
struct FrameInspectorCard: View {
    @EnvironmentObject var central: CockpitCentral

    /// 已知字段（起始偏移 → 说明）
    private let known: [Int: String] = [
        0: "帧头", 1: "帧头", 2: "长度", 3: "命令",
        4: "转速", 6: "相电流²", 10: "母线电压", 12: "母线电流",
        14: "控温", 16: "电机温", 18: "故障", 22: "转把", 24: "状态", 27: "挡位"
    ]

    private var frame: [UInt8] { central.lastRealtimeFrame }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            headerRow
            if frame.isEmpty {
                Text("还没有收到 0x62 实时帧。连上控制器后这里会显示逐字节结构。")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            } else {
                byteGrid
                decodeRow
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

    private var headerRow: some View {
        HStack(spacing: 8) {
            Text("最近实时帧")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.white)
            Text("len \(frame.count)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundColor(lengthColor)
            if !frame.isEmpty {
                Text(checksumOK ? "校验 ✔" : "校验 ✘")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(checksumOK ? .green : .red)
            }
            Spacer()
            Button {
                UIPasteboard.general.string = central.diagnosticReport()
            } label: {
                Label("复制诊断", systemImage: "doc.on.doc")
                    .font(.system(size: 11))
            }
            .buttonStyle(.bordered)
            .controlSize(.mini)
        }
    }

    private var lengthColor: Color {
        if frame.isEmpty { return .gray }
        if frame.count >= 29 { return .green }        // 标准长帧：转把/挡位齐全
        if frame.count >= 25 { return .yellow }       // 缺挡位
        if frame.count >= 24 { return .orange }       // 缺挡位/转把待确认
        return .red
    }

    private var checksumOK: Bool {
        guard frame.count >= 2 else { return false }
        let sum = frame.dropLast().reduce(UInt32(0)) { $0 &+ UInt32($1) }
        return UInt8(truncatingIfNeeded: sum) == frame[frame.count - 1]
    }

    private var byteGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 8),
                  spacing: 4) {
            ForEach(Array(frame.enumerated()), id: \.offset) { pair in
                let idx = pair.offset
                let b = pair.element
                VStack(spacing: 1) {
                    Text(String(format: "%02d", idx))
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(.white.opacity(0.35))
                    Text(String(format: "%02X", b))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundColor(known[idx] != nil ? .white : .white.opacity(0.62))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(known[idx] != nil
                              ? Color(red: 0.859, green: 0.051, blue: 0.420).opacity(0.28)
                              : Color.white.opacity(0.045))
                )
                .overlay(alignment: .bottom) {
                    if let label = known[idx] {
                        Text(label)
                            .font(.system(size: 6.5))
                            .foregroundColor(.white.opacity(0.75))
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .offset(y: 0)
                    }
                }
            }
        }
    }

    private var decodeRow: some View {
        HStack(spacing: 14) {
            item("转速", "\(central.telemetry?.rpm ?? 0)", ok: frame.count >= 6)
            item("电压", String(format: "%.2f", central.telemetry?.busVoltage ?? 0), ok: frame.count >= 12)
            item("电流", String(format: "%.2f", central.telemetry?.busCurrent ?? 0), ok: frame.count >= 14)
            item("转把", throttleText, ok: central.fieldTrace.throttleOffset != nil)
            item("挡位", gearText, ok: central.fieldTrace.gearOffset != nil)
            Spacer()
            Text(frame.count < 25
                 ? "帧长 \(frame.count) < 25，协议里没有转把字段"
                 : (frame.count < 29 ? "帧长 \(frame.count) < 29，标准挡位字段缺失" : "标准长帧，字段齐全"))
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.5))
                .lineLimit(2)
                .frame(maxWidth: 210, alignment: .trailing)
        }
    }

    private var throttleText: String {
        guard let v = central.telemetry?.throttleVolts else { return "无" }
        return String(format: "%.2fV", v)
    }

    private var gearText: String {
        guard let g = central.telemetry?.gear else { return "无" }
        let off = central.fieldTrace.gearOffset.map { "@\($0)" } ?? ""
        return "P\(g)\(off)"
    }

    private func item(_ k: String, _ v: String, ok: Bool) -> some View {
        VStack(spacing: 0) {
            Text(k)
                .font(.system(size: 8))
                .foregroundColor(.white.opacity(0.5))
            Text(v)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(ok ? .white : .red.opacity(0.8))
        }
    }
}

// MARK: - 数据台

struct ConsoleView: View {
    @EnvironmentObject var central: CockpitCentral

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                HStack {
                    Text("数据台")
                        .font(.headline)
                    Spacer()
                    Text("\(central.console.count) 条")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Button {
                        UIPasteboard.general.string = central.diagnosticReport()
                    } label: {
                        Label("复制诊断", systemImage: "doc.on.doc")
                    }
                    .font(.caption)
                    Button {
                        central.console.removeAll()
                    } label: {
                        Image(systemName: "trash")
                    }
                    .font(.caption)
                }
                FrameInspectorCard()
            }
            .padding(12)

            Divider()

            if central.console.isEmpty {
                Spacer()
                Text("连接控制器后，这里会显示收到的每一帧原始字节\n\n用于核对协议：0x60 = 标定帧\n0x62 = 实时帧")
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .font(.footnote)
                Spacer()
            } else {
                List(Array(central.console.reversed())) { line in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(timeStr(line.time))
                                .font(.caption2.monospaced())
                                .foregroundColor(.gray)
                            Spacer()
                            Text(line.note)
                                .font(.caption2.monospaced())
                                .foregroundColor(line.note.contains("标定") ? .orange : .secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                        }
                        Text(line.hex.isEmpty ? "—" : line.hex)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                    }
                }
                .listStyle(.plain)
            }
        }
        .background(Color.black.ignoresSafeArea())
    }

    private func timeStr(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f.string(from: d)
    }
}
