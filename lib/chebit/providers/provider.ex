defmodule Chebit.Providers.Provider do
  @moduledoc """
  The contract that each payment provider adapter implements.

  An adapter translates between one provider and the common payment model. It keeps no
  payment state of its own and it writes nothing to the database. `Chebit.Payments` calls it
  outside any database transaction.

  ## Statuses

  An adapter maps the provider's statuses to the common ones:

  | Provider type                | `:paid`                   | `:final`                          |
  |------------------------------|---------------------------|-----------------------------------|
  | Lightning, Transferencias 3.0 | when the payment settles  | at the same time                  |
  | Cards                        | when the charge is approved | when the chargeback window ends |
  | On-chain                     | when the transaction is seen | after N confirmations          |

  ## Exactly once

  `create_payment/1` receives `reference`, the id of our attempt. A second call with the
  same reference must return the first payment and create nothing. An adapter for a provider
  without idempotency keys looks the payment up by reference before it creates one.
  """

  alias Chebit.Money

  @type status :: :pending | :paid | :final | :failed | :expired | :refunded | :disputed

  @type payment :: %{
          external_id: String.t(),
          reference: String.t(),
          status: status(),
          amount_minor: Money.amount_minor(),
          currency: Money.currency(),
          payment_data: map(),
          failure_reason: String.t() | nil
        }

  @type create_request :: %{
          reference: String.t(),
          amount_minor: Money.amount_minor(),
          currency: Money.currency(),
          description: String.t() | nil,
          expires_at: DateTime.t()
        }

  @type webhook :: %{event_id: String.t(), reference: String.t()}

  @doc """
  Creates the payment at the provider. Idempotent on `reference`.

  - `{:error, :declined}`: the provider refused. No payment exists. Do not retry.
  - `{:error, :unavailable}`: the outcome is unknown. A payment can exist. Retry with the
    same reference.
  """
  @callback create_payment(create_request()) ::
              {:ok, payment()} | {:error, :declined | :unavailable}

  @doc "Reads the current state of a payment from the provider, by our reference."
  @callback fetch_payment(reference :: String.t()) ::
              {:ok, payment()} | {:error, :not_found | :unavailable}

  @doc """
  Checks the signature of a webhook and reads the two fields that the inbox needs.

  `raw_body` is the exact body of the request. `headers` has lower-case names.
  The event is only a signal: the processor then calls `fetch_payment/1` for the truth.
  """
  @callback verify_webhook(raw_body :: binary(), headers :: [{String.t(), String.t()}]) ::
              {:ok, webhook()} | {:error, :invalid_signature | :malformed}

  @doc "Lists the payments that the provider holds. Reconciliation compares them with the ledger."
  @callback list_payments() :: {:ok, [payment()]} | {:error, :unavailable}
end
