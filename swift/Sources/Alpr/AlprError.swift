import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// A request the API refused.
///
/// `code` is the API's: invalid_api_key, insufficient_scope,
/// insufficient_credits, missing image, invalid_image, invalid_option,
/// image_too_large, no_plate, not_found, image_unavailable, rate_limited,
/// engine_unavailable or storage_unavailable. `fields` says, when the API
/// names them, what is wrong with each field; it is empty otherwise.
/// `retryAfter` is how many seconds to wait on a 429.
public struct AlprError: Error, Sendable, Hashable, CustomStringConvertible, LocalizedError {
    /// The HTTP status.
    public let status: Int
    /// The API's code for the refusal.
    public let code: String
    /// What went wrong, for a person to read.
    public let message: String
    /// The problems of each field of the request, when the API names them.
    public let fields: [String: [String]]
    /// How many seconds to wait before trying again.
    public let retryAfter: TimeInterval?

    public init(status: Int, code: String, message: String = "", fields: [String: [String]] = [:], retryAfter: TimeInterval? = nil) {
        self.status = status
        self.code = code
        self.message = message
        self.fields = fields
        self.retryAfter = retryAfter
    }

    /// The error a refused response carries. A refusal without a JSON body is
    /// still a refusal.
    init(response: HTTPURLResponse, body: Data) {
        let decoded = try? JSONDecoder().decode(Body.self, from: body)
        let retryAfter = response.value(forHTTPHeaderField: "Retry-After")
            .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
            .map(TimeInterval.init)
        self.init(
            status: response.statusCode,
            code: decoded?.error ?? "",
            message: decoded?.message ?? "",
            fields: decoded?.fields ?? [:],
            retryAfter: retryAfter
        )
    }

    public var description: String {
        message.isEmpty ? "alpr: \(status) \(code)" : "alpr: \(status) \(code): \(message)"
    }

    public var errorDescription: String? { description }

    private struct Body: Decodable {
        let error: String?
        let message: String?
        let fields: [String: [String]]?
    }
}
