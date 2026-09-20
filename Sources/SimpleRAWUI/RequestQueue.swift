/// Requests waiting for their turn: first asked, first served, one per key, and no more than
/// `limit` of them, the oldest being forgotten first. Asking, giving up and serving all cost
/// the same whatever the length of the queue.
struct RequestQueue<Key: Hashable, Value> {
    private var values: [Key: (ticket: Int, value: Value)] = [:]
    /// Keys in the order they were asked. An entry whose ticket is no longer the one of its
    /// key was given up: it is skipped when its turn comes.
    private var order: [(key: Key, ticket: Int)] = []
    private var head = 0
    private var lastTicket = 0
    let limit: Int

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    var count: Int { values.count }
    var isEmpty: Bool { values.isEmpty }
    /// How much is kept, entries that were given up included. For tests.
    var storageCount: Int { order.count }

    /// Asking again for a key that is waiting keeps its place.
    mutating func push(_ value: Value, for key: Key) {
        if let waiting = values[key] {
            values[key] = (waiting.ticket, value)
            return
        }
        lastTicket += 1
        values[key] = (lastTicket, value)
        order.append((key, lastTicket))
        while values.count > limit { _ = pop() }
        compact()
    }

    mutating func remove(_ key: Key) {
        values[key] = nil
    }

    mutating func pop() -> Value? {
        while head < order.count {
            let entry = order[head]
            head += 1
            if let waiting = values[entry.key], waiting.ticket == entry.ticket {
                values[entry.key] = nil
                return waiting.value
            }
        }
        order = []
        head = 0
        return nil
    }

    /// Drops what was served or given up once it outweighs what is waiting.
    private mutating func compact() {
        guard order.count > 4 * limit + 16 else { return }
        order = order[head...].filter { values[$0.key]?.ticket == $0.ticket }
        head = 0
    }
}
