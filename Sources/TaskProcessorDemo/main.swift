import TaskProcessor

actor Tracker {
    private let limit: Int
    private var running = 0

    init(limit: Int) {
        self.limit = limit
    }

    func start(_ id: String, _ note: String = "") {
        running += 1
        print("  ▶ start \(id)\(note)   running \(running)/\(limit)")
    }

    func end(_ id: String, _ what: String) {
        running -= 1
        print("  ■ end   \(id) → \(what)   running \(running)/\(limit)")
    }
}

func pause(milliseconds: Int) async throws {
    try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000)
}

func describe(_ outcome: JobOutcome) -> String {
    switch outcome {
    case .succeeded(let value): "succeeded(\(value))"
    case .failed: "failed"
    case .cancelled: "cancelled"
    }
}

func printReport(_ results: [JobResult]) {
    print("  Report (input order):")
    for result in results {
        print("    \(result.id): \(describe(result.outcome))")
    }
}

func header(_ title: String, _ rule: String) {
    print("\n=== \(title) ===")
    print("  Rule: \(rule)")
}

func limitAndOrder() async throws {
    header("1. Limit and order", "at most 2 at once; report in input order")
    let tracker = Tracker(limit: 2)
    let processor = try TaskProcessor(maximumConcurrency: 2)
    let durations = [("a", 300), ("b", 100), ("c", 200), ("d", 50), ("e", 150)]
    let jobs = durations.map { Job(id: $0.0, input: $0.1) }

    let results = try await processor.process(jobs) { job in
        await tracker.start(job.id)
        try await pause(milliseconds: job.input)
        await tracker.end(job.id, "done after \(job.input) ms")
        return job.input
    }
    printReport(results)
}

func errors() async throws {
    header("2. Errors", "one bad job does not stop the others")
    struct BrokenPhoto: Error {}
    let tracker = Tracker(limit: 2)
    let processor = try TaskProcessor(maximumConcurrency: 2)
    let jobs = ["ok-1", "broken", "gives-up", "ok-2"].map { Job(id: $0, input: 1) }

    let results = try await processor.process(jobs) { job in
        await tracker.start(job.id)
        try await pause(milliseconds: 100)
        switch job.id {
        case "broken":
            await tracker.end(job.id, "throws an error")
            throw BrokenPhoto()
        case "gives-up":
            await tracker.end(job.id, "throws CancellationError")
            throw CancellationError()
        default:
            await tracker.end(job.id, "done")
            return job.input
        }
    }
    printReport(results)
}

func cancellation() async throws {
    header("3. Cancel", "nothing new starts; finished work is kept")
    let tracker = Tracker(limit: 1)
    let processor = try TaskProcessor(maximumConcurrency: 1)
    let jobs = ["a", "b", "c", "d"].map { Job(id: $0, input: 1) }

    let run = Task {
        try await processor.process(jobs) { job in
            await tracker.start(job.id)
            do {
                try await pause(milliseconds: 300)
            } catch {
                await tracker.end(job.id, "stopped by cancel")
                throw error
            }
            await tracker.end(job.id, "done")
            return job.input
        }
    }

    try await pause(milliseconds: 450)
    print("  ✋ user presses Cancel")
    run.cancel()
    printReport(try await run.value)
}

func retry() async throws {
    header("4. Retry (bonus)", "up to 3 attempts; ordinary errors are retried")
    struct NetworkGlitch: Error {}
    let tracker = Tracker(limit: 2)
    let processor = try TaskProcessor(maximumConcurrency: 2)
    let policy = try RetryPolicy(maximumAttempts: 3)
    let jobs = ["flaky", "broken", "fine"].map { Job(id: $0, input: 1) }

    let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
        await tracker.start(job.id, " (attempt \(attempt))")
        try await pause(milliseconds: 100)
        let fails = job.id == "broken" || (job.id == "flaky" && attempt < 2)
        await tracker.end(job.id, fails ? "error, attempt \(attempt)" : "done on attempt \(attempt)")
        if fails { throw NetworkGlitch() }
        return attempt
    }
    printReport(results)
}

func badInput() async throws {
    header("5. Bad input", "rejected before any work starts")
    do {
        _ = try TaskProcessor(maximumConcurrency: 0)
    } catch {
        print("  limit 0 → \(error)")
    }
    let processor = try TaskProcessor(maximumConcurrency: 2)
    let jobs = ["a", "b", "a"].map { Job(id: $0, input: 1) }
    do {
        _ = try await processor.process(jobs) { _ in
            print("  (this line must never print)")
            return 0
        }
    } catch {
        print("  ids [a, b, a] → \(error)")
    }
}

try await limitAndOrder()
try await errors()
try await cancellation()
try await retry()
try await badInput()
print("\nDone.")
