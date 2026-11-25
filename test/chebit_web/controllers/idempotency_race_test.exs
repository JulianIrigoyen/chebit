defmodule ChebitWeb.IdempotencyRaceTest do
  use Chebit.UnboxedCase

  import Chebit.Fixtures
  import Phoenix.ConnTest, only: [build_conn: 0, json_response: 2]
  import ChebitWeb.ConnCase, only: [post_api: 5]

  test "20 concurrent identical creates make one intent" do
    %{api_key: key} = merchant_fixture()
    body = %{"amount_minor" => 700, "currency" => "ARS"}

    results =
      race(
        for _ <- 1..20 do
          fn -> post_api(build_conn(), key, "/v1/payment_intents", body, "race-key") end
        end
      )

    assert Repo.aggregate(Chebit.Payments.Intent, :count) == 1
    assert Enum.all?(results, &(&1.status in [201, 409]))

    for c <- results, c.status == 409 do
      assert %{"error" => %{"code" => "request_in_progress"}} = json_response(c, 409)
    end

    created = for c <- results, c.status == 201, do: json_response(c, 201)
    assert created != []
    assert created |> Enum.uniq() |> length() == 1
  end
end
