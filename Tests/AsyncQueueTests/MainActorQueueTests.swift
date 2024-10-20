// MIT License
//
// Copyright (c) 2023 Dan Federman
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

struct MainActorQueueTests {
    // MARK: Behavior Tests

    @Test func test_shared_returnsSameInstance() async {
        #expect(MainActorQueue.shared === MainActorQueue.shared)
    }

    @Test func test_enqueue_executesOnMainThread() async {
        let key: DispatchSpecificKey<Void> = .init()
        DispatchQueue.main.setSpecific(key: key, value: ())
        systemUnderTest.enqueue {
            #expect(DispatchQueue.main.getSpecific(key: key) != nil)
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_sendsEventsInOrder() async {
        for iteration in 1...1_000 {
            systemUnderTest.enqueue { [counter] in
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueue_startsExecutionOfNextTaskAfterSuspension() async {
        let semaphore = Semaphore()

        systemUnderTest.enqueue {
            await semaphore.wait()
        }
        systemUnderTest.enqueue {
            // Signal the semaphore from the actor queue.
            // If the actor queue were FIFO, this test would hang since this code would never execute:
            // we'd still be waiting for the prior `wait()` tasks to finish.
            await semaphore.signal()
        }
        await systemUnderTest.enqueueAndWait { /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_executesOnMainThread() async {
        let key: DispatchSpecificKey<Void> = .init()
        DispatchQueue.main.setSpecific(key: key, value: ())
        await systemUnderTest.enqueueAndWait {
            #expect(DispatchQueue.main.getSpecific(key: key) != nil)
        }
    }

    @Test func test_enqueueAndWait_allowsReentrancy() async {
        await systemUnderTest.enqueueAndWait { [systemUnderTest, counter] in
            await systemUnderTest.enqueueAndWait { [counter] in
                await counter.incrementAndExpectCount(equals: 1)
            }
            await counter.incrementAndExpectCount(equals: 2)
        }
    }

    @Test func test_enqueue_doesNotRetainTaskAfterExecution() async {
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
        let systemUnderTest = ActorQueue<Semaphore>()
        systemUnderTest.adoptExecutionContext(of: syncSemaphore)

        let expectation = Expectation()
        systemUnderTest.enqueue { [reference = referenceHolder.reference] syncSemaphore in
            // Now that we've started the task and captured the reference, release the synchronous code.
            syncSemaphore.signal()
            // Wait for the synchronous setup to complete and the reference to be nil'd out.
            await asyncSemaphore.wait()
            // Retain the unsafe counter until the task is completed.
            _ = reference
            systemUnderTest.enqueue { _ in
                // Signal that this task has cleaned up.
                // This closure will not execute until the prior closure completes.
                expectation.fulfill()
            }
        }
        // Wait for the asynchronous task to start.
        await syncSemaphore.wait()
        referenceHolder.clearReference()
        #expect(referenceHolder.weakReference != nil)
        // Allow the enqueued task to complete.
        await asyncSemaphore.signal()
        // Make sure the task has completed.
        await expectation.fulfillment(withinSeconds: 10)

        #expect(referenceHolder.weakReference == nil)
    }

    @Test func test_enqueueAndWait_sendsEventsInOrder() async {
        for iteration in 1...1_000 {
            systemUnderTest.enqueue { [counter] in
                await counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.enqueueAndWait { [counter] in
                let count = await counter.count
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

    // MARK: Private

    private let systemUnderTest = MainActorQueue()
    private let counter = Counter()
}
