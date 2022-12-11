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

final class ActorQueueTests: XCTestCase {

    // MARK: XCTestCase

    override func setUp() async throws {
        try await super.setUp()

        systemUnderTest = ActorQueue()
    }

    // MARK: Behavior Tests

    func test_async_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.async(on: counter) { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.await(on: counter) { _ in /* Drain the queue */ }
    }

    func test_async_startsExecutionOfNextTaskAfterSuspension() async {
        let semaphore = Semaphore()
        systemUnderTest.async(on: semaphore) { semaphore in
            await semaphore.wait()
        }
        systemUnderTest.async(on: semaphore) { semaphore in
            // Signal the semaphore from the actor queue.
            // If the actor queue were FIFO, this test would hang since this code would never execute:
            // we'd still be waiting for the prior `wait()` tasks to finish.
            semaphore.signal()
        }
        await systemUnderTest.await(on: semaphore) { _ in /* Drain the queue */ }
    }

    func test_await_allowsReentrancy() async {
        let counter = Counter()
        await systemUnderTest.await(on: counter) { [systemUnderTest] counter in
            await systemUnderTest.await(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 1)
            }
            counter.incrementAndExpectCount(equals: 2)
        }
    }

    func test_async_executesEnqueuedTasksAfterReceiverIsDeallocated() async {
        var systemUnderTest: ActorQueue? = ActorQueue()
        let counter = Counter()
        let expectation = self.expectation(description: #function)
        let semaphore = Semaphore()
        systemUnderTest?.async(on: counter) { counter in
            // Make the task wait.
            await semaphore.wait()
            counter.incrementAndExpectCount(equals: 1)
            expectation.fulfill()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        XCTAssertNil(queue)
        // Signal the semaphore to unlock the enqueued tasks.
        await semaphore.signal()

        await waitForExpectations(timeout: 1.0)
    }

    func test_async_doesNotRetainTaskAfterExecution() async {
        final class Reference: Sendable {}
        final class ReferenceHolder: @unchecked Sendable {
            init() {
                reference = Reference()
                weakReference = reference
            }
            private(set) var reference: Reference?
            private(set) weak var weakReference: Reference?

            func clearReference() {
                reference = nil
            }
        }
        let referenceHolder = ReferenceHolder()
        let asyncSemaphore = Semaphore()
        let syncSemaphore = Semaphore()
        let expectation = self.expectation(description: #function)
        systemUnderTest.async(on: syncSemaphore) { [reference = referenceHolder.reference] syncSemaphore in
            // Now that we've started the task and captured the reference, release the synchronous code.
            syncSemaphore.signal()
            // Wait for the synchronous setup to complete and the reference to be nil'd out.
            await asyncSemaphore.wait()
            // Retain the unsafe counter until the task is completed.
            _ = reference
            self.systemUnderTest.async(on: syncSemaphore) { _ in
                // Signal that this task has cleaned up.
                // This closure will not execute until the prior closure completes.
                expectation.fulfill()
            }
        }
        // Wait for the asynchronous task to start.
        await syncSemaphore.wait()
        referenceHolder.clearReference()
        XCTAssertNotNil(referenceHolder.weakReference)
        // Allow the enqueued task to complete.
        await asyncSemaphore.signal()
        // Make sure the task has completed.
        await waitForExpectations(timeout: 1.0)

        XCTAssertNil(referenceHolder.weakReference)
    }

    func test_await_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.async(on: counter) { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.await(on: counter) { counter in
                let count = counter.count
                XCTAssertEqual(count, iteration)
            }
        }
        await systemUnderTest.await(on: counter) { counter in /* Drain the queue */ }
    }

    func test_await_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await systemUnderTest.await(on: Counter()) { _ in expectedValue }
        XCTAssertEqual(expectedValue, returnedValue)
    }

    func test_await_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await systemUnderTest.await(on: Counter()) { _ in throw expectedError }
        } catch {
            XCTAssertEqual(error as? TestError, expectedError)
        }
    }

    // MARK: Private

    private var systemUnderTest = ActorQueue()
}
