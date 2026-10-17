# Block 1 — Understanding the task (selected session excerpts)

Session: Claude Code (Claude Opus 5.5), 2026-10-17. Conversation in Ukrainian;
my questions are quoted as asked, with an English translation. Agent answers
are shortened summaries, not raw transcript.


---

**Q1.** «чи у свіфті concurrency виконується так само як в с++? ... в с++
можна робити тред пул, тут нам теж шось таке треба буде робити?»
*(Does Swift concurrency work like C++? Do we need a thread pool?)*

Agent (summary): Concurrency = many tasks in progress; parallelism = really at
the same moment on different cores. Swift already has a cooperative thread
pool (about one thread per core). Tasks are light objects, not threads; at
`await` a task gives its thread back. We do not write a pool; we limit tasks
in flight.

My takeaway: N limits tasks, not threads.

---

**Q2.** «може тут нам теж треба спробувати робити якесь таке тестування і
заміряти час і перформанс ... шоб підібрати найкраще число N?»
*(Should we benchmark to find the best N, like in another course?)*

Agent (summary): N is passed by the caller; tests use many values. The
contract forbids time-based checks, and the best N depends on what the worker
does (compute vs wait), which the library cannot know. Swift already caps
threads at the core count, so a large N cannot create thread overload.

My decision: no benchmarking; N stays a caller parameter. Logged as out of scope.

---

**Q3.** «Тому в Swift concurrency семафори і локи — погана ідея, поясни чому
це погано» *(Why are semaphores and locks bad in Swift concurrency?)*

Agent (summary): A blocked semaphore wait holds one of the few pool threads.
If all threads wait for a signal that needs a free thread, nothing can run —
deadlock by thread starvation (like the lecture's "holding A, wants B"). A
lock cannot be held across `await`, because the task may resume on another
thread.

---

**Q4.** «Swift 6 ловить більшість гонок під час компіляції — які гонки тут
маються на увазі?» *(Which races does Swift 6 catch?)*

Agent (summary): Data races (two tasks writing the same memory) are rejected
by the compiler through `Sendable` checks — e.g. child tasks writing one
shared results array. Logic races (race conditions) are not caught — e.g.
appending results in finishing order. Fix: children return
`(index, outcome)`, only the parent writes.

---

**Q5.** «кооперативне скасування шо це означає?»
*(What does cooperative cancellation mean?)*

Agent (summary): `cancel()` only sets a flag; it propagates to child tasks.
Code must check it (`Task.isCancelled`, `Task.checkCancellation()`). Lecture 1
slide 89 shows a running operation finishing after `cancelAllOperations()`.

---

**Q6.** «retry — поясни це більш детально ... maximumAttempts як визначити
значення ... чи треба ше якісь таймаути додавати?»
*(Explain retry; how to choose maximumAttempts; are timeouts needed?)*

Agent (summary): Ordinary error → try again, up to `maximumAttempts`;
`CancellationError` → never retried. Attempts run one after another inside
the same slot. `maximumAttempts` is chosen by the caller. Timeouts and delays
are forbidden by the contract and would make tests machine-dependent. One
case is not covered by the contract (retry after the run was cancelled) —
open question Q-1.

My decision: no timeouts; Q-1 to decide in block 2.

---

**Q7.** «Одне приватне ядро — а можна якийсь перевикористовуваний інтерфейс
зробити?» *(Can we make a reusable interface instead of one private core?)*

Agent (summary): Split the scheduler (limit, order, cancellation) from the
per-job execution (one attempt or retries). Three ways: a function with a
`maxAttempts` parameter, a closure "executor", or a protocol with two
conforming types. Agent recommended the closure.

My decision: **protocol** — clearer separation and practice with protocols.
