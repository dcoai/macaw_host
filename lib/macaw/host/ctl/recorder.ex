defmodule Macaw.Host.Ctl.Recorder do
  @moduledoc """
  A recording stand-in for a generated script's `Ctl.World`, so an app's
  tests drive every `<app>-ctl` command without docker on the box and
  assert each command's exact docker argv.

  It ships in `lib/` rather than `test/support/` because a dependency's
  test support is not compiled into the app that depends on it: this way
  every app's tests use the one recorder that matches the generated
  `Ctl.World`, instead of copying it. It has no dependencies and does
  nothing until `install/2` names it in the calling process.

      # test/test_helper.exs: once per VM, before any test runs, since the
      # script's modules (`Ctl`, `Ctl.Env` …) are global.
      Macaw.Host.Ctl.Recorder.load!("container/my_app-ctl")

      # a test, with `@moduletag :tmp_dir`
      alias Macaw.Host.Ctl.Recorder

      test "start runs the container", %{tmp_dir: tmp_dir} do
        {script, _home} = Recorder.home!(tmp_dir, "my_app-ctl")
        Recorder.install([{["docker"], {"", 0}}])
        Ctl.dispatch(["start"], %{}, script)
        run = Enum.find(Recorder.docker_calls(), &match?(["run", "-d" | _], &1))
        assert ["run", "-d", "--name", "my_app" | _] = run
      end

  `install/2` takes the canned answers: a list of `{matcher, reply}`, the
  matcher a list the command's `[exe | args]` must start with, or a
  function of `(exe, args)`, and the reply `{output, status}`. The first
  matching entry answers; anything unmatched is `{"", 1}`, a docker that
  says no. Every call is recorded, with its options (where a secret's value
  travels, in `:env`). Everything lives in the calling process's
  dictionary, so async tests do not see each other's calls.
  """

  @doc """
  Loads a generated script's modules into this VM without running it:
  `:ctl_no_main` keeps its last line from calling `main/1`. Loading the
  same path again is a no-op; a script is loaded once per VM, as its
  modules are global.
  """
  @spec load!(Path.t()) :: :ok
  def load!(path) do
    Process.put(:ctl_no_main, true)
    Code.require_file(path)
    Process.delete(:ctl_no_main)
    :ok
  end

  @doc """
  Makes this process's `Ctl.World` the recorder. Options: `:answer`, what
  `prompt/1` and `prompt_secret/1` answer (default `""`); `:files`, a map
  of host paths to their text, what `read_local/1` answers (any other path
  is `{:error, :enoent}`).
  """
  @spec install(
          [{list() | (String.t(), [String.t()] -> boolean()), {String.t(), integer()}}],
          keyword()
        ) ::
          :ok
  def install(replies \\ [], opts \\ []) do
    Process.put(:ctl_world, __MODULE__)
    Process.put(:ctl_world_replies, replies)
    Process.put(:ctl_world_calls, [])
    Process.put(:ctl_world_answer, Keyword.get(opts, :answer, ""))
    Process.put(:ctl_world_files, Keyword.get(opts, :files, %{}))
    :ok
  end

  @doc """
  Every call so far, in order: `{exe, args, opts}`, `{:sleep, ms}`,
  `{:read_local, path}`, `{:write_local, path, bytes}` (nothing is written)
  or `{:prompt, question}`.
  """
  @spec calls() :: [tuple()]
  def calls, do: Process.get(:ctl_world_calls, []) |> Enum.reverse()

  @doc "The argv of each docker invocation, in order."
  @spec docker_calls() :: [[String.t()]]
  def docker_calls, do: for({"docker", args, _opts} <- calls(), do: args)

  @doc """
  Writes a minimal script at `path`: its `Ctl.Home` naming `data_dir`, the
  only part of the file the loaded modules read from disk.
  """
  @spec script!(Path.t(), Path.t() | nil) :: Path.t()
  def script!(path, data_dir \\ nil) do
    File.write!(path, """
    #!/usr/bin/env elixir
    defmodule Ctl.Home do
      @moduledoc false
      @data_dir #{inspect(data_dir)}
      def data_dir, do: @data_dir
    end
    # the rest of the script
    """)

    path
  end

  @doc """
  A host under `tmp_dir`: `home/data/` and a script `script_name` naming
  `home` as its data directory. `{script, home}`.
  """
  @spec home!(Path.t(), String.t()) :: {Path.t(), Path.t()}
  def home!(tmp_dir, script_name) do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(home, "data"))
    {script!(Path.join(tmp_dir, script_name), home), home}
  end

  @doc false
  def cmd(exe, args, opts) do
    record({exe, args, opts})

    reply =
      Enum.find_value(Process.get(:ctl_world_replies, []), {"", 1}, fn {matcher, reply} ->
        if matches?(matcher, exe, args), do: reply
      end)

    case Keyword.get(opts, :into) do
      nil ->
        reply

      collectable ->
        {output, status} = reply
        {Enum.into([output], collectable), status}
    end
  end

  @doc false
  def sleep(ms), do: record({:sleep, ms})

  @doc false
  def write_local(path, bytes) do
    record({:write_local, path, bytes})
    :ok
  end

  @doc false
  def read_local(path) do
    record({:read_local, path})

    case Process.get(:ctl_world_files, %{}) do
      %{^path => text} -> {:ok, text}
      _ -> {:error, :enoent}
    end
  end

  @doc false
  def prompt(question) do
    record({:prompt, question})
    Process.get(:ctl_world_answer, "")
  end

  @doc false
  def prompt_secret(question) do
    record({:prompt_secret, question})
    Process.get(:ctl_world_answer, "")
  end

  defp record(call), do: Process.put(:ctl_world_calls, [call | Process.get(:ctl_world_calls, [])])

  defp matches?(matcher, exe, args) when is_function(matcher, 2), do: matcher.(exe, args)

  defp matches?(prefix, exe, args) when is_list(prefix),
    do: List.starts_with?([exe | args], prefix)
end
