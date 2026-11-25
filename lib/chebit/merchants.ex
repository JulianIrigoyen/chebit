defmodule Chebit.Merchants do
  @moduledoc """
  Merchants and their API keys.
  """
  import Ecto.Changeset
  import Ecto.Query, only: [from: 2]

  alias Chebit.Merchants.Merchant
  alias Chebit.Repo

  @key_prefix "chebit_sk_"

  @doc """
  Creates a merchant and its API key.

  The key is returned once. Only its SHA-256 is stored.
  """
  @spec create_merchant(%{required(:name) => String.t(), optional(:fee_bps) => 0..10_000}) ::
          {:ok, %{merchant: Merchant.t(), api_key: String.t()}} | {:error, Ecto.Changeset.t()}
  def create_merchant(attrs) do
    api_key = @key_prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    result =
      %Merchant{api_key_hash: hash(api_key)}
      |> cast(attrs, [:name, :fee_bps])
      |> validate_required([:name])
      |> validate_number(:fee_bps, greater_than_or_equal_to: 0, less_than_or_equal_to: 10_000)
      |> Repo.insert()

    with {:ok, merchant} <- result, do: {:ok, %{merchant: merchant, api_key: api_key}}
  end

  @doc """
  Returns the merchant with this name, and creates it when none exists.

  The dev dashboard uses it for its demo merchant. A new merchant has no API key that
  anyone sees, because the dashboard needs none.
  """
  @spec get_or_create(String.t()) :: {:ok, Merchant.t()} | {:error, Ecto.Changeset.t()}
  def get_or_create(name) when is_binary(name) do
    case Repo.one(from(m in Merchant, where: m.name == ^name, order_by: m.inserted_at, limit: 1)) do
      %Merchant{} = merchant ->
        {:ok, merchant}

      nil ->
        with {:ok, %{merchant: merchant}} <- create_merchant(%{name: name, fee_bps: 250}) do
          {:ok, merchant}
        end
    end
  end

  @doc """
  Finds the merchant that owns an API key.

  An unknown key gives `{:error, :unauthorized}`. The lookup is by hash, so its time does
  not depend on how many characters of the key match.
  """
  @spec authenticate(term()) :: {:ok, Merchant.t()} | {:error, :unauthorized}
  def authenticate(@key_prefix <> _rest = api_key) do
    case Repo.get_by(Merchant, api_key_hash: hash(api_key)) do
      %Merchant{} = merchant -> {:ok, merchant}
      nil -> {:error, :unauthorized}
    end
  end

  def authenticate(_other), do: {:error, :unauthorized}

  defp hash(api_key), do: :crypto.hash(:sha256, api_key)
end
