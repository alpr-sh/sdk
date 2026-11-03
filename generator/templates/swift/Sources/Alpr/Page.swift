/// One page of a list, and where the list ends.
public struct Page<Item: Decodable & Sendable>: Decodable, Sendable {
    /// The page's items.
    public let items: [Item]
    /// How many items and pages the list has.
    public let pagination: Pagination

    public init(items: [Item], pagination: Pagination) {
        self.items = items
        self.pagination = pagination
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([Item].self, forKey: .items) ?? []
        pagination = try container.decode(Pagination.self, forKey: .pagination)
    }

    enum CodingKeys: String, CodingKey {
        case items
        case pagination
    }
}

/// Walks pages from `first` (1 when nil) until the last one, as Polar's SDKs
/// do, yielding every item. A page is fetched only when the items before it
/// were taken, and an error ends the walk.
func iterate<Item: Decodable & Sendable>(
    from first: Int?,
    fetch: @escaping @Sendable (Int) async throws -> Page<Item>
) -> AsyncThrowingStream<Item, any Error> {
    let pager = Pager(page: max(first ?? 1, 1), fetch: fetch)
    return AsyncThrowingStream { try await pager.next() }
}

private actor Pager<Item: Decodable & Sendable> {
    private var page: Int
    private var items: ArraySlice<Item> = []
    private var done = false
    private let fetch: @Sendable (Int) async throws -> Page<Item>

    init(page: Int, fetch: @escaping @Sendable (Int) async throws -> Page<Item>) {
        self.page = page
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
            done = true
            let result = try await fetch(page)
            if page < result.pagination.maxPage {
                page += 1
                done = false
            }
            items = result.items[...]
        }
    }
}
