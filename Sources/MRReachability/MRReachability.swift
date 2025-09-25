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

public let ReachabilityVersionNumber: Double = 1.0
public let ReachabilityVersionString: String = "MRReachability 1.0.4"

public extension Notification.Name {
    static let reachabilityChanged = Notification.Name("reachabilityChanged")
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *)
public final class MRReachability: @unchecked Sendable, CustomStringConvertible {

    // MARK: - Stored Properties (Grouped Up)

    // Public configuration
    public var allowsCellularConnection: Bool = true
    public var debounceInterval: TimeInterval = 0.2
    public var retryAttempts: Int = 2
    public var retryBackoff: TimeInterval = 1.0
    public var enableDebugLogging: Bool = false
    public var notificationCooldown: TimeInterval = 5.0

    public var whenReachable: NetworkReachable?
    public var whenUnreachable: NetworkUnreachable?

    // Private internals
    private let monitor: NWPathMonitor
    private let queue: DispatchQueue
    private var notifierRunning: Bool = false
    private var lastStatus: Connection?
    private var lastNotifiedStatus: Connection?
    private var lastNotificationTime: Date?
    private var debounceWorkItem: DispatchWorkItem?
    private var host: String?

    // MARK: - Public Types

    public typealias NetworkReachable   = (MRReachability) -> Void
    public typealias NetworkUnreachable = (MRReachability) -> Void

    public enum Connection: String, Sendable, CustomStringConvertible {
        case unavailable
        case wifi
        case cellular

        public static let none: Connection = .unavailable
        public var description: String { rawValue }
    }

    public var connection: Connection {
        if let cached = lastStatus { return cached }
        return Self.map(path: monitor.currentPath, allowsCellular: allowsCellularConnection)
    }

    public var description: String { connection.description }

    // MARK: - Init

    public init?() {
        self.monitor = NWPathMonitor()
        self.queue   = DispatchQueue(label: "com.mrsool.reachability.monitor")
    }

    public convenience init?(hostname: String) {
        self.init()
        self.host = hostname
    }

    #if canImport(SystemConfiguration)
    public convenience init?(_ reachabilityRef: SCNetworkReachability?) {
        self.init()
    }
    #endif

    deinit { stopNotifier() }

    // MARK: - Notifier Lifecycle

    public func startNotifier() throws {
        guard !notifierRunning else { return }

        monitor.pathUpdateHandler = { [weak self] path in
            self?.handlePathUpdate(path)
        }

        monitor.start(queue: queue)
        notifierRunning = true
    }

    public func stopNotifier() {
        guard notifierRunning else { return }
        monitor.cancel()
        notifierRunning = false
        lastStatus = nil
        lastNotifiedStatus = nil
        lastNotificationTime = nil
        debounceWorkItem?.cancel()
        debounceWorkItem = nil
    }

    // MARK: - Path Update + Internet Check

    private func handlePathUpdate(_ path: NWPath) {
        DispatchQueue.main.async { [weak self] in
            self?.processPathOnMain(path)
        }
    }

    private func processPathOnMain(_ path: NWPath) {
        let status = Self.map(path: path, allowsCellular: self.allowsCellularConnection)
        self.lastStatus = status

        // Internet check before notifying
        if status != .unavailable {
            self.checkInternetAvailability(retries: retryAttempts) { [weak self] isReachable in
                self?.scheduleNotifyIfNeeded(for: isReachable ? status : .unavailable)
            }
        } else {
            self.scheduleNotifyIfNeeded(for: .unavailable)
        }
    }

    // MARK: - Notification Scheduling with Cooldown Throttle

    private func scheduleNotifyIfNeeded(for status: Connection) {
        let now = Date()
        let sameAsLast = (status == self.lastNotifiedStatus)
        let cooldownNotMet = (now.timeIntervalSince(lastNotificationTime ?? .distantPast) < notificationCooldown)

        if sameAsLast && cooldownNotMet {
            if enableDebugLogging {
                print("[MRReachability] ⏱ Skipping duplicate '\(status)' notification (cooldown active)")
            }
            return
        }

        let fireNow = { [weak self] in
            guard let self = self else { return }
            self.lastNotifiedStatus = status
            self.lastNotificationTime = Date()
            self.fireCallbacksAndNotification(for: status)
        }

        if debounceInterval > 0 {
            debounceWorkItem?.cancel()
            let item = DispatchWorkItem(block: fireNow)
            debounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
        } else {
            fireNow()
        }
    }

    private func fireCallbacksAndNotification(for status: Connection) {
        if enableDebugLogging {
            print("[MRReachability] 🔔 Status changed to: \(status)")
        }

        switch status {
        case .unavailable:
            self.whenUnreachable?(self)
        case .wifi, .cellular:
            self.whenReachable?(self)
        }

        NotificationCenter.default.post(name: .reachabilityChanged, object: self)
    }

    // MARK: - Internet Reachability Check with Retry

    private func checkInternetAvailability(retries: Int, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "https://www.google.com/generate_204") else {
            completion(false)
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        request.httpMethod = "HEAD"

        if enableDebugLogging {
            print("[MRReachability] 🌐 Checking internet... Attempt \(retryAttempts - retries + 1)")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            let success: Bool

            if let httpResp = response as? HTTPURLResponse, httpResp.statusCode == 204 {
                success = true
            } else if let data = data, !data.isEmpty {
                success = true
            } else {
                success = false
            }

            if success {
                DispatchQueue.main.async {
                    if self?.enableDebugLogging == true {
                        print("[MRReachability] ✅ Internet is reachable.")
                    }
                    completion(true)
                }
            } else if retries > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + (self?.retryBackoff ?? 1)) {
                    self?.checkInternetAvailability(retries: retries - 1, completion: completion)
                }
            } else {
                DispatchQueue.main.async {
                    if self?.enableDebugLogging == true {
                        print("[MRReachability] ❌ Internet check failed after all retries.")
                    }
                    completion(false)
                }
            }
        }.resume()
    }

    // MARK: - Utility

    private static func map(path: NWPath, allowsCellular: Bool) -> Connection {
        guard path.status == .satisfied else { return .unavailable }
        if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
            return .wifi
        }
        if allowsCellular && path.usesInterfaceType(.cellular) {
            return .cellular
        }
        return .unavailable
    }
}
