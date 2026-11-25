# ADR 0007: A webhook is a signal. The provider's current state is the truth

- Status: accepted
- Date: 2026-11-20

## Context

Providers send webhooks twice, late and out of order. A webhook can also be forged. The
brief asks to store the raw event, to deduplicate it, and to tolerate disorder by asking
the provider for the current state.

## Decision

- The inbox checks the signature, stores the raw body, and answers 200. `(provider,
  event_id)` is unique, so a duplicate is stored once.
- The processor does not read a status from the event. It calls
  `Chebit.Payments.sync_attempt/1`, which asks the provider for the payment and compares
  states. `StateMachine.path/2` lists the steps that we missed, and each one is applied in
  order, in one database transaction.
- Our attempt id is the provider's `reference` and its idempotency key. A webhook finds
  its attempt by the reference, so it cannot arrive "too early".
- Expiry follows the same rule. An intent that reached a provider expires only when the
  provider says so. The one exception is an attempt that the provider never confirmed
  (`initiated`) and does not know: its intent expires here, 120 seconds after
  `expires_at`. The wait is for a confirm that started just before the expiry and is still
  on its way to the provider. The job checks the attempt again under the row lock.
- An attempt that the provider confirmed and then does not know is never expired here.
  "Not found" can be a provider that lags behind its own write. Reconciliation reports it
  as `missing_at_provider`, and a person decides.
- A provider status that our status cannot reach changes nothing and marks the event
  `failed`. Example: `paid` for an intent that already `expired`. Reconciliation then shows
  the difference, and a person decides.

## Consequences

- Each event costs one read at the provider. That is the price of not trusting order.
- A sync is safe to run at any time and any number of times. A sweep job can call it for
  each open payment when a provider sends no webhooks.
- A provider that reports a payment with another amount or currency than our intent is
  refused (`:provider_mismatch`): fail closed.
