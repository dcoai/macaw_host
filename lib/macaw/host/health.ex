defmodule Macaw.Host.Health do
  @moduledoc """
  An app's health, in one shape every `<app>-ctl status` reads.

  A report runs named checks. Each returns `:ok`, `{:error, detail}` (the
  app is unhealthy) or `{:warn, detail}` (worth showing, not a failure):

      Macaw.Host.Health.report([
        database: fn -> Macaw.Host.Health.database(MyApp.Repo) end,
        migrations: fn -> Macaw.Host.Health.migrations(MyApp.Repo) end,
        data_dir: fn -> Macaw.Host.Health.writable(data_dir) end
      ], version: MyApp.Build.version(), build: MyApp.Build.sha())

  gives

      %{healthy: true, version: "1.2.0", build: "3f639e84a704",
        checks: %{database: "ok", migrations: "ok", data_dir: "ok"}}

  A check that raises is reported as an error naming the exception, never
  a crash of the report: the point of a health check is to answer while
  something is broken. `Macaw.Host.Health.Plug` serves the report as JSON,
  `200` when healthy and `503` when not.
  """

  @type check :: (-> :ok | {:error, String.t()} | {:warn, String.t()})

  @doc "Runs the checks and builds the report; `extra` is merged in (version, build)."
  @spec report([{atom(), check()}], keyword()) :: map()
  def report(checks, extra \\ []) do
    results = Map.new(checks, fn {name, check} -> {name, run(check)} end)

    healthy =
      Enum.all?(results, fn {_, r} -> r == "ok" or String.starts_with?(r, "warning: ") end)

    Map.merge(%{healthy: healthy, checks: results}, Map.new(extra))
  end

  # A check runs in its own process, so one that raises or exits is reported
  # by its exit reason (never rescued) and the report still answers.
  defp run(check) do
    task = Task.Supervisor.async_nolink(Macaw.Host.Health.Tasks, check)

    case Task.yield(task, 5_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, :ok} -> "ok"
      {:ok, {:error, detail}} -> "error: " <> detail
      {:ok, {:warn, detail}} -> "warning: " <> detail
      {:ok, other} -> "error: check returned #{inspect(other)}"
      {:exit, reason} -> "error: " <> Exception.format_exit(reason)
      nil -> "error: no answer in 5 s"
    end
  end

  @doc "Whether a directory is writable, by writing and removing a probe file."
  @spec writable(Path.t()) :: :ok | {:error, String.t()}
  def writable(dir) do
    probe = Path.join(dir, ".health-#{System.unique_integer([:positive])}")

    case File.write(probe, "") do
      :ok ->
        File.rm(probe)
        :ok

      {:error, reason} ->
        {:error, "#{dir} is not writable (#{:file.format_error(reason)})"}
    end
  end

  @doc "Whether a repo answers `SELECT 1`. Requires `ecto_sql`."
  @spec database(module()) :: :ok | {:error, String.t()}
  def database(repo) do
    case apply(Ecto.Adapters.SQL, :query, [repo, "SELECT 1", []]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, Exception.message(error)}
    end
  end

  @doc "Whether every migration has run. Requires `ecto_sql`."
  @spec migrations(module()) :: :ok | {:error, String.t()}
  def migrations(repo) do
    pending = for {:down, version, _} <- apply(Ecto.Migrator, :migrations, [repo]), do: version
    if pending == [], do: :ok, else: {:error, "#{length(pending)} pending"}
  end
end
