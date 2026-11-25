# ADR 0002: Jobs and the outbox run on Postgres with Oban

- Status: accepted
- Date: 2026-11-20

## Context

A change in the ledger and the event that announces it must commit together. A webhook
must be processed after the HTTP request ends, with retries. The brief asks for queues on
Postgres first.

## Decision

- Oban runs every background job. A job is a row in Postgres.
- `Chebit.Outbox.emit/1` writes the event row and one Oban job in the transaction of the
  caller. The job publishes the event and stamps `published_at`.
- `emit/1` refuses to run outside a transaction.
- The webhook inbox stores the event row and its job in one transaction.
- Scheduled work (expiry, ledger audit, reconciliation) uses the Oban cron plugin.

## Consequences

- Delivery is at least once. A consumer drops a duplicate by event id.
- The `outbox` queue runs one job at a time, so on one node events leave in the order of
  their ids. A retry or a second node breaks that order. The event id grows with time, and
  a consumer uses it to order. If a consumer needs strict order, replace the job per event
  with one reader that publishes in id order.
- `outbox_events` stays as the durable log. Oban prunes its own finished jobs after 7 days.
- Each job runs in its own supervised process. A crash fails one job, and Oban retries it.

## Revisit when

Postgres job throughput limits us, or an outside consumer needs a real broker.
