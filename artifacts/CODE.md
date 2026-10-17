# Code guide

How the code works, file by file. Rules and acceptance criteria are in
`SPEC.md`; design decisions are in `../PLAN.md`.

## Files

| File | One sentence |
| --- | --- |
| `Package.swift` | Three targets: the library, the tests and the demo program. |
| `Sources/TaskProcessor/TaskProcessor.swift` | Public types and the processor: validation, shared entry, scheduler. |
| `Sources/TaskProcessor/JobQueue.swift` | Hands out job indexes one by one; stops on cancellation. |
| `Sources/TaskProcessor/JobRunner.swift` | How to run one job and turn the worker's result into an outcome. |
| `Sources/TaskProcessor/RetryPolicy.swift` | Bonus: retry settings and the retrying `process`. |
| `Sources/TaskProcessorDemo/main.swift` | Console demo with 5 scenarios. |
| `Tests/TaskProcessorTests/TaskProcessorStudentTests.swift` | My 19 tests and their helpers. |

## Path of one call

    process(jobs, worker)                       base: wraps worker in SingleRun
    process(jobs, retryPolicy:, worker)         bonus: wraps worker in RetryRun
        └─ processAll(jobs, runner)
              ├─ validateUniqueIDs(jobs)        duplicate → throw, nothing runs
              ├─ jobs empty → return []
              └─ schedule(jobs, runner)
                    ├─ JobQueue(count:)         new queue for this call
                    ├─ min(N, jobs.count) worker loops in a task group
                    │     loop: index = await queue.next()   (nil → stop)
                    │           outcome = await runner.run(jobs[index])
                    │           keep (index, outcome) in a local list
                    ├─ parent collects all lists into outcomes[index]
                    └─ report in input order; missing outcome → .cancelled

## Package.swift

- `.target(name: "TaskProcessor")` — the library. No dependencies.
- `.executableTarget(name: "TaskProcessorDemo", dependencies: ["TaskProcessor"])` —
  added for the demo; run with `swift run TaskProcessorDemo`.
- `.testTarget(name: "TaskProcessorTests", dependencies: ["TaskProcessor"])` — tests.
- Each target is a separate module. All are built by one `swift build` / `swift test`.

## TaskProcessor.swift

- `Job`, `JobOutcome`, `JobResult`, `TaskProcessorError` — starter types, unchanged.
- `actor TaskProcessor` keeps only `maximumConcurrency` (`let`). Everything
  that belongs to one call is a local variable, so calls do not share state.
- `init` throws `.nonPositiveMaximumConcurrency` when the limit is `<= 0` (`guard`).
- `process` (public) → `processAll(jobs, using: SingleRun(worker:))`.
- `processAll` (internal, also used by the bonus file): validate → empty
  check → `schedule`.
- `schedule` (private):
  - `withTaskGroup(of: [(Int, JobOutcome)].self)` — one child task per worker loop.
  - Each loop writes only to its own local list; only the parent writes
    `outcomes`, so there is no data race.
  - `for await finished in group` collects the lists as loops finish.
  - `jobs.indices.map { ... outcomes[index] ?? .cancelled }` builds the report
    in input order.
  - The limit comes from the structure: at most N loops, each runs one job at a time.
- `validateUniqueIDs` (static): left-to-right scan with a `Set`;
  `insert(...).inserted == false` means the ID was seen before → throw `.duplicateID`.

## JobQueue.swift

- `actor JobQueue` with `count` and `nextIndex`.
- `next() -> Int?`: returns `nil` if the calling task is cancelled or no jobs
  are left; otherwise returns `nextIndex` and then adds 1 (`defer`).
- It is an actor because N loops call `next()` at the same time; with a class
  two loops could get the same index (the lecture's `accountBalance` race).
- The cancel check and the hand-out are one step with no `await` between
  them, so no job can start after cancellation is seen.

## JobRunner.swift

- `protocol JobRunner: Sendable { func run(_ job: Job) async -> JobOutcome }` —
  no `throws`: every worker error becomes an outcome here.
- `SingleRun` (base): `do { .succeeded(try await worker(job)) }`,
  `catch is CancellationError { .cancelled }`, `catch { .failed }`.
- `RetryRun` (bonus): `for attempt in 1...maximumAttempts`:
  success → return; `CancellationError` → `.cancelled`;
  ordinary error → if the run is cancelled return `.failed`, else `continue`.
  After the loop → `.failed`.
- All attempts run inside one `run` call, so a retry never uses another slot.
- Both are `struct`s: they hold no changing state, so they are `Sendable` for free.

## RetryPolicy.swift

- `RetryPolicy`: `init` throws `.nonPositiveMaximumAttempts` for `<= 0`, so a
  policy always holds at least 1 attempt and `1...maximumAttempts` is safe.
- `RetryPolicyError`: one case.
- `public extension TaskProcessor { func process(_:retryPolicy:worker:) }` —
  an overload; Swift picks it by the `retryPolicy:` label and the
  `(Job, Int)` worker. Body: `processAll(jobs, using: RetryRun(...))`.

## Demo (main.swift)

- Uses a plain `import TaskProcessor`, so it sees only the public API.
- `Tracker` (actor) prints "start/end" and how many jobs run now.
- `pause` uses `Task.sleep`, which does not block a thread and throws on cancel.
- Scenarios: 1) limit and order, 2) errors, 3) cancel, 4) retry, 5) bad input.
- Scenarios are functions because top-level variables in `main.swift` belong
  to the main actor in Swift 6 and cannot be passed to workers.
- `print` and delays are only in the demo, never in the library.

## Tests

- Helpers (all `private`, all actors because workers call them at the same time):
  - `CallCounter` — counts worker calls (proves "no work started").
  - `AttemptLog` — records attempt numbers per job.
  - `Probe` — records start/finish order and the most jobs running at once,
    and holds each job at a gate until the test calls `release`. Uses
    `CheckedContinuation`: the worker sleeps until `resume()` is called.
- Pattern: start `process` in a `Task`, wait for a state with
  `waitForStarts`/`waitForFinishes`, release or cancel, then check the report.
- No sleeps or time limits: the test decides the order of events.
- Which test covers which acceptance criterion: `SPEC.md` §6.

## Swift syntax used

| Syntax | Meaning |
| --- | --- |
| `actor` | type whose state one task at a time can touch; callers use `await` |
| `async` / `await` | function can pause; caller waits without blocking a thread |
| `throws` / `try` | function can fail; caller marks the call |
| `guard cond else { ... }` | early exit when the condition is false |
| `Int?`, `??` | optional value; "use this value, or the default if nil" |
| `defer { }` | run this when leaving the function |
| `some JobRunner` | any one concrete type that follows the protocol |
| `@Sendable`, `Sendable` | safe to share between tasks (checked by Swift 6) |
| `@escaping` | closure is kept after the call returns |
| `withTaskGroup` / `addTask` / `for await` | structured child tasks and collecting their results |
| `Task.isCancelled`, `Task.checkCancellation()` | read / react to cooperative cancellation |
| `catch is CancellationError` | catch by error type |
| `extension` | add methods to an existing type |
| `private` / `internal` / `public` | file / module / everyone |
