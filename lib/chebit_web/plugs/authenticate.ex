defmodule ChebitWeb.Plugs.Authenticate do
  @moduledoc "Finds the merchant from `authorization: Bearer <api key>`. Anything else is 401."
  import Plug.Conn

  alias ChebitWeb.ApiError
  alias ChebitWeb.Plugs.Respond

  @spec init(term()) :: term()
  def init(opts), do: opts

  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(conn, _opts) do
    with ["Bearer " <> key] <- get_req_header(conn, "authorization"),
         {:ok, merchant} <- Chebit.Merchants.authenticate(key) do
      assign(conn, :merchant, merchant)
    else
      _ -> conn |> Respond.error(ApiError.to_response(:unauthorized)) |> halt()
    end
  end
end
