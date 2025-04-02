// MIT License
//
// Copyright (c) 2025 Dan Federman
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

actor Delivery<Success: Sendable, Failure: Error> {
    func sendValue(_ value: Success) {
        self.value = value
    }

    func sendFailure(_ failure: Failure) {
        self.failure = failure
    }

    private var value: Success? {
        didSet {
            if let value {
                valueContinuations.forEach { $0.resume(returning: value) }
                valueContinuations.removeAll()
            }
        }
    }

    private var failure: Failure? {
        didSet {
            if let failure {
                valueContinuations.forEach { $0.resume(throwing: failure) }
                valueContinuations.removeAll()
            }
        }
    }

    private var valueContinuations: [UnsafeContinuation<Success, Failure>] = []
}

extension Delivery where Failure == Never {
    func getValue() async -> Success {
        if let value {
            value
        } else {
            await withUnsafeContinuation { continuation in
                valueContinuations.append(continuation)
            }
        }
    }
}

extension Delivery where Failure == any Error {
    func getValue() async throws -> Success {
        if let value {
            value
        } else if let failure {
            throw failure
        } else {
            try await withUnsafeThrowingContinuation { continuation in
                valueContinuations.append(continuation)
            }
        }
    }
}
