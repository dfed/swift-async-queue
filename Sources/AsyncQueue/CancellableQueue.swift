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

#if canImport(FoundationEssentials)
	import FoundationEssentials
#else
	import Foundation
#endif
import Synchronization

/// A queue that wraps a `FIFOQueue` or an `ActorQueue` and lets you cancel all of its unfinished tasks at once.
public final class CancellableQueue<UnderlyingQueue: Sendable>: Sendable {
	// MARK: Initialization

	/// Creates a cancellable queue.
	/// - Parameter underlyingQueue: The `FIFOQueue` or `ActorQueue` to wrap.
	public init(underlyingQueue: UnderlyingQueue) {
		self.underlyingQueue = underlyingQueue
	}

	// MARK: Public

	/// Cancels every unfinished task that you enqueued on this queue, whether it's running or waiting.
	/// Tasks that you enqueue afterward aren't affected.
	///
	/// If another thread is still enqueuing a task when you call this method, the task is cancelled as soon as it's enqueued.
	///
	/// If another call to this method is in progress, this call may return before the other call finishes cancelling the tasks it found.
	public func cancelTasks() {
		let cancellations = taskIdentifierToState.withLock { taskIdentifierToState in
			var cancellations = [@Sendable () -> Void]()
			taskIdentifierToState = taskIdentifierToState.compactMapValues { state in
				switch state {
				case let .registered(cancel):
					cancellations.append(cancel)
					return nil
				case .reserved, .cancellationRequested:
					// The task has not registered its `cancel` closure yet, so cancel it once it does.
					return .cancellationRequested
				}
			}
			return cancellations
		}
		// Cancelling a task synchronously runs its cancellation handlers, which may call back into this queue.
		// Cancel only after releasing the lock so that those handlers can never re-enter it.
		for cancel in cancellations {
			cancel()
		}
	}

	// MARK: Internal

	/// Reserves an identifier for a task that is about to be created.
	/// Reserving before the task starts ensures the task's removal of the identifier can never be processed before the reservation.
	func reserveTaskIdentifier() -> UUID {
		let identifier = UUID()
		taskIdentifierToState.withLock {
			$0[identifier] = .reserved
		}
		return identifier
	}

	/// Registers the `cancel` closure for a task whose identifier was previously reserved.
	/// Cancels the task if `cancelTasks()` was called after the identifier was reserved.
	func registerCancellation(forTaskWithIdentifier identifier: UUID, _ cancel: @escaping @Sendable () -> Void) {
		let isCancellationRequested = taskIdentifierToState.withLock { taskIdentifierToState in
			switch taskIdentifierToState[identifier] {
			case .reserved:
				taskIdentifierToState[identifier] = .registered(cancel)
				return false
			case .cancellationRequested:
				taskIdentifierToState[identifier] = nil
				return true
			case .registered, nil:
				// The task already finished, so there is nothing to cancel.
				return false
			}
		}
		if isCancellationRequested {
			// Cancel only after releasing the lock. See `cancelTasks()`.
			cancel()
		}
	}

	/// Removes the identifier of a task that has finished executing.
	func taskDidFinish(withIdentifier identifier: UUID) {
		taskIdentifierToState.withLock {
			$0[identifier] = nil
		}
	}

	/// Tracks the task that `createTask` creates to perform `operation`, so that `cancelTasks()` can cancel it.
	/// Reserves the task's identifier before the task is created and registers its `cancel` closure afterward,
	/// so that the task may finish, or `cancelTasks()` may be called, while it is being created.
	///
	/// Always inlined: without `@inline(__always)`, the generic call is not inlined, and enqueuing a task on a
	/// `CancellableQueue` measured about 11% slower.
	@inline(__always)
	func trackTask<Operation, Success, Failure>(
		performing operation: sending Operation,
		createdBy createTask: (_ identifier: UUID, _ operation: sending Operation) -> Task<Success, Failure>,
	) -> Task<Success, Failure> {
		let identifier = reserveTaskIdentifier()
		let task = createTask(identifier, operation)
		registerCancellation(forTaskWithIdentifier: identifier, task.cancel)
		return task
	}

	// MARK: Fileprivate

	fileprivate let underlyingQueue: UnderlyingQueue

	/// The state of each enqueued task that has not finished executing.
	/// Never cancel a task while holding this lock: cancellation handlers run synchronously and may call back into this queue.
	fileprivate let taskIdentifierToState = Mutex<[UUID: TaskState]>([:])

	fileprivate enum TaskState: Sendable {
		/// The task is being enqueued, and has not registered its `cancel` closure yet.
		case reserved
		/// `cancelTasks()` was called before the task registered its `cancel` closure, so the task is cancelled when it registers.
		case cancellationRequested
		/// The task registered its `cancel` closure.
		case registered(@Sendable () -> Void)
	}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on actorQueue: CancellableQueue<ActorQueue<ActorType>>,
		operation: @Sendable @escaping (isolated ActorType) async -> Success,
	) where Failure == Never {
		self = actorQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: actorQueue.underlyingQueue, operation: {
				defer {
					actorQueue.taskDidFinish(withIdentifier: identifier)
				}
				return await operation($0)
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on actorQueue: CancellableQueue<ActorQueue<ActorType>>,
		operation: @escaping @Sendable (isolated ActorType) async throws -> Success,
	) where Failure == any Error {
		self = actorQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: actorQueue.underlyingQueue, operation: {
				defer {
					actorQueue.taskDidFinish(withIdentifier: identifier)
				}
				return try await operation($0)
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on actorQueue: CancellableQueue<ActorQueue<MainActor>>,
		operation: @MainActor @escaping () async -> Success,
	) where Failure == Never {
		self = actorQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: actorQueue.underlyingQueue, operation: {
				defer {
					actorQueue.taskDidFinish(withIdentifier: identifier)
				}
				return await operation()
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on actorQueue: CancellableQueue<ActorQueue<MainActor>>,
		operation: @escaping @MainActor () async throws -> Success,
	) where Failure == any Error {
		self = actorQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: actorQueue.underlyingQueue, operation: {
				defer {
					actorQueue.taskDidFinish(withIdentifier: identifier)
				}
				return try await operation()
			})
		}
	}

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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on fifoQueue: CancellableQueue<FIFOQueue>,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async -> Success,
	) where Failure == Never {
		self = fifoQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: fifoQueue.underlyingQueue, operation: {
				defer {
					fifoQueue.taskDidFinish(withIdentifier: identifier)
				}
				return await operation()
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on fifoQueue: CancellableQueue<FIFOQueue>,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async throws -> Success,
	) where Failure == any Error {
		self = fifoQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: fifoQueue.underlyingQueue, operation: {
				defer {
					fifoQueue.taskDidFinish(withIdentifier: identifier)
				}
				return try await operation()
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on fifoQueue: CancellableQueue<FIFOQueue>,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async -> Success,
	) where Failure == Never {
		self = fifoQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: fifoQueue.underlyingQueue, isolatedTo: isolatedActor, operation: {
				defer {
					fifoQueue.taskDidFinish(withIdentifier: identifier)
				}
				return await operation($0)
			})
		}
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
	/// Calling the queue's `cancelTasks()` method cancels the task if it hasn't finished.
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
		on fifoQueue: CancellableQueue<FIFOQueue>,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async throws -> Success,
	) where Failure == any Error {
		self = fifoQueue.trackTask(performing: operation) { identifier, operation in
			Task(name: name, priority: priority, on: fifoQueue.underlyingQueue, isolatedTo: isolatedActor, operation: {
				defer {
					fifoQueue.taskDidFinish(withIdentifier: identifier)
				}
				return try await operation($0)
			})
		}
	}
}
