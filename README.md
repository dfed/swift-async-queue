# swift-async-queue
[![CI Status](https://img.shields.io/github/actions/workflow/status/dfed/swift-async-queue/ci.yml?branch=main)](https://github.com/dfed/swift-async-queue/actions?query=workflow%3ACI+branch%3Amain)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://spdx.org/licenses/MIT.html)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/dfed/swift-async-queue)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/dfed/swift-async-queue)

When you create several tasks from synchronous or `nonisolated` code, Swift doesn't guarantee the order in which they run, even if they all call the same actor. The queues in this library run tasks in the order you enqueue them.

## Choosing a queue

To enqueue a task, call `Task(on:)` with a queue instead of calling `Task.init`. The closure you pass is the task's *operation*: the code that the task runs. You can call `Task(on:)` from synchronous code. Like `Task.init`, it creates a new task and returns it, so you can wait for its value or cancel it.

- Use a `FIFOQueue` when each task must finish before the next task starts.
- Use an `ActorQueue` when tasks must start in order on your own actor. The next task can start while an earlier one is suspended.
- Use `MainActor.queue` when tasks must start in order on the main actor.
- Use a `CancellableQueue` around a `FIFOQueue` or an `ActorQueue` when you need to cancel all of its tasks at once.

## Running tasks in order

Consider the following test:

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

In the code above, the loop creates the tasks in order, but the tasks can run on the actor in a different order. When they do, the expectation fails. An [actor](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Actors) runs only one piece of code at a time, but it doesn't promise to run tasks in the order you create them. The sections below show how each queue runs tasks in the order you enqueue them.

## Running tasks one at a time with `FIFOQueue`

A `FIFOQueue` runs one task at a time, in the order you enqueue them: first in, first out. Each task waits until every task enqueued before it has finished. A task that is suspended at an `await` hasn't finished, so the next task keeps waiting. As a result, tasks start and finish in the order you enqueue them.

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

In the code above, `incrementAndAssertCountEquals(_:)` is `nonisolated`, so synchronous code can call it. The operation runs with the same actor isolation as the code that enqueues it, like a task you create with `Task.init`. Here, that code is `nonisolated`, so the operation uses `await` to call the actor.

Keep these points in mind when you use a `FIFOQueue`:

- To run the operation on an actor, call `Task(on:isolatedTo:)` with that actor. The operation receives the actor, so it can use the actor's state without `await`.
- If the next task should start while one is suspended at an `await`, use an `ActorQueue`.
- Inside a task on a `FIFOQueue`, don't await another task that you enqueue on the same queue. The new task waits for the current task to finish, and the current task waits for the new one, so both wait forever.

## Running tasks on your actor with `ActorQueue`

An `ActorQueue` runs tasks on your own actor, and the tasks start in the order you enqueue them. Once a task starts, it behaves like any other code on the actor:

- When the task suspends at an `await`, the next task can start.
- Between [suspension points](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Defining-and-Calling-Asynchronous-Functions), the task runs without interruption from other code on the actor.
- A task can enqueue another task on the same queue and await its value.

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

To wait for an operation's result, await the task's value. For example, a method of `Counter` could read the count with `let count = await Task(on: queue) { myself in myself.count }.value`.

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
- [Cancellation](#cancellation) is cooperative, so the operation should check for cancellation, as `loadImage(from:)` does below.

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

In the code above, each load calls `Task.checkCancellation()` after it fetches the image. A cancelled load throws `CancellationError` there, so it doesn't process the image.

A `CancellableQueue` can also wrap a `FIFOQueue`:

```swift
let cancellableQueue = CancellableQueue(underlyingQueue: FIFOQueue())

Task(on: cancellableQueue) {
    // Calling `cancellableQueue.cancelTasks()` cancels this task.
    await performWork()
}
```

## Task-local values, priority, and cancellation

`Task(on:)` creates a new [unstructured task](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Unstructured-Concurrency), as `Task.init` does, and your operation runs in that task. So the task behaves like a task you create with `Task.init`.

### Task-local values

Your operation sees the [task-local values](https://developer.apple.com/documentation/swift/tasklocal) of the code that enqueues it, as with `Task.init`.

### Priority

- A task runs at the priority you pass to `Task(on:)`. If you pass `nil`, it runs at the priority of the code that enqueues it, as with `Task.init`.
- `FIFOQueue(priority:)` gives each of the queue's tasks at least that priority. A task that would run at a lower priority runs at the queue's priority instead.
- When a higher-priority task awaits a task's value, Swift raises, or *escalates*, that task's priority, as it does for any task.

### Cancellation

Cancellation is [cooperative](https://docs.swift.org/swift-book/documentation/the-swift-programming-language/concurrency/#Task-Cancellation), as it is for any Swift task:

- Calling a task's `cancel()` method, or calling `cancelTasks()` on the `CancellableQueue` you enqueued it on, marks the task as cancelled right away.
- The task keeps its place in the queue. Its operation still runs, in the same order as if you hadn't cancelled it.
- The operation decides how to respond. It can check `Task.isCancelled`, or call `Task.checkCancellation()` to throw a `CancellationError`.
- An operation that doesn't check for cancellation runs to completion, and the tasks behind it wait for it as usual.

## Migrating from 1.x

- **Swift and platform versions.** Version 2.0 requires Swift 6.4 and newer platform versions; see [Installation](#installation). Update your toolchain and deployment targets.
- **Priority.** An operation you enqueue without a priority now runs at the priority of the code that enqueues it. In 1.x, a `FIFOQueue` created without a priority ran it at `.medium`, and an `ActorQueue` ran it at the priority of the code that created the queue.
  - On a `FIFOQueue`, a task enqueued from low-priority code now runs at low priority, and the tasks behind it wait for it. To keep the 1.x priority, create the queue with `FIFOQueue(priority: .medium)`.
  - On an `ActorQueue`, pass `priority:` to `Task(on:)` when you enqueue important work from low-priority code.
- **Task-local values.** An operation now sees the task-local values of the code that enqueues it. In 1.x, an operation on an `ActorQueue` saw the values of the code that created the queue, and an operation on a `FIFOQueue` saw none. You need to change your code only if an operation relied on the 1.x values.
- **Queue names.** `FIFOQueue(name:priority:)` and `ActorQueue(name:)` are removed, because operations now run in the task that `Task(on:)` returns. Use `FIFOQueue(priority:)` and `ActorQueue()`, and pass `name:` to `Task(on:)` to name each task instead.

## Installation

swift-async-queue requires Swift 6.4, and macOS 15, iOS 18, tvOS 18, watchOS 11, Mac Catalyst 18, or visionOS 2 or later. It also runs on Linux.

To install swift-async-queue in your project with [Swift Package Manager](https://github.com/apple/swift-package-manager), add the following lines to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/dfed/swift-async-queue", from: "2.0.0"),
]
```

Then add `AsyncQueue` to your target's dependencies, and write `import AsyncQueue` in each file that uses a queue.

## Contributing

I’m glad you’re interested in swift-async-queue, and I’d love to see where you take it. Please read the [contributing guidelines](Contributing.md) prior to submitting a Pull Request.

Thanks, and happy queueing!

## Developing

Double-click on `Package.swift` in the root of the repository to open the project in Xcode.
