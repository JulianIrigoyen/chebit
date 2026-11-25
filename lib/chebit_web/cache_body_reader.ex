defmodule ChebitWeb.CacheBodyReader do
  @moduledoc """
  Body reader for `Plug.Parsers`. It keeps the exact request bytes in `conn.assigns[:raw_body]`.

  A provider signs the raw bytes of a webhook. Parsed JSON loses them. The value is a list of
  chunks in reverse order. Use `raw_body/1` to read it.
  """
  @doc "Reads the body like `Plug.Conn.read_body/2` and keeps each chunk."
  @spec read_body(Plug.Conn.t(), keyword()) ::
          {:ok, binary(), Plug.Conn.t()} | {:more, binary(), Plug.Conn.t()} | {:error, term()}
  def read_body(conn, opts) do
    case Plug.Conn.read_body(conn, opts) do
      {status, body, conn} when status in [:ok, :more] ->
        {status, body, update_in(conn.assigns[:raw_body], &[body | &1 || []])}

      other ->
        other
    end
  end

  @doc "Returns the request body as one binary. It is empty when the parser did not read a body."
  @spec raw_body(Plug.Conn.t()) :: binary()
  def raw_body(conn), do: (conn.assigns[:raw_body] || []) |> Enum.reverse() |> Enum.join()
end
