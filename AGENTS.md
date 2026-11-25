# AGENTS.md

Rules for coding agents and for people in this repo. `CLAUDE.md` imports this file.
The product brief is `docs/BRIEF.md`. The plan and the open questions are `docs/PLAN.md`.
The decisions are in `docs/adr/`.

## Commands

- Run each tool through mise: `mise exec -- <cmd>` or `mise run <task>`. Homebrew's Erlang can shadow the pinned one.
- `mise run db` starts Postgres on `127.0.0.1:54330`. It is safe to run twice.
- Tests: `bin/t` for all, `bin/t test/path_test.exs` for one file, add `:LINE` for one test.
  Always use `bin/t`, never `mix test`: it runs one test run at a time for the repo.
- `mise run gate` runs format, compile with warnings as errors, credo, dialyzer and the tests.
- New migration: `mise exec -- mix ecto.gen.migration <name>`. Do not write the file name by hand.
  Do not edit a migration that already ran. Write a new one.

## Invariants

Each one has a test that fails when it breaks. `Chebit.Ledger.Audit` checks 1, 3 and 8 on stored data.

1. Each ledger transaction sums to zero for each currency.
2. The ledger is append-only. A correction is a new transaction that reverses the old one.
3. The available balance (`balance_minor - held_minor`) of a merchant or user account is never negative.
4. A request with the same idempotency key has its effect once. A retry gets the first response.
5. A payment is sent to a provider exactly once in effect.
6. A terminal status never changes. A transition only moves forward.
7. No float holds money. An amount is an integer in the smallest unit.
8. The funds that providers hold cover what the ledger owes to merchants and users.

## Money rules

- An amount is an integer in the smallest unit. The name ends in `_minor`, and a `currency` goes with it. No float and no Decimal.
- Each write that moves money is idempotent on a key or a source. A unique index backs it.
- The same key with the same request returns the first result. The same key with a different request returns an error.
- Money tables are append-only. A correction is a new row.
- The database enforces each invariant with a constraint. The application check comes first and returns an error atom.
- A change and its outbox event commit in one transaction.
- Lock order: account rows in ascending id order, then the hold row.
- A function that computes entries or a transition is pure: data in, result or error out. It calls no Repo.
- No call to a provider inside a database transaction.
- Inside a transaction, never let a statement fail on a constraint and then continue. Use `on_conflict: :nothing` and read the row.
- Fail closed. An unknown provider, status, actor or error means: refuse, change nothing, log.

## Code

- A public function in `lib/chebit/` has a `@spec` and a `@doc`. Each module has a `@moduledoc`.
- A function returns `{:ok, value}` or `{:error, atom}`. One shape per function. The `@spec` lists each error atom.
  A function that validates outside input can return `{:error, Ecto.Changeset.t()}` instead.
- `with` carries the happy path. Add `else` only to rename an error.
- Code that reads outside input does not raise. Validate at the boundary.
- Do not list fields that the program sets, such as `merchant_id` or `status`, in `cast`.
- No `String.to_atom/1` on input.
- Use `Repo.transact/2` for a transaction. Return `{:error, reason}` from the function to roll back.
- A comment states the constraint and its reason. It does not tell the history of the change.
- No new dependency without a line in `docs/PLAN.md` that names it and gives the reason.
- Never log an API key, a webhook secret or a full request body.

## Tests

- Test files mirror `lib/`. A `describe` block names the function and its arity.
- Property tests cover invariants (`use ExUnitProperties`). Each one sets `max_runs`.
- Rejected input has its own `describe` block.
- A test that needs real concurrency or a real COMMIT uses `Chebit.UnboxedCase`. Other database tests use `Chebit.DataCase, async: true`.
- Never delete or loosen a test to make it pass. If a test and a contract disagree, report both.

## Writing

Docs, comments and commit messages use short sentences in active voice, one idea each.
Use the same word for the same thing every time. Name the file, the number, the error.

## Commits

Do not commit and do not push. The owner commits.
