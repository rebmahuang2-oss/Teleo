import Foundation
import Darwin

enum LinkError: LocalizedError {
    case noPairingFile
    case notConnected
    case ffi(step: String, code: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .noPairingFile:
            return "尚未匯入配對檔"
        case .notConnected:
            return "尚未連線"
        case let .ffi(step, code, message):
            return "\(step)失敗（\(code)）：\(message)"
        }
    }
}

/// 專用的單一執行緒。idevice 的文件要求 adapter 與其 stream 必須在同一條執行緒使用；
/// DispatchQueue 不保證每次都在同一條執行緒，所以改用固定執行緒依序執行工作。
final class SerialThread: Thread {
    private let cond = NSCondition()
    private var jobs: [() -> Void] = []

    override init() {
        super.init()
        name = "virtualloc.devicelink"
        stackSize = 8 * 1024 * 1024
        qualityOfService = .userInitiated
        start()
    }

    override func main() {
        while true {
            cond.lock()
            while jobs.isEmpty { cond.wait() }
            let job = jobs.removeFirst()
            cond.unlock()
            job()
        }
    }

    /// 與 DispatchQueue.async 相同的呼叫方式
    func async(_ job: @escaping () -> Void) {
        cond.lock()
        jobs.append(job)
        cond.signal()
        cond.unlock()
    }
}

/// 對 idevice 的薄封裝：配對檔 → 本機回環 (10.7.0.1) → CoreDeviceProxy → RSD → RemoteServer → LocationSimulation。
/// idevice 的 handle 不是執行緒安全的，所有呼叫都在同一條固定的執行緒上依序進行。
final class DeviceLink: @unchecked Sendable {
    private let queue = SerialThread()

    // 以下屬性只在 queue 上讀寫
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var remote: OpaquePointer?
    private var locsim: OpaquePointer?

    private let lock = NSLock()
    private var connectedFlag = false
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return connectedFlag
    }
    private func setConnected(_ v: Bool) {
        lock.lock(); connectedFlag = v; lock.unlock()
    }

    /// 本機回環位址（LocalDevVPN 提供）與 lockdown 連接埠
    static let loopbackAddress = "10.7.0.1"
    static let lockdownPort: UInt16 = 62078

    // MARK: 對外（async）

    func connect(pairingPath: String) async throws {
        try await run { try self.connectSync(pairingPath: pairingPath) }
    }

    func set(latitude: Double, longitude: Double) async throws {
        try await run { try self.setSync(latitude: latitude, longitude: longitude) }
    }

    func clear() async throws {
        try await run { try self.clearSync() }
    }

    func disconnect() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            queue.async {
                self.teardown()
                cont.resume()
            }
        }
    }

    private func run<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                do { cont.resume(returning: try work()) }
                catch { cont.resume(throwing: error) }
            }
        }
    }

    // MARK: 實作（在 queue 上執行）

    private func check(_ err: UnsafeMutablePointer<IdeviceFfiError>?, _ step: String) throws {
        guard let err = err else { return }
        let code = err.pointee.code
        let message = err.pointee.message.map { String(cString: $0) } ?? "未知錯誤"
        idevice_error_free(err)
        throw LinkError.ffi(step: step, code: code, message: message)
    }

    /// 配對檔有兩種完全不同的格式：
    /// - 無線配對（RPPairing）：idevice_pair「非 lockdown」模式、StikPair 這類工具產生的
    /// - 傳統 lockdown 配對：idevice_pair「lockdown」模式產生的（需要 USB 線）
    ///
    /// 實測發現：就算拿到的是合法的 lockdown 配對檔，透過 LocalDevVPN 這種回環 VPN
    /// （而不是真的 USB 線）連線時，手機端常常會在 TLS 這一步直接斷線拒絕
    /// （Socket(1)：peer closed connection without sending TLS close_notify），
    /// 這是 iOS 對「非 USB 連線」的安全限制，不是配對檔本身壞掉。
    /// 無線配對（RPPairing）協定是專門設計給網路連線用的，才是這種回環 VPN 情境下真正該走的路。
    ///
    /// 所以這裡會先試著把配對檔當無線配對讀；讀得起來就走無線配對的連線方式。
    /// 讀不起來（代表它其實是傳統格式）才退回傳統 lockdown 連線方式。
    private func connectSync(pairingPath: String) throws {
        teardown()

        var rpPairing: OpaquePointer? = nil
        let rpReadErr = rp_pairing_file_read(pairingPath, &rpPairing)

        if rpReadErr == nil, let rpPairing {
            try connectViaRemotePairing(rpPairing: rpPairing, pairingPath: pairingPath)
        } else {
            if let rpReadErr { idevice_error_free(rpReadErr) }
            try connectViaClassicLockdown(pairingPath: pairingPath)
        }
    }

    private func connectViaRemotePairing(rpPairing: OpaquePointer, pairingPath: String) throws {
        defer { rp_pairing_file_free(rpPairing) }

        var newAdapter: OpaquePointer? = nil
        var hs: OpaquePointer? = nil
        var lastError: LinkError?

        // 先試不用掃描的候選埠（手動指定、常見備用埠 49152），都不行才真的掃一次 Bonjour。
        var tried = RemotePairingDiscovery.candidatePorts(includeDiscovery: false)
        var attemptedDiscovery = false
        var index = 0
        while true {
            guard index < tried.count else {
                if attemptedDiscovery { break }
                attemptedDiscovery = true
                tried = RemotePairingDiscovery.candidatePorts(includeDiscovery: true)
                index = 0
                if tried.isEmpty { break }
                continue
            }
            let port = tried[index]
            index += 1

            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            inet_pton(AF_INET, DeviceLink.loopbackAddress, &addr.sin_addr)

            var candidateAdapter: OpaquePointer? = nil
            var candidateHandshake: OpaquePointer? = nil
            let tunnelErr: UnsafeMutablePointer<IdeviceFfiError>? = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    tunnel_create_rppairing(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                                             "Teleo", rpPairing, nil, nil,
                                             &candidateAdapter, &candidateHandshake)
                }
            }
            if tunnelErr == nil {
                newAdapter = candidateAdapter
                hs = candidateHandshake
                lastError = nil
                break
            } else {
                do { try check(tunnelErr, "建立無線配對通道（埠 \(port)）") }
                catch let e as LinkError { lastError = e }
                catch {}
            }
        }

        guard let newAdapter else {
            throw lastError ?? LinkError.ffi(step: "建立無線配對通道", code: 13, message: "找不到裝置本機的無線配對服務")
        }
        adapter = newAdapter
        handshake = hs

        // 配對驗證成功後 idevice 可能會更新配對檔內容，寫回去才不會每次都重新驗證。
        _ = rp_pairing_file_write(rpPairing, pairingPath)

        try finishTunnel()
    }

    private func connectViaClassicLockdown(pairingPath: String) throws {
        let fixedPath = try PairingFileFixer.normalizedCopy(of: pairingPath)

        var pairing: OpaquePointer? = nil
        try check(idevice_pairing_file_read(fixedPath, &pairing), "讀取配對檔")

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = DeviceLink.lockdownPort.bigEndian
        inet_pton(AF_INET, DeviceLink.loopbackAddress, &addr.sin_addr)

        // pairing 會被 provider 吃掉（成功與否都不能再使用）
        var provider: OpaquePointer? = nil
        let providerErr: UnsafeMutablePointer<IdeviceFfiError>? = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                idevice_tcp_provider_new(sa, pairing, "VirtualLoc", &provider)
            }
        }
        try check(providerErr, "建立連線")

        var proxy: OpaquePointer? = nil
        let proxyErr = core_device_proxy_connect(provider, &proxy)
        idevice_provider_free(provider)
        try check(proxyErr, "連線 CoreDeviceProxy（請確認 LocalDevVPN 已開啟並連上 Wi-Fi）")

        var rsdPort: UInt16 = 0
        let portErr = core_device_proxy_get_server_rsd_port(proxy, &rsdPort)
        if portErr != nil {
            core_device_proxy_free(proxy)
            try check(portErr, "取得 RSD 連接埠")
        }

        // proxy 在此被消耗，之後不可再使用
        var newAdapter: OpaquePointer? = nil
        try check(core_device_proxy_create_tcp_adapter(proxy, &newAdapter), "建立 TCP 轉接")
        adapter = newAdapter

        do {
            var stream: OpaquePointer? = nil
            try check(adapter_connect(adapter, rsdPort, &stream), "連接 RSD 連接埠")

            // stream 在此被消耗
            var hs: OpaquePointer? = nil
            try check(rsd_handshake_new(stream, &hs), "RSD 握手")
            handshake = hs
        } catch {
            teardown()
            throw error
        }

        try finishTunnel()
    }

    /// adapter／handshake 準備好之後，兩種配對方式共用的最後兩步。
    private func finishTunnel() throws {
        do {
            var rs: OpaquePointer? = nil
            try check(remote_server_connect_rsd(adapter, handshake, &rs),
                      "連接開發者服務（請確認已開啟開發者模式並掛載開發者磁碟映像）")
            remote = rs

            var ls: OpaquePointer? = nil
            try check(location_simulation_new(remote, &ls), "建立定位模擬服務")
            locsim = ls
        } catch {
            teardown()
            throw error
        }
        setConnected(true)
    }

    private func setSync(latitude: Double, longitude: Double) throws {
        guard let ls = locsim else { throw LinkError.notConnected }
        do {
            try check(location_simulation_set(ls, latitude, longitude), "送出定位")
        } catch {
            setConnected(false)
            throw error
        }
    }

    private func clearSync() throws {
        guard let ls = locsim else { throw LinkError.notConnected }
        try check(location_simulation_clear(ls), "恢復真實定位")
    }

    /// 釋放順序：定位 → 遠端伺服器 → 握手 → 轉接器
    private func teardown() {
        setConnected(false)
        if let ls = locsim { location_simulation_free(ls); locsim = nil }
        if let rs = remote { remote_server_free(rs); remote = nil }
        if let hs = handshake { rsd_handshake_free(hs); handshake = nil }
        if let ad = adapter { adapter_free(ad); adapter = nil }
    }
}
