defmodule ChebitWeb.WebhookControllerTest do
  use ChebitWeb.ConnCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  import Chebit.Fixtures

  alias Chebit.Payments
  alias Chebit.Providers.Simulated
  alias Chebit.Repo
  alias Chebit.Webhooks.ProcessWorker
  alias Chebit.Webhooks.ProviderEvent

  setup do
    %{merchant: merchant, api_key: key} = merchant_fixture()
    %{merchant: merchant, key: key}
  end

  # Creates and confirms an intent through HTTP. Returns the intent id and the attempt id.
  defp confirmed_intent(conn, key, merchant, amount \\ 2500) do
    %{"id" => id} =
      conn
      |> post_api(
        key,
        "/v1/payment_intents",
        %{"amount_minor" => amount, "currency" => "ARS"},
        "create-#{System.unique_integer([:positive])}"
      )
      |> json_response(201)

    conn
    |> post_api(
      key,
      "/v1/payment_intents/#{id}/confirm",
      %{"provider" => "simulated"},
      "confirm-#{id}"
    )
    |> json_response(202)

    {:ok, %{attempts: [attempt]}} = Payments.fetch_intent(merchant.id, id)
    {id, attempt.id}
  end

  defp post_hook(conn, provider, body, headers) do
    conn = put_req_header(conn, "content-type", "application/json")
    conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
    post(conn, "/webhooks/#{provider}", body)
  end

  defp get_intent(conn, key, id),
    do: conn |> authenticated(key) |> get("/v1/payment_intents/#{id}") |> json_response(200)

  defp balances(conn, key),
    do: conn |> authenticated(key) |> get("/v1/balances") |> json_response(200)

  describe "POST /webhooks/:provider" do
    test "stores a valid webhook once and queues one job", %{
      conn: conn,
      key: key,
      merchant: merchant
    } do
      {_id, attempt_id} = confirmed_intent(conn, key, merchant)
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt_id, :instant)

      assert %{"received" => true} =
               conn |> post_hook("simulated", body, headers) |> json_response(200)

      assert Repo.aggregate(ProviderEvent, :count) == 1
      assert [_] = all_enqueued(worker: ProcessWorker)

      assert %{"received" => true} =
               conn |> post_hook("simulated", body, headers) |> json_response(200)

      assert Repo.aggregate(ProviderEvent, :count) == 1
      assert [_] = all_enqueued(worker: ProcessWorker)
    end

    test "a tampered body gives 401 and stores nothing", %{
      conn: conn,
      key: key,
      merchant: merchant
    } do
      {_id, attempt_id} = confirmed_intent(conn, key, merchant)
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt_id, :instant)

      c = post_hook(conn, "simulated", body <> " ", headers)
      assert %{"error" => %{"code" => "invalid_signature"}} = json_response(c, 401)
      assert Repo.aggregate(ProviderEvent, :count) == 0
    end

    test "no signature gives 401", %{conn: conn, key: key, merchant: merchant} do
      {_id, attempt_id} = confirmed_intent(conn, key, merchant)
      {:ok, %{body: body}} = Simulated.pay(attempt_id, :instant)

      c = post_hook(conn, "simulated", body, [])
      assert %{"error" => %{"code" => "invalid_signature"}} = json_response(c, 401)
      assert Repo.aggregate(ProviderEvent, :count) == 0
    end

    test "a body with a content type that no parser reads is still verified", %{
      conn: conn,
      key: key,
      merchant: merchant
    } do
      {_id, attempt_id} = confirmed_intent(conn, key, merchant)
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt_id)

      conn = put_req_header(build_conn(), "content-type", "text/plain")
      conn = Enum.reduce(headers, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)

      assert conn |> post("/webhooks/simulated", body) |> json_response(200) == %{
               "received" => true
             }

      assert [%ProviderEvent{raw_body: ^body}] = Repo.all(ProviderEvent)
    end

    test "an unknown provider gives 404", %{conn: conn} do
      c = post_hook(conn, "nope", ~s({"a":1}), [])
      assert %{"error" => %{"code" => "not_found"}} = json_response(c, 404)
    end
  end

  describe "end to end" do
    test "instant payment: final, no next_action, balance available", %{
      conn: conn,
      key: key,
      merchant: merchant
    } do
      {id, attempt_id} = confirmed_intent(conn, key, merchant, 2500)
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt_id, :instant)

      assert json_response(post_hook(conn, "simulated", body, headers), 200)
      assert %{success: 1} = Oban.drain_queue(queue: :webhooks)

      assert %{"status" => "final", "next_action" => nil} = get_intent(conn, key, id)

      assert %{
               "data" => [
                 %{
                   "currency" => "ARS",
                   "balance_minor" => 2500,
                   "held_minor" => 0,
                   "available_minor" => 2500
                 }
               ]
             } =
               balances(conn, key)
    end

    test "delayed payment: paid, all of it held", %{conn: conn, key: key, merchant: merchant} do
      {id, attempt_id} = confirmed_intent(conn, key, merchant, 2500)
      {:ok, %{body: body, headers: headers}} = Simulated.pay(attempt_id, :delayed)

      assert json_response(post_hook(conn, "simulated", body, headers), 200)
      assert %{success: 1} = Oban.drain_queue(queue: :webhooks)

      assert %{"status" => "paid", "next_action" => nil} = get_intent(conn, key, id)

      assert %{
               "data" => [
                 %{"balance_minor" => 2500, "held_minor" => 2500, "available_minor" => 0}
               ]
             } =
               balances(conn, key)
    end

    test "a merchant with no payments has no balances", %{conn: conn, key: key} do
      assert %{"data" => []} = balances(conn, key)
    end
  end
end
