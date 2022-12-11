# swift-async-queue
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-4BC51D.svg?style=flat)](https://github.com/apple/swift-package-manager)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![Version](https://img.shields.io/cocoapods/v/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)
[![License](https://img.shields.io/cocoapods/l/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)
[![Platform](https://img.shields.io/cocoapods/p/AsyncQueue.svg)](https://cocoapods.org/pods/AsyncQueue)

A library of queues that enable sending ordered tasks from synchronous to asynchronous contexts.

## Task Ordering and Swift Concurrency

Tasks sent from a synchronous context to an asynchronous context in Swift Concurrency are inherently unordered. Consider the following test:

```
@MainActor
func test_mainActor_taskOrdering() async {
    var counter = 0
    var tasks = [Task<Void, Never>]()
    for iteration in 1...100 {
        tasks.append(Task {
            counter += 1
            XCTAssertEqual(counter, iteration) // often fails
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
Task {
    await queue.await {
        /*
        `async` context that can return a value or throw an error.
        Executes after all other enqueued work is completed.
        Work enqueued after this task will wait for this task to complete.
        */
    }
}
```

### Sending ordered asynchronous tasks to Actors

Use an `ActorQueue` to send ordered asynchronous tasks from a nonisolated context to an `actor` instance's isolated `async` context. Tasks sent to one of these queues are guaranteed to begin executing in the order in which they are enqueued. Ordering of execution is guaranteed up until the first [suspension point](https://docs.swift.org/swift-book/LanguageGuide/Concurrency.html#ID639) within the called `actor` code.

```swift
let targetActor = MyActor()
let queue = ActorQueue()
queue.async(on: targetActor) { targetActor in
    /*
    `async` context that executes after all other enqueued work has begun executing.
    Work enqueued after this task will wait for this task to complete or suspend.
    This task executes on the `targetActor`'s isolated context.
    */
    try? await Task.sleep(nanoseconds: 1_000_000)
}
queue.async(on: targetActor) { targetActor in
    /*
    This task begins execution once the above task suspends due to the one-second sleep.
    This task executes on the `targetActor`'s isolated context.
    */
}
Task {
    await queue.await(on: targetActor) { targetActor in
        /*
        `async` context that can return a value or throw an error.
        Executes after all other enqueued work has begun executing.
        Work enqueued after this task will wait for this task to complete or suspend.
        This task executes on the targetActor's isolated context.
        */
    }
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
