# Chebit

<p align="center">
  <img src="priv/static/images/logo-mark.png" width="180" alt="Chebit logo: a gaucho on a horse throws a lasso at a bitcoin">
</p>

A payment core for Argentina that joins pesos, dollars and Bitcoin behind one API.
Site: [chebit.com.ar](https://chebit.com.ar). Handbook: [chebit.com.ar/handbook.html](https://chebit.com.ar/handbook.html).
This repo holds Phase 0 of `docs/BRIEF.md`: the foundations that every later feature stands on.
It moves no real money yet: the only provider is a simulator.

## Run it

You need [mise](https://mise.jdx.dev) and Docker.

```bash
mise run demo
```

The command starts Postgres in Docker, builds a fresh `chebit_demo` database and runs three
payments against the simulated provider: one card-like (paid, then final), one
Lightning-like (final at once) and one refunded. It prints each step, each outbox event,
the ledger, the ledger audit and the reconciliation. It ends with `DEMO OK`.

## Commands

Run each with `mise run <name>`.

| Command  | What it does                                                             |
| -------- | ------------------------------------------------------------------------ |
| `demo`   | The run above. It uses its own database and never touches dev data.      |
| `setup`  | Start Postgres, fetch deps, create and migrate the dev database.         |
| `db`     | Start Postgres on `127.0.0.1:54330`. Safe to repeat.                     |
| `test`   | Run the tests. One run at a time: a second caller waits.                 |
| `gate`   | Format check, compile with warnings as errors, credo, dialyzer, tests.   |
| `server` | Start the API on port 4000.                                              |

One test file: `bin/t test/chebit/ledger_test.exs`. One test: add `:LINE`.

## What is here

| Part | Module | What it guarantees |
| ---- | ------ | ------------------ |
| Ledger | `Chebit.Ledger` | Double entry, append-only. Each transaction sums to zero per currency. |
| Holds | `Chebit.Ledger` | Available balance (`balance - held`) is never negative. |
| Ledger audit | `Chebit.Ledger.Audit` | Recomputes each balance from the postings, each hour. |
| State machine | `Chebit.Payments.StateMachine` | One machine for every provider. Terminal statuses never change. |
| Payments | `Chebit.Payments` | Intent, confirm, sync. One step, one database transaction. |
| Idempotency | `Chebit.Idempotency` | The same key has one effect and gets the first answer. |
| Provider contract | `Chebit.Providers.Provider` | One interface for each rail. A payment is created once. |
| Simulated provider | `Chebit.Providers.Simulated` | Plays the provider and the payer, with faults on demand. |
| Webhook inbox | `Chebit.Webhooks` | Raw body stored, deduplicated, safe against late and repeated events. |
| Outbox | `Chebit.Outbox` | An event commits with its change, and is published at least once. |
| Reconciliation | `Chebit.Reconciliation` | Provider against ledger, to zero. Custody covers what is owed. |
| API | `ChebitWeb` | REST, Bearer key, `Idempotency-Key`. See `docs/openapi.yaml`. |

The database enforces the money rules on its own, with constraints and triggers. See
`priv/repo/migrations/` and `docs/adr/0005-ledger-model.md`.

## The payment flow

```
POST /v1/payment_intents            created
POST /v1/payment_intents/:id/confirm  pending   (the provider returns a QR)
        the payer pays
POST /webhooks/:provider            paid      (merchant credited, amount held)
                                    final     (hold released)
```

A webhook is only a signal. The processor asks the provider for the current state and
applies each missing step in order (`docs/adr/0007-...`).

## Try the API

```bash
mise run setup
mise exec -- mix run -e '{:ok, %{api_key: key}} = Chebit.Merchants.create_merchant(%{name: "Mi parrilla", fee_bps: 250}); IO.puts(key)'
mise run server
```

In another terminal, with the key that the second command printed:

```bash
KEY=chebit_sk_...
curl -s localhost:4000/v1/payment_intents \
  -H "authorization: Bearer $KEY" -H "idempotency-key: order-1" -H "content-type: application/json" \
  -d '{"amount_minor": 1500000, "currency": "ARS", "description": "Mesa 4"}'
```

Send the same request again: the answer is the same, with the header
`idempotent-replayed: true`. Change the amount and keep the key: the answer is 409.
Amounts are integers in the smallest unit: 1500000 is ARS 15.000,00.

## How it is implemented

Elixir, Phoenix and Postgres. Background jobs run on Oban, in the same database.
There is no process per payment: the state of each payment lives in Postgres
(`docs/adr/0004-...`). Each step is one database transaction.

```
HTTP API (ChebitWeb)
  Authenticate plug          Bearer API key  ->  merchant
  IdempotencyKey plug        stores the first answer per key
        |
Chebit.Payments              intent -> confirm -> sync, through the StateMachine
        |                        \
Chebit.Providers.Provider     Chebit.Ledger          double entry, holds
  Simulated (only one today)     Chebit.Outbox        event in the same transaction
        |                                 |
POST /webhooks/:provider              Outbox.PublishWorker  ->  sinks (PubSub)
  Chebit.Webhooks inbox  ->  ProcessWorker  ->  asks the provider, then Payments.sync
```

Background workers (Oban):

- `Chebit.Payments.ExpiryWorker` expires intents that were never paid.
- `Chebit.Webhooks.ProcessWorker` turns a stored webhook into state changes.
- `Chebit.Outbox.PublishWorker` publishes committed events, at least once.
- `Chebit.Ledger.AuditWorker` recomputes each balance from its postings, each hour.
- `Chebit.Reconciliation.Worker` compares the provider against the ledger.

Where to read first:

1. `lib/chebit/payments/state_machine.ex`: the statuses and the allowed moves. Pure functions.
2. `lib/chebit/ledger/rules.ex`: which postings each event makes. Pure functions.
3. `lib/chebit/payments.ex`: how a step locks, writes the ledger and the outbox, and commits.
4. `lib/chebit/idempotency.ex` and `lib/chebit_web/plugs/idempotency_key.ex`: the two layers (`docs/adr/0006-...`).
5. `priv/repo/migrations/`: the constraints and triggers that back each invariant in the database.

Tests mirror `lib/`. Property tests (StreamData) cover the invariants in `AGENTS.md`.
Tests that need a real COMMIT or real concurrency use `Chebit.UnboxedCase`.
The suite has 421 tests and 19 properties.

## Docs

- `docs/BRIEF.md`: the product brief.
- `docs/PLAN.md`: phases, workstreams, where each invariant lives, open questions.
- `docs/adr/`: the decisions, one file each.
- `docs/openapi.yaml`: the API.
- `AGENTS.md`: the rules for people and coding agents in this repo.

## License

MIT. See `LICENSE`.
