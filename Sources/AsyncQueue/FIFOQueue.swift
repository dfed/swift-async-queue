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

/// A queue that runs one task at a time, in the order you enqueue them: first in, first out.
/// You can enqueue tasks from synchronous or `nonisolated` code.
/// Each task waits until every task enqueued before it has finished, so tasks start and finish in the order you enqueue them.
/// A task that is suspended at an `await` hasn't finished.
/// Inside a task on this queue, don't await another task that you enqueue on the same queue:
/// each task waits for the other, so both wait forever.
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

	// MARK: Public

	/// Whether every task you enqueued on this queue has finished.
	///
	/// A task counts from the moment you enqueue it until its operation returns or throws.
	/// A task that is suspended at an `await` hasn't finished,
	/// so an operation that reads this property on its own queue always reads `false`.
	/// A cancelled task hasn't finished either: it keeps its place in the queue, and its operation still runs.
	/// A task runs alongside the code that enqueues it, so the task might finish before that code reads this property.
	/// If the task's operation needs an actor that the code is running on, though,
	/// the task can't finish until the code suspends or returns.
	///
	/// The value can change as soon as you read it: a task you enqueue afterward makes the queue busy again.
	/// If one actor enqueues every task on the queue, that actor can read this property and then safely remove an idle queue,
	/// without suspending between the read and the removal.
	/// No task can be enqueued in between, and a task that the actor enqueues afterward on a new queue
	/// runs after every task on the removed queue, because they have all finished.
	/// For example, an actor that keeps one queue per document can remove the queues of documents whose work has finished:
	///
	/// ```swift
	/// actor DocumentStore {
	///     func save(_ contents: String, as name: String) -> Task<Void, Never> {
	///         let queue = queues[name] ?? FIFOQueue()
	///         queues[name] = queue
	///         return Task(on: queue) {
	///             await self.write(contents, as: name)
	///         }
	///     }
	///
	///     func removeIdleQueues() {
	///         queues = queues.filter { !$0.value.isIdle }
	///     }
	///
	///     private func write(_ contents: String, as name: String) async {
	///         // Write implementation…
	///     }
	///
	///     private var queues = [String: FIFOQueue]()
	/// }
	/// ```
	public var isIdle: Bool {
		turns.isIdle
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
	/// as part of a new unstructured task that runs with the same actor isolation as the code that enqueues it.
	/// The operation doesn't run until every task enqueued before it has finished.
	/// A task that is suspended at an `await` hasn't finished.
	///
	/// Like a task created with `Task.init(name:priority:operation:)`, the task inherits the task-local values
	/// and, unless you pass a `priority`, the priority of the code that enqueues it.
	/// When a higher-priority task awaits the task's value, Swift escalates the task's priority.
	/// On Linux, and on macOS 26, iOS 26, tvOS 26, watchOS 26, and visionOS 26 or later,
	/// a task that waits on the queue also escalates the tasks ahead of it to its own priority.
	/// On earlier releases, the tasks ahead keep their own priority.
	/// An escalated task keeps that priority until it finishes.
	///
	/// Cancelling the task doesn't remove it from the queue: the operation still runs,
	/// after every task enqueued before it has finished.
	/// Check `Task.isCancelled` or call `Task.checkCancellation()` within the operation to stop early.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to inherit the priority of the code that enqueues the task,
	///     as a task created with `Task.init(name:priority:operation:)` does.
	///     If the queue was created with a higher priority, the task runs at the queue's priority instead.
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
		turn.register(self)
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new unstructured task that runs with the same actor isolation as the code that enqueues it.
	/// The operation doesn't run until every task enqueued before it has finished.
	/// A task that is suspended at an `await` hasn't finished.
	///
	/// Like a task created with `Task.init(name:priority:operation:)`, the task inherits the task-local values
	/// and, unless you pass a `priority`, the priority of the code that enqueues it.
	/// When a higher-priority task awaits the task's value, Swift escalates the task's priority.
	/// On Linux, and on macOS 26, iOS 26, tvOS 26, watchOS 26, and visionOS 26 or later,
	/// a task that waits on the queue also escalates the tasks ahead of it to its own priority.
	/// On earlier releases, the tasks ahead keep their own priority.
	/// An escalated task keeps that priority until it finishes.
	///
	/// Cancelling the task doesn't remove it from the queue: the operation still runs,
	/// after every task enqueued before it has finished.
	/// Check `Task.isCancelled` or call `Task.checkCancellation()` within the operation to stop early.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to inherit the priority of the code that enqueues the task,
	///     as a task created with `Task.init(name:priority:operation:)` does.
	///     If the queue was created with a higher priority, the task runs at the queue's priority instead.
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
		turn.register(self)
	}

	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new unstructured task isolated to the given actor.
	/// The operation doesn't run until every task enqueued before it has finished.
	/// A task that is suspended at an `await` hasn't finished.
	///
	/// Like a task created with `Task.init(name:priority:operation:)`, the task inherits the task-local values
	/// and, unless you pass a `priority`, the priority of the code that enqueues it.
	/// When a higher-priority task awaits the task's value, Swift escalates the task's priority.
	/// On Linux, and on macOS 26, iOS 26, tvOS 26, watchOS 26, and visionOS 26 or later,
	/// a task that waits on the queue also escalates the tasks ahead of it to its own priority.
	/// On earlier releases, the tasks ahead keep their own priority.
	/// An escalated task keeps that priority until it finishes.
	///
	/// Cancelling the task doesn't remove it from the queue: the operation still runs,
	/// after every task enqueued before it has finished.
	/// Check `Task.isCancelled` or call `Task.checkCancellation()` within the operation to stop early.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to inherit the priority of the code that enqueues the task,
	///     as a task created with `Task.init(name:priority:operation:)` does.
	///     If the queue was created with a higher priority, the task runs at the queue's priority instead.
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
		turn.register(self)
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new unstructured task isolated to the given actor.
	/// The operation doesn't run until every task enqueued before it has finished.
	/// A task that is suspended at an `await` hasn't finished.
	///
	/// Like a task created with `Task.init(name:priority:operation:)`, the task inherits the task-local values
	/// and, unless you pass a `priority`, the priority of the code that enqueues it.
	/// When a higher-priority task awaits the task's value, Swift escalates the task's priority.
	/// On Linux, and on macOS 26, iOS 26, tvOS 26, watchOS 26, and visionOS 26 or later,
	/// a task that waits on the queue also escalates the tasks ahead of it to its own priority.
	/// On earlier releases, the tasks ahead keep their own priority.
	/// An escalated task keeps that priority until it finishes.
	///
	/// Cancelling the task doesn't remove it from the queue: the operation still runs,
	/// after every task enqueued before it has finished.
	/// Check `Task.isCancelled` or call `Task.checkCancellation()` within the operation to stop early.
	///
	/// You need to keep a reference to the task
	/// if you want to cancel it by calling the `Task.cancel()` method.
	/// Discarding your reference to a task
	/// doesn't implicitly cancel that task,
	/// it only makes it impossible for you to explicitly cancel the task.
	///
	/// - Parameters:
	///   - name: Human readable name of the task.
	///   - priority: The priority of the task.
	///     Pass `nil` to inherit the priority of the code that enqueues the task,
	///     as a task created with `Task.init(name:priority:operation:)` does.
	///     If the queue was created with a higher priority, the task runs at the queue's priority instead.
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
		turn.register(self)
	}
}
