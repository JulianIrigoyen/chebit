defmodule ChebitWeb.PaymentIntentController do
  use ChebitWeb, :controller

  alias Chebit.Idempotency
  alias Chebit.Payments
  alias ChebitWeb.ApiError
  alias ChebitWeb.IntentJSON
  alias ChebitWeb.Plugs.Respond

  plug ChebitWeb.Plugs.IdempotencyKey when action in [:create, :confirm]

  def create(conn, _params) do
    merchant = conn.assigns.merchant
    key = conn.assigns.idempotency_key

    idempotent(conn, fn ->
      case Payments.create_intent(merchant, key, conn.body_params) do
        {:ok, intent} -> {201, IntentJSON.render(intent)}
        {:error, reason} -> ApiError.to_response(reason)
      end
    end)
  end

  def show(conn, %{"id" => id}) do
    case Payments.fetch_intent(conn.assigns.merchant.id, id) do
      {:ok, intent} -> conn |> put_status(200) |> json(IntentJSON.render(intent))
      {:error, reason} -> Respond.error(conn, ApiError.to_response(reason))
    end
  end

  def confirm(conn, %{"id" => id}) do
    merchant_id = conn.assigns.merchant.id

    idempotent(conn, fn ->
      with {:ok, provider} <- provider_param(conn.body_params),
           {:ok, _intent} <- Payments.confirm_intent(merchant_id, id, provider),
           {:ok, intent} <- Payments.fetch_intent(merchant_id, id) do
        {202, IntentJSON.render(intent)}
      else
        {:error, reason} -> ApiError.to_response(reason)
      end
    end)
  end

  # The provider comes from the JSON body only. A value in the query string would not be
  # part of what the client signed up to repeat.
  defp provider_param(%{"provider" => provider}) when is_binary(provider), do: {:ok, provider}
  defp provider_param(_body), do: {:error, :invalid_request}

  # Runs the request once for the key. A stored response, error or not, is replayed.
  defp idempotent(conn, fun) do
    if json_body?(conn) do
      run_once(conn, fun)
    else
      Respond.error(conn, ApiError.to_response(:unsupported_media_type))
    end
  end

  # Only a JSON body is parsed. Any other body would hash as empty, whatever it holds.
  defp json_body?(conn) do
    match?(["application/json" <> _rest], get_req_header(conn, "content-type"))
  end

  # The hash covers the method, the path with its query string, and the parsed body.
  defp run_once(conn, fun) do
    target = conn.request_path <> "?" <> conn.query_string
    hash = Idempotency.request_hash(conn.method, target, conn.body_params)

    case Idempotency.run(conn.assigns.merchant.id, conn.assigns.idempotency_key, hash, fun) do
      {:ok, %{status: status, body: body, replayed?: replayed?}} ->
        conn = if replayed?, do: put_resp_header(conn, "idempotent-replayed", "true"), else: conn
        conn |> put_status(status) |> json(body)

      {:error, reason} ->
        Respond.error(conn, ApiError.to_response(reason))
    end
  end
end
