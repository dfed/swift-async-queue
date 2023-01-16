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
        func increment() -> Int {
            count += 1
            return count
        }
        var count = 0
    }

    let counter = Counter()
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(Task {
            let incrementedCount = await counter.increment()
            XCTAssertEqual(incrementedCount, iteration) // often fails
        })
    }
    for task in tasks {
        _ = await task.value
    }
}
```

Despite the spawned `Task` inheriting the serial `@MainActor` execution context, the ordering of the scheduled asynchronous work is not guaranteed.

While [actors](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID645) are great at serializing tasks, there is no simple way in the standard Swift library to send ordered tasks to them from a synchronous context.

### Executing asynchronous tasks in FIFO order

Use a `FIFOQueue` to execute asynchronous tasks enqueued from a nonisolated context in FIFO order. Tasks sent to one of these queues are guaranteed to begin _and end_ executing in the order in which they are enqueued.

```swift
let queue = FIFOQueue()
queue.async {
    /*
    `async` context that executes after all other enqueued work is completed.
    Work enqueued after this task will wait for this task to complete.
    */
    try? await Task.sleep(nanoseconds: 1_000_000)
}
queue.async {
    /*
    This task begins execution once the above one-second sleep completes.
    */
}
await queue.await {
    /*
    `async` context that can return a value or throw an error.
    Executes after all other enqueued work is completed.
    Work enqueued after this task will wait for this task to complete.
    */
}
```

With a `FIFOQueue` you can easily execute asynchronous tasks from a nonisolated context in FIFO order:
```swift
func testFIFOQueueOrdering() async {
    actor Counter {
        func increment() -> Int {
            count += 1
            return count
        }
        var count = 0
    }

    let counter = Counter()
    let queue = FIFOQueue()
    for iteration in 1...100 {
        queue.async {
            let incrementedCount = await counter.increment()
            XCTAssertEqual(incrementedCount, iteration) // always succeeds
        }
    }
    await queue.await { }
}
```

### Sending ordered asynchronous tasks to Actors from a nonisolated context

Use an `ActorQueue` to send ordered asynchronous tasks to an `actor`'s isolated context from a nonisolated and synchronous context. Tasks sent to an actor queue are guaranteed to begin executing in the order in which they are enqueued. Ordering of execution is guaranteed up until the first [suspension point](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID639) within the enqueued task.

```swift
let queue = ActorQueue()
queue.setTargetContext(to: actor)
queue.async { actor in
    /*
    `async` context that executes after all other enqueued work has begun executing.
    Work enqueued after this task will wait for this task to complete or suspend.
    */
    await actor.longRunningTask()
}
queue.async { actor in
    /*
    This task begins execution once the above task suspends due to the long-running task.
    */
}
await queue.await { actor in
    /*
    `async` context that can return a value or throw an error.
    Executes after all other enqueued work has begun executing.
    Work enqueued after this task will wait for this task to complete or suspend.
    */
}

With an `ActorQueue` you can easily begin execution of asynchronous tasks from a nonisolated context in order:
```swift
func testActorQueueOrdering() async {
    actor Counter {
        init() {
            queue.setTargetContext(to: self)
        }

        nonisolated
        func increment(expectedCount: Int) {
            queue.async { myself in
                myself.count += 1
                XCTAssertEqual(expectedCount, myself.count) // always succeeds
            }
        }
        var count = 0

        nonisolated
        func flushQueue() async {
            await queue.await { _ in }
        }

        private let queue = ActorQueue<Counter>()
    }

    let counter = Counter()
    for iteration in 1...100 {
        counter.increment(expectedCount: iteration)
    }
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
