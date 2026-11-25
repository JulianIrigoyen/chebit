defmodule ChebitWeb.HealthController do
  use ChebitWeb, :controller

  def show(conn, _params), do: json(conn, %{"status" => "ok"})
end
