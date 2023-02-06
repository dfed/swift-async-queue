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
///         queue.async { myself in
///             myself.logs.append(message)
///         }
///     }
///
///     nonisolated
///     public func retrieveLogs() async -> [String] {
///         await queue.await { myself in myself.logs }
///     }
///
///     private let queue = ActorQueue<LogStore>()
///     private var logs = [String]()
/// }
/// ```
///
/// - Warning: The lifecycle of an `ActorQueue` should not exceed that of the adopted actor.
public final class ActorQueue<ActorType: Actor> {

    // MARK: Initialization

    /// Instantiates an actor queue.
    public init() {
        var capturedTaskStreamContinuation: AsyncStream<ActorTask>.Continuation? = nil
        let taskStream = AsyncStream<ActorTask> { continuation in
            capturedTaskStreamContinuation = continuation
        }
        // Continuation will be captured during stream creation, so it is safe to force unwrap here.
        // If this force-unwrap fails, something is fundamentally broken in the Swift runtime.
        taskStreamContinuation = capturedTaskStreamContinuation!

        Task.detached {
            for await actorTask in taskStream {
                await actorTask.executionContext.suspendUntilStarted(actorTask.task)
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// Sets the actor context within which each `async` and `await`ed task will execute.
    /// It is recommended that this method be called in the adopted actor’s `init` method.
    /// **Must be called prior to enqueuing any work on the receiver.**
    ///
    /// - Parameter actor: The actor on which the queue's task will execute. This parameter is not retained by the receiver.
    /// - Warning: Calling this method more than once will result in an assertion failure.
    public func adoptExecutionContext(of actor: ActorType) {
        assert(executionContext == nil) // Setting multiple executionContexts on the same queue is API abuse.
        executionContext = actor
    }

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue. The task's parameter is a reference to the actor whose execution context has been adopted.
    public func async(_ task: @escaping @Sendable (isolated ActorType) async -> Void) {
        // Crashing here means that this queue is being sent tasks either before an execution context has been set, or
        // after the execution context has deallocated. An ActorQueue's execution context should be set in the adopted
        // actor's `init` method, and the ActorQueue should not exceed the lifecycle of the adopted actor.
        taskStreamContinuation.yield(ActorTask(executionContext: executionContext!, task: task))
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue. The task's parameter is a reference to the actor whose execution context has been adopted.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable (isolated ActorType) async -> T) async -> T {
        // Crashing here means that this queue is being sent tasks either before an execution context has been set, or
        // after the execution context has deallocated. An ActorQueue's execution context should be set in the adopted
        // actor's `init` method, and the ActorQueue should not exceed the lifecycle of the adopted actor.
        let executionContext = self.executionContext! // Capture/retain the executionContext before suspending.
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
    public func await<T>(_ task: @escaping @Sendable (isolated ActorType) async throws -> T) async throws -> T {
        // Crashing here means that this queue is being sent tasks either before an execution context has been set, or
        // after the execution context has deallocated. An ActorQueue's execution context should be set in the adopted
        // actor's `init` method, and the ActorQueue should not exceed the lifecycle of the adopted actor.
        let executionContext = self.executionContext! // Capture/retain the executionContext before suspending.
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

    private let taskStreamContinuation: AsyncStream<ActorTask>.Continuation

    /// The executionContext actor on whose isolated context our tasks run.
    /// It is safe to use `unowned` here because it is API misuse to interact with an `ActorQueue` from an instance other than the `executionContext`.
    private unowned var executionContext: ActorType?

    private struct ActorTask {
        let executionContext: ActorType
        let task: @Sendable (isolated ActorType) async -> Void
    }

}

extension Actor {
    func suspendUntilStarted(_ task: @escaping @Sendable (isolated Self) async -> Void) async {
        // Suspend the calling code until our enqueued task starts.
        await withUnsafeContinuation { continuation in
            // Utilize the serial (but not FIFO) Actor context to execute the task without requiring the calling method to wait for the task to complete.
            Task {
                // Signal that the task has started. Since this `task` is executing on the current actor's execution context, the order of execution is guaranteed.
                continuation.resume()
                await task(self)
            }
        }
    }
}
