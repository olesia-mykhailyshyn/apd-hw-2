actor JobQueue {
    private let count: Int
    private var nextIndex = 0

    init(count: Int) {
        self.count = count
    }

    func next() -> Int? {
        guard !Task.isCancelled, nextIndex < count else {
            return nil
        }
        defer { nextIndex += 1 }
        return nextIndex
    }
}
