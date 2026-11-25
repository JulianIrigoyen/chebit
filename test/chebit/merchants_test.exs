defmodule Chebit.MerchantsTest do
  use Chebit.DataCase, async: true

  alias Chebit.Merchants
  alias Chebit.Merchants.Merchant

  defp create!(attrs \\ %{}) do
    {:ok, result} = Merchants.create_merchant(Map.merge(%{name: "Parrilla"}, attrs))
    result
  end

  describe "create_merchant/1" do
    test "returns the merchant and a key with the chebit_sk_ prefix" do
      assert {:ok, %{merchant: %Merchant{} = merchant, api_key: key}} =
               Merchants.create_merchant(%{name: "Parrilla", fee_bps: 250})

      assert String.starts_with?(key, "chebit_sk_")
      assert byte_size(key) > byte_size("chebit_sk_") + 30
      assert merchant.name == "Parrilla"
      assert merchant.fee_bps == 250
      assert merchant.id
    end

    test "fee_bps defaults to 0" do
      assert create!().merchant.fee_bps == 0
    end

    test "stores only the SHA-256 of the key" do
      %{merchant: merchant, api_key: key} = create!()
      stored = Repo.get!(Merchant, merchant.id)

      assert stored.api_key_hash == :crypto.hash(:sha256, key)
      refute stored.api_key_hash == key
      assert byte_size(stored.api_key_hash) == 32
      refute String.contains?(stored.api_key_hash, key)
    end

    test "gives each merchant a different key" do
      refute create!().api_key == create!().api_key
    end

    test "inspect does not show the hash or the key" do
      %{merchant: merchant, api_key: key} = create!()
      text = inspect(merchant)

      refute text =~ key
      refute text =~ Base.encode16(merchant.api_key_hash, case: :lower)
      refute text =~ Base.encode16(merchant.api_key_hash, case: :upper)
      refute text =~ Base.encode64(merchant.api_key_hash)
      refute text =~ Base.url_encode64(merchant.api_key_hash)
      refute text =~ "api_key_hash"
    end
  end

  describe "create_merchant/1 with rejected input" do
    test "refuses fee_bps outside 0..10_000" do
      for bps <- [-1, 10_001, 1_000_000] do
        assert {:error, changeset} = Merchants.create_merchant(%{name: "X", fee_bps: bps})
        assert %{fee_bps: [_ | _]} = errors_on(changeset)
      end
    end

    test "accepts the bounds 0 and 10_000" do
      assert {:ok, _} = Merchants.create_merchant(%{name: "X", fee_bps: 0})
      assert {:ok, _} = Merchants.create_merchant(%{name: "X", fee_bps: 10_000})
    end

    test "refuses a missing or blank name" do
      for attrs <- [%{}, %{fee_bps: 10}, %{name: nil}, %{name: ""}] do
        assert {:error, changeset} = Merchants.create_merchant(attrs)
        assert %{name: ["can't be blank"]} = errors_on(changeset)
      end
    end

    test "refuses a non-integer fee_bps" do
      for bps <- ["abc", 1.5, [1]] do
        assert {:error, changeset} = Merchants.create_merchant(%{name: "X", fee_bps: bps})
        assert %{fee_bps: [_ | _]} = errors_on(changeset)
      end
    end

    test "a refused merchant is not stored" do
      before = Repo.aggregate(Merchant, :count)
      {:error, _} = Merchants.create_merchant(%{name: "X", fee_bps: -1})
      assert Repo.aggregate(Merchant, :count) == before
    end
  end

  describe "authenticate/1" do
    test "finds the merchant by its key" do
      %{merchant: merchant, api_key: key} = create!()
      assert {:ok, found} = Merchants.authenticate(key)
      assert found.id == merchant.id
    end

    test "each key finds its own merchant" do
      a = create!(%{name: "A"})
      b = create!(%{name: "B"})
      assert {:ok, %{id: id_a}} = Merchants.authenticate(a.api_key)
      assert {:ok, %{id: id_b}} = Merchants.authenticate(b.api_key)
      assert id_a == a.merchant.id
      assert id_b == b.merchant.id
    end

    test "refuses a wrong key with the right prefix" do
      %{api_key: key} = create!()
      wrong = String.slice(key, 0..-2//1) <> if(String.ends_with?(key, "A"), do: "B", else: "A")

      assert Merchants.authenticate(wrong) == {:error, :unauthorized}
      assert Merchants.authenticate("chebit_sk_") == {:error, :unauthorized}
      assert Merchants.authenticate("chebit_sk_nope") == {:error, :unauthorized}
      assert Merchants.authenticate(key <> "x") == {:error, :unauthorized}
    end

    test "refuses a key of another shape" do
      %{api_key: key} = create!()
      without_prefix = String.replace_prefix(key, "chebit_sk_", "")

      for other <- [
            without_prefix,
            "sk_live_abc",
            "",
            "Bearer " <> key,
            " " <> key,
            String.upcase(key)
          ] do
        assert Merchants.authenticate(other) == {:error, :unauthorized}
      end
    end

    test "refuses the stored hash used as a key" do
      %{merchant: merchant} = create!()

      assert Merchants.authenticate(Base.encode16(merchant.api_key_hash, case: :lower)) ==
               {:error, :unauthorized}
    end

    test "refuses nil, integers and other terms without raising" do
      for other <- [nil, 1, 0, 1.5, :chebit_sk_x, [], %{}, {:a}, <<0xFF, 0xFE>>] do
        assert Merchants.authenticate(other) == {:error, :unauthorized}
      end
    end
  end
end
