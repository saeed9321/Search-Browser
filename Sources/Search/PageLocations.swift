import CoreLocation
import Darwin
import WebKit

private typealias LocationRef = UnsafeMutableRawPointer

private struct LocationWebKit {
    let pageContext: @convention(c) (LocationRef) -> LocationRef?
    let manager: @convention(c) (LocationRef) -> LocationRef?
    let setProvider: @convention(c) (LocationRef, UnsafeRawPointer) -> Void
    let position: @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> LocationRef?
    let changed: @convention(c) (LocationRef, LocationRef) -> Void
    let failed: @convention(c) (LocationRef) -> Void
    let retain: @convention(c) (LocationRef) -> LocationRef
    let release: @convention(c) (LocationRef) -> Void

    static let loaded: LocationWebKit? = {
        let webkit = dlopen("/System/Library/Frameworks/WebKit.framework/WebKit", RTLD_NOW)
        func f<T>(_ name: String) -> T? { dlsym(webkit, name).map { unsafeBitCast($0, to: T.self) } }
        guard let pageContext: @convention(c) (LocationRef) -> LocationRef? = f("WKPageGetContext"),
              let manager: @convention(c) (LocationRef) -> LocationRef? = f("WKContextGetGeolocationManager"),
              let setProvider: @convention(c) (LocationRef, UnsafeRawPointer) -> Void = f("WKGeolocationManagerSetProvider"),
              let position: @convention(c) (Double, Double, Double, Double, Bool, Double, Bool, Double, Bool, Double, Bool, Double) -> LocationRef? = f("WKGeolocationPositionCreate_b"),
              let changed: @convention(c) (LocationRef, LocationRef) -> Void = f("WKGeolocationManagerProviderDidChangePosition"),
              let failed: @convention(c) (LocationRef) -> Void = f("WKGeolocationManagerProviderDidFailToDeterminePosition"),
              let retain: @convention(c) (LocationRef) -> LocationRef = f("WKRetain"),
              let release: @convention(c) (LocationRef) -> Void = f("WKRelease")
        else { return nil }
        return LocationWebKit(pageContext: pageContext, manager: manager, setProvider: setProvider,
                              position: position, changed: changed, failed: failed, retain: retain, release: release)
    }()
}

/// On macOS WebKit has no default location provider. It asks this provider
/// to start only after a page has passed its permission delegate.
@MainActor
enum PageLocations {
    private static var managers: Set<LocationRef> = []
    private static var active: Set<LocationRef> = []
    private static var precise: Set<LocationRef> = []

    static var updating: Bool { !active.isEmpty }

    /// WKGeolocationProviderV1: version, clientInfo, start, stop, accuracy.
    private static let provider: UnsafeMutableRawPointer = {
        let start: @convention(c) (LocationRef, UnsafeRawPointer?) -> Void = { manager, _ in
            MainActor.assumeIsolated { PageLocations.start(manager) }
        }
        let stop: @convention(c) (LocationRef, UnsafeRawPointer?) -> Void = { manager, _ in
            MainActor.assumeIsolated { PageLocations.stop(manager) }
        }
        let accuracy: @convention(c) (LocationRef, Bool, UnsafeRawPointer?) -> Void = { manager, high, _ in
            MainActor.assumeIsolated {
                if high { precise.insert(manager) } else { precise.remove(manager) }
                if !Store.testing { LocationAccess.shared.setAccuracy(!active.isDisjoint(with: precise)) }
            }
        }
        let table = UnsafeMutableRawPointer.allocate(byteCount: 40, alignment: 8)
        table.storeBytes(of: Int32(1), toByteOffset: 0, as: Int32.self)
        table.storeBytes(of: nil, toByteOffset: 8, as: UnsafeRawPointer?.self)
        for (index, callback) in [unsafeBitCast(start, to: UnsafeRawPointer.self),
                                  unsafeBitCast(stop, to: UnsafeRawPointer.self),
                                  unsafeBitCast(accuracy, to: UnsafeRawPointer.self)].enumerated() {
            table.storeBytes(of: callback, toByteOffset: 16 + index * 8, as: UnsafeRawPointer.self)
        }
        return table
    }()

    @discardableResult static func provide(_ web: WKWebView) -> Bool {
        let selector = NSSelectorFromString("_pageRefForTransitionToWKWebView")
        typealias Page = @convention(c) (AnyObject, Selector) -> LocationRef?
        guard let c = LocationWebKit.loaded, web.responds(to: selector),
              let method = class_getMethodImplementation(type(of: web), selector),
              let page = unsafeBitCast(method, to: Page.self)(web, selector),
              let context = c.pageContext(page), let manager = c.manager(context) else { return false }
        if managers.insert(manager).inserted {
            _ = c.retain(manager)
            c.setProvider(manager, provider)
        }
        return true
    }

    private static func start(_ manager: LocationRef) {
        active.insert(manager)
        guard !Store.testing else { return }
        LocationAccess.shared.setAccuracy(!active.isDisjoint(with: precise))
        LocationAccess.shared.startUpdating()
    }

    private static func stop(_ manager: LocationRef) {
        active.remove(manager)
        precise.remove(manager)
        guard !Store.testing else { return }
        if active.isEmpty { LocationAccess.shared.stopUpdating() }
        else { LocationAccess.shared.setAccuracy(!active.isDisjoint(with: precise)) }
    }

    static func changed(_ location: CLLocation) {
        guard !active.isEmpty, location.horizontalAccuracy >= 0, let c = LocationWebKit.loaded,
              let position = c.position(location.timestamp.timeIntervalSince1970,
                                        location.coordinate.latitude, location.coordinate.longitude, location.horizontalAccuracy,
                                        location.verticalAccuracy >= 0, location.altitude,
                                        location.verticalAccuracy >= 0, location.verticalAccuracy,
                                        location.course >= 0, location.course, location.speed >= 0, location.speed)
        else { return }
        defer { c.release(position) }
        for manager in active { c.changed(manager, position) }
    }

    static func failed() {
        guard let c = LocationWebKit.loaded else { return }
        for manager in active { c.failed(manager) }
    }
}
