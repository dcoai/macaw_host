defmodule Macaw.Host.Ctl.RecorderTest do
  @moduledoc """
  `Macaw.Host.Ctl.Recorder` as an app's tests use it: installed as the
  generated script's `Ctl.World`, it records every call in the calling
  process and answers from its canned replies.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Macaw.Host.Ctl.Recorder

  @moduletag :tmp_dir

  @ref "registry.example/acme/sample:latest"

  @tag verifies: "gen-recorder"
  test "records a command's exact docker argv, answers what is unmatched with a no, per process",
       %{tmp_dir: tmp_dir} do
    {script, home} = Recorder.home!(tmp_dir, "sample-ctl")
    data = Path.join(home, "data")

    Recorder.install([
      {["docker", "info"], {"ok", 0}},
      {["docker", "image", "inspect"], {"sha256:img\n", 0}},
      {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "chown"], {"", 0}},
      {["docker", "container", "inspect", "sample"],
       {~s([{"State":{"Running":true},"Config":{"Image":"#{@ref}"}}]), 0}},
      {["docker", "rm", "-f", "sample"], {"", 0}},
      {["docker", "run", "-d"], {"id\n", 0}}
    ])

    with_io(fn -> Ctl.dispatch(["start"], %{}, script) end)

    assert Recorder.docker_calls() == [
             ["info"],
             ["image", "inspect", @ref],
             ["run", "--rm", "--user", "0:0", "--entrypoint", "chown"] ++
               ["-v", "#{data}:/data", @ref, "2060:2060", "/data"],
             ["container", "inspect", "sample"],
             ["rm", "-f", "sample"],
             ["run", "-d", "--name", "sample", "--ulimit", "nofile=65536:65536"] ++
               ["--network", "bridge", "-p", "4000:4000", "-v", "#{data}:/data"] ++
               ["-p", "4001:4001", "--restart", "unless-stopped", @ref],
             ["container", "inspect", "sample"]
           ]

    assert {:sleep, 2000} in Recorder.calls()

    # Nothing matches: a docker that says no.
    assert Ctl.World.cmd("docker", ["volume", "ls"]) == {"", 1}

    # Another process's calls are its own.
    before = Recorder.calls()

    Task.async(fn ->
      Recorder.install()
      Ctl.World.cmd("docker", ["ps"])
    end)
    |> Task.await()

    assert Recorder.calls() == before
    refute Enum.any?(Recorder.calls(), &match?({"docker", ["ps"], _}, &1))
  end

  @tag verifies: "host-gen-recorder"
  test "the recorder's parts: loading, matching, answering, recording, and the minimal scripts",
       %{tmp_dir: tmp_dir} do
    # load!/1: the modules without main/1; loading again is a no-op.
    assert :ok = Recorder.load!(CtlFixture.path())
    assert Process.get(:ctl_no_main) == nil

    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    code = """
    Macaw.Host.Ctl.Recorder.load!(#{inspect(CtlFixture.path())})
    IO.puts(Code.ensure_loaded?(Ctl.Commands))
    """

    assert {"true\n", 0} =
             System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code],
               stderr_to_stdout: true
             )

    # A matcher is a list the call starts with, or a function; the first match answers.
    Recorder.install(
      [
        {fn exe, args -> exe == "docker" and "ps" in args end, {"by function", 0}},
        {["docker", "ps"], {"by list", 0}},
        {["docker"], {"any docker", 0}}
      ],
      answer: "an answer",
      files: %{"/host/auth.exs" => "%{a: 1}"}
    )

    assert Ctl.World.cmd("docker", ["ps", "-a"]) == {"by function", 0}
    assert Ctl.World.cmd("docker", ["info"]) == {"any docker", 0}
    assert Ctl.World.cmd("hostname", []) == {"", 1}
    assert Ctl.World.cmd("docker", ["logs"], into: "") == {"any docker", 0}
    assert Ctl.World.prompt("Where? ") == "an answer"
    assert Ctl.World.prompt_secret("Password: ") == "an answer"
    Ctl.World.sleep(5)
    assert Ctl.World.read_local("/host/auth.exs") == {:ok, "%{a: 1}"}
    assert Ctl.World.read_local("/host/other.exs") == {:error, :enoent}

    assert Recorder.calls() == [
             {"docker", ["ps", "-a"], []},
             {"docker", ["info"], []},
             {"hostname", [], []},
             {"docker", ["logs"], [into: ""]},
             {:prompt, "Where? "},
             {:prompt_secret, "Password: "},
             {:sleep, 5},
             {:read_local, "/host/auth.exs"},
             {:read_local, "/host/other.exs"}
           ]

    assert Recorder.docker_calls() == [["ps", "-a"], ["info"], ["logs"]]

    # into: collects the output; prompts answer "" by default.
    Recorder.install([{["docker"], {"streamed", 0}}])
    assert Ctl.World.cmd("docker", ["logs"], into: []) == {["streamed"], 0}
    assert Ctl.World.prompt("Where? ") == ""

    # script!/2 names a data directory, or nil; home!/2 makes home/data and its script.
    script = Recorder.script!(Path.join(tmp_dir, "none-ctl"))
    assert {:ok, nil} = Ctl.Script.data_dir(File.read!(script))
    script = Recorder.script!(Path.join(tmp_dir, "some-ctl"), "/srv/x")
    assert {:ok, "/srv/x"} = Ctl.Script.data_dir(File.read!(script))

    assert {script, home} = Recorder.home!(tmp_dir, "sample-ctl")
    assert script == Path.join(tmp_dir, "sample-ctl")
    assert File.dir?(Path.join(home, "data"))
    assert {:ok, ^home} = Ctl.Script.data_dir(File.read!(script))
  end
end
