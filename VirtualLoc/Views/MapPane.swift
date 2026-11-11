import SwiftUI
import MapKit

final class MapPin: MKPointAnnotation {
    enum Kind { case selected, current, original, routePoint(Int), start, end }
    var kind: Kind = .selected
}

struct MapPane: UIViewRepresentable {
    @EnvironmentObject var engine: SimulationEngine
    @EnvironmentObject var keepAlive: KeepAlive
    /// 改變時把地圖移到「目前模擬位置」
    var recenterToken: Int
    /// 改變時把地圖移到「選取的點」（搜尋後使用）
    var focusToken: Int

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = false
        map.showsScale = false
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 25.0330, longitude: 121.5654),
                                         span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)),
                      animated: false)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:)))
        map.addGestureRecognizer(tap)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.sync(map)
    }

    final class Coordinator: NSObject, MKMapViewDelegate {
        var parent: MapPane
        private var selectedPin: MapPin?
        private var currentPin: MapPin?
        private var originalPin: MapPin?
        private var routePins: [MapPin] = []
        private var polyline: MKPolyline?
        private var circles: [MKCircle] = []
        private var routeSignature = ""
        private var lastToken = 0
        private var lastFocusToken = 0
        private var didCenterOnOriginal = false

        init(_ parent: MapPane) { self.parent = parent }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let map = g.view as? MKMapView else { return }
            let pt = g.location(in: map)
            let c = map.convert(pt, toCoordinateFrom: map)
            Task { @MainActor in
                if self.parent.engine.pickOnMap {
                    self.parent.engine.addRoutePoint(c)
                } else {
                    self.parent.engine.selected = c
                }
            }
        }

        func sync(_ map: MKMapView) {
            let engine = parent.engine

            selectedPin = update(map, pin: selectedPin, coord: engine.selected, kind: .selected, title: "選取")
            currentPin = update(map, pin: currentPin, coord: engine.current, kind: .current, title: "目前模擬位置")
            originalPin = update(map, pin: originalPin, coord: parent.keepAlive.original, kind: .original, title: "原始位置")

            // 路線與圈圈：只在內容改變時重建
            let sig = "\(engine.route.count)|\(engine.route.first?.latitude ?? 0)|\(engine.route.first?.longitude ?? 0)|\(engine.route.last?.latitude ?? 0)|\(engine.route.last?.longitude ?? 0)|\(engine.showCircles)|\(Int(engine.flowerRadius))|\(engine.farmCenters.count)|\(engine.farmCenters.first?.latitude ?? 0)|\(engine.farmCenters.last?.longitude ?? 0)|\(Int(engine.farmRadius))"
            if sig != routeSignature {
                routeSignature = sig
                if let p = polyline { map.removeOverlay(p) }
                map.removeOverlays(circles)
                map.removeAnnotations(routePins)
                routePins = []
                circles = []
                polyline = nil
                let pts = engine.route
                if pts.count > 1 {
                    var coords = pts
                    let line = MKPolyline(coordinates: &coords, count: coords.count)
                    map.addOverlay(line)
                    polyline = line
                }
                if !engine.farmCenters.isEmpty {
                    // 花農路線：每朵花一個編號標記與繞圈範圍，不標出圓上的每個點
                    let centers = engine.farmCenters
                    if centers.count <= 300 {
                        for (i, c) in centers.enumerated() {
                            routePins.append(makePin(c, .routePoint(i + 1), "花 \(i + 1)"))
                            circles.append(MKCircle(center: c, radius: engine.farmRadius))
                        }
                        map.addOverlays(circles)
                    } else {
                        routePins.append(makePin(centers[0], .start, "第一朵花"))
                        routePins.append(makePin(centers[centers.count - 1], .end, "最後一朵花"))
                    }
                    map.addAnnotations(routePins)
                } else if pts.count > 0 {
                    if pts.count <= 80 {
                        for (i, c) in pts.enumerated() {
                            routePins.append(makePin(c, .routePoint(i + 1), "路線點 \(i + 1)"))
                        }
                        if engine.showCircles {
                            for c in pts {
                                circles.append(MKCircle(center: c, radius: engine.flowerRadius))
                                circles.append(MKCircle(center: c, radius: engine.flowerRadius * 0.9))
                            }
                            map.addOverlays(circles)
                        }
                    } else {
                        routePins.append(makePin(pts[0], .start, "起點"))
                        routePins.append(makePin(pts[pts.count - 1], .end, "終點"))
                    }
                    map.addAnnotations(routePins)
                }
            }

            // 移到目前模擬位置
            if parent.recenterToken != lastToken {
                lastToken = parent.recenterToken
                if let c = engine.current ?? engine.selected ?? parent.keepAlive.original {
                    map.setCenter(c, animated: true)
                }
            }
            // 移到選取的點（搜尋結果）
            if parent.focusToken != lastFocusToken {
                lastFocusToken = parent.focusToken
                if let c = engine.selected {
                    map.setRegion(MKCoordinateRegion(center: c,
                                                     span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                                  animated: true)
                }
            }
            // 第一次取得原始位置時自動置中一次
            if !didCenterOnOriginal, engine.current == nil, engine.selected == nil,
               let o = parent.keepAlive.original {
                didCenterOnOriginal = true
                map.setRegion(MKCoordinateRegion(center: o,
                                                 span: MKCoordinateSpan(latitudeDelta: 0.01, longitudeDelta: 0.01)),
                              animated: false)
            }
            // 搖桿／路線進行中跟隨模擬位置
            if (engine.mode == .joystick || (engine.mode == .route && engine.routeRunning && !engine.routePaused)),
               let c = engine.current {
                map.setCenter(c, animated: false)
            }
        }

        private func makePin(_ c: CLLocationCoordinate2D, _ kind: MapPin.Kind, _ title: String) -> MapPin {
            let p = MapPin()
            p.coordinate = c
            p.kind = kind
            p.title = title
            return p
        }

        private func update(_ map: MKMapView, pin: MapPin?, coord: CLLocationCoordinate2D?,
                            kind: MapPin.Kind, title: String) -> MapPin? {
            guard let coord = coord else {
                if let pin = pin { map.removeAnnotation(pin) }
                return nil
            }
            if let pin = pin {
                if pin.coordinate.latitude != coord.latitude || pin.coordinate.longitude != coord.longitude {
                    pin.coordinate = coord
                }
                return pin
            }
            let p = makePin(coord, kind, title)
            map.addAnnotation(p)
            return p
        }

        // MARK: 圖示

        /// 圓形數字徽章（路線點）
        private static func badge(_ text: String, fill: UIColor) -> UIImage {
            let size = CGSize(width: 36, height: 36)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: rect)
                fill.setFill()
                ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 3, dy: 3))
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: UIFont.boldSystemFont(ofSize: 15),
                    .foregroundColor: UIColor.white
                ]
                let s = NSAttributedString(string: text, attributes: attrs)
                let ts = s.size()
                s.draw(at: CGPoint(x: (size.width - ts.width) / 2, y: (size.height - ts.height) / 2))
            }
        }

        /// 橘色圓底白色箭頭（目前模擬位置）
        private static func arrow() -> UIImage {
            let size = CGSize(width: 46, height: 46)
            return UIGraphicsImageRenderer(size: size).image { ctx in
                let rect = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
                UIColor.white.setFill()
                ctx.cgContext.fillEllipse(in: rect)
                UIColor(red: 0.93, green: 0.50, blue: 0.12, alpha: 1).setFill()
                ctx.cgContext.fillEllipse(in: rect.insetBy(dx: 4, dy: 4))
                let cfg = UIImage.SymbolConfiguration(pointSize: 18, weight: .bold)
                if let sym = UIImage(systemName: "location.north.fill", withConfiguration: cfg)?
                    .withTintColor(.white, renderingMode: .alwaysOriginal) {
                    sym.draw(at: CGPoint(x: (size.width - sym.size.width) / 2,
                                         y: (size.height - sym.size.height) / 2))
                }
            }
        }

        // MARK: MKMapViewDelegate

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? MapPin else { return nil }

            switch pin.kind {
            case .current:
                let id = "current"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                view.image = Coordinator.arrow()
                view.canShowCallout = true
                view.displayPriority = .required
                view.zPriority = .max
                return view

            case .routePoint(let n):
                let id = "route"
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: id)
                    ?? MKAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                let color = n == 1
                    ? UIColor(red: 0.05, green: 0.72, blue: 0.78, alpha: 1)
                    : UIColor(red: 0.09, green: 0.51, blue: 0.69, alpha: 1)
                view.image = Coordinator.badge("\(n)", fill: color)
                view.canShowCallout = true
                view.displayPriority = .defaultHigh
                return view

            default:
                let id = "pin"
                let view = (mapView.dequeueReusableAnnotationView(withIdentifier: id) as? MKMarkerAnnotationView)
                    ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: id)
                view.annotation = pin
                view.canShowCallout = true
                view.displayPriority = .required
                switch pin.kind {
                case .selected:
                    view.markerTintColor = .systemOrange
                    view.glyphImage = UIImage(systemName: "scope")
                case .original:
                    view.markerTintColor = .systemPurple
                    view.glyphImage = UIImage(systemName: "flag.fill")
                case .start:
                    view.markerTintColor = .systemGreen
                    view.glyphImage = UIImage(systemName: "play.fill")
                case .end:
                    view.markerTintColor = .systemGray
                    view.glyphImage = UIImage(systemName: "flag.checkered")
                default:
                    break
                }
                return view
            }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let line = overlay as? MKPolyline {
                let r = MKPolylineRenderer(polyline: line)
                r.strokeColor = UIColor(red: 0.09, green: 0.45, blue: 0.65, alpha: 0.9)
                r.lineWidth = 4
                return r
            }
            if let circle = overlay as? MKCircle {
                let r = MKCircleRenderer(circle: circle)
                r.strokeColor = UIColor(red: 0.05, green: 0.72, blue: 0.78, alpha: 0.95)
                r.fillColor = UIColor(red: 0.05, green: 0.72, blue: 0.78, alpha: 0.05)
                r.lineWidth = 3
                return r
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
