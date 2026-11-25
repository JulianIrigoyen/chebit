defmodule ChebitWeb.PaymentIntentControllerTest do
  use ChebitWeb.ConnCase, async: true
  use Oban.Testing, repo: Chebit.Repo

  import Chebit.Fixtures

  alias Chebit.Payments
  alias Chebit.Payments.Attempt
  alias Chebit.Providers.Simulated
  alias Chebit.Repo

  @valid %{"amount_minor" => 1500, "currency" => "ARS", "description" => "Empanadas"}

  setup do
    %{merchant: merchant, api_key: key} = merchant_fixture()
    %{merchant: merchant, key: key}
  end

  defp create!(conn, key, body \\ @valid, idem \\ nil) do
    idem = idem || "k-#{System.unique_integer([:positive])}"
    conn |> post_api(key, "/v1/payment_intents", body, idem) |> json_response(201)
  end

  defp confirm(conn, key, id, body, idem),
    do: post_api(conn, key, "/v1/payment_intents/#{id}/confirm", body, idem)

  defp count(table), do: Repo.aggregate(table, :count)

  describe "health" do
    test "GET /healthz needs no auth", %{conn: conn} do
      assert %{"status" => "ok"} = conn |> get("/healthz") |> json_response(200)
    end
  end

  describe "authentication" do
    test "no header, wrong scheme and unknown key give 401 on each /v1 route", %{
      conn: conn,
      key: key
    } do
      id = Ecto.UUID.generate()

      requests = [
        {:post, "/v1/payment_intents"},
        {:get, "/v1/payment_intents/#{id}"},
        {:post, "/v1/payment_intents/#{id}/confirm"},
        {:get, "/v1/balances"}
      ]

      headers = [
        [],
        [{"authorization", "Basic " <> key}],
        [{"authorization", key}],
        [{"authorization", "Bearer chebit_sk_unknown"}],
        [{"authorization", "Bearer "}]
      ]

      for {method, path} <- requests, hs <- headers do
        c = Enum.reduce(hs, conn, fn {k, v}, acc -> put_req_header(acc, k, v) end)
        c = put_req_header(c, "idempotency-key", "k")
        c = dispatch(c, @endpoint, method, path, %{})

        assert %{"error" => %{"code" => "unauthorized"}} = json_response(c, 401)
      end
    end
  end

  describe "POST /v1/payment_intents" do
    test "creates an intent", %{conn: conn, key: key} do
      body = create!(conn, key)

      assert %{
               "id" => _,
               "status" => "created",
               "amount_minor" => 1500,
               "currency" => "ARS",
               "description" => "Empanadas",
               "metadata" => %{},
               "failure_reason" => nil,
               "next_action" => nil
             } = body

      assert {:ok, _, 0} = DateTime.from_iso8601(body["expires_at"])
      assert {:ok, _, 0} = DateTime.from_iso8601(body["created_at"])
      refute Map.has_key?(body, "merchant_id")
      refute Map.has_key?(body, "idempotency_key")
    end

    test "rejects invalid bodies with 422 and fields", %{conn: conn, key: key} do
      bad = [
        {%{}, ["amount_minor", "currency"]},
        {%{"amount_minor" => 100, "currency" => "XXX"}, ["currency"]},
        {%{"amount_minor" => 0, "currency" => "ARS"}, ["amount_minor"]},
        {%{"amount_minor" => -5, "currency" => "ARS"}, ["amount_minor"]},
        {%{"amount_minor" => 10.5, "currency" => "ARS"}, ["amount_minor"]},
        {%{"amount_minor" => "abc", "currency" => "ARS"}, ["amount_minor"]}
      ]

      for {body, fields} <- bad do
        c = post_api(conn, key, "/v1/payment_intents", body, "k-#{System.unique_integer()}")
        assert %{"error" => %{"code" => "invalid_request", "fields" => f}} = json_response(c, 422)
        for field <- fields, do: assert(is_list(f[field]), "#{inspect(body)} lacks #{field}")
      end

      assert count(Payments.Intent) == 0
    end

    test "a missing or bad Idempotency-Key gives 400", %{conn: conn, key: key} do
      for idem <- [nil, "", String.duplicate("a", 256)] do
        c = post_api(conn, key, "/v1/payment_intents", @valid, idem)
        assert %{"error" => %{"code" => "idempotency_key_required"}} = json_response(c, 400)
      end

      c = post_api(conn, key, "/v1/payment_intents", @valid, String.duplicate("a", 255))
      assert json_response(c, 201)
    end
  end

  describe "idempotency" do
    test "same key and body replays the first response", %{conn: conn, key: key} do
      c1 = post_api(conn, key, "/v1/payment_intents", @valid, "same")
      c2 = post_api(conn, key, "/v1/payment_intents", @valid, "same")

      assert c1.status == 201 and c2.status == 201
      assert c1.resp_body == c2.resp_body
      assert get_resp_header(c1, "idempotent-replayed") == []
      assert get_resp_header(c2, "idempotent-replayed") == ["true"]
      assert count(Payments.Intent) == 1
    end

    test "same key with another body gives 409", %{conn: conn, key: key} do
      post_api(conn, key, "/v1/payment_intents", @valid, "same")
      other = Map.put(@valid, "amount_minor", 99)
      c = post_api(conn, key, "/v1/payment_intents", other, "same")

      assert %{"error" => %{"code" => "idempotency_key_reused"}} = json_response(c, 409)
      assert count(Payments.Intent) == 1
    end

    test "a stored 422 is replayed", %{conn: conn, key: key} do
      c1 = post_api(conn, key, "/v1/payment_intents", %{}, "bad")
      c2 = post_api(conn, key, "/v1/payment_intents", %{}, "bad")

      assert c1.status == 422 and c2.status == 422
      assert c1.resp_body == c2.resp_body
      assert get_resp_header(c2, "idempotent-replayed") == ["true"]
    end

    test "the same key of two merchants is independent", %{conn: conn, key: key} do
      %{api_key: key2} = merchant_fixture()
      a = create!(conn, key, @valid, "shared")
      b = create!(conn, key2, @valid, "shared")

      assert a["id"] != b["id"]
      assert count(Payments.Intent) == 2
    end
  end

  describe "GET /v1/payment_intents/:id" do
    test "owner sees it, others get 404", %{conn: conn, key: key} do
      %{api_key: other} = merchant_fixture()
      %{"id" => id} = create!(conn, key)

      assert %{"id" => ^id} =
               conn
               |> authenticated(key)
               |> get("/v1/payment_intents/#{id}")
               |> json_response(200)

      c = conn |> authenticated(other) |> get("/v1/payment_intents/#{id}")
      assert %{"error" => %{"code" => "not_found"}} = json_response(c, 404)
    end

    test "a malformed id gives 404", %{conn: conn, key: key} do
      c = conn |> authenticated(key) |> get("/v1/payment_intents/not-a-uuid")
      assert %{"error" => %{"code" => "not_found"}} = json_response(c, 404)
    end
  end

  describe "POST /v1/payment_intents/:id/confirm" do
    setup %{conn: conn, key: key} do
      %{"id" => id} = create!(conn, key)
      %{id: id}
    end

    test "gives 202 pending with the QR, and replays on the same key", %{
      conn: conn,
      key: key,
      id: id
    } do
      c1 = confirm(conn, key, id, %{"provider" => "simulated"}, "c1")
      body = json_response(c1, 202)

      assert %{
               "status" => "pending",
               "next_action" => %{"provider" => "simulated", "payment_data" => %{"qr" => qr}}
             } = body

      assert is_binary(qr)

      c2 = confirm(conn, key, id, %{"provider" => "simulated"}, "c1")
      assert c2.resp_body == c1.resp_body
      assert get_resp_header(c2, "idempotent-replayed") == ["true"]
    end

    test "a new key gives the same next_action and one provider payment", %{
      conn: conn,
      key: key,
      merchant: merchant,
      id: id
    } do
      a = conn |> confirm(key, id, %{"provider" => "simulated"}, "c1") |> json_response(202)
      b = conn |> confirm(key, id, %{"provider" => "simulated"}, "c2") |> json_response(202)

      assert a["next_action"] == b["next_action"]
      {:ok, intent} = Payments.fetch_intent(merchant.id, id)
      [attempt] = intent.attempts
      assert Simulated.created_count(attempt.id) == 1
    end

    test "rejects an unknown or non-string provider with 422", %{conn: conn, key: key, id: id} do
      c = confirm(conn, key, id, %{"provider" => "nope"}, "c1")
      assert %{"error" => %{"code" => "unknown_provider"}} = json_response(c, 422)

      for {p, i} <- Enum.with_index([42, nil, %{"a" => 1}, ["simulated"]]) do
        c = confirm(conn, key, id, %{"provider" => p}, "np#{i}")
        assert %{"error" => %{"code" => "invalid_request"}} = json_response(c, 422)
      end

      c = confirm(conn, key, id, %{}, "np-none")
      assert %{"error" => %{"code" => "invalid_request"}} = json_response(c, 422)
    end

    test "another merchant's intent gives 404", %{conn: conn, id: id} do
      %{api_key: other} = merchant_fixture()
      c = confirm(conn, other, id, %{"provider" => "simulated"}, "c1")
      assert %{"error" => %{"code" => "not_found"}} = json_response(c, 404)
    end

    test "a confirm needs an Idempotency-Key", %{conn: conn, key: key, id: id} do
      c = confirm(conn, key, id, %{"provider" => "simulated"}, nil)
      assert %{"error" => %{"code" => "idempotency_key_required"}} = json_response(c, 400)
    end

    test "a confirm after the payment is final returns the final intent and sends nothing", %{
      conn: conn,
      key: key,
      merchant: merchant,
      id: id
    } do
      conn |> confirm(key, id, %{"provider" => "simulated"}, "c1") |> json_response(202)
      {:ok, intent} = Payments.fetch_intent(merchant.id, id)
      [attempt] = intent.attempts
      {:ok, hook} = Simulated.pay(attempt.id, :instant)
      assert :accepted = deliver!(conn, hook)
      Oban.drain_queue(queue: :webhooks)

      c = confirm(conn, key, id, %{"provider" => "simulated"}, "c9")
      assert %{"status" => "final", "next_action" => nil} = json_response(c, 202)
      assert Simulated.created_count(attempt.id) == 1
    end

    test "the provider comes from the body: one in the query string is ignored", %{
      conn: conn,
      key: key,
      id: id
    } do
      path = "/v1/payment_intents/#{id}/confirm?provider=simulated"
      c = post_api(conn, key, path, %{}, "q1")

      assert %{"error" => %{"code" => "invalid_request"}} = json_response(c, 422)
      assert count(Attempt) == 0
    end

    test "a lost reply: 503 is not stored, the retry finishes the same payment", %{
      conn: conn,
      key: key,
      merchant: merchant,
      id: id
    } do
      attempt = Repo.insert!(%Attempt{payment_intent_id: id, provider: "simulated"})
      Simulated.fault_next_create(attempt.id, :unavailable_after)

      c1 = confirm(conn, key, id, %{"provider" => "simulated"}, "K")
      assert %{"error" => %{"code" => "provider_unavailable"}} = json_response(c1, 503)

      c2 = confirm(conn, key, id, %{"provider" => "simulated"}, "K")
      assert %{"status" => "pending"} = json_response(c2, 202)
      assert get_resp_header(c2, "idempotent-replayed") == []
      assert Simulated.created_count(attempt.id) == 1

      c3 = confirm(conn, key, id, %{"provider" => "simulated"}, "K")
      assert c3.resp_body == c2.resp_body
      assert get_resp_header(c3, "idempotent-replayed") == ["true"]
      {:ok, intent} = Payments.fetch_intent(merchant.id, id)
      assert length(intent.attempts) == 1
    end

    test "a declined payment gives 422, and a new key makes a new attempt", %{
      conn: conn,
      key: key,
      merchant: merchant,
      id: id
    } do
      attempt = Repo.insert!(%Attempt{payment_intent_id: id, provider: "simulated"})
      Simulated.fault_next_create(attempt.id, :decline)

      c1 = confirm(conn, key, id, %{"provider" => "simulated"}, "D1")
      assert %{"error" => %{"code" => "provider_declined"}} = json_response(c1, 422)

      c2 = confirm(conn, key, id, %{"provider" => "simulated"}, "D2")
      assert %{"status" => "pending"} = json_response(c2, 202)

      {:ok, intent} = Payments.fetch_intent(merchant.id, id)
      assert length(intent.attempts) == 2
      assert Enum.any?(intent.attempts, &(&1.id == attempt.id and &1.status == :failed))
    end
  end

  # POSTs a signed webhook through HTTP. Returns the `received` marker.
  defp deliver!(conn, %{body: body, headers: headers}) do
    c =
      Enum.reduce(headers, put_req_header(conn, "content-type", "application/json"), fn {k, v},
                                                                                        acc ->
        put_req_header(acc, k, v)
      end)

    assert %{"received" => true} = c |> post("/webhooks/simulated", body) |> json_response(200)
    :accepted
  end

  describe "what the idempotency hash covers" do
    test "the query string is part of the request", %{conn: conn, key: key} do
      conn |> post_api(key, "/v1/payment_intents", @valid, "same") |> json_response(201)

      c = post_api(conn, key, "/v1/payment_intents?x=1", @valid, "same")
      assert %{"error" => %{"code" => "idempotency_key_reused"}} = json_response(c, 409)
      assert count(Chebit.Payments.Intent) == 1
    end

    test "a body that is not JSON gives 415 and has no effect", %{conn: conn, key: key} do
      c =
        conn
        |> authenticated(key)
        |> put_req_header("idempotency-key", "plain")
        |> put_req_header("content-type", "text/plain")
        |> post("/v1/payment_intents", ~s({"amount_minor": 1500, "currency": "ARS"}))

      assert %{"error" => %{"code" => "unsupported_media_type"}} = json_response(c, 415)
      assert count(Chebit.Payments.Intent) == 0
      assert count(Chebit.Idempotency.Key) == 0
    end

    test "a null metadata is accepted as no metadata", %{conn: conn, key: key} do
      body = Map.put(@valid, "metadata", nil)
      assert %{"metadata" => %{}} = create!(conn, key, body)
    end
  end
end
