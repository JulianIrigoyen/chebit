defmodule ChebitWeb.WebhookController do
  use ChebitWeb, :controller

  alias ChebitWeb.ApiError
  alias ChebitWeb.CacheBodyReader
  alias ChebitWeb.Plugs.Respond

  # A webhook body above this size is not read. Its signature check then fails.
  @max_body_bytes 1_000_000

  # The signature covers the exact bytes, so this reads the raw body and not `body_params`.
  def create(conn, %{"provider" => provider}) do
    case Chebit.Webhooks.ingest(provider, raw_body(conn), conn.req_headers) do
      {:ok, status} when status in [:accepted, :duplicate] -> json(conn, %{"received" => true})
      {:error, reason} -> Respond.error(conn, ApiError.webhook_response(reason))
    end
  end

  # `Plug.Parsers` reads the body only for a content type that it parses. A provider can
  # send another one, such as `text/plain`. Then the body is still unread.
  defp raw_body(conn) do
    with "" <- CacheBodyReader.raw_body(conn),
         {:ok, body, _conn} <- Plug.Conn.read_body(conn, length: @max_body_bytes) do
      body
    else
      body when is_binary(body) -> body
      _too_large_or_error -> ""
    end
  end
end
