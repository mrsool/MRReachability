// MRReachability.swift
// NWPathMonitor-backed, legacy-style Reachability surface.
// Works on iOS 12+
//
// Notes for Swift 6:
// - Immutable global constants (no shared mutable state)
// - Class isolated to MainActor (UI-friendly notifications/callbacks)
// - Enum is Sendable
// - NWPathMonitor callback hops to MainActor via Task { @MainActor in … }

// MRReachability.swift
// NWPathMonitor-backed, legacy-style Reachability surface.
// Supported: iOS 12+ / macOS 10.14+ / tvOS 12+ / watchOS 5+
//
// Swift 6 compatibility:
//  - No @MainActor on the whole class (so CustomStringConvertible is satisfied).
//  - Class is @unchecked Sendable to allow capture inside @Sendable closures;
//    we hop to the main queue before touching callbacks/NotificationCenter.
//  - Enum Connection is Sendable.
//  - No use of Task { } (which needs iOS 13/macOS 10.15); we use DispatchQueue.main.async.
//  - Availability is scoped on the class so older platforms compile apps that include this file,
//    but the type itself is only available where Network.framework exists.

import Foundation
import Network

#if canImport(UIKit)
import UIKit
#endif

#if canImport(SystemConfiguration)
import SystemConfiguration
#endif

// Public version symbols (compat with older Reachability headers)
public let ReachabilityVersionNumber: Double = 1.0
public let ReachabilityVersionString: String = "MRReachability 1.0.3"

public extension Notification.Name {
    static let reachabilityChanged = Notification.Name("reachabilityChanged")
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *)
public final class MRReachability: @unchecked Sendable, CustomStringConvertible {

    // MARK: - Legacy callback aliases
    public typealias NetworkReachable   = (MRReachability) -> Void
    public typealias NetworkUnreachable = (MRReachability) -> Void

    // MARK: - Connection (legacy 3-state), Sendable for Swift 6
    public enum Connection: String, Sendable, CustomStringConvertible {
        case unavailable
        case wifi
        case cellular

        // Some legacy code expects 'none'
        public static let none: Connection = .unavailable

        public var description: String { rawValue }
    }

    // MARK: - Public API
    public var allowsCellularConnection: Bool = true

    public var whenReachable:   NetworkReachable?
    public var whenUnreachable: NetworkUnreachable?

    /// Current connection (best-effort if notifier not started yet)
    public var connection: Connection {
        if let cached = lastStatus { return cached }
        return Self.map(path: monitor.currentPath, allowsCellular: allowsCellularConnection)
    }

    public var description: String { connection.description }

    // MARK: - Init (legacy surface kept)
    public init?() {
        self.monitor = NWPathMonitor()
        self.queue   = DispatchQueue(label: "com.mrsool.reachability.monitor")
    }

    /// Legacy hostname initializer (NWPathMonitor doesn’t do host reachability; kept for API compat)
    public convenience init?(hostname: String) {
        self.init()
        self.host = hostname
    }

    /// Legacy SCNetworkReachability initializer placeholder (kept for source compatibility)
    public convenience init?(_ reachabilityRef: SCNetworkReachability?) {
        self.init()
    }

    // MARK: - Notifier lifecycle
    public func startNotifier() throws {
        guard !notifierRunning else { return }

        // NOTE: pathUpdateHandler is @Sendable. We capture `self` weakly and bounce to main queue
        // before touching any state or calling user callbacks (UI-friendly).
        monitor.pathUpdateHandler = { [weak self] path in
            guard let strongSelf = self else { return }
            let status = Self.map(path: path, allowsCellular: strongSelf.allowsCellularConnection)

            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                self.lastStatus = status

                switch status {
                case .unavailable:
                    self.whenUnreachable?(self)
                case .wifi, .cellular:
                    self.whenReachable?(self)
                }

                NotificationCenter.default.post(name: .reachabilityChanged, object: self)
            }
        }

        monitor.start(queue: queue)
        notifierRunning = true
    }

    public func stopNotifier() {
        guard notifierRunning else { return }
        monitor.cancel()
        notifierRunning = false
        lastStatus = nil
    }

    deinit {
        // Safe to call from deinit; we don’t require main actor here.
        stopNotifier()
    }

    // MARK: - Internals
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var notifierRunning: Bool = false
    private var lastStatus: Connection?
    private var host: String?

    // Map NWPath → legacy Connection
    private static func map(path: NWPath, allowsCellular: Bool) -> Connection {
        guard path.status == .satisfied else { return .unavailable }

        // Treat Wi-Fi and Wired Ethernet both as "wifi" for legacy parity.
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return .wifi
        }

        if allowsCellular && path.usesInterfaceType(.cellular) {
            return .cellular
        }

        // Satisfied but only loopback/other → unavailable in legacy model.
        return .unavailable
    }
}
