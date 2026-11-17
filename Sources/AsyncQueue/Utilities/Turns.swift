// MIT License
//
// Copyright (c) 2026 Dan Federman
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

/// Hands out turns in the order in which they are reserved.
///
/// Each turn begins once every turn reserved before it has ended.
///
/// Where the runtime supports priority escalation, a task waiting for its turn escalates the task holding the current turn
/// to the waiting task's priority, so that a high-priority task does not wait on a low-priority task indefinitely.
/// The current turn is held by the earliest turn that has not ended, whether or not its task has started running.
/// When a turn ends, the next turn's task is escalated to the highest priority of the tasks still waiting before it is resumed.
/// Escalation therefore never walks the queue, however many tasks are waiting.
final class Turns: Sendable {
	// MARK: Initialization

	/// - Parameter escalatesPriority: Whether waiting tasks escalate the task holding the current turn.
	///   Tests pass `false` to exercise the behavior of runtimes that cannot escalate another task.
	init(escalatesPriority: Bool = true) {
		self.escalatesPriority = escalatesPriority
	}

	// MARK: Internal

	/// Reserves the next turn.
	func reserve() -> Turn {
		let ticket = Ticket()
		let previousTicket = state.withLock { state in
			defer { state.lastTicket = ticket }
			if let lastTicket = state.lastTicket, !lastTicket.hasEnded {
				lastTicket.next = ticket
			} else {
				// Every earlier turn has ended, so this turn is the current turn.
				state.holder = ticket
				state.holderPriority = nil
			}
			return state.lastTicket
		}
		return Turn(turns: self, previousTicket: previousTicket, ticket: ticket)
	}

	/// The number of tasks waiting for their turn whose priority is recorded. Used by tests.
	var waitingTaskCount: Int {
		state.withLock { $0.waitingTaskCounts.values.reduce(0, +) }
	}

	/// The highest priority of the tasks waiting for their turn whose priority is recorded. Used by tests.
	var highestWaitingPriority: TaskPriority? {
		state.withLock(\.highestWaitingPriority)
	}

	/// Records that the task waiting for `ticket`'s turn was escalated to `priority`, and escalates the task holding the
	/// current turn to match from a new task, so the task holding the turn may be escalated after this method returns.
	/// Called by the waiting task's escalation handler. Tests call it directly to deliver escalations in orders that the
	/// runtime allows but cannot be made to produce on demand.
	func waitingTicket(_ ticket: Ticket, wasEscalatedTo priority: TaskPriority) {
		let escalateHolder = state.withLock { state -> (@Sendable () -> Void)? in
			// Ignore the escalation if the ticket is not waiting yet, is no longer waiting, or already waits at this
			// priority or higher.
			guard let waitingPriority = ticket.waitingPriority, waitingPriority < priority else { return nil }
			state.removeWaitingTask(at: waitingPriority)
			state.addWaitingTask(at: priority)
			ticket.waitingPriority = priority
			return state.escalateHolder(to: priority)
		}
		if let escalateHolder {
			// The runtime holds the waiting task's status lock while it runs the task's escalation handler, and
			// escalating the task holding the turn takes that task's status lock. A cancellation handler of the task
			// holding the turn runs under that task's status lock and may cancel the waiting task, which takes the
			// locks in the opposite order. Escalate from a new task so that this handler never waits for another
			// task's status lock. Escalation only raises a task's priority, so escalations that run late or out of
			// order still leave the task at the highest priority requested.
			Task.detached(priority: priority) {
				escalateHolder()
			}
		}
	}

	// MARK: Fileprivate

	fileprivate let escalatesPriority: Bool

	fileprivate func register(
		escalation escalate: @escaping @Sendable (TaskPriority) -> Void,
		for ticket: Ticket,
	) {
		let priority = state.withLock { state -> TaskPriority? in
			guard !ticket.hasEnded else {
				// Do not retain a task that has already ended its turn.
				return nil
			}
			ticket.escalate = escalate
			// Waiting tasks may have asked to escalate this ticket's task before it was registered.
			return state.holder === ticket ? state.holderPriority : nil
		}
		if let priority {
			escalate(priority)
		}
	}

	fileprivate func begin(_ ticket: Ticket, after previousTicket: Ticket?) async {
		if let previousTicket {
			if escalatesPriority, #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) {
				await withTaskPriorityEscalationHandler {
					await wait(for: previousTicket, as: ticket, recordingPriority: true)
				} onPriorityEscalated: { [self] _, newPriority in
					waitingTicket(ticket, wasEscalatedTo: newPriority)
				}
			} else {
				await wait(for: previousTicket, as: ticket, recordingPriority: false)
			}
		}
		state.withLock { state in
			if let waitingPriority = ticket.waitingPriority {
				state.removeWaitingTask(at: waitingPriority)
				ticket.waitingPriority = nil
			}
		}
	}

	fileprivate func end(_ ticket: Ticket) {
		let (successor, escalateNextHolder) = state.withLock { state -> (UnsafeContinuation<Void, Never>?, (@Sendable () -> Void)?) in
			ticket.hasEnded = true
			// Release the task now that waiting tasks no longer need to escalate it.
			ticket.escalate = nil
			var escalateNextHolder: (@Sendable () -> Void)?
			if state.holder === ticket {
				// Turns end in order, so the next ticket, if one has been reserved, holds the current turn now.
				state.holder = ticket.next
				state.holderPriority = nil
				if let highestWaitingPriority = state.highestWaitingPriority {
					escalateNextHolder = state.escalateHolder(to: highestWaitingPriority)
				}
			}
			ticket.next = nil
			defer { ticket.successor = nil }
			return (ticket.successor, escalateNextHolder)
		}
		// Escalate and resume only after releasing the lock: either may synchronously run other code.
		// Escalating before resuming means the next task is scheduled at its escalated priority.
		escalateNextHolder?()
		successor?.resume()
	}

	// MARK: Private

	private struct State {
		/// The most recently reserved ticket.
		var lastTicket: Ticket?
		/// The earliest ticket whose turn has not ended, if any.
		var holder: Ticket?
		/// The priority to which the holder's task has been escalated on behalf of waiting tasks.
		var holderPriority: TaskPriority?
		/// The number of tasks waiting for their turn, by the raw value of their priority.
		var waitingTaskCounts = [UInt8: Int]()

		var highestWaitingPriority: TaskPriority? {
			waitingTaskCounts.keys.max().map(TaskPriority.init(rawValue:))
		}

		mutating func addWaitingTask(at priority: TaskPriority) {
			waitingTaskCounts[priority.rawValue, default: 0] += 1
		}

		mutating func removeWaitingTask(at priority: TaskPriority) {
			let count = waitingTaskCounts[priority.rawValue, default: 0] - 1
			waitingTaskCounts[priority.rawValue] = count > 0 ? count : nil
		}

		/// Records that the holder's task should execute at `priority` or higher.
		/// - Returns: A closure that escalates the holder's task, to be called after releasing the lock.
		mutating func escalateHolder(to priority: TaskPriority) -> (@Sendable () -> Void)? {
			guard let holder, holderPriority.map({ $0 < priority }) ?? true else { return nil }
			holderPriority = priority
			// If the holder's task is not yet registered, registering it applies `holderPriority`.
			guard let escalate = holder.escalate else { return nil }
			return { escalate(priority) }
		}
	}

	private let state = Mutex(State())

	private func wait(for previousTicket: Ticket, as ticket: Ticket, recordingPriority: Bool) async {
		await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
			let (hasPreviousTicketEnded, escalateHolder) = state.withLock { state -> (Bool, (@Sendable () -> Void)?) in
				guard !previousTicket.hasEnded else { return (true, nil) }
				previousTicket.successor = continuation
				guard recordingPriority else { return (false, nil) }
				// Read the priority under the lock so that an escalation of this task is either reflected here
				// or delivered to `waitingTicket(_:wasEscalatedTo:)` after this ticket is recorded as waiting.
				let priority = Task.currentPriority
				ticket.waitingPriority = priority
				state.addWaitingTask(at: priority)
				return (false, state.escalateHolder(to: priority))
			}
			// Escalate and resume only after releasing the lock: either may synchronously run other code.
			// A continuation resumed before its task suspends does not suspend the task.
			escalateHolder?()
			if hasPreviousTicketEnded {
				continuation.resume()
			}
		}
	}
}

/// A turn reserved from a `Turns` instance.
struct Turn: Sendable {
	// MARK: Initialization

	fileprivate init(turns: Turns, previousTicket: Ticket?, ticket: Ticket) {
		self.turns = turns
		self.previousTicket = previousTicket
		self.ticket = ticket
	}

	// MARK: Internal

	/// The state of this turn. Used by tests.
	let ticket: Ticket

	/// Registers the task that takes this turn, so that tasks waiting for later turns can escalate its priority.
	func register(_ task: Task<some Sendable, some Error>) {
		guard turns.escalatesPriority, #available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *) else { return }
		turns.register(escalation: { task.escalatePriority(to: $0) }, for: ticket)
	}

	/// Suspends until every earlier turn has ended.
	/// - Warning: Must be called at most once, from the task that takes this turn.
	func begin() async {
		await turns.begin(ticket, after: previousTicket)
	}

	/// Ends this turn, allowing the next turn to begin.
	/// - Warning: Must be called exactly once, after `begin()` returns.
	func end() {
		turns.end(ticket)
	}

	// MARK: Private

	private let turns: Turns
	private let previousTicket: Ticket?
}

// MARK: - Ticket

/// The state of one turn. Every property is guarded by the lock of the `Turns` instance that reserved the ticket.
final class Ticket: @unchecked Sendable {
	/// Whether the turn has ended.
	var hasEnded = false
	/// The ticket reserved after this one, while this ticket's turn has not ended.
	var next: Ticket?
	/// The continuation of the task waiting for this turn to end.
	var successor: UnsafeContinuation<Void, Never>?
	/// The priority of this ticket's task while it waits for its turn, or `nil` if it is not waiting.
	var waitingPriority: TaskPriority?
	/// Escalates this ticket's task. Set once the task is registered, and cleared when its turn ends.
	var escalate: (@Sendable (TaskPriority) -> Void)?
}
