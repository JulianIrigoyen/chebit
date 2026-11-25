# Chebit handbook: payment practices and where each one lives

This handbook lists the practices of a professional payment system. For each practice it
gives the rule, the failure that the rule prevents, the exact place in Chebit that
implements it, the test that proves it, and the gaps.

- **State of the code:** Phase 0, read on 2026-11-20 between 01:57 and 02:09 ART. The review findings were tested again on the code of 02:31 ART.
- **Sources:** the code in `lib/`, the migrations in `priv/repo/migrations/`, the tests in
  `test/`, `docs/PLAN.md` and `docs/adr/`.
- **References** name a file and a function, not a line. Lines move.
- **Test counts** for one file come from a count of its `test` and `property` definitions
  at 02:09 ART. The whole suite ran in a lab copy of the code of 02:39 ART: 421 tests, 19
  properties and 2 doctests, with 0 failures.
- **Review findings** have the ids R1 to R7. Section "Review findings" at the end lists
  them with their evidence.
- **Keep it current.** When a gap closes, change its line here in the same change.
- **The landing** shows this file at `landing/handbook.html`. That page reads
  `landing/handbook-data.js`, a copy of this file. `test/chebit/handbook_test.exs` fails
  when the copy is old. After a change here, run this from the root of the repository:

      mise exec -- elixir -e 'File.write!("landing/handbook-data.js", "window.CHEBIT_HANDBOOK = " <> JSON.encode!(File.read!("docs/HANDBOOK.md")) <> ";\n")'

Status values:

- **Done**: built and tested. The gaps are small or recorded.
- **Partial**: a part of the practice is missing, or a review finding of severity High is open.
- **Not yet**: not built. The phase that builds it is named.

The MCP server in `mcp/chebit_mcp.exs` reads this file. It finds a practice by the heading
`### N. Title` and the line `**Status:**`. Keep that format.

## Map

| # | Practice | Status | Main module | Main proof |
|---|---|---|---|---|
| 1 | Integer money in the smallest unit | Done | `Chebit.Money` | `test/chebit/money_test.exs` |
| 2 | Double-entry ledger that sums to zero | Done | `Chebit.Ledger`, `Chebit.Ledger.Rules` | `test/chebit/ledger/rules_test.exs` |
| 3 | Append-only ledger, correction by reversal | Done | `Chebit.Ledger.reverse/2` | `test/chebit/ledger/db_constraints_test.exs` |
| 4 | Balances are derived, the cache is audited | Done | `Chebit.Ledger.Audit` | `test/chebit/ledger/audit_test.exs` |
| 5 | Holds: reserve before you promise | Done | `Chebit.Ledger.place_hold/1` | `test/chebit/ledger/concurrency_test.exs` |
| 6 | Locks in one order | Done | `Chebit.Ledger` | `test/chebit/ledger/concurrency_test.exs` |
| 7 | The database is the last guard | Done | the migration `create_payment_core` | both `db_constraints_test.exs` files |
| 8 | Idempotency keys on each write | Done | `Chebit.Idempotency` | `test/chebit/idempotency_test.exs` |
| 9 | Idempotent operations on natural keys | Done | unique indexes | `test/chebit/payments/concurrency_test.exs` |
| 10 | Payment intents | Done | `Chebit.Payments` | `test/chebit/payments_test.exs` |
| 11 | One send to the provider | Done | `Chebit.Payments.confirm_intent/3` | `test/chebit/providers/simulated_test.exs` |
| 12 | Transactional outbox | Partial | `Chebit.Outbox` | `test/chebit/outbox_test.exs` |
| 13 | Webhook inbox | Partial | `Chebit.Webhooks` | `test/chebit/webhooks_test.exs` |
| 14 | Sagas and compensation | Not yet | none | none |
| 15 | One explicit state machine | Done | `Chebit.Payments.StateMachine` | `test/chebit/payments/state_machine_test.exs` |
| 16 | State in the database, one step per transaction | Done | `Chebit.Payments` | `test/chebit/payments/concurrency_test.exs` |
| 17 | Paid is not final | Done | `Chebit.Payments` | `test/chebit/payments/properties_test.exs` |
| 18 | Expiry and timeouts | Partial | `Chebit.Payments.expire_due/1` | `test/chebit/payments/expiry_test.exs` |
| 19 | Reconciliation with each provider | Partial | `Chebit.Reconciliation` | `test/chebit/reconciliation_test.exs` |
| 20 | Checks that run in production | Partial | `Chebit.Ledger.AuditWorker` | `test/chebit/reconciliation/worker_test.exs` |
| 21 | Tests that attack the invariants | Done | `test/` | 421 tests, 19 properties |
| 22 | Provider adapters and a simulated provider | Partial | `Chebit.Providers.Provider` | `test/chebit/providers/simulated_test.exs` |
| 23 | Authentication and tenant isolation | Partial | `ChebitWeb.Plugs.Authenticate` | `test/chebit/merchants_test.exs` |
| 24 | Secrets | Partial | `config/runtime.exs` | none |
| 25 | Input validation and one error contract | Done | `ChebitWeb.ApiError` | `test/chebit_web/controllers/payment_intent_controller_test.exs` |
| 26 | Durable jobs with retries | Done | Oban, `config/config.exs` | `test/chebit/webhooks/outage_test.exs` |
| 27 | Observability and alerts | Partial | `ChebitWeb.Telemetry` | none |
| 28 | Rate limits | Not yet | none | none |
| 29 | API design and versions | Partial | `docs/openapi.yaml` | controller tests |
| 30 | Database changes and roles | Partial | `AGENTS.md` | none |
| 31 | Quality gate and decision records | Done | `bin/gate`, `docs/adr/` | the gate |
| 32 | FX quotes and settlement | Not yet | none | none |
| 33 | An invoice for each sale | Not yet | none | none |
| 34 | Custody, keys and on-chain payouts | Not yet | none | none |
| 35 | Compliance | Not yet | none | none |
| 36 | Backups and recovery | Not yet | none | none |
| 37 | Agent access through MCP | Partial | `mcp/chebit_mcp.exs` | a protocol check, see the section |

## Part 1. Money

### 1. Integer money in the smallest unit

**Status:** Done

**Rule.** An amount is an integer count of the smallest unit of its currency. A currency
always goes with it. No float and no Decimal holds money.

**Failure it prevents.** A float cannot store 0.1. Sums drift by one centavo, and the
ledger no longer balances.

**In Chebit.**

- `Chebit.Money` knows five currencies and their exponents: ARS 2, USD 2, BTC 8 (satoshi),
  USDT 6, USDC 6.
- `Money.valid_amount?/1` accepts a positive integer up to the `bigint` limit.
- `Money.fee_minor/2` computes a fee as `div(amount_minor * fee_bps, 10_000)`. It rounds
  down. The rounding rule is in one place.
- A field that holds an amount ends in `_minor`. Each amount column is `bigint`.
- The checks `postings_amount_positive`, `holds_amount_positive` and
  `payment_intents_amount_positive` refuse zero and negative amounts.
- The API takes `amount_minor` as a JSON integer. `Payments.create_intent/3` casts it as
  an integer and then calls `Money.valid_amount?/1`.

**Proof.** `test/chebit/money_test.exs` (17 definitions, 5 properties) and
`test/chebit/ledger/rules_test.exs`.

**Gaps.**

- R7, fixed by 02:31 ART: a balance that would leave the `bigint` range now gives
  `{:error, :balance_out_of_range}` from `Ledger.Rules.apply_entries/3`.
- The upper limit of one amount is still the `bigint` limit for each currency.
- Lightning counts millisatoshis and the ledger counts satoshis (`docs/PLAN.md`, question 10).
- A token with 18 decimals does not fit in `bigint`.

### 2. Double-entry ledger that sums to zero

**Status:** Done

**Rule.** Each movement of money is one transaction with two or more postings. For each
currency the debits equal the credits.

**Failure it prevents.** Money appears or vanishes, and nobody can say where.

**In Chebit.**

- `Chebit.Ledger.post/2` is the only function that writes postings. No other module
  writes accounts, transactions, postings or holds.
- `Ledger.Rules.validate/1` is pure. It demands two or more entries and a zero sum for
  each currency. The error is `:unbalanced`.
- The trigger `postings_balanced` runs after each `INSERT` statement on `postings`. It
  checks each transaction that the statement touched. One `INSERT` writes all the postings
  of a transaction, so the check needs no deferred constraint.
- The foreign key `postings (account_id, currency)` points at `accounts (id, currency)`.
  A posting therefore has the currency of its account.
- An account belongs to the house, a merchant or a user, and has a `kind` and a currency.
  One unique index covers the four columns, with `NULLS NOT DISTINCT` for the house.
- A balance is credits minus debits. The house account `clearing:<provider>` is negative
  when the provider holds money for Chebit.
- A paid payment debits `clearing:<provider>` by the full amount, credits the merchant
  account `balance` by the net amount, and credits the house account `fees` by the fee
  (`Payments.ledger_effect/3`).

**Proof.** `test/chebit/ledger/rules_test.exs` (40 definitions, 3 properties);
`test/chebit/ledger/db_constraints_test.exs` ("postings_balanced refuses an unbalanced
INSERT of postings", "postings_balanced refuses postings that balance only across
currencies"); `test/chebit/ledger/properties_test.exs` ("any sequence of operations keeps
the ledger audit clean").

**Gaps.**

- R5: the database accepts two more postings on an old transaction when they balance.

### 3. Append-only ledger, correction by reversal

**Status:** Done

**Rule.** Nobody edits or deletes a posting. A correction is a new transaction that
reverses the old one.

**Failure it prevents.** History changes, and an audit cannot rebuild a balance.

**In Chebit.**

- The triggers `postings_append_only` and `ledger_transactions_append_only` refuse each
  `UPDATE` and `DELETE`.
- `Ledger.reverse/2` writes the same postings with the direction swapped and sets
  `reverses_id`. Its source is `("ledger_transaction", id, "reversal")`.
- A partial unique index on `reverses_id` allows one reversal for each transaction.
- A reversal of a reversal is refused with `:invalid_request`.
- A refund uses it: `Payments.ledger_effect/3` for `:refunded` reverses the `payment_paid`
  transaction.

**Proof.** `test/chebit/ledger/db_constraints_test.exs` ("postings_append_only refuses
UPDATE and DELETE on postings") and `test/chebit/ledger_test.exs` (60 definitions).

**Gaps.**

- `TRUNCATE` is not blocked. The tests use it to clean up (`test/support/unboxed_case.ex`).
- There is one database role. `docs/adr/0005-ledger-model.md` records that production
  must remove UPDATE, DELETE and TRUNCATE from the application role.

### 4. Balances are derived, the cache is audited

**Status:** Done

**Rule.** The postings are the truth. A stored balance is a cache, and a job compares the
two.

**Failure it prevents.** A cached balance drifts, and the system pays out money that does
not exist.

**In Chebit.**

- `accounts.balance_minor` and `accounts.held_minor` are caches. `Ledger.post/2` updates
  them in the same database transaction as the postings.
- `Ledger.balance/1` and `Ledger.balances/1` read the cache. Available is
  `balance_minor - held_minor`.
- `Chebit.Ledger.Audit.run/0` runs five SQL checks: `:transaction_unbalanced`,
  `:balance_cache_mismatch`, `:held_cache_mismatch`, `:negative_available` and
  `:currency_not_zero`.
- `Chebit.Ledger.AuditWorker` runs the audit each hour, at minute 7.

**Proof.** `test/chebit/ledger/audit_test.exs` (8 definitions). Each check has a test that
breaks the data on purpose.

**Gaps.**

- No constraint ties a cache to the postings. The audit finds a drift up to one hour later.
- Each run reads all postings. This needs a checkpoint when the table grows.

### 5. Holds: reserve before you promise

**Status:** Done

**Rule.** Reserve the money in one atomic step before any asynchronous work. The available
balance never goes below zero.

**Failure it prevents.** Two requests spend the same balance.

**In Chebit.**

- `Ledger.place_hold/1` locks the account, checks that available covers the amount, raises
  `held_minor` and inserts the hold. It is idempotent on `(source_type, source_id)`.
- `Ledger.release_hold/1` ends a hold and makes the amount available again.
- `Ledger.post/2` and `Ledger.reverse/2` take `capture_hold: hold_id`. The transaction
  must debit the account of the hold by exactly the amount of the hold. If not, the error
  is `:hold_mismatch`.
- The check `accounts_available_non_negative` refuses a merchant or user account with
  `balance_minor - held_minor < 0`. A house account has no floor.
- The trigger `holds_terminal_status` refuses a change of a `captured` or `released` hold.
- Payments use holds: `paid` credits the merchant and holds the net amount, `final`
  releases the hold, `refunded` captures it.

**Proof.** `test/chebit/ledger/concurrency_test.exs` ("30 holds of 10 on an available
balance of 100: 10 succeed", "release_hold raced against a capture: exactly one wins each
time"). These tests use real connections.

**Gaps.**

- No partial capture and no expiry of a hold.
- R5: the database accepts a change of `amount_minor` on an active hold.

### 6. Locks in one order

**Status:** Done

**Rule.** A write to a balance takes a row lock. Each transaction takes its locks in the
same order.

**Failure it prevents.** A lost update, or a deadlock between two transfers.

**In Chebit.**

- `Ledger.lock_accounts/1` runs `SELECT ... ORDER BY id FOR UPDATE` on each account of the
  transaction. The hold row comes after the accounts.
- `Payments.lock_intent/2` locks the intent row first. Two workers on one intent run one
  after the other.
- The rule is in `AGENTS.md`: account rows in ascending id order, then the hold row.
- No provider call runs inside a database transaction, so a lock lives for milliseconds.

**Proof.** `test/chebit/ledger/concurrency_test.exs` ("transfers A to B and B to A raced
20 and 20 do not deadlock", "30 debits of 10 against a balance of 100: 10 succeed, 20 are
refused").

**Gaps.**

- The order holds inside one call. A caller that posts twice in one database transaction,
  with different accounts, can break it. Phase 0 has no such caller.
- The house accounts `fees` and `clearing:<provider>` are hot rows
  (`docs/adr/0005-ledger-model.md`).

### 7. The database is the last guard

**Status:** Done

**Rule.** The application checks first and returns an error. A constraint in the database
refuses the same mistake when the application has a bug.

**Failure it prevents.** One wrong code path writes bad money data, and nothing stops it.

**In Chebit.** The migration `create_payment_core` holds each guard:

- Triggers: `postings_balanced`, `postings_append_only`, `ledger_transactions_append_only`,
  `payment_intents_terminal_status`, `holds_terminal_status`.
- Checks: `accounts_available_non_negative`, `accounts_held_non_negative`,
  `accounts_house_has_no_owner`, `postings_amount_positive`, `holds_capture_has_transaction`,
  `payment_attempts_dispatched_has_external_id`, and a list of valid values for each status
  and currency column.
- Unique indexes: one for each natural key in practice 9.
- A statement that fails on a constraint aborts the whole Postgres transaction. The code
  therefore uses `on_conflict: :nothing` and reads the row (`Chebit.Ledger` moduledoc).

**Proof.** `test/chebit/ledger/db_constraints_test.exs` (16 definitions) and
`test/chebit/payments/db_constraints_test.exs` (4 definitions). They write raw SQL against
each guard.

**Gaps.**

- R5: the database guards terminal statuses only. It accepts `paid` to `created`, a new
  amount on a paid intent, and a new amount on an active hold. `AGENTS.md` says that the
  database enforces each invariant; for the forward-only half of invariant 6 it does not.

## Part 2. One effect

### 8. Idempotency keys on each write

**Status:** Done

**Rule.** A client sends a key with each write. The same key and the same request give
the first response again. The same key with another request, or while the first request
runs, gives 409.

**Failure it prevents.** A retry after a timeout charges twice.

**In Chebit.**

- `ChebitWeb.Plugs.IdempotencyKey` demands the header `idempotency-key`, 1 to 255
  characters, on both POST endpoints. Without it the answer is 400
  `idempotency_key_required`.
- `Chebit.Idempotency.run/5` inserts the key row as `processing`, runs the function
  outside any database transaction, stores the response and marks the row `completed`.
- The table `idempotency_keys` is unique on `(merchant_id, key)`.
- `Idempotency.request_hash/3` hashes the method, the path and the decoded body.
- Same key, same hash: the stored response, with the header `idempotent-replayed: true`.
- Same key, other hash: 409 `idempotency_key_reused`. Same key in flight: 409
  `request_in_progress`.
- A response of 500 or above is not stored. A function that raises deletes the row. The
  client can retry with the same key.
- A row that is `processing` for more than 30 seconds belongs to a dead request. The next
  retry takes it over (`docs/adr/0006-idempotency-in-two-layers.md`).

**Proof.** `test/chebit/idempotency_test.exs` (10 definitions; the property "fun runs once
per key and each same-body retry gets the first response");
`test/chebit/idempotency/concurrency_test.exs` (30 concurrent callers);
`test/chebit_web/controllers/idempotency_race_test.exs` ("20 concurrent identical creates
make one intent").

**Gaps.**

- R4, fixed by 02:31 ART: `locked_at` is now the fencing token of the owner. A request
  that lost its row to a take-over can no longer delete or complete that row.
- Keys are never deleted (`docs/PLAN.md`, section 7).
- The hash uses `:erlang.term_to_binary/2` with `:deterministic`. The OTP documentation
  promises a stable encoding inside one OTP major release only. This handbook did not
  re-check that text. A raw-body hash has no such limit.

### 9. Idempotent operations on natural keys

**Status:** Done

**Rule.** Each operation is safe to run twice by itself. A unique index on its natural key
backs that.

**Failure it prevents.** The key store has a hole (a take-over, a 5xx), and the operation
then runs twice with two effects.

**In Chebit.** Each natural key has a unique index:

- An intent: `(merchant_id, idempotency_key)`.
- A live attempt: one for each intent (`payment_attempts_one_live_per_intent`).
- A ledger transaction: `(source_type, source_id, kind)`.
- A hold: `(source_type, source_id)`.
- A provider event: `(provider, event_id)`.
- A provider payment: `(provider, external_id)`.

A repeated ledger call compares content. `Ledger.Rules.same_entries?/2` gives the first
result for an equal request and `:source_conflict` for a different one.

**Proof.** `test/chebit/ledger/concurrency_test.exs` ("the same post raced 20 times writes
one transaction"); `test/chebit/payments/concurrency_test.exs` ("20 concurrent
create_intent calls with one key make one intent and one event").

**Gaps.** None found.

### 10. Payment intents

**Status:** Done

**Rule.** The server creates the intent and returns its id. The client confirms that id.
A retry uses the same intent.

**Failure it prevents.** Each retry of "pay" makes a new payment.

**In Chebit.**

- `POST /v1/payment_intents` calls `Payments.create_intent/3` and answers 201.
- `POST /v1/payment_intents/{id}/confirm` calls `Payments.confirm_intent/3` and answers 202.
- `GET /v1/payment_intents/{id}` shows the status and `next_action`, which holds the
  provider and the `payment_data` that the payer needs.
- An intent lives 15 minutes (`@intent_ttl_seconds`).
- A second confirm with the same provider sends nothing new. A confirm with another
  provider while an attempt is live gives 409 `invalid_state`.

**Proof.** `test/chebit/payments_test.exs` (54 definitions) and
`test/chebit_web/controllers/payment_intent_controller_test.exs` (19 definitions).

**Gaps.**

- R6: the intent does not store the fee. `ledger_effect/3` reads `fee_bps` from the
  merchant row when the payment is paid. A change of the fee between create and paid
  changes the fee of an intent that already exists.
- No endpoint to cancel an intent and no endpoint to list intents.

### 11. One send to the provider

**Status:** Done

**Rule.** Write the intention to the database first. Then call the provider with a key
that the provider treats as idempotent. Never call a provider inside a database
transaction. A timeout means "unknown", not "failed".

**Failure it prevents.** A lost reply, then a retry, then two payments at the provider.

**In Chebit.**

- `Payments.open_attempt/3` commits the attempt row under the intent lock.
- `Payments.dispatch/3` then calls `provider.create_payment/1` outside any transaction.
- The attempt id is the `reference`. The contract in `Chebit.Providers.Provider` demands
  that a second call with the same reference returns the first payment.
- `{:error, :declined}` means that no payment exists. The attempt fails and the intent
  stays `created`.
- `{:error, :unavailable}` means that the outcome is unknown. The attempt stays
  `initiated`, the API answers 503, and the retry sends the same reference.
- A webhook can never arrive before its attempt row exists, because the row commits first.

**Proof.** `test/chebit/payments/concurrency_test.exs` ("20 concurrent confirms of one
intent make one attempt and one provider payment");
`test/chebit/providers/simulated_test.exs` (":unavailable_after creates the payment, and a
retry gets it once (invariant 5)"); `test/chebit/payments/expiry_test.exs` ("an initiated
attempt whose reply was lost: the provider payment exists, the intent follows it").

**Gaps.**

- No job retries an `initiated` attempt. The client retries, or the expiry sweep reads the
  provider after 15 minutes.
- `Payments.apply_payment/2` reads the attempt row before it takes the intent lock. A
  re-read after the lock removes a small race.

### 12. Transactional outbox

**Status:** Partial

**Rule.** Write the event in the same database transaction as the change. A separate
worker publishes it. Delivery is at least once, and each consumer drops duplicates.

**Failure it prevents.** The change commits and the event is lost, or the event goes out
and the change rolls back.

**In Chebit.**

- `Chebit.Outbox.emit/1` writes the event row and one Oban job in the transaction of the
  caller. Outside a transaction it refuses with `{:error, :not_in_transaction}`.
- `Chebit.Outbox.PublishWorker` skips an event that has `published_at`, calls the sink, and
  then stamps `published_at` with a conditional update. It tries up to 20 times.
- `Chebit.Outbox.Sink` is the contract of a sink. `Chebit.Outbox.PubSubSink` publishes
  `{:chebit_event, event}` on the topics `events` and
  `events:<aggregate_type>:<aggregate_id>`.
- Each step of an intent emits `payment_intent.<status>` (`Payments.emit/1`).
- A consumer drops a duplicate by `event.id`.

**Proof.** `test/chebit/outbox_test.exs` (5), `test/chebit/outbox/publish_worker_test.exs`
(5), `test/chebit/outbox/pub_sub_sink_test.exs` (1).

**Gaps.**

- The only sink is in memory. No durable consumer exists. Webhooks to merchants are Phase 1.
- A job that uses its 20 attempts leaves the event without `published_at`.
  `Outbox.pending/0` lists such events, and no job calls it.
- The order of events holds for one aggregate, not across aggregates.

### 13. Webhook inbox

**Status:** Partial

**Rule.** Check the signature on the raw bytes. Store the event as it arrived. Drop a
duplicate by the event id. Answer fast and process later. Treat the event as a signal and
read the current state from the provider.

**Failure it prevents.** A forged, repeated, late or out-of-order event moves money.

**In Chebit.**

- `ChebitWeb.CacheBodyReader` keeps the exact request bytes.
  `ChebitWeb.WebhookController.create/2` passes them to `Webhooks.ingest/3`.
- `provider.verify_webhook/2` checks the signature. A bad signature is not stored and gets
  401. The simulator signs with HMAC-SHA256 and compares with
  `Plug.Crypto.secure_compare/2`.
- `Webhooks.ingest/3` inserts into `provider_events`, unique on `(provider, event_id)`, and
  queues one `ProcessWorker` job in the same transaction. A duplicate gets 200 and no job.
- `Webhooks.process/1` calls `Payments.sync_attempt/1`. That function reads the payment
  from the provider and applies each missing step from `StateMachine.path/2`.
- An outage keeps the event `received`, and Oban tries again, up to 10 times.
- The decision is in `docs/adr/0007-the-provider-is-the-truth-for-a-payment-in-flight.md`.

**Proof.** `test/chebit/webhooks_test.exs` (18); `test/chebit/webhooks/outage_test.exs` (4);
`test/chebit_web/controllers/webhook_controller_test.exs` (8);
`test/chebit/payments/properties_test.exs` ("any control sequence and any webhook delivery
order end in the provider state with a consistent ledger");
`test/chebit/payments/concurrency_test.exs` ("20 concurrent ingests of one delivery store
one row, accept once, enqueue one job").

**Gaps.**

- R2: a webhook that is lost after the intent is `paid` is never repaired. See practice 19.
- R3: `Webhooks.sync/1` marks an event `failed` for each error except an outage. Two syncs
  of one attempt can interleave. The older provider answer then gives
  `:invalid_transition`, and a good event becomes `failed`. The intent is correct.
- An event whose job uses its 10 attempts stays `received`. No job picks it up again.
- The inbox does not store the request headers.

### 14. Sagas and compensation

**Status:** Not yet (Phase 1, workstream 1C in `docs/PLAN.md`)

**Rule.** An operation across two systems is a list of steps. Each step is idempotent on
the saga id and the step number. A failed saga runs compensation entries.

**Failure it prevents.** A sale in BTC is collected, the sale of the BTC fails, and the
merchant is credited in pesos anyway.

**In Chebit.** Nothing yet. Phase 0 has no operation that spans two systems after the
payment. The ledger sources and `Ledger.reverse/2` are the parts that a saga will use.

**Proof.** None.

**Gaps.** The whole practice.

## Part 3. State

### 15. One explicit state machine

**Status:** Done

**Rule.** One table of transitions for each provider. A terminal status never changes. A
step only moves forward. The detail of a failure is a code in a field, not a new status.

**Failure it prevents.** A late event moves a refunded payment back to paid.

**In Chebit.**

- `Chebit.Payments.StateMachine` holds the table: `created` to `pending`, `failed`,
  `expired`; `pending` to `paid`, `failed`, `expired`; `paid` to `final`, `refunded`,
  `disputed`; `disputed` to `final`, `refunded`.
- `final`, `failed`, `expired` and `refunded` are terminal.
- `StateMachine.transition/2` checks one step. `StateMachine.path/2` gives the shortest
  list of steps between two statuses.
- `Payments.put_status/3` updates with a condition on the old status.
- `failure_reason` holds a code: the reason from the provider, `provider_failed`,
  `expired`, `refunded` or `dispute_lost`.
- The trigger `payment_intents_terminal_status` refuses a change of a terminal status.

**Proof.** `test/chebit/payments/state_machine_test.exs` (16 definitions, 5 properties);
`test/chebit/payments/db_constraints_test.exs` ("refuses each change of status from each
terminal status").

**Gaps.**

- R5: the database accepts a backward step between two statuses that are not terminal.
- `final` has no exit. A refund after `final` needs a new object in a later phase.

### 16. State in the database, one step per transaction

**Status:** Done

**Rule.** The state of a payment lives in the database. One step is one database
transaction: lock, check, ledger effect, new status, event.

**Failure it prevents.** A process dies with the only copy of the state, or a crash
between two writes leaves a status without its money.

**In Chebit.**

- `Payments.apply_step/3` runs inside the transaction of `apply_payment/2`. It checks the
  step, writes the ledger effect, updates the status and emits the event.
- Asynchronous work runs in Oban jobs. Each job is a supervised process.
- The brief asked for one process per payment.
  `docs/adr/0004-payment-state-in-postgres-no-process-per-payment.md` records why Phase 0
  differs.

**Proof.** `test/chebit/payments/concurrency_test.exs` ("20 concurrent syncs of a paid
payment post one transaction, one hold, one event").

**Gaps.** None found.

### 17. Paid is not final

**Status:** Done

**Rule.** `paid` means that the provider accepted the payment and can still reverse it.
`final` means that it cannot. The merchant can use the money only at `final`.

**Failure it prevents.** The merchant withdraws the money of a card payment, and a
chargeback arrives a month later.

**In Chebit.**

- The moduledoc of `Chebit.Providers.Provider` maps each rail: Lightning and Transferencias
  3.0 reach `paid` and `final` together; a card reaches `final` when the chargeback window
  ends; on-chain reaches `final` after N confirmations.
- `paid`: credit the merchant, credit the fee, and hold the net amount.
- `disputed`: no entry. The hold stays.
- `final`: release the hold.
- `refunded`: reverse the `payment_paid` transaction and capture the hold. The fee goes
  back too.
- `Simulated.pay/2` takes `:instant` or `:delayed`. `finalize/1`, `dispute/1` and
  `refund/1` play the rest.

**Proof.** `test/chebit/payments_test.exs` (the block `sync_attempt/1`) and
`test/chebit/payments/properties_test.exs`.

**Gaps.**

- No endpoint for a merchant to start a refund, and no partial refund.
- A payment that arrives after the intent expired is flagged and not refunded
  (`docs/PLAN.md`, question 8).
- Open decision: does a refund return the fee (`docs/PLAN.md`, question 9)?

### 18. Expiry and timeouts

**Status:** Partial

**Rule.** Each intent has a deadline. One side owns the decision that the deadline passed.

**Failure it prevents.** An abandoned payment stays open, or Chebit expires an intent
that the payer is paying.

**In Chebit.**

- `expires_at` is 15 minutes after the intent is created. The provider receives it in
  `create_payment/1`.
- `Chebit.Payments.ExpiryWorker` runs each minute and calls `Payments.expire_due/1`.
- An intent with no live attempt expires at once (`expire_locally/2`).
- An intent with a live attempt belongs to the provider. The job syncs with the provider.
  When the provider has no such payment and never confirmed the attempt, the intent
  expires after a grace period. When the provider reports `pending`, the intent stays
  `pending`.
- One call visits each due intent once, in pages of 500.

**Proof.** `test/chebit/payments/expiry_test.exs` (14 definitions).

**Gaps.**

- R1, fixed in part by 02:31 ART: the job now reads each page of due intents, so 500 stuck
  intents no longer hide a newer one. What remains: an intent that the provider keeps
  `pending` is synced again each minute, forever. The simulator ignores `expires_at`, so
  each abandoned confirmed intent in development is one of them.
- The job is not unique. A run that takes more than one minute queues behind the next one.
- `docs/PLAN.md` section 7 records the first half: a `pending` intent whose provider never
  expires it stays `pending`.

## Part 4. Proof

### 19. Reconciliation with each provider

**Status:** Partial

**Rule.** A job compares the ledger with each provider, payment by payment and total by
total. The difference must be zero. The funds in custody must cover the debt to users.

**Failure it prevents.** The ledger says that a provider holds money that the provider
does not hold.

**In Chebit.**

- `Chebit.Reconciliation.run/1` compares `provider.list_payments/0` with the attempts and
  intents. The kinds of difference are `:missing_in_ledger`, `:missing_at_provider`,
  `:amount_mismatch` and `:status_mismatch`.
- It compares totals for each currency: the provider's payments in `paid`, `disputed` or
  `final` against minus the balance of `clearing:<provider>`.
- `Reconciliation.coverage/0` checks invariant 8: custody is at least the sum of the
  merchant and user balances.
- `Chebit.Reconciliation.Worker` runs `run_all/0` each hour, at minute 17, and logs an error.

**Proof.** `test/chebit/reconciliation_test.exs` (18 definitions, 1 property) and
`test/chebit/reconciliation/worker_test.exs` (3).

**Gaps.**

- R2: reconciliation detects a `:status_mismatch` and repairs nothing. After a lost
  `final` webhook the intent stays `paid` and the money of the merchant stays held. One
  call to `Payments.sync_attempt/1` repairs it. No job makes that call for a `paid` intent.
- No job calls `coverage/0`. `AGENTS.md` says that the ledger audit checks invariant 8. The
  audit proves that the ledger sums to zero. Only `coverage/0` reads the custody side.
- A payment in flight can show as a mismatch for a moment.
- Each run reads all attempts and all provider payments. A real provider needs a window.

### 20. Checks that run in production

**Status:** Partial

**Rule.** The invariants are checked on the stored data all the time, not only in tests.

**Failure it prevents.** A bug in production breaks an invariant, and the first person
who sees it is a merchant.

**In Chebit.**

- `Chebit.Ledger.AuditWorker`: each hour. A violation gives a log line at error level and
  a failed job.
- `Chebit.Reconciliation.Worker`: each hour. Same behaviour.
- Both use `max_attempts: 1`, so a failure is one signal.

**Proof.** `test/chebit/reconciliation/worker_test.exs` and `test/chebit/ledger/audit_test.exs`.

**Gaps.**

- The alert is a log line. Nothing sends it to a person.
- Invariant 8 has no scheduled check (practice 19).

### 21. Tests that attack the invariants

**Status:** Done

**Rule.** Each invariant has a test that fails when the invariant breaks. Random
sequences, real concurrency and injected faults do the attack.

**Failure it prevents.** The tests only show that the happy path works.

**In Chebit.**

- Properties with StreamData: 19, in the money, ledger, state machine, idempotency,
  payments, simulator and reconciliation tests.
- Real concurrency: `Chebit.UnboxedCase` gives each process its own connection and a real
  commit. `race/1` starts the processes at one gate.
- Database guards: the two `db_constraints_test.exs` files write raw SQL.
- Faults: the simulator declines, loses a reply, or is down (practice 22).
- Verification by another author: `docs/PLAN.md` workstream B3. An agent that did not
  write the payments code wrote its tests.
- `bin/t` lets one test run happen at a time. The tests that truncate tables need that.

**Proof.** The test tree. On the code of 02:39 ART: 421 tests, 19 properties and 2 doctests.

**Gaps.**

- The seven review findings had no failing test. `test/review/findings_test.exs` in the
  review lab reproduces each one. It is not in this repository.

### 22. Provider adapters and a simulated provider

**Status:** Partial

**Rule.** Each provider sits behind one contract. A simulated provider implements the same
contract and can fail on demand.

**Failure it prevents.** The core depends on one provider, and nobody can test a lost
reply.

**In Chebit.**

- `Chebit.Providers.Provider` has four callbacks: `create_payment/1`, `fetch_payment/1`,
  `verify_webhook/2` and `list_payments/0`.
- `Chebit.Providers.fetch/1` finds an adapter in the config map `:providers`. An unknown
  name fails closed. Production starts with an empty map.
- `Chebit.Providers.Simulated` is a GenServer that keeps payments in memory.
- Its controls play the payer and the network: `pay/2`, `finalize/1`, `fail/2`, `expire/1`,
  `dispute/1`, `refund/1`.
- Its faults: `fault_next_create/2` with `:decline`, `:unavailable_before` or
  `:unavailable_after`, and `set_outage/1`.
- Each control returns a signed webhook. The caller delivers it, so a test can deliver it
  twice, late or never.

**Proof.** `test/chebit/providers/simulated_test.exs` (46 definitions, 2 properties) and
`test/chebit/providers/simulated_global_test.exs` (6).

**Gaps.**

- No real adapter yet (Phase 1, workstream 1A).
- `list_payments/0` has no window and no pages.
- `Chebit.Application` starts the simulator after Oban and the endpoint. A job in the
  first moment after boot can call a simulator that is not up.
- A restart forgets the simulated payments (`docs/PLAN.md`, section 7).

## Part 5. Platform

### 23. Authentication and tenant isolation

**Status:** Partial

**Rule.** Each request proves who sends it. Each read and each write is limited to that
merchant. A secret is stored as a hash.

**Failure it prevents.** One merchant reads or confirms the payment of another.

**In Chebit.**

- `ChebitWeb.Plugs.Authenticate` reads `authorization: Bearer <key>`. Anything else is 401.
- `Chebit.Merchants.create_merchant/1` makes the key `chebit_sk_` plus 32 random bytes. It
  returns the key once and stores the SHA-256.
- `Merchants.authenticate/1` looks the merchant up by the hash.
- Each query takes the merchant id: `Payments.fetch_intent/2`, `Payments.lock_intent/2`,
  `Ledger.balances/1`, and the idempotency key.
- `ChebitWeb.IntentJSON` never shows the merchant id, the key or the attempt internals.
- A webhook is authenticated by its signature, not by an API key.

**Proof.** `test/chebit/merchants_test.exs` (16) and
`test/chebit_web/controllers/payment_intent_controller_test.exs` (19).

**Gaps.**

- One key for each merchant. No rotation, no revocation and no scopes.
- No rate limit (practice 28).

### 24. Secrets

**Status:** Partial

**Rule.** A secret comes from the environment at run time. The repository holds none.

**Failure it prevents.** A key in git history.

**In Chebit.**

- `config/runtime.exs` reads `DATABASE_URL` and `SECRET_KEY_BASE` from the environment in
  production.
- `config/dev.exs` and `config/test.exs` hold the webhook secret of the simulator. Those
  values protect nothing real, and production has no simulator.
- API keys are stored as hashes (practice 23).

**Proof.** None.

**Gaps.**

- No secret store. Phase 1 needs one for provider credentials and the ARCA certificate.

### 25. Input validation and one error contract

**Status:** Done

**Rule.** Outside input is checked at the edge. Each error has a stable code. The client
never sees an internal reason.

**Failure it prevents.** A bad input reaches the ledger, or an error text leaks a detail.

**In Chebit.**

- `Payments.create_intent/3` uses a changeset: `amount_minor` and `currency` are required,
  the amount passes `Money.valid_amount?/1`, the description has 500 characters or fewer.
- `Ledger.Rules.validate/1` accepts any term and never raises.
- `ChebitWeb.ApiError.to_response/1` is the one map from a domain error to a status and
  the body `{"error": {"code", "message"}}`.
- The codes: 400 `idempotency_key_required`, 401 `unauthorized`, 404 `not_found`, 409
  `invalid_state`, 409 `idempotency_key_reused`, 409 `request_in_progress`, 422
  `invalid_request`, 422 `unknown_provider`, 422 `provider_declined`, 503
  `provider_unavailable`.
- An error that the map does not know gives 500 `internal_error` and a log line.

**Proof.** `test/chebit/payments_test.exs` (the block "rejected input") and the controller
tests.

**Gaps.** None found.

### 26. Durable jobs with retries

**Status:** Done

**Rule.** Asynchronous work is a row in a durable queue. It commits with the change that
needs it. A worker retries with backoff.

**Failure it prevents.** A restart loses work that was only in memory.

**In Chebit.**

- Oban runs on Postgres (`docs/adr/0002-jobs-and-outbox-on-postgres.md`).
- Queues in `config/config.exs`: `outbox` 10, `webhooks` 10, `maintenance` 1.
- Attempts: `PublishWorker` 20, `ProcessWorker` 10, `ExpiryWorker` 3, `AuditWorker` 1,
  `Reconciliation.Worker` 1.
- Cron: expiry each minute, audit at minute 7, reconciliation at minute 17.
- The pruner deletes a finished job after 7 days.

**Proof.** `test/chebit/webhooks/outage_test.exs` and
`test/chebit/webhooks/process_worker_test.exs`.

**Gaps.**

- A discarded job has no sweep (practices 12 and 13).
- The cron workers are not unique (practice 18).

### 27. Observability and alerts

**Status:** Partial

**Rule.** Each request and each payment can be followed. A broken invariant reaches a
person.

**Failure it prevents.** A merchant reports a problem, and nobody can see what happened.

**In Chebit.**

- `Plug.RequestId` gives each request an id, and the logger prints it.
- `Plug.Telemetry` and the Phoenix default `ChebitWeb.Telemetry` emit request metrics.
- The outbox events are the history of an intent, one event for each status.
- The audit, the reconciliation and an unmapped API error log at error level.

**Proof.** None.

**Gaps.**

- No export of metrics, no alert route and no dashboard.
- No audit trail of who called what, beyond the request log.

### 28. Rate limits

**Status:** Not yet (Phase 1, workstream 1F in `docs/PLAN.md`)

**Rule.** Each key and each address has a limit of requests.

**Failure it prevents.** One client, or one attacker, takes the API down or guesses keys.

**In Chebit.** Nothing yet. The brief allows Redis for this, and never as a source of truth.

**Proof.** None.

**Gaps.** The whole practice.

### 29. API design and versions

**Status:** Partial

**Rule.** The API has a version, a written contract, and status codes that tell a client
what to do next.

**Failure it prevents.** A client cannot tell "retry", "do not retry" and "wait".

**In Chebit.**

- Each route is under `/v1` (`ChebitWeb.Router`). The contract is `docs/openapi.yaml`.
- 201 for a new intent, 202 for a confirm, 409 for a conflict, 503 for "retry with the
  same key".
- An amount is an integer. A time is ISO 8601.

**Proof.** The controller tests.

**Gaps.**

- No list endpoints and no pages.
- No webhooks to merchants and no SDK (Phase 4).

### 30. Database changes and roles

**Status:** Partial

**Rule.** A migration that ran is never edited. The application role has only the rights
that it needs.

**Failure it prevents.** Two environments with different schemas, or an application bug
that deletes ledger rows.

**In Chebit.**

- `AGENTS.md`: make a migration with `mix ecto.gen.migration`, and never edit one that ran.
- The migration `create_payment_core` has a `down`.

**Proof.** None.

**Gaps.**

- One database role (`docs/PLAN.md`, section 7 and workstream 1F).

### 31. Quality gate and decision records

**Status:** Done

**Rule.** One command decides whether a change is good. Each important decision has a
short record.

**Failure it prevents.** A warning or a failing test goes in unseen, and nobody remembers
why a design is as it is.

**In Chebit.**

- `bin/gate`: format, compile with warnings as errors, unused dependencies, Credo strict,
  Dialyzer, tests.
- `mise.toml` pins Erlang 27.3.4.19 and Elixir 1.18.6.
- `docs/adr/` has seven records. `docs/PLAN.md` has the phases, the defaults and the open
  questions.
- `mise run demo` runs three payments end to end in a fresh database.

**Proof.** The gate.

**Gaps.**

- No CI. CI costs money, so that is a decision for the founder.

## Part 6. Not built yet

### 32. FX quotes and settlement

**Status:** Not yet (Phase 1, workstream 1C)

**Rule.** A quote has a rate and a deadline. A conversion uses the quote that the payer
saw. A contract says who takes the rate risk.

**Failure it prevents.** The rate moves between the payment and the payout, and nobody
knows who pays the difference.

**In Chebit.** Nothing yet. Open questions 3 and 4 in `docs/PLAN.md` block it.

**Proof.** None.

**Gaps.** The whole practice.

### 33. An invoice for each sale

**Status:** Not yet (Phase 1, workstream 1D)

**Rule.** Each sale has an invoice in ARCA or is marked as pending. This is invariant 9 of
the brief.

**Failure it prevents.** A merchant sells without an invoice.

**In Chebit.** Nothing yet. It needs a CUIT and a test certificate.

**Proof.** None.

**Gaps.** The whole practice.

### 34. Custody, keys and on-chain payouts

**Status:** Not yet (Phase 3)

**Rule.** Keys live in an HSM or a KMS. A hot wallet has limits. A signed transaction is
stored with its txid and its UTXOs before it is sent. After a crash the same transaction
is sent again, never a new one.

**Failure it prevents.** A double payout on-chain, or a stolen key.

**In Chebit.** Nothing yet. `docs/adr/0003-lightning-through-a-managed-provider-first.md`
proposes a partner first, so Phase 1 holds no keys.

**Proof.** None.

**Gaps.** The whole practice.

### 35. Compliance

**Status:** Not yet (needs the founder's lawyers)

**Rule.** The licence follows what the system does with funds: software only, custody of
pesos (PSP at the BCRA), custody or conversion of crypto (PSAV at the CNV). KYC and reports
to the UIF follow.

**Failure it prevents.** The product operates without the registration that it needs.

**In Chebit.** Nothing in code. Phase 0 holds no real funds.

**Proof.** None.

**Gaps.** The whole practice.

### 36. Backups and recovery

**Status:** Not yet (needs the hosting decision, question 7)

**Rule.** Postgres has point-in-time recovery, and a restore is practised.

**Failure it prevents.** The ledger is lost with the database.

**In Chebit.** Nothing yet. Postgres runs in a local container (`bin/db`).

**Proof.** None.

**Gaps.** The whole practice.

## Part 7. Agents

### 37. Agent access through MCP

**Status:** Partial

**Rule.** An agent uses the same public API as any client. It gets no path around the
key, the idempotency rule or the integer money rule.

**Failure it prevents.** An agent retries a tool call and pays twice, or sends 100.5 as an
amount.

**In Chebit.**

- `mcp/chebit_mcp.exs` is an MCP server over stdio. It is one Elixir script with no
  dependency. It calls the HTTP API with the merchant's key.
- Payment tools: `create_payment_intent`, `confirm_payment_intent`, `get_payment_intent`,
  `list_balances`.
- Handbook tools: `handbook_list`, `handbook_read`. The practices are also MCP resources,
  `chebit://handbook` and `chebit://handbook/<number>`.
- The landing shows the tools, the rules and these commands at `landing/handbook.html#agents`.
- Each write tool sends an `idempotency-key`. When the agent gives none, the server makes
  one and returns it. After a timeout the answer tells the agent to call again with that key.
- A tool refuses an amount that is not a JSON integer.
- The key comes from the environment variable `CHEBIT_API_KEY`. The server never prints it.

Run it:

```bash
# 1. In the root of the repository: start Postgres and the API (port 4000).
mise run db && mise run server

# 2. Make a merchant. The command prints the API key once.
mise exec -- mix run -e 'IO.puts(elem(Chebit.Merchants.create_merchant(%{name: "Dev"}), 1).api_key)'

# 3. Add the server to Claude Code.
claude mcp add chebit --env CHEBIT_API_KEY=<the key> -- \
  mise exec -- elixir "$(pwd)/mcp/chebit_mcp.exs"
```

`CHEBIT_API_URL` changes the address. The default is `http://127.0.0.1:4000`.

**Proof.** A protocol check on 2026-11-20: `initialize`, `tools/list`, `resources/list`,
each tool against a running API, a float amount, a bad key and bad JSON.

**Gaps.**

- It runs on the developer's machine. The remote server of the brief is Phase 4.
- No tool pays a simulated payment. Only the demo script and the tests drive the simulator.
- The check is manual. No test in `bin/gate` covers the script.

## Review findings

Found on 2026-11-20 in a read-only review. Each one has a test that reproduced it in a
copy of the code from 02:02 ART. The same tests ran again on the code of 02:31 ART: three
findings no longer reproduce. The tests are in the review lab, not in this repository.

| Id | Severity | Finding | Evidence | Practice | State at 02:31 ART |
|---|---|---|---|---|---|
| R1 | High | The expiry job reads the 500 oldest due intents. An intent that the provider keeps `pending` never leaves that list. | With 500 stuck intents, 3 runs expired 0 and a `created` intent stayed `created`. With 10 stuck, it expired. | 18 | Fixed in part. Each stuck intent is still synced each minute. |
| R2 | High | A webhook lost after `paid` is detected each hour and never repaired. | After a lost `final`: intent `paid`, held 10000, available 0, after each job. One `sync_attempt/1` repaired it. | 13, 19 | Open |
| R3 | Medium | A provider answer that is read before `final` and applied after it marks a good event `failed`. | `process/1` gave `{:error, {:rejected, :invalid_transition}}`; the intent was `final`. | 13 | Open |
| R4 | Medium | A request that lost its idempotency claim can delete the key row of the request that took over. | The row was gone after request 2. Request 3 ran the function again and got another body. | 8 | Fixed |
| R5 | Medium | The database accepts a backward status, a new amount on a paid intent, a new amount on an active hold, and two more postings on an old transaction. | Each statement changed rows. The audit found the cache drift afterwards. | 2, 5, 7, 15 | Open |
| R6 | Medium | The fee is read from the merchant when the payment is paid. The intent does not store it. | An intent made at 100 bps and paid after a change to 1000 bps paid a fee of 1000 on 10000. | 10 | Open |
| R7 | Medium | Two amounts that each pass `valid_amount?/1` overflow a balance. | The second credit raised `bigint out of range`. | 1 | Fixed |

None of the seven lets money appear or vanish. Invariants 1, 2, 3 and 7 held in each test.
