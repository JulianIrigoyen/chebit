defmodule ChebitWeb.ErrorJSON do
  @moduledoc """
  Renders framework errors (an unknown route, a bad body, a crash) in the API error shape.
  """
  alias ChebitWeb.ApiError

  @doc "Renders `404.json`, `500.json` and each other status template."
  @spec render(String.t(), map()) :: map()
  def render("500.json", _assigns),
    do: ApiError.body("internal_error", "Something went wrong on our side.")

  def render(template, _assigns) do
    message = Phoenix.Controller.status_message_from_template(template)
    code = message |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")
    ApiError.body(code, message <> ".")
  end
end
