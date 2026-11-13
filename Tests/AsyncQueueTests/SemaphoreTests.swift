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

import Synchronization
import Testing

@testable import AsyncQueue

struct SemaphoreTests {
	// MARK: Behavior Tests

	@Test
	func signal_whenSignalCallsReachSuspendedWaitCalls_resumesEveryWaiterAtOnce() async {
		let waiters = (1...3).map { _ in Waiter(on: systemUnderTest, executor: executor) }
		executor.runUntilIdle()
		// No `signal()` call matches any of the three `wait()` calls, so every waiter suspends.
		#expect(waiters.map(\.result) == [nil, nil, nil])

		await systemUnderTest.signal()
		executor.runUntilIdle()
		// Two `wait()` calls are still unmatched, so every waiter is still suspended.
		#expect(waiters.map(\.result) == [nil, nil, nil])
		let isWaitingAfterFirstSignal = await systemUnderTest.isWaiting
		#expect(isWaitingAfterFirstSignal)

		await systemUnderTest.signal()
		executor.runUntilIdle()
		// One `wait()` call is still unmatched, so every waiter is still suspended.
		#expect(waiters.map(\.result) == [nil, nil, nil])
		let isWaitingAfterSecondSignal = await systemUnderTest.isWaiting
		#expect(isWaitingAfterSecondSignal)

		await systemUnderTest.signal()
		executor.runUntilIdle()
		// Every `wait()` call is matched, so every waiter has resumed.
		#expect(waiters.map(\.result) == [true, true, true])
		let isWaitingAfterThirdSignal = await systemUnderTest.isWaiting
		#expect(!isWaitingAfterThirdSignal)
	}

	@Test
	func signal_whenSignalCallsReachAThousandSuspendedWaitCalls_resumesEveryWaiterAtOnce() async {
		let waiterCount = 1_000
		let waiters = (1...waiterCount).map { _ in Waiter(on: systemUnderTest, executor: executor) }
		executor.runUntilIdle()
		// No `signal()` call matches any of the `wait()` calls, so every waiter suspends.
		#expect(waiters.allSatisfy { $0.result == nil })

		for _ in 1..<waiterCount {
			await systemUnderTest.signal()
			executor.runUntilIdle()
			// At least one `wait()` call is still unmatched, so every waiter is still suspended.
			#expect(waiters.allSatisfy { $0.result == nil })
		}
		let isWaitingBeforeLastSignal = await systemUnderTest.isWaiting
		#expect(isWaitingBeforeLastSignal)

		await systemUnderTest.signal()
		executor.runUntilIdle()
		// Every `wait()` call is matched, so every waiter has resumed.
		#expect(waiters.allSatisfy { $0.result == true })
		let isWaitingAfterLastSignal = await systemUnderTest.isWaiting
		#expect(!isWaitingAfterLastSignal)
	}

	@Test
	func wait_whenPrecededByFewerSignalCalls_suspendsOnlyTheUnmatchedWait() async {
		await systemUnderTest.signal()
		await systemUnderTest.signal()

		let waiters = (1...3).map { _ in Waiter(on: systemUnderTest, executor: executor) }
		executor.runUntilIdle()
		// The two `signal()` calls match the first two `wait()` calls, so only the third waiter suspends.
		#expect(waiters.map(\.result) == [false, false, nil])
		let isWaitingBeforeThirdSignal = await systemUnderTest.isWaiting
		#expect(isWaitingBeforeThirdSignal)

		await systemUnderTest.signal()
		executor.runUntilIdle()
		#expect(waiters.map(\.result) == [false, false, true])
		let isWaitingAfterThirdSignal = await systemUnderTest.isWaiting
		#expect(!isWaitingAfterThirdSignal)
	}

	@Test
	func wait_afterEveryWaiterResumed_suspendsUntilSignaledAgain() async {
		let firstWaiters = (1...2).map { _ in Waiter(on: systemUnderTest, executor: executor) }
		executor.runUntilIdle()
		await systemUnderTest.signal()
		await systemUnderTest.signal()
		executor.runUntilIdle()
		#expect(firstWaiters.map(\.result) == [true, true])

		let secondWaiters = (1...2).map { _ in Waiter(on: systemUnderTest, executor: executor) }
		executor.runUntilIdle()
		// The first two `signal()` calls matched the first two `wait()` calls, so the new waiters suspend.
		#expect(secondWaiters.map(\.result) == [nil, nil])

		await systemUnderTest.signal()
		executor.runUntilIdle()
		// One new `wait()` call is still unmatched, so both new waiters are still suspended.
		#expect(secondWaiters.map(\.result) == [nil, nil])
		let isWaitingAfterThirdSignal = await systemUnderTest.isWaiting
		#expect(isWaitingAfterThirdSignal)

		await systemUnderTest.signal()
		executor.runUntilIdle()
		#expect(secondWaiters.map(\.result) == [true, true])
		let isWaitingAfterFourthSignal = await systemUnderTest.isWaiting
		#expect(!isWaitingAfterFourthSignal)
	}

	@Test
	func wait_whenSignalCallIsEnqueuedBehindIt_resumes() async {
		let waiter = Waiter(on: systemUnderTest, executor: executor)
		// The executor runs the waiter's `wait()` call before this task's `signal()` call, so the signal reaches a
		// waiter that has already decremented the count.
		Task(executorPreference: executor) {
			await systemUnderTest.signal()
		}
		executor.runUntilIdle()
		#expect(waiter.result == true)
	}

	// MARK: Private

	private let systemUnderTest = Semaphore()
	private let executor = ManualTaskExecutor()
}

// MARK: - Waiter

/// A task that calls `wait()` on a semaphore, and that runs only when a test runs its executor.
///
/// Calls into the semaphore, a default actor, run on the executor that the calling task prefers. So once a test runs
/// the executor until it is idle, every waiter has either returned from `wait()` or is suspended in it.
private final class Waiter: Sendable {
	// MARK: Initialization

	init(on semaphore: Semaphore, executor: ManualTaskExecutor) {
		Task(executorPreference: executor) {
			let didSuspend = await semaphore.wait()
			self.waitResult.withLock { $0 = didSuspend }
		}
	}

	// MARK: Internal

	/// What `wait()` returned, which is whether it suspended, or `nil` while `wait()` has not returned.
	var result: Bool? {
		waitResult.withLock(\.self)
	}

	// MARK: Private

	private let waitResult = Mutex<Bool?>(nil)
}
