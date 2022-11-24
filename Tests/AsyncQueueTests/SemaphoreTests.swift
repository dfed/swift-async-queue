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
        for _ in 0..<(iterationCount-1) {
            signals.append(Task {
                await self.systemUnderTest.signal()
                let count = await counter.count
                XCTAssertEqual(0, count)
            })
        }

        for signal in signals {
            await signal.value
        }

        await self.systemUnderTest.signal()

        for wait in waits {
            await wait.value
        }

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
