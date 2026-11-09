import Foundation
import CoreLocation
import Combine

/// 真实天气：走 Open-Meteo 的免费接口（不用注册、不用 key、不用备案）。
///
/// 取数逻辑：
/// 1. 设置里填了城市 → 先地理编码成坐标（CLGeocoder）
/// 2. 没填 → 用 CoreLocation 要一次定位（只取一次，不常驻，省电）
/// 3. 坐标拿到后抓 `current.temperature_2m / weather_code`
/// 4. 结果连坐标一起缓存，30 分钟内不重复请求；断网就沿用旧值并在设置里标状态
///
/// 注意：这个类不常驻定位、不开后台刷新——天气变化本来就很慢，
/// 半小时一次足够，没必要跟 GPS 测速抢定位硬件。
final class WeatherCenter: NSObject, ObservableObject, CLLocationManagerDelegate {

    /// 全局一份：设置页改城市后能立刻让仪表页看到新值，不用等下一个 30 分钟
    static let shared = WeatherCenter()

    static let enabledKey = "weather_on"
    static let cityKey = "weather_city"

    private static let cacheTemp = "weather_temp"
    private static let cacheCode = "weather_code"
    private static let cacheAt   = "weather_at"
    private static let cacheLat  = "weather_lat"
    private static let cacheLon  = "weather_lon"

    /// 当前气温（℃）。nil = 还没拿到
    @Published private(set) var temp: Double?
    /// WMO 天气码
    @Published private(set) var code: Int?
    /// 给设置页看的状态文案
    @Published private(set) var status = "还没更新"
    @Published private(set) var updatedAt: Date?

    private let manager = CLLocationManager()
    private var fetching = false
    private var timer: Timer?
    private var geocoder: CLGeocoder?

    override init() {
        super.init()
        manager.delegate = self
        // 天气只要城市级精度，用公里级就够，别为了个温度把 GPS 拉满
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
    }

    deinit {
        timer?.invalidate()
    }

    var enabled: Bool {
        UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool ?? true
    }

    // MARK: 生命周期

    func start() {
        loadCache()
        refresh()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1800, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: 取数

    func refresh(force: Bool = false) {
        guard enabled, !fetching else { return }

        // 半小时内用过同一坐标就不再打扰系统（force 用于「改了城市立刻重取」）
        if !force, let at = cachedAt, Date().timeIntervalSince(at) < 1800,
           let lat = cachedCoord?.latitude, let lon = cachedCoord?.longitude {
            fetch(lat: lat, lon: lon)
            return
        }

        let city = (UserDefaults.standard.string(forKey: Self.cityKey) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !city.isEmpty {
            geocode(city)
        } else {
            requestLocation()
        }
    }

    private func requestLocation() {
        switch manager.authorizationStatus {
        case .notDetermined:
            // 授权结果在 didChangeAuthorization 里再继续
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            if let c = cachedCoord {
                status = "定位未授权，用上次位置"
                fetch(lat: c.latitude, lon: c.longitude)
            } else {
                status = "定位未授权"
            }
        default:
            status = "定位中"
            manager.requestLocation()
        }
    }

    private func geocode(_ city: String) {
        status = "解析城市"
        let g = CLGeocoder()
        geocoder = g
        g.geocodeAddressString(city) { [weak self] marks, _ in
            guard let self = self else { return }
            guard let loc = marks?.first?.location else {
                self.status = "没找到这个城市"
                self.requestLocation()
                return
            }
            self.saveCoord(loc.coordinate)
            self.fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
        }
    }

    private func fetch(lat: Double, lon: Double) {
        guard !fetching else { return }
        guard let url = URL(string: String(
            format: "https://api.open-meteo.com/v1/forecast?latitude=%.4f&longitude=%.4f&current=temperature_2m,weather_code",
            lat, lon)) else { return }

        fetching = true
        status = "更新中"

        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.cachePolicy = .reloadIgnoringLocalCacheData

        URLSession.shared.dataTask(with: req) { [weak self] data, _, err in
            guard let self = self else { return }

            guard let data = data, err == nil else {
                DispatchQueue.main.async {
                    self.fetching = false
                    self.status = self.temp == nil ? "没网络" : "没网络，用上次的数据"
                }
                return
            }

            do {
                let r = try JSONDecoder().decode(Response.self, from: data)
                DispatchQueue.main.async {
                    self.temp = r.current.temperature_2m
                    self.code = r.current.weather_code
                    self.updatedAt = Date()
                    self.status = "已更新"
                    self.fetching = false
                    self.saveCache()
                }
            } catch {
                DispatchQueue.main.async {
                    self.fetching = false
                    self.status = "数据解析失败"
                }
            }
        }.resume()
    }

    // MARK: 缓存

    private var cachedCoord: CLLocationCoordinate2D? {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.cacheLat) != nil else { return nil }
        return CLLocationCoordinate2D(latitude: d.double(forKey: Self.cacheLat),
                                      longitude: d.double(forKey: Self.cacheLon))
    }

    private var cachedAt: Date? {
        let t = UserDefaults.standard.double(forKey: Self.cacheAt)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    private func loadCache() {
        let d = UserDefaults.standard
        guard d.object(forKey: Self.cacheTemp) != nil else { return }
        temp = d.double(forKey: Self.cacheTemp)
        code = d.integer(forKey: Self.cacheCode)
        if let at = cachedAt { updatedAt = at }
        status = "用缓存"
    }

    private func saveCache() {
        let d = UserDefaults.standard
        if let t = temp { d.set(t, forKey: Self.cacheTemp) }
        if let c = code { d.set(c, forKey: Self.cacheCode) }
        d.set(Date().timeIntervalSince1970, forKey: Self.cacheAt)
    }

    private func saveCoord(_ c: CLLocationCoordinate2D) {
        let d = UserDefaults.standard
        d.set(c.latitude, forKey: Self.cacheLat)
        d.set(c.longitude, forKey: Self.cacheLon)
    }

    // MARK: CLLocationManagerDelegate

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways else { return }
        manager.requestLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        saveCoord(loc.coordinate)
        fetch(lat: loc.coordinate.latitude, lon: loc.coordinate.longitude)
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        if let c = cachedCoord {
            fetch(lat: c.latitude, lon: c.longitude)
        } else {
            status = "定位失败"
            fetching = false
        }
    }

    // MARK: 展示

    private struct Response: Decodable {
        struct Current: Decodable {
            let temperature_2m: Double
            let weather_code: Int
        }
        let current: Current
    }

    var tempText: String {
        guard let t = temp else { return "--°c" }
        return "\(Int(t.rounded()))°c"
    }

    /// WMO 天气码 → SF Symbol
    static func symbol(for code: Int?) -> String {
        guard let c = code else { return "cloud" }
        switch c {
        case 0:            return "sun.max.fill"
        case 1, 2:         return "cloud.sun.fill"
        case 3:            return "cloud.fill"
        case 45, 48:       return "cloud.fog.fill"
        case 51, 53, 55,
             56, 57:       return "cloud.drizzle.fill"
        case 61, 63, 65,
             66, 67:       return "cloud.rain.fill"
        case 71, 73, 75,
             77:           return "cloud.snow.fill"
        case 80, 81, 82:   return "cloud.heavyrain.fill"
        case 85, 86:       return "cloud.snow.fill"
        case 95, 96, 99:   return "cloud.bolt.rain.fill"
        default:           return "cloud.fill"
        }
    }
}
