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

/// A queue that executes asynchronous tasks enqueued from a nonisolated context in FIFO order.
/// Tasks are guaranteed to begin _and end_ executing in the order in which they are enqueued.
/// Asynchronous tasks sent to this queue work as they would in a `DispatchQueue` type. Attempting to `enqueueAndWait` this queue from a task executing on this queue will result in a deadlock.
public final class FIFOQueue: Sendable {
	// MARK: Initialization

	/// Creates a FIFO queue.
	/// - Parameter priority: The lowest priority at which the queue's tasks run.
	///   A task that would run at a lower priority runs at this priority instead.
	///   Pass `nil` to run each task at the priority you pass to `Task(on:)`,
	///   or, if you pass `nil` there too, at the priority of the code that enqueues it.
	public init(priority: TaskPriority? = nil) {
		self.priority = priority
	}

	// MARK: Internal

	/// Hands out turns to execute, in the order in which tasks are enqueued.
	let turns = Turns()

	// MARK: Fileprivate

	/// Returns the priority with which to create a task that was enqueued with the given priority.
	/// - Parameter taskPriority: The priority with which the task was enqueued. `nil` means the priority of the enqueuing context.
	fileprivate func priority(forTaskEnqueuedWith taskPriority: TaskPriority?) -> TaskPriority? {
		if let priority, Self.priorityOfNewTask(enqueuedWith: taskPriority) < priority {
			priority
		} else {
			// Keep the enqueued priority when it suffices, so that `Task` determines the task's priority itself.
			taskPriority
		}
	}

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

	// MARK: Private

	private let priority: TaskPriority?
}

extension Task {
	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new top-level task that inherits the current isolated context.
	/// The operation will not execute until all prior tasks – including
	/// suspended tasks – have completed.
	///
	/// Use this function when creating asynchronous work
	/// that operates on behalf of the synchronous function that calls it.
	/// Like `Task.detached(priority:operation:)`,
	/// this function creates a separate, top-level task.
	/// Unlike `Task.detached(priority:operation:)`,
	/// the task created by `Task.init(priority:operation:)`
	/// inherits the priority and actor context of the caller,
	/// so the operation is treated more like an asynchronous extension
	/// to the synchronous operation.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a detached task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on fifoQueue: FIFOQueue,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async -> Success,
	) where Failure == Never {
		let turn = fifoQueue.turns.reserve()
		self.init(name: name, priority: fifoQueue.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			defer { turn.end() }
			return await operation()
		}
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new top-level task that inherits the current isolated context.
	/// The operation will not execute until all prior tasks – including
	/// suspended tasks – have completed.
	///
	/// Use this function when creating asynchronous work
	/// that operates on behalf of the synchronous function that calls it.
	/// Like `Task.detached(priority:operation:)`,
	/// this function creates a separate, top-level task.
	/// Unlike `Task.detached(priority:operation:)`,
	/// the task created by `Task.init(priority:operation:)`
	/// inherits the priority and actor context of the caller,
	/// so the operation is treated more like an asynchronous extension
	/// to the synchronous operation.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a detached task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on fifoQueue: FIFOQueue,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async throws -> Success,
	) where Failure == any Error {
		let turn = fifoQueue.turns.reserve()
		self.init(name: name, priority: fifoQueue.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			defer { turn.end() }
			return try await operation()
		}
	}

	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new top-level task isolated to the given actor.
	/// The operation will not execute until all prior tasks – including
	/// suspended tasks – have completed.
	///
	/// Use this function when creating asynchronous work
	/// that operates on behalf of the synchronous function that calls it.
	/// Like `Task.detached(priority:operation:)`,
	/// this function creates a separate, top-level task.
	/// Unlike `Task.detached(priority:operation:)`,
	/// the task created by `Task.init(priority:operation:)`
	/// inherits the priority and actor context of the caller,
	/// so the operation is treated more like an asynchronous extension
	/// to the synchronous operation.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a detached task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - isolatedActor: The actor to which the operation is isolated.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on fifoQueue: FIFOQueue,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async -> Success,
	) where Failure == Never {
		let turn = fifoQueue.turns.reserve()
		self.init(name: name, priority: fifoQueue.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			defer { turn.end() }
			return await operation(isolatedActor)
		}
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new top-level task isolated to the given actor.
	/// The operation will not execute until all prior tasks – including
	/// suspended tasks – have completed.
	///
	/// Use this function when creating asynchronous work
	/// that operates on behalf of the synchronous function that calls it.
	/// Like `Task.detached(priority:operation:)`,
	/// this function creates a separate, top-level task.
	/// Unlike `Task.detached(priority:operation:)`,
	/// the task created by `Task.init(priority:operation:)`
	/// inherits the priority and actor context of the caller,
	/// so the operation is treated more like an asynchronous extension
	/// to the synchronous operation.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a detached task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - isolatedActor: The actor to which the operation is isolated.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on fifoQueue: FIFOQueue,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async throws -> Success,
	) where Failure == any Error {
		let turn = fifoQueue.turns.reserve()
		self.init(name: name, priority: fifoQueue.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			defer { turn.end() }
			return try await operation(isolatedActor)
		}
	}
}
