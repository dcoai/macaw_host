defmodule Mix.Tasks.Macaw.Host.Ctl do
  @shortdoc "Generates the app's <app>-ctl host control script"

  @moduledoc """
  Generates the app's host control script from the `:ctl` description in
  its `mix.exs` (`Macaw.Host.Ctl.Description`) and its own commands
  (`Ctl.AppCommands`, in `ctl/app_commands.ex` by default).

      mix macaw.host.ctl           # write the script (mode 0755)
      mix macaw.host.ctl --check   # fail if the committed script differs

  `--check` is for CI: it regenerates in memory and exits non-zero naming
  the first line that differs, so a script edited by hand, or a generator
  or app commands changed without regenerating, never ships.
  """

  use Mix.Task

  alias Macaw.Host.Ctl
  alias Macaw.Host.Ctl.Description

  @impl Mix.Task
  def run(argv) do
    check? =
      case OptionParser.parse(argv, strict: [check: :boolean]) do
        {opts, [], []} -> Keyword.get(opts, :check, false)
        _ -> Mix.raise("usage: mix macaw.host.ctl [--check]")
      end

    project = Mix.Project.config()

    with {:ok, description} <- Description.new(project[:ctl], project[:app]),
         {:ok, source} <- app_commands_source(description.app_commands),
         {:ok, script} <- Ctl.build(description, source) do
      if check?, do: check(description.output, script), else: write(description.output, script)
    else
      {:error, message} -> Mix.raise(message)
    end
  end

  defp app_commands_source(false), do: {:ok, nil}

  defp app_commands_source(path) do
    case File.read(path) do
      {:ok, source} ->
        {:ok, source}

      {:error, reason} ->
        {:error, "cannot read the app commands #{path}: #{:file.format_error(reason)}"}
    end
  end

  defp write(path, script) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, script)
    File.chmod!(path, 0o755)
    Mix.shell().info("wrote #{path}")
  end

  defp check(path, script) do
    with {:ok, committed} <- read_committed(path),
         :ok <- Ctl.compare(script, committed) do
      Mix.shell().info("#{path} is up to date")
    else
      {:error, message} ->
        Mix.raise("#{path}: #{message}\nRun mix macaw.host.ctl to regenerate it.")
    end
  end

  defp read_committed(path) do
    case File.read(path) do
      {:ok, text} -> {:ok, text}
      {:error, reason} -> {:error, "cannot read it: #{:file.format_error(reason)}"}
    end
  end
end
