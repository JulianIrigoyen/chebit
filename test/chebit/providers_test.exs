defmodule Chebit.ProvidersTest do
  use ExUnit.Case, async: true

  alias Chebit.Providers

  describe "fetch/1" do
    test "finds the simulated provider" do
      assert Providers.fetch("simulated") == {:ok, Chebit.Providers.Simulated}
    end

    test "fails closed on an unknown name" do
      for name <- ["", "Simulated", "simulated ", "stripe", "__struct__"] do
        assert Providers.fetch(name) == {:error, :unknown_provider}
      end
    end

    test "fails closed on a non-binary" do
      for name <- [nil, :simulated, 1, 1.5, [], ["simulated"], %{}, {:a}, ~c"simulated"] do
        assert Providers.fetch(name) == {:error, :unknown_provider}
      end
    end
  end

  describe "names/0" do
    test "lists the configured names, sorted" do
      assert Providers.names() == ["simulated"]
    end
  end
end
