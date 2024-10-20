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

import Foundation
import Testing

@testable import AsyncQueue

struct FIFOQueueTests {

    // MARK: Behavior Tests

    @Test func test_enqueue_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueOn_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_enqueueOn_sendEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            if iteration % 2 == 0 {
                systemUnderTest.enqueue {
                    await counter.incrementAndExpectCount(equals: iteration)
                }
            } else {
                systemUnderTest.enqueue(on: counter) { counter in
                    counter.incrementAndExpectCount(equals: iteration)
                }
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            systemUnderTest.enqueue {
                let isWaiting = await semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by replacing `systemUnderTest.enqueue` above with `Task`.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    await semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueOn_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            systemUnderTest.enqueue(on: semaphore) { semaphore in
                let isWaiting = semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by replacing `systemUnderTest.enqueue` above with `Task`.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_isNotReentrant() async {
        let counter = Counter()
        systemUnderTest.enqueue { [systemUnderTest] in
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 2)
            }
            await counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueOn_isNotReentrant() async {
        let counter = Counter()
        systemUnderTest.enqueue(on: counter) { [systemUnderTest] counter in
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 2)
            }
            counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_enqueue_areNotReentrant() async {
        let counter = Counter()
        await systemUnderTest.enqueueAndWait { [systemUnderTest] in
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 2)
            }
            await counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWaitOn_enqueueOn_areNotReentrant() async {
        let counter = Counter()
        await systemUnderTest.enqueueAndWait(on: counter) { [systemUnderTest] counter in
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 2)
            }
            counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_enqueueOn_areNotReentrant() async {
        let counter = Counter()
        await systemUnderTest.enqueueAndWait { [systemUnderTest] in
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 2)
            }
            await counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue(on: counter) { counter in
                counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWaitOn_enqueue_areNotReentrant() async {
        let counter = Counter()
        await systemUnderTest.enqueueAndWait(on: counter) { [systemUnderTest] counter in
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 2)
            }
            counter.incrementAndExpectCount(equals: 1)
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: 3)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_executesAfterReceiverIsDeallocated() async {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        systemUnderTest?.enqueue {
            // Make the queue wait.
            await semaphore.wait()
            await counter.incrementAndExpectCount(equals: 1)
        }
        systemUnderTest?.enqueue {
            // This async task should not execute until the semaphore is released.
            await counter.incrementAndExpectCount(equals: 2)
            expectation.fulfill()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        #expect(queue == nil)
        // Signal the semaphore to unlock the remaining enqueued tasks.
        await semaphore.signal()

        await expectation.fulfillment(withinSeconds: 10)
    }

    @Test func test_enqueueOn_executesAfterReceiverIsDeallocated() async {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        systemUnderTest?.enqueue(on: counter) { counter in
            // Make the queue wait.
            await semaphore.wait()
            counter.incrementAndExpectCount(equals: 1)
        }
        systemUnderTest?.enqueue(on: counter) { counter in
            // This async task should not execute until the semaphore is released.
            counter.incrementAndExpectCount(equals: 2)
            expectation.fulfill()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        #expect(queue == nil)
        // Signal the semaphore to unlock the remaining enqueued tasks.
        await semaphore.signal()

        await expectation.fulfillment(withinSeconds: 10)
    }

    @Test func test_enqueue_doesNotRetainTaskAfterExecution() async {
        final class Reference: Sendable {}
        final class ReferenceHolder: @unchecked Sendable {
            var reference: Reference? = Reference()
        }
        let referenceHolder = ReferenceHolder()
        weak var weakReference = referenceHolder.reference
        let asyncSemaphore = Semaphore()
        let syncSemaphore = Semaphore()
        systemUnderTest.enqueue { [reference = referenceHolder.reference] in
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
        #expect(weakReference != nil)
        // Allow the enqueued task to complete.
        await asyncSemaphore.signal()
        // Make sure the task has completed.
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
        #expect(weakReference == nil)
    }

    @Test func test_enqueueOn_doesNotRetainTaskAfterExecution() async {
        final class Reference: Sendable {}
        final class ReferenceHolder: @unchecked Sendable {
            var reference: Reference? = Reference()
        }
        let referenceHolder = ReferenceHolder()
        weak var weakReference = referenceHolder.reference
        let asyncSemaphore = Semaphore()
        let syncSemaphore = Semaphore()
        systemUnderTest.enqueue(on: syncSemaphore) { [reference = referenceHolder.reference] syncSemaphore in
            // Now that we've started the task and captured the reference, release the synchronous code.
            syncSemaphore.signal()
            // Wait for the synchronous setup to complete and the reference to be nil'd out.
            await asyncSemaphore.wait()
            // Retain the unsafe counter until the task is completed.
            _ = reference
        }
        // Wait for the asynchronous task to start.
        await syncSemaphore.wait()
        referenceHolder.reference = nil
        #expect(weakReference != nil)
        // Allow the enqueued task to complete.
        await asyncSemaphore.signal()
        // Make sure the task has completed.
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
        #expect(weakReference == nil)
    }

    @Test func test_enqueueAndWait_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.enqueueAndWait {
                let count = await counter.count
                #expect(count == iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWaitOn_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            systemUnderTest.enqueue {
                await counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.enqueueAndWait(on: counter) { counter in
                let count = counter.count
                #expect(count == iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await systemUnderTest.enqueueAndWait { expectedValue }
        #expect(expectedValue == returnedValue)
    }

    @Test func test_enqueueAndWait_throwing_canReturn() async throws {
        let expectedValue = UUID()
        @Sendable func throwingMethod() throws {}
        let returnedValue = try await systemUnderTest.enqueueAndWait {
            try throwingMethod()
            return expectedValue
        }
        #expect(expectedValue == returnedValue)
    }

    @Test func test_enqueueAndWaitOn_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await systemUnderTest.enqueueAndWait(on: Counter()) { _ in expectedValue }
        #expect(expectedValue == returnedValue)
    }

    @Test func test_enqueueAndWaitOn_throwing_canReturn() async throws {
        let expectedValue = UUID()
        @Sendable func throwingMethod() throws {}
        let returnedValue = try await systemUnderTest.enqueueAndWait(on: Counter()) { _ in
            try throwingMethod()
            return expectedValue
        }
        #expect(expectedValue == returnedValue)
    }

    @Test func test_enqueueAndWait_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await systemUnderTest.enqueueAndWait { throw expectedError }
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    @Test func test_enqueueAndWaitOn_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await systemUnderTest.enqueueAndWait(on: Counter()) { _ in throw expectedError }
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    // MARK: Private

    private let systemUnderTest = FIFOQueue()
}
