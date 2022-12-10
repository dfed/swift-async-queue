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

/// A queue that executes asynchronous tasks enqueued from a nonisolated context.
/// Tasks are guaranteed to begin executing in the order in which they are enqueued. However, if a task suspends it will allow subsequently enqueued tasks to begin executing.
/// Asynchronous tasks sent to this queue execute as they would in an `actor` type, allowing for re-entrancy and non-FIFO behavior when an individual task suspends.
///
/// An `ActorQueue` is used to ensure tasks sent from a nonisolated context to a single `actor`'s isolated context begin execution in order.
/// Here is an example of how an `ActorQueue` should be utilized within an `actor`:
/// ```
/// public actor LogStore {
///
///     nonisolated
///     public func log(_ message: String) {
///         queue.async {
///             await self.append(message)
///         }
///     }
///
///     nonisolated
///     public func retrieveLogs() async -> [String] {
///         await queue.await { await self.logs }
///     }
///
///     private func append(_ message: String) {
///         logs.append(message)
///     }
///
///     private let queue = ActorQueue()
///     private var logs = [String]()
/// }
/// ```
///
/// - Warning: Execution order is not guaranteed unless the enqueued tasks interact with a single `actor` instance.
public final class ActorQueue {

    // MARK: Initialization

    /// Instantiates an actor queue.
    /// - Parameter priority: The baseline priority of the tasks added to the asynchronous queue.
    public init(priority: TaskPriority? = nil) {
        var capturedTaskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation? = nil
        let taskStream = AsyncStream<@Sendable () async -> Void> { continuation in
            capturedTaskStreamContinuation = continuation
        }
        // Continuation will be captured during stream creation, so it is safe to force unwrap here.
        // If this force-unwrap fails, something is fundamentally broken in the Swift runtime.
        taskStreamContinuation = capturedTaskStreamContinuation!

        Task.detached(priority: priority) {
            let executor = ActorExecutor()
            for await task in taskStream {
                await executor.suspendUntilStarted(task)
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    public func async(_ task: @escaping @Sendable () async -> Void) {
        taskStreamContinuation.yield(task)
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable () async -> T) async -> T {
        await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield {
                continuation.resume(returning: await task())
            }
        }
    }

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withUnsafeThrowingContinuation { continuation in
            taskStreamContinuation.yield {
                do {
                    continuation.resume(returning: try await task())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Private

    private let taskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation

    // MARK: - ActorExecutor

    private actor ActorExecutor {
        func suspendUntilStarted(_ task: @escaping @Sendable () async -> Void) async {
            // Suspend the calling code until our enqueued task starts.
            await withUnsafeContinuation { continuation in
                // Utilize the serial (but not FIFO) Actor context to execute the task without requiring the calling method to wait for the task to complete.
                Task {
                    // Force this task to execute within the ActorExecutor's context by accessing an ivar on the instance.
                    // Without this line the task executes on a random context, causing execution order to be nondeterministic.
                    _ = void

                    // Signal that the task has started. As long as the `task` below interacts with another `actor` the order of execution is guaranteed.
                    continuation.resume()
                    await task()
                }
            }
        }

        private let void: Void = ()
    }

}
