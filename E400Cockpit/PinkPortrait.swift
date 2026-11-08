import SwiftUI
import UIKit

/// 粉黑仪表中间的立绘。
///
/// 用户从相册选一张（最好是抠好的透明底 PNG），存进 Documents，
/// 仪表页优先画它；没选过就回落到全息核心——不至于开天窗。
enum PortraitStore {
    static let versionKey = "pink_portrait_version"
    static let fileName = "pink_portrait.png"

    private static var url: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(fileName)
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static var image: UIImage? {
        guard exists else { return nil }
        return UIImage(contentsOfFile: url.path)
    }

    /// 统一转成 PNG 存：JPG 会把透明底烧成白底，抠图就白抠了
    @discardableResult
    static func save(_ data: Data) -> Bool {
        guard let img = UIImage(data: data), let png = img.pngData() else { return false }
        do {
            try png.write(to: url, options: .atomic)
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: versionKey)
            return true
        } catch {
            return false
        }
    }

    static func clear() {
        try? FileManager.default.removeItem(at: url)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: versionKey)
    }

    static var sizeText: String {
        guard let img = image else { return "未设置" }
        return "\(Int(img.size.width))×\(Int(img.size.height))"
    }
}
