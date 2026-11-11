import Foundation
import CoreLocation

typealias Coord = CLLocationCoordinate2D

enum Geo {
    static let earthRadius = 6_371_008.8

    static func isValid(_ c: Coord) -> Bool {
        abs(c.latitude) <= 90 && abs(c.longitude) <= 180
    }

    /// Haversine 距離（公尺）
    static func distance(_ a: Coord, _ b: Coord) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1
        let dl = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * earthRadius * asin(min(1, sqrt(h)))
    }

    static func lerp(_ a: Coord, _ b: Coord, _ t: Double) -> Coord {
        Coord(latitude: a.latitude + (b.latitude - a.latitude) * t,
              longitude: a.longitude + (b.longitude - a.longitude) * t)
    }

    static func pathLength(_ pts: [Coord]) -> Double {
        guard pts.count > 1 else { return 0 }
        var sum = 0.0
        for i in 0..<(pts.count - 1) { sum += distance(pts[i], pts[i + 1]) }
        return sum
    }

    /// 座標文字（小數點後六位）
    static func format(_ c: Coord) -> String {
        String(format: "%.6f, %.6f", c.latitude, c.longitude)
    }

    static func wrapLongitude(_ lon: Double) -> Double {
        var l = lon
        while l > 180 { l -= 360 }
        while l < -180 { l += 360 }
        return l
    }

    // MARK: 文字座標解析

    /// 解析多行座標：每行「緯度, 經度」，分隔符可為逗號、分號、空白或 Tab。無效的行會被略過。
    static func parseList(_ text: String) -> [Coord] {
        var result: [Coord] = []
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            if let c = parseOne(String(line)) { result.append(c) }
        }
        return result
    }

    /// 解析多行座標，每行可在座標後多寫一個數字當作「停留秒數」，例如「25.0330, 121.5654, 15」。
    static func parseListWithDwell(_ text: String) -> [(coord: Coord, dwell: Double?)] {
        var result: [(coord: Coord, dwell: Double?)] = []
        let seps = CharacterSet(charactersIn: ",;\t ()[]°\u{FF0C}\u{3000}")
        for line in text.split(whereSeparator: { $0 == "\n" || $0 == "\r" }) {
            let parts = String(line).components(separatedBy: seps).filter { !$0.isEmpty }
            guard parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { continue }
            let c = Coord(latitude: lat, longitude: lon)
            guard isValid(c) else { continue }
            var dwell: Double? = nil
            if parts.count >= 3, let d = Double(parts[2]), d >= 1, d <= 3600 { dwell = d }
            result.append((c, dwell))
        }
        return result
    }

    static func parseOne(_ s: String) -> Coord? {
        // 容許 (25.03, 121.56)、25.03°, 121.56° 這類貼法
        let seps = CharacterSet(charactersIn: ",;\t ()[]°\u{FF0C}\u{3000}")
        let parts = s.components(separatedBy: seps).filter { !$0.isEmpty }
        guard parts.count >= 2,
              let lat = Double(parts[0]), let lon = Double(parts[1]) else { return nil }
        let c = Coord(latitude: lat, longitude: lon)
        return isValid(c) ? c : nil
    }

    // MARK: 最短路線排序（最近鄰 + 2-opt，開放路徑，起點固定為第一點以外可自動挑選）

    /// 3～5000 點。超過 700 點時只做最近鄰（避免 2-opt 太慢）。
    static func shortestOrder(_ pts: [Coord]) -> [Coord] {
        let n = pts.count
        guard n >= 3 else { return pts }

        // 最近鄰：嘗試少數幾個起點，挑總長最短者
        let starts = n <= 60 ? Array(0..<n) : [0, n / 4, n / 2, (3 * n) / 4]
        var best: [Int] = []
        var bestLen = Double.infinity
        for s in starts {
            let order = nearestNeighbor(pts, start: s)
            let len = length(of: order, pts)
            if len < bestLen { bestLen = len; best = order }
        }
        if n <= 700 { best = twoOpt(best, pts) }
        return best.map { pts[$0] }
    }

    private static func nearestNeighbor(_ pts: [Coord], start: Int) -> [Int] {
        var unvisited = Set(0..<pts.count)
        var order = [start]
        unvisited.remove(start)
        var cur = start
        while !unvisited.isEmpty {
            var bestIdx = -1
            var bestD = Double.infinity
            for i in unvisited {
                let d = distance(pts[cur], pts[i])
                if d < bestD { bestD = d; bestIdx = i }
            }
            order.append(bestIdx)
            unvisited.remove(bestIdx)
            cur = bestIdx
        }
        return order
    }

    private static func length(of order: [Int], _ pts: [Coord]) -> Double {
        var sum = 0.0
        for i in 0..<(order.count - 1) { sum += distance(pts[order[i]], pts[order[i + 1]]) }
        return sum
    }

    private static func twoOpt(_ initial: [Int], _ pts: [Coord]) -> [Int] {
        var order = initial
        let n = order.count
        var improved = true
        var rounds = 0
        while improved && rounds < 50 {
            improved = false
            rounds += 1
            for i in 0..<(n - 2) {
                for j in (i + 1)..<(n - 1) {
                    // 反轉 order[i+1...j]
                    let a = pts[order[i]], b = pts[order[i + 1]]
                    let c = pts[order[j]], d = pts[order[j + 1]]
                    let delta = distance(a, c) + distance(b, d) - distance(a, b) - distance(c, d)
                    if delta < -0.01 {
                        order[(i + 1)...j].reverse()
                        improved = true
                    }
                }
            }
        }
        return order
    }
}

extension Double {
    /// 秒 → 「1 時 02 分」之類的文字
    var durationText: String {
        guard self.isFinite, self >= 0 else { return "--" }
        let s = Int(self.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        if h > 0 { return String(format: "%d 時 %02d 分", h, m) }
        if m > 0 { return String(format: "%d 分 %02d 秒", m, sec) }
        return "\(sec) 秒"
    }

    var distanceText: String {
        self >= 1000 ? String(format: "%.2f 公里", self / 1000) : String(format: "%.0f 公尺", self)
    }
}
