import Foundation
import Testing
@testable import RawEngine

@Suite struct RecentValuesCacheTests {
    /// Counts builds from any thread.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var counts: [Int: Int] = [:]

        func increment(_ key: Int) { lock.withLock { counts[key, default: 0] += 1 } }
        func count(_ key: Int) -> Int { lock.withLock { counts[key, default: 0] } }
    }

    @Test func buildsAValueOnce() {
        let cache = RecentValuesCache<Int, String>()
        let builds = Counter()
        for _ in 0..<3 {
            #expect(cache.value(for: 7) { builds.increment(7); return "seven" } == "seven")
        }
        #expect(builds.count(7) == 1)
    }

    /// The canvas, a thumbnail and an export run through the same stages at once: the canvas
    /// must still find its lookup table on the next frame.
    @Test func theCanvasIsNotEvictedByAThumbnailAndAnExport() {
        let cache = RecentValuesCache<Int, Int>()
        let builds = Counter()
        let (canvas, thumbnail, export) = (1, 2, 3)
        for _ in 0..<5 {
            for key in [canvas, thumbnail, export] {
                _ = cache.value(for: key) { builds.increment(key); return key }
            }
        }
        #expect(builds.count(canvas) == 1)
        #expect(builds.count(thumbnail) == 1)
        #expect(builds.count(export) == 1)
    }

    @Test func forgetsTheLeastRecentlyUsedValue() {
        let cache = RecentValuesCache<Int, Int>(capacity: 2)
        let builds = Counter()
        func ask(_ key: Int) { _ = cache.value(for: key) { builds.increment(key); return key } }
        ask(1); ask(2); ask(1); ask(3) // 2 is the least recently used: it goes.
        ask(1)
        #expect(builds.count(1) == 1)
        ask(2)
        #expect(builds.count(2) == 2)
    }

    /// A slow build in the background (an export rasterizing a mask) must not make the main
    /// thread wait for a value that has nothing to do with it.
    @Test func aSlowBuildDoesNotBlockAnotherKey() {
        let cache = RecentValuesCache<Int, Int>()
        let (started, release, finished) = (DispatchSemaphore(value: 0), DispatchSemaphore(value: 0), DispatchSemaphore(value: 0))

        Thread.detachNewThread {
            _ = cache.value(for: 1) {
                started.signal()
                release.wait()
                return 1
            }
            finished.signal()
        }
        started.wait()

        let other = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            _ = cache.value(for: 2) { 2 }
            other.signal()
        }
        let result = other.wait(timeout: .now() + 2)
        release.signal()
        finished.wait()
        #expect(result == .success)
        // The slow value made it into the cache all the same.
        #expect(cache.value(for: 1) { -1 } == 1)
    }
}
