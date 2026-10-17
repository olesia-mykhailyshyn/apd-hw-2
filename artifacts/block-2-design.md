# Block 2 — Design decisions (selected session excerpts)

Session: Claude Code (Claude Opus 5.5), 2026-10-17. My messages quoted as
written, with an English translation. Agent answers are short summaries.

---

**Step 1 — options.** The agent listed 8 decisions. For the limit N:
A) sliding window in a task group (recommended), B) N worker loops that take
the next index from a shared counter, C) own async semaphore.

**My choice:** «B. N «працівників» (як thread pool у C++)»
*(B — N workers, like a thread pool in C++)*

Agent (summary): Corrected its earlier argument against B — `addTask` in A
also does not fix which worker really starts first; the contract asks that
jobs are *chosen* left to right, which B does. Raised three details for B:
the counter must be a separate actor per call; where to check cancellation;
start only `min(N, jobs.count)` loops.

---

**Step 2 — cancelled or failed?**
«Д3 ... це поясни і давай разом обговоримо варіанти»
*(Explain D3 and let's discuss the options together)*

Agent (summary): Compared three rules on four scenarios:

| Scenario | Contract | By type | By flag | Type or flag |
| --- | --- | --- | --- | --- |
| run not cancelled, worker throws `CancellationError` | `.cancelled` | ✅ | ❌ failed | ✅ |
| run cancelled, worker throws `CancellationError` | `.cancelled` | ✅ | ✅ | ✅ |
| run cancelled, worker throws its own error | not stated | failed | cancelled | cancelled |
| run not cancelled, ordinary error | `.failed` | ✅ | ✅ | ✅ |

Flag-only breaks row 1. "By type" follows "ordinary error → failed" literally.

---

**Step 3 — questionnaire.**
«давай приймемо всі необхідні рішення таким чином: ти зараз даш опитувальник
і я виберу» *(Give me a questionnaire and I will choose)*

| Question | Options | My answer |
| --- | --- | --- |
| Where to check cancellation | in the worker loop / inside `JobQueue.next()` | inside `next()` |
| Cancelled vs failed | by type / type or flag | by type |
| Retry after run cancelled (Q-1) | stop `.cancelled` / stop `.failed` / keep retrying | stop `.cancelled` |
| Source files | one file / several files | several files |
| Names | `JobExecutor`… / `JobRunner`… | `JobRunner`, `SingleRun`, `RetryRun`, `JobQueue` |
| Explicit `cancelAll()` | no / yes | no |
| Worker ignores cancel, returns value | `.succeeded` / `.cancelled` | `.succeeded` |
| Demo and tests | demo with prints + own tests / deterministic demo | demo with prints + own tests |
