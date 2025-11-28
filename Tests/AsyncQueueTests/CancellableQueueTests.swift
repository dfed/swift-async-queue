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
	func cancelTasks_fifoQueue_doesNotCancelFutureTasks() {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let counter = Counter()

		// Cancel tasks before creating any.
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled.
		let task = Task(on: systemUnderTest, isolatedTo: counter) { _ in
			try doWork()
		}

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
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
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
			while true {
				try Task.checkCancellation()
			}
		}

		// Create a pending task.
		let task3 = Task(on: systemUnderTest) { _ in
			await taskAllowedToEnd.wait()
		}

		// Wait for the first task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow tasks to end now that we've cancelled them.
		await taskAllowedToEnd.signal()

		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelFutureTasks() {
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
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let taskStarted = Semaphore()
		let taskAllowedToEnd = Semaphore()

		// Create a task that signals when it starts, then waits.
		let task1 = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await taskAllowedToEnd.wait()
		}

		// Create a task that spins until cancelled, ensuring task3 remains pending.
		let task2 = Task(on: systemUnderTest) {
			while true {
				try Task.checkCancellation()
			}
		}

		// Create a pending task.
		let task3 = Task(on: systemUnderTest) {
			await taskAllowedToEnd.wait()
		}

		// Wait for the first task to start executing.
		await taskStarted.wait()

		// Cancel all tasks.
		systemUnderTest.cancelTasks()

		// Allow tasks to end now that we've cancelled them.
		await taskAllowedToEnd.signal()

		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelFutureTasks() {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)

		// Cancel tasks before creating any.
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled.
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		#expect(!task.isCancelled)
	}

	// MARK: Private

	@Sendable
	private func doWork() throws {}
}
