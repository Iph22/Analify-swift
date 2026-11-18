import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import Analify

/// Answers every request with a chosen status and remembers the bodies, so tests see exactly what's sent.
final class FakeServer: URLProtocol {
    static var status = 202
    static var bodies: [[String: Any]] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {  // URLSession may hand the body over as a stream
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 65536)
            var collected = Data()
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                collected.append(buffer, count: n)
            }
            stream.close()
            data = collected
        }
        if let d = data, let json = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            FakeServer.lock.lock(); FakeServer.bodies.append(json); FakeServer.lock.unlock()
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: FakeServer.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class AnalifyTests: XCTestCase {
    var sdk: Analify!
    var queueFile: URL!
    var defaults: UserDefaults!

    override func setUp() {
        FakeServer.status = 202
        FakeServer.bodies = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FakeServer.self]
        queueFile = FileManager.default.temporaryDirectory.appendingPathComponent("analify-test-\(UUID().uuidString).json")
        defaults = UserDefaults(suiteName: "analify-tests-\(UUID().uuidString)")!
        sdk = Analify(session: URLSession(configuration: config), defaults: defaults, queueFile: queueFile)
        sdk.start(key: "AN-TEST", appVersion: "2.0.1", host: URL(string: "https://example.test")!, debug: false)
    }

    private func flush() {
        let done = expectation(description: "flushed")
        sdk.flush { done.fulfill() }
        wait(for: [done], timeout: 5)
    }

    func testScreensEventsAndUsersGoOutInOneBatch() throws {
        sdk.openedFrom(URL(string: "myapp://open?utm_source=newsletter&utm_campaign=launch")!)
        sdk.screen("Home", nil)
        sdk.track("note_saved", ["words": 120, "draft": true, "ratio": 0.5, "title": "Hi", "skipped": [1, 2]])
        sdk.identify("user-9")
        sdk.screen("Editor", nil)
        flush()

        XCTAssertEqual(FakeServer.bodies.count, 1)
        let body = FakeServer.bodies[0]
        XCTAssertEqual(body["key"] as? String, "AN-TEST")
        XCTAssertEqual(body["app_version"] as? String, "2.0.1")
        XCTAssertEqual((body["install"] as? String)?.count, 36)
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.map { $0["type"] as? String }, ["screen", "event", "identify", "screen"])
        XCTAssertEqual(events[0]["screen"] as? String, "Home")
        XCTAssertEqual(events[0]["utm_campaign"] as? String, "launch")  // the link's campaign, on the next screen only
        XCTAssertNil(events[3]["utm_campaign"])
        XCTAssertEqual(events[1]["screen"] as? String, "Home")          // events say which screen they happened on
        let props = try XCTUnwrap(events[1]["props"] as? [String: Any])
        XCTAssertEqual(props["words"] as? Int, 120)
        XCTAssertEqual(props["draft"] as? Bool, true)
        XCTAssertNil(props["skipped"])                                    // only text, numbers and true/false
        XCTAssertEqual(events[3]["uid"] as? String, "user-9")             // signed in from then on
        XCTAssertNil(events[0]["uid"])
        XCTAssertNotNil(Analify.iso.date(from: events[0]["at"] as? String ?? ""))
    }

    func testTheInstallIdStaysTheSame() {
        let first = defaults.string(forKey: Analify.installKey)
        XCTAssertNotNil(first)
        sdk.start(key: "AN-TEST", appVersion: nil, host: URL(string: "https://example.test")!, debug: false)
        XCTAssertEqual(defaults.string(forKey: Analify.installKey), first)
    }

    func testOfflineEventsAreKeptAndSentLater() {
        FakeServer.status = 503
        sdk.screen("Home", nil)
        flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: queueFile.path))  // kept on disk while it can't send
        FakeServer.status = 202
        FakeServer.bodies = []
        flush()
        XCTAssertEqual((FakeServer.bodies.first?["events"] as? [[String: Any]])?.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: queueFile.path))
    }

    func testRefusedEventsAreDropped() {
        FakeServer.status = 400  // e.g. a website's key
        sdk.track("x", nil)
        flush()
        FakeServer.bodies = []
        flush()
        XCTAssertTrue(FakeServer.bodies.isEmpty)
    }

    func testSignOutStopsSendingTheUser() throws {
        sdk.identify("user-9")
        sdk.identify(nil)
        sdk.screen("Home", nil)
        flush()
        let events = try XCTUnwrap(FakeServer.bodies.first?["events"] as? [[String: Any]])
        XCTAssertNil(events.last?["uid"])
    }

    func testLongQueuesGoInRequestsOfFifty() {
        FakeServer.status = 503
        for i in 0..<70 { sdk.track("e\(i)", nil) }  // fills past 20, so sends start and fail
        flush()
        FakeServer.status = 202
        FakeServer.bodies = []
        flush()
        XCTAssertEqual(FakeServer.bodies.map { ($0["events"] as? [[String: Any]])?.count ?? 0 }, [50, 20])
    }
}
