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
        didSet { playbackDelegate.isPaused = isPaused }
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

    private let renderSize = CGSize(width: 340, height: 84)

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
    }

    func stop() {
        pip?.stopPictureInPicture()
        stopSilentAudio()
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

    /// 用 `ImageRenderer` 把 `PiPOverlayWidgetView` 拍成一張圖，包成一格
    /// sample buffer 塞進 `AVSampleBufferDisplayLayer`。沒有真的影片在播，
    /// 所以每次狀態變化（時速、進度、暫停狀態）就重新拍一張、重新塞一次。
    private func renderFrame() {
        let renderer = ImageRenderer(content: PiPOverlayWidgetView(overlay: self).frame(
            width: renderSize.width, height: renderSize.height))
        renderer.scale = UIScreen.main.scale
        guard let cgImage = renderer.uiImage?.cgImage else { return }
        guard let pixelBuffer = PiPOverlay.makePixelBuffer(from: cgImage, size: renderSize) else { return }
        guard let sampleBuffer = PiPOverlay.makeSampleBuffer(from: pixelBuffer) else { return }
        if displayLayer.status == .failed { displayLayer.flush() }
        displayLayer.enqueue(sampleBuffer)
    }

    private static func makePixelBuffer(from image: CGImage, size: CGSize) -> CVPixelBuffer? {
        let width = Int(size.width * UIScreen.main.scale)
        let height = Int(size.height * UIScreen.main.scale)
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                          kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private static func makeSampleBuffer(from pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        guard let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
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
    }

    func pictureInPictureController(_ controller: AVPictureInPictureController,
                                     failedToStartPictureInPictureWithError error: Error) {
        isActive = false
        AppLog.shared.add("浮動視窗開啟失敗：\(error.localizedDescription)")
    }
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

    func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
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
