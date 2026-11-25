defmodule ChebitWeb.BalanceController do
  use ChebitWeb, :controller

  def index(conn, _params) do
    data =
      for %{kind: "balance"} = b <- Chebit.Ledger.balances({:merchant, conn.assigns.merchant.id}) do
        %{
          "currency" => to_string(b.currency),
          "balance_minor" => b.balance_minor,
          "held_minor" => b.held_minor,
          "available_minor" => b.available_minor
        }
      end

    json(conn, %{"data" => data})
  end
end
