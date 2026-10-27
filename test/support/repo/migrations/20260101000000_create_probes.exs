defmodule Macaw.Host.TestRepo.Migrations.CreateProbes do
  use Ecto.Migration

  def change do
    create table(:probes) do
      add(:name, :string)
    end
  end
end
