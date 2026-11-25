# ADR 0003: Lightning starts with a managed provider, behind the provider contract

- Status: proposed. Julián decides (open questions 2 and 3 in `docs/PLAN.md`).
- Date: 2026-11-20

## Context

The brief asks to evaluate a managed Lightning provider for the MVP, against our own node
(LDK in Rust). Our own node means channel liquidity, backups of channel state, a hot wallet
with keys, and on-call for a node that must stay online to receive.

Phase 1 must also work at the lowest regulatory step: Chebit provides software, and
regulated providers hold the funds.

## Decision

- Phase 1 receives Lightning through a managed provider: an API that creates an invoice,
  reports the payment and pays out in pesos or holds the sats under its own licence.
- The provider sits behind `Chebit.Providers.Provider`, like Mercado Pago. `:paid` and
  `:final` arrive together, because a settled Lightning payment cannot reverse.
- Chebit holds no key and no channel in Phase 1.
- The Rust services (LDK node, signer) come in Phase 3, when users hold sats with Chebit
  and withdraw to their own wallets. They implement the same contract.

## Consequences

- Phase 1 ships without node operations and without custody of Bitcoin.
- We depend on one partner for Lightning uptime, fees and limits. The adapter contract
  keeps the cost of a change low.
- The ledger counts BTC in satoshis. Lightning counts millisatoshis. An adapter creates
  invoices in whole satoshis, and a routing fee rounds up to one satoshi.

## Not decided here

Which provider. Check each candidate for: service to an Argentine company, payout in ARS,
webhooks with signatures, idempotency keys, fees, and its licence. Verify on their current
docs, not from memory.
