import Foundation
import Testing
@testable import Sieve

struct TimeoutRaceTests {
    @Test func returnsResultWhenOperationBeatsTheTimeout() async {
        let value = await firstResult(within: .seconds(5)) { 42 }
        #expect(value == 42)
    }

    @Test func returnsNilWhenOperationOutlastsTheTimeout() async {
        let start = ContinuousClock.now
        // A synchronous call that blocks well past the timeout, like a stalled mount.
        let value = await firstResult(within: .milliseconds(50)) { () -> Int in
            Thread.sleep(forTimeInterval: 2)
            return 42
        }
        #expect(value == nil)
        #expect(start.duration(to: .now) < .seconds(1))   // gave up promptly, didn't wait out the block
    }

    @Test func isReachableIsFalseForAMissingPath() async {
        let missing = URL(fileURLWithPath: "/Volumes/Definitely Not Mounted \(UUID().uuidString)/x")
        #expect(await BookmarkStore.isReachable(missing, timeout: .seconds(2)) == false)
    }
}
