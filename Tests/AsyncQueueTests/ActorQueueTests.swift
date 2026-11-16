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

	@Test
	func adoptExecutionContext_doesNotRetainActor() {
		let systemUnderTest = ActorQueue<Counter>()
		var counter: Counter? = Counter()
		weak let weakCounter = counter
		systemUnderTest.adoptExecutionContext(of: counter!)
		counter = nil
		#expect(weakCounter == nil)
	}

	@Test
	func task_retainsAdoptedActorUntilEnqueuedTasksComplete() async {
		let systemUnderTest = ActorQueue<Counter>()
		var counter: Counter? = Counter()
		weak let weakCounter = counter
		systemUnderTest.adoptExecutionContext(of: counter!)

		let semaphore = Semaphore()
		Task(on: systemUnderTest) { _ in
			await semaphore.wait()
		}

		counter = nil
		#expect(weakCounter != nil)
		await semaphore.signal()
	}

	@Test
	func throwingTask_retainsAdoptedActorUntilEnqueuedTasksComplete() async {
		let systemUnderTest = ActorQueue<Counter>()
		var counter: Counter? = Counter()
		weak let weakCounter = counter
		systemUnderTest.adoptExecutionContext(of: counter!)

		let semaphore = Semaphore()
		Task(on: systemUnderTest) { _ in
			await semaphore.wait()
			try doWork()
		}

		counter = nil
		#expect(weakCounter != nil)
		await semaphore.signal()
	}

	@Test
	func task_taskParameterIsAdoptedActor() async {
		let semaphore = Semaphore()
		Task(on: systemUnderTest) { [storedCounter = counter] counter in
			#expect(counter === storedCounter)
			await semaphore.signal()
		}

		await semaphore.wait()
	}

	@Test
	func throwingTask_taskParameterIsAdoptedActor() async {
		let semaphore = Semaphore()
		Task(on: systemUnderTest) { [storedCounter = counter] counter in
			#expect(counter === storedCounter)
			await semaphore.signal()
			try doWork()
		}

		await semaphore.wait()
	}

	@Test
	func task_sendsEventsInOrder() async throws {
		var lastTask: Task<Void, Never>?
		for iteration in 1...1_000 {
			lastTask = Task(on: systemUnderTest) { counter in
				counter.incrementAndExpectCount(equals: iteration)
			}
		}
		// Drain the queue
		try await #require(lastTask).value
	}

	@Test
	func throwingTask_sendsEventsInOrder() async throws {
		var lastTask: Task<Void, Error>?
		for iteration in 1...1_000 {
			lastTask = Task(on: systemUnderTest) { counter in
				counter.incrementAndExpectCount(equals: iteration)
				try doWork()
			}
		}
		// Drain the queue
		try await #require(lastTask).value
	}

	@Test
	func mainTask_sendsEventsInOrder() async throws {
		// Use a queue of our own rather than `MainActor.queue`: higher-priority tasks that tests running in parallel enqueue
		// on the shared queue escalate the tasks ahead of them, which reorders what those tasks do after they suspend.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		var lastTask: Task<Void, Error>?
		for iteration in 1...1_000 {
			lastTask = Task(on: mainActorQueue) {
				await counter.incrementAndExpectCount(equals: iteration)
			}
		}
		// Drain the queue
		try await #require(lastTask).value
	}

	@Test
	func mainThrowingTask_sendsEventsInOrder() async throws {
		// Use a queue of our own rather than `MainActor.queue`. See `mainTask_sendsEventsInOrder`.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		var lastTask: Task<Void, Error>?
		for iteration in 1...1_000 {
			lastTask = Task(on: mainActorQueue) {
				await counter.incrementAndExpectCount(equals: iteration)
				try doWork()
			}
		}
		// Drain the queue
		try await #require(lastTask).value
	}

	@Test
	func task_startsExecutionOfNextTaskAfterSuspension() async {
		let systemUnderTest = ActorQueue<Semaphore>()
		let semaphore = Semaphore()
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
		_ = await (firstTask.value, secondTask.value)
	}

	@Test
	func throwingTask_startsExecutionOfNextTaskAfterSuspension() async throws {
		let systemUnderTest = ActorQueue<Semaphore>()
		let semaphore = Semaphore()
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
		_ = try await (firstTask.value, secondTask.value)
	}

	@Test
	func task_allowsReentrancy() async {
		await Task(on: systemUnderTest) { [systemUnderTest] counter in
			await Task(on: systemUnderTest) { counter in
				counter.incrementAndExpectCount(equals: 1)
			}.value
			counter.incrementAndExpectCount(equals: 2)
		}.value
	}

	@Test
	func throwingTask_allowsReentrancy() async throws {
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

	@Test
	func mainTask_allowsReentrancy() async {
		await Task(on: MainActor.queue) { [counter] in
			await Task(on: MainActor.queue) {
				await counter.incrementAndExpectCount(equals: 1)
			}.value
			await counter.incrementAndExpectCount(equals: 2)
		}.value
	}

	@Test
	func mainThrowingTask_allowsReentrancy() async throws {
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

	@Test
	func task_executesEnqueuedTasksAfterQueueIsDeallocated() async throws {
		var systemUnderTest: ActorQueue<Counter>? = ActorQueue()
		systemUnderTest?.adoptExecutionContext(of: counter)

		let semaphore = Semaphore()
		let task = try Task(on: #require(systemUnderTest)) { counter in
			// Make the task wait.
			await semaphore.wait()
			counter.incrementAndExpectCount(equals: 1)
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the enqueued tasks.
		await semaphore.signal()

		// Await the enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		await task.value
	}

	@Test
	func throwingTask_executesEnqueuedTasksAfterQueueIsDeallocated() async throws {
		var systemUnderTest: ActorQueue<Counter>? = ActorQueue()
		systemUnderTest?.adoptExecutionContext(of: counter)

		let semaphore = Semaphore()
		let task = try Task(on: #require(systemUnderTest)) { counter in
			try doWork()

			// Make the task wait.
			await semaphore.wait()
			counter.incrementAndExpectCount(equals: 1)
		}
		weak let queue = systemUnderTest
		// Nil out our reference to the queue to show that the enqueued tasks will still complete
		systemUnderTest = nil
		#expect(queue == nil)
		// Signal the semaphore to unlock the enqueued tasks.
		await semaphore.signal()

		// Await the enqueued task to deterministically confirm the enqueued work ran after the queue was deallocated.
		try await task.value
	}

	@Test
	func task_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: systemUnderTest) { _ in
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
		let task = Task(on: systemUnderTest) { _ in
			await semaphore.wait()
			#expect(Task.isCancelled)
			throw CancellationError() // This is wonky, but we can't `try` if we want 100% code coverage.
		}
		task.cancel()
		await semaphore.signal()
		try? await task.value
	}

	@Test
	func mainTask_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: MainActor.queue) { _ in
			await semaphore.wait()
			#expect(Task.isCancelled)
		}
		task.cancel()
		await semaphore.signal()
		await task.value
	}

	@Test
	func mainThrowingTask_canBeCancelled() async {
		let semaphore = Semaphore()
		let task = Task(on: MainActor.queue) { _ in
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
		let taskStarted = Semaphore()
		let innerTaskStarted = Semaphore()
		let task = Task(on: systemUnderTest) { [systemUnderTest] _ in
			let innerTask = Task(on: systemUnderTest) { _ in
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
		let returnedValue = await Task(on: systemUnderTest) { _ in expectedValue }.value
		#expect(expectedValue == returnedValue)
	}

	@Test
	func throwingTask_canReturn() async throws {
		let expectedValue = UUID()
		@Sendable
		func generateValue() throws -> UUID {
			expectedValue
		}
		#expect(try await Task(on: systemUnderTest) { _ in try generateValue() }.value == expectedValue)
	}

	@Test
	func throwingTask_canThrow() async {
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

	@Test
	func mainThrowingTask_canThrow() async {
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

	@Test
	func mainTask_executesOnMainActor() async {
		@MainActor
		func executesOnMainActor() {}
		await Task(on: MainActor.queue) {
			executesOnMainActor()
		}.value
	}

	@Test
	func mainThrowingTask_executesOnMainActor() async throws {
		@MainActor
		func executesOnMainActor() throws {}
		try await Task(on: MainActor.queue) {
			try executesOnMainActor()
		}.value
	}

	@Test
	func task_holdsTurnUntilItIsIsolatedToActor() async {
		let actor = ManuallyExecutedActor()
		var enqueuedJobs = actor.executor.enqueuedJobs.makeAsyncIterator()
		let task = Task(on: actor.queue) { _ in }
		// Wait for the task to hop to the actor, whose executor holds the task's job until the test runs it.
		_ = await enqueuedJobs.next()
		// The task holds its turn until it is isolated to the actor, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: actor.queue.turns)
		let didNextTurnBeginBeforeTaskWasIsolatedToActor = hasNextTurnBegun()
		// Running the task's job isolates the task to the actor, which ends its turn.
		actor.executor.runUntilIdle()
		await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeTaskWasIsolatedToActor)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func throwingTask_holdsTurnUntilItIsIsolatedToActor() async throws {
		let actor = ManuallyExecutedActor()
		var enqueuedJobs = actor.executor.enqueuedJobs.makeAsyncIterator()
		let task = Task(on: actor.queue) { _ in try doWork() }
		// Wait for the task to hop to the actor, whose executor holds the task's job until the test runs it.
		_ = await enqueuedJobs.next()
		// The task holds its turn until it is isolated to the actor, so the next turn cannot begin yet.
		let hasNextTurnBegun = probeNextTurn(of: actor.queue.turns)
		let didNextTurnBeginBeforeTaskWasIsolatedToActor = hasNextTurnBegun()
		// Running the task's job isolates the task to the actor, which ends its turn.
		actor.executor.runUntilIdle()
		try await task.value
		let didNextTurnBeginAfterTaskCompleted = hasNextTurnBegun()
		#expect(!didNextTurnBeginBeforeTaskWasIsolatedToActor)
		#expect(didNextTurnBeginAfterTaskCompleted)
	}

	@Test
	func mainTask_holdsTurnUntilItIsIsolatedToMainActor() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let executor = ManualTaskExecutor()
		// While this closure holds the main actor, the task cannot be isolated to it, so its turn cannot end.
		let task = await MainActor.run {
			let task = Task(on: mainActorQueue) {}
			let nextTurn = mainActorQueue.turns.reserve()
			Task(executorPreference: executor) {
				await nextTurn.begin()
				nextTurn.end()
			}
			// Run the probe until it waits for its turn.
			executor.runUntilIdle()
			return task
		}
		await task.value
		executor.runUntilIdle()
		// The probe is enqueued when it is created, here on the main actor, and again by whoever ends the task's turn.
		// `false` for the second job means that the task's turn ended before the task was isolated to the main actor.
		#expect(executor.wasEachJobEnqueuedOnMainQueue == [true, true])
	}

	@Test
	func mainThrowingTask_holdsTurnUntilItIsIsolatedToMainActor() async throws {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let executor = ManualTaskExecutor()
		// While this closure holds the main actor, the task cannot be isolated to it, so its turn cannot end.
		let task = await MainActor.run {
			let task = Task(on: mainActorQueue) { try doWork() }
			let nextTurn = mainActorQueue.turns.reserve()
			Task(executorPreference: executor) {
				await nextTurn.begin()
				nextTurn.end()
			}
			// Run the probe until it waits for its turn.
			executor.runUntilIdle()
			return task
		}
		try await task.value
		executor.runUntilIdle()
		// The probe is enqueued when it is created, here on the main actor, and again by whoever ends the task's turn.
		// `false` for the second job means that the task's turn ended before the task was isolated to the main actor.
		#expect(executor.wasEachJobEnqueuedOnMainQueue == [true, true])
	}

	@Test
	func hasStartedAllWork_onNewQueue_isTrue() {
		#expect(systemUnderTest.hasStartedAllWork)
	}

	@Test
	func hasStartedAllWork_afterTaskIsEnqueued_isFalseUntilTaskIsIsolatedToActor() async {
		let actor = ManuallyExecutedActor()
		var enqueuedJobs = actor.executor.enqueuedJobs.makeAsyncIterator()
		let task = Task(on: actor.queue) { actor in
			actor.queue.hasStartedAllWork
		}
		// `Task(on:)` takes the task's place on the queue before it returns, and the task cannot be isolated to the actor
		// until the test runs the actor's executor.
		let hadStartedAllWorkAfterTaskWasEnqueued = actor.queue.hasStartedAllWork
		// Wait for the task to hop to the actor. It has begun executing, but it is not isolated to the actor yet.
		_ = await enqueuedJobs.next()
		let hadStartedAllWorkAfterTaskHoppedToActor = actor.queue.hasStartedAllWork
		actor.executor.runUntilIdle()
		let hadStartedAllWorkWhileOperationExecuted = await task.value
		#expect(!hadStartedAllWorkAfterTaskWasEnqueued)
		#expect(!hadStartedAllWorkAfterTaskHoppedToActor)
		#expect(hadStartedAllWorkWhileOperationExecuted)
	}

	@Test
	func hasStartedAllWork_whileLastOperationIsSuspended_isTrue() async {
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: systemUnderTest) { _ in
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
		}
		await operationStarted.wait()
		// The task gave up its place on the queue once it was isolated to the actor, before its operation began.
		let hadStartedAllWorkWhileOperationWasSuspended = systemUnderTest.hasStartedAllWork
		await operationAllowedToReturn.signal()
		await task.value
		#expect(hadStartedAllWorkWhileOperationWasSuspended)
	}

	@Test
	func hasStartedAllWork_withSeveralTasks_isFalseUntilLastTaskIsIsolatedToActor() async {
		let actor = ManuallyExecutedActor()
		var enqueuedJobs = actor.executor.enqueuedJobs.makeAsyncIterator()
		// Each operation reads the property before it can suspend. The actor executes one job at a time, so the last task
		// cannot be isolated to the actor while the first task's operation executes.
		let firstTask = Task(on: actor.queue) { actor in
			actor.queue.hasStartedAllWork
		}
		let lastTask = Task(on: actor.queue) { actor in
			actor.queue.hasStartedAllWork
		}
		// Wait for the first task to hop to the actor, then run it. Its operation cannot execute before both tasks are enqueued.
		_ = await enqueuedJobs.next()
		actor.executor.runUntilIdle()
		// Wait for the last task to hop to the actor, then run it if the previous call did not already.
		_ = await enqueuedJobs.next()
		actor.executor.runUntilIdle()
		let hadStartedAllWorkWhileFirstOperationExecuted = await firstTask.value
		let hadStartedAllWorkWhileLastOperationExecuted = await lastTask.value
		#expect(!hadStartedAllWorkWhileFirstOperationExecuted)
		#expect(hadStartedAllWorkWhileLastOperationExecuted)
	}

	@Test
	func hasStartedAllWork_onMainActorQueue_afterTaskIsEnqueuedWhileCallerHoldsMainActor_isFalseUntilOperationRuns() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		// While this closure holds the main actor, the task cannot be isolated to it. The test cannot wait here for the task
		// to hop to the main actor, so `mainTask_holdsTurnUntilItIsIsolatedToMainActor` covers when the task's turn ends.
		let (task, hadStartedAllWorkAfterTaskWasEnqueued) = await MainActor.run {
			let task = Task(on: mainActorQueue) {
				mainActorQueue.hasStartedAllWork
			}
			return (task, mainActorQueue.hasStartedAllWork)
		}
		let hadStartedAllWorkWhileOperationExecuted = await task.value
		#expect(!hadStartedAllWorkAfterTaskWasEnqueued)
		#expect(hadStartedAllWorkWhileOperationExecuted)
	}

	@Test
	func hasStartedAllWork_onMainActorQueue_whileLastOperationIsSuspended_isTrue() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let operationStarted = Semaphore()
		let operationAllowedToReturn = Semaphore()
		let task = Task(on: mainActorQueue) {
			await operationStarted.signal()
			await operationAllowedToReturn.wait()
		}
		await operationStarted.wait()
		// The task gave up its place on the queue once it was isolated to the main actor, before its operation began.
		let hadStartedAllWorkWhileOperationWasSuspended = mainActorQueue.hasStartedAllWork
		await operationAllowedToReturn.signal()
		await task.value
		#expect(hadStartedAllWorkWhileOperationWasSuspended)
	}

	@Test
	func task_seesCallersTaskLocalValues() async throws {
		// Create the queue while a task-local value is bound: enqueued tasks must see their caller's values instead.
		let systemUnderTest = TestTaskLocal.$value.withValue("queue creator") {
			ActorQueue<Counter>()
		}
		systemUnderTest.adoptExecutionContext(of: counter)
		let (value, throwingValue) = try await TestTaskLocal.$value.withValue("caller") {
			try await (
				Task(on: systemUnderTest) { _ in TestTaskLocal.value }.value,
				Task(on: systemUnderTest) { _ in try doWork(); return TestTaskLocal.value }.value,
			)
		}
		#expect(value == "caller")
		#expect(throwingValue == "caller")
		#expect(await Task(on: systemUnderTest) { _ in TestTaskLocal.value }.value == "default")
	}

	@Test
	func mainTask_seesCallersTaskLocalValues() async throws {
		let (value, throwingValue) = try await TestTaskLocal.$value.withValue("caller") {
			try await (
				Task(on: MainActor.queue) { TestTaskLocal.value }.value,
				Task(on: MainActor.queue) { try doWork(); return TestTaskLocal.value }.value,
			)
		}
		#expect(value == "caller")
		#expect(throwingValue == "caller")
		#expect(await Task(on: MainActor.queue) { TestTaskLocal.value }.value == "default")
	}

	@Test
	func task_withNilPriority_inheritsCallersPriority() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		for priority in [TaskPriority.background, .low, .medium, .high] {
			let executionPriorities = await [
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { [systemUnderTest] report in
					Task(on: systemUnderTest) { _ in report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { [systemUnderTest] report in
					Task(on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: mainActorQueue) { report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: priority) { report in
					Task(on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
				},
			]
			#expect(executionPriorities == Array(repeating: priority, count: 4))
		}
	}

	@Test
	func task_withPriority_executesAtThatPriority() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		for priority in [TaskPriority.background, .low, .medium, .high] {
			let executionPriorities = await [
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest) { _ in report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { [systemUnderTest] report in
					Task(priority: priority, on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
					Task(priority: priority, on: mainActorQueue) { report(Task.currentPriority) }
				},
				priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
					Task(priority: priority, on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
				},
			]
			#expect(executionPriorities == Array(repeating: priority, count: 4))
		}
	}

	@Test
	func task_onQueueWithPriority_withLowerPriority_executesAtQueuePriority() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .medium)
		systemUnderTest.adoptExecutionContext(of: counter)
		let mainActorQueue = ActorQueue<MainActor>(priority: .medium)
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: systemUnderTest) { _ in report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: mainActorQueue) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(priority: .low, on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.medium, .medium, .medium, .medium])
	}

	@Test
	func task_onQueueWithPriority_withHigherPriority_executesAtThatPriority() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .medium)
		systemUnderTest.adoptExecutionContext(of: counter)
		let mainActorQueue = ActorQueue<MainActor>(priority: .medium)
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: systemUnderTest) { _ in report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: mainActorQueue) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(priority: .high, on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.high, .high, .high, .high])
	}

	@Test
	func task_onQueueWithPriority_withNilPriority_executesAtHigherOfCallersAndQueuePriority() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .medium)
		systemUnderTest.adoptExecutionContext(of: counter)
		let mainActorQueue = ActorQueue<MainActor>(priority: .medium)
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let executionPriorities = await [
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: systemUnderTest) { _ in report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: systemUnderTest) { _ in report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: systemUnderTest) { _ in try doWork(); report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: mainActorQueue) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: mainActorQueue) { report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .background) { report in
				Task(on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
			},
			priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
				Task(on: mainActorQueue) { try doWork(); report(Task.currentPriority) }
			},
		]
		#expect(executionPriorities == [.medium, .high, .medium, .high, .medium, .high, .medium, .high])
	}

	@Test
	func task_onQueueWithPriority_enqueuedFromEscalatedTaskWithLowerBasePriority_executesAtQueuePriority() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .medium)
		systemUnderTest.adoptExecutionContext(of: counter)
		let enqueuingTaskAllowedToEnqueue = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		let enqueuingTask = Task.detached(priority: .background) {
			// Wait for a higher-priority task to escalate this task above the queue's priority.
			await enqueuingTaskAllowedToEnqueue.wait()
			// Do not await the enqueued task: awaiting it would escalate it.
			Task(on: systemUnderTest) { _ in
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
				let systemUnderTest = ActorQueue<Counter>(priority: queuePriority)
				systemUnderTest.adoptExecutionContext(of: counter)
				let (priorities, prioritiesContinuation) = AsyncStream<(isEnqueued: Bool, priority: TaskPriority)>.makeStream()
				// Enqueue from a thread that is not running a task, and create a plain task there for comparison.
				let thread = Thread {
					Task {
						prioritiesContinuation.yield((isEnqueued: false, priority: Task.currentPriority))
					}
					Task(on: systemUnderTest) { _ in
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
		let systemUnderTest = ActorQueue<Counter>(priority: .low)
		systemUnderTest.adoptExecutionContext(of: counter)
		// `Task` treats a priority with a raw value of zero as no priority, so the task inherits the caller's priority.
		let executionPriority = await priorityOfTask(enqueuedFromTaskWithPriority: .high) { report in
			Task(priority: TaskPriority(rawValue: 0), on: systemUnderTest) { _ in report(Task.currentPriority) }
		}
		#expect(executionPriority == .high)
	}

	@Test
	func task_onQueueWithUserInteractivePriority_enqueuedFromUserInteractiveTask_executesAtQueuePriority() async {
		let userInteractivePriority = TaskPriority(rawValue: 0x21)
		let systemUnderTest = ActorQueue<Counter>(priority: userInteractivePriority)
		systemUnderTest.adoptExecutionContext(of: counter)
		// `Task` lowers an inherited user-interactive priority, so only the queue's priority keeps the task user-interactive.
		let executionPriority = await priorityOfTask(enqueuedFromTaskWithPriority: userInteractivePriority) { report in
			Task(on: systemUnderTest) { _ in report(Task.currentPriority) }
		}
		#expect(executionPriority == userInteractivePriority)
	}

	@Test
	func task_onQueueWithPriority_isEscalatedWhenAwaitedFromHigherPriorityTask() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .low)
		systemUnderTest.adoptExecutionContext(of: counter)
		let taskStarted = Semaphore()
		let taskAllowedToReturn = Semaphore()
		let task = Task(priority: .background, on: systemUnderTest) { _ in
			let startingPriority = Task.currentPriority
			await taskStarted.signal()
			await taskAllowedToReturn.wait()
			return [startingPriority, Task.currentPriority]
		}
		await taskStarted.wait()
		let priorities = await value(of: task, awaitedFromTaskWithPriority: .high) {
			await taskAllowedToReturn.signal()
		}
		#expect(priorities[0] == .low)
		#expect(priorities[1] >= .high)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func throwingTask_onQueueWithPriority_isEscalatedWhenItsTurnBeginsWhileHigherPriorityTaskWaits() async {
		let systemUnderTest = ActorQueue<Counter>(priority: .low)
		systemUnderTest.adoptExecutionContext(of: counter)
		// Hold the turn before the task enqueued at `.background`, so that the task cannot begin its turn yet.
		let heldTurn = systemUnderTest.turns.reserve()
		let taskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it without the queue's help.
		let task = Task(priority: .background, on: systemUnderTest) { _ in
			await taskAllowedToReport.wait()
			try doWork()
			prioritiesContinuation.yield(Task.currentPriority)
		}
		// This task waits for that task's turn to end, and so escalates that task once its turn begins.
		let finishWaiting = runTaskWaitingForNextTurn(of: systemUnderTest.turns, withPriority: .high)
		await heldTurn.begin()
		// Ending the held turn escalates that task on behalf of the waiting task before `end()` returns.
		heldTurn.end()
		// That task may begin its turn before `end()` escalates it, so let it report only once `end()` has returned.
		await taskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await finishWaiting()
		_ = await task.result
		#expect(priority.map { $0 >= .high } == true)
	}

	@Test
	func task_isEscalatedWhenAwaitedFromHigherPriorityTask() async {
		let taskStarted = Semaphore()
		let taskAllowedToReturn = Semaphore()
		let task = Task(priority: .low, on: systemUnderTest) { _ in
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
	func mainTask_isEscalatedWhenAwaitedFromHigherPriorityTask() async {
		// Use a queue of our own rather than `MainActor.queue`: a higher-priority task that a test running in parallel
		// enqueues on the shared queue may escalate this task, which would hide whether awaiting this task escalates it.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let taskStarted = Semaphore()
		let taskAllowedToReturn = Semaphore()
		let task = Task(priority: .low, on: mainActorQueue) {
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

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func task_waitingForActor_isEscalatedByHigherPriorityTaskWaitingForItsTurn() async {
		let actor = ManuallyExecutedActor()
		var enqueuedJobs = actor.executor.enqueuedJobs.makeAsyncIterator()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the queue's help.
		Task(priority: .background, on: actor.queue) { _ in
			prioritiesContinuation.yield(Task.currentPriority)
		}
		// Wait for the task to hop to the actor, whose executor holds the task's job until the test runs it.
		await enqueuedJobs.next()
		let executor = ManualTaskExecutor()
		let nextTurn = actor.queue.turns.reserve()
		let waitingTask = Task(executorPreference: executor, priority: .high) {
			await nextTurn.begin()
			nextTurn.end()
		}
		nextTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn, which escalates the task holding the turn before returning.
		executor.runUntilIdle()
		actor.executor.runUntilIdle()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func throwingTask_isEscalatedWhenItsTurnBeginsWhileHigherPriorityTaskWaits() async {
		// Hold the turn before the background task's, so that the background task cannot begin its turn yet.
		let heldTurn = systemUnderTest.turns.reserve()
		let taskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it without the queue's help.
		let task = Task(priority: .background, on: systemUnderTest) { _ in
			await taskAllowedToReport.wait()
			try doWork()
			prioritiesContinuation.yield(Task.currentPriority)
		}
		// This task waits for the background task's turn to end, and so escalates the background task once its turn begins.
		let finishWaiting = runTaskWaitingForNextTurn(of: systemUnderTest.turns, withPriority: .high)
		await heldTurn.begin()
		// Ending the held turn escalates the background task on behalf of the waiting task before `end()` returns.
		heldTurn.end()
		// The background task may begin its turn before `end()` escalates it, so let it report only once `end()` has returned.
		await taskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await finishWaiting()
		_ = await task.result
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func mainTask_isEscalatedWhenItsTurnBeginsWhileHigherPriorityTaskWaits() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		// Hold the turn before the background task's, so that the background task cannot begin its turn yet.
		let heldTurn = mainActorQueue.turns.reserve()
		let taskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it without the queue's help.
		let task = Task(priority: .background, on: mainActorQueue) {
			await taskAllowedToReport.wait()
			prioritiesContinuation.yield(Task.currentPriority)
		}
		// This task waits for the background task's turn to end, and so escalates the background task once its turn begins.
		let finishWaiting = runTaskWaitingForNextTurn(of: mainActorQueue.turns, withPriority: .high)
		await heldTurn.begin()
		// Ending the held turn escalates the background task on behalf of the waiting task before `end()` returns.
		heldTurn.end()
		// The background task may begin its turn before `end()` escalates it, so let it report only once `end()` has returned.
		await taskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await finishWaiting()
		_ = await task.result
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func mainThrowingTask_isEscalatedWhenItsTurnBeginsWhileHigherPriorityTaskWaits() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		// Hold the turn before the background task's, so that the background task cannot begin its turn yet.
		let heldTurn = mainActorQueue.turns.reserve()
		let taskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it without the queue's help.
		let task = Task(priority: .background, on: mainActorQueue) {
			await taskAllowedToReport.wait()
			try doWork()
			prioritiesContinuation.yield(Task.currentPriority)
		}
		// This task waits for the background task's turn to end, and so escalates the background task once its turn begins.
		let finishWaiting = runTaskWaitingForNextTurn(of: mainActorQueue.turns, withPriority: .high)
		await heldTurn.begin()
		// Ending the held turn escalates the background task on behalf of the waiting task before `end()` returns.
		heldTurn.end()
		// The background task may begin its turn before `end()` escalates it, so let it report only once `end()` has returned.
		await taskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await finishWaiting()
		_ = await task.result
		#expect(priority.map { $0 >= .high } == true)
	}

	// MARK: Private

	private let systemUnderTest: ActorQueue<Counter>
	private let counter: Counter

	@Sendable
	private func doWork() throws {}
}

// MARK: - ManuallyExecutedActor

/// An actor whose jobs run only when a test calls `executor.runUntilIdle()`.
private actor ManuallyExecutedActor {
	init() {
		queue.adoptExecutionContext(of: self)
	}

	nonisolated let queue = ActorQueue<ManuallyExecutedActor>()
	nonisolated let executor = ManualSerialExecutor()

	nonisolated var unownedExecutor: UnownedSerialExecutor {
		executor.asUnownedSerialExecutor()
	}
}
