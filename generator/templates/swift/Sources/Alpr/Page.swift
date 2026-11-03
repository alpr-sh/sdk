/// One page of a list: its items, and the cursor of the next page.
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    /// The page's items.
    public let items: [Item]
    /// The cursor to ask the next page with; nil on the last page.
    public let next: String?

    public init(items: [Item], next: String? = nil) {
        self.items = items
        self.next = next
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        let next = try container.decodeIfPresent(String.self, forKey: .next)
        self.next = next?.isEmpty == true ? nil : next
    }

    enum CodingKeys: String, CodingKey {
        case items = "data"
        case next
    }
}

/// Walks pages from the cursor `first` (nil asks for the newest page) until
/// the last one, yielding every item. A page is fetched only when the items
/// before it were taken. The walk ends at the first error, and when the next
/// cursor is the one just used, which would ask for the same page forever.
func iterate<Item: Decodable & Sendable>(
    from first: String?,
    fetch: @escaping @Sendable (String?) async throws -> Page<Item>
) -> AsyncThrowingStream<Item, any Error> {
    let pager = Pager(cursor: first?.isEmpty == true ? nil : first, fetch: fetch)
    return AsyncThrowingStream { try await pager.next() }
}

private actor Pager<Item: Decodable & Sendable> {
    private var cursor: String?
    private var items: ArraySlice<Item> = []
    private var done = false
    private let fetch: @Sendable (String?) async throws -> Page<Item>

    init(cursor: String?, fetch: @escaping @Sendable (String?) async throws -> Page<Item>) {
        self.cursor = cursor
        self.fetch = fetch
    }

    func next() async throws -> Item? {
        while true {
            if let item = items.popFirst() {
                return item
            }
            if done {
                return nil
            }
            let used = cursor
            do {
                let result = try await fetch(used)
                items = result.items[...]
                if let next = result.next, next != used {
                    cursor = next
                } else {
                    done = true
                }
            } catch {
                done = true
                throw error
            }
        }
    }
}
