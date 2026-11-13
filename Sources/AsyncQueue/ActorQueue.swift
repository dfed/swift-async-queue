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

/// A queue that enables enqueuing ordered asynchronous tasks from a nonisolated context onto an adopted actor's isolated context.
/// Tasks are guaranteed to begin executing in the order in which they are enqueued. However, if a task suspends it will allow subsequently enqueued tasks to begin executing.
/// This queue exhibits the execution behavior of an actor: tasks sent to this queue can re-enter the queue, and tasks may execute in non-FIFO order when a task suspends.
///
/// An `ActorQueue` ensures tasks sent from a nonisolated context to a single actor's isolated context begin execution in order.
/// Here is an example of how an `ActorQueue` should be utilized within an actor:
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
/// - Warning: The `ActorQueue`'s conformance to `@unchecked Sendable` is safe if and only if `adoptExecutionContext(of:)` is called only from the adopted actor's `init` method.
/// - Precondition: The lifecycle of an `ActorQueue` must not exceed that of the adopted actor.
public final class ActorQueue<ActorType: Actor>: @unchecked Sendable {
	// MARK: Initialization

	/// Instantiates an actor queue.
	public init() {}

	// MARK: Public

	/// Sets the actor context within which each `enqueue` and `enqueueAndWait`ed task will execute.
	/// It is recommended that this method be called in the adopted actor’s `init` method.
	/// **Must be called prior to enqueuing any work on the receiver.**
	///
	/// - Parameter actor: The actor on which the queue's task will execute. This parameter is not retained by the receiver.
	/// - Warning: Calling this method more than once will result in an assertion failure.
	public func adoptExecutionContext(of actor: ActorType) {
		assert(weakExecutionContext == nil) // Adopting multiple executionContexts on the same queue is API abuse.
		weakExecutionContext = actor
	}

	// MARK: Internal

	/// Hands out turns to begin executing on the adopted actor, in the order in which tasks are enqueued.
	let turns = Turns()

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
	/// as part of a new top-level task on behalf of the current actor.
	/// The operation will not execute until all prior tasks have
	/// completed or suspended.
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
	///   - priority: The priority of the operation task.
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
		self.init(name: name, priority: priority) {
			await turn.begin()
			return await execute(operation, on: executionContext, endingTurn: turn)
		}
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new top-level task on behalf of the current actor.
	/// The operation will not execute until all prior tasks have
	/// completed or suspended.
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
		self.init(name: name, priority: priority) {
			await turn.begin()
			return try await execute(operation, on: executionContext, endingTurn: turn)
		}
	}

	/// Runs the given nonthrowing operation asynchronously
	/// as part of a new top-level task on behalf of the current actor.
	/// The operation will not execute until all prior tasks have
	/// completed or suspended.
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
		self.init(name: name, priority: priority) {
			await turn.begin()
			return await executeOnMainActor(operation, endingTurn: turn)
		}
	}

	/// Runs the given throwing operation asynchronously
	/// as part of a new top-level task on behalf of the current actor.
	/// The operation will not execute until all prior tasks have
	/// completed or suspended.
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
		self.init(name: name, priority: priority) {
			await turn.begin()
			return try await executeOnMainActor(operation, endingTurn: turn)
		}
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
	public static var queue: ActorQueue<MainActor> {
		mainActorQueue
	}
}

private let mainActorQueue = {
	let queue = ActorQueue<MainActor>()
	queue.adoptExecutionContext(of: MainActor.shared)
	return queue
}()
