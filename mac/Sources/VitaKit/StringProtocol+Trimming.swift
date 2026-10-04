extension StringProtocol {
    /// The text without leading and trailing whitespace and newlines.
    func trimmingWhitespace() -> SubSequence {
        let start = firstIndex { !$0.isWhitespace } ?? endIndex
        let end = lastIndex { !$0.isWhitespace }.map(index(after:)) ?? start
        return self[start..<end]
    }
}
