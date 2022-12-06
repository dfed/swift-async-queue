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
        actor CountingExecutor {
            func enqueue(andCount incrementOnCompletion: Bool = false, _ task: @escaping @Sendable () async -> Void) async {
                await withCheckedContinuation { continuation in
                    // Re-enter the actor context but don't wait for the result.
                    Task {
                        // Now that we're back in the actor context, resume.
                        continuation.resume()
                        await task()
                        if incrementOnCompletion {
                            incrementTasksCompleted()
                        }
                    }
                }
            }

            func execute(_ task: @Sendable () async -> Void) async {
                await task()
            }

            var countedTasksCompleted = 0

            private func incrementTasksCompleted() {
                countedTasksCompleted += 1
            }
        }
        let executor = CountingExecutor()
        let iterationCount = 1_000

        for _ in 1...iterationCount {
            await executor.enqueue(andCount: true) {
                let didSuspend = await self.systemUnderTest.wait()
                XCTAssertTrue(didSuspend)

                // Signal without waiting that our prior wait completed.
                Task {
                    await self.systemUnderTest.signal()
                }
            }
        }

        // Loop one fewer than iterationCount.
        // The count will be zero each time because we have more `wait` than `signal` calls.
        for _ in 0..<(iterationCount-1) {
            await executor.enqueue {
                await self.systemUnderTest.signal()
                // Enqueue a task to check the completed task count to give the suspended tasks above time to resume (if they were to resume, which they won't).
                await executor.enqueue {
                    let completedCountedTasks = await executor.countedTasksCompleted
                    XCTAssertEqual(completedCountedTasks, 0)
                }
            }
        }

        await executor.execute {
            // Signal one last time, enabling all of the original `wait` calls to resume.
            await self.systemUnderTest.signal()

            for _ in 1...iterationCount {
                // Wait for all enqueued `wait`s to have completed and signaled their completion.
                await self.systemUnderTest.wait()
            }
            // Enqueue a task to check the completed task count to give the suspended tasks above time to resume.
            await executor.enqueue {
                let tasksCompleted = await executor.countedTasksCompleted
                XCTAssertEqual(iterationCount, tasksCompleted)
            }
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
