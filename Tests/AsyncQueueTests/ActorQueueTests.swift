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

    @Test func test_task_retainsAdoptedActorUntilEnqueuedTasksComplete() async {
        let systemUnderTest = ActorQueue<Counter>()
        var counter: Counter? = Counter()
        weak var weakCounter = counter
        systemUnderTest.adoptExecutionContext(of: counter!)

        let semaphore = Semaphore()
        Task(on: systemUnderTest) { counter in
            await semaphore.wait()
        }

        counter = nil
        #expect(weakCounter != nil)
        await semaphore.signal()
    }

    @Test func test_throwingTask_retainsAdoptedActorUntilEnqueuedTasksComplete() async {
        let systemUnderTest = ActorQueue<Counter>()
        var counter: Counter? = Counter()
        weak var weakCounter = counter
        systemUnderTest.adoptExecutionContext(of: counter!)

        let semaphore = Semaphore()
        Task(on: systemUnderTest) { counter in
            await semaphore.wait()
            try doWork()
        }

        counter = nil
        #expect(weakCounter != nil)
        await semaphore.signal()
    }

    @Test func test_task_taskParameterIsAdoptedActor() async {
        let semaphore = Semaphore()
        Task(on: systemUnderTest) { [storedCounter = counter] counter in
            #expect(counter === storedCounter)
            await semaphore.signal()
        }

        await semaphore.wait()
    }

    @Test func test_throwingTask_taskParameterIsAdoptedActor() async {
        let semaphore = Semaphore()
        Task(on: systemUnderTest) { [storedCounter = counter] counter in
            #expect(counter === storedCounter)
            await semaphore.signal()
            try doWork()
        }

        await semaphore.wait()
    }

    @Test func test_task_sendsEventsInOrder() async throws {
        var lastTask: Task<Void, Never>?
        (1...1_000).forEach { iteration in
            lastTask = Task(on: systemUnderTest) { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }
        }
        // Drain the queue
        try await #require(lastTask).value
    }

    @Test func test_throwingTask_sendsEventsInOrder() async throws {
        var lastTask: Task<Void, Error>?
        (1...1_000).forEach { iteration in
            lastTask = Task(on: systemUnderTest) { counter in
                counter.incrementAndExpectCount(equals: iteration)
                try doWork()
            }
        }
        // Drain the queue
        try await #require(lastTask).value
    }

    @TestingQueue
    @Test func test_mainTask_sendsEventsInOrder() async throws {
        var lastTask: Task<Void, Error>?
        (1...1_000).forEach { iteration in
            lastTask = Task(on: MainActor.queue) {
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
        // Drain the queue
        try await #require(lastTask).value
    }

    @TestingQueue
    @Test func test_mainThrowingTask_sendsEventsInOrder() async throws {
        var lastTask: Task<Void, Error>?
        (1...1_000).forEach { iteration in
            lastTask = Task(on: MainActor.queue) {
                await counter.incrementAndExpectCount(equals: iteration)
                try doWork()
            }
        }
        // Drain the queue
        try await #require(lastTask).value
    }

    @Test func test_task_startsExecutionOfNextTaskAfterSuspension() async {
        let systemUnderTest = ActorQueue<AsyncQueue.Semaphore>()
        let semaphore = AsyncQueue.Semaphore()
        systemUnderTest.adoptExecutionContext(of: semaphore)

        let firstTask = Task(on: systemUnderTest) { semaphore in
            await semaphore.wait()
        }
        let secondTask = Task(on: systemUnderTest) { semaphore in
            // Signal the semaphore from the actor queue.
            // If the actor queue were FIFO, this test would hang since this code would never execute:
            // we'd still be waiting for the prior `wait()` tasks to finish.
            semaphore.signal()
        }
        (_, _) = await (firstTask.value, secondTask.value)
    }

    @Test func test_throwingTask_startsExecutionOfNextTaskAfterSuspension() async throws {
        let systemUnderTest = ActorQueue<AsyncQueue.Semaphore>()
        let semaphore = AsyncQueue.Semaphore()
        systemUnderTest.adoptExecutionContext(of: semaphore)

        let firstTask = Task(on: systemUnderTest) { semaphore in
            await semaphore.wait()
            try doWork()
        }
        let secondTask = Task(on: systemUnderTest) { semaphore in
            // Signal the semaphore from the actor queue.
            // If the actor queue were FIFO, this test would hang since this code would never execute:
            // we'd still be waiting for the prior `wait()` tasks to finish.
            semaphore.signal()
            try doWork()
        }
        (_, _) = try await (firstTask.value, secondTask.value)
    }

    @Test func test_task_allowsReentrancy() async {
        await Task(on: systemUnderTest) { [systemUnderTest] counter in
            await Task(on: systemUnderTest) { counter in
                counter.incrementAndExpectCount(equals: 1)
            }.value
            counter.incrementAndExpectCount(equals: 2)
        }.value
    }

    @Test func test_throwingTask_allowsReentrancy() async throws {
        try await Task(on: systemUnderTest) { [systemUnderTest] counter in
            try doWork()
            try await Task(on: systemUnderTest) { counter in
                try doWork()
                counter.incrementAndExpectCount(equals: 1)
            }.value
            try doWork()
            counter.incrementAndExpectCount(equals: 2)
        }.value
    }

    @TestingQueue
    @Test func test_mainTask_allowsReentrancy() async {
        await Task(on: MainActor.queue) { [counter] in
            await Task(on: MainActor.queue) {
                await counter.incrementAndExpectCount(equals: 1)
            }.value
            await counter.incrementAndExpectCount(equals: 2)
        }.value
    }

    @TestingQueue
    @Test func test_mainThrowingTask_allowsReentrancy() async throws {
        try await Task(on: MainActor.queue) { [counter] in
            try doWork()
            try await Task(on: MainActor.queue) {
                try doWork()
                await counter.incrementAndExpectCount(equals: 1)
            }.value
            try doWork()
            await counter.incrementAndExpectCount(equals: 2)
        }.value
    }

    @Test func test_task_executesEnqueuedTasksAfterQueueIsDeallocated() async throws {
        var systemUnderTest: ActorQueue<Counter>? = ActorQueue()
        systemUnderTest?.adoptExecutionContext(of: counter)

        let expectation = Expectation()
        let semaphore = AsyncQueue.Semaphore()
        Task(on: try #require(systemUnderTest)) { counter in
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
        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test func test_throwingTask_executesEnqueuedTasksAfterQueueIsDeallocated() async throws {
        var systemUnderTest: ActorQueue<Counter>? = ActorQueue()
        systemUnderTest?.adoptExecutionContext(of: counter)

        let expectation = Expectation()
        let semaphore = AsyncQueue.Semaphore()
        Task(on: try #require(systemUnderTest)) { counter in
            try doWork()

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
        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test func test_task_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await Task(on: systemUnderTest) { _ in expectedValue }.value
        #expect(expectedValue == returnedValue)
    }

    @Test func test_throwingTask_canReturn() async throws {
        let expectedValue = UUID()
        @Sendable func generateValue() throws -> UUID {
            expectedValue
        }
        #expect(try await Task(on: systemUnderTest) { _ in try generateValue() }.value == expectedValue)
    }

    @Test func test_throwingTask_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await Task(on: systemUnderTest) { _ in throw expectedError }.value
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    @Test func test_mainThrowingTask_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await Task(on: MainActor.queue) { throw expectedError }.value
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    @Test func test_mainTask_executesOnMainActor() async {
        @MainActor
        func executesOnMainActor() {}
        await Task(on: MainActor.queue) {
            executesOnMainActor()
        }.value
    }

    @Test func test_mainThrowingTask_executesOnMainActor() async throws {
        @MainActor
        func executesOnMainActor() throws {}
        try await Task(on: MainActor.queue) {
            try executesOnMainActor()
        }.value
    }

    // MARK: Private

    private let systemUnderTest: ActorQueue<Counter>
    private let counter: Counter

    @Sendable private func doWork() throws -> Void {}
}

/// A global actor that runs off of `main`, where tests may otherwise deadlock due to waiting for `main` from `main`.
@globalActor
private struct TestingQueue {
    fileprivate actor Shared {}
    fileprivate static let shared = Shared()
}
