defmodule Macaw.Host.Release do
  @moduledoc """
  The release side of an app's `<app>-ctl`: entry points the script runs as
  `bin/<app> eval` (in a throwaway container, so they work with the app
  stopped) or `bin/<app> rpc` (asking the running app).

  The protocol, the same for every app:
  - **Arguments** arrive as a JSON array in `<PREFIX>_CTL_ARGS`, never on
    a command line `ps` can show; a password in `<PREFIX>_CTL_PASSWORD`.
  - **Output** is one JSON object per line on stdout, for the script to
    read; a failure is one line on stderr and exit status 1.
  - **Nothing typed becomes an atom.** Names are matched as strings
    (`String.to_existing_atom/1` fails under `eval` for atoms the release
    never loaded, though tests pass: the bug this module exists to rule out).

  An app's release module delegates to these:

      defmodule MyApp.Release do
        def migrate, do: Macaw.Host.Release.migrate(:my_app)
        def config, do: Macaw.Host.Release.config(:my_app, MyApp.Settings.specs(), "MY_APP")
        def status, do: Macaw.Host.Release.status(MyApp.Health.report())
      end
  """

  alias Macaw.Host.Config

  @doc """
  Runs every repo's migrations for `app` (its `:ecto_repos`), starting
  only what migrating needs, and emits the versions it applied. Ecto's own
  log is off: the answer is the one line on stdout (spec 03 §1). Requires
  `ecto_sql`.
  """
  @spec migrate(atom()) :: :ok
  def migrate(app) do
    Application.load(app)

    unless Code.ensure_loaded?(Ecto.Migrator),
      do: fail("migrate needs ecto_sql, which #{app} does not depend on")

    quiet = [all: true, log: false, log_migrations_sql: false, log_migrator_sql: false]

    versions =
      for repo <- Application.fetch_env!(app, :ecto_repos) do
        {:ok, versions, _} =
          apply(Ecto.Migrator, :with_repo, [repo, &apply(Ecto.Migrator, :run, [&1, :up, quiet])])

        versions
      end

    emit(%{ok: true, migrated: true, versions: versions |> Enum.concat() |> Enum.sort()})
  end

  @doc """
  `<app>-ctl config list | get NAME | set NAME VALUE | unset NAME`, over the
  app's literal `config.exs` in its data directory (`:data_dir` in the
  app's environment). Arguments from `<PREFIX>_CTL_ARGS`.
  """
  @spec config(atom(), [Config.spec()], String.t()) :: :ok
  def config(app, specs, prefix) do
    Application.load(app)
    path = Path.join(Application.fetch_env!(app, :data_dir), "config.exs")

    case config_command(path, specs, prefix, ctl_args!(prefix)) do
      {:ok, lines} -> Enum.each(lines, &emit/1)
      {:error, message} -> fail(message)
    end
  end

  @doc """
  The config commands, pure apart from the file and `env` (the environment,
  `System.get_env/0` by default): `{:ok, objects}` or `{:error, message}`.
  A file with faults is the error, every fault on one line.

  `list` and `get` show each setting as the app would load it, through
  `Macaw.Host.Config.resolve_setting/4`, the path `Macaw.Host.Config.load!/3`
  takes: `%{name, value, source}`, the value typed and then shown
  (`Macaw.Host.Config.mask/2`), or, when it doesn't fit its type, the value
  as found with the load's `fault`.
  """
  @spec config_command(Path.t(), [Config.spec()], String.t(), [String.t()], map()) ::
          {:ok, [map()]} | {:error, String.t()}
  def config_command(path, specs, prefix, argv, env \\ System.get_env()) do
    with {:ok, file} <- Config.read_file(path) do
      command(path, specs, prefix, argv, env, file)
    end
  end

  defp command(path, specs, prefix, argv, env, file) do
    case argv do
      ["list"] ->
        {:ok, for(spec <- specs, do: show(spec, env, file, prefix))}

      ["get", name] ->
        case Enum.find(specs, fn {key, _, _} -> Atom.to_string(key) == name end) do
          nil -> {:error, "no setting named #{name}"}
          spec -> {:ok, [show(spec, env, file, prefix)]}
        end

      ["set", name, value] ->
        with {:ok, _} <- Config.put!(path, specs, name, value),
             do: {:ok, [%{ok: true, set: name, restart: "restart to apply"}]}

      ["unset", name] ->
        with :ok <- Config.delete!(path, specs, name),
             do: {:ok, [%{ok: true, unset: name, restart: "restart to apply"}]}

      _ ->
        {:error, "usage: config list | get NAME | set NAME VALUE | unset NAME"}
    end
  end

  @doc "Prints the running app's report (a health map, say) as one JSON line, for `rpc`."
  @spec status(map()) :: :ok
  def status(report), do: emit(report)

  @doc """
  The arguments in `<PREFIX>_CTL_ARGS`, a JSON array of strings. Fails with a
  message when it is missing or malformed.
  """
  @spec ctl_args!(String.t()) :: [String.t()]
  def ctl_args!(prefix) do
    var = prefix <> "_CTL_ARGS"

    with text when is_binary(text) <- System.get_env(var),
         {:ok, args} when is_list(args) <- JSON.decode(text),
         true <- Enum.all?(args, &is_binary/1) do
      args
    else
      _ -> fail("#{var} must be a JSON array of strings")
    end
  end

  @doc "The password in `<PREFIX>_CTL_PASSWORD`, or nil."
  @spec ctl_password(String.t()) :: String.t() | nil
  def ctl_password(prefix), do: System.get_env(prefix <> "_CTL_PASSWORD")

  @doc "Prints one JSON object as a line."
  @spec emit(map()) :: :ok
  def emit(object), do: IO.puts(JSON.encode!(object))

  @doc "Prints a message on stderr and exits with status 1."
  @spec fail(String.t()) :: no_return()
  def fail(message) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp show({name, type, _} = spec, env, file, prefix) do
    case Config.resolve_setting(spec, env, file, prefix) do
      {:ok, %{value: value, source: source}} ->
        %{name: name, value: Config.mask(type, value), source: source_text(source, name, prefix)}

      {:error, %{raw: raw, source: source, fault: fault}} ->
        %{
          name: name,
          value: Config.mask(type, raw),
          source: source_text(source, name, prefix),
          fault: fault
        }
    end
  end

  defp source_text(:env, name, prefix), do: "env " <> Config.env_var(prefix, name)
  defp source_text(:file, _name, _prefix), do: "config.exs"
  defp source_text(:default, _name, _prefix), do: "default"
end
