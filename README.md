# swift-async-queue
[![Swift Package Manager compatible](https://img.shields.io/badge/SPM-compatible-4BC51D.svg?style=flat)](https://github.com/apple/swift-package-manager)
[![codecov](https://codecov.io/gh/dfed/swift-async-queue/branch/main/graph/badge.svg?token=nZBHcZZ63F)](https://codecov.io/gh/dfed/swift-async-queue)
[![Version](https://img.shields.io/cocoapods/v/swift-async-queue.svg)](https://cocoapods.org/pods/swift-async-queue)
[![License](https://img.shields.io/cocoapods/l/swift-async-queue.svg)](https://cocoapods.org/pods/swift-async-queue)
[![Platform](https://img.shields.io/cocoapods/p/swift-async-queue.svg)](https://cocoapods.org/pods/swift-async-queue)

A queue that enables sending FIFO-ordered tasks from synchronous to asynchronous contexts.

## Usage

### Basic Initialization

```swift
let asyncQueue = AsyncQueue()
```

### Sending events from a synchronous context

```swift
asyncQueue.async { /* awaitable context that executes after all other enqueued work is completed */ }
```

### Awaiting work from an asynchronous context

```swift
await asyncQueue.await { /* throw-able, return-able, awaitable context that executes after all other enqueued work is completed */ }
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
    .package(url: "https://github.com/dfed/swift-async-queue", from: "0.0.1"),
]
```

### CocoaPods

To install swift-async-queue in your iOS project with [CocoaPods](http://cocoapods.org), add the following to your `Podfile`:

```
platform :ios, '13.0'
pod 'AsyncQueue', '~> 0.1'
```

## Contributing

I’m glad you’re interested in swift-async-queue, and I’d love to see where you take it. Please read the [contributing guidelines](Contributing.md) prior to submitting a Pull Request.

Thanks, and happy queueing!

## Developing

Double-click on `Package.swift` in the root of the repository to open the project in Xcode.
