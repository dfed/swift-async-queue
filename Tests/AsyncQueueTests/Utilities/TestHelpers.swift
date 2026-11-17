// MIT License
//
// Copyright (c) 2026 Dan Federman
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

/// Suspends the calling task until it is cancelled.
///
/// Returns once the calling task is cancelled. If the task is never cancelled, this function suspends forever, so a
/// regression that keeps cancellation from reaching the task hangs the test until the CI job times out.
func suspendUntilCancelled() async {
	// Nothing yields to or finishes this stream, and its continuation stays alive until this function returns, so only
	// cancelling the calling task ends the wait for the stream's next element.
	let (untilCancelled, untilCancelledContinuation) = AsyncStream<Void>.makeStream()
	var untilCancelledIterator = untilCancelled.makeAsyncIterator()
	await untilCancelledIterator.next()
	withExtendedLifetime(untilCancelledContinuation) {}
}
