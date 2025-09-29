// MRReachability.swift
// NWPathMonitor-backed, legacy-style Reachability surface.
// Supported: iOS 12+ / macOS 10.14+ / tvOS 12+ / watchOS 5+
//


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
    
    /// Probe endpoint (Google 204 by default)
    public var probeURL: URL? = URL(string: "https://www.google.com/generate_204")
    
    /// Probe timeout
    public var probeTimeout: TimeInterval = 2.0
    
    /// Require exact 204 vs allow lenient 200…203
    public var requireExact204ForProbe: Bool = true
    
    /// Allow accepting 200 with empty body (for custom endpoints)
    public var acceptEmptyBody: Bool = false
    
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
    private var probeInFlight: Bool = false
    
    /// For canceling retries safely
    private var sessionID: UUID = UUID()
    
    // MARK: - Surface
    
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
        sessionID = UUID() // new session
        
        if enableDebugLogging {
            print("[MRReachability] Notifier started (v\(ReachabilityVersionString))")
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
        
        sessionID = UUID() // invalidate old retries
        monitor = NWPathMonitor() // recreate
        
        if enableDebugLogging {
            print("[MRReachability] Notifier stopped")
        }
    }
    
    // MARK: - Path Update
    
    private func handlePathUpdate(_ path: NWPath) {
        processPath(path)
    }
    
    private func processPath(_ path: NWPath) {
        let mapped = Self.map(path: path, allowsCellular: allowsCellularConnection)
        
        if enableDebugLogging {
            print("[MRReachability] Path update → mapped:\(mapped)")
        }
        
        guard mapped != .unavailable else {
            finalizeStatus(.unavailable)
            return
        }
        
        guard requireInternetProbe, probeURL != nil else {
            finalizeStatus(mapped)
            return
        }
        
        queue.async {
            guard !self.probeInFlight else {
                if self.enableDebugLogging {
                    print("[MRReachability] Probe already running")
                }
                return
            }
            self.probeInFlight = true
            let currentSession = self.sessionID
            
            self.checkInternetAvailability(retries: self.retryAttempts, session: currentSession) { isReachable in
                self.queue.async {
                    self.probeInFlight = false
                    guard currentSession == self.sessionID else { return } // ignore old
                    
                    let final: Connection = isReachable ? mapped : .unavailable
                    self.finalizeStatus(final)
                }
            }
        }
    }
    
    // MARK: - Status Handling
    
    private func finalizeStatus(_ status: Connection) {
        lastStatus = status
        scheduleNotifyIfNeeded(for: status)
    }
    
    private func scheduleNotifyIfNeeded(for status: Connection) {
        let now = Date()
        let sameAsLast = (status == self.lastNotifiedStatus)
        let cooldownNotMet = (now.timeIntervalSince(lastNotificationTime ?? .distantPast) < notificationCooldown)
        
        if sameAsLast && cooldownNotMet {
            return
        }
        
        let fireNow = { [weak self] in
            guard let self = self else { return }
            self.lastNotifiedStatus = status
            self.lastNotificationTime = Date()
            self.fireCallbacks(for: status)
        }
        
        if debounceInterval > 0 {
            debounceWorkItem?.cancel()
            let item = DispatchWorkItem(block: fireNow)
            debounceWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + debounceInterval, execute: item)
        } else {
            DispatchQueue.main.async(execute: fireNow)
        }
    }
    
    private func fireCallbacks(for status: Connection) {
        switch status {
        case .unavailable:
            self.whenUnreachable?(self)
        case .wifi, .cellular:
            self.whenReachable?(self)
        }
        NotificationCenter.default.post(name: .reachabilityChanged, object: self)
    }
    
    // MARK: - Internet Probe
    
    private func checkInternetAvailability(retries: Int, session: UUID, completion: @escaping (Bool) -> Void) {
        guard let url = probeURL else { completion(false); return }
        
        var request = URLRequest(url: url)
        request.timeoutInterval = probeTimeout
        request.httpMethod = "GET"
        
        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            guard session == self.sessionID else { return } // ignore old retries
            
            let http = response as? HTTPURLResponse
            let code = http?.statusCode ?? -1
            
            let finalURLHost = http?.url?.host?.lowercased()
            let originalHost = url.host?.lowercased()
            let isRedirected = (finalURLHost != nil && originalHost != nil && finalURLHost != originalHost)
            let isHtml = (http?.mimeType?.lowercased() == "text/html")
            
            let success: Bool
            if self.requireExact204ForProbe {
                success = (code == 204)
            } else {
                let sameHost = !isRedirected
                let hasBody = (data?.isEmpty == false) || self.acceptEmptyBody
                if code == 204 {
                    success = true
                } else {
                    success = (200...203).contains(code) && sameHost && !isHtml && hasBody
                }
            }
            
            if success {
                completion(true)
            } else if retries > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + self.retryBackoff) {
                    self.checkInternetAvailability(retries: retries - 1, session: session, completion: completion)
                }
            } else {
                completion(false)
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
