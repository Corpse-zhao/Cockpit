import SwiftUI
import UIKit

// MARK: - 图片处理小工具

enum ImageTools {
    /// 摆正方向 + 限长边。
    /// PhotosPicker 拿到的图常常带 EXIF 方向或动辄 4000px，
    /// 必须先归一化，否则裁剪坐标系会和肉眼看到的对不上。
    static func normalized(_ img: UIImage, maxSide: CGFloat = 2400) -> UIImage {
        let pixelW = CGFloat(img.cgImage?.width ?? Int(img.size.width * img.scale))
        let pixelH = CGFloat(img.cgImage?.height ?? Int(img.size.height * img.scale))
        guard pixelW > 0, pixelH > 0 else { return img }

        var w = pixelW, h = pixelH
        let longSide = max(w, h)
        if longSide > maxSide {
            let k = maxSide / longSide
            w = (w * k).rounded()
            h = (h * k).rounded()
        }

        let fmt = UIGraphicsImageRendererFormat.default()
        fmt.scale = 1
        fmt.opaque = false
        return UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { _ in
            img.draw(in: CGRect(x: 0, y: 0, width: w, height: h))
        }
    }
}

// MARK: - 壁纸裁剪

/// 拖动 + 双指缩放，框内就是仪表页真正的显示区域。
/// 裁剪在像素坐标系里算，所以无论原图多大、方向如何，最后落盘的区域都和预览一致。
struct WallpaperCropView: View {
    let source: UIImage
    /// 目标长宽比（横屏屏幕）
    var aspect: CGFloat = {
        let b = UIScreen.main.bounds
        let long = max(b.width, b.height)
        let short = min(b.width, b.height)
        return short > 0 ? long / short : 844.0 / 390.0
    }()

    var onCancel: () -> Void
    var onDone: (UIImage) -> Void

    @State private var zoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseZoom: CGFloat = 1
    @State private var baseOffset: CGSize = .zero
    @State private var winSize: CGSize = .zero

    private var pixelSize: CGSize {
        CGSize(width: source.cgImage?.width ?? Int(source.size.width),
               height: source.cgImage?.height ?? Int(source.size.height))
    }

    var body: some View {
        GeometryReader { geo in
            let maxW = min(geo.size.width - 48, (geo.size.height - 190) * aspect)
            let winW = max(120, maxW)
            let winH = winW / aspect
            let scale = max(winW / pixelSize.width, winH / pixelSize.height) * zoom

            ZStack {
                Color.black.ignoresSafeArea()

                VStack(spacing: 14) {
                    Text("拖动平移、双指缩放。框内就是仪表页显示的区域（\(Int(aspect * 100)) : 100）")
                        .font(.footnote)
                        .foregroundColor(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    cropWindow(winW: winW, winH: winH, scale: scale)
                    zoomBar

                    HStack(spacing: 12) {
                        Button("取消") { onCancel() }
                            .buttonStyle(.bordered)
                        Button("重置") { reset() }
                            .buttonStyle(.bordered)
                        Button("使用这张") { commit(winW: winW, winH: winH, scale: scale) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.horizontal, 24)
                }
            }
        }
    }

    private func cropWindow(winW: CGFloat, winH: CGFloat, scale: CGFloat) -> some View {
        ZStack {
            Image(uiImage: source)
                .resizable()
                .frame(width: pixelSize.width * scale, height: pixelSize.height * scale)
                .offset(offset)
                .frame(width: winW, height: winH)
                .clipped()

            // 三分参考线
            Path { p in
                for i in 1...2 {
                    let x = winW * CGFloat(i) / 3
                    p.move(to: CGPoint(x: x, y: 0)); p.addLine(to: CGPoint(x: x, y: winH))
                    let y = winH * CGFloat(i) / 3
                    p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: winW, y: y))
                }
            }
            .stroke(Color.white.opacity(0.18), lineWidth: 0.8)

            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
        }
        .frame(width: winW, height: winH)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onAppear { winSize = CGSize(width: winW, height: winH) }
        .onChange(of: winW) { w in winSize = CGSize(width: w, height: winH) }
        .gesture(dragGesture(winW: winW, winH: winH, scale: scale))
        .simultaneousGesture(magnifyGesture(winW: winW, winH: winH))
    }

    private var zoomBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "minus.magnifyingglass")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
            Slider(value: Binding(
                get: { Double(zoom) },
                set: { v in
                    zoom = CGFloat(v)
                    baseZoom = zoom
                    clampOffset()
                }
            ), in: 1...5)
            .frame(width: 220)
            Image(systemName: "plus.magnifyingglass")
                .font(.caption)
                .foregroundColor(.white.opacity(0.5))
            Text(String(format: "%.1f×", zoom))
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.white.opacity(0.6))
                .frame(width: 42, alignment: .leading)
        }
    }

    // MARK: 手势

    private func dragGesture(winW: CGFloat, winH: CGFloat, scale: CGFloat) -> some Gesture {
        DragGesture()
            .onChanged { g in
                let drawnW = pixelSize.width * scale
                let drawnH = pixelSize.height * scale
                let mx = max(0, (drawnW - winW) / 2)
                let my = max(0, (drawnH - winH) / 2)
                offset = CGSize(
                    width: min(max(baseOffset.width + g.translation.width, -mx), mx),
                    height: min(max(baseOffset.height + g.translation.height, -my), my)
                )
            }
            .onEnded { _ in baseOffset = offset }
    }

    private func magnifyGesture(winW: CGFloat, winH: CGFloat) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                zoom = min(max(baseZoom * v, 1), 5)
                clampOffset()
            }
            .onEnded { _ in
                baseZoom = zoom
                baseOffset = offset
            }
    }

    /// 缩放变化后重新夹紧，防止缩放变小时图片边缘露白
    private func clampOffset() {
        guard winSize.width > 1, winSize.height > 1 else { return }
        let scale = max(winSize.width / pixelSize.width, winSize.height / pixelSize.height) * zoom
        let drawnW = pixelSize.width * scale
        let drawnH = pixelSize.height * scale
        let mx = max(0, (drawnW - winSize.width) / 2)
        let my = max(0, (drawnH - winSize.height) / 2)
        offset = CGSize(width: min(max(offset.width, -mx), mx),
                        height: min(max(offset.height, -my), my))
    }

    private func reset() {
        withAnimation(.easeOut(duration: 0.2)) {
            zoom = 1
            offset = .zero
            baseZoom = 1
            baseOffset = .zero
        }
    }

    // MARK: 出图

    private func commit(winW: CGFloat, winH: CGFloat, scale: CGFloat) {
        guard let cg = source.cgImage else { return }
        let W = CGFloat(cg.width), H = CGFloat(cg.height)

        let cropW = winW / scale
        let cropH = winH / scale
        let cx = W / 2 - offset.width / scale
        let cy = H / 2 - offset.height / scale

        var rect = CGRect(x: cx - cropW / 2, y: cy - cropH / 2, width: cropW, height: cropH)
        rect = rect.intersection(CGRect(x: 0, y: 0, width: W, height: H))
        guard rect.width >= 4, rect.height >= 4,
              let cropped = cg.cropping(to: rect.integral) else { return }

        onDone(UIImage(cgImage: cropped, scale: 1, orientation: .up))
    }
}
