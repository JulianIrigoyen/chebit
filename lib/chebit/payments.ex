defmodule Chebit.Payments do
  @moduledoc """
  Payment intents: create, confirm, and follow the provider to a terminal status.

  ## Flow

  1. `create_intent/3` writes the intent. The merchant gets its id.
  2. `confirm_intent/3` sends the intent to a provider and returns what the payer needs.
  3. The provider reports progress with webhooks. A webhook is only a signal:
     `sync_attempt/1` reads the current state from the provider and applies each step
     that we missed, in order. A duplicate or a late webhook changes nothing.

  ## One step, one transaction

  `apply_step/3` moves an intent one step. In one database transaction it locks the intent,
  checks the step with `Chebit.Payments.StateMachine`, writes the ledger effect, updates the
  status and emits the outbox event. The steps and their ledger effects:

  | Step       | Ledger effect                                                              |
  |------------|----------------------------------------------------------------------------|
  | `pending`  | none                                                                       |
  | `paid`     | debit the provider's clearing account; credit the merchant and the fee account; hold the merchant's share |
  | `disputed` | none: the hold stays                                                       |
  | `final`    | release the hold: the merchant can now use the money                       |
  | `refunded` | reverse the `paid` transaction and capture the hold                        |
  | `failed`, `expired` | none: no money moved                                              |

  A payment that is `paid` and not `final` can still reverse, so the merchant's share stays
  on hold until `final`.

  ## Sent to the provider exactly once

  `confirm_intent/3` commits the attempt row first, then calls the provider outside any
  transaction, then records the answer. The provider receives the attempt id as `reference`
  and treats it as an idempotency key. After a crash or a lost reply the attempt is still
  `initiated`; the next confirm sends the same reference, and the provider returns the same
  payment.
  """
  import Ecto.Changeset
  import Ecto.Query

  alias Chebit.Ledger
  alias Chebit.Merchants.Merchant
  alias Chebit.Money
  alias Chebit.Outbox
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Payments.StateMachine
  alias Chebit.Providers
  alias Chebit.Providers.Provider
  alias Chebit.Repo

  require Logger

  # How long a payer has to pay.
  @intent_ttl_seconds 15 * 60

  # An attempt that the provider does not know is abandoned only this long after the intent
  # expired. A confirm that started just before the expiry can still be on its way to the
  # provider, and the wait must be longer than one provider call.
  @abandon_grace_seconds 120

  # The expiry job reads the due intents in pages of this size.
  @expiry_batch 500

  @type confirm_error ::
          :not_found
          | :unknown_provider
          | :invalid_state
          | :provider_declined
          | :provider_unavailable
          | sync_error()

  @type sync_error ::
          :not_found
          | :unknown_provider
          | :provider_unavailable
          | :payment_not_found
          | :provider_mismatch
          | :invalid_transition
          | Ledger.post_error()

  @doc """
  Creates an intent for a merchant.

  `attrs` is outside input: `amount_minor` (a positive integer in the smallest unit of
  `currency`), `currency`, and the optional `description` and `metadata`.

  The call is idempotent on `(merchant.id, idempotency_key)`: a repeated call returns the
  first intent and writes nothing. The same key with another amount, currency or
  description is an error on `idempotency_key`.
  """
  @spec create_intent(Merchant.t(), String.t(), map()) ::
          {:ok, Intent.t()} | {:error, Ecto.Changeset.t()}
  def create_intent(%Merchant{} = merchant, idempotency_key, attrs)
      when is_binary(idempotency_key) and is_map(attrs) do
    expires_at = DateTime.add(DateTime.utc_now(), @intent_ttl_seconds, :second)

    changeset =
      %Intent{
        merchant_id: merchant.id,
        idempotency_key: idempotency_key,
        expires_at: expires_at
      }
      |> cast(outside_attrs(attrs), [:amount_minor, :currency, :description, :metadata])
      |> validate_required([:amount_minor, :currency])
      |> validate_change(:amount_minor, fn :amount_minor, amount ->
        if Money.valid_amount?(amount), do: [], else: [amount_minor: "must be a positive integer"]
      end)
      |> validate_length(:description, max: 500)

    Repo.transact(fn -> insert_once(changeset) end)
  end

  defp insert_once(changeset) do
    target = [:merchant_id, :idempotency_key]

    with {:ok, candidate} <-
           Repo.insert(changeset, on_conflict: :nothing, conflict_target: target) do
      # With `on_conflict: :nothing`, Ecto returns the candidate even when the row already
      # exists. The stored row tells which case this is.
      stored =
        Repo.get_by!(Intent,
          merchant_id: candidate.merchant_id,
          idempotency_key: candidate.idempotency_key
        )

      first_or_same(stored, candidate, changeset)
    end
  end

  defp first_or_same(stored, candidate, changeset) do
    cond do
      stored.id == candidate.id -> with {:ok, _event} <- emit(stored), do: {:ok, stored}
      same_request?(stored, candidate) -> {:ok, stored}
      true -> {:error, add_error(changeset, :idempotency_key, "was used with another request")}
    end
  end

  defp same_request?(stored, candidate) do
    stored.amount_minor == candidate.amount_minor and stored.currency == candidate.currency and
      stored.description == candidate.description
  end

  # `cast/3` raises on a map that mixes atom and string keys, so each key becomes a string.
  # A key of another type is dropped. `"metadata": null` means "no metadata": the column is
  # not null, and the default is an empty map.
  defp outside_attrs(attrs) do
    for {key, value} <- attrs,
        is_atom(key) or is_binary(key),
        key = to_string(key),
        not (key == "metadata" and is_nil(value)),
        into: %{} do
      {key, value}
    end
  end

  @doc """
  Counts the intents of all merchants by status.

  A status with no intent is missing from the map. The dev dashboard uses this call.
  """
  @spec count_by_status() :: %{StateMachine.status() => non_neg_integer()}
  def count_by_status do
    from(i in Intent, group_by: i.status, select: {i.status, count(i.id)})
    |> Repo.all()
    |> Map.new()
  end

  @doc "Reads one intent of a merchant, with its attempts."
  @spec fetch_intent(Ecto.UUID.t(), term()) :: {:ok, Intent.t()} | {:error, :not_found}
  def fetch_intent(merchant_id, intent_id) do
    with {:ok, id} <- cast_uuid(intent_id),
         %Intent{} = intent <- Repo.get_by(Intent, id: id, merchant_id: merchant_id) do
      {:ok, Repo.preload(intent, :attempts)}
    else
      _missing -> {:error, :not_found}
    end
  end

  @doc """
  Sends an intent to a provider.

  - A `created` intent gets one attempt, and the provider creates the payment.
  - A second confirm with the same provider sends nothing new. If the provider has the
    payment, it returns the intent as it is now, whatever its status. If the first reply was
    lost, it sends the same attempt again.
  - An intent that is not `created`, or that passed `expires_at`, and that has no attempt at
    this provider gives `{:error, :invalid_state}`.
  - A confirm with another provider while an attempt is live gives `{:error, :invalid_state}`.
  - `{:error, :provider_declined}`: no payment exists. The intent stays `created` and can be
    confirmed again.
  - `{:error, :provider_unavailable}`: the outcome is unknown. Confirm again with the same
    provider.
  """
  @spec confirm_intent(Ecto.UUID.t(), term(), term()) ::
          {:ok, Intent.t()} | {:error, confirm_error()}
  def confirm_intent(merchant_id, intent_id, provider_name) do
    with {:ok, provider} <- Providers.fetch(provider_name),
         {:ok, id} <- cast_uuid(intent_id),
         {:ok, {intent, attempt}} <- open_attempt(merchant_id, id, provider_name) do
      case attempt.status do
        :dispatched -> fetch_intent(merchant_id, intent.id)
        :initiated -> dispatch(provider, intent, attempt)
      end
    end
  end

  @doc """
  Reads the current state of an attempt from its provider and applies each missing step.

  The call is safe to repeat, in any order and at any time: it compares states, not events.
  `{:error, :invalid_transition}` means that the provider reports a status that our status
  cannot reach, for example `paid` for an intent that already `expired`. Nothing changes,
  and reconciliation shows the difference.
  """
  @spec sync_attempt(term()) :: {:ok, Intent.t()} | {:error, sync_error()}
  def sync_attempt(attempt_id) do
    with {:ok, id} <- cast_uuid(attempt_id),
         %Attempt{} = attempt <- Repo.get(Attempt, id) || {:error, :not_found},
         {:ok, provider} <- Providers.fetch(attempt.provider),
         {:ok, payment} <- fetch_payment(provider, attempt) do
      apply_payment(attempt.id, payment)
    end
  end

  @doc """
  Expires the intents whose `expires_at` is before `now`.

  - An intent with no live attempt never reached a provider. It expires here.
  - An intent with a live attempt belongs to the provider, which received `expires_at`.
    The job syncs with the provider and applies what it reports. If the provider still
    reports `pending`, the intent stays `pending`: only the provider knows whether the
    payer can still pay.
  - If the provider has no such payment and never confirmed the attempt, the intent expires
    here, but only #{@abandon_grace_seconds} seconds after `expires_at`. Before that, a
    confirm can still be on its way to the provider.

  One call visits each due intent once, in pages of `:batch_size`. An intent that stays
  `pending` therefore cannot keep the job from reaching the ones after it.

  Returns the number of intents that this call moved to `expired`.

  ## Options

  - `:batch_size` - the number of intents in one page. Defaults to #{@expiry_batch}.
  """
  @spec expire_due(DateTime.t(), batch_size: pos_integer()) :: {:ok, non_neg_integer()}
  def expire_due(%DateTime{} = now, opts \\ []) do
    {:ok, expire_pages(now, Keyword.get(opts, :batch_size, @expiry_batch), nil, 0)}
  end

  defp expire_pages(now, batch_size, cursor, count) do
    page = due_page(now, batch_size, cursor)

    expired =
      Enum.count(page, fn
        {intent_id, nil, _at} -> expired?(expire_locally(intent_id, now))
        {intent_id, attempt_id, _at} -> expired?(expire_with_provider(intent_id, attempt_id, now))
      end)

    if length(page) < batch_size do
      count + expired
    else
      {intent_id, _attempt_id, expires_at} = List.last(page)
      expire_pages(now, batch_size, {expires_at, intent_id}, count + expired)
    end
  end

  # Keyset pagination on `(expires_at, id)`: each page starts after the last row of the one before.
  defp due_page(now, batch_size, cursor) do
    query =
      from i in Intent,
        left_join: a in Attempt,
        on: a.payment_intent_id == i.id and a.status != :failed,
        where: i.status in [:created, :pending] and i.expires_at < ^now,
        order_by: [i.expires_at, i.id],
        limit: ^batch_size,
        select: {i.id, a.id, i.expires_at}

    case cursor do
      nil ->
        Repo.all(query)

      {expires_at, intent_id} ->
        Repo.all(
          from [i, _a] in query,
            where:
              i.expires_at > ^expires_at or (i.expires_at == ^expires_at and i.id > ^intent_id)
        )
    end
  end

  # Confirm

  # Commits the attempt before any call to the provider. The intent row lock makes two
  # concurrent confirms agree on one attempt.
  defp open_attempt(merchant_id, intent_id, provider_name) do
    Repo.transact(fn ->
      with {:ok, intent} <- lock_intent(intent_id, merchant_id),
           {:ok, attempt} <- attempt_for(intent, live_attempt(intent.id), provider_name) do
        {:ok, {intent, attempt}}
      end
    end)
  end

  # The provider already has the payment. A repeated confirm sends nothing and returns the
  # intent, whatever its status is by now. A retry after a crash therefore never gets an
  # error for a confirm that worked.
  defp attempt_for(
         _intent,
         %Attempt{provider: provider, status: :dispatched} = attempt,
         provider
       ),
       do: {:ok, attempt}

  # The first reply was lost. Send the same attempt again, while the intent can still be paid.
  defp attempt_for(intent, %Attempt{provider: provider, status: :initiated} = attempt, provider) do
    with :ok <- open(intent), do: {:ok, attempt}
  end

  # Another provider holds the live attempt.
  defp attempt_for(_intent, %Attempt{}, _provider_name), do: {:error, :invalid_state}

  defp attempt_for(intent, nil, provider_name) do
    with :ok <- open(intent) do
      {:ok, Repo.insert!(%Attempt{payment_intent_id: intent.id, provider: provider_name})}
    end
  end

  # Only a `created` intent before its expiry can go to a provider.
  defp open(%Intent{status: :created, expires_at: expires_at}) do
    if DateTime.compare(expires_at, DateTime.utc_now()) == :gt,
      do: :ok,
      else: {:error, :invalid_state}
  end

  defp open(%Intent{}), do: {:error, :invalid_state}

  # Runs outside any transaction: a provider call can take seconds.
  defp dispatch(provider, intent, attempt) do
    request = %{
      reference: attempt.id,
      amount_minor: intent.amount_minor,
      currency: intent.currency,
      description: intent.description,
      expires_at: intent.expires_at
    }

    case provider.create_payment(request) do
      {:ok, payment} ->
        apply_payment(attempt.id, payment)

      {:error, :declined} ->
        fail_attempt(attempt.id, "provider_declined")
        {:error, :provider_declined}

      {:error, :unavailable} ->
        {:error, :provider_unavailable}
    end
  end

  # Only an attempt that the provider never confirmed can fail. The intent stays `created`.
  defp fail_attempt(attempt_id, reason) do
    Repo.update_all(
      from(a in Attempt, where: a.id == ^attempt_id and a.status == :initiated),
      set: [status: :failed, failure_reason: reason, updated_at: DateTime.utc_now()]
    )
  end

  # Sync

  defp fetch_payment(provider, attempt) do
    case provider.fetch_payment(attempt.id) do
      {:ok, payment} -> {:ok, payment}
      {:error, :not_found} -> {:error, :payment_not_found}
      {:error, :unavailable} -> {:error, :provider_unavailable}
    end
  end

  # Records what the provider reports and walks the intent to the reported status.
  @spec apply_payment(Ecto.UUID.t(), Provider.payment()) ::
          {:ok, Intent.t()} | {:error, sync_error()}
  defp apply_payment(attempt_id, payment) do
    Repo.transact(fn ->
      with %Attempt{payment_intent_id: intent_id} <-
             Repo.get(Attempt, attempt_id) || {:error, :not_found},
           {:ok, intent} <- lock_intent(intent_id),
           # Lock order: the intent, then the attempt. Another caller can have failed the
           # attempt since the first read, and none can change it while we hold the lock.
           {:ok, attempt} <- lock_attempt(attempt_id),
           :ok <- same_payment(attempt, intent, payment),
           {:ok, attempt} <- record_payment(attempt, payment),
           {:ok, steps} <- path(intent.status, payment.status),
           {:ok, intent} <- apply_steps(intent, steps, attempt, payment) do
        {:ok, Repo.preload(intent, :attempts, force: true)}
      end
    end)
  end

  # Fail closed: a payment for another reference, amount or currency is not our payment.
  defp same_payment(attempt, intent, payment) do
    if payment.reference == attempt.id and payment.amount_minor == intent.amount_minor and
         payment.currency == intent.currency do
      :ok
    else
      Logger.error(
        "provider #{attempt.provider} reports a different payment for attempt #{attempt.id}"
      )

      {:error, :provider_mismatch}
    end
  end

  defp record_payment(%Attempt{status: :failed}, _payment), do: {:error, :invalid_transition}

  defp record_payment(attempt, payment) do
    attempt
    |> change(
      status: :dispatched,
      external_id: payment.external_id,
      provider_status: Atom.to_string(payment.status),
      payment_data: payment.payment_data
    )
    |> Repo.update()
  end

  defp path(from, to) do
    with {:error, :unreachable} <- StateMachine.path(from, to), do: {:error, :invalid_transition}
  end

  defp apply_steps(intent, steps, attempt, payment) do
    Enum.reduce_while(steps, {:ok, intent}, fn to, {:ok, intent} ->
      case apply_step(intent, to, %{provider: attempt.provider, payment: payment}) do
        {:ok, intent} -> {:cont, {:ok, intent}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # Moves a locked intent one step: ledger effect, status, outbox event. The caller holds
  # the transaction and the row lock.
  defp apply_step(%Intent{} = intent, to, context) do
    with :ok <- StateMachine.transition(intent.status, to),
         :ok <- ledger_effect(intent, to, context),
         {:ok, intent} <- put_status(intent, to, failure_reason(intent.status, to, context)),
         {:ok, _event} <- emit(intent) do
      {:ok, intent}
    end
  end

  defp ledger_effect(intent, :paid, %{provider: provider}) do
    merchant = Repo.get!(Merchant, intent.merchant_id)
    fee_minor = Money.fee_minor(intent.amount_minor, merchant.fee_bps)
    net_minor = intent.amount_minor - fee_minor

    with {:ok, clearing} <-
           Ledger.ensure_account(:house, "clearing:" <> provider, intent.currency),
         {:ok, fees} <- Ledger.ensure_account(:house, "fees", intent.currency),
         {:ok, balance} <-
           Ledger.ensure_account({:merchant, merchant.id}, "balance", intent.currency),
         entries = paid_entries(intent, clearing.id, balance.id, net_minor, fees.id, fee_minor),
         {:ok, _transaction} <- Ledger.post(paid_request(intent, provider, entries)) do
      hold_share(intent, balance.id, net_minor)
    end
  end

  defp ledger_effect(intent, :final, _context) do
    case Ledger.fetch_hold("payment_intent", intent.id) do
      {:ok, hold} -> with {:ok, _hold} <- Ledger.release_hold(hold.id), do: :ok
      {:error, :hold_not_found} -> :ok
    end
  end

  defp ledger_effect(intent, :refunded, _context) do
    with {:ok, paid} <- Ledger.fetch_transaction("payment_intent", intent.id, "payment_paid") do
      opts =
        case Ledger.fetch_hold("payment_intent", intent.id) do
          {:ok, hold} -> [capture_hold: hold.id]
          {:error, :hold_not_found} -> []
        end

      with {:ok, _reversal} <- Ledger.reverse(paid.id, opts), do: :ok
    end
  end

  defp ledger_effect(_intent, _to, _context), do: :ok

  # Pure: the entries of a paid payment. The provider now holds the full amount for us.
  # We owe the merchant its share and keep the fee. An entry of zero is left out.
  defp paid_entries(intent, clearing_id, balance_id, net_minor, fees_id, fee_minor) do
    Enum.filter(
      [
        entry(clearing_id, :debit, intent.amount_minor, intent.currency),
        entry(balance_id, :credit, net_minor, intent.currency),
        entry(fees_id, :credit, fee_minor, intent.currency)
      ],
      &(&1.amount_minor > 0)
    )
  end

  defp entry(account_id, direction, amount_minor, currency) do
    %{
      account_id: account_id,
      direction: direction,
      amount_minor: amount_minor,
      currency: currency
    }
  end

  defp paid_request(intent, provider, entries) do
    %{
      kind: "payment_paid",
      source_type: "payment_intent",
      source_id: intent.id,
      entries: entries,
      metadata: %{"provider" => provider}
    }
  end

  # A fee of 100% leaves no share to hold.
  defp hold_share(_intent, _account_id, 0), do: :ok

  defp hold_share(intent, account_id, net_minor) do
    request = %{
      account_id: account_id,
      amount_minor: net_minor,
      source_type: "payment_intent",
      source_id: intent.id
    }

    with {:ok, _hold} <- Ledger.place_hold(request), do: :ok
  end

  defp failure_reason(_from, :failed, %{payment: %{failure_reason: reason}})
       when is_binary(reason),
       do: reason

  defp failure_reason(_from, :failed, _context), do: "provider_failed"
  defp failure_reason(_from, :expired, _context), do: "expired"
  defp failure_reason(:disputed, :refunded, _context), do: "dispute_lost"
  defp failure_reason(_from, :refunded, _context), do: "refunded"
  defp failure_reason(_from, _to, _context), do: nil

  # The condition on the old status makes the update a no-op if the row changed under us.
  # The row lock already prevents that; this is the second check.
  defp put_status(intent, to, failure_reason) do
    now = DateTime.utc_now()

    query = from i in Intent, where: i.id == ^intent.id and i.status == ^intent.status

    case Repo.update_all(query,
           set: [status: to, failure_reason: failure_reason, updated_at: now]
         ) do
      {1, _rows} ->
        {:ok, %{intent | status: to, failure_reason: failure_reason, updated_at: now}}

      {0, _rows} ->
        {:error, :invalid_transition}
    end
  end

  defp emit(intent) do
    Outbox.emit(%{
      type: "payment_intent.#{intent.status}",
      aggregate_type: "payment_intent",
      aggregate_id: intent.id,
      payload: %{
        "id" => intent.id,
        "merchant_id" => intent.merchant_id,
        "status" => Atom.to_string(intent.status),
        "amount_minor" => intent.amount_minor,
        "currency" => Atom.to_string(intent.currency),
        "failure_reason" => intent.failure_reason
      }
    })
  end

  # Expiry

  defp expired?({:ok, %Intent{status: :expired}}), do: true
  defp expired?(_other), do: false

  defp expire_locally(intent_id, now) do
    Repo.transact(fn ->
      with {:ok, intent} <- lock_intent(intent_id),
           :ok <- due(intent, now),
           nil <- live_attempt(intent.id) do
        apply_step(intent, :expired, %{})
      else
        %Attempt{} -> {:error, :invalid_state}
        {:error, reason} -> {:error, reason}
      end
    end)
  end

  defp expire_with_provider(intent_id, attempt_id, now) do
    case sync_attempt(attempt_id) do
      {:error, :payment_not_found} -> abandon(intent_id, attempt_id, now)
      result -> result
    end
  end

  # The provider has no payment for this attempt, and the time to pay is over.
  defp abandon(intent_id, attempt_id, now) do
    Repo.transact(fn ->
      with {:ok, intent} <- lock_intent(intent_id),
           :ok <- due(intent, DateTime.add(now, -@abandon_grace_seconds, :second)),
           {:ok, attempt} <- lock_attempt(attempt_id),
           :ok <- never_confirmed(intent, attempt) do
        Repo.update_all(
          from(a in Attempt, where: a.id == ^attempt.id),
          set: [status: :failed, failure_reason: "expired", updated_at: DateTime.utc_now()]
        )

        apply_step(intent, :expired, %{})
      end
    end)
  end

  # The read at the provider happened before we took the lock. If a confirm landed since
  # then, the attempt is `dispatched` and the provider has the payment: the provider decides.
  # A `dispatched` attempt that the provider does not know is never abandoned either: it is
  # a difference for reconciliation, not a reason to expire a payment that can be live.
  defp never_confirmed(%Intent{status: :created}, %Attempt{status: :initiated}), do: :ok
  defp never_confirmed(%Intent{}, %Attempt{}), do: {:error, :invalid_state}

  defp due(%Intent{status: status, expires_at: expires_at}, now)
       when status in [:created, :pending] do
    if DateTime.compare(expires_at, now) == :lt, do: :ok, else: {:error, :invalid_state}
  end

  defp due(%Intent{}, _now), do: {:error, :invalid_state}

  # Shared reads

  defp lock_intent(intent_id, merchant_id \\ nil) do
    query = from i in Intent, where: i.id == ^intent_id, lock: "FOR UPDATE"
    query = if merchant_id, do: where(query, [i], i.merchant_id == ^merchant_id), else: query

    case Repo.one(query) do
      %Intent{} = intent -> {:ok, intent}
      nil -> {:error, :not_found}
    end
  end

  defp lock_attempt(attempt_id) do
    case Repo.one(from a in Attempt, where: a.id == ^attempt_id, lock: "FOR UPDATE") do
      %Attempt{} = attempt -> {:ok, attempt}
      nil -> {:error, :not_found}
    end
  end

  defp live_attempt(intent_id) do
    Repo.one(from a in Attempt, where: a.payment_intent_id == ^intent_id and a.status != :failed)
  end

  defp cast_uuid(value) do
    case Ecto.UUID.cast(value) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end
end
