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
	func task_executesAfterQueueIsDeallocated() async throws {
		var systemUnderTest: FIFOQueue? = FIFOQueue()
		let counter = Counter()
		let semaphore = Semaphore()
		try Task(on: #require(systemUnderTest)) {
			// Make the queue wait.
			await semaphore.wait()
			await counter.incrementAndExpectCount(equals: 1)
		}
		let lastTask = try Task(on: #require(systemUnderTest)) {
			// This async task should not execute until the semaphore is released.
			await counter.incrementAndExpectCount(equals: 2)
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the remaining enqueued tasks.
		await semaphore.signal()

		// Await the last enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		await lastTask.value
	}

	@Test
	func taskIsolatedTo_executesAfterQueueIsDeallocated() async throws {
		var systemUnderTest: FIFOQueue? = FIFOQueue()
		let counter = Counter()
		let semaphore = Semaphore()
		try Task(on: #require(systemUnderTest), isolatedTo: counter) { counter in
			// Make the queue wait.
			await semaphore.wait()
			counter.incrementAndExpectCount(equals: 1)
		}
		let lastTask = try Task(on: #require(systemUnderTest), isolatedTo: counter) { counter in
			// This async task should not execute until the semaphore is released.
			counter.incrementAndExpectCount(equals: 2)
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the remaining enqueued tasks.
		await semaphore.signal()

		// Await the last enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		await lastTask.value
	}

	@Test
	func throwingTask_executesAfterQueueIsDeallocated() async throws {
		var systemUnderTest: FIFOQueue? = FIFOQueue()
		let counter = Counter()
		let semaphore = Semaphore()
		try Task(on: #require(systemUnderTest)) {
			// Make the queue wait.
			await semaphore.wait()
			await counter.incrementAndExpectCount(equals: 1)
			try doWork()
		}
		let lastTask = try Task(on: #require(systemUnderTest)) {
			// This async task should not execute until the semaphore is released.
			await counter.incrementAndExpectCount(equals: 2)
			try doWork()
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the remaining enqueued tasks.
		await semaphore.signal()

		// Await the last enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		try await lastTask.value
	}

	@Test
	func throwingTaskIsolatedTo_executesAfterQueueIsDeallocated() async throws {
		var systemUnderTest: FIFOQueue? = FIFOQueue()
		let counter = Counter()
		let semaphore = Semaphore()
		try Task(on: #require(systemUnderTest), isolatedTo: counter) { counter in
			// Make the queue wait.
			await semaphore.wait()
			counter.incrementAndExpectCount(equals: 1)
			try doWork()
		}
		let lastTask = try Task(on: #require(systemUnderTest), isolatedTo: counter) { counter in
			// This async task should not execute until the semaphore is released.
			counter.incrementAndExpectCount(equals: 2)
			try doWork()
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the remaining enqueued tasks.
		await semaphore.signal()

		// Await the last enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		try await lastTask.value
	}

	@Test
	func task_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: systemUnderTest) {
			await semaphore.wait()
			#expect(Task.isCancelled)
		}
		task.cancel()
		await semaphore.signal()
		await task.value
	}

	@Test
	func taskIsolatedTo_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: systemUnderTest, isolatedTo: Semaphore()) { _ in
			await semaphore.wait()
			#expect(Task.isCancelled)
		}
		task.cancel()
		await semaphore.signal()
		await task.value
	}

	@Test
	func throwingTask_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: systemUnderTest) {
			await semaphore.wait()
			#expect(Task.isCancelled)
			throw CancellationError() // This is wonky, but we can't `try` if we want 100% code coverage.
		}
		task.cancel()
		await semaphore.signal()
		try? await task.value
	}

	@Test
	func throwingTaskIsolatedTo_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: systemUnderTest, isolatedTo: Semaphore()) { _ in
			await semaphore.wait()
			#expect(Task.isCancelled)
			throw CancellationError() // This is wonky, but we can't `try` if we want 100% code coverage.
		}
		task.cancel()
		await semaphore.signal()
		try? await task.value
	}

	@Test
	func task_canBeCancelledFromCancellationHandlerOfAnotherQueuedTask() async {
		let otherQueue = FIFOQueue()
		let taskStarted = Semaphore()
		let innerTaskStarted = Semaphore()
		let task = Task(on: systemUnderTest) {
			let innerTask = Task(on: otherQueue) {
				await innerTaskStarted.signal()
				await suspendUntilCancelled()
				return Task.isCancelled
			}
			return await withTaskCancellationHandler {
				// Wait for the inner operation to start, so that cancelling the inner task runs its cancellation handler.
				await innerTaskStarted.wait()
				await taskStarted.signal()
				return await innerTask.value
			} onCancel: {
				innerTask.cancel()
			}
		}
		await taskStarted.wait()
		task.cancel()
		// The inner task returns only once it is cancelled, so if cancellation does not reach it, this test hangs rather
		// than failing the expectation.
		#expect(await task.value)
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
		@Sendable
		func generateValue() throws -> UUID {
			expectedValue
		}
		#expect(try await Task(on: systemUnderTest) { try generateValue() }.value == expectedValue)
	}

	@Test
	func throwingTaskIsolatedTo_canReturn() async throws {
		let expectedValue = UUID()
		@Sendable
		func generateValue() throws -> UUID {
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

	@Test
	func throwingTask_whenOperationThrows_allowsNextTaskToBegin() async {
		struct TestError: Error {}
		let task = Task(on: systemUnderTest) { throw TestError() }
		// Reserve the turn after the task's turn, as the next task enqueued on the queue would.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		await #expect(throws: TestError.self) { try await task.value }
		// The task ended its turn when its operation threw, so the next turn begins without waiting.
		#expect(hasNextTurnBegun())
	}

	@Test
	func throwingTaskIsolatedTo_whenOperationThrows_allowsNextTaskToBegin() async {
		struct TestError: Error {}
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in throw TestError() }
		// Reserve the turn after the task's turn, as the next task enqueued on the queue would.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		await #expect(throws: TestError.self) { try await task.value }
		// The task ended its turn when its operation threw, so the next turn begins without waiting.
		#expect(hasNextTurnBegun())
	}

	@Test
	func task_holdsTurnUntilItsOperationReturns() async {
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: systemUnderTest) {
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
		}
		await operationStarted.wait()
		// The task holds its turn until its operation returns, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		let didNextTurnBeginBeforeOperationReturned = hasNextTurnBegun()
		await operationAllowedToReturn.signal()
		await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeOperationReturned)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func throwingTask_holdsTurnUntilItsOperationReturns() async throws {
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: systemUnderTest) {
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
			try doWork()
		}
		await operationStarted.wait()
		// The task holds its turn until its operation returns, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		let didNextTurnBeginBeforeOperationReturned = hasNextTurnBegun()
		await operationAllowedToReturn.signal()
		try await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeOperationReturned)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func taskIsolatedTo_holdsTurnUntilItsOperationReturns() async {
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
		}
		await operationStarted.wait()
		// The task holds its turn until its operation returns, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		let didNextTurnBeginBeforeOperationReturned = hasNextTurnBegun()
		await operationAllowedToReturn.signal()
		await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeOperationReturned)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func throwingTaskIsolatedTo_holdsTurnUntilItsOperationReturns() async throws {
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
			try doWork()
		}
		await operationStarted.wait()
		// The task holds its turn until its operation returns, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: systemUnderTest.turns)
		let didNextTurnBeginBeforeOperationReturned = hasNextTurnBegun()
		await operationAllowedToReturn.signal()
		try await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeOperationReturned)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func task_seesCallersTaskLocalValues() async throws {
		let systemUnderTest = TestTaskLocal.$value.withValue("queue creator") {
			FIFOQueue()
		}
		let values = try await TestTaskLocal.$value.withValue("caller") {
			try await [
				Task(on: systemUnderTest) { TestTaskLocal.value }.value,
				Task(on: systemUnderTest) { try doWork(); return TestTaskLocal.value }.value,
				Task(on: systemUnderTest, isolatedTo: Counter()) { _ in TestTaskLocal.value }.value,
				Task(on: systemUnderTest, isolatedTo: Counter()) { _ in try doWork(); return TestTaskLocal.value }.value,
			]
		}
		#expect(values == Array(repeating: "caller", count: 4))
		#expect(await Task(on: systemUnderTest) { TestTaskLocal.value }.value == "default")
	}

	@Test
	func task_withNilPriority_inheritsCallersPriority() async {
		let systemUnderTest = await Task.detached(priority: .background) { FIFOQueue() }.value
		for priority in [TaskPriority.background, .low, .medium, .high] {
			let executionPriorities = await [
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: systemUnderTest) { report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: systemUnderTest) { try doWork(); report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: systemUnderTest, isolatedTo: Counter()) { _ in try doWork(); report(Task.currentPriority) }
				},
			]
			#expect(executionPriorities == Array(repeating: priority, count: 4))
		}
	}

	@Test
	func task_withPriority_executesAtThatPriority() async {
		for priority in [TaskPriority.background, .low, .medium, .high] {
			let executionPriorities = await [
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest) { report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest) { try doWork(); report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest, isolatedTo: Counter()) { _ in try doWork(); report(Task.currentPriority) }
				},
			]
			#expect(executionPriorities == Array(repeating: priority, count: 4))
		}
	}

	@Test
	func task_onQueueWithPriority_withLowerPriority_executesAtQueuePriority() async {
		let systemUnderTest = FIFOQueue(priority: .medium)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: systemUnderTest) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.medium, .medium])
	}

	@Test
	func task_onQueueWithPriority_withHigherPriority_executesAtThatPriority() async {
		let systemUnderTest = FIFOQueue(priority: .medium)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: systemUnderTest) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.high, .high])
	}

	@Test
	func task_onQueueWithPriority_withNilPriority_executesAtHigherOfCallersAndQueuePriority() async {
		let systemUnderTest = FIFOQueue(priority: .medium)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: systemUnderTest) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: systemUnderTest) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: systemUnderTest, isolatedTo: Counter()) { _ in report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.medium, .high, .medium, .high])
	}

	@Test
	func task_onQueueWithPriority_enqueuedFromEscalatedTaskWithLowerBasePriority_executesAtQueuePriority() async {
		let systemUnderTest = FIFOQueue(priority: .medium)
		let enqueuingTaskAllowedToEnqueue = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		let enqueuingTask = Task.detached(priority: .background) {
			// Wait for a higher-priority task to escalate this task above the queue's priority.
			await enqueuingTaskAllowedToEnqueue.wait()
			// Do not await the enqueued task: awaiting it would escalate it.
			Task(on: systemUnderTest) {
				prioritiesContinuation.yield(Task.currentPriority)
			}
		}
		await value(of: enqueuingTask, awaitedFromTaskWithPriority: .high) {
			await enqueuingTaskAllowedToEnqueue.signal()
		}
		var prioritiesIterator = priorities.makeAsyncIterator()
		let executionPriority = await prioritiesIterator.next()
		#expect(executionPriority == .medium)
	}

	@Test
	func task_onQueueWithPriority_enqueuedOutsideOfAnyTask_executesAtHigherOfNewTaskAndQueuePriority() async {
		// Threads without a quality of service take the default branch; threads with one, on platforms that support it, do not.
		for qualityOfService in [QualityOfService.default, .userInitiated, .utility] {
			for queuePriority in [TaskPriority.background, .low, .medium, .high] {
				let systemUnderTest = FIFOQueue(priority: queuePriority)
				let (priorities, prioritiesContinuation) = AsyncStream<(isEnqueued: Bool, priority: TaskPriority)>.makeStream()
				// Enqueue from a thread that is not running a task, and create a plain task there for comparison.
				let thread = Thread {
					Task {
						prioritiesContinuation.yield((isEnqueued: false, priority: Task.currentPriority))
					}
					Task(on: systemUnderTest) {
						prioritiesContinuation.yield((isEnqueued: true, priority: Task.currentPriority))
					}
				}
				thread.qualityOfService = qualityOfService
				thread.start()
				var plainTaskPriority: TaskPriority?
				var executionPriority: TaskPriority?
				// The thread reports exactly two priorities: one from each task.
				for await (isEnqueued, priority) in priorities.prefix(2) {
					if isEnqueued {
						executionPriority = priority
					} else {
						plainTaskPriority = priority
					}
				}
				#expect(plainTaskPriority.map { executionPriority == max($0, queuePriority) } == true)
			}
		}
	}

	@Test
	func task_onQueueWithPriority_withUnspecifiedPriority_executesAtHigherOfCallersAndQueuePriority() async {
		let systemUnderTest = FIFOQueue(priority: .low)
		// `Task` treats a priority with a raw value of zero as no priority, so the task inherits the caller's priority.
		let executionPriority = await priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
			Task(priority: TaskPriority(rawValue: 0), on: systemUnderTest) { report(Task.currentPriority) }
		}
		#expect(executionPriority == .high)
	}

	@Test
	func task_onQueueWithUserInteractivePriority_enqueuedFromUserInteractiveTask_executesAtQueuePriority() async {
		let userInteractivePriority = TaskPriority(rawValue: 0x21)
		let systemUnderTest = FIFOQueue(priority: userInteractivePriority)
		// `Task` lowers an inherited user-interactive priority, so only the queue's priority keeps the task user-interactive.
		let executionPriority = await priorityOfTask(enqueuedFromTaskWithPriority: userInteractivePriority) { report in
			Task(on: systemUnderTest) { report(Task.currentPriority) }
		}
		#expect(executionPriority.map { $0 >= userInteractivePriority } == true)
	}

	@Test
	func task_isEscalatedWhenAwaitedFromHigherPriorityTask() async {
		let taskStarted = Semaphore()
		let taskAllowedToReturn = Semaphore()
		let task = Task(priority: .low, on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToReturn.wait()
			return Task.currentPriority
		}
		await taskStarted.wait()
		let priority = await value(of: task, awaitedFromTaskWithPriority: .high) {
			await taskAllowedToReturn.signal()
		}
		#expect(priority >= .high)
	}

	@Test
	func taskIsolatedTo_isEscalatedWhenAwaitedFromHigherPriorityTask() async {
		let taskStarted = Semaphore()
		let taskAllowedToReturn = Semaphore()
		let task = Task(priority: .low, on: systemUnderTest, isolatedTo: Counter()) { _ in
			await taskStarted.signal()
			await taskAllowedToReturn.wait()
			return Task.currentPriority
		}
		await taskStarted.wait()
		let priority = await value(of: task, awaitedFromTaskWithPriority: .high) {
			await taskAllowedToReturn.signal()
		}
		#expect(priority >= .high)
	}

	// MARK: Private

	private let systemUnderTest = FIFOQueue()

	@Sendable
	private func doWork() throws {}
}
