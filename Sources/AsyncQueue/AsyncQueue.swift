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

/// A queue that enables ordered sending of events from synchronous to asynchronous code
public final class AsyncQueue: Sendable {

    // MARK: Initialization

    /// Instantiates an asynchronous queue.
    /// - Parameter priority: The baseline priority of the tasks added to the asynchronous queue.
    public init(priority: TaskPriority? = nil) {
        var capturedTaskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation? = nil
        let taskStream = AsyncStream<@Sendable () async -> Void> { continuation in
            capturedTaskStreamContinuation = continuation
        }
        guard let capturedTaskStreamContinuation else {
            fatalError("Continuation not captured during stream creation!")
        }
        taskStreamContinuation = capturedTaskStreamContinuation

        streamTask = Task.detached(priority: priority) {
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
    /// The schedueled task will not execute until all prior tasks have completed.
    /// - Parameter task: The task to enqueue.
    public func async(_ task: @escaping @Sendable () async -> Void) {
        taskStreamContinuation.yield(task)
    }

    /// Schedules an asynchronous throwing task and returns after the task is complete.
    /// The schedueled task will not execute until all prior tasks have completed.
    /// - Parameter task: The task to enqueue.
    /// - Returns: The value returned from the enqueued task.
    public func await<T>(_ task: @escaping @Sendable () async -> T) async -> T {
        await withUnsafeContinuation { continuation in
            taskStreamContinuation.yield {
                continuation.resume(returning: await task())
            }
        }
    }

    /// Schedules an asynchronous task and returns after the task is complete.
    /// The schedueled task will not execute until all prior tasks have completed.
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

    private let streamTask: Task<Void, Never>
    private let taskStreamContinuation: AsyncStream<@Sendable () async -> Void>.Continuation
}
