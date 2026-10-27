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
  something is broken. The whole report answers within its deadline (5 s
  unless `:deadline` says otherwise): the checks run side by side, each
  given the time left, and one that misses it is reported as timed out.
  `Macaw.Host.Health.Plug` serves the report as JSON, `200` when healthy
  and `503` when not.
  """

  @type check :: (-> :ok | {:error, term()} | {:warn, term()})

  @deadline 5_000
  @reserved [:healthy, :checks]

  @doc """
  Runs the checks and builds the report; `extra` is merged in (version,
  build), and may not set `:healthy` or `:checks` (an `ArgumentError`, at
  the call). Options: `:deadline`, the whole report's, in milliseconds
  (default 5000).
  """
  @spec report([{atom(), check()}], keyword(), keyword()) :: map()
  def report(checks, extra \\ [], opts \\ []) do
    case Enum.filter(@reserved, &Keyword.has_key?(extra, &1)) do
      [] ->
        :ok

      taken ->
        raise ArgumentError,
              "a health report's extra may not set #{Enum.map_join(taken, " or ", &inspect/1)}: " <>
                "the report computes them"
    end

    deadline = Keyword.get(opts, :deadline, @deadline)
    results = run_all(checks, deadline)

    healthy =
      Enum.all?(results, fn {_, r} -> r == "ok" or String.starts_with?(r, "warning: ") end)

    Map.merge(%{healthy: healthy, checks: results}, Map.new(extra))
  end

  # Each check runs in its own process, so one that raises or exits is
  # reported by its exit reason (never rescued) and the report still
  # answers. They start together; each is waited for only as long as the
  # report's deadline leaves, then killed.
  defp run_all(checks, deadline) do
    ends_at = System.monotonic_time(:millisecond) + deadline

    checks
    |> Enum.map(fn {name, check} ->
      {name, Task.Supervisor.async_nolink(Macaw.Host.Health.Tasks, check)}
    end)
    |> Map.new(fn {name, task} ->
      left = max(ends_at - System.monotonic_time(:millisecond), 0)
      {name, result(Task.yield(task, left) || Task.shutdown(task, :brutal_kill), deadline)}
    end)
  end

  defp result({:ok, :ok}, _deadline), do: "ok"
  defp result({:ok, {:error, detail}}, _deadline), do: "error: " <> detail(detail)
  defp result({:ok, {:warn, detail}}, _deadline), do: "warning: " <> detail(detail)
  defp result({:ok, other}, _deadline), do: "error: check returned #{inspect(other)}"
  defp result({:exit, reason}, _deadline), do: "error: " <> Exception.format_exit(reason)

  defp result(nil, deadline),
    do: "error: timed out (no answer within the report's #{deadline} ms)"

  defp detail(detail) when is_binary(detail), do: detail
  defp detail(detail), do: inspect(detail)

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
