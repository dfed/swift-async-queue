# swift-async-queue

## Tests

All tests must be deterministic. A test gives the same result on every
run of the same code: on correct code it passes every run, and on the
regression it guards it fails every run, or hangs, in which case CI's
job timeout is the failure.

- Force the interleaving a test needs with semaphores, manual
  executors, and test hooks.
- Never rely on sleeps, wall-clock timeouts, polling, or repetition.
- CI runs each test once.

A few older tests loop in the hope of catching a bad interleaving: the
`sendsEventsInOrder` tests, the `executesAsyncBlocksAtomically` tests,
and `task_isNotReentrant` and `throwingTask_isNotReentrant`. They stay
as backstops because no deterministic test catches what they catch yet.
Delete a probabilistic test only once a deterministic test fails 10 of
10 runs for every bug it catches.

## Coverage

Code coverage must stay at 100%, the target in `codecov.yml`.

## Concurrency

Never cancel, resume, or escalate a task while holding a lock. That
includes the runtime's own lock on a task, which it holds while it runs
the task's cancellation and priority escalation handlers: do that work
after the lock is released, or from a new task.

## Performance

Prefer the faster code over the shorter code on the path that enqueues
a task.

## Style

`guard` is fine, but don't return early from an `if` without an `else`.

## Documentation

Write the README and documentation comments in the plain style of The
Swift Programming Language's chapter on concurrency. Use the terms it
uses, and don't invent new concepts.
