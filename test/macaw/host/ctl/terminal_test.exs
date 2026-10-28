defmodule Macaw.Host.Ctl.TerminalTest do
  @moduledoc """
  The generated script's real terminal code under a pseudo-terminal
  (macaw_host#1, from collpa#128 and #148). Every other ctl test swaps
  `Ctl.World` for the recorder, so this is where `Ctl.World.Real` reaches a
  terminal: the BEAM runs commands in a new session with no controlling
  terminal, which `/dev/tty` never survived. `script` (util-linux, in CI's
  image) provides the terminal.
  """
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  # Runs `body` in a fresh elixir with the sample script loaded, under a pty,
  # and returns everything the terminal showed. With `after: prompt`, `input`
  # is typed once `prompt` is on the terminal, as a person would, never after
  # a fixed pause a slow start outlasts (collpa#148). The wait is bounded
  # (60 s), after which the input is typed anyway and the output shows why.
  defp under_pty(dir, body, input, opts \\ []) do
    file = Path.join(dir, "run.exs")
    out = Path.join(dir, "out.txt")
    fifo = Path.join(dir, "in")

    File.write!(file, """
    Process.put(:ctl_no_main, true)
    Code.require_file(#{inspect(CtlFixture.path())})
    #{body}
    """)

    {_, 0} = System.cmd("mkfifo", [fifo])

    # The fifo is held open read-write on fd 3, so `script` starts without
    # waiting for a writer, and the typist writes when the prompt is shown.
    {_, _} =
      System.cmd("sh", [
        "-c",
        ~S"""
        exec 3<>"$2"
        (
          if [ -n "$4" ]; then
            i=0
            until grep -qF -- "$4" "$1" 2>/dev/null || [ "$i" -ge 600 ]; do sleep 0.1; i=$((i + 1)); done
          fi
          printf '%s' "$3" >&3
        ) &
        script -qec "elixir $0" /dev/null <&3 >"$1"
        wait
        """,
        file,
        out,
        fifo,
        input,
        Keyword.get(opts, :after, "")
      ])

    File.read!(out)
  end

  @tag verifies: "script-world-secret"
  test "prompt_secret reads the answer without echoing it", %{tmp_dir: dir} do
    out =
      under_pty(
        dir,
        ~S|IO.puts("got:" <> Ctl.World.Real.prompt_secret("password: "))|,
        "S3cretX\n",
        after: "password: "
      )

    assert out =~ "password: "
    assert out =~ "got:S3cretX"
    assert length(String.split(out, "S3cretX")) == 2, "echoed: #{inspect(out)}"
  end

  @tag verifies: "script-world-tty"
  test "a command handed the terminal has one", %{tmp_dir: dir} do
    out =
      under_pty(
        dir,
        ~S|Ctl.World.Real.cmd("sh", ["-c", "test -t 0 && test -t 1 && echo child-has-a-tty"], tty: true)|,
        ""
      )

    assert out =~ "child-has-a-tty"
  end

  @tag verifies: "script-world-secret-refuses"
  test "without a terminal the prompt refuses, rather than read an empty password", %{
    tmp_dir: dir
  } do
    file = Path.join(dir, "run.exs")

    File.write!(file, """
    Process.put(:ctl_no_main, true)
    Code.require_file(#{inspect(CtlFixture.path())})
    Ctl.World.Real.prompt_secret("Admin password: ")
    """)

    {out, status} =
      System.cmd("sh", ["-c", ~s|elixir "$0" </dev/null|, file], stderr_to_stdout: true)

    assert status == 1
    assert out =~ "Admin password: needs a terminal to ask without echoing"
  end

  @tag verifies: "script-world-real"
  test "write_local writes a file on the host", %{tmp_dir: dir} do
    path = Path.join(dir, "qr.png")
    file = Path.join(dir, "run.exs")

    File.write!(file, """
    Process.put(:ctl_no_main, true)
    Code.require_file(#{inspect(CtlFixture.path())})
    IO.inspect(Ctl.World.Real.write_local(#{inspect(path)}, <<137, 80, 78, 71>>))
    """)

    assert {":ok\n", 0} = System.cmd("elixir", [file], stderr_to_stdout: true)
    assert File.read!(path) == <<137, 80, 78, 71>>
  end
end
