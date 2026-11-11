import Foundation
import UserNotifications

/// 側載簽名到期提醒：讀取 App 內嵌的 embedded.mobileprovision，取得到期日。
/// 免費 Apple ID 簽名約 7 天到期；到期前提醒你重新簽名。
@MainActor
final class ExpiryReminder: ObservableObject {
    @Published private(set) var expiry: Date?
    @Published var daysBefore: Int {
        didSet { UserDefaults.standard.set(daysBefore, forKey: "expiryDaysBefore"); schedule() }
    }
    @Published var hour: Int {
        didSet { UserDefaults.standard.set(hour, forKey: "expiryHour"); schedule() }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "expiryEnabled"); schedule() }
    }

    init() {
        let d = UserDefaults.standard
        daysBefore = d.object(forKey: "expiryDaysBefore") as? Int ?? 1
        hour = d.object(forKey: "expiryHour") as? Int ?? 10
        enabled = d.object(forKey: "expiryEnabled") as? Bool ?? true
        expiry = ExpiryReminder.readExpiry()
        schedule()
    }

    var remainingText: String {
        guard let expiry = expiry else { return "無法讀取（可能是用開發者帳號或模擬器安裝）" }
        let secs = expiry.timeIntervalSinceNow
        if secs <= 0 { return "已到期，請重新簽名" }
        let days = Int(secs / 86400)
        let hours = Int(secs.truncatingRemainder(dividingBy: 86400) / 3600)
        return "剩 \(days) 天 \(hours) 小時"
    }

    var soon: Bool {
        guard let expiry = expiry else { return false }
        return expiry.timeIntervalSinceNow < 86400
    }

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func schedule() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: ["signing-expiry"])
        guard enabled, let expiry = expiry else { return }
        var fire = Calendar.current.date(byAdding: .day, value: -daysBefore, to: expiry) ?? expiry
        fire = Calendar.current.date(bySettingHour: hour, minute: 0, second: 0, of: fire) ?? fire
        guard fire > Date() else { return }
        let content = UNMutableNotificationContent()
        content.title = "Teleo 簽名即將到期"
        content.body = "請在到期前用 Sideloadly 或 SideStore 重新簽名，否則 App 會打不開。"
        let comps = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: fire)
        let trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        center.add(UNNotificationRequest(identifier: "signing-expiry", content: content, trigger: trigger))
    }

    private static func readExpiry() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let start = data.range(of: Data("<?xml".utf8)),
              let end = data.range(of: Data("</plist>".utf8)) else { return nil }
        let plistData = data.subdata(in: start.lowerBound..<end.upperBound)
        guard let obj = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil),
              let dict = obj as? [String: Any] else { return nil }
        return dict["ExpirationDate"] as? Date
    }
}
