defmodule Chebit.Providers.Simulated do
  @moduledoc """
  A provider that lives in memory. It behaves like a real one, and a test or the demo plays
  the payer.

  It is a GenServer with one map of payments, keyed by `reference`. It implements
  `Chebit.Providers.Provider`. The functions below the callbacks are the controls of the
  simulation: they do what a payer, a card network or an outage does.

  ## Behaviour

  - `create_payment/1` is idempotent on `reference`. `external_id` is `"sim_" <> random`.
    `payment_data` is `%{"qr" => "simulated:" <> external_id}`.
  - Each control that changes a payment returns a signed webhook, ready to POST to
    `/webhooks/simulated`. The simulator does not deliver it: the caller does, so a test can
    deliver it twice, late, out of order, or never.

  ## Webhook format

  The body is JSON: `{"id": event_id, "type": "payment.updated", "reference": reference,
  "external_id": external_id}`. The header `x-simulated-signature` holds the lower-case hex
  HMAC-SHA256 of the raw body, keyed with the config value `:webhook_secret`. Compare
  signatures with `Plug.Crypto.secure_compare/2`.
  """
  @behaviour Chebit.Providers.Provider

  use GenServer

  @signature_header "x-simulated-signature"

  alias Chebit.Providers.Provider

  @type webhook_delivery :: %{body: binary(), headers: [{String.t(), String.t()}]}
  @type finality :: :instant | :delayed

  @doc "Starts the simulator under the application supervisor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl GenServer
  def init(:ok), do: {:ok, new_state()}

  # Provider callbacks

  @impl Provider
  def create_payment(request), do: GenServer.call(__MODULE__, {:create, request})

  @impl Provider
  def fetch_payment(reference), do: GenServer.call(__MODULE__, {:fetch, reference})

  @impl Provider
  def verify_webhook(raw_body, headers) when is_binary(raw_body) do
    with {:ok, signature} <- find_signature(headers),
         true <- Plug.Crypto.secure_compare(signature, sign(raw_body)) do
      parse_event(raw_body)
    else
      _other -> {:error, :invalid_signature}
    end
  end

  def verify_webhook(_raw_body, _headers), do: {:error, :invalid_signature}

  @impl Provider
  def list_payments, do: GenServer.call(__MODULE__, :list)

  # Simulation controls

  @doc """
  The payer pays. A pending payment becomes `:final` with `:instant` finality (Lightning,
  Transferencias 3.0) or `:paid` with `:delayed` finality (cards).
  """
  @spec pay(String.t(), finality()) ::
          {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def pay(reference, finality \\ :instant),
    do: GenServer.call(__MODULE__, {:pay, reference, finality})

  @doc "The chargeback window ends, or the dispute is won: `:paid` or `:disputed` becomes `:final`."
  @spec finalize(String.t()) :: {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def finalize(reference), do: GenServer.call(__MODULE__, {:finalize, reference})

  @doc "The payment fails with a reason code: `:pending` becomes `:failed`."
  @spec fail(String.t(), String.t()) ::
          {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def fail(reference, failure_reason),
    do: GenServer.call(__MODULE__, {:fail, reference, failure_reason})

  @doc "The payment expires at the provider: `:pending` becomes `:expired`."
  @spec expire(String.t()) :: {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def expire(reference), do: GenServer.call(__MODULE__, {:expire, reference})

  @doc "The payer opens a dispute: `:paid` becomes `:disputed`."
  @spec dispute(String.t()) :: {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def dispute(reference), do: GenServer.call(__MODULE__, {:dispute, reference})

  @doc "The provider returns the money to the payer: `:paid` or `:disputed` becomes `:refunded`."
  @spec refund(String.t()) :: {:ok, webhook_delivery()} | {:error, :not_found | :invalid_state}
  def refund(reference), do: GenServer.call(__MODULE__, {:refund, reference})

  @doc """
  Makes the next `create_payment/1` call for `reference` misbehave once.

  - `:decline` - returns `{:error, :declined}` and creates nothing.
  - `:unavailable_before` - returns `{:error, :unavailable}` and creates nothing.
  - `:unavailable_after` - creates the payment, then returns `{:error, :unavailable}`.
    This is the lost reply: the caller cannot know that the payment exists.
  """
  @spec fault_next_create(String.t(), :decline | :unavailable_before | :unavailable_after) :: :ok
  def fault_next_create(reference, fault),
    do: GenServer.call(__MODULE__, {:fault, reference, fault})

  @doc "Makes `fetch_payment/1` and `list_payments/0` return `{:error, :unavailable}` while `down?` is true."
  @spec set_outage(boolean()) :: :ok
  def set_outage(down?), do: GenServer.call(__MODULE__, {:outage, down?})

  @doc "Counts how many times the provider really created a payment for `reference`: 0 or 1."
  @spec created_count(String.t()) :: non_neg_integer()
  def created_count(reference), do: GenServer.call(__MODULE__, {:created_count, reference})

  @doc "Builds a signed webhook for the current state of a payment, with a new event id."
  @spec webhook_for(String.t()) :: {:ok, webhook_delivery()} | {:error, :not_found}
  def webhook_for(reference), do: GenServer.call(__MODULE__, {:webhook_for, reference})

  @doc "Forgets each payment and each fault. For tests that read `list_payments/0`."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Server callbacks

  @impl GenServer
  def handle_call({:create, request}, _from, state), do: create(request, state)

  def handle_call({:fetch, reference}, _from, state) do
    reply =
      cond do
        state.outage -> {:error, :unavailable}
        payment = state.payments[reference] -> {:ok, payment}
        true -> {:error, :not_found}
      end

    {:reply, reply, state}
  end

  def handle_call(:list, _from, %{outage: true} = state),
    do: {:reply, {:error, :unavailable}, state}

  def handle_call(:list, _from, state), do: {:reply, {:ok, Map.values(state.payments)}, state}

  def handle_call({:pay, reference, :instant}, _from, state),
    do: move(state, reference, [:pending], %{status: :final})

  def handle_call({:pay, reference, :delayed}, _from, state),
    do: move(state, reference, [:pending], %{status: :paid})

  def handle_call({:pay, _reference, _finality}, _from, state),
    do: {:reply, {:error, :invalid_state}, state}

  def handle_call({:finalize, reference}, _from, state),
    do: move(state, reference, [:paid, :disputed], %{status: :final})

  def handle_call({:fail, reference, reason}, _from, state),
    do: move(state, reference, [:pending], %{status: :failed, failure_reason: reason})

  def handle_call({:expire, reference}, _from, state),
    do: move(state, reference, [:pending], %{status: :expired})

  def handle_call({:dispute, reference}, _from, state),
    do: move(state, reference, [:paid], %{status: :disputed})

  def handle_call({:refund, reference}, _from, state),
    do: move(state, reference, [:paid, :disputed], %{status: :refunded})

  def handle_call({:fault, reference, fault}, _from, state)
      when fault in [:decline, :unavailable_before, :unavailable_after] do
    {:reply, :ok, put_in(state.faults[reference], fault)}
  end

  def handle_call({:outage, down?}, _from, state) when is_boolean(down?),
    do: {:reply, :ok, %{state | outage: down?}}

  def handle_call({:created_count, reference}, _from, state),
    do: {:reply, Map.get(state.created, reference, 0), state}

  def handle_call({:webhook_for, reference}, _from, state) do
    case state.payments do
      %{^reference => payment} -> {:reply, {:ok, delivery(payment)}, state}
      _none -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:reset, _from, _state), do: {:reply, :ok, new_state()}

  defp new_state, do: %{payments: %{}, faults: %{}, outage: false, created: %{}}

  # A pending fault applies to the next create call for the reference, then it clears.
  defp create(%{reference: reference} = request, state) do
    {fault, faults} = Map.pop(state.faults, reference)
    state = %{state | faults: faults}

    case fault do
      :decline ->
        {:reply, {:error, :declined}, state}

      :unavailable_before ->
        {:reply, {:error, :unavailable}, state}

      :unavailable_after ->
        {_payment, state} = ensure_payment(request, state)
        {:reply, {:error, :unavailable}, state}

      nil ->
        {payment, state} = ensure_payment(request, state)
        {:reply, {:ok, payment}, state}
    end
  end

  defp create(_request, state), do: {:reply, {:error, :unavailable}, state}

  defp ensure_payment(%{reference: reference} = request, state) do
    case state.payments do
      %{^reference => payment} ->
        {payment, state}

      _none ->
        external_id = "sim_" <> random_hex()

        payment = %{
          external_id: external_id,
          reference: reference,
          status: :pending,
          amount_minor: request.amount_minor,
          currency: request.currency,
          payment_data: %{"qr" => "simulated:" <> external_id},
          failure_reason: nil
        }

        state = %{
          state
          | payments: Map.put(state.payments, reference, payment),
            created: Map.update(state.created, reference, 1, &(&1 + 1))
        }

        {payment, state}
    end
  end

  defp move(state, reference, allowed_from, changes) do
    case state.payments do
      %{^reference => %{status: status} = payment} ->
        if status in allowed_from do
          payment = Map.merge(payment, changes)
          {:reply, {:ok, delivery(payment)}, put_in(state.payments[reference], payment)}
        else
          {:reply, {:error, :invalid_state}, state}
        end

      _none ->
        {:reply, {:error, :not_found}, state}
    end
  end

  defp delivery(payment) do
    body =
      Jason.encode!(%{
        "id" => "evt_" <> random_hex(),
        "type" => "payment.updated",
        "reference" => payment.reference,
        "external_id" => payment.external_id
      })

    %{body: body, headers: [{@signature_header, sign(body)}]}
  end

  defp random_hex, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  defp sign(body) do
    :hmac |> :crypto.mac(:sha256, secret(), body) |> Base.encode16(case: :lower)
  end

  defp secret, do: Application.fetch_env!(:chebit, __MODULE__)[:webhook_secret]

  # Reads the header without raising on a header list of any shape.
  defp find_signature([{@signature_header, signature} | _rest]) when is_binary(signature),
    do: {:ok, signature}

  defp find_signature([_other | rest]), do: find_signature(rest)
  defp find_signature(_none), do: :error

  defp parse_event(raw_body) do
    case Jason.decode(raw_body) do
      {:ok, %{"id" => id, "reference" => reference}}
      when is_binary(id) and is_binary(reference) ->
        {:ok, %{event_id: id, reference: reference}}

      _other ->
        {:error, :malformed}
    end
  end
end
