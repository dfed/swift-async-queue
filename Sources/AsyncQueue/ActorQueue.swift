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

/// A queue that enables enqueing ordered asynchronous tasks from a nonisolated context onto a target `actor`'s isolated context.
/// Tasks are guaranteed to begin executing in the order in which they are enqueued. However, if a task suspends it will allow subsequently enqueued tasks to begin executing.
/// Asynchronous tasks sent to this queue execute as they would in an `actor` type, allowing for re-entrancy and non-FIFO behavior when an individual task suspends.
///
/// An `ActorQueue` is used to ensure tasks sent from a nonisolated context to a single `actor`'s isolated context begin execution in order.
/// Here is an example of how an `ActorQueue` should be utilized within an `actor`:
/// ```swift
/// public actor LogStore {
///
///     public init() {
///         queue.setTargetContext(to: self)
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
/// - Warning: The lifecycle of an `ActorQueue` should not exceed that of the target `actor`.
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
                await actorTask.target.suspendUntilStarted(on: actorTask.target, actorTask.task)
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// Sets the actor context within which each `async` and `await`ed task will execute. Must be called from the target actor's `init` method.
    /// - Parameter actor: The actor on which the queue's task will execute. This parameter is not retained by the receiver.
    public func setTargetContext(to actor: ActorType) {
        assert(target == nil) // Setting multiple targets on the same queue is API abuse.
        target = actor
    }

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    public func async(_ task: @escaping @Sendable (isolated ActorType) async -> Void) {
        taskStreamContinuation.yield(ActorTask(target: target!, task: task))
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable (isolated ActorType) async -> T) async -> T {
        let target = self.target! // Capture/retain the target before suspending.
        return await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield(ActorTask(target: target) { target in
                continuation.resume(returning: await task(target))
            })
        }
    }

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable (isolated ActorType) async throws -> T) async throws -> T {
        let target = self.target! // Capture/retain the target before suspending.
        return try await withUnsafeThrowingContinuation { continuation in
            taskStreamContinuation.yield(ActorTask(target: target) { target in
                do {
                    continuation.resume(returning: try await task(target))
                } catch {
                    continuation.resume(throwing: error)
                }
            })
        }
    }

    // MARK: Private

    private let taskStreamContinuation: AsyncStream<ActorTask>.Continuation

    /// The target actor on whose isolated context our tasks run.
    /// It is safe to use `unowned` here because it is API misuse to interact with an `ActorQueue` from an instance other than the `target`.
    private unowned var target: ActorType?

    private struct ActorTask {
        let target: ActorType
        let task: @Sendable (isolated ActorType) async -> Void
    }

}

extension Actor {
    func suspendUntilStarted(
        on target: Self,
        _ task: @escaping @Sendable (isolated Self) async -> Void
    ) async {
        // Suspend the calling code until our enqueued task starts.
        await withUnsafeContinuation { continuation in
            // Utilize the serial (but not FIFO) Actor context to execute the task without requiring the calling method to wait for the task to complete.
            Task {
                // Signal that the task has started. As long as the `task` below interacts with another `actor` the order of execution is guaranteed.
                continuation.resume()
                await task(self)
            }
        }
    }
}
