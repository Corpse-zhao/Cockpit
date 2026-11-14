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
                if bms.rxTotal > 0 {
                    // 收到字节但没解析出帧——这块最有用，能直接看出板子回的到底是什么
                    VStack(alignment: .leading, spacing: 3) {
                        Text("收到 \(bms.rxTotal) 字节，但不是合法 7EA1 帧（或协议不同）")
                            .font(.system(size: 9.5))
                            .foregroundColor(.orange)
                        Text(bms.lastRX)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.green)
                            .textSelection(.enabled)
                            .lineLimit(3)
                    }
                } else {
                    Text("未连接电池，或还没收到 7E A1 应答。保护板走 FFE0，1 秒要一次状态。")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.5))
                }
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
                    Text("收 \(bms.rxCount) 条 / 解析 \(bms.frameCount) 帧")
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
                                linkHealth()
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
                chip("保护", protectionTitle(t),
                     t.protectionItems.isEmpty ? (t.protectionReserved.isEmpty ? .green : .secondary) : .red)
                chip("告警", warningTitle(t),
                     t.warningItems.isEmpty ? (t.warningReserved.isEmpty ? .green : .secondary) : .orange)
                Spacer()
            }
            if hasFlags(t) { flagDetail(t) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    // MARK: 保护 / 告警按位展开

    private func protectionTitle(_ t: AntBmsParser.Telemetry) -> String {
        if !t.protectionItems.isEmpty {
            return t.protectionItems.count == 1 ? t.protectionItems[0] : "\(t.protectionItems.count) 项"
        }
        return t.protectionReserved.isEmpty ? "无" : "未定义位"
    }

    private func warningTitle(_ t: AntBmsParser.Telemetry) -> String {
        if !t.warningItems.isEmpty {
            return t.warningItems.count == 1 ? t.warningItems[0] : "\(t.warningItems.count) 项"
        }
        return t.warningReserved.isEmpty ? "无" : "未定义位"
    }

    private func hasFlags(_ t: AntBmsParser.Telemetry) -> Bool {
        !(t.protectionItems.isEmpty && t.warningItems.isEmpty
          && t.protectionReserved.isEmpty && t.warningReserved.isEmpty)
    }

    private func flagDetail(_ t: AntBmsParser.Telemetry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            if !t.protectionItems.isEmpty {
                flagRow("保护", t.protectionItems.joined(separator: " · "), .red)
            }
            if !t.warningItems.isEmpty {
                flagRow("告警", t.warningItems.joined(separator: " · "), .orange)
            }
            if !t.protectionReserved.isEmpty || !t.warningReserved.isEmpty {
                flagRow("未定义位", undefinedBits(t), .secondary)
            }
            Text("原始 保护 \(hex(t.protection)) · 告警 \(hex(t.warning)) · 均衡 \(hex(t.balancing))")
                .font(.system(size: 9, design: .monospaced))
                .foregroundColor(.white.opacity(0.30))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 2)
    }

    private func undefinedBits(_ t: AntBmsParser.Telemetry) -> String {
        var parts: [String] = []
        if !t.warningReserved.isEmpty {
            parts.append("告警 " + t.warningReserved.map { "位\($0)" }.joined(separator: ","))
        }
        if !t.protectionReserved.isEmpty {
            parts.append("保护 " + t.protectionReserved.map { "位\($0)" }.joined(separator: ","))
        }
        return parts.joined(separator: " · ")
    }

    private func hex(_ v: UInt64) -> String {
        String(format: "0x%016llX", v)
    }

    private func flagRow(_ k: String, _ v: String, _ c: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(k)
                .font(.system(size: 9))
                .foregroundColor(.white.opacity(0.45))
                .frame(width: 44, alignment: .leading)
            Text(v)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(c)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// 链路自检：帧计数 + 最后一帧到现在多久。
    /// 数值看着「不动」时，先看这里——计数在涨说明板子一直在回，只是电量/电压本来就不会跳。
    private func linkHealth() -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let age = Date().timeIntervalSince(bms.lastFrameAt)
            let stale = age > 3
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 14) {
                    info("收到", "\(bms.rxCount) 条")
                    info("解析", "\(bms.frameCount) 帧")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("最后一帧").font(.system(size: 9)).foregroundColor(.white.opacity(0.45))
                        Text(ageText(age))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(stale ? .orange : .white)
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    info("最近帧", bms.rxShape.isEmpty ? "—" : bms.rxShape)
                    info("帧长", "\(bms.lastFrame.count) 字节")
                    Spacer()
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panel)
    }

    private func ageText(_ s: TimeInterval) -> String {
        if s < 0 || s > 3600 { return "—" }
        if s < 1 { return String(format: "%.2f 秒前", s) }
        if s < 60 { return String(format: "%.1f 秒前", s) }
        return String(format: "%.0f 秒前", s)
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

// MARK: - 电池连接

/// 仪表页左下那条「电池未连接」虚线点进来就是这个。
/// 以前得绕去「设置 → 电池」翻半天，现在原地就能搜、能连、能断开。
struct BmsConnectSheet: View {
    @EnvironmentObject var bms: BmsCentral
    @Environment(\.dismiss) private var dismiss
    @AppStorage("bms_only_boards") private var onlyBoards = true

    private var green: Color { Color(red: 0.2, green: 0.95, blue: 0.55) }
    private var pink: Color { Color(red: 1.0, green: 0.36, blue: 0.66) }

    /// 「仅保护板」过滤命中的数量
    private var boardCount: Int { bms.devices.filter { $0.likely }.count }

    /// 只认保护板名/服务来过滤，但一个都没认出来时不该让用户对着空列表发呆：
    /// 保护板换了固件、广播名被截断、或者广播里干脆不带名字/服务 UUID，
    /// 都会让 likely 全为 false —— 这时自动退回「全部蓝牙」，让人至少能点进去试。
    private var autoFallback: Bool { onlyBoards && boardCount == 0 && !bms.devices.isEmpty }

    private var list: [BmsCentral.Device] {
        (onlyBoards && !autoFallback) ? bms.devices.filter { $0.likely } : bms.devices
    }

    private var tone: Color {
        switch bms.phase {
        case .online, .connected: return green
        case .connecting: return .yellow
        case .scanning: return .orange
        case .idle: return Color.white.opacity(0.40)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(height: 0.5)
            HStack(alignment: .top, spacing: 12) {
                leftColumn.frame(width: 208)
                rightColumn.frame(maxWidth: .infinity)
            }
            .padding(12)
        }
        .background(Color(red: 0.045, green: 0.045, blue: 0.055).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .onAppear {
            guard bms.phase == .idle else { return }
            bms.beginAutoConnect()
            // 等 1 秒：自动连接要是已经直连上了，就别再抢着扫描
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak bms] in
                guard let bms, bms.phase == .idle, bms.devices.isEmpty else { return }
                bms.startScan()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "battery.100.bolt")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(green)
            Text("连接电池 BMS")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(.white)
            HStack(spacing: 5) {
                Circle().fill(tone).frame(width: 6, height: 6)
                Text(bms.phase.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(tone)
            }
            Spacer()
            Button("完成") { dismiss() }
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(pink)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    // MARK: 左：状态 + 操作

    private var leftColumn: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 4) {
                Text(bms.connectedName ?? "未连接")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
                if let t = bms.telemetry {
                    Text(String(format: "%.2f V · %+.2f A · %d%%", t.packVoltage, t.current, t.soc))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                } else {
                    Text(bms.gattInfo ?? "还没收到数据")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.45))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let err = bms.lastError {
                    Text(err)
                        .font(.system(size: 9))
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panel)

            if bms.phase == .scanning {
                actionButton("停止扫描", "stop.circle", .white.opacity(0.75)) { bms.stopScan() }
            } else {
                actionButton("搜索电池", "dot.radiowaves.left.and.right", green) { bms.startScan() }
            }

            if bms.phase == .online || bms.phase == .connected || bms.phase == .connecting {
                actionButton("断开", "xmark.circle", Color(red: 1, green: 0.36, blue: 0.36)) {
                    bms.disconnect()
                }
            } else if bms.hasLastDevice {
                actionButton("重连上次", "arrow.clockwise", .white.opacity(0.75)) {
                    bms.reconnectLast()
                }
            }

            Spacer(minLength: 0)

            Text("只列保护板品牌：蚂蚁 / 极空 / 嘉佰达 / 彦阳 / 达锂…")
                .font(.system(size: 8.5))
                .foregroundColor(.white.opacity(0.28))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 右：设备列表

    private var rightColumn: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("附近设备")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.75))
                Text("\(list.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(0.45))
                Spacer()
                Button {
                    onlyBoards.toggle()
                } label: {
                    Text(autoFallback ? "全部蓝牙（自动）" : (onlyBoards ? "仅保护板" : "全部蓝牙"))
                        .font(.system(size: 9))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(onlyBoards ? green.opacity(0.18)
                                                              : Color.white.opacity(0.10)))
                        .foregroundColor(onlyBoards ? green : .white.opacity(0.70))
                }
                .buttonStyle(.plain)
            }

            if list.isEmpty {
                VStack(spacing: 6) {
                    Spacer(minLength: 0)
                    Image(systemName: bms.phase == .scanning
                          ? "dot.radiowaves.left.and.right" : "battery.0")
                        .font(.system(size: 20, weight: .light))
                        .foregroundColor(.white.opacity(0.25))
                    Text(bms.phase == .scanning
                         ? "正在搜索保护板…"
                         : (bms.devices.isEmpty
                            ? "点左边「搜索电池」，或者直接在车上通电等它出现"
                            : "搜到 \(bms.devices.count) 个蓝牙，但没有保护板名字"))
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.40))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 5) {
                        ForEach(list) { d in
                            Button {
                                bms.connect(d)
                            } label: {
                                row(d)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(maxHeight: .infinity)
        .background(panel)
    }

    private func row(_ d: BmsCentral.Device) -> some View {
        let isCurrent = bms.connectedName?.uppercased() == d.name.uppercased()
        return HStack(spacing: 8) {
            Image(systemName: d.likely ? "battery.100.bolt" : "dot.radiowaves.left.and.right")
                .font(.system(size: 11))
                .foregroundColor(d.likely ? green : .white.opacity(0.45))
            Text(d.name)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundColor(.white.opacity(0.90))
                .lineLimit(1)
            if let b = d.brand {
                Text(b)
                    .font(.system(size: 8.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(green.opacity(0.18)))
                    .foregroundColor(green)
            }
            Spacer(minLength: 4)
            if isCurrent {
                Text("已连")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundColor(green)
            }
            Text("\(d.rssi)")
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.40))
            Image(systemName: "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundColor(.white.opacity(0.22))
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.055)))
    }

    private func actionButton(_ title: String, _ icon: String,
                              _ color: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 9).fill(color.opacity(0.14)))
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(0.28), lineWidth: 0.8))
            .foregroundColor(color)
        }
        .buttonStyle(.plain)
    }

    private var panel: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(Color.white.opacity(0.05))
            .overlay(RoundedRectangle(cornerRadius: 12)
                .stroke(Color.white.opacity(0.09), lineWidth: 0.8))
    }
}
