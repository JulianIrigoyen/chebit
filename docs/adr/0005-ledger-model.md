# ADR 0005: The ledger model

- Status: accepted
- Date: 2026-11-20

## Decision

- **Postings.** A transaction is a group of postings. A posting is one debit or one credit
  of a positive integer amount on one account. For each currency, debits equal credits.
- **One sign rule.** `balance_minor` is credits minus debits, for every account. A merchant
  or user account is a liability: positive means that Chebit owes money. A house account
  can be negative: a clearing balance of -10,000 means that the provider holds 10,000 for us.
  The balances of all accounts in one currency sum to zero.
- **Cached balance.** `accounts.balance_minor` and `accounts.held_minor` are caches. The
  ledger updates them in the transaction that writes the postings. `Chebit.Ledger.Audit`
  recomputes them from the postings and the holds each hour.
- **Holds.** A hold lowers the available balance and moves no money. It ends as `captured`
  (the amount left the account in one transaction) or `released`.
- **Money that can still reverse is held.** When a payment is `paid`, the merchant gets the
  credit and a hold of the same amount. `final` releases the hold. A refund or a lost
  dispute reverses the transaction and captures the hold. The same primitive later reserves
  balance for a payout or a withdrawal before the API answers 202.
- **Corrections.** `Ledger.reverse/2` writes the mirror transaction. Nothing is edited.
- **Idempotent on the source.** `(source_type, source_id, kind)` is unique for a transaction
  and `(source_type, source_id)` for a hold.

## What the database enforces

| Rule | Mechanism |
|---|---|
| A transaction sums to zero per currency | statement trigger `postings_balanced` |
| Postings and transactions never change | triggers `*_append_only` |
| Available balance of a merchant or user is not negative | check `accounts_available_non_negative` |
| A posting has the currency of its account | composite foreign key |
| A captured or released hold never changes status | trigger `holds_terminal_status` |
| One transaction per operation | unique indexes |

The application checks each rule first, in the pure module `Chebit.Ledger.Rules`, and
returns an error atom. The constraint is the backstop.

## Concurrency

The ledger locks the account rows in ascending id order, then the hold row. Two transfers
in opposite directions therefore cannot deadlock.

## Consequences

- An update of the cached balance takes a row lock, so writes to one account run one at a
  time. A very busy house account (fees, clearing) becomes a hot row. The brief names the
  remedy: sub-accounts by shard.
- In production the application role should also lose UPDATE, DELETE and TRUNCATE on the
  two append-only tables. Phase 0 has one role.
