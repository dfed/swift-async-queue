#!/usr/bin/env swift

import Foundation

// Usage: build.swift platforms

func execute(commandPath: String, arguments: [String]) throws {
    let task = Process()
    task.launchPath = commandPath
    task.arguments = arguments
    print("Launching command: \(commandPath) \(arguments.joined(separator: " "))")
    task.launch()
    task.waitUntilExit()
    guard task.terminationStatus == 0 else {
        throw TaskError.code(task.terminationStatus)
    }
}

enum TaskError: Error {
    case code(Int32)
}

enum Platform: String, CaseIterable, CustomStringConvertible {
    case iOS_13
    case iOS_14
    case iOS_15
    case iOS_16
    case tvOS_13
    case tvOS_14
    case tvOS_15
    case tvOS_16
    case macOS_10_15
    case macOS_11
    case macOS_12
    case macOS_13
    case watchOS_6
    case watchOS_7
    case watchOS_8
    case watchOS_9

    var destination: String {
        switch self {
        case .iOS_13:
            return "platform=iOS Simulator,OS=13.7,name=iPad Pro (12.9-inch) (4th generation)"
        case .iOS_14:
            return "platform=iOS Simulator,OS=14.4,name=iPad Pro (12.9-inch) (4th generation)"
        case .iOS_15:
            return "platform=iOS Simulator,OS=15.5,name=iPad Pro (12.9-inch) (5th generation)"
        case .iOS_16:
            return "platform=iOS Simulator,OS=16.4,name=iPad Pro (12.9-inch) (6th generation)"

        case .tvOS_13:
            return "platform=tvOS Simulator,OS=13.4,name=Apple TV"
        case .tvOS_14:
            return "platform=tvOS Simulator,OS=14.3,name=Apple TV"
        case .tvOS_15:
            return "platform=tvOS Simulator,OS=15.4,name=Apple TV"
        case .tvOS_16:
            return "platform=tvOS Simulator,OS=16.4,name=Apple TV"

        case .macOS_10_15,
             .macOS_11,
             .macOS_12,
             .macOS_13:
            return "platform=OS X"

        case .watchOS_6:
            return "OS=6.2.1,name=Apple Watch Series 4 - 44mm"
        case .watchOS_7:
            return "OS=7.2,name=Apple Watch Series 6 - 44mm"
        case .watchOS_8:
            return "OS=8.5,name=Apple Watch Series 6 - 44mm"
        case .watchOS_9:
            return "OS=9.4,name=Apple Watch Series 7 (45mm)"
        }
    }

    var sdk: String {
        switch self {
        case .iOS_13,
             .iOS_14,
             .iOS_15,
             .iOS_16:
            return "iphonesimulator"

        case .tvOS_13,
             .tvOS_14,
             .tvOS_15,
             .tvOS_16:
            return "appletvsimulator"

        case .macOS_10_15:
            return "macosx10.15"
        case .macOS_11:
            return "macosx11.1"
        case .macOS_12:
            return "macosx12.3"
        case .macOS_13:
            return "macosx13.3"

        case .watchOS_6,
             .watchOS_7,
             .watchOS_8,
             .watchOS_9:
            return "watchsimulator"
        }
    }

    var shouldTest: Bool {
        switch self {
        case .iOS_13,
             .iOS_14,
             .iOS_15,
             .iOS_16,
             .tvOS_13,
             .tvOS_14,
             .tvOS_15,
             .tvOS_16,
             .macOS_10_15,
             .macOS_11,
             .macOS_12,
             .macOS_13:
            return true

        case .watchOS_6,
             .watchOS_7,
             .watchOS_8,
             .watchOS_9:
            // watchOS does not support unit testing (yet?).
            return false
        }
    }

    var derivedDataPath: String {
        ".build/derivedData/" + description
    }

    var description: String {
        rawValue
    }
}

guard CommandLine.arguments.count > 1 else {
    print("Usage: build.swift platforms")
    throw TaskError.code(1)
}

let rawPlatforms = CommandLine.arguments[1].components(separatedBy: ",")

var isFirstRun = true
for rawPlatform in rawPlatforms {
    guard let platform = Platform(rawValue: rawPlatform) else {
        print("Received unknown platform type \(rawPlatform)")
        print("Possible platform types are: \(Platform.allCases)")
        throw TaskError.code(1)
    }

    var xcodeBuildArguments = [
        "-scheme", "swift-async-queue",
        "-sdk", platform.sdk,
        "-derivedDataPath", platform.derivedDataPath,
        "-PBXBuildsContinueAfterErrors=0",
        "OTHER_SWIFT_FLAGS=-warnings-as-errors",
    ]

    if !platform.destination.isEmpty {
        xcodeBuildArguments.append("-destination")
        xcodeBuildArguments.append(platform.destination)
    }
    if platform.shouldTest {
        xcodeBuildArguments.append("-enableCodeCoverage")
        xcodeBuildArguments.append("YES")
    }
    xcodeBuildArguments.append("build")
    if platform.shouldTest {
        xcodeBuildArguments.append("test")
    }
    xcodeBuildArguments.append("-test-iterations")
    xcodeBuildArguments.append("100")
    xcodeBuildArguments.append("-run-tests-until-failure")

    try execute(commandPath: "/usr/bin/xcodebuild", arguments: xcodeBuildArguments)
    isFirstRun = false
}
