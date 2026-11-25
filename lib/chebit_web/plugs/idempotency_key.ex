defmodule ChebitWeb.Plugs.IdempotencyKey do
  @moduledoc "Reads the `idempotency-key` header (1 to 255 characters) into `conn.assigns.idempotency_key`."
  import Plug.Conn

  alias ChebitWeb.ApiError
  alias ChebitWeb.Plugs.Respond

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    case get_req_header(conn, "idempotency-key") do
      [key] when byte_size(key) > 0 ->
        if String.length(key) <= 255 and String.valid?(key) do
          assign(conn, :idempotency_key, key)
        else
          reject(conn)
        end

      _ ->
        reject(conn)
    end
  end

  defp reject(conn),
    do:
      conn
      |> Respond.error(ApiError.to_response(:idempotency_key_required))
      |> halt()
end
