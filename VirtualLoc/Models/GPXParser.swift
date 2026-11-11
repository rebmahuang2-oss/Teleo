import Foundation
import CoreLocation

struct GPXPoint {
    let coordinate: CLLocationCoordinate2D
}

/// 簡易 GPX 解析器：讀取 <trkpt>、<rtept>、<wpt> 的 lat/lon。
final class GPXParser: NSObject, XMLParserDelegate {
    private var points: [GPXPoint] = []

    static func parse(data: Data) -> [GPXPoint] {
        let handler = GPXParser()
        let parser = XMLParser(data: data)
        parser.delegate = handler
        parser.parse()
        return handler.points
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName qName: String?,
                attributes attributeDict: [String: String] = [:]) {
        guard ["trkpt", "rtept", "wpt"].contains(elementName),
              let latStr = attributeDict["lat"], let lonStr = attributeDict["lon"],
              let lat = Double(latStr), let lon = Double(lonStr),
              abs(lat) <= 90, abs(lon) <= 180 else { return }
        points.append(GPXPoint(coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon)))
    }
}
