defmodule Chebit.Reconciliation do
  @moduledoc """
  Compares what a provider holds with what the ledger says that it holds.

  Two views of the same money must agree:

  - **The provider's view**: `provider.list_payments/0`. A payment whose status is `:paid`,
    `:disputed` or `:final` is money that the provider holds for Chebit.
  - **The ledger's view**: the house account `clearing:<provider>` for each currency. Its
    balance is negative when the provider holds money, so the ledger amount is
    `-balance_minor`.

  `run/1` checks the totals and each payment. A report is balanced when each total differs
  by zero and no payment has a discrepancy.

  `coverage/0` checks invariant 8 over all providers: the funds that providers hold are at
  least what the ledger owes to merchants and users.
  """

  import Ecto.Query

  alias Chebit.Ledger.Account
  alias Chebit.Money
  alias Chebit.Payments.Attempt
  alias Chebit.Payments.Intent
  alias Chebit.Providers
  alias Chebit.Repo

  # The provider holds the money of a payment in these statuses.
  @custody_statuses [:paid, :disputed, :final]

  @type discrepancy_kind ::
          :missing_in_ledger | :missing_at_provider | :amount_mismatch | :status_mismatch

  @type discrepancy :: %{kind: discrepancy_kind(), reference: String.t(), detail: map()}

  @type total :: %{
          currency: Money.currency(),
          provider_minor: non_neg_integer(),
          ledger_minor: integer(),
          difference_minor: integer()
        }

  @type report :: %{
          provider: String.t(),
          matched: non_neg_integer(),
          discrepancies: [discrepancy()],
          totals: [total()],
          balanced?: boolean()
        }

  @type coverage :: %{
          currency: Money.currency(),
          custody_minor: non_neg_integer(),
          owed_minor: integer(),
          covered?: boolean()
        }

  @doc """
  Reconciles one provider.

  ## Per payment

  The key is the provider's `reference`, which is the id of our attempt.

  - `:missing_in_ledger` - the provider has a payment and no attempt of this provider has
    that id. `detail` holds the provider's status and amount.
  - `:missing_at_provider` - a `dispatched` attempt of this provider is not in the
    provider's list. `detail` holds the status of the intent.
  - `:amount_mismatch` - the amount or the currency of the provider's payment differs from
    the intent. `detail` holds both sides.
  - `:status_mismatch` - the provider's status differs from the status of the intent.
    `detail` holds both. An attempt that is still `initiated` while the provider has the
    payment is a status mismatch too: the reply to the create call was lost.

  `matched` counts the payments with no discrepancy.

  ## Totals

  One entry for each currency that either side knows, ordered by currency:
  `provider_minor` is the sum of the provider's payments in `:paid`, `:disputed` or
  `:final`; `ledger_minor` is minus the balance of the house account `clearing:<provider>`
  (zero when the account does not exist); `difference_minor` is the first minus the second.

  `balanced?` is true when `discrepancies` is empty and each `difference_minor` is zero.
  """
  @spec run(term()) :: {:ok, report()} | {:error, :unknown_provider | :provider_unavailable}
  def run(provider_name) do
    with {:ok, provider} <- Providers.fetch(provider_name),
         {:ok, payments} <- list_payments(provider) do
      {:ok, build_report(provider_name, payments)}
    end
  end

  @doc """
  Reconciles each configured provider. Returns the names of the providers whose report is
  not balanced, or that are unavailable. An empty list means that everything matches.
  """
  @spec run_all() :: {:ok, [String.t()]}
  def run_all do
    unmatched =
      Enum.reject(Providers.names(), fn name ->
        match?({:ok, %{balanced?: true}}, run(name))
      end)

    {:ok, unmatched}
  end

  @doc """
  Compares custody with debt, for each currency (invariant 8).

  `custody_minor` is the sum over all configured providers of the payments in `:paid`,
  `:disputed` or `:final`. `owed_minor` is the sum of `balance_minor` over all merchant and
  user accounts. `covered?` is true when custody is at least what is owed.

  A provider that is unavailable makes the whole call fail: an unknown custody amount
  cannot prove coverage.
  """
  @spec coverage() :: {:ok, [coverage()]} | {:error, :provider_unavailable}
  def coverage do
    with {:ok, payments} <- all_payments() do
      custody = sum_custody(payments)

      owed =
        Repo.all(
          from a in Account,
            where: a.owner_type in [:merchant, :user],
            group_by: a.currency,
            # As text: a sum of bigint columns can pass the bigint range.
            select: {a.currency, fragment("SUM(?)::text", a.balance_minor)}
        )
        |> Map.new(fn {currency, sum} -> {currency, String.to_integer(sum)} end)

      result =
        (Map.keys(custody) ++ Map.keys(owed))
        |> Enum.uniq()
        |> sort_currencies()
        |> Enum.map(fn currency ->
          custody_minor = Map.get(custody, currency, 0)
          owed_minor = Map.get(owed, currency, 0)

          %{
            currency: currency,
            custody_minor: custody_minor,
            owed_minor: owed_minor,
            covered?: custody_minor >= owed_minor
          }
        end)

      {:ok, result}
    end
  end

  # Reads

  defp list_payments(provider) do
    case provider.list_payments() do
      {:ok, payments} -> {:ok, payments}
      {:error, :unavailable} -> {:error, :provider_unavailable}
    end
  end

  # One failed provider fails the whole call: a missing custody amount proves nothing.
  defp all_payments do
    Enum.reduce_while(Providers.names(), {:ok, []}, fn name, {:ok, acc} ->
      with {:ok, provider} <- Providers.fetch(name),
           {:ok, payments} <- list_payments(provider) do
        {:cont, {:ok, acc ++ payments}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp load_attempts(provider_name) do
    Repo.all(
      from a in Attempt,
        join: i in Intent,
        on: i.id == a.payment_intent_id,
        where: a.provider == ^provider_name,
        select: {a, i}
    )
    |> Map.new(fn {attempt, intent} -> {attempt.id, {attempt, intent}} end)
  end

  defp load_ledger(provider_name) do
    Repo.all(
      from a in Account,
        where: a.owner_type == :house and a.kind == ^("clearing:" <> provider_name),
        select: {a.currency, a.balance_minor}
    )
    |> Map.new(fn {currency, balance_minor} -> {currency, -balance_minor} end)
  end

  # Report

  defp build_report(provider_name, payments) do
    attempts = load_attempts(provider_name)
    by_reference = Map.new(payments, &{&1.reference, &1})

    at_provider =
      payments
      |> Enum.sort_by(& &1.reference)
      |> Enum.flat_map(&check_payment(&1, Map.get(attempts, &1.reference)))

    lost =
      attempts
      |> Enum.filter(fn {id, {attempt, _intent}} ->
        attempt.status == :dispatched and not is_map_key(by_reference, id)
      end)
      |> Enum.sort_by(fn {id, _row} -> id end)
      |> Enum.map(fn {id, {_attempt, intent}} ->
        discrepancy(:missing_at_provider, id, %{intent_status: intent.status})
      end)

    discrepancies = at_provider ++ lost
    flagged = discrepancies |> Enum.map(& &1.reference) |> MapSet.new()
    matched = Enum.count(payments, &(not MapSet.member?(flagged, &1.reference)))
    totals = build_totals(payments, load_ledger(provider_name))

    %{
      provider: provider_name,
      matched: matched,
      discrepancies: discrepancies,
      totals: totals,
      balanced?: discrepancies == [] and Enum.all?(totals, &(&1.difference_minor == 0))
    }
  end

  defp check_payment(payment, nil) do
    [
      discrepancy(:missing_in_ledger, payment.reference, %{
        provider_status: payment.status,
        provider_amount_minor: payment.amount_minor,
        currency: payment.currency
      })
    ]
  end

  # We ignore a failed attempt, so any payment that the provider holds for it is a difference.
  defp check_payment(payment, {%Attempt{status: :failed}, intent}) do
    [status_mismatch(payment, intent, :failed)]
  end

  defp check_payment(payment, {attempt, intent}) do
    amount =
      if payment.amount_minor == intent.amount_minor and payment.currency == intent.currency,
        do: [],
        else: [
          discrepancy(:amount_mismatch, payment.reference, %{
            provider_amount_minor: payment.amount_minor,
            provider_currency: payment.currency,
            ledger_amount_minor: intent.amount_minor,
            ledger_currency: intent.currency
          })
        ]

    status =
      if payment.status == intent.status and attempt.status == :dispatched,
        do: [],
        else: [status_mismatch(payment, intent, attempt.status)]

    amount ++ status
  end

  defp status_mismatch(payment, intent, attempt_status) do
    discrepancy(:status_mismatch, payment.reference, %{
      provider_status: payment.status,
      intent_status: intent.status,
      attempt_status: attempt_status
    })
  end

  defp discrepancy(kind, reference, detail),
    do: %{kind: kind, reference: reference, detail: detail}

  defp build_totals(payments, ledger) do
    custody = sum_custody(payments)
    currencies = Enum.map(payments, & &1.currency) ++ Map.keys(ledger)

    currencies
    |> Enum.uniq()
    |> sort_currencies()
    |> Enum.map(fn currency ->
      provider_minor = Map.get(custody, currency, 0)
      ledger_minor = Map.get(ledger, currency, 0)

      %{
        currency: currency,
        provider_minor: provider_minor,
        ledger_minor: ledger_minor,
        difference_minor: provider_minor - ledger_minor
      }
    end)
  end

  defp sum_custody(payments) do
    payments
    |> Enum.filter(&(&1.status in @custody_statuses))
    |> Enum.group_by(& &1.currency, & &1.amount_minor)
    |> Map.new(fn {currency, amounts} -> {currency, Enum.sum(amounts)} end)
  end

  defp sort_currencies(currencies), do: Enum.sort_by(currencies, &Atom.to_string/1)
end
