defmodule ChebitWeb.ApiError do
  @moduledoc """
  Maps a domain error to an HTTP status and the error body.

  The body is always `{"error": {"code", "message"}}`. An error atom that this module does
  not know gives 500 `internal_error` and a log line. The client never sees the reason.
  """
  require Logger

  @type response :: {pos_integer(), map()}

  @doc "Builds the error body for a status, a code and a message."
  @spec body(String.t(), String.t()) :: map()
  def body(code, message), do: %{"error" => %{"code" => code, "message" => message}}

  @doc "Turns a domain error into `{status, body}`."
  @spec to_response(term()) :: response()
  def to_response(%Ecto.Changeset{} = changeset) do
    fields =
      Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
        Regex.replace(~r"%{(\w+)}", message, fn _, key ->
          opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
        end)
      end)

    body = body("invalid_request", "The request has invalid fields.")
    {422, put_in(body, ["error", "fields"], stringify(fields))}
  end

  def to_response(:not_found), do: {404, body("not_found", "The resource does not exist.")}

  def to_response(:unauthorized),
    do: {401, body("unauthorized", "The API key is missing or wrong.")}

  def to_response(:invalid_request),
    do: {422, body("invalid_request", "The request has invalid fields.")}

  def to_response(:unknown_provider),
    do: {422, body("unknown_provider", "The provider is not supported.")}

  def to_response(:invalid_state),
    do: {409, body("invalid_state", "The payment intent is not in a state that allows this.")}

  def to_response(:provider_declined),
    do: {422, body("provider_declined", "The provider declined the payment.")}

  def to_response(:provider_unavailable),
    do:
      {503,
       body("provider_unavailable", "The provider is not available. Retry with the same key.")}

  def to_response(:key_reused),
    do:
      {409,
       body("idempotency_key_reused", "The Idempotency-Key was used with a different request.")}

  def to_response(:in_progress),
    do:
      {409, body("request_in_progress", "A request with this Idempotency-Key is still running.")}

  def to_response(:unsupported_media_type),
    do: {415, body("unsupported_media_type", "Send the body as application/json.")}

  def to_response(:idempotency_key_required),
    do:
      {400,
       body(
         "idempotency_key_required",
         "The Idempotency-Key header is required, 1 to 255 characters."
       )}

  def to_response(other) do
    Logger.error("unmapped API error: #{inspect(other)}")
    {500, body("internal_error", "Something went wrong on our side.")}
  end

  @doc "Turns a webhook error into `{status, body}`."
  @spec webhook_response(term()) :: response()
  def webhook_response(:invalid_signature),
    do: {401, body("invalid_signature", "The webhook signature is not valid.")}

  def webhook_response(:malformed), do: {400, body("malformed", "The webhook body is malformed.")}

  def webhook_response(:unknown_provider),
    do: {404, body("not_found", "The resource does not exist.")}

  def webhook_response(other), do: to_response(other)

  defp stringify(map) when is_map(map),
    do: Map.new(map, fn {k, v} -> {to_string(k), stringify(v)} end)

  defp stringify(list) when is_list(list), do: Enum.map(list, &stringify/1)
  defp stringify(other), do: other
end
