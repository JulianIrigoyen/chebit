defmodule ChebitWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use ChebitWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint ChebitWeb.Endpoint

      use ChebitWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import ChebitWeb.ConnCase
    end
  end

  setup tags do
    Chebit.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Adds the bearer header of an API key to a conn."
  @spec authenticated(Plug.Conn.t(), String.t()) :: Plug.Conn.t()
  def authenticated(conn, api_key),
    do: Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> api_key)

  @doc "POSTs JSON as a merchant. `idem` sets the `idempotency-key` header when it is a string."
  @spec post_api(Plug.Conn.t(), String.t(), String.t(), term(), String.t() | nil) :: Plug.Conn.t()
  def post_api(conn, api_key, path, body, idem \\ nil) do
    conn = authenticated(conn, api_key)
    conn = if idem, do: Plug.Conn.put_req_header(conn, "idempotency-key", idem), else: conn
    conn = Plug.Conn.put_req_header(conn, "content-type", "application/json")

    # The body goes over the wire as JSON text, so the real parser reads it.
    Phoenix.ConnTest.dispatch(conn, ChebitWeb.Endpoint, :post, path, Jason.encode!(body))
  end
end
