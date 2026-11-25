defmodule Chebit.Repo.Migrations.AddReferenceToProviderEvents do
  use Ecto.Migration

  # The reference names our payment attempt. The inbox reads it once, when it checks the
  # signature, so the processor does not need the request headers again.
  def change do
    alter table(:provider_events) do
      add :reference, :text, null: false
    end
  end
end
