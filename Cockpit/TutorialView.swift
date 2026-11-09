import SwiftUI

// MARK: - 使用教程

/// 首次启动自动弹一次（`tutorial_seen`），之后从「设置 → 关于」还能再看。
/// 一整屏纵向滑动，滑到底「我知道了」才亮；「再看一遍」滚回开头。
struct TutorialView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("tutorial_seen") private var seen = false

    @State private var contentH: CGFloat = 1
    @State private var bottomY: CGFloat = 1
    @State private var viewportH: CGFloat = 1

    private let pink = Color(red: 0.86, green: 0.05, blue: 0.42)
    private let pinkLight = Color(red: 1.0, green: 0.36, blue: 0.66)

    /// 0…1，滑到底才是 1
    private var progress: Double {
        let scrollable = max(contentH - viewportH, 1)
        let scrolled = max(contentH - bottomY, 0)
        return min(1, max(0, scrolled / scrollable))
    }

    private var atBottom: Bool {
        contentH <= viewportH + 12 || progress > 0.995
    }

    var body: some View {
        ScrollViewReader { proxy in
            VStack(spacing: 0) {
                header
                GeometryReader { geo in
                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 10) {
                            Color.clear.frame(height: 0).id("tut_top")
                            hero
                            ForEach(Tutorial.content) { s in
                                card(s)
                            }
                            ending
                        }
                        .padding(.horizontal, 26)
                        .padding(.top, 14)
                        .padding(.bottom, 26)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: TutMetricsKey.self,
                                    value: TutMetrics(
                                        contentH: g.size.height,
                                        bottomY: g.frame(in: .named("tut")).maxY
                                    )
                                )
                            }
                        )
                    }
                    .coordinateSpace(name: "tut")
                    .onPreferenceChange(TutMetricsKey.self) { m in
                        contentH = m.contentH
                        bottomY = m.bottomY
                    }
                    .onAppear { viewportH = geo.size.height }
                    .onChange(of: geo.size.height) { h in viewportH = h }
                }
                footer(proxy)
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
    }

    // MARK: 背景

    private var background: some View {
        ZStack {
            Color(red: 0.043, green: 0.012, blue: 0.024)
            RadialGradient(colors: [pink.opacity(0.34), .clear],
                           center: UnitPoint(x: 0.92, y: -0.05),
                           startRadius: 8, endRadius: 520)
            RadialGradient(colors: [Color(red: 0.47, green: 0.02, blue: 0.24).opacity(0.55), .clear],
                           center: UnitPoint(x: 0.02, y: 1.02),
                           startRadius: 8, endRadius: 460)
            LinearGradient(colors: [Color.black.opacity(0.55), .clear],
                           startPoint: .leading, endPoint: UnitPoint(x: 0.45, y: 0.5))
        }
    }

    // MARK: 头

    private var header: some View {
        HStack(spacing: 8) {
            Text("使用教程")
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(pinkLight)
            Text("共 \(Tutorial.content.count) 节 · 约 3 分钟")
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.50))
            Spacer()
            Text("↓ 可滑动")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.white.opacity(0.35))
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.10)).frame(height: 0.5)
        }
    }

    // MARK: 首屏

    private var hero: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("作者说")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(pinkLight)
                .tracking(1.2)
            (Text("下面就是各类功能\n")
                + Text("讲解教学").foregroundColor(pinkLight))
                .font(.system(size: 30, weight: .bold))
                .foregroundColor(.white)
                .lineSpacing(2)
                .padding(.top, 4)
            md("本来只是我自己闲得慌做的一个小玩意，想看看控制器和电池到底在说什么。**没想到越写越多**，最后成了这么一块正经仪表。下面九节，都是我自己踩过的坑——看完能省你至少两小时。")
                .font(.system(size: 13.5))
                .foregroundColor(.white.opacity(0.62))
                .lineSpacing(5)
                .padding(.top, 9)
                .frame(maxWidth: 560, alignment: .leading)
        }
    }

    // MARK: 卡片

    private func card(_ s: Tutorial.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 7) {
                Text("\(s.id)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(pinkLight)
                    .frame(width: 19, height: 19)
                    .background(Circle().fill(pink.opacity(0.28)))
                Text(s.title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.white)
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(s.lines.enumerated()), id: \.offset) { _, line in
                    md(line)
                        .font(.system(size: 12.5))
                        .foregroundColor(.white.opacity(0.60))
                        .lineSpacing(4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 7)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(0.055))
                .overlay(RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.white.opacity(0.10), lineWidth: 0.6))
        )
    }

    // MARK: 结尾

    private var ending: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("作者说")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(pinkLight)
                .tracking(1.2)
            Text("就这些，剩下的自己骑两圈就懂了")
                .font(.system(size: 22, weight: .bold))
                .foregroundColor(.white)
                .padding(.top, 4)
            md("数据是给你看的，不是给你焦虑的。**「——」不是坏了**，是那一项这辆车确实没有；**「状态良好」也不用天天盯着**，出问题它会变红。\n\n以后想再看一遍：设置 → 关于 → 使用教程。")
                .font(.system(size: 13))
                .foregroundColor(.white.opacity(0.60))
                .lineSpacing(5)
                .padding(.top, 8)
                .frame(maxWidth: 560, alignment: .leading)
            HStack(spacing: 6) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 10, weight: .bold))
                Text(atBottom ? "已经到底了，点下面「我知道了」收起来" : "继续往下滑")
                    .font(.system(size: 11))
            }
            .foregroundColor(atBottom ? pinkLight : .white.opacity(0.32))
            .padding(.top, 16)
        }
        .padding(.top, 4)
    }

    // MARK: 底部条

    private func footer(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 11) {
            VStack(alignment: .leading, spacing: 4) {
                Text(atBottom
                     ? "已经看完 · 可以确认了"
                     : String(format: "已经看到 %.0f%% · 滑到底才能确认", progress * 100))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white.opacity(atBottom ? 0.62 : 0.36))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.10))
                        Capsule()
                            .fill(LinearGradient(colors: [pink, pinkLight],
                                                 startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(3, g.size.width * CGFloat(atBottom ? 1 : progress)))
                    }
                }
                .frame(height: 3)
            }

            Button {
                seen = true
                dismiss()
            } label: {
                Text("我知道了")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(
                        Capsule().fill(LinearGradient(
                            colors: [pink, pinkLight],
                            startPoint: .leading, endPoint: .trailing))
                    )
                    .foregroundColor(.white)
                    .opacity(atBottom ? 1 : 0.30)
                    .shadow(color: atBottom ? pink.opacity(0.42) : .clear, radius: 10, y: 4)
            }
            .buttonStyle(.plain)
            .disabled(!atBottom)

            Button {
                withAnimation(.easeOut(duration: 0.35)) {
                    proxy.scrollTo("tut_top", anchor: .top)
                }
            } label: {
                Text("再看一遍")
                    .font(.system(size: 13, weight: .semibold))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 9)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.07))
                            .overlay(Capsule().stroke(Color.white.opacity(0.16), lineWidth: 0.8))
                    )
                    .foregroundColor(.white.opacity(0.82))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .padding(.bottom, 11)
        .background(Color.black.opacity(0.42))
        .overlay(alignment: .top) {
            Rectangle().fill(Color.white.opacity(0.09)).frame(height: 0.5)
        }
    }

    /// 行内 Markdown（**加粗**）转 Text
    private func md(_ s: String) -> Text {
        if let a = try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            return Text(a)
        }
        return Text(s)
    }
}

// MARK: - 进度测量

private struct TutMetrics: Equatable {
    var contentH: CGFloat = 0
    var bottomY: CGFloat = 0
}

private struct TutMetricsKey: PreferenceKey {
    static var defaultValue = TutMetrics()
    static func reduce(value: inout TutMetrics, nextValue: () -> TutMetrics) {
        value = nextValue()
    }
}

// MARK: - 内容

enum Tutorial {

    struct Section: Identifiable {
        var id: Int
        var title: String
        var lines: [String]
    }

    static let content: [Section] = [
        Section(id: 1, title: "先给两个权限", lines: [
            "第一次打开会问**蓝牙**和**定位**，两个都允许。",
            "定位给「使用期间」就够；不给也能用，只是没有 GPS 车速和里程。",
            "蓝牙要是点了不允许，去 设置 → 蓝牙 里放开，再回 App。"
        ]),
        Section(id: 2, title: "连控制器", lines: [
            "进 App 会自动连上次那台。第一次用要手动点左栏「扫描控制器」，等 `LBMC-xxx` 出现，点一下。",
            "之后每次开机都会自己连，不用再点；手动点「断开」不会被自动连回来。",
            "想换车或换控：设置 → 连接与显示 → 忘记这台控制器。",
            "控制器走 FFF0 通道，**和电池互不影响**，一条断了另一条照跑。"
        ]),
        Section(id: 3, title: "连电池 BMS", lines: [
            "右栏只列保护板品牌（蚂蚁 / 极空 / 嘉佰达 / 彦阳 / 达锂），耳机手表不会混进来。",
            "仪表页底下那条虚线「电池未连接」点一下也能直接连，不用跑设置。",
            "连上后每 0.4 秒问一次状态；想省电可以在设置里调到 1 秒或 2 秒。"
        ]),
        Section(id: 4, title: "仪表页怎么读", lines: [
            "左边分四层：**上面两层控制器，下面两层电池**。电池没连时控制器自己撑满，不留空。",
            "右边圆盘：大数字是车速，中间是功率，最下面一行是母线电压和控制器温度。",
            "最底一条是 GPS 状态和本次里程。"
        ]),
        Section(id: 5, title: "几个数字别理解错", lines: [
            "**功率**单位是瓦。踏板车上千瓦永远是 0.xx，看不出变化，所以直接给整数瓦。",
            "**相电流**是控制器给的「相电流平方」再开根，属推算值——看趋势，别抠绝对值。",
            "**故障码**没故障写「状态良好」，有故障才显示 `0x00XX` 并变红。",
            "**定位精度**是 GPS 水平精度，8 m 以内算能用，越小车速越准。",
            "**SOH** 是电池健康度。新电池 100%，掉到 80% 以下该考虑换电池了。"
        ]),
        Section(id: 6, title: "电池详情", lines: [
            "点电池那一块任意位置进去。",
            "左边是 SOC、总压、电流、剩余/额定容量，下面是温度、MOS 开关、保护、均衡。",
            "右边是单体电压柱状图，20 串两列排；高于平均的用主色、低的用浅色，压差一眼就看出来。"
        ]),
        Section(id: 7, title: "设置里值得改的", lines: [
            "**主题色**：只换强调色（进度弧、发光、关键数值、按钮），毛玻璃和刻度不变。",
            "**壁纸**：「铺满」会把 4:3 照片放大 6 成再裁掉上下；「完整显示」一点不裁，两侧用模糊补。",
            "**小数位**：影响电压/电流/功率/温度，速度固定整数。",
            "**测速来源**：GPS 优先 / 只用 GPS / 只用轮速，GPS 没信号时会自动回落到轮速。",
            "**轮胎周长**：换过胎或者想更准，量一下填进去。"
        ]),
        Section(id: 8, title: "数据台（排障用）", lines: [
            "「数据台」标签页有原始字节、帧长、字段偏移，还有 BMS 帧。",
            "数据不动、显示「——」的时候先看这里：帧长 23 说明车只回了短帧，有些字段本来就没有。",
            "最下面有「复制协议诊断」，粘给我就能查。"
        ]),
        Section(id: 9, title: "常见问题", lines: [
            "**连不上**：走近车，确认没被官方 App 或另一台手机占着。",
            "**数据不动**：蓝牙连着但没数据，App 会自己重连；还不行就断开重连一次。",
            "**电池时不时掉线**：保护板模块本身就这样，App 会自动重连，不用管。",
            "**为什么有「——」**：那一项这辆车确实没有，不是坏了。"
        ])
    ]
}
