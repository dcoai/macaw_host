defmodule Macaw.Host.Ctl do
  @moduledoc """
  Generates an app's host control script, `<app>-ctl`, so the apps of the
  family stop hand-maintaining thousands of lines of the same script.

  The script follows the deployable-containers pattern: a single Elixir
  file, standard library only, with one line of host state (`@data_dir`,
  in `Ctl.Home`, the first module), every docker argv built in `Ctl.Docker`,
  and the host touched only through the swappable `Ctl.World`. It is built
  from three parts:

  - the **generic modules**, EEx templates in `priv/ctl/` compiled into this
    module: `Ctl.Home`, `Ctl.App`, `Ctl.World`, `Ctl.Script`, `Ctl.Secret`,
    `Ctl.Env`, `Ctl.Docker`, `Ctl.Commands` and `Ctl`;
  - the **description** (`Macaw.Host.Ctl.Description`), from the app's
    `mix.exs`, which fills in everything app-specific;
  - the app's **own commands**, a source file defining `Ctl.AppCommands`,
    spliced in as it is.

  `generate/2` is pure, so it is tested without Mix; `mix macaw.host.ctl`
  writes its result, and `--check` compares it with the committed file.

  ## The `Ctl.AppCommands` contract

  The app's file holds one module, `Ctl.AppCommands`, and nothing beside
  it: a module of its own goes inside it (`Ctl.AppCommands.Helpers`), and
  code outside it, which would run every time the script loads, is
  refused. The module has:

  - `commands/0`: `[{name, usage, help}]`, the app's commands. `name` is
    what is typed (`"asterisk"`), `usage` how `help` shows it
    (`"asterisk [CLI COMMAND]"`), `help` one sentence. A name the script
    already has (`start`, `config` …) is never dispatched here.
  - `run(name, env, args)`: runs one, returning what the common commands
    do: `:ok`, `{:error, message}` (printed, exit 1) or `{:halt, status}`.
    It is called only once the data directory is set.
  - optionally `run_args(env)`: extra `docker run` arguments (more ports,
    say), placed before DOCKER_RUN_ARGS.

  It builds its docker command lines with `Ctl.Docker` (`exec_args/3`,
  `rpc_args/2`, `eval_args/3`, `release_args/4`), runs them with
  `Ctl.Commands.stream/1` or `interactive/1`, checks the container with
  `Ctl.Commands.ensure_running/1` or `ensure_ready/1`, and reads what it
  manages from `Ctl.App`. A secret goes to the container by name, through
  `eval_args/3` or `release_args/4`, never on a command line.
  """

  require EEx

  alias Macaw.Host.Ctl.Description

  @templates ~w(head world env docker commands main)a

  for name <- @templates do
    path = Path.join([__DIR__, "..", "..", "..", "priv", "ctl", "#{name}.eex"]) |> Path.expand()
    @external_resource path
    text = File.read!(path)

    # A template with no tags (a module with nothing app-specific) is text.
    if String.contains?(text, "<%") do
      EEx.function_from_file(:defp, name, path, [:assigns])
    else
      defp unquote(name)(_assigns), do: unquote(text)
    end
  end

  @no_app_commands """
  defmodule Ctl.AppCommands do
    @moduledoc "The app adds no commands of its own."
    def commands, do: []
    def run(command, _env, _args), do: {:error, "unknown command: \#{command}"}
  end
  """

  @doc """
  The script for `description` (a `:ctl` keyword list, or a map
  `Macaw.Host.Ctl.Description.new/2` returned) and the source of the app's
  `Ctl.AppCommands` (nil for none). Raises `ArgumentError` naming the fault
  when either is invalid.
  """
  @spec generate(keyword() | Description.t(), String.t() | nil) :: String.t()
  def generate(description, app_commands_source) do
    case build(description, app_commands_source) do
      {:ok, script} -> script
      {:error, message} -> raise ArgumentError, message
    end
  end

  @doc "As `generate/2`: `{:ok, script}` or `{:error, message}`."
  @spec build(keyword() | Description.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, String.t()}
  def build(description, app_commands_source) do
    with {:ok, d} <- describe(description),
         {:ok, source} <- app_commands(app_commands_source) do
      parts = [
        head(d),
        world(d),
        env(d),
        docker(d),
        commands(d),
        source,
        main(d)
      ]

      {:ok,
       parts
       |> Enum.join("\n")
       |> Code.format_string!()
       |> IO.iodata_to_binary()
       |> Kernel.<>("\n")}
    end
  end

  defp describe(%{script: _, ids: _} = checked), do: {:ok, checked}
  defp describe(description), do: Description.new(description)

  @doc """
  Checks the source of an app's commands: it parses, holds nothing but the
  one `Ctl.AppCommands` module (no other module, no code outside it,
  which would run whenever the script loads), and defines `commands/0`
  and `run/3`, so it can neither replace a generic module nor carry a
  second `@data_dir`. nil is the module of no commands.
  """
  @spec app_commands(String.t() | nil) :: {:ok, String.t()} | {:error, String.t()}
  def app_commands(nil), do: {:ok, @no_app_commands}

  def app_commands(source) when is_binary(source) do
    with {:ok, ast} <- parse(source),
         :ok <- only_app_modules(ast),
         :ok <- nothing_beside(source),
         :ok <- defines(ast, :commands, 0),
         :ok <- defines(ast, :run, 3),
         :ok <- no_data_dir(source) do
      {:ok, source}
    end
  end

  defp parse(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        {:error,
         "Ctl.AppCommands does not parse: line #{meta[:line]}: #{format_message(message)}#{token}"}
    end
  end

  defp format_message({prefix, suffix}), do: "#{prefix}#{suffix} "
  defp format_message(message), do: message

  defp only_app_modules(ast) do
    names = for {:defmodule, _, [{:__aliases__, _, parts}, _]} <- top_level(ast), do: parts

    cond do
      names == [] ->
        {:error, "the app commands file must define Ctl.AppCommands"}

      bad = Enum.find(names, &(not match?([:Ctl, :AppCommands | _], &1))) ->
        {:error,
         "the app commands file may define only Ctl.AppCommands, not #{Enum.join(bad, ".")}"}

      [:Ctl, :AppCommands] not in names ->
        {:error, "the app commands file must define Ctl.AppCommands"}

      true ->
        :ok
    end
  end

  defp top_level({:__block__, _, exprs}), do: exprs
  defp top_level(expr), do: [expr]

  # The file's one top-level expression is `defmodule Ctl.AppCommands`.
  # Parsed again with every literal wrapped, so a bare literal at the top
  # level has a line too.
  defp nothing_beside(source) do
    {:ok, ast} =
      Code.string_to_quoted(source, literal_encoder: &{:ok, {:__block__, &2, [&1]}})

    stray =
      ast
      |> top_level()
      |> Enum.reject(&match?({:defmodule, _, [{:__aliases__, _, [:Ctl, :AppCommands]}, _]}, &1))

    case {stray, length(top_level(ast))} do
      {[], 1} ->
        :ok

      {[], _} ->
        {:error, "the app commands file may hold only one Ctl.AppCommands module"}

      {[first | _], _} ->
        {:error,
         "the app commands file may hold only the Ctl.AppCommands module; " <>
           "line #{line_of(first)} is outside it: #{first_line(first)}"}
    end
  end

  defp line_of({_, meta, _}) when is_list(meta), do: Keyword.get(meta, :line, "?")
  defp line_of(_), do: "?"

  defp first_line(ast), do: ast |> Macro.to_string() |> String.split("\n") |> hd()

  defp defines(ast, name, arity) do
    {_, found?} =
      Macro.prewalk(ast, false, fn
        {:def, _, [head | _]} = node, acc -> {node, acc or def_head?(head, name, arity)}
        node, acc -> {node, acc}
      end)

    if found?, do: :ok, else: {:error, "Ctl.AppCommands must define #{name}/#{arity}"}
  end

  defp def_head?({:when, _, [head | _]}, name, arity), do: def_head?(head, name, arity)
  defp def_head?({name, _, args}, name, arity) when is_list(args), do: length(args) == arity
  defp def_head?({name, _, ctx}, name, 0) when is_atom(ctx), do: true
  defp def_head?(_, _, _), do: false

  defp no_data_dir(source) do
    if Regex.match?(~r/^\s*@data_dir\b/m, source),
      do:
        {:error,
         "Ctl.AppCommands must not set @data_dir: the script's one line of host state is in Ctl.Home"},
      else: :ok
  end

  @doc """
  `:ok` when `committed` is exactly `generated`, else `{:error, message}`
  naming the first line that differs, for `mix macaw.host.ctl --check`.
  """
  @spec compare(String.t(), String.t()) :: :ok | {:error, String.t()}
  def compare(generated, generated), do: :ok

  def compare(generated, committed) do
    wanted = lines(generated)
    found = lines(committed)

    {line, want, got} =
      case first_difference(wanted, found) do
        nil ->
          # Every line agrees: only the newline at the end of one differs.
          last = length(wanted)
          {last, ending(List.last(wanted), generated), ending(List.last(found), committed)}

        {line, want, got} ->
          {line, describe_line(want), describe_line(got)}
      end

    {:error,
     """
     the committed script differs from what the generator makes, first at line #{line}:
       generated: #{want}
       committed: #{got}\
     """}
  end

  # A text's lines; the newline ending the last one starts no line of its own.
  defp lines(text) do
    case String.split(text, "\n") do
      [""] -> []
      split -> if String.ends_with?(text, "\n"), do: Enum.drop(split, -1), else: split
    end
  end

  defp first_difference(wanted, found) do
    width = max(length(wanted), length(found))

    Enum.find_value(0..(width - 1)//1, fn i ->
      want = Enum.at(wanted, i)
      got = Enum.at(found, i)
      if want != got, do: {i + 1, want, got}
    end)
  end

  defp ending(line, text) do
    if String.ends_with?(text, "\n"),
      do: inspect(line),
      else: inspect(line) <> " (no newline at the end of the file)"
  end

  defp describe_line(nil), do: "(end of file)"
  defp describe_line(line), do: inspect(line)
end
