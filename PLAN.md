# Implementation Plan

Complete this before implementation and update it when the plan changes.

Business rules, scope and acceptance criteria (AC-x) are in
[`artifacts/SPEC.md`](artifacts/SPEC.md). This plan explains *how* they will
be met.

## Approach

### Overview

Two parts with separate jobs:

- **Scheduler** (inside `TaskProcessor`): limit, input order, cancellation,
  never-started jobs. It does not know about retry.
- **Runner** (`JobRunner` protocol): runs one job and turns the worker's
  result into a `JobOutcome`. `SingleRun` = one attempt (base).
  `RetryRun` = up to `maximumAttempts` attempts (bonus).

Both public `process` methods do the same three steps:
validate input → pick a runner → call the shared scheduler.

### Validation (AC-1 – AC-4)

- `init` throws `.nonPositiveMaximumConcurrency` if the limit is `<= 0`.
- `process` scans jobs left to right with a `Set<String>` of seen IDs and
  throws `.duplicateID(id)` at the first ID already in the set. This happens
  before any worker runs.
- An empty list returns `[]` straight away.

### Bounded scheduling — "workers" model (AC-5, AC-6)

- A small actor `JobQueue` is created for each `process` call. It hands out
  job indexes 0, 1, 2, … one at a time through `next() -> Int?`.
- The scheduler starts `min(maximumConcurrency, jobs.count)` child tasks in a
  task group. Each child is a "worker loop": ask `JobQueue` for the next
  index, run that job, repeat until `next()` returns `nil`.
- So at most N jobs are in progress, and a freed worker always takes the
  next job from the left.

### Result storage and order (AC-7, AC-12)

- Each worker loop returns its own list of `(index, outcome)` pairs. It never
  writes to shared memory (no data race; Swift 6 checks this).
- The scheduler collects all lists into `[JobOutcome?]` of size
  `jobs.count`, by index.
- Any slot still `nil` at the end belongs to a job that never started → it
  becomes `.cancelled`.
- The final `[JobResult]` is built in input order from `jobs` and this array.

### Outcome mapping (AC-8 – AC-10)

Decided by the **type** of what the worker did:

- returns a value → `.succeeded(value)`
- throws `CancellationError` → `.cancelled`
- throws anything else → `.failed`

A worker that ignores cancellation and still returns a value is recorded as
`.succeeded`. One job's error never stops other jobs: errors are caught
inside the runner.

### Caller cancellation (AC-11, AC-12)

- `JobQueue.next()` checks `Task.isCancelled` (the calling worker loop's
  task) and returns `nil` if it is set. Checking and handing out the index
  happen in one step inside the actor, so no job can start after
  cancellation was seen.
- Running workers are cancelled automatically: cancelling `process` cancels
  the task group's children. We do not call `cancelAll()` ourselves.
- Jobs already finished keep their outcome.

### Retry — bonus (AC-B1 – AC-B8)

- `RetryPolicy(maximumAttempts:)` throws `.nonPositiveMaximumAttempts` if
  the value is `<= 0`.
- `RetryRun` loops `attempt = 1...maximumAttempts` inside the same worker
  loop, so a retry never takes an extra slot:
  - success → `.succeeded`
  - `CancellationError` → `.cancelled`, no more attempts
  - ordinary error → try again; on the last attempt → `.failed`
  - ordinary error while the run is cancelled → stop, no new attempt,
    `.failed` (same as the base rule: an ordinary error is `.failed`)
- No delays, no timeouts.

### Files

| File | Contents |
| --- | --- |
| `Sources/TaskProcessor/TaskProcessor.swift` | public types (unchanged), `TaskProcessor` actor, validation, shared entry `processAll` (used by both `process` methods), scheduler |
| `Sources/TaskProcessor/JobRunner.swift` | `JobRunner` protocol, `SingleRun`, `RetryRun` |
| `Sources/TaskProcessor/JobQueue.swift` | `JobQueue` actor |
| `Sources/TaskProcessor/RetryPolicy.swift` | `RetryPolicy`, `RetryPolicyError`, retrying `process` |
| `Sources/TaskProcessorDemo/main.swift` | demo program with prints |
| `Tests/TaskProcessorTests/TaskProcessorStudentTests.swift` | my tests |

`JobRunner`, `SingleRun`, `RetryRun`, `JobQueue` are `internal` — the public
API stays exactly as in the contract.

### Decisions and alternatives

| Topic | Chosen | Alternatives considered | Why |
| --- | --- | --- | --- |
| Limit N | N worker loops + `JobQueue` actor | sliding window in a task group; own async semaphore | Familiar thread-pool model from C++; shows actor use. Indexes are still chosen left to right. |
| Where to check cancellation | inside `JobQueue.next()` | `if Task.isCancelled` in the loop | Check and hand-out are one step; no gap where a job could slip through. |
| Result storage | array by index | dictionary by ID | IDs are unique and the index is already known. |
| Cancelled vs failed | by error type | by `Task.isCancelled` flag; type or flag | Flag-only breaks the contract (worker may throw `CancellationError` on its own). Type matches "ordinary error → failed" literally. |
| `cancelAll()` | not called | call explicitly | Cancellation already reaches children automatically. |
| Shared design | `JobRunner` protocol | function with `maxAttempts`; closure | Clear split between scheduler and retry; practice with protocols. (Agent suggested the closure.) |
| Retry after run cancelled (SPEC Q-1) | stop, `.failed` (revised after review) | stop, `.cancelled` (my first choice); keep retrying | Same rule for every attempt number and the same as the base rule "ordinary error → failed". The first choice gave `.cancelled` or `.failed` depending on how many attempts were left — found by the independent review. |
| Choosing N | caller decides | benchmark cores and time | Contract forbids time checks; best N depends on the worker. |
| Timeouts / delays | none | — | Forbidden by the contract; would make tests machine-dependent. |

## Milestones

- [x] Validate configuration and all job IDs before starting work.
- [x] Schedule jobs within the concurrency limit and preserve input order.
- [x] Map success, ordinary errors, and cancellation outcomes.
- [x] Handle caller cancellation and never-started jobs.
- [x] Add at least six distinct student-authored tests and run `swift test`.
- [x] Bonus: `RetryPolicy` and retrying `process`, with tests.
- [x] Demo program (`swift run TaskProcessorDemo`).
- [ ] Final review of the whole diff; worklog complete.

## Risks and checks

| Risk | How it is handled / tested |
| --- | --- |
| More than N workers at once | Test probe counts active workers and records the maximum (AC-5, AC-6, AC-B5). |
| Wrong next job after a slot frees | Gate keeps jobs waiting; release one and check exactly the next one started (AC-6). |
| Results in finishing order | Release jobs in reverse order; check input order (AC-7). |
| One error stops the run | Mix failing and succeeding jobs (AC-9). |
| Worker throws `CancellationError` without run cancellation | Check that job is `.cancelled` and others succeed (AC-10). |
| Job starts after cancellation | Limit 1, cancel while a job runs; check the waiting job's worker is never called (AC-11). |
| Data race on results | Children only return values; Swift 6 compiler check. |
| Overlapping `process` calls share state | All per-call state is local (`JobQueue` per call). Not graded. |
| Worker ignores cancellation | Recorded as `.succeeded`; the processor waits for it (non-goal). |
| Contract does not say what to do in Q-1 | Decided above; covered by AC-B8 test. |
| Initial N jobs may call the worker in any order | Contract requires left-to-right *choice*; tests wait until all initial jobs are waiting before checking. |
| Adding a demo target to `Package.swift` breaks the build | Run `swift build` and `swift test` after the change. |
| Tests depend on timing | No `sleep` in tests; only gates and probes. |
| `RetryRun` with `maximumAttempts` 0 would crash (`1...0` is an invalid range) | `RetryRun` is only created from a `RetryPolicy`, which refuses values `<= 0` (AC-B1). |
| A gate test hangs instead of failing if the processor has a bug (XCTest has no default timeout for async tests) | Run the suite many times (serial and `--parallel`) after each change and watch for hangs. |

Which test covers which acceptance criterion: see
[`artifacts/SPEC.md` §6 "Test coverage"](artifacts/SPEC.md#6-test-coverage).
