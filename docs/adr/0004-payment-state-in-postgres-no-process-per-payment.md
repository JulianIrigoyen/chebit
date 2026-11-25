# ADR 0004: Payment state lives in Postgres. No long-lived process per payment

- Status: accepted for Phase 0. It differs from one line of the brief; see below.
- Date: 2026-11-20

## Context

The brief says: "each payment is a lightweight process with its state machine, supervised;
if it fails, it restarts without affecting the rest". A GenServer or `gen_statem` per
payment gives that. It also gives a second copy of the state, in memory.

## Decision

- The status of a payment is one column in `payment_intents`. Nothing else holds it.
- `Chebit.Payments.StateMachine` is a pure module: `transition/2` and `path/2`.
- Each step runs in a short-lived supervised process: the HTTP request process, or one
  Oban job for a webhook, an expiry or a publish. A crash in one does not touch another,
  and Oban retries it.
- A row lock (`SELECT ... FOR UPDATE` on the intent) puts the steps of one payment in order.
- Timers are scheduled Oban jobs, so they survive a restart.

## Why not one process per payment

- A process that mirrors a database row can disagree with it. Then two things claim to be
  the truth.
- After a deploy or a crash each live payment needs its process again, from the database.
- Two nodes can each start a process for one payment. The row lock is still needed, so the
  process adds no safety.
- What the brief wants from the process (isolation, restart, concurrency) the short-lived
  processes already give.

## Revisit when

A payment needs work that Postgres plus jobs does badly: timers finer than one second,
a stream of updates to a live screen for each payment, or measured lock contention on one
intent. Then add a process as a cache and a timer, never as the owner of the state.
