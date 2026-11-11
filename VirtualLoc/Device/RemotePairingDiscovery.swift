import Foundation

/// 像 StikPair／idevice_pair「非 lockdown」模式這種無線配對（RPPairing）產生的配對檔，
/// 連線時不是打固定的 62078，而是裝置本機廣播出來的 `_remotepairing._tcp` Bonjour 服務，
/// 而這個服務的連接埠**不是固定的**。
///
/// 實務上：
/// 1. 使用者可以在設定裡手動指定一個埠號（之前試過哪個能用，就固定用那個，省掉每次掃描的時間）
/// 2. 很多裝置上這個服務常落在 49152，所以先試這個
/// 3. 都不行的話，才真的用 Bonjour 掃描本機的 `_remotepairing._tcp` 服務，取得目前實際的埠號
///
/// 由於 LocalDevVPN 的回環通道是整包 IP 做位址轉換（不是只轉某一個埠），
/// 所以只要埠號猜對，透過 10.7.0.1 連過去就會被轉送到裝置本機對應的服務。
final class RemotePairingDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    /// 多數裝置上 RemotePairing 服務常見的連接埠；StikDebug 等工具在掃描不到時也是退回用這個。
    static let fallbackPort: UInt16 = 49152

    static let overrideDefaultsKey = "remotePairingPortOverride"

    /// 使用者在設定裡手動指定的埠號（0 或沒設定代表沒有）
    static var overridePort: UInt16? {
        let v = UserDefaults.standard.integer(forKey: overrideDefaultsKey)
        return v > 0 && v <= 65535 ? UInt16(v) : nil
    }

    /// 依序嘗試的候選埠號：手動設定優先，接著是常見的備用埠，最後才是即時掃描（比較慢，放最後）。
    static func candidatePorts(includeDiscovery: Bool, timeout: TimeInterval = 4) -> [UInt16] {
        var ports: [UInt16] = []
        if let p = overridePort { ports.append(p) }
        if !ports.contains(fallbackPort) { ports.append(fallbackPort) }
        if includeDiscovery {
            if let found = RemotePairingDiscovery().discover(timeout: timeout), !ports.contains(found) {
                ports.append(found)
            }
        }
        return ports
    }

    private let semaphore = DispatchSemaphore(value: 0)
    private var resolvedPort: UInt16?
    private var pendingServices: [NetService] = []

    /// 掃描本機的 `_remotepairing._tcp` 服務，找到並解析出埠號就回傳；逾時回傳 nil。
    /// 必須在非主執行緒呼叫（內部會同步等待）。
    func discover(timeout: TimeInterval) -> UInt16? {
        let browser = NetServiceBrowser()
        browser.delegate = self
        browser.schedule(in: .main, forMode: .common)
        browser.searchForServices(ofType: "_remotepairing._tcp.", inDomain: "local.")
        _ = semaphore.wait(timeout: .now() + timeout)
        browser.stop()
        browser.remove(from: .main, forMode: .common)
        pendingServices.forEach { $0.stop() }
        return resolvedPort
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        pendingServices.append(service)
        service.delegate = self
        service.schedule(in: .main, forMode: .common)
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        if resolvedPort == nil, sender.port > 0 {
            resolvedPort = UInt16(sender.port)
        }
        semaphore.signal()
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        semaphore.signal()
    }
}
