defmodule ChebitWeb.ErrorJSONTest do
  use ChebitWeb.ConnCase, async: true

  test "renders 404" do
    assert ChebitWeb.ErrorJSON.render("404.json", %{}) ==
             %{"error" => %{"code" => "not_found", "message" => "Not Found."}}
  end

  test "renders 500" do
    assert %{"error" => %{"code" => "internal_error", "message" => message}} =
             ChebitWeb.ErrorJSON.render("500.json", %{})

    assert is_binary(message)
  end

  test "an unknown route gives the error body", %{conn: conn} do
    conn = get(conn, "/nope")
    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end
end
