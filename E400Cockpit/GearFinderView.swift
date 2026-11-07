import SwiftUI

/// 挡位定位工具
///
/// 思路：挡位是「会变」的字段。先在某个挡位下拍一张快照，然后换挡，
/// 与快照不同的字节就自动高亮出来——真正承载挡位的那一两个字节跑不掉。
/// 找到后点一下就把它设为挡位偏移，仪表页立刻生效。
struct GearFinderView: View {
    @EnvironmentObject var central: CockpitCentral
    @Environment(\.dismiss) private var dismiss

    @AppStorage("gear_offset") private var gearOffset = -1
    @AppStorage("gear_short_fallback") private var gearShortFallback = false
    @AppStorage("gear_manual") private var manualGear = 0
    @AppStorage("long_realtime_request") private var longRealtime = false

    @State private var baseRealtime: [UInt8] = []
    @State private var baseConfig: [UInt8] = []
    @State private var liveRealtime: [UInt8] = []
    @State private var liveConfig: [UInt8] = []
    @State private var ticker: Timer?

    private var realtimeDiff: [Int] { diffIndexes(baseRealtime, liveRealtime) }
    private var configDiff: [Int] { diffIndexes(baseConfig, liveConfig) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    statusBlock
                    howToBlock
                    realtimeBlock
                    configBlock
                    fallbackBlock
                }
                .padding(16)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("挡位定位")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .onAppear {
            liveRealtime = central.lastRealtimeFrame
            liveConfig = central.lastConfigFrame
            ticker?.invalidate()
            ticker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
                liveRealtime = central.lastRealtimeFrame
                liveConfig = central.lastConfigFrame
            }
        }
        .onDisappear {
            ticker?.invalidate()
            ticker = nil
        }
    }

    // MARK: 状态

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            row("最近实时帧长", "\(central.lastFrameLength) 字节")
            row("最近配置帧长", "\(central.lastConfigFrame.count) 字节")
            row("当前挡位", gearNow)
            row("挡位偏移", gearOffset < 0 ? "自动（@27 / 回退 @24）" : "@\(gearOffset)")
            if central.lastFrameLength > 0 && central.lastFrameLength < 29 {
                Label("实时帧只有 \(central.lastFrameLength) 字节，标准挡位字段 @27 在帧外 —— 这就是「——」的直接原因。", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private var gearNow: String {
        if let g = central.telemetry?.gear {
            let off = central.fieldTrace.gearOffset.map { " @\($0)" } ?? ""
            return "P\(g)\(off)"
        }
        if manualGear > 0 { return "P\(manualGear)（手动）" }
        return "未取到"
    }

    private var howToBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("怎么用")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)
            Text("1. 把车挂到 1 挡，点「采样基准」\n2. 把车挂到 2 挡（或 3 挡），保持连接\n3. 下面的列表会自动刷新，只剩**变化过的字节**\n4. 哪一字节从 01 变成了 02，点它的「设为挡住」")
                .font(.caption)
                .foregroundColor(.white.opacity(0.72))
            Text("如果整个列表一直是空的，说明挡位不在实时帧里 —— 打开下面的「长帧请求」，或直接看「配置帧」区块。")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.5))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    // MARK: 实时帧

    private var realtimeBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("实时帧（0x62）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("采样基准") { baseRealtime = central.lastRealtimeFrame }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("清空") { baseRealtime = [] }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            byteStrip(f: liveRealtime)

            if baseRealtime.isEmpty {
                hint("先在当前挡位点「采样基准」，然后换挡。")
            } else if realtimeDiff.isEmpty {
                hint(baseRealtime == liveRealtime
                     ? "还没检测到任何变化。换挡后再等等，或看下面的配置帧。"
                     : "帧长发生变化，请重新采样。")
            } else {
                diffList(realtimeDiff, base: baseRealtime, live: liveRealtime)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    // MARK: 配置帧

    private var configBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("配置帧（0x60）")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.white)
                Spacer()
                Button("重读") { central.requestConfigFrame() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button("采样基准") { baseConfig = central.lastConfigFrame }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            byteStrip(f: liveConfig)

            if liveConfig.isEmpty {
                hint("还没收到配置帧，点「重读」抓一次。")
            } else if baseConfig.isEmpty {
                hint("先点「采样基准」，换挡后再点「重读」，对比两次配置帧。")
            } else if configDiff.isEmpty {
                hint("两次配置帧完全一致 —— 挡位不在这里。")
            } else {
                diffList(configDiff, base: baseConfig, live: liveConfig)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    // MARK: 兜底

    private var fallbackBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("实在找不到时")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white)

            Toggle("向控制器要「长帧」（AA 55 1A 22 3B）", isOn: $longRealtime)
                .font(.subheadline)
                .tint(NeonTheme.pink)

            Toggle("短帧挡位回退（读 @24 低 4 位）", isOn: $gearShortFallback)
                .font(.subheadline)
                .tint(NeonTheme.pink)

            VStack(alignment: .leading, spacing: 6) {
                Text("手动挡位（控制器确实不报时用）")
                    .font(.caption)
                    .foregroundColor(.white.opacity(0.6))
                Picker("手动挡位", selection: $manualGear) {
                    Text("关闭").tag(0)
                    Text("1 档").tag(1)
                    Text("2 档").tag(2)
                    Text("3 档").tag(3)
                    Text("4 档").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text("打开后仪表页的「挡位」格会显示你选的档位（标为手动），自动解析到真实值时会优先用解析值。")
                    .font(.caption2)
                    .foregroundColor(.white.opacity(0.45))
            }

            Button("全部恢复自动") {
                gearOffset = -1
                gearShortFallback = false
                longRealtime = false
                manualGear = 0
                baseRealtime = []
                baseConfig = []
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    // MARK: 组件

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.06))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.10), lineWidth: 0.8))
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            Text(v)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(.white)
        }
    }

    private func hint(_ s: String) -> some View {
        Text(s)
            .font(.caption2)
            .foregroundColor(.white.opacity(0.5))
    }

    /// 紧凑字节条：每 12 个换行，已知字段着品红
    @ViewBuilder
    private func byteStrip(f: [UInt8]) -> some View {
        if f.isEmpty {
            Text("（空）")
                .font(.caption2)
                .foregroundColor(.white.opacity(0.35))
        } else {
            byteRows(f)
        }
    }

    private func byteRows(_ f: [UInt8]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(stride(from: 0, to: f.count, by: 12)), id: \.self) { start in
                HStack(spacing: 3) {
                    Text(String(format: "%02X", start))
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundColor(.white.opacity(0.3))
                    ForEach(start..<min(start + 12, f.count), id: \.self) { i in
                        Text(String(format: "%02X", f[i]))
                            .font(.system(size: 9, weight: .semibold, design: .monospaced))
                            .foregroundColor(.white.opacity(0.85))
                            .padding(.horizontal, 2)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(isKnownField(i)
                                          ? NeonTheme.pink.opacity(0.30)
                                          : Color.white.opacity(0.05))
                            )
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func isKnownField(_ i: Int) -> Bool {
        [4, 6, 10, 12, 14, 16, 18, 22, 24, 27].contains(i)
    }

    private func diffList(_ idxs: [Int], base: [UInt8], live: [UInt8]) -> some View {
        VStack(spacing: 6) {
            ForEach(idxs, id: \.self) { i in
                HStack(spacing: 10) {
                    Text("@\(i)")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundColor(NeonTheme.pinkLight)
                        .frame(width: 36, alignment: .leading)
                    Text(String(format: "%02X → %02X", base[i], live[i]))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white)
                    Text("低4位 \(base[i] & 0x0F) → \(live[i] & 0x0F)")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                    Spacer()
                    Button(gearOffset == i ? "已用作挡位" : "设为挡住") {
                        gearOffset = i
                    }
                    .font(.system(size: 11))
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .disabled(gearOffset == i)
                }
            }
        }
    }

    private func diffIndexes(_ base: [UInt8], _ live: [UInt8]) -> [Int] {
        guard !base.isEmpty, !live.isEmpty, base.count == live.count else { return [] }
        return (0..<base.count).filter { base[$0] != live[$0] }
    }
}
