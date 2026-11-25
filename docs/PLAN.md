# Chebit: plan

The product brief is `docs/BRIEF.md`. This file turns it into phases and workstreams, and
it records what exists, what is next, and what Julián must decide.

## 1. Status

| Phase | Scope | State |
|---|---|---|
| 0 | Foundations: ledger, holds, idempotency, state machine, outbox, webhook inbox, provider contract, simulated provider | Built on 2026-11-20. Section 2. |
| 1 | Pilot merchant: universal QR, payout in pesos, ARCA invoice, reconciliation panel | Not started. Section 4. |
| 2 | More providers | Not started. |
| 3 | Bitcoin adoption for users | Not started. |
| 4 | Full merchant management, public platform, MCP server | Not started. |

## 2. Phase 0: what exists

| Component in the brief | Module | Notes |
|---|---|---|
| API gateway | `ChebitWeb.Router`, `ChebitWeb.Plugs.*`, `ChebitWeb.ApiError` | Bearer API key, `Idempotency-Key` header. No rate limit yet. |
| Payments service | `Chebit.Payments`, `Chebit.Payments.StateMachine` | Intents, attempts, one transaction per step. |
| Provider adapters | `Chebit.Providers.Provider` (contract), `Chebit.Providers.Simulated` | The simulator plays the provider and the payer. |
| Ledger service | `Chebit.Ledger`, `Chebit.Ledger.Rules`, `Chebit.Ledger.Audit` | The only writer of accounts, postings and holds. |
| Webhook inbox | `Chebit.Webhooks`, `Chebit.Webhooks.ProcessWorker` | Raw body stored, unique by `(provider, event_id)`. |
| Outbox publisher | `Chebit.Outbox`, `Chebit.Outbox.PublishWorker` | Event row and job commit with the change. |
| Reconciliation jobs | `Chebit.Reconciliation`, `Chebit.Reconciliation.Worker` | Provider against ledger, each hour. |
| Idempotency | `Chebit.Idempotency` | Key store plus natural keys (ADR 0006). |
| Quote/FX, invoicing, Lightning, signing, merchant app | none | Phase 1 and later. |

The API is in `docs/openapi.yaml`. The decisions are in `docs/adr/`.

### How the work was split

Contracts came first: the migration with its constraints, the schemas, the state machine,
the provider contract, and the public functions of each module with `@doc` and `@spec`.
Then the workstreams below ran against those contracts, each in its own set of files.

| Workstream | Scope | Who |
|---|---|---|
| Contracts | Schema, state machine, provider contract, module contracts, ADRs | orchestrator |
| A, ledger | `Chebit.Ledger`, rules, audit, their tests | agent |
| B1, idempotency and outbox | `Chebit.Idempotency`, `Chebit.Outbox`, their tests | agent |
| C, simulated provider | `Chebit.Providers.Simulated`; tests of the state machine, money, merchants | agent |
| B2, payments core | `Chebit.Payments`, `Chebit.Webhooks` | orchestrator |
| B3, verification | Tests of payments and webhooks, written by an agent that did not write the code | agent |
| E0, API | Web layer, API tests, OpenAPI | agent |
| R, reconciliation | `Chebit.Reconciliation`, its tests, `priv/demo.exs` | agent |

### What the verification found

The agent that tested the payments core did not write it. Its brief was to break the
contract. It found three things, and all three are fixed and now have tests:

- Two payments near the `bigint` maximum made Postgres raise inside a sync. The ledger
  rules now return `{:error, :balance_out_of_range}`.
- `Payments.create_intent/3` raised on a map with mixed atom and string keys. The HTTP
  path could not reach it.
- The expiry job could abandon an attempt while its confirm was still on the way to the
  provider. The job now waits 120 seconds after the expiry (ADR 0007).

Then a model of another family (Gemini, through Antigravity, read-only) reviewed the money
code. It reported 12 findings. Ten were new and real, and each one is fixed with a test:

- The expiry job could expire a payment that a confirm had just made live (critical).
- A slow request could delete or complete the idempotency row of the request that took
  its key over (critical). `locked_at` is now a fencing token.
- A retry of a confirm that worked got 409 when the payment had already moved on.
- The API read `provider` from the query string, which the idempotency hash did not cover.
- `"metadata": null` raised instead of giving a clean answer.
- A ledger replay ignored a different hold or `reverses_id`.
- A debit and a credit on the same account could capture a hold with no money leaving.
- A concurrent decline could be overwritten by a late provider answer. The attempt row is
  now locked.
- The expiry job could starve behind 500 intents that stay `pending`. It now pages.
- `Ledger.post/2` accepted a `reverses_id` with entries that were not the mirror.

Its other two findings overlapped with what the test agent had found. One of them added a
new case, a sum above the `bigint` range in `Reconciliation.coverage/0`, which is fixed too.

The state of the gate on 2026-11-20: format, compile with warnings as errors, credo
strict, dialyzer, and 418 tests with 19 properties and 2 doctests, 0 failures on three seeds.

## 3. Invariants: where each one lives

| # | Invariant | Application check | Database backstop | Tests |
|---|---|---|---|---|
| 1 | A ledger transaction sums to zero per currency | `Ledger.Rules.validate/1` | trigger `postings_balanced` | `test/chebit/ledger/rules_test.exs`, `properties_test.exs`, `db_constraints_test.exs` |
| 2 | The ledger is append-only | only `Ledger.post/2` and `Ledger.reverse/2` write | triggers `*_append_only` | `test/chebit/ledger/db_constraints_test.exs`, `ledger_test.exs` |
| 3 | Available balance is never negative | `Ledger.Rules.apply_entries/3`, row locks in id order | check `accounts_available_non_negative` | `test/chebit/ledger/concurrency_test.exs`, `properties_test.exs` |
| 4 | One effect per idempotency key | `Chebit.Idempotency.run/5`, natural keys | unique indexes | `test/chebit/idempotency_test.exs`, `idempotency/concurrency_test.exs`, `test/chebit_web/controllers/idempotency_race_test.exs` |
| 5 | A payment reaches the provider once in effect | attempt id is the provider's idempotency key; attempt row commits before the call | unique index `payment_attempts_one_live_per_intent` | `test/chebit/payments_test.exs`, `payments/concurrency_test.exs`, `providers/simulated_test.exs` |
| 6 | Terminal statuses do not change; steps go forward | `Payments.StateMachine`, conditional update | trigger `payment_intents_terminal_status` | `test/chebit/payments/state_machine_test.exs`, `properties_test.exs`, `db_constraints_test.exs` |
| 7 | No float holds money | `Money.valid_amount?/1`, integer cast | `bigint` columns, checks `*_amount_positive` | `test/chebit/money_test.exs`, `ledger/rules_test.exs`, `test/chebit_web/controllers/payment_intent_controller_test.exs` |
| 8 | Custody covers what the ledger owes | `Reconciliation.coverage/0` | none: the funds are outside the database | `test/chebit/reconciliation_test.exs` |
| 9 | Each sale has an ARCA invoice or is marked pending | Phase 1 | Phase 1 | none yet |

Checks that run on stored data in production: `Chebit.Ledger.AuditWorker` (1, 3, cache
drift) and `Chebit.Reconciliation.Worker` (provider against ledger), each hour.

## 4. Phase 1: workstreams

Order: 1G can start now. The others wait for the item in "Needs".

| # | Workstream | What | Needs |
|---|---|---|---|
| 1G | End to end with a simulated restaurant | Sale in Lightning, payout in pesos, invoice, ledger balanced, all with simulated adapters. It proves the saga and the invoice rule before any credential exists. | nothing |
| 1C | Quotes and settlement saga | `fx_quotes` with expiry; `settlements`; a saga log with idempotent steps (saga id + step number) and compensation entries; sell BTC, credit ARS. | question 4 (who takes the FX risk); partner API for the real adapter (question 3) |
| 1D | ARCA invoicing | `invoices` table; WSFE client in homologation; CAE; invariant 9 with a "pending invoice" status and a retry job. | a CUIT and a test certificate from ARCA |
| 1A | Real adapters | Mercado Pago, Transferencias 3.0, Lightning through a managed provider (ADR 0003). Each one implements `Chebit.Providers.Provider`. | sandbox credentials; questions 2 and 3 |
| 1B | Universal QR | One intent, one live attempt for each rail. The first payment wins. A second payment on another rail is refunded. The unique index changes to `(payment_intent_id, provider)`. | 1A |
| 1E | Merchant app | Phoenix LiveView: point of sale, QR, reconciliation panel, invoices. It reads the same contexts and listens to the outbox topics. | 1B |
| 1F | Platform | Rate limit, merchant-initiated refund, cleanup of old idempotency keys, a database role without UPDATE and DELETE on the ledger, deploy. | question 7 (hosting) |

Later phases keep the brief's scope. Phase 2 adds adapters only. Phase 3 adds user
accounts in BTC, the Rust Lightning and signing services, and on-chain withdrawals (the
tables `withdrawals`, `batches`, `utxos`). Phase 4 adds the merchant back office, SDKs, the
MCP server and routing between providers.

The map of merchants (Phase 3) has a first version on the landing: `landing/mapa.html`.
It reads the places of BTC Map in the browser and draws them with MapLibre on OpenFreeMap
tiles. It has no backend, no key and no cost. It does not show Chebit's own merchants and
does not write to BTC Map yet.

## 5. Defaults that this plan chose

Say so if you want another choice. Each one is small to change now.

1. **No process per payment** (ADR 0004). The brief describes one supervised process per
   payment. Phase 0 keeps the state in Postgres and runs each step in a short-lived
   supervised process. This is the one place where the build differs from the brief.
2. **Lightning through a managed provider first** (ADR 0003, proposed).
3. **Money that can still reverse is held** (ADR 0005). `paid` credits the merchant and
   holds the amount; `final` releases it.
4. **The fee comes out of the payment**, in basis points per merchant, rounded down.
   `fee_bps` defaults to 0 until question 5 has an answer.
5. **An intent lives 15 minutes.** After that it expires, unless a provider still holds it.
6. **REST with OpenAPI**, as the brief asks for a public API with 202 and 409 answers.
7. **English for code and docs.** The brief stays in Spanish.
8. **UUIDs for public ids, `bigserial` for ordered logs** (postings, events).
9. **A 5xx answer does not use up an idempotency key** (ADR 0006).

## 6. Open questions for Julián

From the brief:

1. Final name. Check INPI and the domains.
2. Own custody of Bitcoin in Phase 1, or only through a partner? ADR 0003 proposes: partner.
3. Partner to convert BTC and stablecoins to pesos.
4. Who takes the exchange-rate risk between the payment and the payout?
5. Merchant fees and the business model.
6. The pilot restaurants.
7. Hosting.

New, from the build:

8. A payer pays after our intent expired (or pays twice in the universal QR). Phase 0
   refuses the late payment, changes nothing and shows it in reconciliation. Should
   Phase 1 refund it at once, or credit the merchant?
9. Does a refund return the fee to the merchant? Phase 0 reverses the whole transaction,
   so the fee goes back too.
10. Lightning counts millisatoshis and the ledger counts satoshis. ADR 0003 rounds a
    routing fee up to one satoshi. Confirm, or the ledger moves to millisatoshis for BTC.
11. Is one process per payment a requirement (default 1)?

## 7. Known gaps in Phase 0

- A late payment for an expired intent is flagged, not refunded (question 8).
- No endpoint for a merchant to start a refund. A refund or a dispute arrives from the provider.
- No partial refund.
- No rate limit.
- A `pending` intent whose provider never expires it stays `pending`. Real adapters pass
  `expires_at` to the provider.
- A confirm whose provider call takes more than 120 seconds past the expiry can still
  create a payment for an intent that expired here. Reconciliation reports it.
- Idempotency keys are never deleted.
- One database role. The ledger tables rely on triggers, not on grants.
- The outbox keeps the order of events only on one node and without retries (ADR 0002).
- The simulator keeps its payments in memory. A restart of the server forgets them, and
  reconciliation then reports each open payment as missing at the provider.

## 8. Dependencies added

| Package | Reason |
|---|---|
| `oban` | Jobs and the outbox relay on Postgres (ADR 0002). |
| `stream_data` | Property tests for the invariants. Dev and test only. |
| `credo`, `dialyxir` | Lint and type checks in the gate. Dev and test only. |
| `phoenix_live_view`, `phoenix_html` | The dev dashboard at `/dashboard`: one server process per page, PubSub pushes, diffs. Dev routes only. The client JS is the prebuilt file in `priv/static/assets/`. No esbuild. |
| `lazy_html` | The HTML parser that `Phoenix.LiveViewTest` needs. Test only. |
