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

/// The priority that a queue gives each of its tasks at least.
struct MinimumPriority: Sendable {
	// MARK: Initialization

	/// - Parameter priority: The lowest priority at which the queue's tasks run.
	///   Pass `nil` to run each task at the priority with which it was enqueued.
	init(_ priority: TaskPriority?) {
		self.priority = priority
	}

	// MARK: Internal

	/// Returns the priority with which to create a task that was enqueued with the given priority.
	/// - Parameter taskPriority: The priority with which the task was enqueued. `nil` means the priority of the enqueuing context.
	func priority(forTaskEnqueuedWith taskPriority: TaskPriority?) -> TaskPriority? {
		if let priority, Self.priorityOfNewTask(enqueuedWith: taskPriority) < priority {
			priority
		} else {
			// Keep the enqueued priority when it suffices, so that `Task` determines the task's priority itself.
			taskPriority
		}
	}

	// MARK: Private

	private let priority: TaskPriority?

	/// Returns the priority that `Task.init(priority:)` gives a task created in the current context with the given priority.
	private static func priorityOfNewTask(enqueuedWith taskPriority: TaskPriority?) -> TaskPriority {
		// `Task` treats a priority with a raw value of zero as no priority.
		if let taskPriority, taskPriority.rawValue != 0 {
			return taskPriority
		} else {
			// Within a task, a new task inherits the task's base priority, not its escalated priority.
			// Outside of a task, a new task takes the current thread's priority, or `.medium` if the thread has none.
			let inheritedPriority = Task.basePriority ?? Task.currentPriority
			guard inheritedPriority.rawValue != 0 else { return .medium }
			// `Task` lowers an inherited user-interactive priority to user-initiated, which is `.high`.
			return min(inheritedPriority, .high)
		}
	}
}
