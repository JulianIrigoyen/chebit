defmodule Chebit.Fixtures do
  @moduledoc """
  Builders for test data. Each one goes through the public API of its context.
  """

  alias Chebit.Ledger
  alias Chebit.Merchants

  @doc "Creates a merchant. Returns the merchant with its API key."
  @spec merchant_fixture(map()) :: %{merchant: Merchants.Merchant.t(), api_key: String.t()}
  def merchant_fixture(attrs \\ %{}) do
    {:ok, result} =
      attrs
      |> Enum.into(%{name: "Parrilla #{System.unique_integer([:positive])}", fee_bps: 0})
      |> Merchants.create_merchant()

    result
  end

  @doc "Returns the `balance` account of a new random merchant id, in `currency`."
  @spec customer_account(Chebit.Money.currency()) :: Ledger.Account.t()
  def customer_account(currency \\ :ARS) do
    {:ok, account} = Ledger.ensure_account({:merchant, Ecto.UUID.generate()}, "balance", currency)
    account
  end

  @doc "Returns a house account. The kind is unique, so tests do not share it."
  @spec house_account(Chebit.Money.currency()) :: Ledger.Account.t()
  def house_account(currency \\ :ARS) do
    kind = "test:#{System.unique_integer([:positive])}"
    {:ok, account} = Ledger.ensure_account(:house, kind, currency)
    account
  end

  @doc "Posts a transaction that moves `amount_minor` from a house account to `account`."
  @spec fund(Ledger.Account.t(), pos_integer()) :: Ledger.Transaction.t()
  def fund(account, amount_minor) do
    house = house_account(account.currency)

    {:ok, transaction} =
      Ledger.post(%{
        kind: "test_funding",
        source_type: "test",
        source_id: Ecto.UUID.generate(),
        entries: [
          %{
            account_id: house.id,
            direction: :debit,
            amount_minor: amount_minor,
            currency: account.currency
          },
          %{
            account_id: account.id,
            direction: :credit,
            amount_minor: amount_minor,
            currency: account.currency
          }
        ]
      })

    transaction
  end

  @doc "Creates an intent for `merchant` with a fresh idempotency key. `attrs` use string keys."
  @spec intent_fixture(Merchants.Merchant.t(), map()) :: Chebit.Payments.Intent.t()
  def intent_fixture(merchant, attrs \\ %{}) do
    attrs = Map.merge(%{"amount_minor" => 10_000, "currency" => "ARS"}, attrs)

    {:ok, intent} =
      Chebit.Payments.create_intent(
        merchant,
        "key-#{System.unique_integer([:positive])}",
        attrs
      )

    intent
  end

  @doc """
  Creates a merchant and an intent, and confirms it with the simulator.
  Returns the merchant, the intent (status `pending`) and its single attempt.
  Options: `:fee_bps` (default 0), `:amount_minor` (default 10_000), `:currency` (default `:ARS`).
  """
  @spec pending_payment_fixture(keyword()) :: %{
          merchant: Merchants.Merchant.t(),
          intent: Chebit.Payments.Intent.t(),
          attempt: Chebit.Payments.Attempt.t()
        }
  def pending_payment_fixture(opts \\ []) do
    %{merchant: merchant} = merchant_fixture(%{fee_bps: Keyword.get(opts, :fee_bps, 0)})

    intent =
      intent_fixture(merchant, %{
        "amount_minor" => Keyword.get(opts, :amount_minor, 10_000),
        "currency" => opts |> Keyword.get(:currency, :ARS) |> Atom.to_string()
      })

    {:ok, confirmed} = Chebit.Payments.confirm_intent(merchant.id, intent.id, "simulated")
    %{merchant: merchant, intent: confirmed, attempt: hd(confirmed.attempts)}
  end

  @doc "Returns the balances of the merchant, clearing and fees accounts in `currency`."
  @spec payment_balances(Merchants.Merchant.t(), Chebit.Money.currency()) :: %{
          merchant: Ledger.balance(),
          clearing: Ledger.balance(),
          fees: Ledger.balance()
        }
  def payment_balances(merchant, currency \\ :ARS) do
    read = fn owner, kind ->
      {:ok, account} = Ledger.ensure_account(owner, kind, currency)
      {:ok, balance} = Ledger.balance(account.id)
      balance
    end

    %{
      merchant: read.({:merchant, merchant.id}, "balance"),
      clearing: read.(:house, "clearing:simulated"),
      fees: read.(:house, "fees")
    }
  end

  @doc "Returns the outbox event types of an intent, in id order."
  @spec intent_event_types(Chebit.Payments.Intent.t()) :: [String.t()]
  def intent_event_types(intent) do
    import Ecto.Query

    Chebit.Repo.all(
      from e in Chebit.Outbox.Event,
        where: e.aggregate_id == ^intent.id,
        order_by: e.id,
        select: e.type
    )
  end

  @doc "Reads an intent row by id, outside any merchant scope."
  @spec reload_intent(Chebit.Payments.Intent.t()) :: Chebit.Payments.Intent.t()
  def reload_intent(intent), do: Chebit.Repo.get!(Chebit.Payments.Intent, intent.id)

  @doc """
  Delivers a simulator webhook: ingest, then process the stored event.
  Returns `{ingest_result, process_result}`. `process_result` is `nil` when nothing was stored.
  """
  @spec deliver_webhook(%{body: binary(), headers: list()}) :: {term(), term()}
  def deliver_webhook(%{body: body, headers: headers}) do
    ingest = Chebit.Webhooks.ingest("simulated", body, headers)
    %{"id" => event_id} = Jason.decode!(body)

    case Chebit.Repo.get_by(Chebit.Webhooks.ProviderEvent,
           provider: "simulated",
           event_id: event_id
         ) do
      nil -> {ingest, nil}
      row -> {ingest, Chebit.Webhooks.process(row.id)}
    end
  end
end
