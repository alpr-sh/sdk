import Foundation
import XCTest

@testable import Alpr

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Network)
    import Network
#endif

/// A value shared between a fake transport and the test, behind a lock.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func update(_ change: (inout Value) -> Void) {
        lock.withLock { change(&value) }
    }

    var current: Value {
        lock.withLock { value }
    }
}

/// The requests a fake transport was sent.
final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.withLock { requests.append(request) }
    }

    var seen: [URLRequest] {
        lock.withLock { requests }
    }
}

typealias Answer = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: String)

let key = "alpr_live_" + "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

func client(_ answer: @escaping Answer) -> (AlprClient, Recorder) {
    let recorder = Recorder()
    let transport: AlprTransport = { request in
        recorder.append(request)
        let (status, headers, body) = answer(request)
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (Data(body.utf8), response)
    }
    return (AlprClient(apiKey: key, baseURL: URL(string: "https://alpr.test/")!, transport: transport), recorder)
}

func queryItem(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

// jpeg and png start with the bytes the API tells them by.
let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x01])
let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52])

let recognized = #"{"creditsRemaining":41,"imageHeight":720,"imageWidth":1280,"plates":[{"charConfs":"0.99,0.98,0.97,0.96,0.97,0.96,0.96","conf":97.3,"coordinateBottom":361,"coordinateLeft":120,"coordinateRight":300,"coordinateTop":301,"createdAt":"2026-10-22T12:00:00-03:00","plate":"BRA2E19","plateType":"mercosul","time":"2026-10-22T12:00:00-03:00"}],"processingTimeMs":84}"#

/// One part of a multipart body.
struct FormPart {
    let name: String
    let filename: String?
    let contentType: String?
    let data: Data
}

/// Reads a multipart/form-data body.
func parseMultipart(_ body: Data, contentType: String) -> [FormPart] {
    guard let boundary = contentType.components(separatedBy: "boundary=").dropFirst().first else { return [] }
    let delimiter = Data("--\(boundary)".utf8)
    var starts: [Data.Index] = []
    var from = body.startIndex
    while let found = body.range(of: delimiter, in: from..<body.endIndex) {
        starts.append(found.lowerBound)
        from = found.upperBound
    }
    var parts: [FormPart] = []
    for (index, start) in starts.enumerated().dropLast() {
        let segment = Data(body[(start + delimiter.count)..<starts[index + 1]])
        // Each segment starts with CRLF and ends with the CRLF before the next delimiter.
        let inner = Data(segment.dropFirst(2).dropLast(2))
        guard let split = inner.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let head = String(decoding: inner[..<split.lowerBound], as: UTF8.self)
        func attribute(_ line: String, _ name: String) -> String? {
            guard let found = line.range(of: "; \(name)=\"") else { return nil }
            return String(line[found.upperBound...].prefix { $0 != "\"" })
        }
        var name = "", filename: String?, contentType: String?
        for line in head.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-disposition:") {
                name = attribute(line, "name") ?? ""
                filename = attribute(line, "filename")
            } else if line.lowercased().hasPrefix("content-type:") {
                contentType = String(line.dropFirst("content-type:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        parts.append(FormPart(name: name, filename: filename, contentType: contentType, data: Data(inner[split.upperBound...])))
    }
    return parts
}

final class AlprTests: XCTestCase {
    func testACallCarriesTheKeyAndNoIdempotencyKey() async throws {
        let (alpr, recorder) = client { _ in
            (200, [:], #"{"data":[{"createdAt":"2026-10-01T09:00:00-03:00","enabled":true,"id":"cam_1","location":"Portaria","name":"Portão","protocol":"rtsp","readingArea":null},{"createdAt":"2026-10-01T09:00:00-03:00","enabled":false,"id":"cam_2","location":"","name":"Garagem","protocol":"rtsp","readingArea":{"box":{"height":0.5,"width":0.5,"x":0.1,"y":0.2},"points":[[0.1,0.2],[0.6,0.2],[0.6,0.7]]}}]}"#)
        }
        let cameras = try await alpr.cameras.list()
        let seen = try XCTUnwrap(recorder.seen.first)
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.url?.path, "/api/v1/cameras")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "User-Agent"), "alpr-swift/\(AlprClient.version)")
        XCTAssertTrue(seen.value(forHTTPHeaderField: "User-Agent")?.hasPrefix("alpr-swift/") == true)
        XCTAssertNil(seen.value(forHTTPHeaderField: "Idempotency-Key"))
        XCTAssertEqual(cameras.count, 2)
        XCTAssertEqual(cameras[0].id, "cam_1")
        XCTAssertTrue(cameras[0].enabled)
        XCTAssertNil(cameras[0].readingArea)
        let area = try XCTUnwrap(cameras[1].readingArea)
        XCTAssertEqual(area.box.x, 0.1)
        XCTAssertEqual(area.points.count, 3)
        XCTAssertEqual(area.points[1][0], 0.6)
    }

    func testAPhotoGoesAsMultipart() async throws {
        let (alpr, recorder) = client { _ in (200, [:], recognized) }
        let result = try await alpr.photos.recognize(PhotosRecognizeParams(image: jpeg, lprConfidence: 0.5))
        let seen = try XCTUnwrap(recorder.seen.first)
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.url?.path, "/api/v1/recognize")
        let contentType = try XCTUnwrap(seen.value(forHTTPHeaderField: "Content-Type"))
        XCTAssertTrue(contentType.hasPrefix("multipart/form-data; boundary="), contentType)
        let parts = parseMultipart(try XCTUnwrap(seen.httpBody), contentType: contentType)
        XCTAssertEqual(parts.map(\.name), ["image", "lpr_confidence"])
        XCTAssertEqual(parts[0].data, jpeg)
        XCTAssertEqual(parts[0].filename, "photo.jpg")
        XCTAssertEqual(parts[0].contentType, "image/jpeg")
        XCTAssertEqual(String(decoding: parts[1].data, as: UTF8.self), "0.5")
        XCTAssertNil(parts[1].filename)
        // min_ocr_confidence was left out and is not sent.
        XCTAssertFalse(parts.contains { $0.name == "min_ocr_confidence" })
        XCTAssertEqual(result.creditsRemaining, 41)
        XCTAssertEqual(result.plates.count, 1)
        XCTAssertEqual(result.plates[0].plate, "BRA2E19")
        XCTAssertEqual(result.plates[0].conf, 97.3)
        XCTAssertEqual(result.plates[0].coordinateLeft, 120)
    }

    func testAPhotoIsNamedByItsBytes() async throws {
        let cases: [(String, Data, String, String)] = [
            ("jpeg", jpeg, "photo.jpg", "image/jpeg"),
            ("png", png, "photo.png", "image/png"),
            ("other", Data("not an image".utf8), "photo", "application/octet-stream"),
            ("empty", Data(), "photo", "application/octet-stream"),
        ]
        for (name, data, filename, kind) in cases {
            let (alpr, recorder) = client { _ in (200, [:], #"{"imageHeight":10,"imageWidth":20,"plates":[],"processingTimeMs":3}"#) }
            let result = try await alpr.photos.detect(PhotosDetectParams(image: data))
            XCTAssertEqual(result.imageWidth, 20, name)
            XCTAssertTrue(result.plates.isEmpty, name)
            let seen = try XCTUnwrap(recorder.seen.first)
            XCTAssertEqual(seen.url?.path, "/api/v1/detect", name)
            let parts = parseMultipart(try XCTUnwrap(seen.httpBody), contentType: try XCTUnwrap(seen.value(forHTTPHeaderField: "Content-Type")))
            XCTAssertEqual(parts.count, 1, name)
            XCTAssertEqual(parts[0].data, data, name)
            XCTAssertEqual(parts[0].filename, filename, name)
            XCTAssertEqual(parts[0].contentType, kind, name)
        }
    }

    func testAPlateImageIsReadByOCR() async throws {
        let (alpr, recorder) = client { _ in (200, [:], #"{"confidence":0.91,"creditsRemaining":40,"detectionId":null,"latencyMs":12,"plate":"ABC1234"}"#) }
        let result = try await alpr.photos.ocr(PhotosOCRParams(image: png))
        XCTAssertEqual(recorder.seen.first?.url?.path, "/api/v1/ocr")
        XCTAssertEqual(result.plate, "ABC1234")
        XCTAssertNil(result.detectionID)
        XCTAssertEqual(result.confidence, 0.91)
    }

    func testADetectionImageIsALink() async throws {
        let (alpr, recorder) = client { _ in
            (200, [:], #"{"detectionId":"a/b","expiresIn":300,"imageUrl":"https://alpr.sh/api/v1/detections/a/image/file?s=x"}"#)
        }
        let image = try await alpr.recognitions.image("a/b")
        let seen = try XCTUnwrap(recorder.seen.first)
        XCTAssertEqual(URLComponents(url: try XCTUnwrap(seen.url), resolvingAgainstBaseURL: false)?.percentEncodedPath, "/api/v1/detections/a%2Fb/image")
        XCTAssertEqual(image.expiresIn, 300)
        XCTAssertEqual(image.detectionID, "a/b")
        XCTAssertTrue(image.imageURL.hasPrefix("https://alpr.sh/"))
    }

    func testIteratingWalksEveryPageByCursor() async throws {
        @Sendable func item(_ id: String) -> String {
            #"{"cameraId":null,"capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"\#(id)","plate":"BRA2E19","source":"api"}"#
        }
        let (alpr, recorder) = client { request in
            switch queryItem(request, "before") {
            case nil: return (200, [:], #"{"data":[\#(item("r3")),\#(item("r2"))],"next":"c2"}"#)
            case "c2": return (200, [:], #"{"data":[\#(item("r1"))],"next":null}"#)
            default: return (500, [:], "{}")
            }
        }
        var ids: [String] = []
        for try await reading in alpr.recognitions.listIter(RecognitionsListParams(plate: "BRA", source: "api")) {
            ids.append(reading.id)
        }
        XCTAssertEqual(ids, ["r3", "r2", "r1"])
        let asked = recorder.seen.map { "\(queryItem($0, "before") ?? "")|\(queryItem($0, "plate") ?? "")|\(queryItem($0, "source") ?? "")" }
        XCTAssertEqual(asked, ["|BRA|api", "c2|BRA|api"])
        XCTAssertNil(queryItem(recorder.seen[0], "before"))
        XCTAssertEqual(recorder.seen[0].url?.path, "/api/v1/recognitions")

        let page = try await alpr.recognitions.list(RecognitionsListParams(before: "c2"))
        XCTAssertEqual(page.items.count, 1)
        XCTAssertNil(page.next)
        XCTAssertNil(page.items[0].cameraID)
        XCTAssertEqual(page.items[0].source, .api)
        XCTAssertEqual(queryItem(recorder.seen[2], "before"), "c2")
    }

    func testAnIterationStartsFromTheCursorGiven() async throws {
        let (alpr, recorder) = client { _ in (200, [:], #"{"data":[],"next":null}"#) }
        for try await _ in alpr.recognitions.listIter(RecognitionsListParams(before: "mid")) {}
        XCTAssertEqual(recorder.seen.count, 1)
        XCTAssertEqual(queryItem(recorder.seen[0], "before"), "mid")
    }

    func testACursorThatDoesNotMoveEndsTheWalk() async throws {
        let (alpr, recorder) = client { _ in
            (200, [:], #"{"data":[{"cameraId":"cam_1","capturedAt":"2026-10-22T12:00:00-03:00","conf":90,"id":"r1","plate":"ABC1234","source":"camera"}],"next":"same"}"#)
        }
        var count = 0
        for try await _ in alpr.recognitions.listIter() {
            count += 1
        }
        XCTAssertEqual(count, 2)
        XCTAssertEqual(recorder.seen.count, 2)
    }

    func testAnIterationEndsAtTheFirstError() async throws {
        let calls = Box(0)
        let (alpr, _) = client { _ in
            calls.update { $0 += 1 }
            if calls.current == 1 {
                return (200, [:], #"{"data":[{"cameraId":null,"capturedAt":"x","conf":90,"id":"r1","plate":"ABC1234","source":"api"}],"next":"c2"}"#)
            }
            return (503, [:], #"{"error":"engine_unavailable","message":"later"}"#)
        }
        var ids: [String] = []
        do {
            for try await reading in alpr.recognitions.listIter() {
                ids.append(reading.id)
            }
            XCTFail("the error did not end the walk")
        } catch let refused as AlprError {
            XCTAssertEqual(refused.status, 503)
        }
        XCTAssertEqual(ids, ["r1"])
        XCTAssertEqual(calls.current, 2)
    }

    func testARefusalIsATypedError() async throws {
        let (alpr, _) = client { request in
            switch request.url?.path {
            case "/api/v1/recognize":
                return (402, [:], #"{"error":"insufficient_credits","message":"This workspace has no credits left."}"#)
            case "/api/v1/cameras":
                return (429, ["Retry-After": "7"], #"{"error":"rate_limited","message":"Too many requests."}"#)
            default:
                return (502, [:], "<html>bad gateway</html>")
            }
        }
        do {
            _ = try await alpr.photos.recognize(PhotosRecognizeParams(image: jpeg))
            XCTFail("a 402 was not refused")
        } catch let refused as AlprError {
            XCTAssertEqual(refused.status, 402)
            XCTAssertEqual(refused.code, "insufficient_credits")
            XCTAssertEqual(refused.message, "This workspace has no credits left.")
            XCTAssertTrue(refused.fields.isEmpty)
            XCTAssertNil(refused.retryAfter)
        }
        do {
            _ = try await alpr.cameras.list()
            XCTFail("a 429 was not refused")
        } catch let limited as AlprError {
            XCTAssertEqual(limited.status, 429)
            XCTAssertEqual(limited.code, "rate_limited")
            XCTAssertEqual(limited.retryAfter, 7)
        }
        do {
            _ = try await alpr.recognitions.image("x")
            XCTFail("a 502 was not refused")
        } catch let broken as AlprError {
            XCTAssertEqual(broken.status, 502)
            XCTAssertEqual(broken.code, "")
        }
    }

    func testACallCanUseAnotherKey() async throws {
        let (alpr, recorder) = client { _ in (200, [:], #"{"data":[]}"#) }
        _ = try await alpr.cameras.list(apiKey: "alpr_live_other")
        _ = try await alpr.cameras.list()
        XCTAssertEqual(recorder.seen[0].value(forHTTPHeaderField: "Authorization"), "Bearer alpr_live_other")
        XCTAssertEqual(recorder.seen[1].value(forHTTPHeaderField: "Authorization"), "Bearer \(key)")
    }

    func testABaseURLMustBeHTTPSUnlessItIsLoopback() async throws {
        let accepted = ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]
        let refused = ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "alpr.sh", "http://[::2]"]
        for base in accepted + refused {
            let recorder = Recorder()
            let transport: AlprTransport = { request in
                recorder.append(request)
                return (Data(#"{"data":[]}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            let alpr = AlprClient(apiKey: key, baseURL: URL(string: base)!, transport: transport)
            do {
                _ = try await alpr.cameras.list()
                XCTAssertTrue(accepted.contains(base), base)
            } catch let error as AlprError {
                XCTAssertTrue(refused.contains(base), base)
                XCTAssertEqual(error.code, "insecure_base_url")
                XCTAssertEqual(recorder.seen.count, 0, base)
            }
        }
    }

    #if canImport(Network)
        func testARedirectIsRefusedAndTheKeyNeverFollowsIt() async throws {
            let elsewhereHits = Box(0)
            let elsewhere = try LocalServer { _ in
                elsewhereHits.update { $0 += 1 }
                return LocalServer.response(200, body: "{}")
            }
            let elsewherePort = try await elsewhere.start()
            defer { elsewhere.stop() }
            let server = try LocalServer { _ in
                LocalServer.response(302, headers: ["Location": "http://127.0.0.1:\(elsewherePort)/steal"])
            }
            let port = try await server.start()
            defer { server.stop() }
            let alpr = AlprClient(apiKey: key, baseURL: URL(string: "http://127.0.0.1:\(port)")!)
            do {
                _ = try await alpr.cameras.list()
                XCTFail("a redirect was not refused")
            } catch let refused as AlprError {
                XCTAssertEqual(refused.status, 302)
            }
            XCTAssertEqual(elsewhereHits.current, 0)
        }

        func testThePhotoCrossesTheRealHTTPAsMultipart() async throws {
            let received = Box<LocalServer.Request?>(nil)
            let server = try LocalServer { request in
                received.update { $0 = request }
                if request.headers["authorization"] != "Bearer \(key)" {
                    return LocalServer.response(401, headers: ["Retry-After": "3"], body: #"{"error":"invalid_api_key","message":"no"}"#)
                }
                return LocalServer.response(200, body: recognized)
            }
            let port = try await server.start()
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(port)")!
            let result = try await AlprClient(apiKey: key, baseURL: base).photos.recognize(PhotosRecognizeParams(image: jpeg, minOCRConfidence: 0.25))
            XCTAssertEqual(result.plates.first?.plate, "BRA2E19")
            let request = try XCTUnwrap(received.current)
            XCTAssertEqual(request.method, "POST")
            XCTAssertEqual(request.target, "/api/v1/recognize")
            let parts = parseMultipart(request.body, contentType: try XCTUnwrap(request.headers["content-type"]))
            XCTAssertEqual(parts.map(\.name), ["image", "min_ocr_confidence"])
            XCTAssertEqual(parts[0].data, jpeg)
            XCTAssertEqual(String(decoding: parts[1].data, as: UTF8.self), "0.25")
            do {
                _ = try await AlprClient(apiKey: "alpr_live_wrong", baseURL: base).photos.recognize(PhotosRecognizeParams(image: jpeg))
                XCTFail("a 401 was not refused")
            } catch let refused as AlprError {
                XCTAssertEqual(refused.status, 401)
                XCTAssertEqual(refused.code, "invalid_api_key")
                XCTAssertEqual(refused.retryAfter, 3)
            }
        }
    #endif

    #if canImport(CryptoKit)
        // The webhook vectors every SDK checks (generator/testdata/webhook-vectors.json):
        // Alpr.sh events signed under two secrets, as while one is rotated.
        static let newSecret = "whsec_SDK-test-secret-new-0123456789"
        static let oldSecret = "whsec_SDK-test-secret-old-0123456789"
        static let otherSecret = "whsec_SDK-test-secret-other-012345678"
        static let thirdSecret = "whsec_SDK-test-secret-third-01234567"
        static let signedAt = "1792670400"

        static let recognitionBody = #"{"event":"recognition.created","id":"rec_1","tenant_id":"ws_1","source":"camera","camera_id":"cam_1","plate":"BRA2E19","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}"#
        static let recognitionNew = "sha256=97deaf1c8a9348f3a7d64ce68943f4e6b4cc44590df4caea4c16d6373fa7d623"
        static let recognitionOld = "sha256=12b70f2a8838157260e3b9470befa2627c16c42fe5e4b1d80fb841e206f8c781"
        static let alertBody = #"{"event":"alert.triggered","id":"alt_1","tenant_id":"ws_1","rule_id":"rule_1","rule_name":"Veículo bloqueado","recognition_id":"rec_1","plate":"BRA2E19","camera_id":"cam_1","confidence":0.97,"captured_at":"2026-10-22T11:59:58Z"}"#
        static let alertNew = "sha256=0b84627fa4564b006237b52feca68ca3c8dfebc54d4e271e881105f75e2a962a"
        static let testBody = #"{"event":"webhook.test","id":"evt_1","tenant_id":"ws_1","sent_at":"2026-10-22T12:00:00Z"}"#
        static let testNew = "sha256=f3064f502ba3ffe3e409d9186c89ce7e425ad1dcad34b73edbeb1ad8e0633245"
        static let unknownBody = #"{"event":"payout.sent","id":"po_1","tenant_id":"ws_1"}"#
        static let unknownNew = "sha256=cb5b4f83462c974ea9706723b97a28de5d591d2093aa62e8dc8e388997daa0d6"
        static let plusSignature = "sha256=ceef0f02180106de386c85b403f2b448142e897911c1e6075725b7e8d2912771"

        /// The three headers of a delivery; a signature each, as repeated lines.
        func lines(_ id: String, _ stamp: String, _ signatures: String...) -> [(String, String)] {
            [("x-alprsh-delivery-id", id), ("X-Alprsh-Timestamp", stamp)] + signatures.map { ("X-Alprsh-Signature", $0) }
        }

        func refused(_ secret: String, _ headers: [(String, String)], _ body: Data, _ now: Date, _ what: String) {
            XCTAssertThrowsError(try verifyWebhookSignatureAt(secret: secret, headers: headers, body: body, now: now), what) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature, what)
            }
        }

        let now = Date(timeIntervalSince1970: 1_792_670_400 + 120)

        func testTheWebhookVectorVerifies() throws {
            let body = Data(Self.recognitionBody.utf8)
            let headers = lines("del_0001", Self.signedAt, Self.recognitionNew)
            try verifyWebhookSignatureAt(secret: Self.newSecret, headers: headers, body: body, now: now)
            // The same through the dictionary of a web stack, in any case.
            try verifyWebhookSignatureAt(
                secret: Self.newSecret,
                headers: ["X-ALPRSH-DELIVERY-ID": "del_0001", "x-alprsh-timestamp": Self.signedAt, "x-alprsh-signature": Self.recognitionNew],
                body: body, now: now)
            refused(Self.newSecret, headers, body + Data(" ".utf8), now, "a changed body")
            refused(Self.newSecret, lines("del_0009", Self.signedAt, Self.recognitionNew), body, now, "another delivery id")
            refused(Self.newSecret, headers, body, Date(timeIntervalSince1970: 1_792_670_400 + 301), "a stale webhook")
            refused(Self.newSecret, headers, body, Date(timeIntervalSince1970: 1_792_670_400 - 301), "a webhook from the future")
            try verifyWebhookSignatureAt(secret: Self.newSecret, headers: headers, body: body, now: Date(timeIntervalSince1970: 1_792_670_400 + 300))
            refused(Self.otherSecret, headers, body, now, "another secret")
            refused(Self.newSecret, [], body, now, "no headers")
            refused(Self.newSecret, lines("", Self.signedAt, Self.recognitionNew), body, now, "no delivery id")
            XCTAssertThrowsError(try verifyWebhookSignatureAt(secret: "", headers: headers, body: body, now: now)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .emptySecret)
            }
            // The public call checks against the real clock: a 2026-10-22 delivery is stale by now.
            XCTAssertThrowsError(try verifyWebhookSignature(secret: Self.newSecret, headers: ["X-Alprsh-Delivery-Id": "del_0001", "X-Alprsh-Timestamp": Self.signedAt, "X-Alprsh-Signature": Self.recognitionNew], body: body)) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
            }
        }

        func testATimestampThatIsNotPlainDigitsIsRefused() throws {
            let body = Data(Self.recognitionBody.utf8)
            for stamp in ["+1792670400", "²", "", "1_7", " 1792670400", "1792670400 "] {
                refused(Self.newSecret, lines("del_0001", stamp, Self.plusSignature), body, now, "timestamp \(stamp.debugDescription)")
            }
        }

        func testMoreThanOneSignatureVerifiesDuringARotation() throws {
            let body = Data(Self.recognitionBody.utf8)
            let rotations: [(String, [(String, String)])] = [
                ("one value", lines("del_0001", Self.signedAt, Self.recognitionOld + "," + Self.recognitionNew)),
                ("two lines", lines("del_0001", Self.signedAt, Self.recognitionOld, Self.recognitionNew)),
                ("with spaces", lines("del_0001", Self.signedAt, Self.recognitionOld + ", " + Self.recognitionNew)),
            ]
            for (name, headers) in rotations {
                for secret in [Self.newSecret, Self.oldSecret] {
                    try verifyWebhookSignatureAt(secret: secret, headers: headers, body: body, now: now)
                }
                refused(Self.thirdSecret, headers, body, now, "\(name): a secret that signed nothing")
            }
            let malformed: [(String, String)] = [
                ("a malformed one beside a good one", "sha256=zz," + Self.recognitionNew),
                ("no prefix", String(Self.recognitionNew.dropFirst("sha256=".count))),
                ("a short one", "sha256=97de"),
                ("an empty entry", Self.recognitionNew + ","),
                ("too many", String(repeating: Self.recognitionOld + ",", count: 6) + Self.recognitionNew),
            ]
            for (name, signature) in malformed {
                refused(Self.newSecret, lines("del_0001", Self.signedAt, signature), body, now, name)
            }
            // Six entries are the most a request may list.
            try verifyWebhookSignatureAt(
                secret: Self.newSecret, headers: lines("del_0001", Self.signedAt, String(repeating: Self.recognitionOld + ",", count: 5) + Self.recognitionNew), body: body, now: now)
        }

        func testAWebhookAnswersItsTypedEvent() throws {
            let event = try verifyWebhookAt(
                secret: Self.newSecret, headers: lines("del_0001", Self.signedAt, Self.recognitionNew), body: Data(Self.recognitionBody.utf8), now: now)
            guard case let .recognitionCreated(reading) = event else { return XCTFail("not a recognition event") }
            XCTAssertEqual(event.eventName, "recognition.created")
            XCTAssertEqual(reading.id, "rec_1")
            XCTAssertEqual(reading.plate, "BRA2E19")
            XCTAssertEqual(reading.confidence, 0.97)
            XCTAssertEqual(reading.cameraID, "cam_1")
            XCTAssertEqual(reading.source, .camera)
            XCTAssertEqual(reading.tenantID, "ws_1")
            XCTAssertEqual(reading.capturedAt, "2026-10-22T11:59:58Z")

            let alertEvent = try verifyWebhookAt(
                secret: Self.newSecret, headers: lines("del_0002", Self.signedAt, Self.alertNew), body: Data(Self.alertBody.utf8), now: now)
            guard case let .alertTriggered(alert) = alertEvent else { return XCTFail("not an alert event") }
            XCTAssertEqual(alert.ruleName, "Veículo bloqueado")
            XCTAssertEqual(alert.recognitionID, "rec_1")
            XCTAssertEqual(alert.ruleID, "rule_1")

            let testEvent = try verifyWebhookAt(
                secret: Self.newSecret, headers: lines("del_0003", Self.signedAt, Self.testNew), body: Data(Self.testBody.utf8), now: now)
            guard case let .test(test) = testEvent else { return XCTFail("not a test event") }
            XCTAssertEqual(testEvent.eventName, "webhook.test")
            XCTAssertEqual(test.sentAt, "2026-10-22T12:00:00Z")

            let unknownEvent = try verifyWebhookAt(
                secret: Self.newSecret, headers: lines("del_0004", Self.signedAt, Self.unknownNew), body: Data(Self.unknownBody.utf8), now: now)
            guard case let .unknown(unknown) = unknownEvent else { return XCTFail("not an unknown event") }
            XCTAssertEqual(unknownEvent.eventName, "payout.sent")
            XCTAssertEqual(unknown.event, "payout.sent")
            XCTAssertEqual(unknown.id, "po_1")
            XCTAssertEqual(unknown.body, Data(Self.unknownBody.utf8))

            XCTAssertThrowsError(
                try verifyWebhookAt(
                    secret: Self.newSecret, headers: lines("del_0005", Self.signedAt, "sha256=" + String(repeating: "0", count: 64)), body: Data(#"{"id":"x"}"#.utf8), now: now)
            ) {
                XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
            }
        }

        func testAVerifiedBodyThatIsNotAnEventIsRefused() throws {
            for body in ["[1]", #"{"id":"x"}"#, #"{"event":5}"#, "not json"] {
                XCTAssertThrowsError(try WebhookEvent.parse(Data(body.utf8)), body) {
                    XCTAssertEqual($0 as? WebhookVerificationError, .notAnEvent, body)
                }
            }
        }
    #endif
}

#if canImport(Network)
    /// A real HTTP server on the loopback, for what only the real URLSession
    /// does: it answers each request with what its handler builds.
    final class LocalServer: @unchecked Sendable {
        struct Request: Sendable {
            let method: String
            let target: String
            /// Header names in lower case.
            let headers: [String: String]
            let body: Data
        }

        private let listener: NWListener
        private let queue = DispatchQueue(label: "alpr.local-server")
        private let handler: @Sendable (Request) -> Data
        private var started = false

        init(handler: @escaping @Sendable (Request) -> Data) throws {
            listener = try NWListener(using: .tcp, on: .any)
            self.handler = handler
        }

        /// An HTTP/1.1 answer, ready to send.
        static func response(_ status: Int, headers: [String: String] = [:], body: String = "") -> Data {
            var head = "HTTP/1.1 \(status) Status\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n"
            for (name, value) in headers {
                head += "\(name): \(value)\r\n"
            }
            return Data((head + "\r\n" + body).utf8)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [queue, handler] connection in
                connection.start(queue: queue)
                Self.read(connection, Data(), handler)
            }
            return try await withCheckedThrowingContinuation { continuation in
                // The handler runs on the server's serial queue only.
                listener.stateUpdateHandler = { [self] state in
                    guard !started else { return }
                    switch state {
                    case .ready:
                        started = true
                        continuation.resume(returning: listener.port?.rawValue ?? 0)
                    case .failed(let error):
                        started = true
                        continuation.resume(throwing: error)
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }

        private static func read(_ connection: NWConnection, _ buffer: Data, _ handler: @escaping @Sendable (Request) -> Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let request = parse(buffer) {
                    connection.send(content: handler(request), completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, buffer, handler)
                }
            }
        }

        /// The request, or nil while it has not all arrived.
        private static func parse(_ buffer: Data) -> Request? {
            guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
                return nil
            }
            let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
            var headers: [String: String] = [:]
            for line in head.dropFirst() {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 {
                    headers[parts[0].lowercased()] = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
            let length = Int(headers["content-length"] ?? "") ?? 0
            let body = Data(buffer[end.upperBound...])
            guard body.count >= length else {
                return nil
            }
            let line = head[0].split(separator: " ").map(String.init)
            return Request(method: line.first ?? "", target: line.count > 1 ? line[1] : "", headers: headers, body: Data(body.prefix(length)))
        }
    }
#endif
