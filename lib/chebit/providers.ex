defmodule Chebit.Providers do
  @moduledoc """
  The registry of provider adapters.

  The config key `:providers` maps a provider name to its adapter module. A name that is
  not in the map does not exist: the lookup fails closed.
  """

  @doc "Finds the adapter module of a provider."
  @spec fetch(term()) :: {:ok, module()} | {:error, :unknown_provider}
  def fetch(name) when is_binary(name) do
    case Application.fetch_env!(:chebit, :providers) do
      %{^name => module} -> {:ok, module}
      _other -> {:error, :unknown_provider}
    end
  end

  def fetch(_name), do: {:error, :unknown_provider}

  @doc "Lists the names of the configured providers."
  @spec names() :: [String.t()]
  def names, do: :chebit |> Application.fetch_env!(:providers) |> Map.keys() |> Enum.sort()
end
