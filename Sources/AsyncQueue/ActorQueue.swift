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

/// A queue that runs tasks on an actor and starts them in the order you enqueue them.
/// You can enqueue tasks from synchronous or `nonisolated` code.
/// Once a task starts, it behaves like any other code on the actor: when it suspends at an `await`, the next task can start,
/// and it can enqueue another task on the same queue and await its value.
///
/// Each `ActorQueue` belongs to one actor. Here is an example of how to use an `ActorQueue` within an actor:
/// ```swift
/// public actor LogStore {
///
///     public init() {
///         queue.adoptExecutionContext(of: self)
///     }
///
///     nonisolated
///     public func log(_ message: String) {
///         Task(on: queue) { myself in
///             myself.logs.append(message)
///         }
///     }
///
///     public func retrieveLogs() async -> [String] {
///         await Task(on: queue) { myself in myself.logs }.value
///     }
///
///     private let queue = ActorQueue<LogStore>()
///     private var logs = [String]()
/// }
/// ```
///
/// - Warning: The `ActorQueue`'s conformance to `@unchecked Sendable` is safe if and only if `adoptExecutionContext(of:)` is called only from the `init` method of the actor you pass to it.
/// - Precondition: An `ActorQueue` must not outlive the actor you pass to `adoptExecutionContext(of:)`.
public final class ActorQueue<ActorType: Actor>: @unchecked Sendable {
	// MARK: Initialization

	/// Creates an actor queue.
	/// - Parameter priority: The lowest priority at which the queue's tasks run.
	///   A task that would run at a lower priority runs at this priority instead.
	///   Pass `nil` to run each task at the priority you pass to `Task(on:)`,
	///   or, if you pass `nil` there too, at the priority of the code that enqueues it.
	public init(priority: TaskPriority? = nil) {
		minimumPriority = MinimumPriority(priority)
	}

	// MARK: Public

	/// Sets the actor on which this queue runs its tasks.
	/// Call this method once, in that actor's `init`, before you enqueue any task on this queue.
	///
	/// - Parameter actor: The actor on which this queue runs its tasks.
	///   This queue doesn't retain the actor, but each enqueued task retains it until the task finishes.
	/// - Warning: Calling this method more than once causes an assertion failure.
	public func adoptExecutionContext(of actor: ActorType) {
		assert(weakExecutionContext == nil) // Adopting multiple executionContexts on the same queue is API abuse.
		weakExecutionContext = actor
	}

	/// Whether every task you enqueued on this queue has started running on the actor.
	///
	/// A task counts from the moment you enqueue it until it starts running on the actor.
	/// So the queue can be idle while the operations of its tasks haven't finished.
	/// A task runs alongside the code that enqueues it, so the task might start running on the actor before that code reads this property.
	/// If that code is running on the actor, though, the task can't start running there until the code suspends or returns.
	///
	/// The value can change as soon as you read it: a task you enqueue afterward makes the queue busy again.
	/// If one actor enqueues every task on the queue, that actor can read this property and then remove an idle queue
	/// without suspending between the read and the removal.
	/// No task can be enqueued in between, so every task enqueued on the removed queue has started running on the queue's actor.
	public var isIdle: Bool {
		turns.isIdle
	}

	// MARK: Internal

	/// Hands out turns to begin executing on the adopted actor, in the order in which tasks are enqueued.
	let turns = Turns()

	/// The priority that the queue gives each of its tasks at least.
	let minimumPriority: MinimumPriority

	// MARK: Fileprivate

	/// The actor on whose isolated context our tasks run, force-unwrapped.
	/// Utilize this accessor to retrieve the weak execution context in order to avoid repeating the below comment.
	fileprivate var executionContext: ActorType {
		// Crashing here means that this queue is being sent tasks either before an execution context has been set, or
		// after the execution context has deallocated. An ActorQueue's execution context should be set in the adopted
		// actor's `init` method, and the ActorQueue should not exceed the lifecycle of the adopted actor.
		weakExecutionContext!
	}

	// MARK: Private

	/// The actor on whose isolated context our tasks run.
	/// We must use`weak` here to avoid creating a retain cycle between the adopted actor and this actor queue.
	///
	/// We will assume this execution context always exists for the lifecycle of the queue because:
	/// 1. The lifecycle of any `ActorQueue` must not exceed the lifecycle of its adopted `actor`.
	/// 2. The adopted `actor` must set itself as the execution context for this queue within its `init` method.
	private weak var weakExecutionContext: ActorType?
}

extension Task {
	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new unstructured task isolated to the queue's actor.
	/// The operation doesn't run until every task enqueued before it has finished or suspended.
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
	/// after every task enqueued before it has finished or suspended.
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
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on actorQueue: ActorQueue<ActorType>,
		operation: @Sendable @escaping (isolated ActorType) async -> Success,
	) where Failure == Never {
		let executionContext = actorQueue.executionContext
		let turn = actorQueue.turns.reserve()
		self.init(name: name, priority: actorQueue.minimumPriority.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			return await execute(operation, on: executionContext, endingTurn: turn)
		}
		turn.register(self)
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new unstructured task isolated to the queue's actor.
	/// The operation doesn't run until every task enqueued before it has finished or suspended.
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
	/// after every task enqueued before it has finished or suspended.
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
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on actorQueue: ActorQueue<ActorType>,
		operation: @escaping @Sendable (isolated ActorType) async throws -> Success,
	) where Failure == any Error {
		let executionContext = actorQueue.executionContext
		let turn = actorQueue.turns.reserve()
		self.init(name: name, priority: actorQueue.minimumPriority.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			return try await execute(operation, on: executionContext, endingTurn: turn)
		}
		turn.register(self)
	}

	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new unstructured task isolated to the main actor.
	/// The operation doesn't run until every task enqueued before it has finished or suspended.
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
	/// after every task enqueued before it has finished or suspended.
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
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on actorQueue: ActorQueue<MainActor>,
		operation: @MainActor @escaping () async -> Success,
	) where Failure == Never {
		let turn = actorQueue.turns.reserve()
		self.init(name: name, priority: actorQueue.minimumPriority.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			return await executeOnMainActor(operation, endingTurn: turn)
		}
		turn.register(self)
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new unstructured task isolated to the main actor.
	/// The operation doesn't run until every task enqueued before it has finished or suspended.
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
	/// after every task enqueued before it has finished or suspended.
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
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		name: String? = nil,
		priority: TaskPriority? = nil,
		on actorQueue: ActorQueue<MainActor>,
		operation: @escaping @MainActor () async throws -> Success,
	) where Failure == any Error {
		let turn = actorQueue.turns.reserve()
		self.init(name: name, priority: actorQueue.minimumPriority.priority(forTaskEnqueuedWith: priority)) {
			await turn.begin()
			return try await executeOnMainActor(operation, endingTurn: turn)
		}
		turn.register(self)
	}
}

// MARK: - Execution

/// Executes `operation` on `actor`, ending `turn` as soon as the task is isolated to `actor`.
///
/// Ending the turn lets the next enqueued task hop to `actor`. That task cannot execute on `actor`
/// until `operation` suspends or returns, so tasks begin executing in the order in which they were enqueued.
private func execute<ActorType: Actor, Success>(
	_ operation: (isolated ActorType) async throws -> Success,
	on actor: isolated ActorType,
	endingTurn turn: Turn,
) async rethrows -> Success {
	turn.end()
	return try await operation(actor)
}

/// Executes `operation` on the main actor, ending `turn` as soon as the task is isolated to the main actor.
///
/// Ending the turn lets the next enqueued task hop to the main actor. That task cannot execute on the main actor
/// until `operation` suspends or returns, so tasks begin executing in the order in which they were enqueued.
@MainActor
private func executeOnMainActor<Success>(
	_ operation: @MainActor () async throws -> Success,
	endingTurn turn: Turn,
) async rethrows -> Success {
	turn.end()
	return try await operation()
}

extension MainActor {
	/// A global instance of an `ActorQueue<MainActor>`.
	///
	/// This queue has no priority of its own: each task runs at the priority you pass to `Task(on:)`,
	/// or, if you pass `nil`, at the priority of the code that enqueues it.
	/// Pass a `priority` to `Task(on:)` when you enqueue important work from low-priority code.
	public static var queue: ActorQueue<MainActor> {
		mainActorQueue
	}
}

private let mainActorQueue = {
	let queue = ActorQueue<MainActor>()
	queue.adoptExecutionContext(of: MainActor.shared)
	return queue
}()
