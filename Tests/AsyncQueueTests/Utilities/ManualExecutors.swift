// MIT License
//
// Copyright (c) 2026 Dan Federman
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

import Dispatch
import Synchronization

@testable import AsyncQueue

/// A task executor that runs its jobs only when a test calls `runUntilIdle()`.
///
/// A task that prefers this executor makes progress only while the test runs it,
/// so the test decides exactly when the task runs, and knows when it has suspended.
final class ManualTaskExecutor: TaskExecutor {
	// MARK: Initialization

	init() {
		(enqueuedJobs, enqueuedJobsContinuation) = AsyncStream<Void>.makeStream()
	}

	// MARK: Internal

	/// Yields once each time a job is enqueued.
	let enqueuedJobs: AsyncStream<Void>

	/// The priority of each job enqueued so far, in the order in which the jobs were enqueued.
	var enqueuedJobPriorities: [TaskPriority] {
		state.withLock { $0.enqueuedJobs.map(\.priority) }
	}

	/// Whether each job enqueued so far was enqueued from the main dispatch queue, in the order in which the jobs were enqueued.
	var wasEachJobEnqueuedOnMainQueue: [Bool] {
		state.withLock { $0.enqueuedJobs.map(\.wasEnqueuedOnMainQueue) }
	}

	func enqueue(_ job: consuming ExecutorJob) {
		// The caller doesn't keep this executor alive. Once `yield()` resumes the test, the test may run the job to the end
		// and release its last reference to this executor before `yield()` returns, so keep the executor alive until this
		// method returns.
		let retainedSelf = Unmanaged.passRetained(self)
		defer { retainedSelf.release() }
		let job = UnownedJob(job)
		let enqueuedJob = EnqueuedJob(
			priority: TaskPriority(rawValue: job.priority.rawValue),
			wasEnqueuedOnMainQueue: Self.mainQueueKey.withLock { DispatchQueue.getSpecific(key: $0) } == true,
		)
		state.withLock { state in
			state.pendingJobs.append(job)
			state.enqueuedJobs.append(enqueuedJob)
		}
		enqueuedJobsContinuation.yield()
	}

	/// Runs every pending job, and every job those jobs enqueue on this executor, until none is pending.
	///
	/// The jobs run synchronously on the calling thread, so a job run from a test's task runs nested inside that task,
	/// which the runtime makes current again once the job returns. Call this function from one task at a time, and never
	/// from a job that this executor runs.
	func runUntilIdle() {
		while let job = state.withLock({ $0.pendingJobs.isEmpty ? nil : $0.pendingJobs.removeFirst() }) {
			job.runSynchronously(on: asUnownedTaskExecutor())
		}
	}

	/// Runs the pending jobs each time a job is enqueued, until `isDone` returns `true`.
	///
	/// Another thread may enqueue a job for a task that prefers this executor at any time, and the task may need more than
	/// one job to reach the point that the test waits for. Running the executor after each job is enqueued keeps the test
	/// from missing any of them. `isDone` is checked after the executor runs, so it should become `true` while a job on this
	/// executor runs. If it never does, this method suspends forever, so a regression hangs the test.
	func runUntil(_ isDone: () -> Bool) async {
		var enqueuedJobs = enqueuedJobs.makeAsyncIterator()
		while !isDone() {
			await enqueuedJobs.next()
			runUntilIdle()
		}
	}

	// MARK: Private

	private struct EnqueuedJob {
		let priority: TaskPriority
		let wasEnqueuedOnMainQueue: Bool
	}

	private struct State {
		var pendingJobs = [UnownedJob]()
		var enqueuedJobs = [EnqueuedJob]()
	}

	/// A key whose value is `true` on the main dispatch queue, and `nil` on every other queue.
	/// A `Mutex` holds the key because it is `Sendable` whether or not `DispatchSpecificKey` is on a given platform.
	private static let mainQueueKey = {
		let key = DispatchSpecificKey<Bool>()
		DispatchQueue.main.setSpecific(key: key, value: true)
		return Mutex(key)
	}()

	private let enqueuedJobsContinuation: AsyncStream<Void>.Continuation
	private let state = Mutex(State())
}

/// A serial executor that runs its jobs only when a test calls `runUntilIdle()`.
///
/// An actor that uses this executor runs nothing until the test runs it,
/// so the test can hold a task that has hopped to the actor before the task executes there.
final class ManualSerialExecutor: SerialExecutor {
	// MARK: Initialization

	init() {
		(enqueuedJobs, enqueuedJobsContinuation) = AsyncStream<Void>.makeStream()
	}

	// MARK: Internal

	/// Yields once each time a job is enqueued.
	let enqueuedJobs: AsyncStream<Void>

	func enqueue(_ job: consuming ExecutorJob) {
		// The caller doesn't keep this executor alive. Once `yield()` resumes the test, the test may run the job to the end
		// and release its last reference to this executor before `yield()` returns, so keep the executor alive until this
		// method returns.
		let retainedSelf = Unmanaged.passRetained(self)
		defer { retainedSelf.release() }
		let job = UnownedJob(job)
		pendingJobs.withLock { $0.append(job) }
		enqueuedJobsContinuation.yield()
	}

	/// Runs every pending job, and every job those jobs enqueue on this executor, until none is pending.
	///
	/// The jobs run synchronously on the calling thread, so a job run from a test's task runs nested inside that task,
	/// which the runtime makes current again once the job returns. Call this function from one task at a time, and never
	/// from a job that this executor runs.
	func runUntilIdle() {
		while let job = pendingJobs.withLock({ $0.isEmpty ? nil : $0.removeFirst() }) {
			job.runSynchronously(on: asUnownedSerialExecutor())
		}
	}

	// MARK: Private

	private let enqueuedJobsContinuation: AsyncStream<Void>.Continuation
	private let pendingJobs = Mutex<[UnownedJob]>([])
}

/// Reserves the next turn of `turns` for a probe task that runs only when a test runs it.
///
/// A test calls the returned closure to find out whether the turn can begin at a point of the test's choosing:
/// the closure runs the probe until it suspends or completes, so the answer never depends on how the probe is scheduled.
/// - Returns: A closure that runs the probe until it suspends or completes, and returns whether the probe's turn has begun.
func probeNextTurn(of turns: Turns) -> @Sendable () -> Bool {
	let executor = ManualTaskExecutor()
	let turn = turns.reserve()
	let hasTurnBegun = Mutex(false)
	Task(executorPreference: executor) {
		await turn.begin()
		hasTurnBegun.withLock { $0 = true }
		turn.end()
	}
	return {
		executor.runUntilIdle()
		return hasTurnBegun.withLock(\.self)
	}
}

/// Reserves the next turn of `turns` for a task with the given priority, and runs the task until it waits for its turn.
///
/// A task that begins waiting for its turn escalates the task holding the current turn before it suspends,
/// so that escalation has happened once this function returns. The task runs only when a test runs it.
/// - Returns: A closure that waits for the turn before the task's turn to end, and then runs the task until it completes.
func runTaskWaitingForNextTurn(of turns: Turns, withPriority priority: TaskPriority) -> () async -> Void {
	let executor = ManualTaskExecutor()
	let turn = turns.reserve()
	let task = Task(executorPreference: executor, priority: priority) {
		await turn.begin()
		turn.end()
	}
	turn.register(task)
	executor.runUntilIdle()
	return {
		var enqueuedJobs = executor.enqueuedJobs.makeAsyncIterator()
		// Skip the job that started the task, and wait for the job that resumes it once the turn before its turn ends.
		await enqueuedJobs.next()
		await enqueuedJobs.next()
		executor.runUntilIdle()
		await task.value
	}
}

/// Awaits the value of `task` from a new task with the given priority, as a higher-priority caller may.
///
/// The awaiting task runs only when this function runs it, so `afterEscalating` runs once the awaiting task
/// awaits `task`. Awaiting a task escalates it to the awaiting task's priority before the awaiting task suspends.
/// - Parameters:
///   - task: The task whose value to await.
///   - priority: The priority of the awaiting task.
///   - afterEscalating: Runs once the awaiting task awaits `task`, and so once `task` has been escalated.
/// - Returns: The value of `task`, as the awaiting task received it.
func value<Success: Sendable>(
	of task: Task<Success, Never>,
	awaitedFromTaskWithPriority priority: TaskPriority,
	afterEscalating: () async -> Void,
) async -> Success {
	let executor = ManualTaskExecutor()
	var enqueuedJobs = executor.enqueuedJobs.makeAsyncIterator()
	let awaitingTask = Task(executorPreference: executor, priority: priority) {
		await task.value
	}
	// Run the awaiting task until it awaits `task`.
	await enqueuedJobs.next()
	executor.runUntilIdle()
	await afterEscalating()
	// Completing `task` resumes the awaiting task on the executor.
	await enqueuedJobs.next()
	executor.runUntilIdle()
	return await awaitingTask.value
}
