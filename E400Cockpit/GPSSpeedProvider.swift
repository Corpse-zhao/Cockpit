import Foundation
import CoreLocation

/// GPS 测速源
///
/// 用 CoreLocation 的 `CLLocation.speed`（m/s）换算 km/h。
/// 对电摩来说这是最准的测速手段——不依赖轮周长、不依赖下沉量估算，
/// 也不受胎压/载重/磨损影响。
///
/// 关键取舍：
/// - `bestForNavigation` + `.automotiveNavigation`：骑行姿态下定位最快最稳
/// - `pausesLocationUpdatesAutomatically = false`：等红灯时不会停更
/// - 水平精度差于 50m 或 speed < 0 视为无效（-1 是 CoreLocation 的「无速度」标记）
/// - 轻量 EMA（新值 0.6）压抖动，但保持 0.2s 级的响应
final class GPSSpeedProvider: NSObject, CLLocationManagerDelegate {

    /// (速度 km/h, 水平精度 m, 是否有效)
    var onUpdate: ((Double, Double, Bool) -> Void)?
    /// (状态文案, 是否可用)
    var onStatus: ((String, Bool) -> Void)?

    private let manager = CLLocationManager()
    private var smoothed: Double = 0
    private var hasFix = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.activityType = .automotiveNavigation
        manager.pausesLocationUpdatesAutomatically = false
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var authorizationDenied: Bool {
        manager.authorizationStatus == .denied || manager.authorizationStatus == .restricted
    }

    func start() {
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            onStatus?("定位未授权", false)
            return
        default:
            break
        }
        manager.startUpdatingLocation()
        onStatus?("搜索卫星", false)
    }

    func stop() {
        manager.stopUpdatingLocation()
        smoothed = 0
        hasFix = false
        onUpdate?(0, -1, false)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        switch manager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways:
            manager.startUpdatingLocation()
            onStatus?("搜索卫星", false)
        case .denied, .restricted:
            onStatus?("定位未授权", false)
        default:
            break
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        let acc = loc.horizontalAccuracy
        let fresh = Date().timeIntervalSince(loc.timestamp) < 5
        // speed < 0 表示本次定位解算不出速度（隧道、刚出冷启动）
        let valid = fresh && acc > 0 && acc <= 50 && loc.speed >= 0

        if valid {
            let kmh = loc.speed * 3.6
            smoothed = hasFix ? (smoothed * 0.4 + kmh * 0.6) : kmh
            hasFix = true
            onUpdate?(smoothed, acc, true)
            onStatus?(String(format: "精度 %.0f m", acc), true)
        } else {
            hasFix = false
            onUpdate?(0, acc, false)
            onStatus?(acc > 0 ? String(format: "精度差（%.0f m）", acc) : "搜索卫星", false)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        onStatus?("定位失败", false)
        onUpdate?(0, -1, false)
    }
}
