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
  only what migrating needs. Requires `ecto_sql`.
  """
  @spec migrate(atom()) :: :ok
  def migrate(app) do
    Application.load(app)

    unless Code.ensure_loaded?(Ecto.Migrator),
      do: fail("migrate needs ecto_sql, which #{app} does not depend on")

    for repo <- Application.fetch_env!(app, :ecto_repos) do
      {:ok, _, _} =
        apply(Ecto.Migrator, :with_repo, [
          repo,
          &apply(Ecto.Migrator, :run, [&1, :up, [all: true]])
        ])
    end

    emit(%{ok: true, migrated: true})
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

  @doc "The config commands, pure apart from the file: `{:ok, objects}` or `{:error, message}`."
  @spec config_command(Path.t(), [Config.spec()], String.t(), [String.t()]) ::
          {:ok, [map()]} | {:error, String.t()}
  def config_command(path, specs, prefix, argv) do
    file = Config.Literal.read!(path)

    case argv do
      ["list"] ->
        {:ok, for({name, type, default} <- specs, do: show(name, type, default, file, prefix))}

      ["get", name] ->
        case Enum.find(specs, fn {key, _, _} -> Atom.to_string(key) == name end) do
          nil -> {:error, "no setting named #{name}"}
          {key, type, default} -> {:ok, [show(key, type, default, file, prefix)]}
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

  defp show(name, type, default, file, prefix) do
    var = Config.env_var(prefix, name)

    {value, source} =
      cond do
        System.get_env(var) -> {System.get_env(var), "env #{var}"}
        Map.has_key?(file, name) -> {file[name], "config.exs"}
        true -> {default, "default"}
      end

    %{name: name, value: Config.mask(type, value), source: source}
  end
end
