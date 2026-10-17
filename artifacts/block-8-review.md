# Block 8 — Independent review (selected session excerpts)

Session: Claude Code (Claude Opus 5.5), 2026-10-17. A second agent reviewed
the code. It saw only the code, tests and contract, not my conversation.

## What the reviewer checked
- Contract table row by row; public API (names, labels, access levels,
  conformances); library imports, GCD, locks, prints.
- Swift 6 safety: data races, isolation, deadlocks, hangs.
- Tests: distinct, deterministic, cannot pass for the wrong reason.
- `Package.swift` with the added demo target.
- Ran `swift test` plus 60 extra runs of my tests: 0 failures.

## Findings

| # | Severity | Finding | My decision |
| --- | --- | --- | --- |
| 1 | minor | Retry + cancel: "cancel, then an ordinary error" gave `.cancelled` when attempts were left, but `.failed` on the last attempt or with `maximumAttempts: 1`; the base path gives `.failed`. | Changed to always `.failed`: no new attempt after cancel, the job keeps its real result. One rule for every attempt, same as the base rule and the contract text "the final ordinary error yields `.failed`". |
| 2 | nit | `Probe` waits have no timeout, so a broken scheduler would hang a test instead of failing it. | Kept. Risk already in PLAN.md; the starter `Gate` works the same way. |
| 3 | nit | AC-5 test checks `maxActive == 2` exactly, not `<= 2`. | Kept on purpose: it also proves that jobs really run in parallel; deterministic because both jobs wait at the gate. |

## Options I was given for finding 1
- (b) always `.failed` — recommended, chosen.
- (c) always `.cancelled` — consistent inside retry, but retry with 1 attempt would differ from the base.
- (a) keep as it was — documented, but inconsistent.

My note: I had first accepted the agent's recommendation for Q-1 without
seeing this case; the independent review found it.

## After the change
- `RetryRun`: the cancel check moved from "before attempt 2+" to "after an
  ordinary error".
- Test `testNoRetryAfterTheRunIsCancelled` now expects `a: .failed`, `b: .cancelled`.
- `swift test` 24/24; 30 normal + 10 `--parallel` runs, 0 failures.
