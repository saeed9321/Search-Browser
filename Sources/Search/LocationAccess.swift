import CoreLocation

@MainActor
final class LocationAccess: NSObject, CLLocationManagerDelegate {
    static let shared = LocationAccess()

    private let manager = CLLocationManager()
    private var waiting: [(Bool) -> Void] = []

    override private init() {
        super.init()
        manager.delegate = self
    }

    func authorize(_ answer: @escaping (Bool) -> Void) {
        guard CLLocationManager.locationServicesEnabled() else { return answer(false) }
        switch manager.authorizationStatus {
        case .authorizedAlways:
            answer(true)
        case .notDetermined:
            waiting.append(answer)
            if waiting.count == 1 { manager.requestWhenInUseAuthorization() }
        default:
            answer(false)
        }
    }

    func setAccuracy(_ high: Bool) {
        manager.desiredAccuracy = high ? kCLLocationAccuracyBest : kCLLocationAccuracyHundredMeters
    }

    func startUpdating() {
        guard CLLocationManager.locationServicesEnabled(), manager.authorizationStatus == .authorizedAlways else {
            return PageLocations.failed()
        }
        manager.startUpdatingLocation()
    }

    func stopUpdating() { manager.stopUpdatingLocation() }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            if let location = locations.last { PageLocations.changed(location) }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated { PageLocations.failed() }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            guard manager.authorizationStatus != .notDetermined else { return }
            let allowed = CLLocationManager.locationServicesEnabled()
                && manager.authorizationStatus == .authorizedAlways
            let answers = waiting
            waiting.removeAll()
            for answer in answers { answer(allowed) }
            if !allowed {
                manager.stopUpdatingLocation()
                PageLocations.failed()
            }
        }
    }
}
