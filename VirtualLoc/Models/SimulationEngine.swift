import Foundation
import CoreLocation
import SwiftUI

@MainActor
final class SimulationEngine: ObservableObject {
    enum Connection: Equatable {
        case disconnected
        case connecting
        case connected
        case reconnecting(Int)
    }

    enum Mode { case idle, point, joystick, route }

    // MARK: 狀態
    @Published private(set) var connection: Connection = .disconnected
    @Published private(set) var mode: Mode = .idle
    @Published private(set) var current: Coord?          // 目前送出的模擬位置
    @Published var selected: Coord?                       // 地圖上選取的點
    @Published var message: String = ""                   // 給畫面顯示的最新訊息
    @Published var autoConnect: Bool {
        didSet { UserDefaults.standard.set(autoConnect, forKey: "autoConnect") }
    }

    // 路線
    @Published private(set) var route: [Coord] = []
    @Published private(set) var routeIndex = 0
    @Published private(set) var segProgress = 0.0
    @Published private(set) var routeRunning = false
    @Published private(set) var routePaused = false
    /// 路線開始那一刻的總長度，只用來給浮動視窗算完成度（0...1），不隨路線進行變動。
    private var routeTotalMeters: Double = 0
    enum RouteRepeat: String, CaseIterable {
        case once = "單次", pingPong = "往返", loop = "循環"
    }
    @Published var routeRepeat: RouteRepeat = .once
    var loopRoute: Bool {
        get { routeRepeat == .loop }
        set { routeRepeat = newValue ? .loop : .once }
    }

    // 種花路線：圈數、點間瞬移、停留秒數、圈圈半徑
    @Published var flowerLaps = 2
    @Published var flowerHop = false
    @Published var flowerDwell: Double = 5
    @Published var flowerRadius: Double = 40
    @Published var showCircles = false                    // 地圖上畫出每個路線點的圈圈
    // 花農繞圈：輸入多朵花的座標，繞每朵花走圈，再換下一朵
    @Published private(set) var farmCenters: [Coord] = []
    @Published private(set) var farmRadius: Double = 30
    private var farmStarts: [Int] = []                    // 每朵花在路線中的起點索引
    private var jumpBefore = Set<Int>()                   // 走到這些索引時直接瞬移，不走過去
    private var farmMode = false
    // 跳躍收果：依序跳到每個點、停留指定秒數
    private var hopRoute = false
    private var hopDwells: [Double] = []
    var hopRouteActive: Bool { hopRoute }
    @Published private(set) var lapsDone = 0
    @Published var routeKmh: Double = 5
    @Published var joystickKmh: Double = 8
    @Published var pickOnMap = false                      // 地圖點擊 = 加入路線點

    static let routeLimit = 50_000

    // MARK: 內部
    private let link = DeviceLink()
    private var store: Store?
    private var keepAlive: KeepAlive?
    private var timer: Timer?
    private let tick = 0.5
    private var joystick = CGVector.zero
    private var sending = false
    private var pending: Coord?
    private var lapLimit: Int?                            // 種花路線的圈數上限，nil 代表一般路線
    private var hopping = false
    private var hopElapsed = 0.0
    private var lastSend = Date.distantPast
    /// 上一次依照時速推進路線／搖桿位置的真實時間。用真實經過時間而非固定的 tick
    /// 常數來算距離，時速才不會因為 Timer 抖動或網路延遲而失準（見 onTick 註解）。
    private var lastAdvanceTime = Date()
    private var reconnectTask: Task<Void, Never>?
    private var isSpoofing = false {
        didSet { keepAlive?.isSpoofing = isSpoofing }
    }

    init() {
        autoConnect = UserDefaults.standard.object(forKey: "autoConnect") as? Bool ?? true
        NotificationCenter.default.addObserver(
            forName: .teleoPiPToggle, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.routePaused { self.resumeRoute() } else { self.pauseRoute() }
            }
        }
    }

    func attach(store: Store, keepAlive: KeepAlive) {
        guard self.store == nil else { return }
        self.store = store
        self.keepAlive = keepAlive
        startTimer()
        if autoConnect && PairingStore.exists && connection == .disconnected {
            connect()
        }
    }

    var isConnected: Bool { connection == .connected }

    var connectionText: String {
        switch connection {
        case .disconnected: return "未連線"
        case .connecting: return "連線中…"
        case .connected: return "已連線"
        case .reconnecting(let n): return "重新連線中（第 \(n) 次）"
        }
    }

    // MARK: 連線

    func connect() {
        guard connection == .disconnected else { return }
        guard PairingStore.exists else {
            message = "請先到「設定」匯入配對檔"
            return
        }
        connection = .connecting
        message = "連線中…"
        Task {
            do {
                try await link.connect(pairingPath: PairingStore.fileURL.path)
                connection = .connected
                message = "已連線"
                AppLog.shared.add("連線成功")
                if let c = current { send(c) }
            } catch {
                connection = .disconnected
                message = error.localizedDescription
                AppLog.shared.add("連線失敗：\(error.localizedDescription)")
            }
        }
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        routeRunning = false
        routePaused = false
        joystick = .zero
        mode = .idle
        current = nil
        isSpoofing = false
        connection = .disconnected
        message = "已中斷連線（系統定位已恢復）"
        Task { await link.disconnect() }
    }

    // MARK: 單點定位

    func goTo(_ c: Coord) {
        guard Geo.isValid(c) else { message = "座標超出範圍"; return }
        guard requireConnection() else { return }
        if routeRunning { routePaused = true }          // 路線中切換單點：保留進度
        joystick = .zero
        mode = .point
        isSpoofing = true
        send(c)
        store?.record(point: c)
        message = "已定位到 \(Geo.format(c))"
    }

    func restoreRealGPS() {
        lapLimit = nil
        hopping = false
        routeRunning = false
        routePaused = false
        routeIndex = 0
        segProgress = 0
        joystick = .zero
        mode = .idle
        current = nil
        pending = nil
        isSpoofing = false
        message = "已恢復真實定位"
        guard connection == .connected else { return }
        Task {
            do { try await link.clear() }
            catch { AppLog.shared.add("恢復定位失敗：\(error.localizedDescription)") }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            keepAlive?.refreshOriginal()
        }
    }

    // MARK: 搖桿

    func setJoystick(_ v: CGVector) {
        if v == .zero {
            if mode == .joystick {
                mode = .point
                if !routeRunning { PiPOverlay.shared.stop() }
            }
            joystick = .zero
            return
        }
        guard requireConnection() else { return }
        if mode != .joystick {
            guard current != nil || selected != nil || keepAlive?.original != nil else {
                message = "請先在地圖選一個起點，再使用搖桿"
                return
            }
            if routeRunning { routePaused = true }
            if current == nil {
                let start = selected ?? keepAlive?.original
                if let start = start { send(start) }
            }
            mode = .joystick
            isSpoofing = true
            lastAdvanceTime = Date()
            PiPOverlay.shared.start()
        }
        joystick = v
    }

    // MARK: 路線載入與編輯

    func setRoute(_ pts: [Coord]) {
        stopRoute()
        invalidateFarm()
        route = Array(pts.prefix(SimulationEngine.routeLimit))
        if pts.count > SimulationEngine.routeLimit {
            message = "路線最多 \(SimulationEngine.routeLimit) 點，已截斷"
        } else {
            message = "已載入 \(route.count) 個路線點"
        }
    }

    func loadRouteText(_ text: String, sortShortest: Bool) -> Int {
        var pts = Geo.parseList(text)
        if sortShortest && pts.count >= 3 && pts.count <= 5000 { pts = Geo.shortestOrder(pts) }
        setRoute(pts)
        return pts.count
    }

    func loadGPX(data: Data) -> Int {
        let pts = GPXParser.parse(data: data).map { $0.coordinate }
        setRoute(pts)
        return pts.count
    }

    // MARK: 花農繞圈

    /// 依序繞每朵花走 circleLaps 圈，再換下一朵花。
    /// 每個圓的入口朝向上一朵花、出口朝向下一朵花，讓花與花之間的路最短。
    /// jump = true：花與花之間直接瞬移，不走過去。
    @discardableResult
    func buildFarmRoute(flowers: [Coord], radius: Double, circleLaps: Int,
                        pointsPerCircle: Int, jump: Bool) -> Int {
        stopRoute()
        invalidateFarm()
        guard !flowers.isEmpty else { route = []; return 0 }

        let n = min(72, max(4, pointsPerCircle))
        let laps = min(20, max(1, circleLaps))
        let r = min(5000, max(1, radius))
        let twoPi = 2 * Double.pi
        var pts: [Coord] = []
        var starts: [Int] = []
        var jumps = Set<Int>()

        func heading(from c: Coord, to p: Coord, dLat: Double, dLon: Double) -> Double {
            atan2((p.latitude - c.latitude) / dLat, (p.longitude - c.longitude) / dLon)
        }

        for (i, c) in flowers.enumerated() {
            let dLat = r / 111_320.0
            let dLon = r / (111_320.0 * max(cos(c.latitude * .pi / 180), 0.01))
            let prev: Coord? = i > 0 ? flowers[i - 1] : nil
            let next: Coord? = i + 1 < flowers.count ? flowers[i + 1] : nil
            let entry: Double = prev.map { heading(from: c, to: $0, dLat: dLat, dLon: dLon) }
                ?? next.map { heading(from: c, to: $0, dLat: dLat, dLon: dLon) } ?? 0
            let exit: Double = next.map { heading(from: c, to: $0, dLat: dLat, dLon: dLon) } ?? entry
            var extra = (exit - entry).truncatingRemainder(dividingBy: twoPi)
            if extra < 0 { extra += twoPi }
            let sweep = twoPi * Double(laps) + extra
            let steps = max(1, Int((sweep / (twoPi / Double(n))).rounded(.up)))

            starts.append(pts.count)
            if i > 0 && jump { jumps.insert(pts.count) }
            for k in 0...steps {
                let a = entry + sweep * Double(k) / Double(steps)
                pts.append(Coord(latitude: c.latitude + dLat * sin(a),
                                 longitude: c.longitude + dLon * cos(a)))
            }
            if pts.count >= SimulationEngine.routeLimit { break }
        }
        if jump && flowers.count > 1 { jumps.insert(0) }          // 下一輪從第一朵花重新開始

        route = Array(pts.prefix(SimulationEngine.routeLimit))
        farmCenters = Array(flowers.prefix(starts.count))
        farmStarts = starts
        jumpBefore = jumps.filter { $0 < route.count }
        farmRadius = r
        farmMode = true
        message = "已產生花農路線：\(farmCenters.count) 朵花、每朵 \(laps) 圈、半徑 \(Int(r)) 公尺"
        return farmCenters.count
    }

    // MARK: 跳躍收果

    /// 依序跳到每個點並停留：dwells 為各點專屬秒數（nil 用 defaultDwell）。
    @discardableResult
    func buildHopRoute(points: [Coord], dwells: [Double?], defaultDwell: Double) -> Int {
        stopRoute()
        invalidateFarm()
        route = Array(points.prefix(SimulationEngine.routeLimit))
        hopDwells = route.indices.map { i in
            let d = i < dwells.count ? dwells[i] : nil
            return max(1, d ?? defaultDwell)
        }
        flowerDwell = defaultDwell
        hopRoute = true
        message = "已產生跳躍路線：\(route.count) 個點"
        return route.count
    }

    private func hopDwell(at index: Int) -> Double {
        hopRoute && index < hopDwells.count ? hopDwells[index] : flowerDwell
    }

    /// 跳躍收果進行中的進度，例如「第 3 / 12 點 · 停留 8 秒」
    var hopProgressText: String? {
        guard hopRoute, routeRunning, routeIndex < route.count else { return nil }
        let left = max(0, Int(hopDwell(at: routeIndex) - hopElapsed))
        return "第 \(routeIndex + 1) / \(route.count) 點 · 剩 \(left) 秒換下一點"
    }

    /// 花農路線進行中的進度，例如「第 3 / 10 朵花」
    var farmProgressText: String? {
        guard farmMode, routeRunning, !farmStarts.isEmpty else { return nil }
        let idx = farmStarts.lastIndex(where: { $0 <= routeIndex }) ?? 0
        return "第 \(idx + 1) / \(farmStarts.count) 朵花"
    }

    private func invalidateFarm() {
        hopRoute = false
        hopDwells = []
        farmCenters = []
        farmStarts = []
        jumpBefore = []
        farmMode = false
    }

    private func segmentLength(_ i: Int) -> Double {
        let j = (i + 1) % route.count
        return jumpBefore.contains(j) ? 0 : Geo.distance(route[i], route[j])
    }

    func addRoutePoint(_ c: Coord) {
        guard !routeRunning, route.count < SimulationEngine.routeLimit else { return }
        invalidateFarm()
        route.append(c)
    }

    func removeLastRoutePoint() {
        guard !routeRunning, !route.isEmpty else { return }
        invalidateFarm()
        route.removeLast()
    }

    func clearRoute() {
        stopRoute()
        invalidateFarm()
        route = []
    }

    func sortRouteShortest() {
        guard !routeRunning else { message = "路線執行中不能排序"; return }
        guard route.count >= 3, route.count <= 5000 else { message = "需 3～5000 點"; return }
        let before = Geo.pathLength(route)
        invalidateFarm()
        route = Geo.shortestOrder(route)
        message = "已排序：\(before.distanceText) → \(Geo.pathLength(route).distanceText)"
    }

    func reverseRoute() {
        guard !routeRunning else { return }
        invalidateFarm()
        route.reverse()
    }

    // MARK: 路線控制

    func startRoute(from index: Int = 0, laps: Int? = nil) {
        guard route.count > 1 else { message = "路線至少需要 2 個點"; return }
        guard requireConnection() else { return }
        joystick = .zero
        routeIndex = min(max(0, index), route.count - 1)
        segProgress = 0
        lapLimit = laps
        lapsDone = 0
        hopElapsed = 0
        routeTotalMeters = Geo.pathLength(route)
        hopping = laps != nil && ((flowerHop && !farmMode) || hopRoute)
        routeRunning = true
        routePaused = false
        mode = .route
        isSpoofing = true
        lastAdvanceTime = Date()
        send(route[routeIndex])
        store?.record(route: route)
        message = "路線開始"
        PiPOverlay.shared.start()
        updatePiPOverlay()
    }

    func pauseRoute() {
        guard routeRunning else { return }
        routePaused = true
        message = "路線已暫停"
        updatePiPOverlay()
    }

    /// 繼續路線：先回到暫停點再接著走
    func resumeRoute() {
        guard routeRunning, routePaused else { return }
        guard requireConnection() else { return }
        joystick = .zero
        mode = .route
        routePaused = false
        lastAdvanceTime = Date()
        send(routeCoordinate())
        message = "路線繼續"
        updatePiPOverlay()
    }

    func stopRoute() {
        lapLimit = nil
        hopping = false
        routeRunning = false
        routePaused = false
        routeIndex = 0
        segProgress = 0
        if mode == .route { mode = isSpoofing ? .point : .idle }
        PiPOverlay.shared.stop()
    }

    /// 更新浮動子母畫面視窗裡顯示的進度文字，路線跟搖桿模式都會呼叫，
    /// 時速會放在最前面，跟著 routeKmh／joystickKmh 即時變化。
    ///
    /// 這裡同時負責「補開」浮動視窗：如果路線／搖桿已經在跑，但浮動視窗還沒浮出來
    /// （例如使用者是在路線開始「之後」才去設定頁把開關打開，或是子母畫面上一次
    /// 嘗試失敗了），每次 tick 呼叫 updatePiPOverlay() 時都會順便再呼叫一次
    /// PiPOverlay.shared.start()。start() 內部已經檢查「已經在顯示就不重做」，
    /// 所以這裡重複呼叫沒有副作用，純粹是為了讓它能補救，不用等下一次路線開始／
    /// 繼續才生效。
    private func updatePiPOverlay() {
        PiPOverlay.shared.start()
        if mode == .joystick {
            guard joystick != .zero else { return }
            PiPOverlay.shared.update(
                title: "搖桿中 · Teleo",
                subtitle: "持續送出定位",
                speedText: joystickKmh.kmhText,
                isPaused: false,
                progress: nil)
            return
        }
        guard routeRunning else { return }
        let title = routePaused ? "已暫停 · Teleo" : "進行中 · Teleo"
        var parts = ["第 \(routeIndex + 1) / \(route.count) 點"]
        if let farmText = farmProgressText { parts.append(farmText) }
        if let hopText = hopProgressText { parts.append(hopText) }
        if let laps = lapsTotalText { parts.append(laps) }
        if !routePaused {
            parts.append("剩 \(remainingMeters.distanceText) · 約 \(remainingSeconds.durationText)")
        }
        let progress: Double? = routeTotalMeters > 0
            ? min(1, max(0, 1 - remainingMeters / routeTotalMeters))
            : nil
        PiPOverlay.shared.update(
            title: title,
            subtitle: parts.joined(separator: " · "),
            speedText: routeKmh.kmhText,
            isPaused: routePaused,
            progress: progress)
    }

    func nextPoint() {
        guard routeRunning else { return }
        routeIndex = min(route.count - 1, routeIndex + 1)
        segProgress = 0
        send(route[routeIndex])
    }

    func previousPoint() {
        guard routeRunning else { return }
        if segProgress > 0 { segProgress = 0 } else { routeIndex = max(0, routeIndex - 1) }
        send(route[routeIndex])
    }

    var remainingMeters: Double {
        guard route.count > 1, routeRunning else { return Geo.pathLength(route) }
        let segs = wrapsAround ? route.count : route.count - 1
        guard routeIndex < segs else { return 0 }
        var sum = segmentLength(routeIndex) * (1 - segProgress)
        var i = routeIndex + 1
        while i < segs {
            sum += segmentLength(i)
            i += 1
        }
        return sum
    }

    var remainingSeconds: Double {
        routeKmh > 0 ? remainingMeters / (routeKmh / 3.6) : .infinity
    }

    // MARK: 計時器

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: tick, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onTick() }
        }
    }

    private func onTick() {
        guard connection == .connected else { return }
        let now = Date()

        // 時速準不準，關鍵不是「算距離的公式」，而是「送到裝置的那一刻，距離有沒有算到那一刻」。
        //
        // 原本每個 tick（固定 0.5 秒）都會算一次距離、呼叫一次 send()；但送一次定位要等裝置回應，
        // 碰到網路延遲、送不完的時候，send() 會把來不及送的中間點直接丟掉、只留最新的一個（見
        // send() 的 pending 機制）。問題是：lastAdvanceTime 當時仍然每 0.5 秒照樣往前推進，
        // 所以「被丟掉那個點」裡算進去的距離，跟「真正送出去那一刻」之間，其實還多經過了一段
        // 排隊等待的時間沒被算進去——等於偷偷漏算了一段距離。遊戲端拿「收到的距離」除以「收到
        // 的時間間隔」反推時速，算出來就會比設定的慢，而且網路忽快忽慢時還會忽快忽慢。
        //
        // 修法：只有在「上一次送出已經完成」（!sending）時才去算距離、呼叫 send()；
        // 還在等裝置回應的那幾個 tick 就先跳過，不去動 lastAdvanceTime。這樣不管中間
        // 卡了幾個 tick 沒送，下一次真正要送的時候，用的 dt 永遠等於「上一次真正送出」
        // 到「這一次真正送出」之間，裝置實際收到兩個點的真實時間差，距離／時間的比例
        // 才會跟設定的時速完全對得起來，不會被網路延遲偷走一段。
        //
        // 跳躍收果（hopTick）不是連續移動、沒有「時速」這回事，只是單純倒數停留秒數，
        // 所以它的倒數改用真實經過時間計算（不再用固定 tick 常數），但不受 !sending 影響——
        // 停留時間準不準跟「有沒有送成功上一個點」是兩件事，不應該卡在一起。
        switch mode {
        case .route:
            if routeRunning && !routePaused {
                if hopping {
                    let dt = now.timeIntervalSince(lastAdvanceTime)
                    lastAdvanceTime = now
                    hopTick(dt: dt)
                } else if !sending {
                    let dt = min(now.timeIntervalSince(lastAdvanceTime), tick * 8)
                    lastAdvanceTime = now
                    advanceRoute(meters: routeKmh / 3.6 * dt)
                }
                updatePiPOverlay()
            }
        case .joystick:
            if joystick != .zero, !sending {
                let dt = min(now.timeIntervalSince(lastAdvanceTime), tick * 8)
                lastAdvanceTime = now
                moveByJoystick(meters: joystickKmh / 3.6 * dt)
                updatePiPOverlay()
            }
        default:
            break
        }
        // 心跳：每 4 秒重送一次，維持模擬位置
        if isSpoofing, !sending, let c = current, now.timeIntervalSince(lastSend) >= 4 {
            send(c)
        }
    }

    private func routeCoordinate() -> Coord {
        guard route.count > 1 else { return route.first ?? Coord(latitude: 0, longitude: 0) }
        let a = route[routeIndex]
        let b = route[(routeIndex + 1) % route.count]
        return Geo.lerp(a, b, segProgress)
    }

    private func advanceRoute(meters: Double) {
        var remaining = meters
        let segs = wrapsAround ? route.count : route.count - 1
        var guardCount = 0
        while remaining > 0 && guardCount < 10_000 {
            guardCount += 1
            if routeIndex >= segs {
                if reachedEnd() { routeFinished(); return }
                continue
            }
            if jumpBefore.contains((routeIndex + 1) % route.count) {      // 花與花之間：直接瞬移
                routeIndex += 1
                segProgress = 0
                if routeIndex >= segs, reachedEnd() { routeFinished(); return }
                continue
            }
            let a = route[routeIndex]
            let b = route[(routeIndex + 1) % route.count]
            let len = Geo.distance(a, b)
            if len < 0.01 {
                routeIndex += 1
                segProgress = 0
                continue
            }
            let left = len * (1 - segProgress)
            if remaining >= left {
                remaining -= left
                routeIndex += 1
                segProgress = 0
                if routeIndex >= segs {
                    if reachedEnd() { routeFinished(); return }
                }
            } else {
                segProgress += remaining / len
                remaining = 0
            }
        }
        send(routeCoordinate())
    }

    private var wrapsAround: Bool { loopRoute || lapLimit != nil }

    /// 種花路線進行中的圈數顯示，例如「第 1 / 2 輪」
    var lapsTotalText: String? {
        guard let limit = lapLimit else { return nil }
        return "第 \(min(lapsDone + 1, limit)) / \(limit) 輪"
    }

    /// 走到終點時呼叫：回傳 true 代表整趟結束
    private func reachedEnd() -> Bool {
        if let limit = lapLimit {
            lapsDone += 1
            if lapsDone >= limit { return true }
            routeIndex = 0
            segProgress = 0
            return false
        }
        switch routeRepeat {
        case .once:
            return true
        case .loop:
            routeIndex = 0
            segProgress = 0
            return false
        case .pingPong:
            route.reverse()
            routeIndex = 0
            segProgress = 0
            return false
        }
    }

    /// 種花「點間瞬移」：每隔停留秒數跳到下一個點。用真實經過時間（dt）累計，
    /// 不用固定的 tick 常數，才不會因為 Timer 抖動讓停留時間偏長或偏短。
    private func hopTick(dt: Double) {
        hopElapsed += dt
        guard hopElapsed >= max(1, hopDwell(at: routeIndex)) else { return }
        hopElapsed = 0
        routeIndex += 1
        if routeIndex >= route.count {
            lapsDone += 1
            if let limit = lapLimit, lapsDone >= limit { routeFinished(); return }
            routeIndex = 0
        }
        send(route[routeIndex])
    }

    private func routeFinished() {
        lapLimit = nil
        hopping = false
        if let last = route.last { send(last) }
        routeRunning = false
        routePaused = false
        routeIndex = 0
        segProgress = 0
        mode = .point
        message = "路線完成，停在終點"
    }

    private func moveByJoystick(meters: Double) {
        guard let cur = current else { return }
        let mag = min(1, hypot(Double(joystick.dx), Double(joystick.dy)))
        guard mag > 0.001 else { return }
        let dist = meters * mag
        let north = Double(joystick.dy) / hypot(Double(joystick.dx), Double(joystick.dy)) * dist
        let east = Double(joystick.dx) / hypot(Double(joystick.dx), Double(joystick.dy)) * dist
        let lat = min(89.999, max(-89.999, cur.latitude + north / 111_320.0))
        let lonScale = 111_320.0 * max(cos(cur.latitude * .pi / 180), 0.01)
        let lon = Geo.wrapLongitude(cur.longitude + east / lonScale)
        send(Coord(latitude: lat, longitude: lon))
    }

    // MARK: 送出與重連

    private func requireConnection() -> Bool {
        switch connection {
        case .connected:
            return true
        case .disconnected:
            message = "尚未連線，請到「設定」連線"
            return false
        case .connecting:
            message = "連線中，請稍候"
            return false
        case .reconnecting:
            message = "正在重新連線，請稍候"
            return false
        }
    }

    private func send(_ c: Coord) {
        current = c
        guard connection == .connected else { return }
        if sending { pending = c; return }
        sending = true
        lastSend = Date()
        Task {
            do {
                try await link.set(latitude: c.latitude, longitude: c.longitude)
                sending = false
                if let p = pending {
                    pending = nil
                    send(p)
                }
            } catch {
                sending = false
                pending = nil
                handleFailure(error)
            }
        }
    }

    private func handleFailure(_ error: Error) {
        AppLog.shared.add("送出定位失敗：\(error.localizedDescription)（模式 \(mode)，路線 \(routeIndex)/\(route.count)）")
        message = "連線中斷，嘗試自動重連（路線進度已保留）"
        startReconnect()
    }

    /// 斷線後在背景重試，最多 10 分鐘；成功後回到最後位置接著走
    private func startReconnect() {
        guard reconnectTask == nil, connection != .disconnected else { return }
        connection = .reconnecting(0)
        reconnectTask = Task { [weak self] in
            let began = Date()
            var attempt = 0
            var delay = 1.0
            while !Task.isCancelled {
                guard let self = self else { return }
                if Date().timeIntervalSince(began) > 600 {
                    self.connection = .disconnected
                    self.reconnectTask = nil
                    self.message = "重新連線逾時，請手動連線"
                    AppLog.shared.add("重新連線逾時（10 分鐘）")
                    return
                }
                attempt += 1
                self.connection = .reconnecting(attempt)
                do {
                    try await self.link.connect(pairingPath: PairingStore.fileURL.path)
                    self.connection = .connected
                    self.reconnectTask = nil
                    self.message = "已重新連線"
                    AppLog.shared.add("重新連線成功（第 \(attempt) 次）")
                    if let c = self.current { self.send(c) }
                    return
                } catch {
                    AppLog.shared.add("重新連線第 \(attempt) 次失敗：\(error.localizedDescription)")
                }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                delay = min(delay * 2, 30)
            }
        }
    }
}
