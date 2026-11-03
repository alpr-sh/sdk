import Foundation

/// A multipart/form-data body: the photo and the text fields beside it, in
/// the order they were added.
struct MultipartForm: Sendable {
    private enum Part: Sendable {
        case text(name: String, value: String)
        case file(name: String, data: Data)
    }

    private var parts: [Part] = []

    /// Adds a text field.
    mutating func text(_ name: String, _ value: String) {
        parts.append(.text(name: name, value: value))
    }

    /// Adds the photo, named and typed by what its first bytes say it is.
    mutating func file(_ name: String, _ data: Data) {
        parts.append(.file(name: name, data: data))
    }

    /// The body and its Content-Type, boundary included.
    func encode() -> (body: Data, contentType: String) {
        var payloads: [Data] = []
        for part in parts {
            switch part {
            case let .text(_, value): payloads.append(Data(value.utf8))
            case let .file(_, data): payloads.append(data)
            }
        }
        // A boundary that no part contains.
        var boundary = Self.boundary()
        while payloads.contains(where: { $0.range(of: Data(boundary.utf8)) != nil }) {
            boundary = Self.boundary()
        }
        var body = Data()
        for part in parts {
            body.append(Data("--\(boundary)\r\n".utf8))
            switch part {
            case let .text(name, value):
                body.append(Data("Content-Disposition: form-data; name=\"\(quoted(name))\"\r\n\r\n".utf8))
                body.append(Data(value.utf8))
            case let .file(name, data):
                let (kind, filename) = imageType(data)
                body.append(Data("Content-Disposition: form-data; name=\"\(quoted(name))\"; filename=\"\(filename)\"\r\n".utf8))
                body.append(Data("Content-Type: \(kind)\r\n\r\n".utf8))
                body.append(data)
            }
            body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)--\r\n".utf8))
        return (body, "multipart/form-data; boundary=\(boundary)")
    }

    private static func boundary() -> String {
        "alpr-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func quoted(_ name: String) -> String {
        name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// The content type and file name of a photo: JPEG and PNG are what the API
/// reads, and anything else goes as bytes for the API to refuse.
func imageType(_ data: Data) -> (kind: String, filename: String) {
    let head = [UInt8](data.prefix(8))
    if head.count >= 3, head[0] == 0xFF, head[1] == 0xD8, head[2] == 0xFF {
        return ("image/jpeg", "photo.jpg")
    }
    if head == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] {
        return ("image/png", "photo.png")
    }
    return ("application/octet-stream", "photo")
}

/// A number as the shortest decimal text that reads back as it: 0.5, and 1
/// for 1.0.
func formatNumber(_ value: Double) -> String {
    if value == value.rounded(), abs(value) < 1e15 {
        return String(Int64(value))
    }
    return String(value)
}
