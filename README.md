# swift-async-queue
[![CI Status](https://img.shields.io/github/actions/workflow/status/dfed/swift-async-queue/ci.yml?branch=main)](https://github.com/dfed/swift-async-queue/actions?query=workflow%3ACI+branch%3Amain)
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-4BC51D.svg?style=flat)](https://github.com/apple/swift-package-manager)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![Version](https://img.shields.io/cocoapods/v/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)
[![License](https://img.shields.io/cocoapods/l/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)
[![Platform](https://img.shields.io/cocoapods/p/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)

A library of queues that enable sending ordered tasks from synchronous to asynchronous contexts.

## Task Ordering and Swift Concurrency

Tasks sent from a synchronous context to an asynchronous context in Swift Concurrency are inherently unordered. Consider the following test:

```swift
@MainActor
func testMainActorTaskOrdering() async {
    actor Counter {
        func incrementAndAssertCountEquals(_ expectedCount: Int) {
            count += 1
            let incrementedCount = count
            XCTAssertEqual(incrementedCount, expectedCount) // often fails
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

Despite the spawned `Task` inheriting the serial `@MainActor` execution context, the ordering of the scheduled asynchronous work is not guaranteed.

While [actors](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645) are great at serializing tasks, there is no simple way in the standard Swift library to send ordered tasks to them from a synchronous context.

### Executing asynchronous tasks in FIFO order

Use a `FIFOQueue` to execute asynchronous tasks enqueued from a nonisolated context in FIFO order. Tasks sent to one of these queues are guaranteed to begin _and end_ executing in the order in which they are enqueued. A `FIFOQueue` executes tasks in a similar manner to a `DispatchQueue`: enqueued tasks executes atomically, and the program will deadlock if a task executing on a `FIFOQueue` awaits results from the queue on which it is executing.

A `FIFOQueue` can easily execute asynchronous tasks from a nonisolated context in FIFO order:
```swift
func testFIFOQueueOrdering() async {
    actor Counter {
        nonisolated
        func incrementAndAssertCountEquals(_ expectedCount: Int) {
            queue.async {
                await self.increment()
                let incrementedCount = await self.count
                XCTAssertEqual(incrementedCount, expectedCount) // always succeeds
            }
        }

        nonisolated
        func flushQueue() async {
            await queue.await { }
        }

        func increment() {
            count += 1
        }

        var count = 0

        private let queue = FIFOQueue()
    }

    let counter = Counter()
    for iteration in 1...100 {
        counter.incrementAndAssertCountEquals(iteration)
    }
    // Wait for all enqueued tasks to finish.
    await counter.flushQueue()
}
```

FIFO execution has a key downside: the queue must wait for all previously enqueued work – including suspended work – to complete before new work can begin. If you desire new work to start when a prior task suspends, utilize an `ActorQueue`.

### Sending ordered asynchronous tasks to Actors from a nonisolated context

Use an `ActorQueue` to send ordered asynchronous tasks to an `actor`’s isolated context from nonisolated or synchronous contexts. Tasks sent to an actor queue are guaranteed to begin executing in the order in which they are enqueued. However, unlike a `FIFOQueue`, execution order is guaranteed only until the first [suspension point](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID639) within the enqueued task. An `ActorQueue` executes tasks within the its adopted actor’s isolated context, resulting in `ActorQueue` task execution having the same properties as `actor` code execution: code between suspension points is executed atomically, and tasks sent to a single `ActorQueue` can await results from the queue without deadlocking.

An instance of an `ActorQueue` is designed to be utilized by a single `actor` instance: tasks sent to an `ActorQueue` utilize the isolated context of the queue‘s adopted `actor` to serialize tasks. As such, the lifecycle of any `ActorQueue` should not exceed the lifecycle of its `actor`. It is strongly recommended that an `ActorQueue` be a `let` constant on the adopted `actor`. Additionally, an `actor` utilizing an `ActorQueue` should set the adopted execution context of the queue to `self` within the `actor`’s `init`. Failing to set an adopted execution context prior to enqueuing work on an `ActorQueue` will result in a crash.

An `ActorQueue` can easily enqueue tasks that execute on an actor’s isolated context from a nonisolated context in order:
```swift
func testActorQueueOrdering() async {
    actor Counter {
        init() {
            queue.adoptExecutionContext(of: self)
        }

        nonisolated
        func incrementAndAssertCountEquals(_ expectedCount: Int) {
            queue.async { myself in
                myself.count += 1
                XCTAssertEqual(expectedCount, myself.count) // always succeeds
            }
        }

        nonisolated
        func flushQueue() async {
            await queue.await { _ in }
        }

        private var count = 0
        private let queue = ActorQueue<Counter>()
    }

    let counter = Counter()
    for iteration in 1...100 {
        counter.incrementAndAssertCountEquals(iteration)
    }
    // Wait for all enqueued tasks to finish.
    await counter.flushQueue()
}
```

## Requirements

* Xcode 14.1 or later.
* iOS 13 or later.
* tvOS 13 or later.
* watchOS 6 or later.
* macOS 10.15 or later.
* Swift 5.7 or later.

## Installation

### Swift Package Manager

To install swift-async-queue in your iOS project with [Swift Package Manager](https://github.com/apple/swift-package-manager), the following lines can be added to your `Package.swift` file:

```swift
dependencies: [
    .package(url: "https://github.com/dfed/swift-async-queue", from: "0.1.0"),
]
```

### CocoaPods

To install swift-async-queue in your iOS project with [CocoaPods](http://cocoapods.org), add the following to your `Podfile`:

```
platform :ios, '13.0'
pod 'AsyncQueue', '~> 0.1.0'
```

## Contributing

I’m glad you’re interested in swift-async-queue, and I’d love to see where you take it. Please read the [contributing guidelines](Contributing.md) prior to submitting a Pull Request.

Thanks, and happy queueing!

## Developing

Double-click on `Package.swift` in the root of the repository to open the project in Xcode.
