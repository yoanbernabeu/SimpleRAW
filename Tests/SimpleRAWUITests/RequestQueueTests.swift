import Testing
@testable import SimpleRAWUI

@Suite struct RequestQueueTests {
    @Test func servesInTheOrderAsked() {
        var queue = RequestQueue<Int, String>(limit: 10)
        queue.push("a", for: 1)
        queue.push("b", for: 2)
        #expect(queue.pop() == "a")
        #expect(queue.pop() == "b")
        #expect(queue.pop() == nil && queue.isEmpty)
    }

    @Test func askingAgainKeepsThePlaceAndTakesTheNewValue() {
        var queue = RequestQueue<Int, String>(limit: 10)
        queue.push("a", for: 1)
        queue.push("b", for: 2)
        queue.push("a, edited", for: 1)
        #expect(queue.count == 2)
        #expect(queue.pop() == "a, edited")
    }

    @Test func aRemovedRequestIsNeverServed() {
        var queue = RequestQueue<Int, String>(limit: 10)
        queue.push("a", for: 1)
        queue.push("b", for: 2)
        queue.remove(1)
        #expect(queue.count == 1)
        #expect(queue.pop() == "b")
        #expect(queue.pop() == nil)
    }

    @Test func aRequestRemovedThenAskedAgainGoesToTheBack() {
        var queue = RequestQueue<Int, String>(limit: 10)
        queue.push("a", for: 1)
        queue.push("b", for: 2)
        queue.remove(1)
        queue.push("a", for: 1)
        #expect(queue.pop() == "b")
        #expect(queue.pop() == "a")
        #expect(queue.pop() == nil)
    }

    @Test func overTheLimitTheOldestRequestsAreForgotten() {
        var queue = RequestQueue<Int, String>(limit: 2)
        queue.push("a", for: 1)
        queue.push("b", for: 2)
        queue.remove(1)
        queue.push("a", for: 1)
        queue.push("c", for: 3)
        #expect(queue.count == 2)
        #expect(queue.pop() == "a")
        #expect(queue.pop() == "c")
    }

    /// Scrolling through a whole library asks and gives up thousands of times.
    @Test func itDoesNotGrowWithRequestsThatWereGivenUp() {
        var queue = RequestQueue<Int, Int>(limit: 4)
        for key in 0..<10_000 {
            queue.push(key, for: key)
            if key.isMultiple(of: 2) { queue.remove(key) }
        }
        #expect(queue.count <= 4)
        #expect(queue.storageCount <= 64)
    }
}
