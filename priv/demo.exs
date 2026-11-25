# Runs the Chebit core end to end against the simulated provider.
# Start it with `mise run demo`. It needs the application and an empty database.

import Ecto.Query

# Hide the SQL debug log so the output reads top to bottom.
Logger.configure(level: :warning)

alias Chebit.Ledger
alias Chebit.Ledger.Account
alias Chebit.Ledger.Audit
alias Chebit.Ledger.Posting
alias Chebit.Ledger.Transaction
alias Chebit.Merchants
alias Chebit.Money
alias Chebit.Payments
alias Chebit.Providers.Simulated
alias Chebit.Reconciliation
alias Chebit.Repo
alias Chebit.Webhooks

defmodule Demo do
  @moduledoc false

  def step(title), do: IO.puts("\n== #{title}")

  def fail!(message) do
    IO.puts(:stderr, "DEMO FAILED: #{message}")
    System.halt(1)
  end

  # 1500000 ARS minor -> "ARS 15.000,00"
  def format(amount_minor, currency) do
    exponent = Money.exponent(currency)
    sign = if amount_minor < 0, do: "-", else: ""
    digits = amount_minor |> abs() |> Integer.to_string() |> String.pad_leading(exponent + 1, "0")
    {whole, fraction} = String.split_at(digits, String.length(digits) - exponent)

    whole =
      whole
      |> String.reverse()
      |> String.graphemes()
      |> Enum.chunk_every(3)
      |> Enum.map_join(".", &Enum.join/1)
      |> String.reverse()

    "#{currency} #{sign}#{whole}#{if exponent > 0, do: "," <> fraction, else: ""}"
  end

  def money(amount_minor, currency),
    do: "#{amount_minor} #{currency} minor (#{format(amount_minor, currency)})"

  def print_balances(merchant, currency) do
    case Enum.find(Ledger.balances({:merchant, merchant.id}), &(&1.currency == currency)) do
      nil ->
        IO.puts("  merchant balance: none yet")

      b ->
        IO.puts(
          "  merchant balance #{format(b.balance_minor, currency)}" <>
            " | held #{format(b.held_minor, currency)}" <>
            " | available #{format(b.available_minor, currency)}"
        )
    end
  end

  def deliver(delivery) do
    {:ok, first} = Webhooks.ingest("simulated", delivery.body, delivery.headers)
    {:ok, second} = Webhooks.ingest("simulated", delivery.body, delivery.headers)
    IO.puts("  webhook delivered twice: #{inspect(first)}, then #{inspect(second)}")
  end

  # One delivery only, for the later steps of a payment.
  def deliver_once(delivery) do
    {:ok, result} = Webhooks.ingest("simulated", delivery.body, delivery.headers)
    IO.puts("  webhook delivered: #{inspect(result)}")
  end

  def wait_for(merchant, intent, status, timeout_ms \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_wait(merchant, intent, status, deadline)
  end

  defp do_wait(merchant, intent, status, deadline) do
    {:ok, current} = Payments.fetch_intent(merchant.id, intent.id)

    cond do
      current.status == status ->
        IO.puts("  intent is #{status}")
        current

      System.monotonic_time(:millisecond) > deadline ->
        fail!("intent #{intent.id} stayed #{current.status}, expected #{status} within 10 s")

      true ->
        Process.sleep(50)
        do_wait(merchant, intent, status, deadline)
    end
  end

  # Creates and confirms an intent, then returns the intent and its attempt reference.
  def open_payment(merchant, key, amount_minor, currency) do
    {:ok, intent} =
      Payments.create_intent(merchant, key, %{
        "amount_minor" => amount_minor,
        "currency" => Atom.to_string(currency),
        "description" => "demo payment #{key}"
      })

    IO.puts("  intent #{intent.id}: #{money(amount_minor, currency)}, status #{intent.status}")
    intent
  end

  def confirm(merchant, intent) do
    {:ok, confirmed} = Payments.confirm_intent(merchant.id, intent.id, "simulated")
    attempt = hd(confirmed.attempts)
    IO.puts("  confirmed with simulated: status #{confirmed.status}, reference #{attempt.id}")
    IO.puts("  payer sees QR payload: #{attempt.payment_data["qr"]}")
    {confirmed, attempt.id}
  end
end

# 1. Events from the outbox. A separate process subscribes and prints them as they arrive.
parent = self()

spawn_link(fn ->
  Phoenix.PubSub.subscribe(Chebit.PubSub, "events")
  send(parent, :subscribed)

  loop = fn loop ->
    receive do
      {:chebit_event, event} ->
        IO.puts("    [event] #{event.type} (status #{event.payload["status"]})")
        loop.(loop)
    end
  end

  loop.(loop)
end)

receive do
  :subscribed -> :ok
end

IO.puts("Chebit demo: payments through the simulated provider")
IO.puts("Outbox events print as [event] lines, when the outbox job publishes them.")

# 2. Merchant
Demo.step("Merchant")

{:ok, %{merchant: merchant}} =
  Merchants.create_merchant(%{name: "Parrilla Don Julián", fee_bps: 250})

IO.puts("  #{merchant.name}, id #{merchant.id}, fee #{merchant.fee_bps} bps (2,50%)")

# 3. Payment A
Demo.step("Payment A: ARS 15.000,00, card-like (paid first, final later)")
a = Demo.open_payment(merchant, "demo-a", 1_500_000, :ARS)

request_a = %{
  "amount_minor" => 1_500_000,
  "currency" => "ARS",
  "description" => "demo payment demo-a"
}

{:ok, again} = Payments.create_intent(merchant, "demo-a", request_a)
IO.puts("  create again with the same key and request: same id? #{again.id == a.id}")

{:error, changeset} =
  Payments.create_intent(merchant, "demo-a", %{request_a | "amount_minor" => 1_600_000})

{reason, _opts} = changeset.errors[:idempotency_key]
IO.puts("  same key with another amount: refused, idempotency_key #{reason}")
{_confirmed, ref_a} = Demo.confirm(merchant, a)
{:ok, delivery} = Simulated.pay(ref_a, :delayed)
IO.puts("  payer paid (delayed finality)")
Demo.deliver(delivery)
Demo.wait_for(merchant, a, :paid)
Demo.print_balances(merchant, :ARS)
IO.puts("  expected: fee 37500, merchant share 1462500, all held")
{:ok, delivery} = Simulated.finalize(ref_a)
IO.puts("  chargeback window ended")
Demo.deliver_once(delivery)
Demo.wait_for(merchant, a, :final)
Demo.print_balances(merchant, :ARS)

# 4. Payment B
Demo.step("Payment B: BTC 50.000 sats, Lightning-like (final at once)")
b = Demo.open_payment(merchant, "demo-b", 50_000, :BTC)
{_confirmed, ref_b} = Demo.confirm(merchant, b)
{:ok, delivery} = Simulated.pay(ref_b, :instant)
IO.puts("  payer paid (instant finality)")
Demo.deliver_once(delivery)
Demo.wait_for(merchant, b, :final)
Demo.print_balances(merchant, :BTC)
IO.puts("  expected: fee 1250 sats, merchant share 48750 sats, all available")

# 5. Payment C
Demo.step("Payment C: ARS 8.000,00, refunded")
c = Demo.open_payment(merchant, "demo-c", 800_000, :ARS)
{_confirmed, ref_c} = Demo.confirm(merchant, c)
{:ok, delivery} = Simulated.pay(ref_c, :delayed)
IO.puts("  payer paid (delayed finality)")
Demo.deliver_once(delivery)
Demo.wait_for(merchant, c, :paid)
Demo.print_balances(merchant, :ARS)
{:ok, delivery} = Simulated.refund(ref_c)
IO.puts("  provider refunded the payer")
Demo.deliver_once(delivery)
Demo.wait_for(merchant, c, :refunded)
Demo.print_balances(merchant, :ARS)
IO.puts("  expected: payment C nets to zero, ARS balance is still A's 1462500")

# Let the outbox publish the last events.
Process.sleep(300)

# 6. Ledger
Demo.step("Ledger transactions, in order")

accounts = Account |> Repo.all() |> Map.new(&{&1.id, &1})

transactions = Repo.all(from t in Transaction, order_by: [t.inserted_at, t.id])

for transaction <- transactions do
  IO.puts("  #{transaction.kind} (#{transaction.source_type} #{transaction.source_id})")

  postings =
    Repo.all(from p in Posting, where: p.transaction_id == ^transaction.id, order_by: p.id)

  for posting <- postings do
    account = Map.fetch!(accounts, posting.account_id)

    owner =
      case account.owner_type do
        :house -> "house"
        type -> "#{type} #{String.slice(account.owner_id, 0, 8)}"
      end

    IO.puts(
      "    #{String.pad_trailing(Atom.to_string(posting.direction), 6)}" <>
        " #{String.pad_trailing(owner, 18)} #{String.pad_trailing(account.kind, 20)}" <>
        " #{Demo.money(posting.amount_minor, posting.currency)}"
    )
  end
end

# 7. Checks
Demo.step("Ledger audit")
audit = Audit.run()
IO.puts("  #{inspect(audit)}")

Demo.step("Reconciliation with the simulated provider")
{:ok, report} = Reconciliation.run("simulated")
IO.puts("  provider: #{report.provider}")
IO.puts("  matched payments: #{report.matched}")
IO.puts("  discrepancies: #{inspect(report.discrepancies)}")

for t <- report.totals do
  IO.puts(
    "  total #{t.currency}: provider #{Demo.format(t.provider_minor, t.currency)}" <>
      " | ledger #{Demo.format(t.ledger_minor, t.currency)}" <>
      " | difference #{Demo.format(t.difference_minor, t.currency)}" <>
      " (#{t.provider_minor} / #{t.ledger_minor} / #{t.difference_minor} minor)"
  )
end

IO.puts("  balanced?: #{report.balanced?}")

Demo.step("Coverage (invariant 8)")
{:ok, coverage} = Reconciliation.coverage()

for c <- coverage do
  IO.puts(
    "  #{c.currency}: custody #{Demo.format(c.custody_minor, c.currency)}" <>
      " | owed #{Demo.format(c.owed_minor, c.currency)} | covered? #{c.covered?}"
  )
end

# 8. Verdict
IO.puts("")

if audit == [] and report.balanced? and coverage != [] and Enum.all?(coverage, & &1.covered?) do
  IO.puts("DEMO OK")
else
  IO.puts("DEMO FAILED")
  System.halt(1)
end
