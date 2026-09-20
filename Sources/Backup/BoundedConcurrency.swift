/// Runs `work` on every item, a few at a time: most of an upload is waiting for the network,
/// and one after the other is what makes a first backup take the night. More than a few
/// would only fight over the same uplink.
enum BoundedConcurrency {
    /// - Parameter finished: called on the caller's task each time an item is done, with how
    ///   many are, in whatever order they finish.
    /// - Returns: one result per item, in the order of the items.
    static func map<Item: Sendable, Output: Sendable>(
        _ items: [Item], limit: Int,
        finished: (_ count: Int, _ item: Item) -> Void = { _, _ in },
        _ work: @escaping @Sendable (Item) async -> Output
    ) async -> [Output] {
        await withTaskGroup(of: (Int, Output).self) { group in
            var results = [Output?](repeating: nil, count: items.count)
            var next = 0
            var count = 0
            func start() {
                guard next < items.count else { return }
                let (index, item) = (next, items[next])
                next += 1
                group.addTask { (index, await work(item)) }
            }
            for _ in 0..<max(1, limit) { start() }
            for await (index, output) in group {
                results[index] = output
                count += 1
                finished(count, items[index])
                start()
            }
            return results.compactMap { $0 }
        }
    }
}
