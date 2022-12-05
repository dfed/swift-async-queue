// MIT License
//
// Copyright (c) 2022 Dan Federman
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

/// A thread-safe semaphore implementation.
actor Semaphore {
    /// Decrement the counting semaphore. If the resulting value is less than zero, this function waits for a signal to occur before returning.
    /// - Returns: Whether the call triggered a suspension
    @discardableResult
    func wait() async -> Bool {
        count -= 1
        guard count < 0 else {
            // We don't need to wait because count is greater than or equal to zero.
            return false
        }

        await withUnsafeContinuation { continuation in
            continuations.append(continuation)
        }
        return true
    }

    /// Increment the counting semaphore. If the previous value was less than zero, this function resumes a waiting thread before returning.
    func signal() {
        count += 1
        guard !isWaiting else {
            // Continue waiting.
            return
        }

        for continuation in continuations {
            continuation.resume()
        }

        continuations.removeAll()
    }

    var isWaiting: Bool {
        count < 0
    }

    private var continuations = [UnsafeContinuation<Void, Never>]()
    private var count = 0
}
