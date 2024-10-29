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

struct ActorQueueTests {

    // MARK: Initialization

    init() {
        systemUnderTest = ActorQueue<Counter>()
        counter = Counter()
        systemUnderTest.adoptExecutionContext(of: counter)
    }

    // MARK: Behavior Tests

    @Test func test_adoptExecutionContext_doesNotRetainActor() {
        let systemUnderTest = ActorQueue<Counter>()
        var counter: Counter? = Counter()
        weak var weakCounter = counter
        systemUnderTest.adoptExecutionContext(of: counter!)
        counter = nil
        #expect(weakCounter == nil)
    }

    @Test func test_enqueue_retainsAdoptedActorUntilEnqueuedTasksComplete() async {
        let systemUnderTest = ActorQueue<Counter>()
        var counter: Counter? = Counter()
        weak var weakCounter = counter
        systemUnderTest.adoptExecutionContext(of: counter!)

        let semaphore = Semaphore()
        systemUnderTest.enqueue { counter in
            await semaphore.wait()
        }

        counter = nil
        #expect(weakCounter != nil)
        await semaphore.signal()
    }

    @Test func test_enqueue_taskParameterIsAdoptedActor() async {
        let semaphore = Semaphore()
        systemUnderTest.enqueue { [storedCounter = counter] counter in
            #expect(counter === storedCounter)
            await semaphore.signal()
        }

        await semaphore.wait()
    }

    @Test func test_enqueueAndWait_taskParameterIsAdoptedActor() async {
        await systemUnderTest.enqueueAndWait { [storedCounter = counter] counter in
            #expect(counter === storedCounter)
        }
    }

    @Test func test_enqueue_sendsEventsInOrder() async {
        for iteration in 1...1_000 {
            systemUnderTest.enqueue { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { _ in /* Drain the queue */ }
    }

    @Test func test_enqueue_startsExecutionOfNextTaskAfterSuspension() async {
        let systemUnderTest = ActorQueue<Semaphore>()
        let semaphore = Semaphore()
        systemUnderTest.adoptExecutionContext(of: semaphore)

        systemUnderTest.enqueue { semaphore in
            await semaphore.wait()
        }
        systemUnderTest.enqueue { semaphore in
            // Signal the semaphore from the actor queue.
            // If the actor queue were FIFO, this test would hang since this code would never execute:
            // we'd still be waiting for the prior `wait()` tasks to finish.
            semaphore.signal()
        }
        await systemUnderTest.enqueueAndWait { _ in /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_allowsReentrancy() async {
        await systemUnderTest.enqueueAndWait { [systemUnderTest] counter in
            await systemUnderTest.enqueueAndWait { counter in
                counter.incrementAndExpectCount(equals: 1)
            }
            counter.incrementAndExpectCount(equals: 2)
        }
    }

    @Test func test_enqueue_executesEnqueuedTasksAfterReceiverIsDeallocated() async {
        var systemUnderTest: ActorQueue<Counter>? = ActorQueue()
        systemUnderTest?.adoptExecutionContext(of: counter)

        let expectation = Expectation()
        let semaphore = Semaphore()
        systemUnderTest?.enqueue { counter in
            // Make the task wait.
            await semaphore.wait()
            counter.incrementAndExpectCount(equals: 1)
            expectation.fulfill()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        #expect(queue == nil)
        // Signal the semaphore to unlock the enqueued tasks.
        await semaphore.signal()
        await expectation.fulfillment(withinSeconds: 1)
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
        await expectation.fulfillment(withinSeconds: 1)

        #expect(referenceHolder.weakReference == nil)
    }

    @Test func test_enqueueAndWait_sendsEventsInOrder() async {
        for iteration in 1...1_000 {
            systemUnderTest.enqueue { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }

            guard iteration % 25 == 0 else {
                // Keep sending async events to the queue.
                continue
            }

            await systemUnderTest.enqueueAndWait { counter in
                #expect(counter.count == iteration)
            }
        }
        await systemUnderTest.enqueueAndWait { _ in /* Drain the queue */ }
    }

    @Test func test_enqueueAndWait_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await systemUnderTest.enqueueAndWait { _ in expectedValue }
        #expect(expectedValue == returnedValue)
    }

    @Test func test_enqueueAndWait_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await systemUnderTest.enqueueAndWait { _ in throw expectedError }
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    // MARK: Private

    private let systemUnderTest: ActorQueue<Counter>
    private let counter: Counter
}
