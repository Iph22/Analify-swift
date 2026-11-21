// Analify for iPhone, iPad and Mac apps: screens, events and signed-in users, privately.
// https://analify.dev/docs#apps
//
//     import Analify
//
//     Analify.start(key: "AN-XXXXXXXX")       // in your App's init or application(_:didFinishLaunchingWithOptions:)
//     Analify.screen("Home")                  // when a screen appears
//     Analify.track("note_saved", ["words": 120])
//     Analify.identify(user.id)               // after sign-in; Analify.identify(nil) on sign-out
//
// What it sends: the screen or event name, your properties, the app version, the operating system and whether it's
// a phone, tablet or computer. It keeps one random install ID in the app's own storage (no name, email, advertising
// ID or device identifier) so a returning user is counted once, and it holds events while the device is offline
// (up to 7 days). Events go in small batches every 10 seconds and when the app moves to the background.

import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif
#if canImport(AppKit) && os(macOS)
import AppKit
#endif

public final class Analify {
    /// The one shared instance. The static methods below use it.
    public static let shared = Analify()

    // MARK: - Public API

    /// Starts Analify. Call once, as early as possible.
    /// - Parameters:
    ///   - key: your app's key from Analify (AN-...). A website's key is refused.
    ///   - appVersion: shown as the app version in reports. Defaults to the app's CFBundleShortVersionString.
    ///   - host: your Analify address (default https://analify.dev).
    ///   - debug: prints what's sent.
    public static func start(key: String, appVersion: String? = nil,
                             host: URL = URL(string: "https://analify.dev")!, debug: Bool = false) {
        shared.start(key: key, appVersion: appVersion, host: host, debug: debug)
    }

    /// A screen came into view, e.g. "Home" or "Settings".
    public static func screen(_ name: String, _ props: [String: Any]? = nil) {
        shared.screen(name, props)
    }

    /// Something happened, e.g. `Analify.track("purchase", ["plan": "pro"])`.
    public static func track(_ name: String, _ props: [String: Any]? = nil) {
        shared.track(name, props)
    }

    /// The person signed in: your own user ID (Analify scrambles it before saving). `nil` when they sign out.
    public static func identify(_ userId: String?) {
        shared.identify(userId)
    }

    /// The app was opened from a link (universal link or URL scheme): its campaign counts for the next screen.
    public static func openedFrom(_ url: URL) {
        shared.openedFrom(url)
    }

    /// Sends what's waiting now. `completion` runs on a background queue when done.
    public static func flush(completion: (() -> Void)? = nil) {
        shared.flush(completion: completion)
    }

    // MARK: - Settings

    static let batchSize = 20      // send when this many events are waiting...
    static let interval = 10.0     // ...or this often (seconds)
    static let maxQueue = 500      // events kept while offline; the oldest go first
    static let perRequest = 50     // the server takes at most 50 events per request
    static let installKey = "analify_install"

    // MARK: - State (only touched on `queue`)

    private let queue = DispatchQueue(label: "dev.analify.sdk")
    private var config: Config?
    private var events: [Event] = []
    private var uid: String?
    private var currentScreen: String?
    private var campaign: Campaign?
    private var sending = false
    private var waiters: [() -> Void] = []  // flush completions waiting for the sending in progress
    private var timer: DispatchSourceTimer?
    private let session: URLSession
    private let defaults: UserDefaults
    private let queueFile: URL?

    struct Config {
        let key: String
        let appVersion: String?
        let endpoint: URL
        let debug: Bool
        let install: String
        let device: DeviceInfo
    }

    struct Campaign: Equatable {
        var referrer: String?
        var source: String?
        var medium: String?
        var name: String?
    }

    init(session: URLSession = .shared, defaults: UserDefaults = .standard, queueFile: URL? = Analify.defaultQueueFile()) {
        self.session = session
        self.defaults = defaults
        self.queueFile = queueFile
    }

    func start(key: String, appVersion: String?, host: URL, debug: Bool) {
        let device = Analify.deviceInfo()  // here, on the caller's (usually the main) thread
        queue.sync {
            let install = self.installId()
            let version = appVersion ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String)
            self.config = Config(key: key, appVersion: version, endpoint: host.appendingPathComponent("api/app/events"),
                                 debug: debug, install: install, device: device)
            self.events = self.loadQueue() + self.events  // anything left from last time
            self.startTimer()
        }
        observeLifecycle()
        log("started")
    }

    func screen(_ name: String, _ props: [String: Any]?) {
        queue.async {
            let screen = String(name.prefix(300))
            self.currentScreen = screen
            var e = Event(type: "screen", screen: screen, props: Analify.clean(props), uid: self.uid)
            if let c = self.campaign {
                e.referrer = c.referrer; e.utmSource = c.source; e.utmMedium = c.medium; e.utmCampaign = c.name
                self.campaign = nil
            }
            self.push(e)
        }
    }

    func track(_ name: String, _ props: [String: Any]?) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        queue.async {
            self.push(Event(type: "event", name: String(trimmed.prefix(120)), screen: self.currentScreen,
                            props: Analify.clean(props), uid: self.uid))
        }
    }

    func identify(_ userId: String?) {
        queue.async {
            guard let id = userId, !id.isEmpty else { self.uid = nil; return }
            self.uid = String(id.prefix(255))
            self.push(Event(type: "identify", uid: self.uid))
        }
    }

    func openedFrom(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        let c = Campaign(referrer: value("ref") ?? value("referrer"), source: value("utm_source"),
                         medium: value("utm_medium"), name: value("utm_campaign"))
        queue.async { self.campaign = c }
    }

    /// The app moved to the background: counts the time on the last screen and sends what's waiting.
    func background(completion: (() -> Void)? = nil) {
        queue.async {
            self.push(Event(type: "engagement", uid: self.uid), sendIfFull: false)
            self.saveQueue()
            self.send(completion: completion)
        }
    }

    func flush(completion: (() -> Void)? = nil) {
        queue.async { self.send(completion: completion) }
    }

    // MARK: - Queue

    private func push(_ event: Event, sendIfFull: Bool = true) {
        guard config != nil else { return log("call Analify.start first") }
        events.append(event)
        if events.count > Analify.maxQueue { events.removeFirst(events.count - Analify.maxQueue) }
        if sendIfFull && events.count >= Analify.batchSize { send(completion: nil) }
    }

    /// Sends the waiting events, 50 at a time. Runs on `queue`. `completion` runs once this round of sending is
    /// over (everything sent, or the network failed), even if another send was already in progress.
    private func send(completion: (() -> Void)?) {
        if let c = completion { waiters.append(c) }
        if sending { return }  // the send in progress finishes the waiters
        guard let config = config, !events.isEmpty else { return finishWaiters() }
        sending = true
        let batch = Array(events.prefix(Analify.perRequest))
        var request = URLRequest(url: config.endpoint)
        request.httpMethod = "POST"
        request.setValue("text/plain", forHTTPHeaderField: "Content-Type")
        request.httpBody = Analify.body(config: config, events: batch, device: config.device)
        session.dataTask(with: request) { data, response, error in
            self.queue.async {
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                if error != nil || status == 0 || status == 429 || status >= 500 {
                    self.log("couldn't send (\(error.map { "\($0)" } ?? "status \(status)")), will retry")
                    self.saveQueue()
                    self.sending = false
                    self.finishWaiters()
                    return
                }
                self.events.removeFirst(min(batch.count, self.events.count))
                if status >= 400 {
                    let detail = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["detail"]
                    print("[analify] events refused: \(status) \(detail ?? "")")
                } else {
                    self.log("sent \(batch.count)")
                }
                self.saveQueue()
                self.sending = false
                if self.events.isEmpty { self.finishWaiters() } else { self.send(completion: nil) }
            }
        }.resume()
    }

    private func finishWaiters() {
        let done = waiters
        waiters = []
        done.forEach { $0() }
    }

    private func startTimer() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + Analify.interval, repeating: Analify.interval)
        t.setEventHandler { [weak self] in self?.send(completion: nil) }
        t.resume()
        timer = t
    }

    // MARK: - Install ID and offline queue

    private func installId() -> String {
        if let id = defaults.string(forKey: Analify.installKey), id.count >= 8 { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Analify.installKey)
        return id
    }

    static func defaultQueueFile() -> URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return dir.appendingPathComponent("analify-queue.json")
    }

    private func saveQueue() {
        guard let file = queueFile else { return }
        do {
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if events.isEmpty {
                try? FileManager.default.removeItem(at: file)
            } else {
                try JSONEncoder().encode(events).write(to: file, options: .atomic)
            }
        } catch {
            log("couldn't save the offline queue: \(error)")
        }
    }

    private func loadQueue() -> [Event] {
        guard let file = queueFile, let data = try? Data(contentsOf: file),
              let saved = try? JSONDecoder().decode([Event].self, from: data) else { return [] }
        try? FileManager.default.removeItem(at: file)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        return saved.filter { $0.at > cutoff }
    }

    // MARK: - App lifecycle

    private var observing = false

    private func observeLifecycle() {
        guard !observing else { return }
        observing = true
        #if canImport(UIKit) && !os(watchOS)
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: nil) { [weak self] _ in
            guard let self = self else { return }
            // Ask iOS for a few seconds so the last batch gets out before the app is suspended.
            var task = UIBackgroundTaskIdentifier.invalid
            task = UIApplication.shared.beginBackgroundTask(withName: "analify-flush") {
                UIApplication.shared.endBackgroundTask(task)
                task = .invalid
            }
            self.background {
                DispatchQueue.main.async {
                    if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
                }
            }
        }
        center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flush()
        }
        #elseif canImport(AppKit) && os(macOS)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: nil) { [weak self] _ in
            self?.background()
        }
        center.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.queue.sync { self?.saveQueue() }
        }
        #endif
    }

    // MARK: - Payload

    struct Event: Codable, Equatable {
        var type: String
        var name: String?
        var screen: String?
        var props: [String: PropValue]?
        var uid: String?
        var at: Date = Date()
        var referrer: String?
        var utmSource: String?
        var utmMedium: String?
        var utmCampaign: String?

        init(type: String, name: String? = nil, screen: String? = nil, props: [String: PropValue]? = nil, uid: String? = nil) {
            self.type = type; self.name = name; self.screen = screen; self.props = props; self.uid = uid
        }

        enum CodingKeys: String, CodingKey {
            case type, name, screen, props, uid, at, referrer
            case utmSource = "utm_source", utmMedium = "utm_medium", utmCampaign = "utm_campaign"
        }
    }

    /// Property values Analify keeps: text, numbers and true/false.
    enum PropValue: Codable, Equatable {
        case string(String), int(Int), double(Double), bool(Bool)

        func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            switch self {
            case .string(let v): try c.encode(v)
            case .int(let v): try c.encode(v)
            case .double(let v): try c.encode(v)
            case .bool(let v): try c.encode(v)
            }
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let v = try? c.decode(Bool.self) { self = .bool(v) }
            else if let v = try? c.decode(Int.self) { self = .int(v) }
            else if let v = try? c.decode(Double.self) { self = .double(v) }
            else { self = .string(try c.decode(String.self)) }
        }
    }

    /// Keeps text, numbers and true/false (at most 30 properties, text up to 500 characters); drops the rest.
    static func clean(_ props: [String: Any]?) -> [String: PropValue]? {
        guard let props = props else { return nil }
        var out: [String: PropValue] = [:]
        for key in props.keys.sorted() {
            guard out.count < 30 else { break }
            switch props[key] {
            case let v as Bool: out[key] = .bool(v)
            case let v as Int: out[key] = .int(v)
            case let v as Double: out[key] = .double(v)
            case let v as Float: out[key] = .double(Double(v))
            case let v as String: out[key] = .string(String(v.prefix(500)))
            default: continue
            }
        }
        return out.isEmpty ? nil : out
    }

    struct DeviceInfo: Equatable {
        let os: String
        let device: String  // "mobile", "tablet" or "desktop"
        var model: String? = Analify.hardwareModel()  // e.g. "iPhone16,1"; Analify shows it as "iPhone 15 Pro"
    }

    /** The hardware identifier ("iPhone16,1", "Mac14,2"). On the simulator, the simulated device's. */
    static func hardwareModel() -> String? {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return simulated }
        #if os(Linux) || os(Windows)
        return nil
        #else
        var info = utsname()
        uname(&info)
        let id = withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        return id.isEmpty ? nil : id
        #endif
    }

    static func deviceInfo() -> DeviceInfo {
        #if os(iOS)
        // UIDevice belongs to the main thread; off it (start called elsewhere), assume a phone.
        if Thread.isMainThread && UIDevice.current.userInterfaceIdiom == .pad {
            return DeviceInfo(os: "ipados", device: "tablet")
        }
        return DeviceInfo(os: "ios", device: "mobile")
        #elseif os(macOS)
        return DeviceInfo(os: "macos", device: "desktop")
        #elseif os(tvOS)
        return DeviceInfo(os: "tvos", device: "desktop")
        #elseif os(watchOS)
        return DeviceInfo(os: "watchos", device: "mobile")
        #elseif os(Linux)
        return DeviceInfo(os: "linux", device: "desktop")
        #elseif os(Windows)
        return DeviceInfo(os: "windows", device: "desktop")
        #else
        return DeviceInfo(os: "unknown", device: "desktop")
        #endif
    }

    static func body(config: Config, events: [Event], device: DeviceInfo) -> Data {
        struct Batch: Encodable {
            let key: String
            let install: String
            let app_version: String?
            let os: String
            let device: String
            let model: String?
            let events: [Event]
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(Analify.iso.string(from: date))
        }
        let batch = Batch(key: config.key, install: config.install, app_version: config.appVersion,
                          os: device.os, device: device.device, model: device.model, events: events)
        return (try? encoder.encode(batch)) ?? Data()
    }

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private func log(_ message: String) {
        if config?.debug == true { print("[analify] \(message)") }
    }
}
