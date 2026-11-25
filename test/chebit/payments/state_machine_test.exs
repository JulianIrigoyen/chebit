defmodule Chebit.Payments.StateMachineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Chebit.Payments.StateMachine

  doctest Chebit.Payments.StateMachine

  @table %{
    created: [:pending, :failed, :expired],
    pending: [:paid, :failed, :expired],
    paid: [:final, :refunded, :disputed],
    disputed: [:final, :refunded],
    final: [],
    failed: [],
    expired: [],
    refunded: []
  }
  @statuses Map.keys(@table)
  @terminal [:final, :failed, :expired, :refunded]

  # Own search over the table above. It does not use the module under test.
  defp reachable?(from, to, seen \\ [])
  defp reachable?(same, same, _seen), do: true

  defp reachable?(from, to, seen) do
    @table
    |> Map.fetch!(from)
    |> Enum.reject(&(&1 in seen))
    |> Enum.any?(&reachable?(&1, to, [from | seen]))
  end

  defp status, do: member_of(@statuses)

  describe "the transition table" do
    test "next/1 matches the exact table" do
      for {from, to} <- @table, do: assert(Enum.sort(StateMachine.next(from)) == Enum.sort(to))
    end

    test "statuses/0 lists the eight statuses" do
      assert Enum.sort(StateMachine.statuses()) == Enum.sort(@statuses)
      assert length(StateMachine.statuses()) == 8
    end

    test "terminal_statuses/0 and terminal?/1 agree with the table" do
      assert Enum.sort(StateMachine.terminal_statuses()) == Enum.sort(@terminal)

      for s <- @statuses do
        assert StateMachine.terminal?(s) == s in @terminal
        assert StateMachine.terminal?(s) == (@table[s] == [])
      end
    end

    test "rank/1 gives each status the documented position" do
      assert StateMachine.rank(:created) == 0
      assert StateMachine.rank(:pending) == 1
      assert StateMachine.rank(:paid) == 2
      assert StateMachine.rank(:disputed) == 3
      for s <- @terminal, do: assert(StateMachine.rank(s) == 4)
    end
  end

  describe "transition/2" do
    test "accepts each allowed step" do
      for {from, tos} <- @table, to <- tos, do: assert(StateMachine.transition(from, to) == :ok)
    end

    test "refuses each other pair" do
      for from <- @statuses, to <- @statuses, to not in @table[from] do
        assert StateMachine.transition(from, to) == {:error, :invalid_transition}
      end
    end

    property "is :ok exactly when to is in next(from)" do
      check all(from <- status(), to <- status(), max_runs: 200) do
        expected = if to in StateMachine.next(from), do: :ok, else: {:error, :invalid_transition}
        assert StateMachine.transition(from, to) == expected
      end
    end

    property "an allowed transition never lowers the rank (invariant 6)" do
      check all(from <- status(), to <- status(), max_runs: 200) do
        if StateMachine.transition(from, to) == :ok do
          assert StateMachine.rank(to) >= StateMachine.rank(from)
          refute to == from
        end
      end
    end

    property "a terminal status has no next status and no transition out (invariant 6)" do
      check all(from <- member_of(@terminal), to <- status(), max_runs: 100) do
        assert StateMachine.next(from) == []
        assert StateMachine.transition(from, to) == {:error, :invalid_transition}
      end
    end

    property "a random walk from :created reaches a terminal status in at most 4 steps" do
      check all(choices <- list_of(integer(0..100), length: 4), max_runs: 200) do
        {final, steps} =
          Enum.reduce_while(choices, {:created, 0}, fn choice, {current, steps} ->
            case StateMachine.next(current) do
              [] -> {:halt, {current, steps}}
              nexts -> {:cont, {Enum.at(nexts, rem(choice, length(nexts))), steps + 1}}
            end
          end)

        assert StateMachine.terminal?(final)
        assert steps <= 4
      end
    end

    test "garbage input gives the error and never raises" do
      garbage = [nil, "paid", 1, 1.5, [], %{}, {:a}, :unknown, <<0xFF>>, "final"]

      for a <- garbage ++ @statuses, b <- garbage ++ @statuses, a in garbage or b in garbage do
        assert StateMachine.transition(a, b) == {:error, :invalid_transition}
      end
    end
  end

  describe "path/2" do
    test "returns the documented shortest paths" do
      assert StateMachine.path(:created, :final) == {:ok, [:pending, :paid, :final]}
      assert StateMachine.path(:pending, :final) == {:ok, [:paid, :final]}
      assert StateMachine.path(:pending, :refunded) == {:ok, [:paid, :refunded]}
      assert StateMachine.path(:paid, :final) == {:ok, [:final]}
      assert StateMachine.path(:final, :refunded) == {:error, :unreachable}
      assert StateMachine.path(:failed, :pending) == {:error, :unreachable}
    end

    property "steps are valid transitions that end at `to`; same status gives []; unreachable matches brute force" do
      check all(from <- status(), to <- status(), max_runs: 200) do
        result = StateMachine.path(from, to)

        cond do
          from == to ->
            assert result == {:ok, []}

          reachable?(from, to) ->
            assert {:ok, steps} = result
            assert steps != []
            assert List.last(steps) == to

            [from | steps]
            |> Enum.chunk_every(2, 1, :discard)
            |> Enum.each(fn [a, b] -> assert StateMachine.transition(a, b) == :ok end)

          true ->
            assert result == {:error, :unreachable}
        end
      end
    end

    test "every pair, exhaustively, agrees with the brute-force search" do
      for from <- @statuses, to <- @statuses, from != to do
        assert match?({:ok, _}, StateMachine.path(from, to)) == reachable?(from, to)
      end
    end

    test "the path is the shortest" do
      for from <- @statuses, to <- @statuses, from != to, reachable?(from, to) do
        {:ok, steps} = StateMachine.path(from, to)
        assert length(steps) == shortest(from, to)
      end
    end

    test "garbage input gives :unreachable and never raises" do
      garbage = [nil, "paid", 1, 1.5, [], %{}, {:a}, :unknown, <<0xFF>>]

      for a <- garbage ++ @statuses, b <- garbage ++ @statuses, a in garbage or b in garbage do
        assert StateMachine.path(a, b) == {:error, :unreachable}
      end
    end
  end

  defp shortest(from, to), do: bfs([{from, 0}], to)

  defp bfs([{to, depth} | _rest], to), do: depth
  defp bfs([{s, depth} | rest], to), do: bfs(rest ++ Enum.map(@table[s], &{&1, depth + 1}), to)
end
