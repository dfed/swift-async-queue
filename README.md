# swift-async-queue
[![CI Status](https://img.shields.io/github/actions/workflow/status/dfed/swift-async-queue/ci.yml?branch=main)](https://github.com/dfed/swift-async-queue/actions?query=workflow%3ACI+branch%3Amain)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](https://spdx.org/licenses/MIT.html)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dswift-versions)](https://swiftpackageindex.com/dfed/swift-async-queue)
[![](https://img.shields.io/endpoint?url=https%3A%2F%2Fswiftpackageindex.com%2Fapi%2Fpackages%2Fdfed%2Fswift-async-queue%2Fbadge%3Ftype%3Dplatforms)](https://swiftpackageindex.com/dfed/swift-async-queue)

A library of queues that enable sending ordered tasks from nonisolated to asynchronous contexts.

## Task Ordering and Swift Concurrency

Tasks sent from a nonisolated context to an asynchronous context in Swift Concurrency are inherently unordered. Consider the following test:

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

Because the `Task` is spawned from a nonisolated execution context, the ordering of the scheduled asynchronous work is not guaranteed.

While [actors](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645) are great at serializing tasks, there is no simple way in the standard Swift library to send ordered tasks to them from a nonisolated synchronous context, or from multiple execution contexts.

### Executing asynchronous tasks in FIFO order

Use a `FIFOQueue` to execute asynchronous tasks enqueued from a nonisolated context in FIFO order. Tasks sent to one of these queues are guaranteed to begin _and end_ executing in the order in which they are enqueued. A `FIFOQueue` executes tasks in a similar manner to a `DispatchQueue`: enqueued tasks executes atomically, and the program will deadlock if a task executing on a `FIFOQueue` awaits results from the queue on which it is executing.

A `FIFOQueue` can easily execute asynchronous tasks from a nonisolated context in FIFO order:
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

FIFO execution has a key downside: the queue must wait for all previously enqueued work – including suspended work – to complete before new work can begin. If you desire new work to start when a prior task suspends, utilize an `ActorQueue`.

### Sending ordered asynchronous tasks to Actors from a nonisolated context

Use an `ActorQueue` to send ordered asynchronous tasks to an `actor`’s isolated context from nonisolated or synchronous contexts. Tasks sent to an actor queue are guaranteed to begin executing in the order in which they are enqueued. However, unlike a `FIFOQueue`, execution order is guaranteed only until the first [suspension point](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID639) within the enqueued task. An `ActorQueue` executes tasks within the its adopted actor’s isolated context, resulting in `ActorQueue` task execution having the same properties as `actor` code execution: code between suspension points is executed atomically, and tasks sent to a single `ActorQueue` can await results from the queue without deadlocking.

An instance of an `ActorQueue` is designed to be utilized by a single `actor` instance: tasks sent to an `ActorQueue` utilize the isolated context of the queue‘s adopted `actor` to serialize tasks. As such, there are a couple requirements that must be met when dealing with an `ActorQueue`:
1. The lifecycle of any `ActorQueue` should not exceed the lifecycle of its `actor`. It is strongly recommended that an `ActorQueue` be a `private let` constant on the adopted `actor`. Enqueuing a task to an `ActorQueue` instance after its adopted `actor` has been deallocated will result in a crash.
2. An `actor` utilizing an `ActorQueue` should set the adopted execution context of the queue to `self` within the `actor`’s `init`. Failing to set an adopted execution context prior to enqueuing work on an `ActorQueue` will result in a crash.

An `ActorQueue` can easily enqueue tasks that execute on an actor’s isolated context from a nonisolated context in order:
```swift
@Test
func actorQueueOrdering() async {
    actor Counter {
        init() {
            // Adopting the execution context in `init` satisfies requirement #2 above.
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
        // Making the queue a private let constant satisfies requirement #1 above.
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

### Sending ordered asynchronous tasks to the `@MainActor` from a nonisolated context

Use `MainActor.queue` to send ordered asynchronous tasks to the `@MainActor`’s isolated context from nonisolated or synchronous contexts. Tasks sent to this queue type are guaranteed to begin executing in the order in which they are enqueued. The `MainActor.queue` is an `ActorQueue` that runs within the `@MainActor` global context: execution order is guaranteed only until the first [suspension point](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID639) within the enqueued task. Similarly, code between suspension points is executed atomically, and tasks sent to the `MainActor.queue` can await results from the queue without deadlocking.

A `MainActor.queue` can easily execute asynchronous tasks from a nonisolated context in FIFO order:
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

## Installation

### Swift Package Manager

To install swift-async-queue in your project with [Swift Package Manager](https://github.com/apple/swift-package-manager), the following lines can be added to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/dfed/swift-async-queue", from: "0.7.0"),
]
```

### CocoaPods

To install swift-async-queue in your project with [CocoaPods](https://blog.cocoapods.org/CocoaPods-Specs-Repo), add the following to your `Podfile`:

```
pod 'AsyncQueue', '~> 0.7.0'
```

## Contributing

I’m glad you’re interested in swift-async-queue, and I’d love to see where you take it. Please read the [contributing guidelines](Contributing.md) prior to submitting a Pull Request.

Thanks, and happy queueing!

## Developing

Double-click on `Package.swift` in the root of the repository to open the project in Xcode.
