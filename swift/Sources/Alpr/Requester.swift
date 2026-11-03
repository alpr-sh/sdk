import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

/// Sends one request and answers its body and response, whatever the status.
/// The SDK sends through a `URLSession` that refuses redirects; a test, or a program with its
/// own HTTP stack, gives another one to `AlprClient`.
public typealias AlprTransport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

/// What a service calls the API through.
struct Requester: Sendable {
    let apiKey: String
    let baseURL: String
    let timeout: TimeInterval
    let transport: AlprTransport
    /// Why the base URL is refused; every call throws it before sending anything.
    var baseURLError: AlprError?

    /// Calls the API and decodes the whole answer; a refusal throws
    /// `AlprError`.
    func request<T: Decodable>(
        _ method: String,
        _ path: String,
        query: [(String, String?)] = [],
        form: MultipartForm? = nil,
        apiKey: String? = nil
    ) async throws -> T {
        let data = try await send(method, path, query: query, form: form, apiKey: apiKey)
        return try JSONDecoder().decode(T.self, from: data)
    }

    /// Calls the API for an answer that is a list, `{"data": [item]}`, and
    /// answers its items.
    func requestList<Item: Decodable>(
        _ method: String,
        _ path: String,
        query: [(String, String?)] = [],
        apiKey: String? = nil
    ) async throws -> [Item] {
        let data = try await send(method, path, query: query, form: nil, apiKey: apiKey)
        return try JSONDecoder().decode(Envelope<[Item]>.self, from: data).data
    }

    /// Calls the API for an answer that is a 204 with no body; a refusal
    /// throws `AlprError`.
    func requestNoContent(
        _ method: String,
        _ path: String,
        form: MultipartForm? = nil,
        apiKey: String? = nil
    ) async throws {
        _ = try await send(method, path, query: [], form: form, apiKey: apiKey)
    }

    private func send(
        _ method: String,
        _ path: String,
        query: [(String, String?)],
        form: MultipartForm?,
        apiKey: String?
    ) async throws -> Data {
        if let baseURLError {
            throw baseURLError
        }
        var address = baseURL + path
        let pairs = query.compactMap { name, value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return "\(escape(name))=\(escape(value))"
        }
        if !pairs.isEmpty {
            address += "?" + pairs.joined(separator: "&")
        }
        guard let url = URL(string: address) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = method
        let key = apiKey.flatMap { $0.isEmpty ? nil : $0 } ?? self.apiKey
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("alpr-swift/\(AlprClient.version)", forHTTPHeaderField: "User-Agent")
        if let form {
            let (body, contentType) = form.encode()
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await transport(request)
        if response.statusCode >= 300 {
            throw AlprError(response: response, body: data)
        }
        return data
    }

    /// A session that refuses redirects: the API never redirects, and a
    /// redirect would carry the key along. The 3xx is the answer.
    private static let session = URLSession(
        configuration: .default, delegate: RefuseRedirects(), delegateQueue: nil)

    /// Sends through a `URLSession` that does not follow redirects.
    static let urlSession: AlprTransport = { request in
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (data, http)
    }
}

extension AlprError {
    /// The refusal of a base URL that is not https and not a loopback address.
    static func insecureBaseURL(_ url: URL) -> AlprError? {
        let scheme = url.scheme?.lowercased()
        let host = (url.host ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        let octets = host.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        let loopback =
            host == "localhost" || host == "::1"
            || (octets.count == 4 && octets[0] == 127 && octets.allSatisfy { ($0 ?? 256) <= 255 })
        if scheme == "https" || (scheme == "http" && loopback) {
            return nil
        }
        return AlprError(status: 0, code: "insecure_base_url", message: "alpr: the base URL must be https (http is accepted only for localhost, 127.0.0.0/8 and ::1), so the API key is never sent in clear text")
    }
}

private struct Envelope<T: Decodable>: Decodable {
    let data: T
}

private let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

/// A path parameter or a query value, escaped: everything but letters, digits
/// and `-._~`.
func escape(_ value: String) -> String {
    value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value
}

private final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
