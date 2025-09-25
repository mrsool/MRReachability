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
public let ReachabilityVersionString: String = "MRReachability 1.0.5"

public extension Notification.Name {
    static let reachabilityChanged = Notification.Name("reachabilityChanged")
}

@available(iOS 12.0, macOS 10.14, tvOS 12.0, watchOS 5.0, *)
public final class MRReachability: @unchecked Sendable, CustomStringConvertible {

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

    // MARK: - Public configuration

    public var allowsCellularConnection: Bool = true
    public var debounceInterval: TimeInterval = 0.2
    public var retryAttempts: Int = 2
    public var retryBackoff: TimeInterval = 1.0
    public var enableDebugLogging: Bool = false
    public var notificationCooldown: TimeInterval = 5.0

    /// Strict mode: only mark reachable when HTTP probe succeeds.
    public var requireInternetProbe: Bool = true

    /// Probe endpoint (Google 204 by default) — replace with your own if needed.
    public var probeURL: URL? = URL(string: "https://www.google.com/generate_204")

    /// Probe timeout (seconds).
    public var probeTimeout: TimeInterval = 4.0

    /// If true, only HTTP 204 is accepted (classic captive-portal detection).
    /// If false (default), we use a lenient-but-safe rule below.
    public var requireExact204ForProbe: Bool = false

    public var whenReachable: NetworkReachable?
    public var whenUnreachable: NetworkUnreachable?

    // MARK: - Private internals

    private let queue: DispatchQueue
    private var monitor: NWPathMonitor
    private var notifierRunning: Bool = false

    private var lastStatus: Connection?
    private var lastNotifiedStatus: Connection?
    private var lastNotificationTime: Date?
    private var debounceWorkItem: DispatchWorkItem?
    private var host: String?

    /// Prevent redundant concurrent probes on rapid path flips.
    private var probeInFlight: Bool = false

    // MARK: - Surface

    /// Current connection state. Uses the cached lastStatus if known;
    /// otherwise maps from NWPath (which may be optimistic prior to probe).
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
        self.host = hostname // retained for compatibility
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

        if enableDebugLogging {
            print("[MRReachability] ▶️ Notifier started (v\(ReachabilityVersionString))")
        }
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
        probeInFlight = false

        // Recreate monitor for clean restarts (more reliable on some OSes)
        monitor = NWPathMonitor()

        if enableDebugLogging {
            print("[MRReachability] ⏹ Notifier stopped")
        }
    }

    // MARK: - Path Update + Internet Check

    private func handlePathUpdate(_ path: NWPath) {
        DispatchQueue.main.async { [weak self] in
            self?.processPathOnMain(path)
        }
    }

    private func processPathOnMain(_ path: NWPath) {
        let mapped = Self.map(path: path, allowsCellular: self.allowsCellularConnection)

        if enableDebugLogging {
            let usesWiFi = path.usesInterfaceType(.wifi)
            let usesCell = path.usesInterfaceType(.cellular)
            let usesEth  = path.usesInterfaceType(.wiredEthernet)
            if #available(macOS 10.15, *) {
                print("[MRReachability] Path=\(path.status) | wifi:\(usesWiFi) cell:\(usesCell) eth:\(usesEth) constrained:\(path.isConstrained) expensive:\(path.isExpensive) → mapped:\(mapped)")
            }
        }

        // If NWPath says unavailable, finalize immediately
        guard mapped != .unavailable else {
            self.lastStatus = .unavailable                    // ✅ final truth
            scheduleNotifyIfNeeded(for: .unavailable)
            return
        }

        // If not requiring probe, trust NWPath and finalize now
        guard requireInternetProbe, probeURL != nil else {
            self.lastStatus = mapped                          // ✅ final truth
            scheduleNotifyIfNeeded(for: mapped)
            return
        }

        // Coalesce: avoid redundant concurrent probes.
        guard !probeInFlight else {
            if enableDebugLogging {
                print("[MRReachability] ⏳ Probe already in flight; skipping duplicate")
            }
            return
        }
        probeInFlight = true

        // Probe the internet before confirming "connected"
        checkInternetAvailability(retries: retryAttempts) { [weak self] isReachable in
            guard let self else { return }
            self.probeInFlight = false

            let finalStatus: Connection = isReachable ? mapped : .unavailable
            self.lastStatus = finalStatus                     // ✅ final truth BEFORE notifying

            if self.enableDebugLogging {
                print("[MRReachability] Probe result: \(isReachable ? "reachable ✅" : "unreachable ❌") → final:\(finalStatus)")
            }

            self.scheduleNotifyIfNeeded(for: finalStatus)
        }
    }

    // MARK: - Notification Scheduling with Cooldown Throttle

    private func scheduleNotifyIfNeeded(for status: Connection) {
        let now = Date()
        let sameAsLast = (status == self.lastNotifiedStatus)
        let cooldownNotMet = (now.timeIntervalSince(lastNotificationTime ?? .distantPast) < notificationCooldown)

        if sameAsLast && cooldownNotMet {
            if enableDebugLogging {
                print("[MRReachability] ⏱ Skipping duplicate '\(status)' (cooldown)")
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
            print("[MRReachability] 🔔 Status → \(status)")
        }

        switch status {
        case .unavailable:
            self.whenUnreachable?(self)
        case .wifi, .cellular:
            self.whenReachable?(self)
        }

        NotificationCenter.default.post(name: .reachabilityChanged, object: self)
    }

    // MARK: - Internet Reachability Check with Retry (Captive-portal-safe)

    private func checkInternetAvailability(retries: Int, completion: @escaping (Bool) -> Void) {
        guard let url = probeURL else { completion(false); return }

        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.httpMethod = "GET" // HEAD is flaky behind proxies/captive portals

        if enableDebugLogging {
            print("[MRReachability] 🌐 Probe attempt \(retryAttempts - retries + 1) → \(url.absoluteString)")
        }

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1

            // Captive-portal avoidance:
            let finalURLHost = http?.url?.host?.lowercased()
            let originalHost = url.host?.lowercased()
            let isRedirected = (finalURLHost != nil && originalHost != nil && finalURLHost != originalHost)
            let isHtml = (http?.mimeType?.lowercased() == "text/html")

            let success: Bool
            if self?.requireExact204ForProbe == true {
                // Strict mode: only 204 counts
                success = (code == 204)
            } else {
                // Lenient-but-safe:
                let okCode = (200...204).contains(code)
                let sameHost = !isRedirected
                let hasBody = (data?.isEmpty == false)
                success = okCode && sameHost && !isHtml && (code == 204 || hasBody || code == 200 || code == 201 || code == 202 || code == 203)
            }

            if success {
                DispatchQueue.main.async { completion(true) }
            } else if retries > 0 {
                let delay = self?.retryBackoff ?? 1.0
                if self?.enableDebugLogging == true {
                    print("[MRReachability] 🔁 Probe failed (code \(code), redirected:\(isRedirected), html:\(isHtml), err:\(String(describing: error))) — retrying in \(delay)s")
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    self?.checkInternetAvailability(retries: retries - 1, completion: completion)
                }
            } else {
                if self?.enableDebugLogging == true {
                    print("[MRReachability] ❌ Probe failed after all retries (code \(code), redirected:\(isRedirected), html:\(isHtml), err:\(String(describing: error)))")
                }
                DispatchQueue.main.async { completion(false) }
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
