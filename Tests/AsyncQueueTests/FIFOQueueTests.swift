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

    @Test
    func task_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @MainActor
    @Test
    func task_sendsEventsInOrderInLocalContext() async {
        var count = 0
        for iteration in 1...1_000 {
            Task(on: systemUnderTest) {
                count += 1
                #expect(iteration == count)
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func taskIsolatedTo_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: iteration)
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTask_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: iteration)
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTaskIsolatedTo_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: iteration)
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func task_interleavedWithTaskIsolatedTo_andThrowing_sendsEventsInOrder() async {
        let counter = Counter()
        for iteration in 1...1_000 {
            let mod = iteration % 4
            if mod == 0 {
                Task(on: systemUnderTest) {
                    await counter.incrementAndExpectCount(equals: iteration)
                }
            } else if mod == 1 {
                Task(on: systemUnderTest, isolatedTo: counter) { counter in
                    counter.incrementAndExpectCount(equals: iteration)
                }
            } else if mod == 2 {
                Task(on: systemUnderTest) {
                    await counter.incrementAndExpectCount(equals: iteration)
                    try doWork()
                }
            } else {
                Task(on: systemUnderTest, isolatedTo: counter) { counter in
                    counter.incrementAndExpectCount(equals: iteration)
                    try doWork()
                }
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func task_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            Task(on: systemUnderTest) {
                let isWaiting = await semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by deleting `on: systemUnderTest` above.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    await semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func taskIsolatedTo_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            Task(on: systemUnderTest, isolatedTo: semaphore) { semaphore in
                let isWaiting = semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by deleting `on: systemUnderTest` above.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTask_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            Task(on: systemUnderTest) {
                let isWaiting = await semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by deleting `on: systemUnderTest` above.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    await semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTaskIsolatedTo_executesAsyncBlocksAtomically() async {
        let semaphore = Semaphore()
        for _ in 1...1_000 {
            Task(on: systemUnderTest, isolatedTo: semaphore) { semaphore in
                let isWaiting = semaphore.isWaiting
                // This test will fail occasionally if we aren't executing atomically.
                // You can prove this to yourself by deleting `on: systemUnderTest` above.
                #expect(!isWaiting)
                // Signal the semaphore before or after we wait – let the scheduler decide.
                Task {
                    semaphore.signal()
                }
                // Wait for the concurrent task to complete.
                await semaphore.wait()
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func task_isNotReentrant() async {
        let counter = Counter()
        Task(on: systemUnderTest) { [systemUnderTest] in
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: 2)
            }
            await counter.incrementAndExpectCount(equals: 1)
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: 3)
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func taskIsolatedTo_isNotReentrant() async {
        let counter = Counter()
        Task(on: systemUnderTest, isolatedTo: counter) { [systemUnderTest] counter in
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: 2)
            }
            counter.incrementAndExpectCount(equals: 1)
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: 3)
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTask_isNotReentrant() async {
        let counter = Counter()
        Task(on: systemUnderTest) { [systemUnderTest] in
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: 2)
                try doWork()
            }
            await counter.incrementAndExpectCount(equals: 1)
            Task(on: systemUnderTest) {
                await counter.incrementAndExpectCount(equals: 3)
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func throwingTaskIsolatedTo_isNotReentrant() async throws {
        let counter = Counter()
        Task(on: systemUnderTest, isolatedTo: counter) { [systemUnderTest] counter in
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: 2)
                try doWork()
            }
            counter.incrementAndExpectCount(equals: 1)
            Task(on: systemUnderTest, isolatedTo: counter) { counter in
                counter.incrementAndExpectCount(equals: 3)
                try doWork()
            }
        }
        await Task(on: systemUnderTest) { /* Drain the queue */ }.value
    }

    @Test
    func task_executesAfterQueueIsDeallocated() async throws {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        Task(on: try #require(systemUnderTest)) {
            // Make the queue wait.
            await semaphore.wait()
            await counter.incrementAndExpectCount(equals: 1)
        }
        Task(on: try #require(systemUnderTest)) {
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

        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test
    func taskIsolatedTo_executesAfterQueueIsDeallocated() async throws {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        Task(on: try #require(systemUnderTest), isolatedTo: counter) { counter in
            // Make the queue wait.
            await semaphore.wait()
            counter.incrementAndExpectCount(equals: 1)
        }
        Task(on: try #require(systemUnderTest), isolatedTo: counter) { counter in
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

        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test
    func throwingTask_executesAfterQueueIsDeallocated() async throws {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        Task(on: try #require(systemUnderTest)) {
            // Make the queue wait.
            await semaphore.wait()
            await counter.incrementAndExpectCount(equals: 1)
            try doWork()
        }
        Task(on: try #require(systemUnderTest)) {
            // This async task should not execute until the semaphore is released.
            await counter.incrementAndExpectCount(equals: 2)
            expectation.fulfill()
            try doWork()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        #expect(queue == nil)
        // Signal the semaphore to unlock the remaining enqueued tasks.
        await semaphore.signal()

        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test
    func throwingTaskIsolatedTo_executesAfterQueueIsDeallocated() async throws {
        var systemUnderTest: FIFOQueue? = FIFOQueue()
        let counter = Counter()
        let expectation = Expectation()
        let semaphore = Semaphore()
        Task(on: try #require(systemUnderTest), isolatedTo: counter) { counter in
            // Make the queue wait.
            await semaphore.wait()
            counter.incrementAndExpectCount(equals: 1)
            try doWork()
        }
        Task(on: try #require(systemUnderTest), isolatedTo: counter) { counter in
            // This async task should not execute until the semaphore is released.
            counter.incrementAndExpectCount(equals: 2)
            expectation.fulfill()
            try doWork()
        }
        weak var queue = systemUnderTest
        // Nil out our reference to the queue to show that the enqueued tasks will still complete
        systemUnderTest = nil
        #expect(queue == nil)
        // Signal the semaphore to unlock the remaining enqueued tasks.
        await semaphore.signal()

        await expectation.fulfillment(withinSeconds: 30)
    }

    @Test
    func task_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await Task(on: systemUnderTest) { expectedValue }.value
        #expect(expectedValue == returnedValue)
    }

    @Test
    func taskIsolatedTo_canReturn() async {
        let expectedValue = UUID()
        let returnedValue = await Task(on: systemUnderTest, isolatedTo: Semaphore()) { _ in expectedValue }.value
        #expect(expectedValue == returnedValue)
    }

    @Test
    func throwingTask_canReturn() async throws {
        let expectedValue = UUID()
        @Sendable func generateValue() throws -> UUID {
            expectedValue
        }
        #expect(try await Task(on: systemUnderTest) { try generateValue() }.value == expectedValue)
    }

    @Test
    func throwingTaskIsolatedTo_canReturn() async throws {
        let expectedValue = UUID()
        @Sendable func generateValue() throws -> UUID {
            expectedValue
        }
        #expect(try await Task(on: systemUnderTest, isolatedTo: Semaphore()) { _ in try generateValue() }.value == expectedValue)
    }

    @Test
    func throwingTask_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await Task(on: systemUnderTest) { throw expectedError }.value
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    @Test
    func throwingTaskIsolatedTo_canThrow() async {
        struct TestError: Error, Equatable {
            private let identifier = UUID()
        }
        let expectedError = TestError()
        do {
            try await Task(on: systemUnderTest, isolatedTo: Semaphore()) { _ in throw expectedError }.value
        } catch {
            #expect(error as? TestError == expectedError)
        }
    }

    // MARK: Private

    private let systemUnderTest = FIFOQueue()

    @Sendable private func doWork() throws -> Void {}
}
