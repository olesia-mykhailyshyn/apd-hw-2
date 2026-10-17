# SPEC — Homework 2: Deterministic Concurrent Task Processor

Source of truth: `TASKS_AND_GRADES.md`. This file restates the contract in
business terms so every test can point to a rule.

## 1. Business rules

| ID | Rule | Why it matters |
| --- | --- | --- |
| BR-1 | The limit must be a positive number. | A limit of 0 or less means nothing could ever run. |
| BR-2 | Every job must have a unique ID. Bad input is rejected before any work starts. | The report is matched to jobs by ID; duplicates make it ambiguous. No partial work on bad input. |
| BR-3 | No more than `maximumConcurrency` jobs run at the same time. | Protects the system from overload. |
| BR-4 | When a job finishes, the next waiting job (left to right) may start. | Keeps the work moving; order of starting is predictable. |
| BR-5 | The report follows the input order, not the finishing order. | Users see a stable list. |
| BR-6 | One failed job does not stop the others. | One broken photo must not cancel the whole upload. |
| BR-7 | A job whose worker reports cancellation is marked cancelled; the rest continue. | The worker may give up on its own. |
| BR-8 | If the caller cancels the whole run, nothing new starts; jobs that never started are marked cancelled; finished results are kept. | The user pressed "Cancel"; work already done is not lost. |
| BR-9 (bonus) | A job that fails with an ordinary error is tried again, up to a set number of attempts. | Temporary problems (e.g. network) often pass. |
| BR-10 (bonus) | A cancelled attempt is never retried. Retries reuse the same slot and happen immediately. | Cancel means stop; retries must not break the limit; results stay predictable. |

## 2. Scope

**In scope**
- `TaskProcessor` with the exact public API from the contract.
- Input validation, bounded scheduling, input-order results, outcome mapping,
  caller cancellation.
- Bonus: `RetryPolicy`, `RetryPolicyError`, and the retrying `process` overload.
- At least six own XCTest tests, each linked to an AC below.
- A small demo program (`swift run`) that prints what happens step by step.
- `PLAN.md`, `AGENT_WORKLOG.md`, this spec.

**Out of scope** (from the contract's non-goals)
- Timeouts, delays, backoff, random behaviour.
- Retrying in the base `process`.
- Forcing a worker to stop if it ignores cancellation.
- Changing job IDs (e.g. trimming spaces or ignoring case).
- Progress reporting.
- Fairness beyond left-to-right order.
- Correct behaviour when two `process` calls overlap on one processor.
- Choosing the best limit for the hardware (the caller decides the limit).
- Foundation, GCD, locks, printing from the library.

## 3. Acceptance criteria — base

| ID | Given | When | Then | Rule |
| --- | --- | --- | --- | --- |
| AC-1 | a limit of 0 or a negative number | the processor is created | it throws `.nonPositiveMaximumConcurrency` | BR-1 |
| AC-2 | jobs `[a, b, a, b]` | `process` is called | it throws `.duplicateID("a")` and the worker is never called | BR-2 |
| AC-3 | jobs `[a, b, b, a]` | `process` is called | it throws `.duplicateID("b")` (first job whose ID was seen before) | BR-2 |
| AC-4 | an empty job list | `process` is called | it returns `[]` and the worker is never called | BR-2 |
| AC-5 | limit 2, five jobs that wait until released | the run starts | exactly jobs 1 and 2 are running; jobs 3–5 have not started | BR-3, BR-4 |
| AC-6 | the situation in AC-5 | job 1 is released and finishes | job 3 starts next (not 4 or 5); never more than 2 running | BR-3, BR-4 |
| AC-7 | three jobs, limit 3 | they finish in reverse order (c, b, a) | the report is `[a, b, c]` | BR-5 |
| AC-8 | a worker that returns a number | a job runs | its result is `.succeeded(number)` | BR-6 |
| AC-9 | one job's worker throws an ordinary error, others succeed | the run finishes | that job is `.failed`; the others are `.succeeded` | BR-6 |
| AC-10 | one job's worker throws `CancellationError` while the run itself is not cancelled | the run finishes | that job is `.cancelled`; the others still run and succeed | BR-7 |
| AC-11 | limit 1, jobs `[a, b, c]`, `a` already finished, `b` running | the caller cancels the run | `c` never starts; `a` keeps `.succeeded`; `b` is `.cancelled` if its worker stops on cancel; `c` is `.cancelled` | BR-8 |
| AC-12 | any cancelled run | it ends | the report still has one line per job, in input order | BR-5, BR-8 |

## 4. Acceptance criteria — bonus

| ID | Given | When | Then | Rule |
| --- | --- | --- | --- | --- |
| AC-B1 | `maximumAttempts` of 0 or less | the policy is created | it throws `.nonPositiveMaximumAttempts` | BR-9 |
| AC-B2 | max 3 attempts, worker fails on attempts 1–2 and succeeds on 3 | the job runs | result `.succeeded`; worker saw attempt numbers 1, 2, 3 | BR-9 |
| AC-B3 | max 3 attempts, worker always fails | the job runs | result `.failed`; worker called exactly 3 times | BR-9 |
| AC-B4 | worker throws `CancellationError` on attempt 1 | the job runs | result `.cancelled`; worker called exactly once | BR-10 |
| AC-B5 | limit 2, several jobs that retry | the run happens | never more than 2 jobs running at once, retries included | BR-10 |
| AC-B6 | jobs with different numbers of retries | the run finishes | report still in input order | BR-5 |
| AC-B7 | duplicate IDs with a retry policy | `process` is called | it throws `.duplicateID` before any attempt | BR-2 |
| AC-B8 | caller cancels during a retry run | the run ends | base cancellation rules hold (AC-11, AC-12) | BR-8 |

## 5. Open questions (decided in PLAN.md)

- Q-1: If the run is cancelled after a job's attempt failed with an ordinary
  error, is the next attempt started? If not, is the job `.failed` or
  `.cancelled`? The contract does not say directly.
  Decided: no new attempt; the job is `.failed` (see PLAN.md).

## 6. Test coverage

Every acceptance criterion is checked by at least one test. Own tests are in
`Tests/TaskProcessorTests/TaskProcessorStudentTests.swift`; starter tests are
in `TaskProcessorPublicTests.swift`. Run all with `swift test`.

### Base

| AC | Test | What it proves (business view) |
| --- | --- | --- |
| AC-1 | `testNegativeLimitIsRejected` | A negative limit is refused just like zero; the processor is never created. |
| AC-1 | *(starter)* `testZeroMaximumConcurrencyIsRejected` | A limit of 0 is refused. |
| AC-2 | `testDuplicateIDsRejectBatchBeforeAnyWorkerRuns` | Duplicate IDs reject the whole batch, and no work at all is done (worker call count is 0). |
| AC-3 | `testReportedDuplicateIsFirstRepeatInInputOrder` | The error names the first job whose ID was already seen (`[a, b, b, a]` → `b`), not the first value that has a copy. |
| AC-4 | *(starter)* `testEmptyJobListReturnsEmptyWithoutCallingWorker` | An empty list gives an empty report and runs nothing. |
| AC-5 | `testNoMoreThanLimitJobsRunAtOnce` | With limit 2, only the first two jobs start, and exactly two run at once — the limit is kept and the work really runs in parallel. |
| AC-6 | `testFreedSlotGoesToNextJobFromTheLeft` | When one job ends, exactly one new job starts, and it is the next one from the left. |
| AC-7 | `testReportFollowsInputOrderWhenJobsFinishInReverse` | Jobs finish in reverse order, but the report is still in input order. |
| AC-7 | *(starter)* `testResultsKeepInputOrderWhenSecondJobPassesGateFirst` | Same rule with two jobs. |
| AC-8 | *(starter)* `testOneSuccessfulJob`, plus every test with a successful job | A returned value is reported as `.succeeded(value)`. |
| AC-9 | `testOneFailingJobDoesNotStopTheOthers` | One broken job is `.failed`; the others still succeed. |
| AC-9 | *(starter)* `testOrdinaryWorkerErrorBecomesFailedOutcome` | An ordinary error becomes `.failed`. |
| AC-10 | `testWorkerGivingUpIsCancelledButTheRunContinues` | A worker that throws `CancellationError` on its own makes that job `.cancelled`; the run goes on and later jobs succeed. |
| AC-11 | `testCancelKeepsFinishedWorkStopsRunningJobAndStartsNothingNew` | User cancels mid-run: finished job keeps its success, running job stops, waiting job never starts. |
| AC-12 | `testRunCancelledBeforeStartRunsNothingButReportsEveryJob` | A run cancelled before it begins does no work, but still reports every job (as cancelled) in input order. |
| PLAN S5 | `testWorkerThatIgnoresCancelKeepsItsResult` | A worker that ignores cancellation and finishes keeps its success; jobs that never started are cancelled. |

### Bonus — retry

| AC | Test | What it proves (business view) |
| --- | --- | --- |
| AC-B1 | `testRetryPolicyNeedsAtLeastOneAttempt` | 0 or negative attempts are refused; 1 is accepted. |
| AC-B2 | `testTemporaryFailureRecoversBeforeTheLimit` | A temporary problem passes on attempt 3 of 4; attempts are numbered 1, 2, 3 and there is no extra attempt after the success. |
| AC-B3 | `testPermanentFailureStopsAfterExactlyMaxAttempts` | A permanent problem is tried exactly 3 times, then reported as `.failed`. |
| AC-B4 | `testCancelledAttemptIsNeverRetried` | `CancellationError` stops the job at once: one attempt, `.cancelled`. |
| AC-B5 | `testRetriesStayInsideTheirSlot` | While two jobs are retrying, a third job does not start — retries never take an extra slot. |
| AC-B6 | `testRetryReportKeepsInputOrderWithMixedOutcomes` | Jobs with different numbers of retries are still reported in input order. |
| AC-B7 | `testRetryRunRejectsDuplicateIDsBeforeAnyAttempt` | Duplicate IDs are rejected before any attempt, with retry too. |
| AC-B8 / Q-1 | `testNoRetryAfterTheRunIsCancelled` | After the user cancels, a failed attempt is not retried (the job keeps its real result, `.failed`) and waiting jobs never start. |

### Totals

- Own tests: 19 (11 base + 8 bonus). Starter tests: 5.
- Why more than the minimum of 6: one test per business rule, so a failing
  test name tells exactly which rule is broken. The whole suite runs in
  about 0.005 s.
- Stability: 30 normal runs and 10 `--parallel` runs, 0 failures. Tests use
  gates and probes, never sleeps or time limits.
