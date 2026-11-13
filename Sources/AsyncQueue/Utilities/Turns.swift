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
final class Turns: Sendable {
	// MARK: Initialization

	init() {}

	// MARK: Internal

	/// Reserves the next turn.
	func reserve() -> Turn {
		let ended = Signal()
		let previousTurnEnded = lastTurnEnded.withLock { lastTurnEnded in
			defer { lastTurnEnded = ended }
			return lastTurnEnded
		}
		return Turn(previousTurnEnded: previousTurnEnded, ended: ended)
	}

	// MARK: Private

	/// The signal fired when the most recently reserved turn ends.
	private let lastTurnEnded = Mutex<Signal?>(nil)
}

/// A turn reserved from a `Turns` instance.
struct Turn: Sendable {
	// MARK: Initialization

	fileprivate init(previousTurnEnded: Signal?, ended: Signal) {
		self.previousTurnEnded = previousTurnEnded
		self.ended = ended
	}

	// MARK: Internal

	/// Suspends until every earlier turn has ended.
	/// - Warning: Must be called at most once.
	func begin() async {
		await previousTurnEnded?.wait()
	}

	/// Ends this turn, allowing the next turn to begin.
	func end() {
		ended.fire()
	}

	// MARK: Private

	private let previousTurnEnded: Signal?
	private let ended: Signal
}

// MARK: - Signal

/// A one-shot latch that a single waiter can await.
private final class Signal: Sendable {
	// MARK: Initialization

	init() {}

	// MARK: Internal

	/// Opens the latch, resuming the waiter if there is one.
	func fire() {
		let waiter = state.withLock { state in
			state.isFired = true
			defer { state.waiter = nil }
			return state.waiter
		}
		// Resume the waiter only after releasing the lock: never resume a continuation while holding a lock.
		waiter?.resume()
	}

	/// Suspends until the latch is open. Returns immediately if it is already open.
	/// - Warning: At most one task may wait on a signal.
	func wait() async {
		// A continuation resumed before its task suspends does not suspend the task,
		// so an open latch costs no suspension even without a separate fast path.
		await withUnsafeContinuation { (continuation: UnsafeContinuation<Void, Never>) in
			let isFired = state.withLock { state in
				if !state.isFired {
					state.waiter = continuation
				}
				return state.isFired
			}
			if isFired {
				continuation.resume()
			}
		}
	}

	// MARK: Private

	private struct State {
		var isFired = false
		var waiter: UnsafeContinuation<Void, Never>?
	}

	private let state = Mutex(State())
}
