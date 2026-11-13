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

import Synchronization

actor Delivery<Success: Sendable, Failure: Error> {
	func sendValue(_ value: Success) {
		self.value = value
	}

	func sendFailure(_ failure: Failure) {
		self.failure = failure
	}

	nonisolated func cancel() {
		let task = taskContainer.withLock {
			$0.isCancelled = true
			return $0.task
		}
		// Cancelling a task synchronously runs its cancellation handlers, which may cancel other tasks.
		// Cancel only after releasing the lock so that those handlers can never re-enter it.
		task?.cancel()
	}

	@discardableResult
	func execute<ActorType: Actor>(
		_ operation: sending @escaping (isolated ActorType) async -> Void,
		in context: isolated ActorType,
		name: String?,
		priority: TaskPriority?,
	) -> Task<Void, Never> {
		// In Swift 6, a `Task` enqueued from an actor begins executing immediately on that actor.
		// Since we're running on our actor's context already, we can just dispatch a Task to get first-enqueued-first-start task execution.
		let task = Task(name: name, priority: priority) {
			await operation(context)
		}
		let isCancelled = taskContainer.withLock {
			$0.task = task
			return $0.isCancelled
		}
		if isCancelled {
			// Cancel only after releasing the lock. See `cancel()`.
			task.cancel()
		}
		return task
	}

	private var value: Success? {
		didSet {
			if let value {
				valueContinuations.forEach { $0.resume(returning: value) }
				valueContinuations.removeAll()
			}
		}
	}

	private var failure: Failure? {
		didSet {
			if let failure {
				valueContinuations.forEach { $0.resume(throwing: failure) }
				valueContinuations.removeAll()
			}
		}
	}

	private var valueContinuations: [UnsafeContinuation<Success, Failure>] = []
	/// Never cancel a task while holding this lock: cancellation handlers run synchronously and may cancel other tasks.
	private let taskContainer = Mutex(TaskContainer())

	struct TaskContainer {
		var task: Task<Void, Never>?
		var isCancelled = false
	}
}

extension Delivery where Failure == Never {
	func getValue() async -> Success {
		if let value {
			value
		} else {
			await withUnsafeContinuation { continuation in
				valueContinuations.append(continuation)
			}
		}
	}
}

extension Delivery where Failure == any Error {
	func getValue() async throws -> Success {
		if let value {
			value
		} else if let failure {
			throw failure
		} else {
			try await withUnsafeThrowingContinuation { continuation in
				valueContinuations.append(continuation)
			}
		}
	}
}
