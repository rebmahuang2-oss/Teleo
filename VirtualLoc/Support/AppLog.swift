import Foundation

/// 簡易錯誤日誌：只保留最近 300 行，並寫入檔案方便重開 App 後查看。不記錄配對檔內容。
@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()
    @Published private(set) var lines: [String] = []

    private let maxLines = 300
    private var fileURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("log.txt")
    }

    private init() {
        if let text = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
    }

    func add(_ message: String) {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        lines.append("[\(f.string(from: Date()))] \(message)")
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        persist()
    }

    func clear() {
        lines = []
        persist()
    }

    var text: String { lines.joined(separator: "\n") }

    private func persist() {
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
    }
}
