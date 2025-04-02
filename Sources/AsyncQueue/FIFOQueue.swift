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

    /// Instantiates a FIFO queue.
    /// - Parameter priority: The baseline priority of the tasks added to the asynchronous queue.
    public init(priority: TaskPriority? = nil) {
        let (taskStream, taskStreamContinuation) = AsyncStream<FIFOTask>.makeStream()
        self.taskStreamContinuation = taskStreamContinuation

        Task.detached(priority: priority) {
            for await fifoTask in taskStream {
                await fifoTask.task()
                await fifoTask.sempahore.signal()
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Fileprivate

    fileprivate struct FIFOTask: Sendable {
        init(task: @escaping @Sendable () async -> Void) {
            self.task = task
        }
        
        let sempahore = Semaphore()
        let task: @Sendable () async -> Void
    }

    fileprivate let taskStreamContinuation: AsyncStream<FIFOTask>.Continuation
}

extension Task {
    /// Runs the given nonthrowing operation asynchronously
    /// as part of a new top-level task on behalf of the current actor.
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
    ///   - priority: The priority of the task.
    ///     Pass `nil` to use the priority from `Task.currentPriority`.
    ///   - fifoQueue: The queue on which to enqueue the task.
    ///   - operation: The operation to perform.
    @discardableResult
    public init(
        priority: TaskPriority? = nil,
        enqueuedOn fifoQueue: FIFOQueue,
        operation: @Sendable @escaping @isolated(any) () async -> Success
    ) where Failure == Never {
        let delivery = Delivery<Success, Failure>()
        let task = FIFOQueue.FIFOTask {
            await delivery.sendValue(operation())
        }
        fifoQueue.taskStreamContinuation.yield(task)
        self.init(priority: priority) {
            await task.sempahore.wait()
            return await delivery.getValue()
        }
    }

    /// Runs the given throwing operation asynchronously
    /// as part of a new top-level task on behalf of the current actor.
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
    ///   - priority: The priority of the task.
    ///     Pass `nil` to use the priority from `Task.currentPriority`.
    ///   - fifoQueue: The queue on which to enqueue the task.
    ///   - operation: The operation to perform.
    @discardableResult
    public init(
        priority: TaskPriority? = nil,
        enqueuedOn actorQueue: FIFOQueue,
        operation: @escaping @Sendable @isolated(any) () async throws -> Success
    ) where Failure == any Error {
        let delivery = Delivery<Success, Failure>()
        let task = FIFOQueue.FIFOTask {
            do {
                try await delivery.sendValue(operation())
            } catch {
                await delivery.sendFailure(error)
            }
        }
        actorQueue.taskStreamContinuation.yield(task)
        self.init(priority: priority) {
            await task.sempahore.wait()
            return try await delivery.getValue()
        }
    }

    /// Runs the given nonthrowing operation asynchronously
    /// as part of a new top-level task on behalf of the current actor.
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
    ///   - priority: The priority of the task.
    ///     Pass `nil` to use the priority from `Task.currentPriority`.
    ///   - fifoQueue: The queue on which to enqueue the task.
    ///   - isolatedActor: The actor to which the operation is isolated.
    ///   - operation: The operation to perform.
    @discardableResult
    public init<ActorType: Actor>(
        priority: TaskPriority? = nil,
        enqueuedOn fifoQueue: FIFOQueue,
        isolatedTo isolatedActor: ActorType,
        operation: @Sendable @escaping (isolated ActorType) async -> Success
    ) where Failure == Never {
        let delivery = Delivery<Success, Failure>()
        let task = FIFOQueue.FIFOTask {
            await delivery.sendValue(operation(isolatedActor))
        }
        fifoQueue.taskStreamContinuation.yield(task)
        self.init(priority: priority) {
            await task.sempahore.wait()
            return await delivery.getValue()
        }
    }

    /// Runs the given throwing operation asynchronously
    /// as part of a new top-level task on behalf of the current actor.
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
    ///   - priority: The priority of the task.
    ///     Pass `nil` to use the priority from `Task.currentPriority`.
    ///   - fifoQueue: The queue on which to enqueue the task.
    ///   - isolatedActor: The actor to which the operation is isolated.
    ///   - operation: The operation to perform.
    @discardableResult
    public init<ActorType: Actor>(
        priority: TaskPriority? = nil,
        enqueuedOn fifoQueue: FIFOQueue,
        isolatedTo isolatedActor: ActorType,
        operation: @Sendable @escaping (isolated ActorType) async throws -> Success
    ) where Failure == any Error {
        let delivery = Delivery<Success, Failure>()
        let task = FIFOQueue.FIFOTask {
            do {
                try await delivery.sendValue(operation(isolatedActor))
            } catch {
                await delivery.sendFailure(error)
            }
        }
        fifoQueue.taskStreamContinuation.yield(task)
        self.init(priority: priority) {
            await task.sempahore.wait()
            return try await delivery.getValue()
        }
    }
}
