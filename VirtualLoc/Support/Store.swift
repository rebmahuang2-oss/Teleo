import Foundation
import CoreLocation

struct SavedPlace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var latitude: Double
    var longitude: Double
    var date = Date()
    var coord: Coord { Coord(latitude: latitude, longitude: longitude) }
}

struct SavedRoute: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var points: [[Double]]          // [lat, lon]
    var date = Date()
    var coords: [Coord] { points.map { Coord(latitude: $0[0], longitude: $0[1]) } }
    init(name: String, coords: [Coord]) {
        self.name = name
        self.points = coords.map { [$0.latitude, $0.longitude] }
    }
}

struct HistoryItem: Codable, Identifiable, Hashable {
    enum Kind: String, Codable { case point, route }
    var id = UUID()
    var kind: Kind
    var title: String
    var points: [[Double]]
    var date = Date()
    var coords: [Coord] { points.map { Coord(latitude: $0[0], longitude: $0[1]) } }
}

/// 收藏與歷史：存成 JSON 檔（Documents）。地標與路線各最多 500 筆，歷史 200 筆。
@MainActor
final class Store: ObservableObject {
    @Published var places: [SavedPlace] = [] { didSet { save(places, "places.json") } }
    @Published var routes: [SavedRoute] = [] { didSet { save(routes, "routes.json") } }
    @Published var history: [HistoryItem] = [] { didSet { save(history, "history.json") } }

    static let placeLimit = 500
    static let routeLimit = 500
    static let historyLimit = 200

    private var loading = true

    init() {
        places = load("places.json") ?? []
        routes = load("routes.json") ?? []
        history = load("history.json") ?? []
        loading = false
    }

    // MARK: 操作

    @discardableResult
    func addPlace(name: String, coord: Coord) -> Bool {
        guard places.count < Store.placeLimit else { return false }
        places.insert(SavedPlace(name: name, latitude: coord.latitude, longitude: coord.longitude), at: 0)
        return true
    }

    @discardableResult
    func addRoute(name: String, coords: [Coord]) -> Bool {
        guard routes.count < Store.routeLimit, coords.count > 1 else { return false }
        routes.insert(SavedRoute(name: name, coords: coords), at: 0)
        return true
    }

    func record(point: Coord) {
        let title = Geo.format(point)
        if let first = history.first, first.kind == .point, first.title == title { return }
        push(HistoryItem(kind: .point, title: title, points: [[point.latitude, point.longitude]]))
    }

    func record(route: [Coord]) {
        guard route.count > 1 else { return }
        let f = DateFormatter()
        f.dateFormat = "MM/dd HH:mm"
        let title = "路線 \(route.count) 點 · \(Geo.pathLength(route).distanceText) · \(f.string(from: Date()))"
        push(HistoryItem(kind: .route, title: title, points: route.map { [$0.latitude, $0.longitude] }))
    }

    func clearHistory() { history = [] }

    private func push(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > Store.historyLimit { history.removeLast(history.count - Store.historyLimit) }
    }

    // MARK: 檔案

    private func url(_ name: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent(name)
    }

    private func load<T: Decodable>(_ name: String) -> T? {
        guard let data = try? Data(contentsOf: url(name)) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func save<T: Encodable>(_ value: T, _ name: String) {
        guard !loading else { return }
        if let data = try? JSONEncoder().encode(value) {
            try? data.write(to: url(name), options: .atomic)
        }
    }
}
