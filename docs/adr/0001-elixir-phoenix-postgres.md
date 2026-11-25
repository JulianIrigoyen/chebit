# ADR 0001: Elixir and Phoenix for the core, Postgres as the source of truth

- Status: accepted (the brief chose it)
- Date: 2026-11-20

## Context

A payment gateway waits most of the time: for a provider, a webhook, a payer. It must keep
one failure from touching another payment. It must never lose or invent money.

## Decision

- The core is one Elixir application with Phoenix for HTTP.
- Postgres holds every fact: intents, attempts, the ledger, events, jobs.
- A process holds no fact that is not in Postgres. A restart loses nothing.
- Rust enters only for the Lightning node and for key signing, as a separate service
  behind the provider contract (ADR 0003).
- Redis is not used in Phase 0. If it comes, it is a cache or a rate limiter.

## Consequences

- One deploy unit and one database. No Kafka and no service mesh in Phase 0.
- The database enforces the invariants with constraints and triggers, so a bug in the
  application cannot break them without an error.
- Postgres is the bottleneck when volume grows. We measure before we split anything.
