defmodule Macaw.Host.TestRepo do
  @moduledoc """
  A real repo for the database checks (`Macaw.Host.Health.database/1`,
  `migrations/1` and `Macaw.Host.Release.migrate/1`): SQLite in a test's
  temporary directory, its one migration in `test/support/repo/migrations`.
  Each test configures it (`:database`, `:priv`) before starting it.
  """

  use Ecto.Repo, otp_app: :macaw_host, adapter: Ecto.Adapters.SQLite3

  @doc """
  The repo's configuration for a database under `dir`: `:priv` reaches
  `test/support/repo` from the app's directory, where Ecto looks for
  migrations (`Application.app_dir/2` joins it as given).
  """
  def configure(dir) do
    up =
      :macaw_host |> Application.app_dir() |> Path.split() |> tl() |> Enum.map(fn _ -> ".." end)

    support = Path.expand("repo", __DIR__) |> Path.relative_to("/")

    Application.put_env(:macaw_host, __MODULE__,
      database: Path.join(dir, "test.db"),
      priv: Path.join(up ++ [support]),
      pool_size: 1
    )
  end
end

defmodule Macaw.Host.TestRepo.Probes do
  @moduledoc """
  The body of the test repo's one migration (version 20260101000000,
  `test/support/repo/migrations`), compiled once with the test support.

  Ecto compiles a migration file every time it runs it from a path, so two
  tests that each migrate a fresh database from the files would define the
  file's module twice in one VM. Only `Macaw.Host.Release.migrate/1`'s test
  needs the files (that is what it tests); a test that only needs the
  migration run hands Ecto this module with the version instead.
  """

  use Ecto.Migration

  def version, do: 20_260_101_000_000

  def change do
    create table(:probes) do
      add(:name, :string)
    end
  end
end
