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
        var capturedTaskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation? = nil
        let taskStream = AsyncStream<@Sendable () async -> Void> { continuation in
            capturedTaskStreamContinuation = continuation
        }
        // Continuation will be captured during stream creation, so it is safe to force unwrap here.
        // If this force-unwrap fails, something is fundamentally broken in the Swift runtime.
        taskStreamContinuation = capturedTaskStreamContinuation!

        Task.detached(priority: priority) {
            for await task in taskStream {
                await task()
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameter task: The task to enqueue.
    public func enqueue(_ task: @escaping @Sendable () async -> Void) {
        taskStreamContinuation.yield(task)
    }

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameters:
    ///   - isolatedActor: The actor within which the task is isolated.
    ///   - task: The task to enqueue.
    public func enqueue<ActorType: Actor>(on isolatedActor: ActorType, _ task: @escaping @Sendable (isolated ActorType) async -> Void) {
        taskStreamContinuation.yield { await task(isolatedActor) }
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable () async -> T) async -> T {
        await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield {
                continuation.resume(returning: await task())
            }
        }
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameters:
    ///   - isolatedActor: The actor within which the task is isolated.
    ///   - task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<ActorType: Actor, T: Sendable>(on isolatedActor: isolated ActorType, _ task: @escaping @Sendable (isolated ActorType) async -> T) async -> T {
        await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield {
                continuation.resume(returning: await task(isolatedActor))
            }
        }
    }

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable () async throws -> T) async throws -> T {
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

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks – including suspended tasks – have completed.
    /// - Parameters:
    ///   - isolatedActor: The actor within which the task is isolated.
    ///   - task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<ActorType: Actor, T: Sendable>(on isolatedActor: isolated ActorType, _ task: @escaping @Sendable (isolated ActorType) async throws -> T) async throws -> T {
        try await withUnsafeThrowingContinuation { continuation in
            taskStreamContinuation.yield {
                do {
                    continuation.resume(returning: try await task(isolatedActor))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: Private

    private let taskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation
}
