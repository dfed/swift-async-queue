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

final class FIFOQueueTests: XCTestCase {

    // MARK: XCTestCase

    override func setUp() async throws {
        try await super.setUp()

        systemUnderTest = FIFOQueue()
    }

    // MARK: Behavior Tests

    func test_async_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.async {
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.await { /* Drain the queue */ }
    }

    func test_async_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            systemUnderTest.async {
                let isWaiting = await semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by replacing `systemUnderTest.async` above with `Task`.
                XCTAssertFalse(isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    await semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
            }
        }
        await systemUnderTest.await { /* Drain the queue */ }
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
        await systemUnderTest.await { /* Drain the queue */ }
    }

    func test_async_retainsReceiverUntilFlushed() async {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = self.expectation(description: #function)
        let semaphore = Semaphore()
        systemUnderTest?.async {
            // Make the queue wait.
            await semaphore.wait()
            await counter.incrementAndExpectCount(equals: 1)
        }
        systemUnderTest?.async {
            // This async task should not execute until the semaphore is released.
            await counter.incrementAndExpectCount(equals: 2)
            expectation.fulfill()
        }
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        // Signal the semaphore to unlock the remaining enqueued tasks.
        await semaphore.signal()

        await waitForExpectations(timeout: 1.0)
    }

    func test_async_doesNotRetainTaskAfterExecution() async {
        final class Reference: Sendable {}
        final class ReferenceHolder: @unchecked Sendable {
            var reference: Reference? = Reference()
        }
        let referenceHolder = ReferenceHolder()
        weak var weakReference = referenceHolder.reference
        let asyncSemaphore = Semaphore()
        let syncSemaphore = Semaphore()
        systemUnderTest.async { [reference = referenceHolder.reference] in
            // Now that we've started the task and captured the reference, release the synchronous code.
            await syncSemaphore.signal()
            // Wait for the synchronous setup to complete and the reference to be nil'd out.
            await asyncSemaphore.wait()
            // Retain the unsafe counter until the task is completed.
            _ = reference
        }
        // Wait for the asynchronous task to start.
        await syncSemaphore.wait()
        referenceHolder.reference = nil
        XCTAssertNotNil(weakReference)
        // Allow the enqueued task to complete.
        await asyncSemaphore.signal()
        // Make sure the task has completed.
        await systemUnderTest.await { /* Drain the queue */ }
        XCTAssertNil(weakReference)
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
        await systemUnderTest.await { /* Drain the queue */ }
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

    private var systemUnderTest = FIFOQueue()
}
