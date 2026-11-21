import AVKit
import AVFoundation
import SwiftUI
import UIKit
import Combine
import CoreMedia
import CoreVideo

extension Notification.Name {
    /// 浮動視窗上的暫停／繼續被按下
    static let teleoPiPToggle = Notification.Name("teleoPiPToggle")
    /// 浮動視窗上的「下一點」被按下（跳躍拉金盆用）
    static let teleoPiPNext = Notification.Name("teleoPiPNext")
    /// 浮動視窗上的「上一點」被按下（跳躍拉金盆用）
    static let teleoPiPPrev = Notification.Name("teleoPiPPrev")
}

/// 讓路線進度能用「子母畫面（Picture in Picture）」的方式浮在其他 App 最上面，
/// 離開 Teleo（例如切回 Pikmin Bloom）時還能看到走到第幾點、剩多久。
///
/// === 這一版改了什麼、為什麼 ===
/// 第一版、第二版都是用 AVKit 給「視訊通話」App 用的子母畫面
/// （`AVPictureInPictureVideoCallViewController` + 自己畫的 SwiftUI／UIButton
/// 按鈕疊在上面）。這條路有個我們一直沒抓到的根本問題：視訊通話樣式的子母畫面，
/// 在真的「浮在別的 App 上面」（不是停留在自己 App 裡）的狀態下，整塊浮動視窗
/// 的觸控是系統保留給「點一下恢復 App」這個手勢用的，不管裡面是 SwiftUI 按鈕
/// 還是原生 UIButton，自己畫的子視圖都收不到點擊——這也是為什麼兩次修法實機
/// 測試起來都一樣，一按就跳回 Teleo。
///
/// 真正能在浮在其他 App 時還正常運作的按鈕，是「播放樣式」子母畫面
/// （一般影片／Podcast App 用的那種）內建的播放控制列：暫停/繼續、
/// 快轉、倒轉這幾顆按鈕是系統自己畫、自己接住點擊的，不是我們的 View
/// 階層收到的，所以不會被「恢復 App」手勢搶走。這才是其他 App（包含你
/// 影片裡那個）做得到的真正原因。
///
/// 做法：不再用 `AVPictureInPictureVideoCallViewController`，改用
/// `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`
/// 這種「播放樣式」子母畫面。我們沒有真的影片，所以把目前要顯示的狀態
/// （圖示、標題、進度條、時速——用原本那份 `PiPOverlayWidgetView` 畫面）
/// 用 `ImageRenderer` 定期拍成一張圖，包成一格「影片畫面」塞進
/// `AVSampleBufferDisplayLayer`，系統就會把它當成影片內容顯示，並在
/// 使用者點一下時自動疊出播放控制列。使用者按下控制列時，系統會呼叫
/// `PiPPlaybackDelegate` 的方法，我們在裡面轉發成跟以前一樣的
/// `NotificationCenter` 通知，`SimulationEngine` 完全不用改。
///
/// 只有「跳躍拉金盆」（`showStepControls == true`）才需要上一點／下一點，
/// 這裡用 `requiresLinearPlayback` 控制：設 `false` 才會出現快轉／倒轉，
/// 設 `true`（一般路線／跳躍收果）就只剩暫停／繼續，很像直播節目的子母畫面。
///
/// 限制／風險：
/// - 這招一樣不是官方保證給「非影片」App 用的正式用法，只是借用播放樣式子母畫面
///   的介面；如果之後系統行為改變，仍有可能需要再調整。
/// - 子母畫面能不能被使用者拖動、縮放，由系統控制，App 自己不能決定位置。
/// - 如果系統環境不支援（例如低電量模式、裝置設定限制），子母畫面可能根本開不起來；
///   這種情況下 App 其他功能完全不受影響，只是看不到那條浮動列。
@MainActor
final class PiPOverlay: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPOverlay()

    @Published var isActive = false
    @Published var title = "Teleo"
    @Published var subtitle = ""
    @Published var speedText = ""
    @Published var isPaused = false {
        didSet {
            playbackDelegate.isPaused = isPaused
            // 暫停時把 timebase 的速率釘成 0，子母畫面的進度列才會跟著凍結在
            // 目前位置，而不是視覺上停了、但系統內部的「目前時間」還在往前跑。
            if let controlTimebase {
                CMTimebaseSetRate(controlTimebase, rate: isPaused ? 0 : 1)
            }
        }
    }
    /// 路線完成度 0...1；搖桿模式或沒有固定路線時是 nil，不顯示進度條。
    @Published var progress: Double?
    /// 跳躍拉金盆才會是 true：true 時系統子母畫面才會出現「上一點／下一點」。
    @Published var showStepControls = false

    /// 使用者是否想要這個功能（設定頁開關），預設關閉，因為會持續耗一點電。
    @AppStorage("pipOverlayEnabled") var enabled = false

    private var pip: AVPictureInPictureController?
    private let displayLayer = AVSampleBufferDisplayLayer()
    private let playbackDelegate = PiPPlaybackDelegate()
    private var sourceView: UIView?
    private var silentPlayer: AVAudioPlayer?
    private var pixelBufferPool: CVPixelBufferPool?
    /// 定期重新送一張畫面進子母畫面，不管內容有沒有變。反組譯同類型的真實 App
    /// （用一模一樣的 AVSampleBufferDisplayLayer + 播放樣式子母畫面做法）發現它們
    /// 也有一個固定頻率的 refresh timer；我們原本只有在 `update()` 被呼叫時才
    /// 送畫面，太久沒送新的一幀，系統大概率會判斷「播放卡住了」，於是系統自己的
    /// 控制列卡在展開狀態收不回去——這才是浮動視窗「整個癱瘓」的真正原因。
    private var refreshTimer: Timer?
    /// 每一幀的時間戳不能直接拿「開機到現在」的絕對時間——那會是幾萬秒起跳，
    /// 跟我們跟系統宣告的「這是一段 0～3600 秒的影片」(`pictureInPictureControllerTimeRangeForPlayback`)
    /// 完全對不上。子母畫面的快轉／倒轉鍵能不能按、按下去要跳到哪，是系統拿
    /// 「目前播放時間」對著這段宣告的時間範圍去算的；時間戳基準不對，倒轉鍵
    /// 判斷永遠在邊界（所以按不下去），快轉鍵狀態也會算錯（按了系統內部覺得
    /// 沒有變化，所以看起來「沒反應」）。這裡自己建一個獨立的 CMTimebase，
    /// 從 0 秒開始算，每一幀都拿這個 timebase「現在」的時間當時間戳，確保跟
    /// 宣告的時間範圍是同一套座標。
    private var controlTimebase: CMTimebase?

    private let renderSize = CGSize(width: 340, height: 84)
    private let refreshInterval: TimeInterval = 1.0

    private override init() {
        super.init()
        playbackDelegate.onToggle = { [weak self] in
            NotificationCenter.default.post(name: .teleoPiPToggle, object: nil)
            Task { @MainActor in self?.isPaused.toggle() }
        }
        playbackDelegate.onSkip = { goBack in
            NotificationCenter.default.post(name: goBack ? .teleoPiPPrev : .teleoPiPNext, object: nil)
        }
    }

    /// 在 App 啟動時呼叫一次，準備好（但不會立刻顯示）子母畫面。
    func prepare() {
        guard enabled, pip == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        // 「播放樣式」子母畫面一樣要求 displayLayer 真的掛在畫面的 view 階層裡，
        // 系統才知道這塊畫面在螢幕上的哪個位置、該從哪裡浮出來。
        let view = UIView(frame: CGRect(origin: .zero, size: renderSize))
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        displayLayer.frame = view.bounds
        displayLayer.videoGravity = .resizeAspect
        displayLayer.controlTimebase = PiPOverlay.makeControlTimebase()
        self.controlTimebase = displayLayer.controlTimebase
        view.layer.addSublayer(displayLayer)
        self.sourceView = view
        attachSourceViewIfNeeded(view)

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: displayLayer, playbackDelegate: playbackDelegate)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.requiresLinearPlayback = !showStepControls
        self.pip = controller

        renderFrame()
    }

    /// 把 sourceView 掛到目前最上層的視窗上（alpha 很低、不接受互動，幾乎看不見），
    /// 子母畫面才找得到它該浮在哪個位置。如果呼叫當下視窗還沒準備好就先放棄，
    /// 下次呼叫 start() 時會再試一次，不會卡住。
    private func attachSourceViewIfNeeded(_ view: UIView) {
        guard view.superview == nil else { return }
        guard let window = UIApplication.shared.connectedScenes
            .compactMap({ ($0 as? UIWindowScene)?.windows.first(where: { $0.isKeyWindow }) })
            .first else { return }
        window.addSubview(view)
    }

    /// 開始浮動（通常在路線開始跑、或 App 要切到背景時呼叫）。
    func start() {
        guard enabled else { return }
        prepare()
        if let sourceView { attachSourceViewIfNeeded(sourceView) }
        guard let pip, !pip.isPictureInPictureActive else { return }
        startSilentAudio()
        pip.startPictureInPicture()
        startRefreshTimer()
    }

    func stop() {
        pip?.stopPictureInPicture()
        stopSilentAudio()
        stopRefreshTimer()
    }

    /// 固定頻率重畫、重送一幀，讓系統一直覺得「畫面持續在播」，不會卡在
    /// 控制列展開的狀態。即使內容完全沒變，也要送，這點是刻意的。
    private func startRefreshTimer() {
        stopRefreshTimer()
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.renderFrame() }
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer
    }

    private func stopRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    /// 更新浮動列顯示的文字內容。
    /// - speedText：目前時速，放大顯示在最醒目的位置。
    /// - progress：路線完成度 0...1，傳 nil 就不顯示進度條（例如搖桿模式）。
    /// - showStepControls：是否要出現「上一點／下一點」（跳躍拉金盆才需要）；
    ///   這裡會連動 `requiresLinearPlayback`，決定系統要不要畫快轉／倒轉按鈕。
    func update(title: String, subtitle: String, speedText: String, isPaused: Bool,
                progress: Double? = nil, showStepControls: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.speedText = speedText
        self.isPaused = isPaused
        self.progress = progress
        self.showStepControls = showStepControls
        pip?.requiresLinearPlayback = !showStepControls
        renderFrame()
        // 使用者在路線跑的途中，到設定頁把開關關掉的話，這裡會順便把正在顯示的浮動視窗收起來，
        // 不用等下一次路線開始/結束才生效。
        if !enabled, pip?.isPictureInPictureActive == true { stop() }
    }

    // MARK: 把目前狀態畫成一張圖，當作子母畫面的「影片畫面」餵進去

    /// 直接用 Core Graphics／UIKit 的 `draw(in:)` 把目前狀態畫進 pixel buffer，
    /// 不再經過 SwiftUI 的 `ImageRenderer`。反組譯參考的真實 App（跟我們用
    /// 同一套子母畫面技術）就是這樣做的：字型、顏色、段落樣式都只建立一次、
    /// 靜態快取起來（見 `PiPFrameStyle`），不是每一幀都重新跑一次 SwiftUI 的
    /// 版面計算，這樣持續每秒畫一次才不容易卡頓、比較省電。
    private func renderFrame() {
        rebaseControlTimebaseIfNeeded()
        guard let pixelBuffer = acquirePixelBuffer() else { return }
        draw(into: pixelBuffer)
        guard let sampleBuffer = makeSampleBuffer(from: pixelBuffer, duration: refreshInterval) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }

    /// 浮動視窗可能一開就是幾十分鐘（路線很長、或搖桿長時間搖著），但我們跟
    /// 系統宣告的是「這是一段 1 小時（3600 秒）長的影片」。快接近那個 1 小時
    /// 上限時，把 timebase 的時間撥回去一點、留出空間，不然繼續往前只會
    /// 超出宣告的範圍，快轉鍵之後又會開始判斷錯亂（跟最初那個 bug一樣）。
    /// 使用者不會感覺到這個動作（進度列極少數情況下可能輕微跳一下），換來的是
    /// 長時間使用時快轉／倒轉鍵持續正常可按。
    private func rebaseControlTimebaseIfNeeded() {
        guard let controlTimebase else { return }
        let elapsed = CMTimeGetSeconds(CMTimebaseGetTime(controlTimebase))
        guard elapsed >= 3000 else { return }
        CMTimebaseSetTime(controlTimebase, time: CMTime(seconds: 60, preferredTimescale: 600))
    }

    /// 建一個獨立、從 0 秒開始算的 CMTimebase，給 displayLayer 當作
    /// `controlTimebase`，往後每一幀的時間戳都從這裡拿「現在幾秒」，
    /// 跟宣告的 `pictureInPictureControllerTimeRangeForPlayback`（0～3600 秒）
    /// 用同一套座標。理由見 `controlTimebase` 屬性上的註解。
    private static func makeControlTimebase() -> CMTimebase? {
        var timebase: CMTimebase?
        CMTimebaseCreateWithSourceClock(
            allocator: kCFAllocatorDefault,
            sourceClock: CMClockGetHostTimeClock(),
            timebaseOut: &timebase)
        guard let timebase else { return nil }
        CMTimebaseSetTime(timebase, time: .zero)
        CMTimebaseSetRate(timebase, rate: 1.0)
        return timebase
    }

    /// 用一個固定大小的 pool 重複借用 pixel buffer，不要每一幀都重新配置記憶體——
    /// 反組譯參考的 App 也是這樣做，持續每秒送幀時比較不會造成記憶體壓力/掉幀。
    private func pixelBufferPool(width: Int, height: Int) -> CVPixelBufferPool? {
        if let pixelBufferPool { return pixelBufferPool }
        let pixelAttrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
        ]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, pixelAttrs as CFDictionary, &pool)
        pixelBufferPool = pool
        return pool
    }

    private func acquirePixelBuffer() -> CVPixelBuffer? {
        let scale = UIScreen.main.scale
        let width = Int(renderSize.width * scale)
        let height = Int(renderSize.height * scale)
        guard let pool = pixelBufferPool(width: width, height: height) else { return nil }
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        return buffer
    }

    /// 把目前的畫面內容直接畫進 pixel buffer 的 CGContext，座標用「點」為單位
    /// （跟 renderSize 一樣），先把 context 依螢幕倍率放大，畫起來才不用自己
    /// 到處乘 scale。
    ///
    /// 這裡漏掉的一步、也是之前浮動視窗「整塊黑底看不到字」的真正原因：
    /// `CGBitmapContext` 原生座標系是「左下角為原點、y 往上」，但
    /// `NSAttributedString.draw`／`UIBezierPath`／`UIImage.draw` 這些 UIKit
    /// 畫法都假設「左上角為原點、y 往下」，兩邊對不起來。之前只有
    /// `scaleBy(scale, scale)`，完全沒處理這個上下顛倒的問題，所以背景那片
    /// 滿版漸層看起來沒事（本來就對稱、翻不翻都一樣），但圖示、文字、進度條
    /// 這些照「左上角原點」算出來的位置跟形狀，實際畫出來的時候整個上下顛倒、
    /// 位置也對不上，疊在一起幾乎等於什麼都看不到。反組譯真實 App 的
    /// `render()`，看到它在 `UIGraphicsPushContext` 之前多做了
    /// `CGContextTranslateCTM` 再 `CGContextScaleCTM`——這正是標準的「把
    /// CGBitmapContext 轉成 UIKit 座標系」寫法：先把原點平移到左上角高度，
    /// 再把 y 方向乘上負值翻過來（順便套用螢幕倍率）。補上這兩行就是這次的修法。
    private func draw(into pixelBuffer: CVPixelBuffer) {
        let scale = UIScreen.main.scale
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(pixelBuffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
            space: PiPFrameStyle.colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        // 翻轉成「左上角原點、y 往下」的 UIKit 座標系，同時套用螢幕倍率，
        // 畫的時候才能直接用 renderSize 這種「點」為單位的座標，不用自己換算。
        context.translateBy(x: 0, y: renderSize.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        PiPFrameStyle.draw(overlay: self, in: CGRect(origin: .zero, size: renderSize))
        UIGraphicsPopContext()
    }

    /// duration 給實際的畫面間隔（不是 `.invalid`），讓系統知道這是持續在播放的
    /// 內容、下一幀大概什麼時候會來，而不是一張「播完就沒了」的單張畫面。
    ///
    /// presentationTimeStamp 改拿 `controlTimebase`「現在」的時間（從 0 秒起算），
    /// 不能用 `CMClockGetTime(CMClockGetHostTimeClock())`——那是裝置開機到現在的
    /// 絕對時間，通常是幾萬秒起跳，跟我們宣告的「0～3600 秒影片」完全對不上，
    /// 這正是快轉／倒轉按鈕判斷錯亂（倒轉永遠灰掉、快轉按了沒反應）的根本原因。
    private func makeSampleBuffer(from pixelBuffer: CVPixelBuffer, duration: TimeInterval) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }

        let pts = controlTimebase.map { CMTimebaseGetTime($0) } ?? CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: duration, preferredTimescale: 600),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid)
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer)
        guard status == noErr else { return nil }
        return sampleBuffer
    }

    // MARK: 無聲音訊，協助背景不被系統中止

    private func startSilentAudio() {
        guard silentPlayer == nil else { silentPlayer?.play(); return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true)
            let data = PiPOverlay.makeSilentWavData(seconds: 1)
            let player = try AVAudioPlayer(data: data, fileTypeHint: AVFileType.wav.rawValue)
            player.numberOfLoops = -1
            player.volume = 0
            player.play()
            silentPlayer = player
        } catch {
            AppLog.shared.add("浮動視窗背景音訊啟動失敗：\(error.localizedDescription)")
        }
    }

    private func stopSilentAudio() {
        silentPlayer?.stop()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 產生一小段靜音的 WAV 資料，不用額外打包音訊檔進 App。
    private static func makeSilentWavData(seconds: Double, sampleRate: Double = 8000) -> Data {
        let frameCount = Int(seconds * sampleRate)
        var data = Data()
        let byteRate = Int32(sampleRate) * 1 * 2
        let blockAlign: Int16 = 2
        let dataSize = Int32(frameCount * 2)
        let chunkSize = 36 + dataSize

        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append(_ v: Int32) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 4)) }
        func append(_ v: Int16) { var le = v.littleEndian; data.append(Data(bytes: &le, count: 2)) }

        append("RIFF"); append(chunkSize); append("WAVE")
        append("fmt "); append(Int32(16))
        append(Int16(1))              // PCM
        append(Int16(1))              // mono
        append(Int32(sampleRate))
        append(byteRate)
        append(blockAlign)
        append(Int16(16))             // bits per sample
        append("data"); append(dataSize)
        data.append(Data(count: frameCount * 2))
        return data
    }

    // MARK: AVPictureInPictureControllerDelegate

    func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        isActive = false
        stopRefreshTimer()
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                     failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        stopRefreshTimer()
        AppLog.shared.add("浮動視窗開啟失敗：\(error.localizedDescription)")
    }

    /// 反組譯比對真實 App 後補上的方法，之前完全漏掉了。使用者點一下子母畫面
    /// 要「恢復回 App」時，系統會呼叫這個方法，**要等我們呼叫 completionHandler
    /// 之後，系統才會真的把控制列收掉、完成轉場**。沒實作這個方法，系統在某些
    /// 情況下可能會一直等這個回呼等不到，導致控制列卡住收不回去——這很可能就是
    /// 浮動視窗「整個癱瘓」的真正原因，不是上一版猜的「太久沒送新畫面」而已
    /// （那個也該修，但這個才是關鍵）。我們沒有自訂的「恢復畫面」轉場動畫，
    /// 直接回報完成就好。
    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                     restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {}

    func pictureInPictureControllerWillStopPictureInPicture(_ controller: AVPictureInPictureController) {}
}

/// 系統「播放樣式」子母畫面的控制代理：暫停/繼續、快轉、倒轉這幾顆按鈕
/// 是系統自己畫、自己接住點擊的（跟 Podcast、影片 App 子母畫面上那排按鈕
/// 一樣），所以就算子母畫面浮在別的 App 上面也能正常點——不會被系統
/// 「點一下恢復 App」的手勢搶走，這正是前兩版自己畫按鈕做不到的地方。
///
/// 系統可能在背景執行緒呼叫這幾個方法，所以用鎖保護狀態，並把實際動作
/// （post 通知、更新 @Published）丟回主執行緒處理。
final class PiPPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
    private let lock = NSLock()
    private var _isPaused = false
    var isPaused: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _isPaused }
        set { lock.lock(); _isPaused = newValue; lock.unlock() }
    }

    /// 使用者按下系統的暫停／繼續。
    var onToggle: (() -> Void)?
    /// 使用者按下系統的快轉（false）／倒轉（true）。
    var onSkip: ((_ goBack: Bool) -> Void)?

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     setPlaying playing: Bool) {
        // 系統按鈕「要播放」但我們目前是暫停（或反過來），才真的需要切換；
        // 避免系統重複呼叫時，暫停狀態被來回切兩次。
        if playing == isPaused {
            DispatchQueue.main.async { [weak self] in self?.onToggle?() }
        }
    }

    /// 反組譯真實 App 挖出來的關鍵差異：它們回的不是「無限長」，而是
    /// `CMTime(seconds: 3600, preferredTimescale: 600)`——假裝自己是一段
    /// 1 小時長的影片，不是真的直播。我們原本回傳 `.positiveInfinity`，
    /// 系統會把這個子母畫面當成「直播」處理，介面上才會一直出現「直播」
    /// 字樣跟那條特別長的進度／控制列，而且很可能就是因為這樣，控制列
    /// 展開之後比較容易卡住收不回去（直播樣式的 PiP 本來就比較像一個
    /// 持續開著的面板，不是「播一下、收起來」的一般影片）。改成有限長度，
    /// 系統會把它當一般影片處理，skip 按鈕一樣正常可以用。
    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .zero, duration: CMTime(seconds: 3600, preferredTimescale: 600))
    }

    func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        isPaused
    }

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                     skipByInterval skipInterval: CMTime,
                                     completion completionHandler: @escaping () -> Void) {
        let goBack = CMTimeGetSeconds(skipInterval) < 0
        DispatchQueue.main.async { [weak self] in
            self?.onSkip?(goBack)
            completionHandler()
        }
    }

    func pictureInPictureControllerShouldProhibitBackgroundAudioPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> Bool {
        false
    }
}

/// 浮動視窗畫面的樣式與畫法。顏色、字型、段落樣式都是靜態、只建立一次就快取
/// 起來，跟反組譯參考的真實 App 一樣——避免每秒重畫一次時反覆建立這些物件。
/// 版面（圖示圓圈＋狀態小圓點、標題/字幕、進度條、右側時速）照搬原本
/// `PiPOverlayWidgetView` 的 SwiftUI 版型，只是改用 Core Graphics／UIKit 的
/// `draw(in:)` 畫出來，不再是 SwiftUI 的 View。
@MainActor
private enum PiPFrameStyle {
    static let colorSpace = CGColorSpaceCreateDeviceRGB()

    static let titleFont = UIFont.systemFont(ofSize: 13, weight: .semibold)
    static let subtitleFont = UIFont.systemFont(ofSize: 11, weight: .regular)
    static let speedFont = UIFont.monospacedDigitSystemFont(ofSize: 19, weight: .bold)

    static let paragraph: NSParagraphStyle = {
        let p = NSMutableParagraphStyle()
        p.lineBreakMode = .byTruncatingTail
        return p
    }()

    static let backgroundColors: CFArray = [
        UIColor(red: 0.07, green: 0.09, blue: 0.09, alpha: 1).cgColor,
        UIColor.black.cgColor,
    ] as CFArray
    static let backgroundGradient = CGGradient(colorsSpace: colorSpace, colors: backgroundColors, locations: [0, 1])
    static let topHairline = UIColor.white.withAlphaComponent(0.08).cgColor
    static let subtitleColor = UIColor.white.withAlphaComponent(0.65)
    static let progressTrackColor = UIColor.white.withAlphaComponent(0.15)
    static let pausedAccent = UIColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 1)
    static let runningAccent = UIColor(red: 0.20, green: 0.85, blue: 0.80, alpha: 1)

    static func attributes(font: UIFont, color: UIColor) -> [NSAttributedString.Key: Any] {
        [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
    }

    static func draw(overlay: PiPOverlay, in rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let accent = overlay.isPaused ? pausedAccent : runningAccent

        // 背景漸層 + 上緣細線
        context.saveGState()
        context.addRect(rect)
        context.clip()
        if let backgroundGradient {
            context.drawLinearGradient(backgroundGradient,
                                        start: CGPoint(x: rect.minX, y: rect.minY),
                                        end: CGPoint(x: rect.maxX, y: rect.maxY),
                                        options: [])
        }
        context.restoreGState()
        context.setFillColor(topHairline)
        context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1))

        let content = rect.insetBy(dx: 14, dy: 12)

        // 左：狀態圖示圓圈 + 右下角狀態小圓點
        let iconDiameter: CGFloat = 46
        let iconRect = CGRect(x: content.minX, y: content.midY - iconDiameter / 2,
                               width: iconDiameter, height: iconDiameter)
        context.setFillColor(accent.withAlphaComponent(0.18).cgColor)
        context.fillEllipse(in: iconRect)
        let symbolName = overlay.isPaused ? "pause.fill" : "location.fill"
        if let symbol = UIImage(systemName: symbolName,
                                 withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .bold))?
            .withTintColor(accent, renderingMode: .alwaysOriginal) {
            let size = symbol.size
            symbol.draw(in: CGRect(x: iconRect.midX - size.width / 2, y: iconRect.midY - size.height / 2,
                                    width: size.width, height: size.height))
        }
        let dotDiameter: CGFloat = 11
        let dotRect = CGRect(x: iconRect.maxX - dotDiameter, y: iconRect.maxY - dotDiameter,
                              width: dotDiameter, height: dotDiameter)
        context.setFillColor(accent.cgColor)
        context.fillEllipse(in: dotRect)
        context.setStrokeColor(UIColor.black.cgColor)
        context.setLineWidth(2)
        context.strokeEllipse(in: dotRect.insetBy(dx: 1, dy: 1))

        // 中：標題／字幕／進度條
        let rightColumnWidth: CGFloat = 92
        let middleX = iconRect.maxX + 12
        let middleWidth = max(0, content.maxX - rightColumnWidth - middleX)
        NSAttributedString(string: overlay.title, attributes: attributes(font: titleFont, color: .white))
            .draw(with: CGRect(x: middleX, y: content.minY, width: middleWidth, height: 18),
                  options: [.usesLineFragmentOrigin], context: nil)
        NSAttributedString(string: overlay.subtitle, attributes: attributes(font: subtitleFont, color: subtitleColor))
            .draw(with: CGRect(x: middleX, y: content.minY + 20, width: middleWidth, height: 16),
                  options: [.usesLineFragmentOrigin], context: nil)

        if let progress = overlay.progress, middleWidth > 0 {
            let barRect = CGRect(x: middleX, y: content.minY + 42, width: middleWidth, height: 4)
            progressTrackColor.setFill()
            UIBezierPath(roundedRect: barRect, cornerRadius: 2).fill()
            let fillWidth = max(4, barRect.width * CGFloat(max(0, min(1, progress))))
            accent.setFill()
            UIBezierPath(roundedRect: CGRect(x: barRect.minX, y: barRect.minY, width: fillWidth, height: barRect.height),
                         cornerRadius: 2).fill()
        }

        // 右：大字時速
        NSAttributedString(string: overlay.speedText, attributes: attributes(font: speedFont, color: accent))
            .draw(with: CGRect(x: content.maxX - rightColumnWidth, y: content.minY, width: rightColumnWidth, height: 26),
                  options: [.usesLineFragmentOrigin], context: nil)
    }
}
