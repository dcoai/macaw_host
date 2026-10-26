defmodule Macaw.Host.Config do
  @moduledoc """
  An app's configuration, from the literal `config.exs` on its data volume.

  Each setting resolves as **env var > `config.exs` > default**. An app
  declares its settings once, as `{name, type, default}`
  (`Macaw.Host.Config.Types`), and loads them at boot:

      @settings [
        {:public_host, :string, "localhost"},
        {:port, :port, 4000},
        {:smtp_password, :secret, nil}
      ]

      Macaw.Host.Config.load!(:my_app, @settings,
        path: "/data/config.exs", env_prefix: "MY_APP")

      Macaw.Host.Config.get(:my_app, :port)

  `MY_APP_PORT` wins over `port` in the file, which wins over `4000`. Every
  invalid value and every unknown key in the file fails the load **at
  once**, each named with where it came from, so a broken boot says
  everything that is wrong in one message. The resolved values, with each
  one's source, are kept in `:persistent_term` and read without copying.

  `put!/4` and `delete!/3` edit the file for the `<app>-ctl config` command:
  the value is parsed as a literal, checked against the setting's type, and
  the file is written atomically; nothing is evaluated.
  """

  alias Macaw.Host.Config.{Literal, Types}

  @type spec :: {atom(), Types.t(), term()}
  @type source :: :env | :file | :default
  @type resolved :: %{atom() => %{value: term(), source: source()}}

  @doc """
  Resolves settings from an env map, a file map and the env var prefix.
  Pure: `{:ok, resolved}` or `{:error, faults}`.
  """
  @spec resolve([spec()], %{String.t() => String.t()}, map(), String.t()) ::
          {:ok, resolved()} | {:error, [String.t()]}
  def resolve(specs, env, file, prefix) do
    names = Map.new(specs, fn {name, _, _} -> {Atom.to_string(name), name} end)

    unknown =
      for {key, _} <- file,
          not Map.has_key?(names, to_string(key)),
          do: "config.exs: unknown setting #{inspect(key)}"

    file = Map.new(file, fn {k, v} -> {to_string(k), v} end)

    {resolved, faults} =
      Enum.reduce(specs, {%{}, []}, fn {name, type, default}, {acc, faults} ->
        var = env_var(prefix, name)

        result =
          cond do
            Map.has_key?(env, var) ->
              {Types.cast(type, env[var]), :env, var}

            Map.has_key?(file, Atom.to_string(name)) ->
              {Types.check(type, file[Atom.to_string(name)]), :file, "config.exs #{name}"}

            true ->
              {{:ok, default}, :default, nil}
          end

        case result do
          {{:ok, value}, source, _} ->
            {Map.put(acc, name, %{value: value, source: source}), faults}

          {{:error, why}, _, where} ->
            {acc, ["#{where}: #{why}" | faults]}
        end
      end)

    case unknown ++ Enum.reverse(faults) do
      [] -> {:ok, resolved}
      all -> {:error, all}
    end
  end

  @doc """
  Reads the file and the environment, resolves, and stores the result under
  `app`. Options: `:path` (the file), `:env_prefix`, `:env` (default
  `System.get_env/0`). Raises `ArgumentError` listing every fault.
  """
  @spec load!(atom(), [spec()], keyword()) :: resolved()
  def load!(app, specs, opts) do
    prefix = Keyword.fetch!(opts, :env_prefix)
    env = Keyword.get_lazy(opts, :env, &System.get_env/0)

    file =
      case Literal.parse(read_text(Keyword.fetch!(opts, :path)), Keyword.fetch!(opts, :path)) do
        {:ok, map} -> map
        {:error, faults} -> raise ArgumentError, Enum.join(faults, "\n")
      end

    case resolve(specs, env, file, prefix) do
      {:ok, resolved} ->
        :persistent_term.put({__MODULE__, app}, %{values: resolved, specs: specs})
        resolved

      {:error, faults} ->
        raise ArgumentError, "invalid configuration:\n  " <> Enum.join(faults, "\n  ")
    end
  end

  @doc "A loaded setting's value. Raises for a name the app didn't declare."
  @spec get(atom(), atom()) :: term()
  def get(app, name), do: fetch!(app, name).value

  @doc "Where a loaded setting's value came from: `:env`, `:file` or `:default`."
  @spec source(atom(), atom()) :: source()
  def source(app, name), do: fetch!(app, name).source

  @doc "Every loaded setting as `{name, shown value, source}`, secrets masked."
  @spec show(atom()) :: [{atom(), String.t(), source()}]
  def show(app) do
    %{values: values, specs: specs} = :persistent_term.get({__MODULE__, app})

    for {name, type, _} <- specs do
      %{value: v, source: s} = values[name]
      {name, mask(type, v), s}
    end
  end

  @doc "A value as shown: a secret as `set (…last4)` or `unset`, anything else inspected."
  @spec mask(Types.t(), term()) :: String.t()
  def mask(:secret, nil), do: "unset"
  def mask(:secret, v) when byte_size(v) <= 4, do: "set"
  def mask(:secret, v), do: "set (…" <> String.slice(v, -4, 4) <> ")"
  def mask(_type, v), do: inspect(v)

  @doc "The env var a setting is read from: `PREFIX_NAME`."
  @spec env_var(String.t(), atom()) :: String.t()
  def env_var(prefix, name), do: prefix <> "_" <> String.upcase(Atom.to_string(name))

  @doc """
  Sets `name` in the file at `path` to the literal `text`, after checking it
  against the setting's type. `{:ok, value}` or `{:error, why}`; the file is
  untouched on error.
  """
  @spec put!(Path.t(), [spec()], String.t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def put!(path, specs, name, text) do
    with {:ok, {key, type}} <- lookup(specs, name),
         {:ok, value} <- parse_value(text),
         {:ok, value} <- Types.check(type, value) do
      Literal.write!(path, Map.put(Literal.read!(path), key, value), header())
      {:ok, value}
    end
  end

  @doc "Removes `name` from the file, so it falls back to its env var or default."
  @spec delete!(Path.t(), [spec()], String.t()) :: :ok | {:error, String.t()}
  def delete!(path, specs, name) do
    with {:ok, {key, _}} <- lookup(specs, name) do
      Literal.write!(path, path |> Literal.read!() |> Map.delete(key), header())
    end
  end

  @doc "The settings' names, in declared order."
  @spec keys([spec()]) :: [atom()]
  def keys(specs), do: Enum.map(specs, &elem(&1, 0))

  defp fetch!(app, name) do
    %{values: values} = :persistent_term.get({__MODULE__, app})

    case values do
      %{^name => entry} -> entry
      _ -> raise ArgumentError, "#{inspect(app)} declares no setting #{inspect(name)}"
    end
  end

  # Names typed at the ctl are matched as strings, so no atom is made.
  defp lookup(specs, name) do
    case Enum.find(specs, fn {key, _, _} -> Atom.to_string(key) == name end) do
      nil -> {:error, "no setting named #{name}"}
      {key, type, _} -> {:ok, {key, type}}
    end
  end

  defp parse_value(text) do
    case Literal.parse_value(text) do
      {:ok, value} -> {:ok, value}
      {:error, faults} -> {:error, Enum.join(faults, "; ")}
    end
  end

  defp read_text(path) do
    case File.read(path) do
      {:ok, text} -> text
      {:error, :enoent} -> "%{}"
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  defp header,
    do:
      "App configuration: a literal map, read but never evaluated.\nEdit it with `<app>-ctl config set KEY VALUE`; an env var still wins over it."
end
