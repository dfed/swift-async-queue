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
	// MARK: FIFOQueue Tests

	@Test
	func cancelTasks_fifoQueue_doesNotCancelCompletedTask() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())

		// Create a task that completes immediately
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		// Wait for the task to complete
		try await task.value

		// Now cancel tasks - should have no effect since task already completed
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let proceedAfterCancel = Semaphore()

		// Create a task that signals when it starts, then waits
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Wait for the task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let the task continue
		await proceedAfterCancel.signal()

		await task.value
		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let taskStarted = Semaphore()
		let proceedAfterCancel = Semaphore()
		let counter = Counter()

		// Create a task that signals when it starts, then waits
		let task1 = Task(on: systemUnderTest, isolatedTo: counter) { _ in
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Create pending tasks that won't start until the first task completes
		let task2 = Task(on: systemUnderTest, isolatedTo: counter) { _ in }

		let task3 = Task(on: systemUnderTest, isolatedTo: counter) { _ in }

		// Wait for the first task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let tasks continue
		await proceedAfterCancel.signal()

		await task1.value
		await task2.value
		await task3.value
		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_fifoQueue_doesNotCancelFutureTasks() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: FIFOQueue())
		let counter = Counter()

		// Cancel tasks before creating any
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled
		let task = Task(on: systemUnderTest, isolatedTo: counter) { _ in
			try doWork()
		}

		try await task.value
		#expect(!task.isCancelled)
	}

	// MARK: ActorQueue Tests

	@Test
	func cancelTasks_actorQueue_doesNotCancelCompletedTask() async throws {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)

		// Create a task that completes immediately
		let task = Task(on: systemUnderTest) { _ in
			try doWork()
		}

		// Wait for the task to complete
		try await task.value

		// Now cancel tasks - should have no effect since task already completed
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
		let proceedAfterCancel = Semaphore()

		// Create a task that signals when it starts, then waits
		let task = Task(on: systemUnderTest) { _ in
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Wait for the task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let the task continue
		await proceedAfterCancel.signal()

		await task.value
		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)
		let taskStarted = Semaphore()
		let proceedAfterCancel = Semaphore()

		// Create a task that signals when it starts, then waits
		let task1 = Task(on: systemUnderTest) { _ in
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Create pending tasks that won't start until the first task suspends
		let task2 = Task(on: systemUnderTest) { _ in }

		let task3 = Task(on: systemUnderTest) { _ in }

		// Wait for the first task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let tasks continue
		await proceedAfterCancel.signal()

		await task1.value
		await task2.value
		await task3.value
		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_actorQueue_doesNotCancelFutureTasks() async throws {
		let actorQueue = ActorQueue<Counter>()
		let counter = Counter()
		actorQueue.adoptExecutionContext(of: counter)
		let systemUnderTest = CancellableQueue(underlyingQueue: actorQueue)

		// Cancel tasks before creating any
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled
		let task = Task(on: systemUnderTest) { _ in
			try doWork()
		}

		try await task.value
		#expect(!task.isCancelled)
	}

	// MARK: MainActor Queue Tests

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelCompletedTask() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)

		// Create a task that completes immediately
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		// Wait for the task to complete
		try await task.value

		// Now cancel tasks - should have no effect since task already completed
		systemUnderTest.cancelTasks()

		#expect(!task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_cancelsCurrentlyExecutingTask() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let taskStarted = Semaphore()
		let proceedAfterCancel = Semaphore()

		// Create a task that signals when it starts, then waits
		let task = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Wait for the task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let the task continue
		await proceedAfterCancel.signal()

		await task.value
		#expect(task.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_cancelsCurrentlyExecutingAndPendingTasks() async {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)
		let taskStarted = Semaphore()
		let proceedAfterCancel = Semaphore()

		// Create a task that signals when it starts, then waits
		let task1 = Task(on: systemUnderTest) {
			await taskStarted.signal()
			await proceedAfterCancel.wait()
		}

		// Create pending tasks that won't start until the first task suspends
		let task2 = Task(on: systemUnderTest) { }

		let task3 = Task(on: systemUnderTest) { }

		// Wait for the first task to start executing
		await taskStarted.wait()

		// Cancel all tasks
		systemUnderTest.cancelTasks()

		// Signal the semaphore to let tasks continue
		await proceedAfterCancel.signal()

		await task1.value
		await task2.value
		await task3.value
		#expect(task1.isCancelled)
		#expect(task2.isCancelled)
		#expect(task3.isCancelled)
	}

	@Test
	func cancelTasks_mainActorQueue_doesNotCancelFutureTasks() async throws {
		let systemUnderTest = CancellableQueue(underlyingQueue: MainActor.queue)

		// Cancel tasks before creating any
		systemUnderTest.cancelTasks()

		// Create a task after cancellation - it should NOT be cancelled
		let task = Task(on: systemUnderTest) {
			try doWork()
		}

		try await task.value
		#expect(!task.isCancelled)
	}

	// MARK: Private

	@Sendable
	private func doWork() throws {}
}
