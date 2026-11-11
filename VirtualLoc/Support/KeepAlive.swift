import Foundation
import CoreLocation

/// 以持續定位維持 App 在背景存活（Info.plist 已宣告 location 背景模式），
/// 同時在尚未模擬定位時記錄「原始位置」。
@MainActor
final class KeepAlive: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var original: Coord?
    @Published private(set) var originalAccuracy: Double?
    @Published private(set) var originalDate: Date?
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published var enabled: Bool = true {
        didSet {
            UserDefaults.standard.set(enabled, forKey: "keepAliveEnabled")
            enabled ? start() : stop()
        }
    }

    /// 模擬期間為 true：此時系統回報的位置是假的，不可當成原始位置
    var isSpoofing = false

    private let manager = CLLocationManager()
    private var running = false

    override init() {
        super.init()
        if UserDefaults.standard.object(forKey: "keepAliveEnabled") != nil {
            enabled = UserDefaults.standard.bool(forKey: "keepAliveEnabled")
        }
        let d = UserDefaults.standard
        if d.object(forKey: "origLat") != nil {
            original = Coord(latitude: d.double(forKey: "origLat"), longitude: d.double(forKey: "origLon"))
            originalAccuracy = d.object(forKey: "origAcc") as? Double
            originalDate = d.object(forKey: "origDate") as? Date
        }
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        authorization = manager.authorizationStatus
    }

    func start() {
        guard enabled else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
            return
        }
        guard manager.authorizationStatus == .authorizedWhenInUse
                || manager.authorizationStatus == .authorizedAlways else { return }
        manager.allowsBackgroundLocationUpdates = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
        running = true
    }

    func stop() {
        manager.stopUpdatingLocation()
        running = false
    }

    /// 手動重新取得原始位置（模擬中不可用）
    func refreshOriginal() {
        guard !isSpoofing else { return }
        manager.requestLocation()
    }

    // MARK: CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if status == .authorizedWhenInUse || status == .authorizedAlways { self.start() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, loc.horizontalAccuracy >= 0 else { return }
        Task { @MainActor in
            guard !self.isSpoofing else { return }
            // 已有原始位置且精度沒有更好時不覆蓋，避免被抖動洗掉
            if self.original != nil, let old = self.originalAccuracy, loc.horizontalAccuracy > old * 1.5 { return }
            self.original = loc.coordinate
            self.originalAccuracy = loc.horizontalAccuracy
            self.originalDate = Date()
            let d = UserDefaults.standard
            d.set(loc.coordinate.latitude, forKey: "origLat")
            d.set(loc.coordinate.longitude, forKey: "origLon")
            d.set(loc.horizontalAccuracy, forKey: "origAcc")
            d.set(Date(), forKey: "origDate")
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // 定位失敗不影響模擬，略過
    }
}
