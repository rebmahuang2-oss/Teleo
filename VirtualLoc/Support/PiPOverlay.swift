import AVKit
import AVFoundation
import SwiftUI
import UIKit

/// 讓路線進度能用「子母畫面（Picture in Picture）」的方式浮在其他 App 最上面，
/// 離開 Teleo（例如切回 Pikmin Bloom）時還能看到走到第幾點、剩多久。
///
/// 原理：iOS 沒有開放一般 App「浮在其他 App 上層」的正式窗口 API，但 AVKit 給視訊通話類
/// App 用的 Picture in Picture（`AVPictureInPictureController` + `.ContentSource`
/// 的「視訊通話」建構式）可以放任意畫面進去，不一定要是真的視訊。這是目前唯一公開、
/// 不需要跳脫越獄就能做到「浮動視窗」的方式，很多類似工具也是用這招。
///
/// 限制／風險（事先講清楚，不是穩賺不賠的東西）：
/// - 這個機制原本是設計給視訊通話 App 用的，Apple 的文件沒有明講「純文字、沒有通話」
///   能不能穩定維持在背景不被系統關掉；為了盡量撐住，這裡會在背景播放一段「無聲音訊」，
///   這是一般 App 用來避免被系統中止的標準做法。
/// - 如果系統環境不支援（例如低電量模式、裝置設定限制），子母畫面可能根本開不起來；
///   這種情況下 App 其他功能完全不受影響，只是看不到那條浮動列。
/// - 子母畫面視窗能不能被使用者拖動、縮放，由系統控制，App 自己不能決定位置。
@MainActor
final class PiPOverlay: NSObject, ObservableObject, AVPictureInPictureControllerDelegate {
    static let shared = PiPOverlay()

    @Published var isActive = false
    @Published var title = "Teleo"
    @Published var subtitle = ""
    @Published var isPaused = false

    /// 使用者是否想要這個功能（設定頁開關），預設關閉，因為會持續耗一點電。
    @AppStorage("pipOverlayEnabled") var enabled = false

    private var pip: AVPictureInPictureController?
    private var callVC: PiPCallViewController?
    private var sourceView: UIView?
    private var silentPlayer: AVAudioPlayer?

    private override init() { super.init() }

    /// 在 App 啟動時呼叫一次，準備好（但不會立刻顯示）子母畫面。
    func prepare() {
        guard enabled, pip == nil else { return }
        guard AVPictureInPictureController.isPictureInPictureSupported() else { return }

        let callVC = PiPCallViewController()
        callVC.hostingController.rootView = AnyView(PiPOverlayWidgetView(overlay: self))
        self.callVC = callVC

        // 「視訊通話」這招的子母畫面，sourceView 一定要真的掛在畫面的 view 階層裡，
        // 系統才知道這塊畫面在螢幕上的哪個位置、該從哪裡浮出來；如果只是在記憶體裡
        // 建立一個 UIView、沒有真的 addSubview 到視窗上，startPictureInPicture()
        // 會悄悄失敗（不一定會丟出明顯的錯誤），結果就是畫面上完全看不到浮動視窗——
        // 這就是之前「開關打開了，但切去其他 App 沒有懸浮視窗」的原因。
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 120, height: 42))
        view.isUserInteractionEnabled = false
        view.alpha = 0.01
        self.sourceView = view
        attachSourceViewIfNeeded(view)

        let source = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: view,
            contentViewController: callVC)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        self.pip = controller
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
    func update(title: String, subtitle: String, isPaused: Bool) {
        self.title = title
        self.subtitle = subtitle
        self.isPaused = isPaused
        // 使用者在路線跑的途中，到設定頁把開關關掉的話，這裡會順便把正在顯示的浮動視窗收起來，
        // 不用等下一次路線開始/結束才生效。
        if !enabled, pip?.isPictureInPictureActive == true { stop() }
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

/// 子母畫面要求內容是 `AVPictureInPictureVideoCallViewController` 的子類別，
/// 裡面放的是我們自己的 SwiftUI 畫面。
final class PiPCallViewController: AVPictureInPictureVideoCallViewController {
    let hostingController = UIHostingController(rootView: AnyView(EmptyView()))

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 260, height: 90)
        view.backgroundColor = .black
        addChild(hostingController)
        hostingController.view.backgroundColor = .clear
        view.addSubview(hostingController.view)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        hostingController.didMove(toParent: self)
    }
}
