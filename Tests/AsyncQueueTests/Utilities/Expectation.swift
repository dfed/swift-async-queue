// MIT License
//
// Copyright (c) 2024 Dan Federman
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

import Testing

public actor Expectation {
	// MARK: Initialization

	public init(
		expectedCount: UInt = 1
	) {
		self.init(
			expectedCount: expectedCount,
			expect: { #expect($0, $1, sourceLocation: $2) }
		)
	}

	init(
		expectedCount: UInt,
		expect: @escaping (Bool, Comment?, SourceLocation) -> Void
	) {
		self.expectedCount = expectedCount
		self.expect = expect
	}

	// MARK: Public

	public func fulfillment(
		withinSeconds seconds: UInt64,
		filePath: String = #filePath,
		fileID: String = #fileID,
		line: Int = #line,
		column: Int = #column
	) async {
		guard !isComplete else { return }
		let wait = Task {
			try await Task.sleep(nanoseconds: seconds * 1_000_000_000)
			expect(isComplete, "Expectation not fulfilled within \(seconds) seconds", .init(
				fileID: fileID,
				filePath: filePath,
				line: line,
				column: column
			))
		}
		waits.append(wait)
		try? await wait.value
	}

	@discardableResult
	nonisolated
	public func fulfill(
		filePath: String = #filePath,
		fileID: String = #fileID,
		line: Int = #line,
		column: Int = #column
	) -> Task<Void, Never> {
		Task {
			await self._fulfill(
				filePath: filePath,
				fileID: fileID,
				line: line,
				column: column
			)
		}
	}

	// MARK: Private

	private var waits = [Task<Void, Error>]()
	private var fulfillCount: UInt = 0
	private var isComplete: Bool {
		expectedCount <= fulfillCount
	}

	private let expectedCount: UInt
	private let expect: (Bool, Comment?, SourceLocation) -> Void

	private func _fulfill(
		filePath: String,
		fileID: String,
		line: Int,
		column: Int
	) {
		fulfillCount += 1
		guard isComplete else { return }
		expect(
			expectedCount == fulfillCount,
			"Expected \(expectedCount) calls to `fulfill()`. Received \(fulfillCount).",
			.init(
				fileID: fileID,
				filePath: filePath,
				line: line,
				column: column
			)
		)
		for wait in waits {
			wait.cancel()
		}
		waits = []
	}
}
