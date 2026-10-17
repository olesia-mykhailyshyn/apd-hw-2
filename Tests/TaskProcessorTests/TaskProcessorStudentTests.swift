import XCTest
@testable import TaskProcessor

// MARK: - Helpers

private struct WorkerFailure: Error {}

/// Counts worker calls. It is an actor, so many workers can call it at the
/// same time without a data race.
private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

/// Records every attempt number a worker was called with, per job.
private actor AttemptLog {
    private(set) var attempts: [String: [Int]] = [:]

    func record(_ id: String, _ attempt: Int) {
        attempts[id, default: []].append(attempt)
    }
}

/// Plays "the outside world" for the processor in tests. It records which
/// jobs started and finished, counts how many run at the same time, and keeps
/// each job waiting until the test releases it. No sleeps: the test decides
/// the order of events.
private actor Probe {
    private(set) var startOrder: [String] = []
    private(set) var finishOrder: [String] = []
    private(set) var maxActive = 0
    private var active = 0

    private var preReleased: Set<String> = []
    private var waiting: [String: CheckedContinuation<Void, Never>] = [:]
    private var startWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var finishWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    /// Called by the worker: record the start, wait to be released, record the finish.
    func runJob(_ id: String) async {
        startOrder.append(id)
        active += 1
        maxActive = max(maxActive, active)
        Self.resume(&startWaiters, reached: startOrder.count)

        if preReleased.remove(id) == nil {
            await withCheckedContinuation { waiting[id] = $0 }
        }

        active -= 1
        finishOrder.append(id)
        Self.resume(&finishWaiters, reached: finishOrder.count)
    }

    /// Lets job `id` finish (now, or as soon as it starts).
    func release(_ id: String) {
        if let continuation = waiting.removeValue(forKey: id) {
            continuation.resume()
        } else {
            preReleased.insert(id)
        }
    }

    func releaseAll(_ ids: [String]) {
        ids.forEach { release($0) }
    }

    /// Test waits until at least `count` jobs have started.
    func waitForStarts(_ count: Int) async {
        guard startOrder.count < count else { return }
        await withCheckedContinuation { startWaiters.append((count, $0)) }
    }

    /// Test waits until at least `count` jobs have finished.
    func waitForFinishes(_ count: Int) async {
        guard finishOrder.count < count else { return }
        await withCheckedContinuation { finishWaiters.append((count, $0)) }
    }

    private static func resume(
        _ waiters: inout [(count: Int, continuation: CheckedContinuation<Void, Never>)],
        reached: Int
    ) {
        let ready = waiters.filter { $0.count <= reached }
        waiters.removeAll { $0.count <= reached }
        ready.forEach { $0.continuation.resume() }
    }
}

@MainActor
final class TaskProcessorStudentTests: XCTestCase {

    // MARK: - Validation (BR-1, BR-2)

    /// AC-1: a negative limit is as invalid as zero — nothing could ever run.
    func testNegativeLimitIsRejected() {
        for limit in [-1, -100] {
            XCTAssertThrowsError(try TaskProcessor(maximumConcurrency: limit)) { error in
                XCTAssertEqual(error as? TaskProcessorError, .nonPositiveMaximumConcurrency)
            }
        }
    }

    /// AC-2: a batch with duplicate IDs is rejected as a whole, before any work starts.
    func testDuplicateIDsRejectBatchBeforeAnyWorkerRuns() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let counter = CallCounter()
        let jobs = ["a", "b", "a", "b"].map { Job(id: $0, input: 0) }

        do {
            _ = try await processor.process(jobs) { _ in
                await counter.increment()
                return 0
            }
            XCTFail("Expected a duplicateID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("a"))
        }

        let calls = await counter.count
        XCTAssertEqual(calls, 0, "No worker may run when the input is invalid")
    }

    /// AC-3: the reported ID is the first job whose ID was already seen,
    /// not simply the first value that has a duplicate somewhere.
    func testReportedDuplicateIsFirstRepeatInInputOrder() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = ["a", "b", "b", "a"].map { Job(id: $0, input: 0) }

        do {
            _ = try await processor.process(jobs) { _ in 0 }
            XCTFail("Expected a duplicateID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("b"))
        }
    }

    // MARK: - Scheduling and order (BR-3, BR-4, BR-5)

    /// AC-5: with limit 2, only the first two jobs start, and never more than two run at once.
    func testNoMoreThanLimitJobsRunAtOnce() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = Probe()
        let ids = ["a", "b", "c", "d", "e"]
        let jobs = ids.enumerated().map { Job(id: $1, input: $0) }

        let run = Task {
            try await processor.process(jobs) { job in
                await probe.runJob(job.id)
                return job.input
            }
        }

        await probe.waitForStarts(2)
        let firstStarted = await probe.startOrder
        XCTAssertEqual(Set(firstStarted), ["a", "b"], "Only the first two jobs may start")

        await probe.releaseAll(ids)
        let results = try await run.value
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 2, "Exactly the limit may run at once — no more, no less")
        XCTAssertEqual(results, ids.enumerated().map { JobResult(id: $1, outcome: .succeeded($0)) })
    }

    /// AC-6: when a job finishes, its slot goes to the next waiting job from the left.
    func testFreedSlotGoesToNextJobFromTheLeft() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = Probe()
        let ids = ["a", "b", "c", "d", "e"]
        let jobs = ids.map { Job(id: $0, input: 0) }

        let run = Task {
            try await processor.process(jobs) { job in
                await probe.runJob(job.id)
                return 0
            }
        }

        await probe.waitForStarts(2)
        await probe.release("a")
        await probe.waitForStarts(3)
        let started = await probe.startOrder
        XCTAssertEqual(started.count, 3, "Only one slot was freed, so only one new job may start")
        XCTAssertEqual(started.last, "c", "The freed slot must take the next job from the left")

        await probe.releaseAll(ids)
        _ = try await run.value
    }

    /// AC-7: the report follows input order even when jobs finish in reverse.
    func testReportFollowsInputOrderWhenJobsFinishInReverse() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let probe = Probe()
        let jobs = [Job(id: "a", input: 1), Job(id: "b", input: 2), Job(id: "c", input: 3)]

        let run = Task {
            try await processor.process(jobs) { job in
                await probe.runJob(job.id)
                return job.input * 100
            }
        }

        await probe.waitForStarts(3)
        await probe.release("c")
        await probe.waitForFinishes(1)
        await probe.release("b")
        await probe.waitForFinishes(2)
        await probe.release("a")

        let results = try await run.value
        let finishOrder = await probe.finishOrder
        XCTAssertEqual(finishOrder, ["c", "b", "a"], "Precondition: jobs really finished in reverse")
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(100)),
            JobResult(id: "b", outcome: .succeeded(200)),
            JobResult(id: "c", outcome: .succeeded(300))
        ])
    }

    // MARK: - Outcomes (BR-6, BR-7)

    /// AC-9: one broken job is reported as failed; the other jobs still succeed.
    func testOneFailingJobDoesNotStopTheOthers() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let jobs = ["a", "b", "c", "d"].enumerated().map { Job(id: $1, input: $0) }

        let results = try await processor.process(jobs) { job in
            if job.id == "b" { throw WorkerFailure() }
            return job.input
        }

        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(0)),
            JobResult(id: "b", outcome: .failed),
            JobResult(id: "c", outcome: .succeeded(2)),
            JobResult(id: "d", outcome: .succeeded(3))
        ])
    }

    /// AC-10: a worker may give up on its own (CancellationError) without the run
    /// being cancelled — that job is cancelled, the rest continue normally.
    func testWorkerGivingUpIsCancelledButTheRunContinues() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let jobs = ["a", "b", "c"].enumerated().map { Job(id: $1, input: $0) }

        let results = try await processor.process(jobs) { job in
            if job.id == "a" { throw CancellationError() }
            return job.input
        }

        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .cancelled),
            JobResult(id: "b", outcome: .succeeded(1)),
            JobResult(id: "c", outcome: .succeeded(2))
        ])
    }

    // MARK: - Caller cancellation (BR-8)

    /// AC-11: the user cancels while a job is running. Finished work is kept,
    /// the running job stops (its worker cooperates), and nothing new starts.
    func testCancelKeepsFinishedWorkStopsRunningJobAndStartsNothingNew() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = Probe()
        let jobs = ["a", "b", "c"].enumerated().map { Job(id: $1, input: $0) }

        let run = Task {
            try await processor.process(jobs) { job in
                await probe.runJob(job.id)
                try Task.checkCancellation()
                return job.input
            }
        }

        await probe.release("a")
        await probe.waitForStarts(2)      // a finished, b is now running
        run.cancel()                      // the user presses "Cancel"
        await probe.release("b")          // b wakes up, sees the cancel, stops

        let results = try await run.value
        let started = await probe.startOrder
        XCTAssertEqual(started, ["a", "b"], "No job may start after cancellation")
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(0)),
            JobResult(id: "b", outcome: .cancelled),
            JobResult(id: "c", outcome: .cancelled)
        ])
    }

    /// AC-12: a run that is already cancelled when it begins starts no work,
    /// but still returns a full report in input order.
    func testRunCancelledBeforeStartRunsNothingButReportsEveryJob() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let counter = CallCounter()
        let jobs = ["a", "b", "c"].map { Job(id: $0, input: 0) }

        let run = Task {
            withUnsafeCurrentTask { $0?.cancel() }   // cancel this task before calling process
            return try await processor.process(jobs) { _ in
                await counter.increment()
                return 0
            }
        }

        let results = try await run.value
        let calls = await counter.count
        XCTAssertEqual(calls, 0, "No worker may run in an already cancelled run")
        XCTAssertEqual(results, jobs.map { JobResult(id: $0.id, outcome: .cancelled) })
    }

    /// S5 (PLAN, outcome mapping): a worker that ignores cancellation and still
    /// returns a value keeps its success — finished work is never thrown away.
    /// Jobs that never started are still cancelled.
    func testWorkerThatIgnoresCancelKeepsItsResult() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = Probe()
        let jobs = ["a", "b", "c"].enumerated().map { Job(id: $1, input: $0) }

        let run = Task {
            try await processor.process(jobs) { job in
                await probe.runJob(job.id)      // does not check for cancellation
                return job.input
            }
        }

        await probe.waitForStarts(2)          // a and b running, c waiting
        run.cancel()
        await probe.releaseAll(["a", "b"])

        let results = try await run.value
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .succeeded(0)),
            JobResult(id: "b", outcome: .succeeded(1)),
            JobResult(id: "c", outcome: .cancelled)
        ])
    }

    // MARK: - Bonus: retry (BR-9, BR-10)

    /// AC-B1: a retry policy needs at least one attempt.
    func testRetryPolicyNeedsAtLeastOneAttempt() {
        for attempts in [0, -1] {
            XCTAssertThrowsError(try RetryPolicy(maximumAttempts: attempts)) { error in
                XCTAssertEqual(error as? RetryPolicyError, .nonPositiveMaximumAttempts)
            }
        }
        XCTAssertNoThrow(try RetryPolicy(maximumAttempts: 1))
    }

    /// AC-B2: a temporary problem passes — the job succeeds on a later attempt
    /// and no extra attempts are made after the success.
    func testTemporaryFailureRecoversBeforeTheLimit() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 4)

        let results = try await processor.process([Job(id: "a", input: 5)], retryPolicy: policy) { job, attempt in
            await log.record(job.id, attempt)
            if attempt < 3 { throw WorkerFailure() }
            return job.input
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .succeeded(5))])
        let attempts = await log.attempts["a"]
        XCTAssertEqual(attempts, [1, 2, 3], "Attempts start at 1 and stop at the first success")
    }

    /// AC-B3: a permanent problem — the job is tried exactly maximumAttempts times, then failed.
    func testPermanentFailureStopsAfterExactlyMaxAttempts() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)

        let results = try await processor.process([Job(id: "a", input: 0)], retryPolicy: policy) { job, attempt in
            await log.record(job.id, attempt)
            throw WorkerFailure()
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .failed)])
        let attempts = await log.attempts["a"]
        XCTAssertEqual(attempts, [1, 2, 3])
    }

    /// AC-B4: cancellation means stop — a cancelled attempt is never retried.
    func testCancelledAttemptIsNeverRetried() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)

        let results = try await processor.process([Job(id: "a", input: 0)], retryPolicy: policy) { job, attempt in
            await log.record(job.id, attempt)
            throw CancellationError()
        }

        XCTAssertEqual(results, [JobResult(id: "a", outcome: .cancelled)])
        let attempts = await log.attempts["a"]
        XCTAssertEqual(attempts, [1])
    }

    /// AC-B5: retries stay inside their job's slot — they never let an extra job run.
    func testRetriesStayInsideTheirSlot() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let probe = Probe()
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let ids = ["a", "b", "c", "d"]
        let jobs = ids.enumerated().map { Job(id: $1, input: $0) }

        let run = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await log.record(job.id, attempt)
                if attempt < 3 { throw WorkerFailure() }
                await probe.runJob(job.id)          // third attempt waits at the gate
                return job.input
            }
        }

        await probe.waitForStarts(2)               // a and b are on attempt 3, holding both slots
        let started = await probe.startOrder
        let attemptsOfC = await log.attempts["c"]
        XCTAssertEqual(Set(started), ["a", "b"])
        XCTAssertNil(attemptsOfC, "c must not start while a and b are still retrying")

        await probe.releaseAll(ids)
        let results = try await run.value
        let maxActive = await probe.maxActive
        XCTAssertEqual(maxActive, 2)
        XCTAssertEqual(results, ids.enumerated().map { JobResult(id: $1, outcome: .succeeded($0)) })
    }

    /// AC-B6: with different numbers of retries per job, the report keeps input order.
    func testRetryReportKeepsInputOrderWithMixedOutcomes() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 3)
        let policy = try RetryPolicy(maximumAttempts: 2)
        let jobs = ["always-fails", "fails-once", "works"].map { Job(id: $0, input: 7) }

        let results = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
            switch job.id {
            case "always-fails": throw WorkerFailure()
            case "fails-once" where attempt == 1: throw WorkerFailure()
            default: return job.input
            }
        }

        XCTAssertEqual(results, [
            JobResult(id: "always-fails", outcome: .failed),
            JobResult(id: "fails-once", outcome: .succeeded(7)),
            JobResult(id: "works", outcome: .succeeded(7))
        ])
    }

    /// AC-B7: bad input is rejected before any attempt, with retry as well.
    func testRetryRunRejectsDuplicateIDsBeforeAnyAttempt() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 2)
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = ["a", "b", "a"].map { Job(id: $0, input: 0) }

        do {
            _ = try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await log.record(job.id, attempt)
                return 0
            }
            XCTFail("Expected a duplicateID error")
        } catch {
            XCTAssertEqual(error as? TaskProcessorError, .duplicateID("a"))
        }
        let attempts = await log.attempts
        XCTAssertTrue(attempts.isEmpty, "No attempt may run when the input is invalid")
    }

    /// AC-B8 / SPEC Q-1: after the user cancels, a failed attempt is not retried;
    /// the job keeps its real result (.failed, as in the base rules), and
    /// waiting jobs never start.
    func testNoRetryAfterTheRunIsCancelled() async throws {
        let processor = try TaskProcessor(maximumConcurrency: 1)
        let probe = Probe()
        let log = AttemptLog()
        let policy = try RetryPolicy(maximumAttempts: 3)
        let jobs = ["a", "b"].map { Job(id: $0, input: 0) }

        let run = Task {
            try await processor.process(jobs, retryPolicy: policy) { job, attempt in
                await log.record(job.id, attempt)
                await probe.runJob(job.id)
                throw WorkerFailure()               // ordinary error, would normally be retried
            }
        }

        await probe.waitForStarts(1)               // a is on attempt 1
        run.cancel()
        await probe.release("a")                   // attempt 1 fails after the cancel

        let results = try await run.value
        let attempts = await log.attempts
        XCTAssertEqual(attempts, ["a": [1]], "No new attempt and no new job after cancellation")
        XCTAssertEqual(results, [
            JobResult(id: "a", outcome: .failed),
            JobResult(id: "b", outcome: .cancelled)
        ])
    }
}
