public struct Job: Sendable, Equatable {
    public let id: String
    public let input: Int

    public init(id: String, input: Int) {
        self.id = id
        self.input = input
    }
}

public enum JobOutcome: Sendable, Equatable {
    case succeeded(Int)
    case failed
    case cancelled
}

public struct JobResult: Sendable, Equatable {
    public let id: String
    public let outcome: JobOutcome

    public init(id: String, outcome: JobOutcome) {
        self.id = id
        self.outcome = outcome
    }
}

public enum TaskProcessorError: Error, Equatable {
    case nonPositiveMaximumConcurrency
    case duplicateID(String)
}

public actor TaskProcessor {
    private let maximumConcurrency: Int

    public init(maximumConcurrency: Int) throws {
        guard maximumConcurrency > 0 else {
            throw TaskProcessorError.nonPositiveMaximumConcurrency
        }
        self.maximumConcurrency = maximumConcurrency
    }

    public func process(
        _ jobs: [Job],
        worker: @escaping @Sendable (Job) async throws -> Int
    ) async throws -> [JobResult] {
        try await processAll(jobs, using: SingleRun(worker: worker))
    }

    func processAll(_ jobs: [Job], using runner: some JobRunner) async throws -> [JobResult] {
        try Self.validateUniqueIDs(jobs)
        if jobs.isEmpty {
            return []
        }
        return await schedule(jobs, using: runner)
    }

    private func schedule(_ jobs: [Job], using runner: some JobRunner) async -> [JobResult] {
        let queue = JobQueue(count: jobs.count)
        let workerCount = min(maximumConcurrency, jobs.count)
        var outcomes = [JobOutcome?](repeating: nil, count: jobs.count)

        await withTaskGroup(of: [(Int, JobOutcome)].self) { group in
            for _ in 0..<workerCount {
                group.addTask {
                    var finished: [(Int, JobOutcome)] = []
                    while let index = await queue.next() {
                        let outcome = await runner.run(jobs[index])
                        finished.append((index, outcome))
                    }
                    return finished
                }
            }
            for await finished in group {
                for (index, outcome) in finished {
                    outcomes[index] = outcome
                }
            }
        }

        return jobs.indices.map { index in
            JobResult(id: jobs[index].id, outcome: outcomes[index] ?? .cancelled)
        }
    }

    static func validateUniqueIDs(_ jobs: [Job]) throws {
        var seen = Set<String>()
        for job in jobs {
            if !seen.insert(job.id).inserted {
                throw TaskProcessorError.duplicateID(job.id)
            }
        }
    }
}
