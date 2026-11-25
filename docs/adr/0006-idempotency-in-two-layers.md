# ADR 0006: Idempotency in two layers

- Status: accepted
- Date: 2026-11-20

## Context

Invariant 4: a request with the same idempotency key has its effect once, and a retry gets
the first response. A stored response alone does not give that: a server can die after the
effect and before it stores the response.

## Decision

1. **The key store** (`Chebit.Idempotency`, table `idempotency_keys`). It is unique on
   `(merchant_id, key)`. It stores the hash of the request and the first response. The hash
   covers the method, the path with its query string, and the parsed JSON body.
   - Same key, same request: the stored response, with the header `idempotent-replayed: true`.
   - Same key, another request: 409 `idempotency_key_reused`.
   - Same key while the first request runs: 409 `request_in_progress`.
   - A response of 500 or above is not stored. The key is free again.
   - A key that is `processing` for more than 30 seconds belongs to a dead request. The
     next retry takes it over and runs the operation again.
   - `locked_at` is the fencing token of the owner. A request that was only slow, and lost
     the key to a take-over, can no longer delete or complete the row of the new owner.
2. **The operation itself.** Each write is idempotent on a natural key, enforced by a
   unique index: an intent on `(merchant_id, idempotency_key)`, an attempt on its intent,
   a ledger transaction and a hold on their source, a provider event on
   `(provider, event_id)`. Running the operation twice changes nothing the second time.

Layer 1 gives the same answer. Layer 2 gives the single effect. Layer 1 can run the
operation twice (take-over, or a 5xx); layer 2 makes that safe.

A second run must also give an answer that agrees with the first. So a confirm with the
same provider, after the provider has the payment, returns the intent as it is now and
never an error. And `create_intent/3` refuses the same key with another amount, currency
or description.

## Consequences

- The key store never wraps the operation in a database transaction, because the operation
  can call a provider.
- Keys are never deleted in Phase 0. A cleanup job after 24 hours or more comes with volume.
