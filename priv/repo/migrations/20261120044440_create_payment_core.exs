defmodule Chebit.Repo.Migrations.CreatePaymentCore do
  @moduledoc """
  The tables of the payment core, and the constraints that hold its invariants.

  The database enforces these rules, whatever the application does:

  1. Each ledger transaction sums to zero for each currency (`postings_balanced`).
  2. Postings and ledger transactions are append-only (`*_append_only`).
  3. The available balance of a merchant or user account is never negative
     (`accounts_available_non_negative`).
  4. A posting has the currency of its account (`postings_account_id_fkey`).
  5. A terminal status never changes (`*_terminal_status`).
  6. One operation writes one transaction, one hold, one intent, one provider event and
     one idempotency key (unique indexes).
  """
  use Ecto.Migration

  @currencies "('ARS', 'USD', 'BTC', 'USDT', 'USDC')"

  def up do
    create table(:merchants, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :text, null: false
      add :api_key_hash, :binary, null: false
      add :fee_bps, :integer, null: false, default: 0

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:merchants, [:api_key_hash])
    create constraint(:merchants, :merchants_fee_bps_range, check: "fee_bps BETWEEN 0 AND 10000")

    # Ledger

    create table(:accounts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :owner_type, :text, null: false
      add :owner_id, :binary_id
      add :kind, :text, null: false
      add :currency, :text, null: false
      add :balance_minor, :bigint, null: false, default: 0
      add :held_minor, :bigint, null: false, default: 0

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # A house account has no owner. NULLS NOT DISTINCT makes the index cover it too.
    create unique_index(:accounts, [:owner_type, :owner_id, :kind, :currency],
             nulls_distinct: false
           )

    # Target of the composite foreign key from postings.
    create unique_index(:accounts, [:id, :currency])

    create constraint(:accounts, :accounts_owner_type_valid,
             check: "owner_type IN ('house', 'merchant', 'user')"
           )

    create constraint(:accounts, :accounts_house_has_no_owner,
             check: "(owner_type = 'house') = (owner_id IS NULL)"
           )

    create constraint(:accounts, :accounts_currency_valid, check: "currency IN #{@currencies}")
    create constraint(:accounts, :accounts_held_non_negative, check: "held_minor >= 0")

    create constraint(:accounts, :accounts_available_non_negative,
             check: "owner_type = 'house' OR balance_minor - held_minor >= 0"
           )

    create table(:ledger_transactions, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :kind, :text, null: false
      add :source_type, :text, null: false
      add :source_id, :text, null: false
      add :reverses_id, references(:ledger_transactions, type: :binary_id)
      add :metadata, :map, null: false, default: %{}

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:ledger_transactions, [:source_type, :source_id, :kind])

    # A transaction is reversed at most once.
    create unique_index(:ledger_transactions, [:reverses_id], where: "reverses_id IS NOT NULL")

    create table(:postings) do
      add :transaction_id, references(:ledger_transactions, type: :binary_id), null: false
      add :currency, :text, null: false

      add :account_id, references(:accounts, type: :binary_id, with: [currency: :currency]),
        null: false

      add :direction, :text, null: false
      add :amount_minor, :bigint, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:postings, [:transaction_id])
    create index(:postings, [:account_id, :id])

    create constraint(:postings, :postings_direction_valid,
             check: "direction IN ('debit', 'credit')"
           )

    create constraint(:postings, :postings_amount_positive, check: "amount_minor > 0")

    create table(:holds, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :account_id, references(:accounts, type: :binary_id), null: false
      add :amount_minor, :bigint, null: false
      add :status, :text, null: false, default: "active"
      add :source_type, :text, null: false
      add :source_id, :text, null: false
      add :capture_transaction_id, references(:ledger_transactions, type: :binary_id)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:holds, [:source_type, :source_id])
    create index(:holds, [:account_id], where: "status = 'active'")
    create constraint(:holds, :holds_amount_positive, check: "amount_minor > 0")

    create constraint(:holds, :holds_status_valid,
             check: "status IN ('active', 'captured', 'released')"
           )

    create constraint(:holds, :holds_capture_has_transaction,
             check: "(status = 'captured') = (capture_transaction_id IS NOT NULL)"
           )

    # Payments

    create table(:payment_intents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :merchant_id, references(:merchants, type: :binary_id), null: false
      add :amount_minor, :bigint, null: false
      add :currency, :text, null: false
      add :status, :text, null: false, default: "created"
      add :failure_reason, :text
      add :description, :text
      add :metadata, :map, null: false, default: %{}
      add :idempotency_key, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:payment_intents, [:merchant_id, :idempotency_key])

    # The expiry job reads only the intents that can still expire.
    create index(:payment_intents, [:expires_at], where: "status IN ('created', 'pending')")

    create constraint(:payment_intents, :payment_intents_amount_positive,
             check: "amount_minor > 0"
           )

    create constraint(:payment_intents, :payment_intents_currency_valid,
             check: "currency IN #{@currencies}"
           )

    create constraint(:payment_intents, :payment_intents_status_valid,
             check:
               "status IN ('created', 'pending', 'paid', 'disputed', 'final', 'failed', 'expired', 'refunded')"
           )

    create table(:payment_attempts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :payment_intent_id, references(:payment_intents, type: :binary_id), null: false
      add :provider, :text, null: false
      add :status, :text, null: false, default: "initiated"
      add :external_id, :text
      add :provider_status, :text
      add :payment_data, :map, null: false, default: %{}
      add :failure_reason, :text

      timestamps(type: :utc_datetime_usec)
    end

    # Phase 0: one live attempt for each intent.
    create unique_index(:payment_attempts, [:payment_intent_id],
             where: "status <> 'failed'",
             name: :payment_attempts_one_live_per_intent
           )

    create unique_index(:payment_attempts, [:provider, :external_id],
             where: "external_id IS NOT NULL"
           )

    create constraint(:payment_attempts, :payment_attempts_status_valid,
             check: "status IN ('initiated', 'dispatched', 'failed')"
           )

    create constraint(:payment_attempts, :payment_attempts_dispatched_has_external_id,
             check: "status <> 'dispatched' OR external_id IS NOT NULL"
           )

    # Webhook inbox

    create table(:provider_events) do
      add :provider, :text, null: false
      add :event_id, :text, null: false
      add :raw_body, :text, null: false
      add :status, :text, null: false, default: "received"
      add :error, :text
      add :processed_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:provider_events, [:provider, :event_id])

    create constraint(:provider_events, :provider_events_status_valid,
             check: "status IN ('received', 'processed', 'failed')"
           )

    # Idempotency

    create table(:idempotency_keys) do
      add :merchant_id, references(:merchants, type: :binary_id), null: false
      add :key, :text, null: false
      add :request_hash, :binary, null: false
      add :status, :text, null: false, default: "processing"
      add :response_status, :integer
      add :response_body, :map
      add :locked_at, :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:idempotency_keys, [:merchant_id, :key])

    create constraint(:idempotency_keys, :idempotency_keys_status_valid,
             check: "status IN ('processing', 'completed')"
           )

    create constraint(:idempotency_keys, :idempotency_keys_completed_has_response,
             check:
               "status <> 'completed' OR (response_status IS NOT NULL AND response_body IS NOT NULL)"
           )

    # Outbox

    create table(:outbox_events) do
      add :type, :text, null: false
      add :aggregate_type, :text, null: false
      add :aggregate_id, :text, null: false
      add :payload, :map, null: false
      add :published_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:outbox_events, [:id],
             where: "published_at IS NULL",
             name: :outbox_events_pending
           )

    # Invariant 1. One INSERT statement writes all the postings of a transaction.
    # The trigger then checks each transaction that the statement touched.
    execute """
    CREATE FUNCTION chebit_check_postings_balanced() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF EXISTS (
        SELECT 1
        FROM postings p
        WHERE p.transaction_id IN (SELECT transaction_id FROM new_postings)
        GROUP BY p.transaction_id, p.currency
        HAVING SUM(CASE p.direction WHEN 'debit' THEN p.amount_minor ELSE -p.amount_minor END) <> 0
      ) THEN
        RAISE EXCEPTION 'a ledger transaction does not sum to zero'
          USING ERRCODE = 'check_violation', CONSTRAINT = 'postings_balanced';
      END IF;
      RETURN NULL;
    END $$
    """

    execute """
    CREATE TRIGGER postings_balanced AFTER INSERT ON postings
    REFERENCING NEW TABLE AS new_postings
    FOR EACH STATEMENT EXECUTE FUNCTION chebit_check_postings_balanced()
    """

    # Invariant 2. A correction is a new transaction that reverses the old one.
    execute """
    CREATE FUNCTION chebit_forbid_change() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      RAISE EXCEPTION '% is append-only: % refused', TG_TABLE_NAME, TG_OP
        USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_append_only';
    END $$
    """

    for table <- ["postings", "ledger_transactions"] do
      execute """
      CREATE TRIGGER #{table}_append_only BEFORE UPDATE OR DELETE ON #{table}
      FOR EACH ROW EXECUTE FUNCTION chebit_forbid_change()
      """
    end

    # Invariant 6. The trigger arguments are the terminal statuses of the table.
    execute """
    CREATE FUNCTION chebit_guard_terminal_status() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF OLD.status = ANY (TG_ARGV) AND NEW.status IS DISTINCT FROM OLD.status THEN
        RAISE EXCEPTION '% %: status % is terminal', TG_TABLE_NAME, OLD.id, OLD.status
          USING ERRCODE = 'check_violation', CONSTRAINT = TG_TABLE_NAME || '_terminal_status';
      END IF;
      RETURN NEW;
    END $$
    """

    execute """
    CREATE TRIGGER payment_intents_terminal_status BEFORE UPDATE ON payment_intents
    FOR EACH ROW EXECUTE FUNCTION chebit_guard_terminal_status('final', 'failed', 'expired', 'refunded')
    """

    execute """
    CREATE TRIGGER holds_terminal_status BEFORE UPDATE ON holds
    FOR EACH ROW EXECUTE FUNCTION chebit_guard_terminal_status('captured', 'released')
    """
  end

  def down do
    for table <-
          ~w(outbox_events idempotency_keys provider_events payment_attempts payment_intents holds postings ledger_transactions accounts merchants) do
      execute "DROP TABLE #{table} CASCADE"
    end

    execute "DROP FUNCTION chebit_guard_terminal_status()"
    execute "DROP FUNCTION chebit_forbid_change()"
    execute "DROP FUNCTION chebit_check_postings_balanced()"
  end
end
