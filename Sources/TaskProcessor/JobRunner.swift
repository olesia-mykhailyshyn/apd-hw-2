protocol JobRunner: Sendable {
    func run(_ job: Job) async -> JobOutcome
}

struct SingleRun: JobRunner {
    let worker: @Sendable (Job) async throws -> Int

    func run(_ job: Job) async -> JobOutcome {
        do {
            return .succeeded(try await worker(job))
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed
        }
    }
}

struct RetryRun: JobRunner {
    let worker: @Sendable (Job, Int) async throws -> Int
    let maximumAttempts: Int

    func run(_ job: Job) async -> JobOutcome {
        for attempt in 1...maximumAttempts {
            do {
                return .succeeded(try await worker(job, attempt))
            } catch is CancellationError {
                return .cancelled
            } catch {
                if Task.isCancelled {
                    return .failed
                }
                continue
            }
        }
        return .failed
    }
}
