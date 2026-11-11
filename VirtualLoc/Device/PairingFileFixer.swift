import Foundation

/// 有些裝置配對時沒有逃生包（EscrowBag）或缺少 UDID 欄位，idevice 讀取配對檔時
/// 對欄位比較龜毛，缺東西時只會回一句看不出所以然的「failed to parse raw pairing file
/// from bytes」，無法知道到底是哪裡出問題。
///
/// 這裡先用系統內建的 plist 解析器讀一次：
/// - 真正必要的欄位（憑證、金鑰、HostID 等）如果缺了，直接丟出清楚講明是哪個欄位的錯誤，
///   不用等 idevice 回一串看不懂的代碼。
/// - 非必要欄位（EscrowBag、UDID）缺少的話就補一個空值，避免解析器卡住。
/// 處理完寫到暫存檔，回傳暫存檔路徑給 idevice 讀取。
enum PairingFileFixer {
    private static let requiredDataKeys = [
        "DeviceCertificate", "HostPrivateKey", "HostCertificate",
        "RootPrivateKey", "RootCertificate",
    ]
    private static let requiredStringKeys = ["SystemBUID", "HostID", "WiFiMACAddress"]

    static func normalizedCopy(of path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let data = try Data(contentsOf: url)

        var format = PropertyListSerialization.PropertyListFormat.xml
        guard let parsed = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: &format),
            var dict = parsed as? [String: Any] else {
            throw NSError(domain: "Teleo", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "配對檔不是看得懂的 plist 格式（檔案可能損毀，或選錯檔案了）"
            ])
        }

        func describeKeys() -> String {
            dict.keys.sorted()
                .map { k -> String in
                    let v = dict[k]
                    let typeName: String
                    switch v {
                    case is Data: typeName = "Data"
                    case is String: typeName = "String"
                    case is [String: Any]: typeName = "Dict"
                    case is [Any]: typeName = "Array"
                    case is NSNumber: typeName = "Number"
                    default: typeName = "\(type(of: v as Any))"
                    }
                    return "\(k)(\(typeName))"
                }
                .joined(separator: "、")
        }

        for key in requiredDataKeys {
            guard dict[key] is Data else {
                throw NSError(domain: "Teleo", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "配對檔缺少必要欄位「\(key)」，這份配對檔可能不完整或壞掉了，建議重新產生一份。" +
                        "實際讀到的欄位：\(describeKeys())"
                ])
            }
        }
        for key in requiredStringKeys {
            guard dict[key] is String else {
                throw NSError(domain: "Teleo", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "配對檔缺少必要欄位「\(key)」，這份配對檔可能不完整或壞掉了，建議重新產生一份。" +
                        "實際讀到的欄位：\(describeKeys())"
                ])
            }
        }

        // 非必要欄位：缺的話補一個空值，不要讓解析器因為少一個欄位就整個拒收。
        if dict["EscrowBag"] == nil { dict["EscrowBag"] = Data() }
        if dict["UDID"] == nil { dict["UDID"] = "" }

        let outData = try PropertyListSerialization.data(
            fromPropertyList: dict, format: .xml, options: 0)
        let outURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-normalized.plist")
        try outData.write(to: outURL, options: .atomic)
        return outURL.path
    }
}
