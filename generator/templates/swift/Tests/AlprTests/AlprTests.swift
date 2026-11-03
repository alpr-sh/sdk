import Foundation
import Alpr
import XCTest

#if canImport(CryptoKit)
    import CryptoKit
#endif
#if canImport(Network)
    import Network
#endif

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

typealias Answer = @Sendable (URLRequest) -> (status: Int, headers: [String: String], body: Any?)

func client(_ answer: @escaping Answer) -> (AlprClient, Recorder) {
    let recorder = Recorder()
    let transport: AlprTransport = { request in
        recorder.append(request)
        let (status, headers, body) = answer(request)
        let data = try body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        return (data, response)
    }
    let alpr = AlprClient(apiKey: "prk_test_key", baseURL: URL(string: "https://alpr.test/")!, transport: transport)
    return (alpr, recorder)
}

func product(_ id: String) -> [String: Any] {
    ["id": id, "name": "Curso", "description": "", "status": "active", "created_at": "2026-10-17T00:00:00Z"]
}

func queryItem(_ request: URLRequest, _ name: String) -> String? {
    URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
}

final class AlprTests: XCTestCase {
    func testACallCarriesTheKeyAndUnwrapsTheData() async throws {
        let (alpr, recorder) = client { _ in (200, [:], ["data": product("prod_1")]) }
        let got = try await alpr.products.get("prod_1")
        XCTAssertEqual(got.id, "prod_1")
        XCTAssertEqual(got.status, .active)
        XCTAssertEqual(got.createdAt, "2026-10-17T00:00:00Z")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "GET")
        XCTAssertEqual(seen.url?.path, "/api/v1/products/prod_1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Authorization"), "Bearer prk_test_key")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "User-Agent"), "alpr-swift/\(AlprClient.version)")
    }

    func testAWriteSendsItsBodyAndIdempotencyKey() async throws {
        let (alpr, recorder) = client { _ in (201, [:], ["data": product("prod_1")]) }
        let created = try await alpr.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "create-1")
        XCTAssertEqual(created.name, "Curso")
        let seen = recorder.seen[0]
        XCTAssertEqual(seen.httpMethod, "POST")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Idempotency-Key"), "create-1")
        XCTAssertEqual(seen.value(forHTTPHeaderField: "Content-Type"), "application/json")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(seen.httpBody)) as? [String: String])
        // The optional description, left nil, is not sent.
        XCTAssertEqual(body, ["name": "Curso"])
    }

    func testABaseURLMustBeHTTPSUnlessItIsLoopback() async throws {
        let accepted = ["https://alpr.sh", "http://localhost:8080", "http://LOCALHOST", "http://127.0.0.1:1", "http://127.255.0.3", "http://[::1]:8080"]
        let refused = ["http://alpr.sh", "http://localhost.evil.test", "http://127.0.0.1.evil.test", "http://10.0.0.1", "ftp://localhost", "http://[::2]"]
        for base in accepted + refused {
            let recorder = Recorder()
            let transport: AlprTransport = { request in
                recorder.append(request)
                let data = try JSONSerialization.data(withJSONObject: ["data": product("prod_1")])
                return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:])!)
            }
            let alpr = AlprClient(apiKey: "k", baseURL: URL(string: base)!, transport: transport)
            do {
                _ = try await alpr.products.get("prod_1")
                XCTAssertTrue(accepted.contains(base), base)
            } catch let error as AlprError {
                XCTAssertTrue(refused.contains(base), base)
                XCTAssertEqual(error.code, "insecure_base_url")
                XCTAssertEqual(recorder.seen.count, 0)
            }
        }
    }

    func testADiscountGoesThroughCreateGetListAndDelete() async throws {
        @Sendable func discount(_ id: String) -> Any {
            try! JSONSerialization.jsonObject(with: Data(#"{"id":"__ID__","name":"Black","code":null,"type":"percentage","basis_points":1000,"amount_cents":0,"currency":"BRL","duration":"once","duration_in_months":0,"max_redemptions":null,"max_redemptions_per_customer":null,"redemptions_count":0,"starts_at":"2026-10-17T00:00:00Z","ends_at":null,"status":"active","product_ids":["prod_1"],"created_at":"2026-10-17T00:00:00Z","modified_at":"2026-10-17T00:00:00Z"}"#.replacingOccurrences(of: "__ID__", with: id).utf8))
        }
        let (alpr, recorder) = client { request in
            if request.httpMethod == "POST" { return (201, [:], ["data": discount("disc_1")]) }
            if request.httpMethod == "DELETE" { return (204, [:], nil) }
            if request.url?.path == "/api/v1/discounts" {
                let page = queryItem(request, "page") ?? ""
                return (200, [:], ["data": ["items": [discount("disc_\(page)")], "pagination": ["total_count": 2, "max_page": 2]]])
            }
            return (200, [:], ["data": discount("disc_1")])
        }
        let created = try await alpr.discounts.create(DiscountsCreateParams(duration: "once", name: "Black", type: "percentage", basisPoints: 1000))
        XCTAssertEqual(created.id, "disc_1")
        XCTAssertNil(created.code)
        XCTAssertEqual(created.productIds, ["prod_1"])
        let got = try await alpr.discounts.get("disc_1")
        XCTAssertEqual(got.name, "Black")
        var ids: [String] = []
        for try await each in alpr.discounts.listIter(limit: 1) { ids.append(each.id) }
        XCTAssertEqual(ids, ["disc_1", "disc_2"])
        try await alpr.discounts.delete("disc_1")
        XCTAssertEqual(
            recorder.seen.map { "\($0.httpMethod ?? "") \($0.url?.path ?? "")" },
            ["POST /api/v1/discounts", "GET /api/v1/discounts/disc_1", "GET /api/v1/discounts", "GET /api/v1/discounts", "DELETE /api/v1/discounts/disc_1"])
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(recorder.seen[0].httpBody)) as? [String: Any])
        XCTAssertEqual(body["basis_points"] as? Int, 1000)
        XCTAssertEqual(body["name"] as? String, "Black")
    }

    func testAFreeFormValueDecodesNested() async throws {
        let (alpr, _) = client { _ in
            let state = try! JSONSerialization.jsonObject(with: Data(#"{"id":"cus_1","name":"Ana","email":"ana@example.com","external_id":"","status":"active","created_at":"2026-10-17T00:00:00Z","active_subscriptions":[],"granted_benefits":[{"id":"gr_1","granted_at":"2026-10-17T00:00:00Z","benefit_id":"ben_1","benefit_type":"feature_flag","benefit_metadata":{"flags":{"beta":true,"limits":{"seats":5,"tiers":["a",2,null,1.5]}}},"properties":{"links":[{"url":"https://example.com","expires":null}]}}]}"#.utf8))
            return (200, [:], ["data": state])
        }
        let grant = try await alpr.customers.getState("cus_1").grantedBenefits[0]
        XCTAssertEqual(
            grant.benefitMetadata,
            ["flags": .object(["beta": .bool(true), "limits": .object(["seats": .int(5), "tiers": .array([.string("a"), .int(2), .null, .double(1.5)])])])])
        XCTAssertEqual(grant.properties, ["links": .array([.object(["url": .string("https://example.com"), "expires": .null])])])
    }

    func testAPostWithoutAKeyIsSentWithItsOwnAGetWithNone() async throws {
        let (alpr, recorder) = client { _ in (201, [:], ["data": product("prod_1")]) }
        _ = try await alpr.products.create(ProductsCreateParams(name: "Curso"))
        _ = try await alpr.products.create(ProductsCreateParams(name: "Curso"))
        _ = try await alpr.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "mine")
        _ = try await alpr.products.get("prod_1")
        let keys = recorder.seen.map { $0.value(forHTTPHeaderField: "Idempotency-Key") }
        let uuid = "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        XCTAssertNotNil(keys[0]?.range(of: uuid, options: .regularExpression))
        XCTAssertNotNil(keys[1]?.range(of: uuid, options: .regularExpression))
        XCTAssertNotEqual(keys[0], keys[1])
        XCTAssertEqual(keys[2], "mine")
        XCTAssertNil(keys[3])
    }

    func testIteratingWalksEveryPage() async throws {
        let (alpr, recorder) = client { request in
            let page = queryItem(request, "page") ?? ""
            return (200, [:], ["data": ["items": [product("prod_\(page)")], "pagination": ["total_count": 3, "max_page": 3]]])
        }
        var ids: [String] = []
        for try await item in alpr.products.listIter(limit: 1) {
            ids.append(item.id)
        }
        XCTAssertEqual(ids, ["prod_1", "prod_2", "prod_3"])
        XCTAssertEqual(queryItem(recorder.seen[0], "limit"), "1")
    }

    func testARefusalIsATypedError() async throws {
        let (alpr, _) = client { request in
            if request.url?.path == "/api/v1/customers" {
                return (422, [:], ["error": "invalid_request", "fields": ["email": ["send an e-mail"]]])
            }
            return (429, ["Retry-After": "7"], nil)
        }
        do {
            _ = try await alpr.customers.create(CustomersCreateParams(email: "x", name: "x"))
            XCTFail("a 422 was not refused")
        } catch let refused as AlprError {
            XCTAssertEqual(refused.status, 422)
            XCTAssertEqual(refused.code, "invalid_request")
            XCTAssertEqual(refused.fields["email"], ["send an e-mail"])
        }
        do {
            _ = try await alpr.products.list()
            XCTFail("a 429 was not refused")
        } catch let limited as AlprError {
            XCTAssertEqual(limited.status, 429)
            XCTAssertEqual(limited.retryAfter, 7)
        }
    }

    #if canImport(CryptoKit)
        // The webhook vectors every SDK checks: Standard Webhooks' own example,
        // and Alpr.sh events signed under two secrets, as while one is rotated.
        static let referenceSecret = "whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw"
        static let oldSecret = "whsec_cGVyYXRhLXNkay1vbGQta2V5LTAxMjM0NTY3ODlhYmM="
        static let newSecret = "whsec_cGVyYXRhLXNkay1uZXcta2V5LTAxMjM0NTY3ODlhYmM="
        static let orderPaid = Data(#"{"id":"msg_2","type":"order.paid","timestamp":"2026-10-22T12:00:00Z","data":{"id":"ord_1","customer_id":"cus_1","product_id":"prod_1","price_id":"price_1","amount_cents":12000,"currency":"BRL","status":"succeeded","paid_at":"2026-10-22T12:00:00Z","installments":3,"installment_interest_cents":360}}"#.utf8)
        static let usageRecorded = Data(#"{"id":"msg_3","type":"usage_event.recorded","timestamp":"2026-10-22T12:00:00Z","data":{"event_id":"ue_1","aggregate":"usage_event","aggregate_id":"ue_1","merchant_id":"mer_1","environment":"test"}}"#.utf8)
        static let payoutSent = Data(#"{"id":"msg_4","type":"payout.sent","timestamp":"2026-10-22T12:00:00Z","data":{"payout_id":"po_1","amount_cents":5000}}"#.utf8)
        static let signedAt = 1_792_670_400

        func webhookHeaders(_ id: String, _ at: Int, _ signature: String) -> [String: String] {
            ["Webhook-Id": id, "webhook-timestamp": String(at), "webhook-signature": signature]
        }

        func testTheStandardWebhooksVectorVerifies() throws {
            let body = Data(#"{"test": 2432232314}"#.utf8)
            let headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 1_614_265_330, "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=")
            let at = Date(timeIntervalSince1970: 1_614_265_330)
            try verifyWebhookSignature(secret: Self.referenceSecret, headers: headers, body: body, now: at)
            for (secret, payload, now) in [
                (Self.referenceSecret, body + Data(" ".utf8), at),
                (Self.referenceSecret, body, at.addingTimeInterval(301)),
                (Self.newSecret, body, at),
            ] {
                XCTAssertThrowsError(try verifyWebhookSignature(secret: secret, headers: headers, body: payload, now: now)) {
                    XCTAssertEqual($0 as? WebhookVerificationError, .invalidSignature)
                }
            }
        }

        func testATimestampThatIsNotPlainDigitsIsRefused() throws {
            let body = Data(#"{"test": 2432232314}"#.utf8)
            for (stamp, signature) in [("+1614265330", "JQsSpSSK1m9NI2FueDRZN3FL/jU9336idQcq6VmF+c8="), ("²", "PEggIsKE32VQ8J4ZIk9apRhPy7w+a20bxGpjk1K4/HY="), ("", "x"), ("1_6", "x")] {
                var headers = webhookHeaders("msg_p5jXN8AQM9LWM0D4loKWxJek", 0, "v1,\(signature)")
                headers["webhook-timestamp"] = stamp
                XCTAssertThrowsError(
                    try verifyWebhookSignature(secret: Self.referenceSecret, headers: headers, body: body, now: Date(timeIntervalSince1970: 1_614_265_330)), stamp)
            }
        }

        func testAWebhookAnswersItsTypedEvent() throws {
            let now = Date(timeIntervalSince1970: TimeInterval(Self.signedAt + 120))
            let headers = webhookHeaders("msg_2", Self.signedAt, "v1,wYfYi9j4EexjSjLLsUssBYbtAFSwF9KVQBJ2o+qD6Jw= v1,0rD3K6HM83kGY+mZMPVidXSW2zXHHDvy3bMt2QzM8Ak=")
            for secret in [Self.newSecret, Self.oldSecret] {
                guard case let .order(order) = try verifyWebhook(secret: secret, headers: headers, body: Self.orderPaid, now: now) else {
                    return XCTFail("not an order event")
                }
                XCTAssertEqual(order.type, "order.paid")
                XCTAssertEqual(order.data.id, "ord_1")
                XCTAssertEqual(order.data.installments, 3)
                XCTAssertEqual(order.data.installmentInterestCents, 360)
            }
            XCTAssertThrowsError(try verifyWebhook(secret: Self.referenceSecret, headers: headers, body: Self.orderPaid, now: now))
            let usage = try verifyWebhook(secret: Self.newSecret, headers: webhookHeaders("msg_3", Self.signedAt, "v1,Z3E2vTbczigiySfkzakxuZotPn9FlBY1KAET6hPEZoU="), body: Self.usageRecorded, now: now)
            XCTAssertEqual(usage.id, "msg_3")
            guard case let .identifiers(identifiers) = usage else {
                return XCTFail("not an identifiers event")
            }
            XCTAssertEqual(identifiers.data["merchant_id"], "mer_1")
            let unknown = try verifyWebhook(secret: Self.newSecret, headers: webhookHeaders("msg_4", Self.signedAt, "v1,Sa/yofA3h/58pFR+rIiWdIc8qXfcuqvyJSjxn4oJ1ZY="), body: Self.payoutSent, now: now)
            guard case let .unknown(event) = unknown else {
                return XCTFail("not an unknown event")
            }
            XCTAssertEqual(event.type, "payout.sent")
            XCTAssertEqual(event.body, Self.payoutSent)
        }
    #endif

    #if canImport(Network)
        func testTheRealHTTPSendsAndReadsThroughURLSession() async throws {
            let server = try EchoServer()
            let port = try await server.start()
            defer { server.stop() }
            let base = URL(string: "http://127.0.0.1:\(port)")!
            let alpr = AlprClient(apiKey: "prk_test_key", baseURL: base)
            let created = try await alpr.products.create(ProductsCreateParams(name: "Curso"), idempotencyKey: "create-1")
            XCTAssertEqual(created.name, "Curso")
            XCTAssertEqual(created.description, "create-1")
            XCTAssertEqual(created.createdAt, "POST /api/v1/products")
            do {
                _ = try await AlprClient(apiKey: "prk_test_other", baseURL: base).products.get("prod_1")
                XCTFail("a 401 was not refused")
            } catch let refused as AlprError {
                XCTAssertEqual(refused.status, 401)
                XCTAssertEqual(refused.code, "invalid_credential")
                XCTAssertEqual(refused.retryAfter, 3)
            }
        }
    #endif
}

#if canImport(Network)
    /// Answers what it was sent, wrapped as the API wraps a resource; a request
    /// without the test key is refused with a 401 and Retry-After 3.
    final class EchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "alpr.echo")
        private var started = false

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
        }

        func start() async throws -> UInt16 {
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.read(connection, Data())
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

        private static func read(_ connection: NWConnection, _ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                var buffer = buffer
                if let data {
                    buffer.append(data)
                }
                if let answer = answer(buffer) {
                    connection.send(content: answer, completion: .contentProcessed { _ in connection.cancel() })
                } else if complete || error != nil {
                    connection.cancel()
                } else {
                    read(connection, buffer)
                }
            }
        }

        /// The answer to a whole request, or nil while it has not all arrived.
        private static func answer(_ buffer: Data) -> Data? {
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
            let body = buffer[end.upperBound...]
            guard body.count >= length else {
                return nil
            }
            let line = head[0].split(separator: " ")
            var status = "201 Created"
            var extra = ""
            var payload: [String: Any]
            if headers["authorization"] != "Bearer prk_test_key" {
                status = "401 Unauthorized"
                extra = "Retry-After: 3\r\n"
                payload = ["error": "invalid_credential"]
            } else {
                let sent = (try? JSONSerialization.jsonObject(with: Data(body.prefix(length)))) as? [String: Any]
                payload = ["data": [
                    "id": "prod_1",
                    "name": sent?["name"] as? String ?? "",
                    "description": headers["idempotency-key"] ?? "",
                    "status": "active",
                    "created_at": "\(line[0]) \(line.count > 1 ? line[1] : "")",
                ]]
            }
            let json = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
            let header = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\n\(extra)Content-Length: \(json.count)\r\nConnection: close\r\n\r\n"
            return Data(header.utf8) + json
        }
    }
#endif
