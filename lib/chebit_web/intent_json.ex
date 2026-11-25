defmodule ChebitWeb.IntentJSON do
  @moduledoc "The public JSON of a payment intent. It never shows the merchant id, the key or attempt internals."
  alias Chebit.Payments.Intent

  @doc "Renders an intent. Attempts must be preloaded for `next_action`."
  @spec render(Intent.t()) :: map()
  def render(%Intent{} = intent) do
    %{
      "id" => intent.id,
      "status" => to_string(intent.status),
      "amount_minor" => intent.amount_minor,
      "currency" => to_string(intent.currency),
      "description" => intent.description,
      "metadata" => intent.metadata,
      "failure_reason" => intent.failure_reason,
      "expires_at" => DateTime.to_iso8601(intent.expires_at),
      "created_at" => DateTime.to_iso8601(intent.inserted_at),
      "next_action" => next_action(intent)
    }
  end

  defp next_action(%Intent{status: :pending, attempts: attempts}) when is_list(attempts) do
    case Enum.find(attempts, &(&1.status == :dispatched)) do
      nil -> nil
      attempt -> %{"provider" => attempt.provider, "payment_data" => attempt.payment_data}
    end
  end

  defp next_action(_intent), do: nil
end
