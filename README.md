# swift-async-queue
[![CI Status](https://img.shields.io/github/actions/workflow/status/dfed/swift-async-queue/ci.yml?branch=main)](https://github.com/dfed/swift-async-queue/actions?query=workflow%3ACI+branch%3Amain)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://spdx.org/licenses/MIT.html)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/dfed/swift-async-queue)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/dfed/swift-async-queue)

When you create several tasks from synchronous or `nonisolated` code, Swift doesn't guarantee the order in which they run, even if they all call the same actor. The queues in this library run tasks in the order you enqueue them.

## Task ordering in Swift concurrency

The following test creates 100 tasks in a loop. Each task calls the same actor and expects to be the next one to run:

```swift
@Test
func actorTaskOrdering() async {
    actor Counter {
        func incrementAndAssertCountEquals(_ expectedCount: Int) {
            count += 1
            let incrementedCount = count
            #expect(incrementedCount == expectedCount) // often fails
        }

        private var count = 0
    }

    let counter = Counter()
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(Task {
            await counter.incrementAndAssertCountEquals(iteration)
        })
    }
    // Wait for all enqueued tasks to finish.
    for task in tasks {
        _ = await task.value
    }
}
```

In the code above, the loop creates the tasks in order, but the tasks can run on the actor in a different order. When they do, the expectation fails. An [actor](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors) runs only one piece of code at a time, but it doesn't promise to run tasks in the order you create them. The queues in this library do.

## Choosing a queue

To enqueue a task, call `Task(on:)` with a queue instead of `Task.init`. Like `Task.init`, it works from synchronous code and returns the new task, so you can await its value or cancel it.

- Use a `FIFOQueue` when each task must finish before the next task starts.
- Use an `ActorQueue` when tasks must start in order on your own actor. The next task can start while an earlier one is suspended.
- Use `MainActor.queue` when tasks must start in order on the main actor.
- Use a `CancellableQueue` around a `FIFOQueue` or an `ActorQueue` when you need to cancel all of its tasks at once.

## Running tasks one at a time with `FIFOQueue`

A `FIFOQueue` runs one task at a time, first in, first out. Each task waits until every task enqueued before it has finished, including a task that is suspended at an `await`. So tasks start and finish in the order you enqueue them, much like work on a serial `DispatchQueue`.

For example, here's how you might use a `FIFOQueue` so that the counter counts in order:

```swift
@Test
func fIFOQueueOrdering() async {
    actor Counter {
        nonisolated
        func incrementAndAssertCountEquals(_ expectedCount: Int) -> Task<Void, Never> {
            Task(on: queue) {
                await self.increment()
                let incrementedCount = await self.count
                #expect(incrementedCount == expectedCount) // always succeeds
            }
        }

        func increment() {
            count += 1
        }

        private var count = 0
        private let queue = FIFOQueue()
    }

    let counter = Counter()
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(counter.incrementAndAssertCountEquals(iteration))
    }
    // Wait for all enqueued tasks to finish.
    for task in tasks {
        _ = await task.value
    }
}
```

In the code above, `incrementAndAssertCountEquals(_:)` is `nonisolated`, so synchronous code can call it. The closure you pass to `Task(on:)` is the task's *operation*. Here, the operation doesn't run on the actor, so it uses `await` to call `increment()` and read `count`.

Keep these points in mind when you use a `FIFOQueue`:

- Inside a task on a `FIFOQueue`, don't await another task that you enqueue on the same queue. The new task waits for the current task to finish, and the current task waits for the new one, so both wait forever.
- If the next task should start while one is suspended at an `await`, use an `ActorQueue`.
- To run the operation on an actor, call `Task(on:isolatedTo:)` with that actor. The operation receives the actor, so it can use the actor's state without `await`.

## Running tasks on your actor with `ActorQueue`

An `ActorQueue` runs tasks on your own actor, and the tasks start in the order you enqueue them. Once a task starts, it behaves like any other code on the actor:

- When the task suspends at an `await`, the next task can start.
- Between [suspension points](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Defining-and-Calling-Asynchronous-Functions), the task runs without interruption from other code on the actor.
- A task can enqueue another task on the same queue and await its value. Unlike on a `FIFOQueue`, this doesn't wait forever.

Each `ActorQueue` belongs to one actor. To set one up:

1. Store the queue in a `private let` property of the actor, so that the queue can't outlive the actor. Enqueuing a task after the actor is deallocated crashes.
2. In the actor's `init`, call `queue.adoptExecutionContext(of: self)` once. This tells the queue which actor to run its tasks on. Enqueuing a task before this call crashes.

For example, here's the counter again, using an `ActorQueue`:

```swift
@Test
func actorQueueOrdering() async {
    actor Counter {
        init() {
            // Calling `adoptExecutionContext(of:)` in `init` is step 2 above.
            queue.adoptExecutionContext(of: self)
        }

        nonisolated
        func incrementAndAssertCountEquals(_ expectedCount: Int) -> Task<Void, Never> {
            Task(on: queue) { myself in
                myself.count += 1
                #expect(expectedCount == myself.count) // always succeeds
            }
        }

        private var count = 0
        // Storing the queue in a `private let` property is step 1 above.
        private let queue = ActorQueue<Counter>()
    }

    let counter = Counter()
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(counter.incrementAndAssertCountEquals(iteration))
    }
    // Wait for all enqueued tasks to finish.
    for task in tasks {
        _ = await task.value
    }
}
```

In the code above, the operation receives the actor as `myself`. The operation runs on the actor, so it reads and changes `count` without `await`.

## Running tasks on the main actor with `MainActor.queue`

`MainActor.queue` is an `ActorQueue` that runs tasks on the main actor. It's ready to use, with no setup. As with any `ActorQueue`, tasks start in the order you enqueue them, and when a task suspends at an `await`, the next task can start.

For example, here's how you might enqueue tasks on the main actor from a `nonisolated` method:

```swift
@MainActor
@Test
func mainActorQueueOrdering() async {
    @MainActor
    final class Counter {
        nonisolated
        func incrementAndAssertCountEquals(_ expectedCount: Int) -> Task<Void, Never> {
            Task(on: MainActor.queue) {
                self.increment()
                let incrementedCount = self.count
                #expect(incrementedCount == expectedCount) // always succeeds
            }
        }

        func increment() {
            count += 1
        }

        private var count = 0
    }

    let counter = Counter()
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(counter.incrementAndAssertCountEquals(iteration))
    }
    // Wait for all enqueued tasks to finish.
    for task in tasks {
        _ = await task.value
    }
}
```

In the code above, the operation runs on the main actor, so it uses `self` without `await`.

## Cancelling tasks with `CancellableQueue`

A `CancellableQueue` wraps a `FIFOQueue` or an `ActorQueue` and lets you cancel all of its tasks at once. For example, you might cancel a view's network requests when the view disappears, or cancel the work for a search when the user starts a new one.

- Calling `cancelTasks()` cancels every unfinished task that you enqueued on the `CancellableQueue`, whether it's running or waiting.
- Tasks that already finished aren't affected. Tasks you enqueue afterward run as usual.

```swift
@Test
func cancellableQueueExample() async {
    actor ImageLoader {
        init() {
            let actorQueue = ActorQueue<ImageLoader>()
            cancellableQueue = CancellableQueue(underlyingQueue: actorQueue)
            actorQueue.adoptExecutionContext(of: self)
        }

        nonisolated
        func loadImage(from url: URL) -> Task<UIImage?, any Error> {
            Task(on: cancellableQueue) { myself in
                guard let image = try await myself.fetchImage(from: url) else { return nil }
                try Task.checkCancellation()
                return await myself.processImage(image)
            }
        }

        nonisolated
        func cancelAllLoads() {
            // Cancels the image that is loading and the loads that are waiting.
            cancellableQueue.cancelTasks()
        }

        private func fetchImage(from url: URL) async throws -> UIImage? {
            // Fetch image implementation…
        }

        private func processImage(_ image: UIImage) async -> UIImage {
            // Expensive image processing implementation…
        }

        private let cancellableQueue: CancellableQueue<ActorQueue<ImageLoader>>
    }

    let loader = ImageLoader()

    // Enqueue several image load tasks.
    let task1 = loader.loadImage(from: URL(string: "https://example.com/1.png")!)
    let task2 = loader.loadImage(from: URL(string: "https://example.com/2.png")!)
    let task3 = loader.loadImage(from: URL(string: "https://example.com/3.png")!)

    // Cancel every load that hasn't finished.
    loader.cancelAllLoads()

    // All tasks are now cancelled.
    #expect(task1.isCancelled)
    #expect(task2.isCancelled)
    #expect(task3.isCancelled)
}
```

In the code above, each load calls `Task.checkCancellation()` after it fetches the image. A cancelled load throws `CancellationError` there, so it doesn't process the image. Cancelled tasks still run in order; see [Cancellation](#cancellation).

A `CancellableQueue` can also wrap a `FIFOQueue`:

```swift
let cancellableQueue = CancellableQueue(underlyingQueue: FIFOQueue())

Task(on: cancellableQueue) {
    // Calling `cancellableQueue.cancelTasks()` cancels this task.
    await performWork()
}
```

## Task-local values, priority, and cancellation

`Task(on:)` creates a new [unstructured task](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Unstructured-Concurrency), as `Task.init` does, and your operation runs in that task. So the task behaves like a task you create with `Task.init`: for example, your operation sees the [task-local values](https://developer.apple.com/documentation/swift/tasklocal) of the code that enqueues it.

### Priority

- A task runs at the priority you pass to `Task(on:)`. If you pass `nil`, it runs at the priority of the code that enqueues it, as with `Task.init`.
- `FIFOQueue(priority:)` and `ActorQueue(priority:)` give each of the queue's tasks at least that priority. A task that would run at a lower priority runs at the queue's priority instead. `MainActor.queue` has no priority of its own.
- On Linux, and on macOS 26, iOS 26, tvOS 26, watchOS 26, and visionOS 26 or later, a task waiting in a queue raises the tasks ahead of it to its own priority. On earlier releases, they keep their own priority.

### Cancellation

Cancellation is [cooperative](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Task-Cancellation), as it is for any Swift task:

- Calling a task's `cancel()` method, or calling `cancelTasks()` on the `CancellableQueue` you enqueued it on, marks the task as cancelled right away.
- The task keeps its place in the queue. Its operation still runs, in the same order as if you hadn't cancelled it.
- The operation decides how to respond. It can check `Task.isCancelled`, or call `Task.checkCancellation()` to throw a `CancellationError`.
- An operation that doesn't check for cancellation runs to completion, and the tasks behind it wait for it as usual.

## Checking whether a queue has work left

A `FIFOQueue` has an `isIdle` property, and an `ActorQueue` has a `hasStartedAllWork` property:

- A `FIFOQueue` is idle when every task you enqueued on it has finished. A task that is suspended at an `await` hasn't finished.
- An `ActorQueue` has started all of its work when every task you enqueued on it has started running on the actor. The operations of its tasks might not have finished.

Either value can change as soon as you read it: a task you enqueue afterward makes it `false` again.

For example, here's how an actor that keeps one `FIFOQueue` per document might remove the queues it no longer needs:

```swift
actor DocumentStore {
    func save(_ contents: String, as name: String) -> Task<Void, Never> {
        let queue = queues[name] ?? FIFOQueue()
        queues[name] = queue
        return Task(on: queue) {
            await self.write(contents, as: name)
        }
    }

    func removeIdleQueues() {
        queues = queues.filter { !$0.value.isIdle }
    }

    private func write(_ contents: String, as name: String) async {
        // Write implementation…
    }

    private var queues = [String: FIFOQueue]()
}
```

In the code above, the actor both enqueues the tasks and reads `isIdle`, so no task can be enqueued between the check and the removal. An actor that keeps `ActorQueue`s can remove them the same way by reading `hasStartedAllWork`.

`CancellableQueue` has neither property. To check one, keep a reference to the queue it wraps, and read that queue's property.

## Installation

To install swift-async-queue in your project with [Swift Package Manager](https://github.com/apple/swift-package-manager), the following lines can be added to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/dfed/swift-async-queue", from: "2.0.0"),
]
```

## Contributing

I’m glad you’re interested in swift-async-queue, and I’d love to see where you take it. Please read the [contributing guidelines](Contributing.md) prior to submitting a Pull Request.

Thanks, and happy queueing!

## Developing

Double-click on `Package.swift` in the root of the repository to open the project in Xcode.
