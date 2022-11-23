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

final class AsyncQueueTests: XCTestCase {

    // MARK: XCTestCase

    override func setUp() async throws {
        try await super.setUp()

        systemUnderTest = AsyncQueue()
    }

    override func tearDown() async throws {
        try await super.tearDown()

        await systemUnderTest.await { /* Drain the queue */ }
    }

    // MARK: Behavior Tests

    func test_async_sendsEventsInOrder() {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.async {
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
    }

    func test_async_executesAsyncBlocksSeriallyAndAtomically() {
        let unsafeCounter = UnsafeCounter()
        for iteration in 1...1_000 {
            systemUnderTest.async {
                unsafeCounter.incrementAndExpectCount(equals: iteration)
            }
        }
    }

    func test_async_isNotReentrant() async {
        let counter = Counter()
        await systemUnderTest.await { [systemUnderTest] in
            systemUnderTest.async {
                await counter.incrementAndExpectCount(equals: 2)
            }
            await counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.async {
                await counter.incrementAndExpectCount(equals: 3)
            }
        }
    }

    func test_async_retainsReceiverUntilFlushed() async {
        var systemUnderTest: AsyncQueue? = AsyncQueue()
        let counter = Counter()
        let expectation = self.expectation(description: #function)
        await withThrowingTaskGroup(of: Void.self) { taskGroup in
            let foreverSleep = Task {
                try await Task.sleep(nanoseconds: UInt64.max)
            }
            taskGroup.addTask {
                try await foreverSleep.value
            }
            systemUnderTest?.async {
                // Make the queue wait.
                try? await foreverSleep.value
                await counter.incrementAndExpectCount(equals: 1)
            }
            systemUnderTest?.async {
                // This async task should not execute until the sleep is cancelled.
                await counter.incrementAndExpectCount(equals: 2)
                expectation.fulfill()
            }
            // Nil out our reference to the queue to show that the enqueued tasks will still complete
            systemUnderTest = nil
            // Cancel the sleep timer to unlock the remaining enqueued tasks.
            foreverSleep.cancel()

            await waitForExpectations(timeout: 1.0)
        }
    }

    func test_await_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.async {
                await counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.await {
                let count = await counter.count
                XCTAssertEqual(count, iteration)
            }
        }
    }

    func test_await_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await systemUnderTest.await { expectedValue }
        XCTAssertEqual(expectedValue, returnedValue)
    }

    func test_await_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await systemUnderTest.await { throw expectedError }
        } catch {
            XCTAssertEqual(error as? TestError, expectedError)
        }
    }

    // MARK: Private

    private var systemUnderTest = AsyncQueue()

    // MARK: - Counter

    private actor Counter {
        func incrementAndExpectCount(equals expectedCount: Int) {
            increment()
            XCTAssertEqual(expectedCount, count)
        }

        func increment() {
            count += 1
        }

        var count = 0
    }

    // MARK: - UnsafeCounter

    /// A counter that is explicitly not safe to utilize concurrently.
    private final class UnsafeCounter: @unchecked Sendable {
        func incrementAndExpectCount(equals expectedCount: Int) {
            count += 1
            XCTAssertEqual(expectedCount, count)
        }

        var count = 0
    }

}
