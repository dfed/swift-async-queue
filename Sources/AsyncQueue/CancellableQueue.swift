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

import Foundation

/// A queue wrapper that enables cancelling all currently executing and pending tasks.
///
/// A `CancellableQueue` wraps either a `FIFOQueue` or an `ActorQueue` and tracks all tasks enqueued on it.
/// Calling `cancelTasks()` will cancel both the currently executing task and any tasks waiting in the queue.
/// Tasks that have already completed are unaffected, and tasks enqueued after `cancelTasks()` is called will execute normally.
public final class CancellableQueue<UnderlyingQueue: Sendable>: Sendable {
	// MARK: Initialization

	/// Instantiates a cancellable queue.
	/// - Parameter underlyingQueue: The queue whose work can be cancelled.
	public init(underlyingQueue: UnderlyingQueue) {
		self.underlyingQueue = underlyingQueue
	}

	// MARK: Public

	/// Cancels the currently executing task, as well as any task currently pending in the queue.
	public func cancelTasks() {
		taskIdentifierToCancelMap.withLock {
			$0.values.forEach { $0() }
			$0.removeAll()
		}
	}

	// MARK: Fileprivate

	fileprivate let underlyingQueue: UnderlyingQueue

	fileprivate let taskIdentifierToCancelMap = Lock<[UUID: () -> Void]>(value: [:])
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		priority: TaskPriority? = nil,
		on actorQueue: CancellableQueue<ActorQueue<ActorType>>,
		operation: @Sendable @escaping (isolated ActorType) async -> Success
	) where Failure == Never {
		let identifier = UUID()
		self.init(priority: priority, on: actorQueue.underlyingQueue, operation: {
			defer {
				actorQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return await operation($0)
		})
		actorQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		priority: TaskPriority? = nil,
		on actorQueue: CancellableQueue<ActorQueue<ActorType>>,
		operation: @escaping @Sendable (isolated ActorType) async throws -> Success
	) where Failure == any Error {
		let identifier = UUID()
		self.init(priority: priority, on: actorQueue.underlyingQueue, operation: {
			defer {
				actorQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return try await operation($0)
		})
		actorQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		priority: TaskPriority? = nil,
		on actorQueue: CancellableQueue<ActorQueue<MainActor>>,
		operation: @MainActor @escaping () async -> Success
	) where Failure == Never {
		let identifier = UUID()
		self.init(priority: priority, on: actorQueue.underlyingQueue, operation: {
			defer {
				actorQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return await operation()
		})
		actorQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - actorQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		priority: TaskPriority? = nil,
		on actorQueue: CancellableQueue<ActorQueue<MainActor>>,
		operation: @escaping @MainActor () async throws -> Success
	) where Failure == any Error {
		let identifier = UUID()
		self.init(priority: priority, on: actorQueue.underlyingQueue, operation: {
			defer {
				actorQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return try await operation()
		})
		actorQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
		}
	}

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
	/// - Parameters:
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		on fifoQueue: CancellableQueue<FIFOQueue>,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async -> Success
	) where Failure == Never {
		let identifier = UUID()
		self.init(on: fifoQueue.underlyingQueue, operation: {
			defer {
				fifoQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return await operation()
		})
		fifoQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - operation: The operation to perform.
	@discardableResult
	public init(
		on fifoQueue: CancellableQueue<FIFOQueue>,
		@_inheritActorContext @_implicitSelfCapture operation: sending @escaping @isolated(any) () async throws -> Success
	) where Failure == any Error {
		let identifier = UUID()
		self.init(on: fifoQueue.underlyingQueue, operation: {
			defer {
				fifoQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return try await operation()
		})
		fifoQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - isolatedActor: The actor to which the operation is isolated.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		priority: TaskPriority? = nil,
		on fifoQueue: CancellableQueue<FIFOQueue>,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async -> Success
	) where Failure == Never {
		let identifier = UUID()
		self.init(priority: priority, on: fifoQueue.underlyingQueue, isolatedTo: isolatedActor, operation: {
			defer {
				fifoQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return await operation($0)
		})
		fifoQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
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
	/// - Parameters:
	///   - priority: The priority of the task.
	///     Pass `nil` to use the priority from `Task.currentPriority`.
	///   - fifoQueue: The queue on which to enqueue the task.
	///   - isolatedActor: The actor to which the operation is isolated.
	///   - operation: The operation to perform.
	@discardableResult
	public init<ActorType: Actor>(
		priority: TaskPriority? = nil,
		on fifoQueue: CancellableQueue<FIFOQueue>,
		isolatedTo isolatedActor: ActorType,
		operation: @Sendable @escaping (isolated ActorType) async throws -> Success
	) where Failure == any Error {
		let identifier = UUID()
		self.init(priority: priority, on: fifoQueue.underlyingQueue, isolatedTo: isolatedActor, operation: {
			defer {
				fifoQueue.taskIdentifierToCancelMap.writeAsync {
					$0[identifier] = nil
				}
			}
			return try await operation($0)
		})
		fifoQueue.taskIdentifierToCancelMap.writeAsync { [cancel] in
			$0[identifier] = cancel
		}
	}
}

// MARK: - Lock

private final class Lock<State>: @unchecked Sendable {
	// MARK: Initialization

	init(value: State) {
		unsafeValue = value
	}

	// MARK: Fileprivate

	fileprivate func withLock<R>(_ body: @Sendable (inout State) throws -> R) rethrows -> R where R: Sendable {
		try lockQueue.sync {
			try body(&unsafeValue)
		}
	}

	fileprivate func writeAsync(_ body: @Sendable @escaping (inout State) -> Void) {
		lockQueue.async {
			body(&self.unsafeValue)
		}
	}

	// MARK: Private

	private var unsafeValue: State

	private let lockQueue = DispatchQueue(label: "ReadWriteLock.Queue", target: DispatchQueue.global())
}
