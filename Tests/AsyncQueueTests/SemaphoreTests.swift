// MIT License
//
// Copyright (c) 2022 Dan Federman
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import XCTest

@testable import AsyncQueue

final class SemaphoreTests: XCTestCase {

    // MARK: XCTestCase

    override func setUp() async throws {
        try await super.setUp()

        systemUnderTest = Semaphore()
    }

    override func tearDown() async throws {
        try await super.tearDown()

        while await systemUnderTest.isWaiting {
            await systemUnderTest.signal()
        }
    }

    // MARK: Behavior Tests

    func test_wait_suspendsUntilEqualNumberOfSignalCalls() async {
        let counter = Counter()
        let iterationCount = 1_000

        var waits = [Task<Void, Never>]()
        for _ in 1...iterationCount {
            waits.append(Task {
                await self.systemUnderTest.wait()
                await counter.increment()
            })
        }

        var signals = [Task<Void, Never>]()
        // Loop one fewer than iterationCount.
        // The count will be zero each time because we haven't `signal`ed `iterationCount` times yet.
        for _ in 0..<(iterationCount-1) {
            signals.append(Task {
                await self.systemUnderTest.signal()
                let count = await counter.count
                XCTAssertEqual(0, count)
            })
        }

        // Wait for every looped `signal` task above to complete before we signal the final time.
        // If we didn't wait here, we could introduce a race condition that would lead the above `XCTAssertEqual` to fail.
        for signal in signals {
            await signal.value
        }

        // Signal one more time, matching the number of `wait`s above.
        await self.systemUnderTest.signal()

        // Now that we have a matching number of `signal`s to the number of enqueued `wait`s, we can await the completion of every wait task.
        // Waiting for the `waits` prior to now would have deadlocked.
        for wait in waits {
            await wait.value
        }

        // Now that we've executed a matching number of `wait` and `signal` calls, the counter will have been incremented `iterationCount` times.
        let count = await counter.count
        XCTAssertEqual(iterationCount, count)
    }

    func test_wait_doesNotSuspendIfSignalCalledFirst() async {
        await systemUnderTest.signal()
        await systemUnderTest.wait()
        // If the test doesn't hang forever, we've succeeded!
    }

    // MARK: Private

    private var systemUnderTest = Semaphore()
}
