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

/// A queue that enables enqueing ordered asynchronous tasks from a nonisolated context onto an adopted actor's isolated context.
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
///         queue.enqueue { myself in
///             myself.logs.append(message)
///         }
///     }
///
///     public func retrieveLogs() async -> [String] {
///         await queue.enqueueAndWait { myself in myself.logs }
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
    public init() {
        (taskStream, taskStreamContinuation) = AsyncStream<ActorTask>.makeStream()
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// Sets the actor context within which each `enqueue` and `enqueueAndWait`ed task will execute.
    /// It is recommended that this method be called in the adopted actor’s `init` method.
    /// **Must be called prior to enqueuing any work on the receiver.**
    ///
    /// - Parameter actor: The actor on which the queue's task will execute. This parameter is not retained by the receiver.
    /// - Precondition: Calling this method more than once will result in a precondition failure.
    public func adoptExecutionContext(of actor: ActorType) {
        precondition(weakExecutionContext == nil) // Adopting multiple executionContexts on the same queue is API abuse.
        weakExecutionContext = actor

        actor.execute { [taskStream] _ in
            func beginExecuting(
                _ operation: sending @escaping (isolated ActorType) async -> Void,
                in context: isolated ActorType
            ) {
                // In Swift 6, a `Task` enqueued from an actor begins executing immediately on that actor.
                // Since we're running on our actor's context due to the isolated parmater, we can just dispatch a Task to get first-enqueued-first-start task execution.
                Task {
                    await operation(context)
                }
            }

            for await actorTask in taskStream {
                // The compiler does not have a guarantee that `actor === actorTask.executionContext`, so we must `await`.
                // In practice, however, that condition is always true, and therefore we do not end up suspending here.
                await beginExecuting(
                    actorTask.task,
                    in: actorTask.executionContext
                )
            }
        }
    }

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue. The task's parameter is a reference to the actor whose execution context has been adopted.
    public func enqueue(_ task: @escaping @Sendable (isolated ActorType) async -> Void) {
        taskStreamContinuation.yield(ActorTask(executionContext: executionContext, task: task))
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue. The task's parameter is a reference to the actor whose execution context has been adopted.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable (isolated ActorType) async -> T) async -> T {
        let executionContext = self.executionContext // Capture/retain the executionContext before suspending.
        return await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield(ActorTask(executionContext: executionContext) { executionContext in
                continuation.resume(returning: await task(executionContext))
            })
        }
    }

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue. The task's parameter is a reference to the actor whose execution context has been adopted.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable (isolated ActorType) async throws -> T) async throws -> T {
        let executionContext = self.executionContext // Capture/retain the executionContext before suspending.
        return try await withUnsafeThrowingContinuation { continuation in
            taskStreamContinuation.yield(ActorTask(executionContext: executionContext) { executionContext in
                do {
                    continuation.resume(returning: try await task(executionContext))
                } catch {
                    continuation.resume(throwing: error)
                }
            })
        }
    }

    // MARK: Private

    private let taskStream: AsyncStream<ActorQueue<ActorType>.ActorTask>
    private let taskStreamContinuation: AsyncStream<ActorTask>.Continuation

    /// The actor on whose isolated context our tasks run, force-unwrapped.
    /// Utilize this accessor to retrieve the weak execution context in order to avoid repeating the below comment.
    private var executionContext: ActorType {
        // Crashing here means that this queue is being sent tasks either before an execution context has been set, or
        // after the execution context has deallocated. An ActorQueue's execution context should be set in the adopted
        // actor's `init` method, and the ActorQueue should not exceed the lifecycle of the adopted actor.
        weakExecutionContext!
    }
    /// The actor on whose isolated context our tasks run.
    /// We must use`weak` here to avoid creating a retain cycle between the adopted actor and this actor queue.
    ///
    /// We will assume this execution context always exists for the lifecycle of the queue because:
    /// 1. The lifecycle of any `ActorQueue` must not exceed the lifecycle of its adopted `actor`.
    /// 2. The adopted `actor` must set itself as the execution context for this queue within its `init` method.
    private weak var weakExecutionContext: ActorType?

    private struct ActorTask {
        let executionContext: ActorType
        let task: @Sendable (isolated ActorType) async -> Void
    }
}

extension Actor {
    nonisolated
    func execute(
        _ task: @escaping @Sendable (isolated Self?) async -> Void
    ) {
        Task {
            await task(nil)
        }
    }
}
