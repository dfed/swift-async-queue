// MIT License
//
// Copyright (c) 2025 Dan Federman
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

import Testing

@testable import AsyncQueue

struct CancellableQueueTests {
	// MARK: Behavior Tests

	@Test
	func cancelTasks_fifoQueue_doesNotCancelCompletedTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())

		// Create a task that completes immediately.
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		// Wait for the task to complete.
		_ = await task.result

		// Now cancel tasks - should have no effect since task already completed.
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_doesNotCancelTaskThatFinishedBeforeRegisteringCancellation() {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task<Void, Never> {}

		// Finish the task before registering its cancellation.
		let identifier = systemUnderTest.reserveTaskIdentifier()
		systemUnderTest.taskDidFinish(withIdentifier: identifier)
		systemUnderTest.registerCancellation(forTaskWithIdentifier: identifier, task.cancel)

		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_cancelsTaskThatRegisteredCancellationAfterEarlierCancelTasks() {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task<Void, Never> {}

		// Cancel tasks after the task reserved its identifier but before it registered its cancellation.
		let identifier = systemUnderTest.reserveTaskIdentifier()
		systemUnderTest.cancelTasks()
		systemUnderTest.registerCancellation(forTaskWithIdentifier: identifier, task.cancel)

		systemUnderTest.cancelTasks()

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Wait for the task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow the task to end now that we've cancelled it.
		await taskAllowedToEnd.signal()

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()
		let counter = Counter()

		// Create a task that signals when it starts.
		let task1 = Task(on: systemUnderTest, isolatedTo: counter) { _ in
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Create pending tasks that won't start until the first task completes.
		let task2 = Task(on: systemUnderTest, isolatedTo: counter) { _ in }

		let task3 = Task(on: systemUnderTest, isolatedTo: counter) { _ in }

		// Wait for the first task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow the task to end now that we've cancelled it.
		await taskAllowedToEnd.signal()

		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelFutureTasks() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let counter = Counter()

		// Cancel tasks before creating any.
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled.
		let task = Task(on: systemUnderTest, isolatedTo: counter) { _ in
			try doWork()
		}

		// Wait for the task to end, so that its operation has run.
		try await task.value

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelCompletedTask() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)

		// Create a task that completes immediately.
		let task = Task(on: systemUnderTest) { _ in
			try doWork()
		}

		// Wait for the task to complete.
		_ = await task.result

		// Now cancel tasks - should have no effect since task already completed.
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_cancelsCurrentlyExecutingTask() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task = Task(on: systemUnderTest) { _ in
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Wait for the task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow the task to end now that we've cancelled it.
		await taskAllowedToEnd.signal()

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		// Use an actor that does not execute on the cooperative thread pool: the spinning task below would
		// otherwise occupy a cooperative thread that this test needs to cancel it, which can hang on a single CPU.
		let actorQueue = ActorQueue<DispatchQueueActor>()
		let dispatchQueueActor = DispatchQueueActor()
		actorQueue.adoptExecutionContext(of: dispatchQueueActor)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task1 = Task(on: systemUnderTest) { _ in
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Create a task that spins until cancelled, ensuring task3 remains pending.
		let task2 = Task(on: systemUnderTest) { _ in
			while !Task.isCancelled {}
		}

		// Create a pending task.
		let task3 = Task(on: systemUnderTest) { _ in
			await taskAllowedToEnd.wait()
		}

		// Wait for the first task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow both waiting tasks to end now that we've cancelled them.
		await taskAllowedToEnd.signal()
		await taskAllowedToEnd.signal()

		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)

		// Stop the spinning task even if cancelling tasks did not, so that a regression fails this test instead of hanging it.
		task2.cancel()

		// Wait for every task to end, so that every operation has run.
		await task1.value
		await task2.value
		_ = await task3.value
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelFutureTasks() async throws {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)

		// Cancel tasks before creating any.
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled.
		let task = Task(on: systemUnderTest) { _ in
			try doWork()
		}

		// Wait for the task to end, so that its operation has run.
		try await task.value

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelCompletedTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)

		// Create a task that completes immediately.
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		// Wait for the task to complete.
		_ = await task.result

		// Now cancel tasks - should have no effect since task already completed.
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_cancelsCurrentlyExecutingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Wait for the task to start executing.
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Allow the task to end now that we've cancelled it.
		await taskAllowedToEnd.signal()

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		// Use a queue of our own rather than `MainActor.queue`, which tests running in parallel share,
		// so that their tasks are not queued behind this test's tasks.
		let mainActorQueue = ActorQueue<MainActor>()
		mainActorQueue.adoptExecutionContext(of: MainActor.shared)
		let systemUnderTest = CancellableQueue(underlyingQueue: mainActorQueue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task1 = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Create a task that spins until cancelled, ensuring task3 remains pending.
		let task2 = Task(on: systemUnderTest) {
			while !Task.isCancelled {}
		}

		// Create a pending task.
		let task3 = Task(on: systemUnderTest) {
			await taskAllowedToEnd.wait()
		}

		// Wait for the first task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow both waiting tasks to end now that we've cancelled them.
		await taskAllowedToEnd.signal()
		await taskAllowedToEnd.signal()

		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)

		// Stop the spinning task even if cancelling tasks did not, so that a regression fails this test instead of hanging it.
		task2.cancel()

		// Wait for every task to end, so that every operation has run.
		await task1.value
		await task2.value
		_ = await task3.value
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelFutureTasks() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)

		// Cancel tasks before creating any.
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled.
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		// Wait for the task to end, so that its operation has run.
		try await task.value

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_canBeCalledFromCancellationHandler() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let task = Task(on: systemUnderTest) {
			await withTaskCancellationHandler {
				await taskStarted.signal()
				await suspendUntilCancelled()
			} onCancel: {
				systemUnderTest.cancelTasks()
			}
		}
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		#expect(task.isCancelled)

		// Stop the task even if cancelling tasks did not, so that a regression fails this test instead of hanging it.
		task.cancel()
		await task.value
	}

	@Test
	func cancelTasks_actorQueue_canBeCalledFromCancellationHandler() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let taskStarted = Semaphore()
		let task = Task(on: systemUnderTest) { _ in
			await withTaskCancellationHandler {
				await taskStarted.signal()
				await suspendUntilCancelled()
			} onCancel: {
				systemUnderTest.cancelTasks()
			}
		}
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		#expect(task.isCancelled)

		// Stop the task even if cancelling tasks did not, so that a regression fails this test instead of hanging it.
		task.cancel()
		await task.value
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelCompletedNonthrowingTask() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let task = Task(on: systemUnderTest) { _ in }

		// The task removes itself from the queue before it completes, so cancelling tasks afterward must not cancel it.
		await task.value
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelCompletedNonthrowingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let task = Task(on: systemUnderTest) {}

		// The task removes itself from the queue before it completes, so cancelling tasks afterward must not cancel it.
		await task.value
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelCompletedNonthrowingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task(on: systemUnderTest) {}

		// The task removes itself from the queue before it completes, so cancelling tasks afterward must not cancel it.
		await task.value
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelCompletedNonthrowingTaskIsolatedToActor() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in }

		// The task removes itself from the queue before it completes, so cancelling tasks afterward must not cancel it.
		await task.value
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelCompletedThrowingTaskIsolatedToActor() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in try doWork() }

		// The task removes itself from the queue before it completes, so cancelling tasks afterward must not cancel it.
		_ = await task.result
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingThrowingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
			try doWork()
		}

		// The task registers its cancellation before `Task(on:)` returns, and cannot end until it is allowed to.
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		await taskAllowedToEnd.signal()
		_ = await task.result

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingThrowingTaskIsolatedToActor() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
			try doWork()
		}

		// The task registers its cancellation before `Task(on:)` returns, and cannot end until it is allowed to.
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		await taskAllowedToEnd.signal()
		_ = await task.result

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_cancelsCurrentlyExecutingThrowingTask() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()
		let task = Task(on: systemUnderTest) { _ in
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
			try doWork()
		}

		// The task registers its cancellation before `Task(on:)` returns, and cannot end until it is allowed to.
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		await taskAllowedToEnd.signal()
		_ = await task.result

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_cancelsCurrentlyExecutingThrowingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
			try doWork()
		}

		// The task registers its cancellation before `Task(on:)` returns, and cannot end until it is allowed to.
		await taskStarted.wait()
		systemUnderTest.cancelTasks()
		await taskAllowedToEnd.signal()
		_ = await task.result

		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelTaskThatThrew() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let task = Task(on: systemUnderTest) { _ in throw TestError() }

		// The task removes itself from the queue when its operation throws, so cancelling tasks afterward must not cancel it.
		_ = await task.result
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelTaskThatThrew() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let task = Task(on: systemUnderTest) { throw TestError() }

		// The task removes itself from the queue when its operation throws, so cancelling tasks afterward must not cancel it.
		_ = await task.result
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelTaskThatThrew() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task(on: systemUnderTest) { throw TestError() }

		// The task removes itself from the queue when its operation throws, so cancelling tasks afterward must not cancel it.
		_ = await task.result
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelTaskIsolatedToActorThatThrew() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let task = Task(on: systemUnderTest, isolatedTo: Counter()) { _ in throw TestError() }

		// The task removes itself from the queue when its operation throws, so cancelling tasks afterward must not cancel it.
		_ = await task.result
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	// MARK: Private

	private struct TestError: Error {}

	@Sendable
	private func doWork() throws {}
}
