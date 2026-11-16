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

import Dispatch
import Synchronization
import Testing

@testable import AsyncQueue

struct TurnsTests {
	// MARK: Behavior Tests

	@Test
	func begin_withoutEscalation_waitsForEarlierTurnToEnd() async {
		// Runtimes that cannot escalate another task take this path.
		let systemUnderTest = Turns(escalatesPriority: false)
		let firstTurn = systemUnderTest.reserve()
		let hasSecondTurnBegun = probeNextTurn(of: systemUnderTest)
		await firstTurn.begin()
		let didSecondTurnBeginBeforeFirstTurnEnded = hasSecondTurnBegun()
		firstTurn.end()
		let didSecondTurnBeginAfterFirstTurnEnded = hasSecondTurnBegun()
		#expect(!didSecondTurnBeginBeforeFirstTurnEnded)
		#expect(didSecondTurnBeginAfterFirstTurnEnded)
	}

	@Test
	func begin_withoutEscalation_beginsTurnsInOrderOfReservation() async {
		// Runtimes that cannot escalate another task take this path.
		let systemUnderTest = Turns(escalatesPriority: false)
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let laterTurns = (1...3).map { _ in systemUnderTest.reserve() }
		let begunTurns = Mutex([Int]())
		// Start the tasks in the reverse order of their turns, so that only the turns can make them begin in order.
		let tasks = laterTurns.indices.reversed().map { index in
			Task(executorPreference: executor) {
				await laterTurns[index].begin()
				begunTurns.withLock { $0.append(index) }
				laterTurns[index].end()
			}
		}
		// Run every task until it waits for its turn.
		executor.runUntilIdle()
		let turnsBegunBeforeFirstTurnEnded = begunTurns.withLock(\.self)
		await firstTurn.begin()
		// Ending the first turn lets the later turns begin, one after another, on the executor.
		firstTurn.end()
		executor.runUntilIdle()
		for task in tasks {
			await task.value
		}
		#expect(turnsBegunBeforeFirstTurnEnded.isEmpty)
		#expect(begunTurns.withLock(\.self) == Array(laterTurns.indices))
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func begin_withEscalation_waitsForEarlierTurnToEndAndRecordsTaskAsWaitingUntilThen() async {
		let systemUnderTest = Turns()
		let firstTurn = systemUnderTest.reserve()
		let hasSecondTurnBegun = probeNextTurn(of: systemUnderTest)
		await firstTurn.begin()
		let didSecondTurnBeginBeforeFirstTurnEnded = hasSecondTurnBegun()
		let waitingTaskCountBeforeFirstTurnEnded = systemUnderTest.waitingTaskCount
		firstTurn.end()
		let didSecondTurnBeginAfterFirstTurnEnded = hasSecondTurnBegun()
		#expect(!didSecondTurnBeginBeforeFirstTurnEnded)
		#expect(waitingTaskCountBeforeFirstTurnEnded == 1)
		#expect(didSecondTurnBeginAfterFirstTurnEnded)
		#expect(systemUnderTest.waitingTaskCount == 0)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func reserve_afterEveryEarlierTurnEnds_makesReservedTurnCurrent() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let escalations = Mutex([TaskPriority]())
		// Take two turns, reserving the second only once the first has ended, as on a queue that is idle between tasks.
		// A higher-priority task waits behind each turn, so the second turn also shows that the first turn's escalation
		// does not carry over to it.
		for _ in 1...2 {
			let currentTurn = systemUnderTest.reserve()
			let (allowedToEnd, allowedToEndContinuation) = AsyncStream<Void>.makeStream()
			let currentTask = Task(executorPreference: executor, priority: .low) {
				await currentTurn.begin()
				await withTaskPriorityEscalationHandler {
					var allowedToEndIterator = allowedToEnd.makeAsyncIterator()
					await allowedToEndIterator.next()
				} onPriorityEscalated: { _, newPriority in
					escalations.withLock { $0.append(newPriority) }
				}
				currentTurn.end()
			}
			currentTurn.register(currentTask)
			let nextTurn = systemUnderTest.reserve()
			let waitingTask = Task(executorPreference: executor, priority: .high) {
				await nextTurn.begin()
				nextTurn.end()
			}
			nextTurn.register(waitingTask)
			// Run the current task until it waits to be allowed to end, then the waiting task until it waits for its turn.
			// Beginning to wait escalates the task holding the current turn, which runs that task's handler.
			executor.runUntilIdle()
			allowedToEndContinuation.finish()
			// Ending the current turn lets the waiting task take its turn, on the executor.
			executor.runUntilIdle()
			await currentTask.value
			await waitingTask.value
		}
		// The waiting task escalated each turn's task once, including the task of the turn reserved once every earlier
		// turn had ended.
		#expect(escalations.withLock(\.self) == [.high, .high])
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func waitingTaskBehindDeepBacklog_escalatedWhileWaiting_escalatesTaskHoldingTurn() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the turns' help.
		let holder = Task(priority: .low) {
			await firstTurn.begin()
			await suspendUntilEscalated(to: .high)
			let priority = Task.currentPriority
			// End the turn before reporting, so that the waiting tasks can take their turns once the priority arrives.
			firstTurn.end()
			prioritiesContinuation.yield(priority)
		}
		firstTurn.register(holder)
		let waitingTasks = (1...10_000).map { _ in
			let turn = systemUnderTest.reserve()
			let task = Task(executorPreference: executor, priority: .low) {
				await turn.begin()
				turn.end()
			}
			turn.register(task)
			return task
		}
		// Run every waiting task until it waits for its turn, at its own priority.
		executor.runUntilIdle()
		// Escalating the last waiting task escalates the task holding the current turn, from a new task.
		waitingTasks[waitingTasks.count - 1].escalatePriority(to: .high)
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		// Ending the holder's turn lets the waiting tasks take their turns, one after another, on the executor.
		executor.runUntilIdle()
		for task in waitingTasks {
			await task.value
		}
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func register_afterHigherPriorityTaskBeginsWaiting_escalatesRegisteredTask() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let waitingTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn. It asks to escalate the task holding the first turn,
		// which is not registered yet.
		executor.runUntilIdle()
		let firstTaskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the turns' help.
		let firstTask = Task(priority: .low) {
			await firstTurn.begin()
			await firstTaskAllowedToReport.wait()
			let priority = Task.currentPriority
			// End the turn before reporting, so that the waiting task can take its turn once the priority arrives.
			firstTurn.end()
			prioritiesContinuation.yield(priority)
		}
		// Registering the task applies the escalation that the waiting task asked for, before this call returns.
		firstTurn.register(firstTask)
		await firstTaskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func register_afterHigherPriorityTaskBeginsWaiting_doesNotEscalateTaskForLaterTurn() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let thirdTurn = systemUnderTest.reserve()
		let waitingTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn. It asks to escalate the task holding the first turn,
		// which is not registered yet.
		executor.runUntilIdle()
		let secondTurnEnded = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it.
		let lowerPriorityTask = Task(priority: .low) {
			await thirdTurn.begin()
			// Report the priority only once ending the second turn has returned, after any escalation it applies.
			await secondTurnEnded.wait()
			prioritiesContinuation.yield(Task.currentPriority)
			thirdTurn.end()
		}
		// The escalation the waiting task asked for belongs to the task holding the first turn, not to this task.
		thirdTurn.register(lowerPriorityTask)
		await firstTurn.begin()
		// Ending the first turn resumes the waiting task on the executor, and ending its turn lets the third turn begin.
		firstTurn.end()
		executor.runUntilIdle()
		await secondTurnEnded.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await waitingTask.value
		await lowerPriorityTask.value
		#expect(priority == .low)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func register_afterHigherThenLowerPriorityTasksBeginWaiting_escalatesRegisteredTaskToHigherPriority() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let thirdTurn = systemUnderTest.reserve()
		let higherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(higherPriorityTask)
		// Run the higher-priority task until it waits for its turn. It asks to escalate the task holding the first turn,
		// which is not registered yet.
		executor.runUntilIdle()
		let lowerPriorityTask = Task(executorPreference: executor, priority: .medium) {
			await thirdTurn.begin()
			thirdTurn.end()
		}
		thirdTurn.register(lowerPriorityTask)
		// Run the lower-priority task until it waits for its turn. It asks to escalate the same task to a lower priority.
		executor.runUntilIdle()
		let firstTaskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the turns' help.
		let firstTask = Task(priority: .low) {
			await firstTurn.begin()
			await firstTaskAllowedToReport.wait()
			let priority = Task.currentPriority
			// End the turn before reporting, so that the waiting tasks can take their turns once the priority arrives.
			firstTurn.end()
			prioritiesContinuation.yield(priority)
		}
		// Registering the task applies the escalation that the waiting tasks asked for, before this call returns.
		firstTurn.register(firstTask)
		await firstTaskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await higherPriorityTask.value
		await lowerPriorityTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func register_whenTaskHasEscalationHandlerThatUsesTurns_escalatesTask() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let higherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(higherPriorityTask)
		// Run the waiting task until it waits for its turn. It asks to escalate the task holding the first turn,
		// which is not registered yet.
		executor.runUntilIdle()
		let (handlerInstalled, handlerInstalledContinuation) = AsyncStream<Void>.makeStream()
		let firstTaskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		let firstTask = taskWithEscalationHandler(
			using: systemUnderTest,
			taking: firstTurn,
			handlerInstalled: handlerInstalledContinuation,
			allowedToReport: firstTaskAllowedToReport,
			priorities: prioritiesContinuation,
		)
		var handlerInstalledIterator = handlerInstalled.makeAsyncIterator()
		await handlerInstalledIterator.next()
		// Registering the task applies the escalation that the waiting task asked for, which runs the task's handler
		// before this call returns.
		firstTurn.register(firstTask)
		await firstTaskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await higherPriorityTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func register_afterTurnEnds_doesNotRetainTask() async {
		let systemUnderTest = Turns()
		let turn = systemUnderTest.reserve()
		await turn.begin()
		turn.end()
		weak let result = await valueOfTask(registeredAfterItsTurnEnded: turn)
		// The ended turn is still the last one reserved, so retaining the task would keep its result alive.
		#expect(result == nil)
		// Keep the turn, and with it the turns, alive until after the check.
		withExtendedLifetime(turn) {}
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func begin_whenWaitingTaskIsEscalated_recordsEscalationAndEscalatesTaskHoldingTurn() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let waitingTaskInspected = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the turns' help.
		let firstTask = Task(priority: .low) {
			await firstTurn.begin()
			// Hold the turn until the test has inspected the waiting task's record.
			await waitingTaskInspected.wait()
			await suspendUntilEscalated(to: .high)
			let priority = Task.currentPriority
			// End the turn before reporting, so that the waiting task can take its turn once the priority arrives.
			firstTurn.end()
			prioritiesContinuation.yield(priority)
		}
		firstTurn.register(firstTask)
		let waitingTask = Task(executorPreference: executor, priority: .medium) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn, recorded at its own priority.
		executor.runUntilIdle()
		// The task is already recorded as waiting, so only its escalation handler can deliver this escalation.
		// The handler records the escalation on this thread before `escalatePriority(to:)` returns, and escalates the
		// task holding the current turn from a new task.
		waitingTask.escalatePriority(to: .high)
		#expect(systemUnderTest.waitingTaskCount == 1)
		#expect(systemUnderTest.highestWaitingPriority == .high)
		await waitingTaskInspected.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(priority.map { $0 >= .high } == true)
		#expect(systemUnderTest.waitingTaskCount == 0)
		#expect(systemUnderTest.highestWaitingPriority == nil)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func waitingTicket_beforeTaskIsRecordedAsWaiting_doesNotRecordTask() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let waitingTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		// An escalation can reach the waiting task's escalation handler after the handler is installed but before the
		// task is recorded as waiting. The task's priority already reflects the escalation, so recording the task reads it.
		systemUnderTest.waitingTicket(secondTurn.ticket, wasEscalatedTo: .high)
		let waitingTaskCountBeforeTaskWaits = systemUnderTest.waitingTaskCount
		// Run the waiting task until it waits for its turn.
		executor.runUntilIdle()
		let waitingTaskCountWhileTaskWaits = systemUnderTest.waitingTaskCount
		await firstTurn.begin()
		// Ending the first turn lets the waiting task take its turn, on the executor.
		firstTurn.end()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(waitingTaskCountBeforeTaskWaits == 0)
		#expect(waitingTaskCountWhileTaskWaits == 1)
		#expect(systemUnderTest.waitingTaskCount == 0)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func waitingTicket_afterEscalationToHigherPriority_ignoresEscalationToLowerPriority() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let waitingTask = Task(executorPreference: executor, priority: .low) {
			await secondTurn.begin()
			secondTurn.end()
		}
		// Run the waiting task until it waits for its turn, recorded at its own priority.
		executor.runUntilIdle()
		// The runtime raises a task's priority before it runs the task's escalation handler, so escalations that race
		// can reach the handler out of order. Deliver an escalation to `.high`, and then a late escalation to `.medium`.
		systemUnderTest.waitingTicket(secondTurn.ticket, wasEscalatedTo: .high)
		systemUnderTest.waitingTicket(secondTurn.ticket, wasEscalatedTo: .medium)
		#expect(systemUnderTest.highestWaitingPriority == .high)
		await firstTurn.begin()
		// Ending the first turn lets the waiting task take its turn, on the executor.
		firstTurn.end()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(systemUnderTest.waitingTaskCount == 0)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func begin_whenTaskHoldingTurnHasEscalationHandlerThatUsesTurns_escalatesTaskHoldingTurn() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let (handlerInstalled, handlerInstalledContinuation) = AsyncStream<Void>.makeStream()
		let firstTaskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		let firstTask = taskWithEscalationHandler(
			using: systemUnderTest,
			taking: firstTurn,
			handlerInstalled: handlerInstalledContinuation,
			allowedToReport: firstTaskAllowedToReport,
			priorities: prioritiesContinuation,
		)
		firstTurn.register(firstTask)
		var handlerInstalledIterator = handlerInstalled.makeAsyncIterator()
		await handlerInstalledIterator.next()
		let waitingTask = Task(executorPreference: executor, priority: .medium) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn. Beginning to wait escalates the first task,
		// which runs the first task's handler.
		executor.runUntilIdle()
		// Escalating the waiting task escalates the first task again, from a new task, which runs the first task's
		// handler again.
		waitingTask.escalatePriority(to: .high)
		await firstTaskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await waitingTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func begin_whenWaitingTaskIsEscalatedWhileTaskHoldingTurnRunsCancellationHandler_escalatesTaskHoldingTurnWithoutWaitingForHandler() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let (handlerInstalled, handlerInstalledContinuation) = AsyncStream<Void>.makeStream()
		let (handlerRunning, handlerRunningContinuation) = AsyncStream<Void>.makeStream()
		let waitingTaskEscalated = DispatchSemaphore(value: 0)
		let firstTaskAllowedToContinue = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task: awaiting it would escalate it without the turns' help.
		let firstTask = Task(priority: .low) {
			await firstTurn.begin()
			await withTaskCancellationHandler {
				handlerInstalledContinuation.yield()
				// Wait for the test rather than for cancellation, so that this task does not resume and wait for its own
				// status lock while its cancellation handler runs.
				await firstTaskAllowedToContinue.wait()
			} onCancel: {
				// The runtime holds this task's status lock while it runs this handler, and escalating this task takes
				// that lock. Hold the lock until escalating the waiting task has returned.
				handlerRunningContinuation.yield()
				waitingTaskEscalated.wait()
			}
			await suspendUntilEscalated(to: .high)
			let priority = Task.currentPriority
			// End the turn before reporting, so that the waiting task can take its turn once the priority arrives.
			firstTurn.end()
			prioritiesContinuation.yield(priority)
		}
		firstTurn.register(firstTask)
		let waitingTask = Task(executorPreference: executor, priority: .low) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(waitingTask)
		// Run the waiting task until it waits for its turn, recorded at its own priority.
		executor.runUntilIdle()
		var handlerInstalledIterator = handlerInstalled.makeAsyncIterator()
		await handlerInstalledIterator.next()
		// Cancel the first task on a thread of its own, since its cancellation handler blocks that thread.
		DispatchQueue(label: "cancelFirstTask").async {
			firstTask.cancel()
		}
		var handlerRunningIterator = handlerRunning.makeAsyncIterator()
		await handlerRunningIterator.next()
		// Only the waiting task's escalation handler can deliver this escalation. If the handler escalated the first task
		// before returning, it would wait for the first task's status lock, which the first task's cancellation handler
		// holds until this call returns, and this test would never finish.
		waitingTask.escalatePriority(to: .high)
		waitingTaskEscalated.signal()
		await firstTaskAllowedToContinue.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		// Ending the first turn lets the waiting task take its turn, on the executor.
		executor.runUntilIdle()
		await waitingTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func end_afterTaskIsRegistered_releasesTask() async {
		let systemUnderTest = Turns()
		let turn = systemUnderTest.reserve()
		weak let result = await valueOfTask(takingTurnAfterItIsRegistered: turn)
		// The ended turn is still the last one reserved, so retaining the task would keep its result alive.
		#expect(result == nil)
		// Keep the turn, and with it the turns, alive until after the check.
		withExtendedLifetime(turn) {}
	}

	@Test
	func end_whileEarlierTurnIsRetained_releasesLaterTurns() async {
		let systemUnderTest = Turns()
		let firstTurn = systemUnderTest.reserve()
		weak let laterTicket = await ticketOfTurn(reservedAndTakenAfter: firstTurn, from: systemUnderTest)
		// Reserve another turn, so that the turns no longer reference the later turn as the last one reserved.
		_ = systemUnderTest.reserve()
		// A queued task keeps its turn until the task completes, so a turn must not keep later turns alive.
		#expect(laterTicket == nil)
		withExtendedLifetime(firstTurn) {}
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func end_whileHigherPriorityTaskWaits_resumesNextTaskAtEscalatedPriority() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let thirdTurn = systemUnderTest.reserve()
		let nextTask = Task(executorPreference: executor, priority: .medium) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(nextTask)
		let higherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await thirdTurn.begin()
			thirdTurn.end()
		}
		thirdTurn.register(higherPriorityTask)
		// Run both tasks until they wait for their turns.
		executor.runUntilIdle()
		let enqueuedJobCount = executor.enqueuedJobPriorities.count
		await firstTurn.begin()
		// Ending the turn resumes the next task, which enqueues the task's next job before `end()` returns.
		firstTurn.end()
		let resumedJobPriority = executor.enqueuedJobPriorities.dropFirst(enqueuedJobCount).first
		executor.runUntilIdle()
		await nextTask.value
		await higherPriorityTask.value
		#expect(resumedJobPriority.map { $0 >= .high } == true)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func end_afterHigherPriorityTaskStopsWaiting_doesNotEscalateNextTask() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let higherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(higherPriorityTask)
		// Run the higher-priority task until it waits for its turn.
		executor.runUntilIdle()
		await firstTurn.begin()
		// Ending the first turn resumes the higher-priority task, which stops waiting when its turn begins.
		firstTurn.end()
		executor.runUntilIdle()
		await higherPriorityTask.value
		// No task waits any longer, so ending the next turn has no priority to escalate the task after it to.
		let thirdTurn = systemUnderTest.reserve()
		let fourthTurn = systemUnderTest.reserve()
		let thirdTurnEnded = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it.
		let lowerPriorityTask = Task(priority: .low) {
			await fourthTurn.begin()
			// Report the priority only once `end()` returns, after any escalation it applies.
			await thirdTurnEnded.wait()
			prioritiesContinuation.yield(Task.currentPriority)
			fourthTurn.end()
		}
		fourthTurn.register(lowerPriorityTask)
		await thirdTurn.begin()
		thirdTurn.end()
		await thirdTurnEnded.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		await lowerPriorityTask.value
		#expect(priority == .low)
	}

	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	@Test
	func end_afterOneOfTwoHigherPriorityTasksStopsWaiting_escalatesNextTask() async {
		let systemUnderTest = Turns()
		let executor = ManualTaskExecutor()
		let firstTurn = systemUnderTest.reserve()
		let secondTurn = systemUnderTest.reserve()
		let thirdTurn = systemUnderTest.reserve()
		let fourthTurn = systemUnderTest.reserve()
		let firstHigherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await secondTurn.begin()
			secondTurn.end()
		}
		secondTurn.register(firstHigherPriorityTask)
		let secondHigherPriorityTask = Task(executorPreference: executor, priority: .high) {
			await fourthTurn.begin()
			fourthTurn.end()
		}
		fourthTurn.register(secondHigherPriorityTask)
		// Run both higher-priority tasks until they wait for their turns.
		executor.runUntilIdle()
		let lowerPriorityTaskAllowedToReport = Semaphore()
		let (priorities, prioritiesContinuation) = AsyncStream<TaskPriority>.makeStream()
		// Never await this task before it reports its priority: awaiting it would escalate it.
		let lowerPriorityTask = Task(priority: .low) {
			await thirdTurn.begin()
			await lowerPriorityTaskAllowedToReport.wait()
			let priority = Task.currentPriority
			// End the turn before reporting, so that the second higher-priority task can take its turn once the priority arrives.
			thirdTurn.end()
			prioritiesContinuation.yield(priority)
		}
		thirdTurn.register(lowerPriorityTask)
		await firstTurn.begin()
		// Ending the first turn resumes the first higher-priority task, which stops waiting when its turn begins.
		// Ending its turn escalates the lower-priority task, on behalf of the second higher-priority task,
		// before the executor runs out of jobs.
		firstTurn.end()
		executor.runUntilIdle()
		await lowerPriorityTaskAllowedToReport.signal()
		var prioritiesIterator = priorities.makeAsyncIterator()
		let priority = await prioritiesIterator.next()
		executor.runUntilIdle()
		await firstHigherPriorityTask.value
		await secondHigherPriorityTask.value
		await lowerPriorityTask.value
		#expect(priority.map { $0 >= .high } == true)
	}

	// MARK: Private

	/// Creates a task that takes `turn` and, once its turn begins, installs an escalation handler that uses `turns`,
	/// as an operation's own escalation handler may.
	/// - Parameters:
	///   - turns: The turns from which `turn` was reserved.
	///   - turn: The turn that the task takes.
	///   - handlerInstalled: Receives a value once the task's escalation handler is installed.
	///   - allowedToReport: Signaled by the test once it has escalated the task.
	///   - priorities: Receives the task's priority once `allowedToReport` is signaled, the task has been escalated to
	///     `.high` or higher, and the task has ended its turn.
	@available(macOS 26, iOS 26, tvOS 26, watchOS 26, visionOS 26, *)
	private func taskWithEscalationHandler(
		using turns: Turns,
		taking turn: Turn,
		handlerInstalled: AsyncStream<Void>.Continuation,
		allowedToReport: Semaphore,
		priorities: AsyncStream<TaskPriority>.Continuation,
	) -> Task<Void, Never> {
		// Never await this task: awaiting it would escalate it without the turns' help.
		Task(priority: .low) {
			await turn.begin()
			let priority = await withTaskPriorityEscalationHandler {
				handlerInstalled.yield()
				await allowedToReport.wait()
				await suspendUntilEscalated(to: .high)
				return Task.currentPriority
			} onPriorityEscalated: { _, _ in
				// The turns must not hold their lock while escalating a task, or this deadlocks.
				_ = turns.waitingTaskCount
			}
			// End the turn before reporting, so that the waiting task can take its turn once the priority arrives.
			turn.end()
			priorities.yield(priority)
		}
	}

	/// Returns the value of a task that is registered for `turn` after the turn ended, once nothing else references the task.
	private func valueOfTask(registeredAfterItsTurnEnded turn: Turn) async -> Counter {
		let executor = ManualTaskExecutor()
		let task = Task(executorPreference: executor) { Counter() }
		// Run the task to completion, so that the executor no longer runs it once this function returns.
		executor.runUntilIdle()
		let value = await task.value
		turn.register(task)
		return value
	}

	/// Returns the value of a task that takes `turn` after it is registered for the turn, once nothing else references the task.
	private func valueOfTask(takingTurnAfterItIsRegistered turn: Turn) async -> Counter {
		let executor = ManualTaskExecutor()
		let task = Task(executorPreference: executor) {
			await turn.begin()
			turn.end()
			return Counter()
		}
		turn.register(task)
		// Run the task only once it is registered, and to completion, so that the executor no longer runs it
		// once this function returns.
		executor.runUntilIdle()
		return await task.value
	}

	/// Reserves a turn after `earlierTurn`, takes both turns in order, and returns the ticket of the turn it reserved.
	private func ticketOfTurn(reservedAndTakenAfter earlierTurn: Turn, from turns: Turns) async -> Ticket {
		let turn = turns.reserve()
		await earlierTurn.begin()
		earlierTurn.end()
		await turn.begin()
		turn.end()
		return turn.ticket
	}
}
