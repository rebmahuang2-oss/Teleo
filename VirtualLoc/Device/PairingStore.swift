import Foundation

/// 配對檔存放在 App 的 Application Support，不會被備份到雲端以外的地方。
enum PairingStore {
    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("VirtualLoc", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL { directory.appendingPathComponent("pairing.plist") }

    static var exists: Bool { FileManager.default.fileExists(atPath: fileURL.path) }

    /// 匯入使用者選擇的檔案（需要 security-scoped 存取）
    static func importFile(from url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else {
            throw NSError(domain: "VirtualLoc", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "檔案是空的"])
        }
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func remove() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
