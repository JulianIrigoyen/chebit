defmodule ChebitWeb.Plugs.Respond do
  @moduledoc "Sends a `{status, body}` pair as JSON."
  import Plug.Conn

  @spec error(Plug.Conn.t(), {pos_integer(), map()}) :: Plug.Conn.t()
  def error(conn, {status, body}), do: conn |> put_status(status) |> Phoenix.Controller.json(body)
end
