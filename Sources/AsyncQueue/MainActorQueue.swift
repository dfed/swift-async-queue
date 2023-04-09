// MIT License
//
// Copyright (c) 2023 Dan Federman
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

/// A queue that enables enqueing ordered asynchronous tasks from a nonisolated context onto the `@MainActor`'s isolated context.
/// Tasks are guaranteed to begin executing in the order in which they are enqueued. However, if a task suspends it will allow subsequently enqueued tasks to begin executing.
/// This queue exhibits the execution behavior of an actor: tasks sent to this queue can re-enter the queue, and tasks may execute in non-FIFO order when a task suspends.
///
/// A `MainActorQueue` ensures tasks sent from a nonisolated context to the `@MainActor`'s isolated context begin execution in order.
public final class MainActorQueue: Sendable {

    // MARK: Initialization

    /// Instantiates a main actor queue.
    public init() {
        var capturedTaskStreamContinuation: AsyncStream<@Sendable @MainActor () async -> Void>.Continuation? = nil
        let taskStream = AsyncStream<@Sendable @MainActor () async -> Void> { continuation in
            capturedTaskStreamContinuation = continuation
        }
        // Continuation will be captured during stream creation, so it is safe to force unwrap here.
        // If this force-unwrap fails, something is fundamentally broken in the Swift runtime.
        taskStreamContinuation = capturedTaskStreamContinuation!

        Task.detached { @MainActor in
            for await task in taskStream {
                await MainActor.shared.suspendUntilStarted(task)
            }
        }
    }

    deinit {
        taskStreamContinuation.finish()
    }

    // MARK: Public

    /// An easily accessible instance of a `MainActorQueue`.
    public static let shared = MainActorQueue()

    /// Schedules an asynchronous task for execution and immediately returns.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    public func enqueue(_ task: @escaping @Sendable @MainActor () async -> Void) {
        taskStreamContinuation.yield(task)
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The scheduled task will not execute until all prior tasks have completed or suspended.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable @MainActor () async -> T) async -> T {
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
    public func enqueueAndWait<T: Sendable>(_ task: @escaping @Sendable @MainActor () async throws -> T) async throws -> T {
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

    private let taskStreamContinuation: AsyncStream<@Sendable @MainActor () async -> Void>.Continuation
}

extension MainActor {
    @MainActor
    fileprivate func suspendUntilStarted(_ task: @escaping @Sendable @MainActor () async -> Void) async {
        // Suspend the calling code until our enqueued task starts.
        await withUnsafeContinuation { @MainActor continuation in
            // Utilize the serial (but not FIFO) @MainActor context to execute the task without requiring the calling method to wait for the task to complete.
            Task { @MainActor in
                // Signal that the task has started. Since this `task` is executing on the main actor's execution context, the order of execution is guaranteed.
                continuation.resume()
                await task()
            }
        }
    }
}
