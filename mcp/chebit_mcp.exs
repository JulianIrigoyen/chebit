# Chebit MCP server.
#
# It gives an AI agent two things: the Chebit payment API and the Chebit handbook.
# Transport: stdio. Each line is one JSON-RPC 2.0 message. Only protocol messages go to
# stdout. It needs Elixir 1.18 on OTP 27 and no dependency.
#
#     mise exec -- elixir mcp/chebit_mcp.exs
#
# Environment:
#
#   CHEBIT_API_KEY   the merchant's API key. The payment tools need it. It is never printed.
#   CHEBIT_API_URL   the address of the API. Default: http://127.0.0.1:4000
#   CHEBIT_HANDBOOK  the handbook file. Default: ../docs/HANDBOOK.md from this script.
#
# The server is a client of the public API. An agent gets no path around the API key, the
# idempotency key or the integer money rule. `docs/HANDBOOK.md`, practice 37, has the rest.

defmodule ChebitMCP.Handbook do
  @moduledoc false

  @heading ~r/^### (\d+)\. (.+)$/
  @status ~r/^\*\*Status:\*\* (.+)$/m

  def path, do: System.get_env("CHEBIT_HANDBOOK") || Path.expand("../docs/HANDBOOK.md", __DIR__)

  # The file is read on each call, so an edit shows without a restart.
  def read do
    case File.read(path()) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "Cannot read #{path()}: #{:file.format_error(reason)}"}
    end
  end

  @doc "Splits the handbook into its practices. A practice starts at `### N. Title`."
  def practices(text) do
    {done, current, _part} =
      text
      |> String.split("\n")
      |> Enum.reduce({[], nil, nil}, &step/2)

    [current | done] |> Enum.reject(&is_nil/1) |> Enum.reverse() |> Enum.map(&finish/1)
  end

  defp step("## " <> heading, {done, current, _part}) do
    part = if String.starts_with?(heading, "Part "), do: heading, else: nil
    {[current | done], nil, part}
  end

  defp step(line, {done, current, part}) do
    case Regex.run(@heading, line) do
      [_all, id, title] ->
        {[current | done], %{id: String.to_integer(id), title: title, part: part, lines: [line]},
         part}

      nil when is_map(current) ->
        {done, %{current | lines: [line | current.lines]}, part}

      nil ->
        {done, current, part}
    end
  end

  defp finish(%{lines: lines} = practice) do
    text = lines |> Enum.reverse() |> Enum.join("\n") |> String.trim()

    status =
      case Regex.run(@status, text) do
        [_all, status] -> status
        nil -> "unknown"
      end

    practice |> Map.delete(:lines) |> Map.merge(%{text: text, status: status})
  end

  @doc "Returns the text of a `## Title` section that is not a part, for example the review findings."
  def section(text, title) do
    case String.split(text, "\n## " <> title <> "\n", parts: 2) do
      [_before, rest] ->
        {:ok, "## " <> title <> "\n" <> hd(String.split(rest, "\n## ", parts: 2))}

      _missing ->
        :error
    end
  end

  @doc "Ranks the practices for a free-text query. A word in the title counts three times."
  def search(practices, query) do
    words = query |> String.downcase() |> String.split(~r/[^\p{L}\p{N}_]+/u, trim: true)

    practices
    |> Enum.map(fn practice ->
      title = String.downcase(practice.title)
      body = String.downcase(practice.text)

      score =
        Enum.reduce(words, 0, fn word, sum ->
          sum + if(String.contains?(title, word), do: 3, else: 0) +
            if(String.contains?(body, word), do: 1, else: 0)
        end)

      {score, practice}
    end)
    |> Enum.filter(fn {score, _practice} -> score > 0 end)
    |> Enum.sort_by(fn {score, practice} -> {-score, practice.id} end)
    |> Enum.map(fn {_score, practice} -> practice end)
  end
end

defmodule ChebitMCP.Api do
  @moduledoc false

  def base_url,
    do: String.trim_trailing(System.get_env("CHEBIT_API_URL") || "http://127.0.0.1:4000", "/")

  @doc "Sends one request to the Chebit API. `body` is a map for POST and nil for GET."
  def request(method, path, body \\ nil, headers \\ []) do
    case System.get_env("CHEBIT_API_KEY") do
      key when is_binary(key) and key != "" -> send_request(method, path, body, headers, key)
      _missing -> {:error, :no_api_key}
    end
  end

  defp send_request(method, path, body, headers, key) do
    url = String.to_charlist(base_url() <> path)

    headers =
      for {name, value} <-
            [{"authorization", "Bearer " <> key}, {"accept", "application/json"}] ++ headers do
        {String.to_charlist(name), String.to_charlist(value)}
      end

    request =
      if body, do: {url, headers, ~c"application/json", JSON.encode!(body)}, else: {url, headers}

    options = [timeout: 20_000, connect_timeout: 5_000] ++ ssl_options(base_url())

    case :httpc.request(method, request, options, body_format: :binary) do
      {:ok, {{_version, status, _reason}, response_headers, response_body}} ->
        {:ok,
         %{
           status: status,
           replayed?: {~c"idempotent-replayed", ~c"true"} in response_headers,
           body: decode(response_body)
         }}

      {:error, reason} ->
        {:error, {:no_answer, reason}}
    end
  end

  defp ssl_options("https://" <> _rest) do
    [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ]
    ]
  end

  defp ssl_options(_http), do: []

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> body
    end
  end
end

defmodule ChebitMCP.Tools do
  @moduledoc false

  alias ChebitMCP.Api
  alias ChebitMCP.Handbook

  @currencies ["ARS", "USD", "BTC", "USDT", "USDC"]
  @uuid ~r/\A[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\z/

  @key_property %{
    "type" => "string",
    "minLength" => 1,
    "maxLength" => 255,
    "description" =>
      "The idempotency key of this request. Leave it out on the first call: the server makes one and returns it. " <>
        "To retry the same request, send the key that the first call returned. The API then makes no second effect."
  }

  def list do
    [
      %{
        "name" => "create_payment_intent",
        "description" =>
          "Creates a payment intent for the merchant. It moves no money. Next step: confirm_payment_intent. " <>
            "The result holds the idempotency_key that was used. Send it again to retry after an error or a timeout.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "amount_minor" => %{
              "type" => "integer",
              "minimum" => 1,
              "description" =>
                "The amount as an integer in the smallest unit of the currency. ARS 100.50 is 10050. " <>
                  "BTC is in satoshis. USDT and USDC use 6 decimals. A float is refused."
            },
            "currency" => %{"type" => "string", "enum" => @currencies},
            "description" => %{"type" => "string", "maxLength" => 500},
            "metadata" => %{"type" => "object"},
            "idempotency_key" => @key_property
          },
          "required" => ["amount_minor", "currency"]
        }
      },
      %{
        "name" => "confirm_payment_intent",
        "description" =>
          "Sends a created intent to a provider. The intent becomes pending, and next_action holds what the payer needs. " <>
            "A 503 means that the outcome is unknown: call again with the same idempotency_key.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "intent_id" => %{"type" => "string", "description" => "The id of the intent, a UUID."},
            "provider" => %{
              "type" => "string",
              "description" => "The provider name. Phase 0 has one: simulated.",
              "default" => "simulated"
            },
            "idempotency_key" => @key_property
          },
          "required" => ["intent_id"]
        }
      },
      %{
        "name" => "get_payment_intent",
        "description" =>
          "Reads one intent: status, amount, failure_reason, next_action. The merchant can use the money only when the status is final. " <>
            "paid can still reverse.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "intent_id" => %{"type" => "string", "description" => "The id of the intent, a UUID."}
          },
          "required" => ["intent_id"]
        },
        "annotations" => %{"readOnlyHint" => true}
      },
      %{
        "name" => "list_balances",
        "description" =>
          "Lists the merchant's balance for each currency: balance_minor, held_minor and available_minor, all integers in the smallest unit. " <>
            "held is money that can still reverse.",
        "inputSchema" => %{"type" => "object", "properties" => %{}},
        "annotations" => %{"readOnlyHint" => true}
      },
      %{
        "name" => "handbook_list",
        "description" =>
          "Lists the practices of a professional payment system, with the status of each one in Chebit: Done, Partial or Not yet.",
        "inputSchema" => %{"type" => "object", "properties" => %{}},
        "annotations" => %{"readOnlyHint" => true}
      },
      %{
        "name" => "handbook_read",
        "description" =>
          "Reads the handbook. Give one of: practice (a number from handbook_list), query (words to search for, such as 'webhook' or 'double entry'), " <>
            "or section ('findings' for the review findings, 'map' for the table of all practices). " <>
            "A practice gives the rule, the failure that it prevents, the exact module and function in Chebit, the test that proves it, and the gaps.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{
            "practice" => %{"type" => "integer", "minimum" => 1},
            "query" => %{"type" => "string"},
            "section" => %{"type" => "string", "enum" => ["findings", "map"]}
          }
        },
        "annotations" => %{"readOnlyHint" => true}
      }
    ]
  end

  def call("create_payment_intent", args) do
    with {:ok, amount} <- amount(args["amount_minor"]),
         {:ok, currency} <- currency(args["currency"]),
         {:ok, key} <- idempotency_key(args["idempotency_key"]) do
      body =
        %{"amount_minor" => amount, "currency" => currency}
        |> put_present("description", args["description"])
        |> put_present("metadata", args["metadata"])

      write("/v1/payment_intents", body, key)
    else
      {:invalid, message} -> failure(message)
    end
  end

  def call("confirm_payment_intent", args) do
    with {:ok, id} <- intent_id(args["intent_id"]),
         {:ok, provider} <- provider(Map.get(args, "provider", "simulated")),
         {:ok, key} <- idempotency_key(args["idempotency_key"]) do
      write("/v1/payment_intents/#{id}/confirm", %{"provider" => provider}, key)
    else
      {:invalid, message} -> failure(message)
    end
  end

  def call("get_payment_intent", args) do
    case intent_id(args["intent_id"]) do
      {:ok, id} -> read("/v1/payment_intents/#{id}")
      {:invalid, message} -> failure(message)
    end
  end

  def call("list_balances", _args), do: read("/v1/balances")

  def call("handbook_list", _args) do
    with_practices(fn practices, _text ->
      rows = for p <- practices, do: Map.take(p, [:id, :title, :part, :status])
      success(%{"practices" => rows, "next" => "Call handbook_read with a practice number."})
    end)
  end

  def call("handbook_read", %{"practice" => id}) when is_integer(id) do
    with_practices(fn practices, _text ->
      case Enum.find(practices, &(&1.id == id)) do
        nil -> failure("No practice #{id}. The handbook has practices 1 to #{length(practices)}.")
        practice -> success(practice.text)
      end
    end)
  end

  def call("handbook_read", %{"section" => section}) when section in ["findings", "map"] do
    title = if section == "findings", do: "Review findings", else: "Map"

    with_practices(fn _practices, text ->
      case Handbook.section(text, title) do
        {:ok, body} -> success(body)
        :error -> failure("The handbook has no section '#{title}'.")
      end
    end)
  end

  def call("handbook_read", %{"query" => query}) when is_binary(query) and query != "" do
    with_practices(fn practices, _text ->
      case Handbook.search(practices, query) do
        [] ->
          failure("No practice matches '#{query}'. Call handbook_list to see each title.")

        [best | others] ->
          more =
            case Enum.take(others, 4) do
              [] -> ""
              list -> "\n\nOther matches: " <> Enum.map_join(list, "; ", &"#{&1.id}. #{&1.title}")
            end

          success(best.text <> more)
      end
    end)
  end

  def call("handbook_read", _args) do
    failure("Give one of: practice (a number), query (words) or section ('findings' or 'map').")
  end

  def call(_unknown, _args), do: :unknown_tool

  # Arguments

  defp amount(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp amount(_other) do
    {:invalid,
     "amount_minor must be a JSON integer above zero, in the smallest unit of the currency. " <>
       "ARS 100.50 is 10050. A float or a string is refused: money is never a float."}
  end

  defp currency(value) when value in @currencies, do: {:ok, value}

  defp currency(_other),
    do: {:invalid, "currency must be one of: #{Enum.join(@currencies, ", ")}."}

  defp intent_id(value) when is_binary(value) do
    if Regex.match?(@uuid, value), do: {:ok, value}, else: {:invalid, "intent_id must be a UUID."}
  end

  defp intent_id(_other), do: {:invalid, "intent_id must be a UUID."}

  defp provider(value) when is_binary(value) and value != "", do: {:ok, value}
  defp provider(_other), do: {:invalid, "provider must be a name, for example simulated."}

  defp idempotency_key(nil), do: {:ok, "mcp-" <> random_uuid()}

  defp idempotency_key(value) when is_binary(value) do
    if String.printable?(value) and String.length(value) in 1..255,
      do: {:ok, value},
      else: {:invalid, "idempotency_key must have 1 to 255 printable characters."}
  end

  defp idempotency_key(_other), do: {:invalid, "idempotency_key must be a string."}

  defp random_uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    [{a, 8}, {b, 4}, {0x4000 + c, 4}, {0x8000 + d, 4}, {e, 12}]
    |> Enum.map_join("-", fn {part, width} ->
      part |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end)
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # API calls

  defp write(path, body, key) do
    case Api.request(:post, path, body, [{"idempotency-key", key}]) do
      {:ok, response} ->
        respond(response, %{"idempotency_key" => key, "replayed" => response.replayed?})

      {:error, {:no_answer, reason}} ->
        failure(
          "No answer from the Chebit API at #{Api.base_url()} (#{inspect(reason)}). The outcome is unknown. " <>
            "Call this tool again with the same arguments and idempotency_key \"#{key}\". " <>
            "The API then returns the first result and makes no second effect."
        )

      {:error, :no_api_key} ->
        no_api_key()
    end
  end

  defp read(path) do
    case Api.request(:get, path) do
      {:ok, response} ->
        respond(response, %{})

      {:error, {:no_answer, reason}} ->
        failure(
          "No answer from the Chebit API at #{Api.base_url()} (#{inspect(reason)}). " <>
            "A read changes nothing, so it is safe to call again. Start the API with: mise run server"
        )

      {:error, :no_api_key} ->
        no_api_key()
    end
  end

  defp respond(%{status: status, body: body}, extra) when status < 400 do
    success(Map.merge(extra, %{"http_status" => status, "data" => body}))
  end

  defp respond(%{status: status, body: body}, extra) do
    advice =
      case status do
        503 ->
          "The outcome is unknown. Call again with the same idempotency_key."

        409 ->
          "A conflict. Read the error code: a request in progress needs a short wait and the same key."

        401 ->
          "The API key is wrong. Check CHEBIT_API_KEY."

        _other ->
          "The API refused the request. Do not retry it unchanged."
      end

    failure(
      JSON.encode!(
        Map.merge(extra, %{"http_status" => status, "error" => body, "advice" => advice})
      )
    )
  end

  defp no_api_key do
    failure(
      "CHEBIT_API_KEY is not set. Create a merchant, then start this server with its key. " <>
        "docs/HANDBOOK.md, practice 37, has the commands. The handbook tools work without a key."
    )
  end

  defp with_practices(fun) do
    case Handbook.read() do
      {:ok, text} -> fun.(Handbook.practices(text), text)
      {:error, message} -> failure(message)
    end
  end

  # Results

  defp success(text) when is_binary(text), do: result(text, false)
  defp success(data), do: result(JSON.encode!(data), false)
  defp failure(text), do: result(text, true)

  defp result(text, error?) do
    {:ok, %{"content" => [%{"type" => "text", "text" => text}], "isError" => error?}}
  end
end

defmodule ChebitMCP.Server do
  @moduledoc false

  alias ChebitMCP.Handbook
  alias ChebitMCP.Tools

  # Newest first. The server answers with the client's version when it is in this list.
  @versions ["2025-06-18", "2025-03-26", "2024-11-05"]

  @instructions """
  Chebit is a payment core. These rules hold for each tool:
  1. An amount is an integer in the smallest unit of its currency. Never send a float.
  2. Each write uses an idempotency key. Keep the key that a tool returns. After an error or a timeout, call again with the same key.
  3. A payment is done only when its status is final. paid can still reverse.
  4. To learn how Chebit implements a payment practice, call handbook_list and handbook_read.
  """

  def run do
    {:ok, _apps} = Application.ensure_all_started(:inets)
    {:ok, _apps} = Application.ensure_all_started(:ssl)
    :ok = :io.setopts(:standard_io, encoding: :unicode)
    IO.puts(:stderr, "chebit-mcp: ready on stdio")
    loop()
  end

  defp loop do
    case IO.read(:stdio, :line) do
      line when is_binary(line) ->
        line |> String.trim() |> handle_line()
        loop()

      _eof_or_error ->
        :ok
    end
  end

  defp handle_line(""), do: :ok

  defp handle_line(line) do
    case JSON.decode(line) do
      {:ok, %{"method" => method, "id" => id} = message} when is_binary(method) ->
        answer(id, method, Map.get(message, "params") || %{})

      # A notification, or a response to a request. This server sends no request.
      {:ok, %{}} ->
        :ok

      {:ok, _other} ->
        send_error(nil, -32_600, "Invalid Request")

      {:error, _reason} ->
        send_error(nil, -32_700, "Parse error")
    end
  end

  defp answer(id, method, params) do
    case request(method, params) do
      {:ok, result} -> send_message(%{"jsonrpc" => "2.0", "id" => id, "result" => result})
      {:error, code, message} -> send_error(id, code, message)
    end
  rescue
    error -> send_error(id, -32_603, "Internal error: " <> Exception.message(error))
  end

  defp request("initialize", params) do
    requested = params["protocolVersion"]
    version = if requested in @versions, do: requested, else: hd(@versions)

    {:ok,
     %{
       "protocolVersion" => version,
       "capabilities" => %{"tools" => %{}, "resources" => %{}},
       "serverInfo" => %{"name" => "chebit", "version" => "0.1.0"},
       "instructions" => @instructions
     }}
  end

  defp request("ping", _params), do: {:ok, %{}}
  defp request("tools/list", _params), do: {:ok, %{"tools" => Tools.list()}}

  defp request("tools/call", %{"name" => name} = params) when is_binary(name) do
    arguments = if is_map(params["arguments"]), do: params["arguments"], else: %{}

    case Tools.call(name, arguments) do
      {:ok, result} -> {:ok, result}
      :unknown_tool -> {:error, -32_602, "Unknown tool: " <> name}
    end
  end

  defp request("tools/call", _params), do: {:error, -32_602, "tools/call needs a name"}

  defp request("resources/list", _params) do
    case Handbook.read() do
      {:ok, text} ->
        whole = %{
          "uri" => "chebit://handbook",
          "name" => "Chebit handbook",
          "description" =>
            "Each payment practice, where Chebit implements it, its proof and its gaps.",
          "mimeType" => "text/markdown"
        }

        practices =
          for p <- Handbook.practices(text) do
            %{
              "uri" => "chebit://handbook/#{p.id}",
              "name" => "#{p.id}. #{p.title}",
              "description" => "Status: #{p.status}",
              "mimeType" => "text/markdown"
            }
          end

        {:ok, %{"resources" => [whole | practices]}}

      {:error, _message} ->
        {:ok, %{"resources" => []}}
    end
  end

  defp request("resources/read", %{"uri" => "chebit://handbook" <> rest = uri}) do
    with {:ok, text} <- Handbook.read(),
         {:ok, body} <- resource_body(rest, text) do
      {:ok, %{"contents" => [%{"uri" => uri, "mimeType" => "text/markdown", "text" => body}]}}
    else
      _missing -> {:error, -32_002, "Resource not found: " <> uri}
    end
  end

  defp request("resources/read", _params), do: {:error, -32_002, "Resource not found"}
  defp request("resources/templates/list", _params), do: {:ok, %{"resourceTemplates" => []}}
  defp request(method, _params), do: {:error, -32_601, "Method not found: " <> method}

  defp resource_body("", text), do: {:ok, text}

  defp resource_body("/" <> id, text) do
    with {number, ""} <- Integer.parse(id),
         %{text: body} <- Enum.find(Handbook.practices(text), &(&1.id == number)) do
      {:ok, body}
    else
      _missing -> :error
    end
  end

  defp resource_body(_other, _text), do: :error

  defp send_error(id, code, message) do
    send_message(%{
      "jsonrpc" => "2.0",
      "id" => id,
      "error" => %{"code" => code, "message" => message}
    })
  end

  # One message, one line. `JSON.encode!/1` escapes each newline inside a string.
  defp send_message(message), do: IO.write(:stdio, [JSON.encode!(message), "\n"])
end

ChebitMCP.Server.run()
