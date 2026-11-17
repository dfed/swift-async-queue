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

import Synchronization
import Testing

struct TestHelpersTests {
	// MARK: Behavior Tests

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func suspendUntilEscalated_whenTaskAlreadyRunsAtPriority_returnsWithoutSuspending() async {
		let reportedPriority = Mutex<TaskPriority?>(nil)
		Task(executorPreference: executor, priority: .high) {
			await suspendUntilEscalated(to: .high)
			reportedPriority.withLock { $0 = Task.currentPriority }
		}
		// Nothing escalates or signals the task, so it returns only if it never waits for an escalation.
		executor.runUntilIdle()
		let priority = reportedPriority.withLock(\.self)
		#expect(priority == .high)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func suspendUntilEscalated_whenTaskIsEscalatedToPriority_returnsAtThatPriority() async {
		let reportedPriority = Mutex<TaskPriority?>(nil)
		let task = Task(executorPreference: executor, priority: .low) {
			await suspendUntilEscalated(to: .high)
			reportedPriority.withLock { $0 = Task.currentPriority }
		}
		// Run the task until it waits for the escalation, by which point its escalation handler is installed.
		executor.runUntilIdle()

		task.escalatePriority(to: .high)
		await executor.runUntil { reportedPriority.withLock(\.self) != nil }
		let priority = reportedPriority.withLock(\.self)
		#expect(priority == .high)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func suspendUntilEscalated_whenTaskIsEscalatedBelowPriority_keepsWaiting() async {
		let reportedPriority = Mutex<TaskPriority?>(nil)
		let task = Task(executorPreference: executor, priority: .low) {
			await suspendUntilEscalated(to: .high)
			reportedPriority.withLock { $0 = Task.currentPriority }
		}
		// Run the task until it waits for the escalation, by which point its escalation handler is installed.
		executor.runUntilIdle()

		task.escalatePriority(to: .medium)
		executor.runUntilIdle()
		let priorityAfterEscalationBelowPriority = reportedPriority.withLock(\.self)
		#expect(priorityAfterEscalationBelowPriority == nil)

		// Escalate the task to the priority it waits for, so that it returns and the test can end.
		task.escalatePriority(to: .high)
		await executor.runUntil { reportedPriority.withLock(\.self) != nil }
		let priority = reportedPriority.withLock(\.self)
		#expect(priority == .high)
	}

	// MARK: Private

	private let executor = ManualTaskExecutor()
}
