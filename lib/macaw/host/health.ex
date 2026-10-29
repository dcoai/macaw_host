defmodule Macaw.Host.Health do
  @moduledoc """
  An app's health, in one shape every `<app>-ctl status` reads.

  A report runs named checks. Each returns a term: `:ok`, `{:error, detail}`
  (the app is unhealthy) or `{:warn, detail}` (worth showing, not a
  failure), `detail` a string for people:

      Macaw.Host.Health.report([
        database: fn -> Macaw.Host.Health.database(MyApp.Repo) end,
        migrations: fn -> Macaw.Host.Health.migrations(MyApp.Repo) end,
        data_dir: fn -> Macaw.Host.Health.writable(data_dir) end
      ], version: MyApp.Build.version(), build: MyApp.Build.sha())

  gives the report, its checks' results kept as the terms they are and
  `healthy` decided from them (a warning keeps it healthy, an error
  doesn't):

      %{healthy: true, version: "1.2.0", build: "3f639e84a704",
        checks: %{database: :ok, migrations: :ok, data_dir: :ok}}

  Text is made only at the edge: `Macaw.Host.Health.to_wire/1` words each
  result (`"ok"`, `"warning: <detail>"`, `"error: <detail>"`), and the two
  edges that send a report, `Macaw.Host.Health.Plug` (JSON, `200` when
  healthy and `503` when not) and `Macaw.Host.Release.status/1` (the line
  `<app>-ctl status` reads), call it.

  A check that raises is reported as an error naming the exception, never
  a crash of the report: the point of a health check is to answer while
  something is broken. A check that returns anything else (a bare string,
  `"ok"` included) is an error naming the check: its text is never read
  for what it might mean. The whole report answers within its deadline
  (5 s unless `:deadline` says otherwise): the checks run side by side,
  each given the time left, and one that misses it is reported as timed
  out.
  """

  @typedoc "A check's result: a term, never text."
  @type result :: :ok | {:warn, term()} | {:error, term()}

  @type check :: (-> result())

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

    Map.merge(%{healthy: healthy?(results), checks: results}, Map.new(extra))
  end

  @doc """
  Whether results are healthy: none is an error (a warning is not a
  failure, and no results are healthy). Decided from the terms alone.
  """
  @spec healthy?(%{optional(atom()) => result()}) :: boolean()
  def healthy?(results), do: not Enum.any?(results, &match?({_, {:error, _}}, &1))

  @doc """
  The report as it is sent: each check's result worded as text, `"ok"`,
  `"warning: <detail>"` or `"error: <detail>"` (a detail that is not a
  string `inspect`ed), every other key as it is. Raises `ArgumentError`
  for a map that isn't a report (no `:healthy` boolean or `:checks` map)
  and for a result that isn't a check's term, naming the check: a
  report's results are never text before this.
  """
  @spec to_wire(map()) :: map()
  def to_wire(%{healthy: healthy, checks: %{} = checks} = report) when is_boolean(healthy),
    do: %{report | checks: Map.new(checks, fn {name, r} -> {name, word(name, r)} end)}

  def to_wire(other),
    do:
      raise(
        ArgumentError,
        "not a health report (a map with a :healthy boolean and a :checks map): #{inspect(other)}"
      )

  defp word(_name, :ok), do: "ok"
  defp word(_name, {:warn, detail}), do: "warning: " <> detail(detail)
  defp word(_name, {:error, detail}), do: "error: " <> detail(detail)

  defp word(name, other),
    do:
      raise(
        ArgumentError,
        "health check #{inspect(name)}'s result is #{inspect(other)}, " <>
          "not :ok, {:warn, detail} or {:error, detail}"
      )

  defp detail(detail) when is_binary(detail), do: detail
  defp detail(detail), do: inspect(detail)

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
      answer = Task.yield(task, left) || Task.shutdown(task, :brutal_kill)
      {name, result(name, answer, deadline)}
    end)
  end

  defp result(_name, {:ok, :ok}, _deadline), do: :ok
  defp result(_name, {:ok, {:error, _} = error}, _deadline), do: error
  defp result(_name, {:ok, {:warn, _} = warn}, _deadline), do: warn

  # Refused, never guessed from: a string is not a result, whatever it says.
  defp result(name, {:ok, other}, _deadline),
    do:
      {:error,
       "check #{inspect(name)} returned #{inspect(other)}, " <>
         "not :ok, {:warn, detail} or {:error, detail}"}

  defp result(_name, {:exit, reason}, _deadline), do: {:error, Exception.format_exit(reason)}

  defp result(_name, nil, deadline),
    do: {:error, "timed out (no answer within the report's #{deadline} ms)"}

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
