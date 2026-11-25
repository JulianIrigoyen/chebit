defmodule Chebit.Idempotency do
  @moduledoc """
  Runs a write request at most once for each idempotency key of a merchant.

  ## Contract

  - First request with a key: run the function, store its response, return it.
  - Same key, same request: return the stored response. The function does not run.
  - Same key, different request: `{:error, :key_reused}`. The API answers 409.
  - Same key while the first request still runs: `{:error, :in_progress}`. The API answers 409.
  - A response with status 500 or above is returned and not stored: the request did not
    finish, so a retry with the same key runs the function again.

  ## How

  1. Insert the key row as `processing` with `on_conflict: :nothing`, in its own statement.
     It commits before the function runs, so a concurrent request sees it.
  2. The request that inserted the row runs the function and then stores the response and
     marks the row `completed`.
  3. If the function raises, delete the row and raise again: nothing is stored, and the
     client can retry with the same key.
  4. A row that is `processing` for longer than `@lock_timeout_ms` belongs to a request that
     died. The next request with the same hash takes the row over (a conditional update on
     `locked_at`) and runs the function.
  5. `locked_at` is also the fencing token of the owner. A request that was only slow, and
     lost its row to a take-over, can no longer delete or complete that row.

  Step 4 can run the function a second time. That is safe only because each function that
  the API passes here is idempotent on its own: `Chebit.Payments.create_intent/2` on
  `(merchant_id, idempotency_key)` and `Chebit.Payments.confirm_intent/3` on the intent state.
  The key table replays the response; the domain rule prevents the double effect.
  """

  import Ecto.Query, only: [from: 2]

  alias Chebit.Idempotency.Key
  alias Chebit.Repo

  @lock_timeout_ms 30_000

  @type response :: %{status: pos_integer(), body: map(), replayed?: boolean()}

  @doc "Returns how long a `processing` key stays locked, in milliseconds."
  @spec lock_timeout_ms() :: pos_integer()
  def lock_timeout_ms, do: @lock_timeout_ms

  @doc """
  Hashes the parts of a request that must be equal on a retry: method, path and body.

  The body is the decoded map, so two JSON bodies that differ only in key order or white
  space give the same hash.
  """
  @spec request_hash(String.t(), String.t(), map()) :: binary()
  def request_hash(method, path, body) do
    :crypto.hash(:sha256, :erlang.term_to_binary({method, path, body}, [:deterministic]))
  end

  @doc """
  Runs `fun` once for `(merchant_id, key)` and stores what it returns.

  `fun` returns `{http_status, body}`. `body` is a map that is safe to store as JSON.
  `replayed?` is true when the response came from the store.

  The body in the response always has string keys, on the first call and on a replay. `run/5`
  passes it through `Jason.encode!/1` and `Jason.decode!/1` before it returns it, so a first
  response and its replay are equal.

  `fun` does not run inside a database transaction. If it raises, throws or exits, the key
  row is deleted and the error propagates.

  ## Options

  - `:now` - the current time, for tests of the lock timeout. Defaults to `DateTime.utc_now/0`.
  """
  @spec run(Ecto.UUID.t(), String.t(), binary(), (-> {pos_integer(), map()}), now: DateTime.t()) ::
          {:ok, response()} | {:error, :key_reused | :in_progress}
  def run(merchant_id, key, request_hash, fun, opts \\ []) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    claim(merchant_id, key, request_hash, fun, now)
  end

  # Claims the key row, or decides from the existing row what to do.
  defp claim(merchant_id, key, hash, fun, now) do
    if insert_row(merchant_id, key, hash, now) == 1 do
      execute(%{merchant_id: merchant_id, key: key, hash: hash, locked_at: now}, fun)
    else
      case Repo.get_by(Key, merchant_id: merchant_id, key: key) do
        # The owner deleted its row after `fun` failed: try to claim again.
        nil -> claim(merchant_id, key, hash, fun, now)
        row -> decide(row, hash, fun, now)
      end
    end
  end

  defp decide(%Key{request_hash: stored}, hash, _fun, _now) when stored != hash do
    {:error, :key_reused}
  end

  defp decide(%Key{status: :completed} = row, _hash, _fun, _now), do: {:ok, replay(row)}

  defp decide(%Key{} = row, hash, fun, now) do
    cutoff = DateTime.add(now, -@lock_timeout_ms, :millisecond)

    if stale?(row, cutoff) do
      take_over(row, hash, fun, now, cutoff)
    else
      {:error, :in_progress}
    end
  end

  defp stale?(%Key{locked_at: locked_at}, cutoff), do: DateTime.compare(locked_at, cutoff) == :lt

  # One conditional update. A count of 1 means this caller owns the key.
  defp take_over(row, hash, fun, now, cutoff) do
    {count, _rows} =
      Repo.update_all(
        from(k in Key,
          where:
            k.id == ^row.id and k.status == :processing and k.locked_at < ^cutoff and
              k.request_hash == ^hash
        ),
        set: [locked_at: now, updated_at: now]
      )

    if count == 1 do
      execute(%{merchant_id: row.merchant_id, key: row.key, hash: hash, locked_at: now}, fun)
    else
      # Another caller took the row or completed it. Read it again.
      case Repo.get(Key, row.id) do
        nil -> {:error, :in_progress}
        fresh -> decide_after_takeover_miss(fresh, hash, now)
      end
    end
  end

  defp decide_after_takeover_miss(%Key{request_hash: stored}, hash, _now) when stored != hash do
    {:error, :key_reused}
  end

  defp decide_after_takeover_miss(%Key{status: :completed} = row, _hash, _now) do
    {:ok, replay(row)}
  end

  defp decide_after_takeover_miss(_row, _hash, _now), do: {:error, :in_progress}

  defp insert_row(merchant_id, key, hash, now) do
    {count, _rows} =
      Repo.insert_all(
        Key,
        [
          %{
            merchant_id: merchant_id,
            key: key,
            request_hash: hash,
            status: :processing,
            locked_at: now,
            inserted_at: now,
            updated_at: now
          }
        ],
        on_conflict: :nothing,
        conflict_target: [:merchant_id, :key]
      )

    count
  end

  # Runs `fun` outside a transaction. A failure frees the key so the client can retry.
  #
  # `claim` is what this caller wrote when it took the key. `locked_at` is its fencing
  # token: a take-over always writes a later `locked_at`, so a caller that lost the key to a
  # take-over matches no row and can neither delete nor complete the new owner's row.
  defp execute(claim, fun) do
    {status, body} =
      try do
        fun.()
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          release(claim)
          :erlang.raise(kind, reason, stacktrace)
      end

    body = body |> Jason.encode!() |> Jason.decode!()

    if status >= 500 do
      # A server error is not an answer. Free the key, so a retry runs the function again.
      release(claim)
      {:ok, %{status: status, body: body, replayed?: false}}
    else
      complete(claim, status, body)
    end
  end

  defp owned(claim) do
    from(k in Key,
      where:
        k.merchant_id == ^claim.merchant_id and k.key == ^claim.key and
          k.status == :processing and k.locked_at == ^claim.locked_at
    )
  end

  defp release(claim), do: Repo.delete_all(owned(claim))

  defp complete(claim, status, body) do
    {count, _rows} =
      Repo.update_all(owned(claim),
        set: [
          status: :completed,
          response_status: status,
          response_body: body,
          updated_at: DateTime.utc_now()
        ]
      )

    if count == 1 do
      {:ok, %{status: status, body: body, replayed?: false}}
    else
      lost_ownership(claim, status, body)
    end
  end

  # Another caller took the key over while `fun` ran here. If it already completed the same
  # request, return its stored response, so both callers give one answer. Else return what
  # `fun` returned here and store nothing: the row belongs to the other caller.
  defp lost_ownership(claim, status, body) do
    case Repo.get_by(Key, merchant_id: claim.merchant_id, key: claim.key) do
      %Key{status: :completed, request_hash: hash} = row when hash == claim.hash ->
        {:ok, replay(row)}

      _other ->
        {:ok, %{status: status, body: body, replayed?: false}}
    end
  end

  defp replay(%Key{response_status: status, response_body: body}) do
    %{status: status, body: body, replayed?: true}
  end
end
