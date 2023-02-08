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

final class SemaphoreTests: XCTestCase {

    // MARK: XCTestCase

    override func setUp() async throws {
        try await super.setUp()

        systemUnderTest = Semaphore()
    }

    override func tearDown() async throws {
        let isWaiting = await systemUnderTest.isWaiting
        XCTAssertFalse(isWaiting)

        try await super.tearDown()
    }

    // MARK: Behavior Tests

    func test_wait_suspendsUntilEqualNumberOfSignalCalls() async {
        /*
         This test is tricky to pull off!
         Our requirements:
         1. We need to call `wait()` before `signal()`
         2. We need to ensure that the `wait()` call suspends _before_ we call `signal()`
         3. We can't `await` the `wait()` call before calling `signal()` since that would effectively deadlock the test.
         4. We must utilize a single actor's isolated context to avoid accidental interleaving when suspending to communicate across actor contexts.

         In order to ensure that we are executing the `wait()` calls before we call `signal()` _without awaiting a `wait()` call_,
         we utilize the Sempahore's ordered execution context to enqueue ordered `Task`s similar to how an ActorQueue works.
         */

        let iterationCount = 1_000
        /// A counter that will only be accessed from within the `systemUnderTest`'s context
        let unsafeCounter = UnsafeCounter()

        for _ in 1...iterationCount {
            await systemUnderTest.enqueueAndCount(using: unsafeCounter) { systemUnderTest in
                let didSuspend = await systemUnderTest.wait()
                XCTAssertTrue(didSuspend)

                return { systemUnderTest in
                    // Signal that the suspended wait call above has resumed.
                    // This signal allows us to `wait()` for all of these enqueued `wait()` tasks to have completed later in this test.
                    systemUnderTest.signal()
                }
            }
        }

        // Loop one fewer than iterationCount.
        for _ in 1..<iterationCount {
            await systemUnderTest.execute { systemUnderTest in
                systemUnderTest.signal()
            }
        }

        await systemUnderTest.execute { systemUnderTest in
            // Give each suspended `wait` task an opportunity to resume (if they were to resume, which they won't) before we check the count.
            for _ in 1...iterationCount {
                await Task.yield()
            }

            // The count will still be zero each time because we have executed one more `wait` than `signal` calls.
            let completedCountedTasks = unsafeCounter.countedTasksCompleted
            XCTAssertEqual(completedCountedTasks, 0)

            // Signal one last time, enabling all of the original `wait` calls to resume.
            systemUnderTest.signal()

            for _ in 1...iterationCount {
                // Wait for all enqueued `wait`s to have completed and signaled their completion.
                await systemUnderTest.wait()
            }

            let tasksCompleted = unsafeCounter.countedTasksCompleted
            XCTAssertEqual(iterationCount, tasksCompleted)
        }
    }

    func test_wait_doesNotSuspendIfSignalCalledFirst() async {
        await systemUnderTest.signal()
        let didSuspend = await systemUnderTest.wait()
        XCTAssertFalse(didSuspend)
    }

    // MARK: Private

    private var systemUnderTest = Semaphore()
}

// MARK: - Semaphore Extension

private extension Semaphore {
    /// Enqueues an asynchronous task. This method suspends the caller until the asynchronous task has begun, ensuring ordered execution of enqueued tasks.
    /// - Parameter task: A unit of work that returns work to execute after the task completes and the count is incremented.
    func enqueueAndCount(using counter: UnsafeCounter, _ task: @escaping @Sendable (isolated Semaphore) async -> ((isolated Semaphore) -> Void)?) async {
        // Await the start of the soon-to-be-enqueued `Task` with a continuation.
        await withCheckedContinuation { continuation in
            // Re-enter the actor context but don't wait for the result.
            Task {
                // Now that we're back in the actor context, resume the calling code.
                continuation.resume()
                let executeAfterIncrement = await task(self)
                counter.countedTasksCompleted += 1
                executeAfterIncrement?(self)
            }
        }
    }

    func execute(_ task: @Sendable (isolated Semaphore) async throws -> Void) async rethrows {
        try await task(self)
    }
}

// MARK: - UnsafeCounter

private final class UnsafeCounter: @unchecked Sendable {
    var countedTasksCompleted = 0
}
