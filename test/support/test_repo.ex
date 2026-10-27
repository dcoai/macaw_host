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
