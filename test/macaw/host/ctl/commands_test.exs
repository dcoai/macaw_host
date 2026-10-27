defmodule Macaw.Host.Ctl.CommandsTest do
  @moduledoc """
  The generated sample script's commands through `Ctl.dispatch/3`, as
  `main/1` runs them, with `Macaw.Host.Ctl.Recorder` as `Ctl.World`: the
  exact docker argv of each, where secrets travel, and what is printed.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Macaw.Host.Ctl.Recorder

  @moduletag :tmp_dir

  @ref "registry.example/acme/sample:latest"
  @eval ["/app/bin/sample", "eval", "Sample.Release.config()"]

  @daemon_up {["docker", "info"], {"ok", 0}}
  @image_present {["docker", "image", "inspect"], {"sha256:img\n", 0}}
  @owned {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "chown"], {"", 0}}
  @running {["docker", "container", "inspect", "sample"],
            {~s([{"State":{"Running":true,"StartedAt":"2026-10-26T10:00:00Z"},"Config":{"Image":"#{@ref}"}}]),
             0}}

  setup %{tmp_dir: tmp_dir} do
    {script, home} = Recorder.home!(tmp_dir, "sample-ctl")
    %{script: script, home: home, data: Path.join(home, "data")}
  end

  defp run(script, argv, sys_env \\ %{}) do
    with_io(fn -> Ctl.dispatch(argv, sys_env, script) end)
  end

  defp eval_calls do
    for {"docker", ["run", "--rm", "--user", "2060:2060" | _] = argv, opts} <- Recorder.calls(),
        do: {argv, opts}
  end

  describe "start" do
    test "recreates the container with the ulimit, its name, the port and the data volume",
         %{script: script, data: data} do
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        @running,
        {["docker", "rm", "-f", "sample"], {"", 0}},
        {["docker", "run", "-d"], {"id\n", 0}}
      ])

      assert {:ok, out} = run(script, ["start"])
      assert out =~ "sample is running"

      run_argv =
        ["run", "-d", "--name", "sample", "--ulimit", "nofile=65536:65536"] ++
          ["--network", "bridge", "-p", "4000:4000", "-v", "#{data}:/data"] ++
          ["-p", "4001:4001", "--restart", "unless-stopped", @ref]

      assert Recorder.docker_calls() == [
               ["info"],
               ["image", "inspect", @ref],
               ["run", "--rm", "--user", "0:0", "--entrypoint", "chown"] ++
                 ["-v", "#{data}:/data", @ref, "2060:2060", "/data"],
               ["container", "inspect", "sample"],
               ["rm", "-f", "sample"],
               run_argv,
               ["container", "inspect", "sample"]
             ]

      assert {:sleep, 2000} in Recorder.calls()
    end

    test "on the host's network, the app listens on PORT itself", %{script: script} do
      Recorder.install([@daemon_up, @image_present, @owned, {["docker", "run", "-d"], {"", 0}}])

      run(script, ["start"], %{"NETWORK" => "host", "PORT" => "8080"})

      [argv] = for ["run", "-d" | _] = argv <- Recorder.docker_calls(), do: argv
      assert ["--network", "host", "-e", "PORT=8080", "-v" | _] = Enum.drop(argv, 6)
      refute "-p" in Enum.take(argv, 12)
    end

    test "a container that does not stay up shows its last words", %{script: script} do
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "-d"], {"", 0}},
        {["docker", "logs", "--tail", "30", "sample"], {"boom\n", 0}}
      ])

      assert {{:error, "sample did not stay up"}, out} = run(script, ["start"])
      assert out =~ "boom"
    end
  end

  test "stop stops with a grace period and removes the container", %{script: script} do
    Recorder.install([@daemon_up, @running, {["docker"], {"", 0}}])

    assert {:ok, out} = run(script, ["stop"])
    assert out =~ "its data is untouched"

    assert Recorder.docker_calls() == [
             ["info"],
             ["container", "inspect", "sample"],
             ["stop", "-t", "30", "sample"],
             ["rm", "-f", "sample"]
           ]
  end

  test "status reports the container and asks the running app for its report",
       %{script: script, home: home} do
    report = ~s({"healthy":true,"version":"1.2.0","checks":{"database":"ok"}})

    Recorder.install([
      @daemon_up,
      @running,
      @image_present,
      {["docker", "exec", "sample"], {"a warning\n" <> report <> "\n", 0}}
    ])

    assert {:ok, out} = run(script, ["status"])

    assert List.last(Recorder.docker_calls()) ==
             ["exec", "sample", "/app/bin/sample", "rpc", "Sample.Release.status()"]

    assert out =~ "state:    running"
    assert out =~ "home:     #{home}"
    assert out =~ "health:   healthy"
    assert out =~ "version:  1.2.0"
    assert out =~ ~r/checks:\n  database:\s+ok/
  end

  describe "config" do
    test "set runs the release in a throwaway container; its words travel by name only",
         %{script: script, data: data} do
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"],
         {~s({"ok":true,"set":"tz","restart":"restart to apply"}\n), 0}}
      ])

      assert {:ok, out} = run(script, ["config", "set", "tz", ~s("Europe/Oslo")])

      assert [{argv, opts}] = eval_calls()

      assert argv ==
               ["run", "--rm", "--user", "2060:2060", "-v", "#{data}:/data"] ++
                 ["-e", "SAMPLE_CTL_ARGS", @ref | @eval]

      assert opts[:env] == [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
      refute Enum.any?(argv, &(&1 =~ "Oslo"))

      assert out =~ "set tz"
      assert out =~ "Sample's configuration updated — ./sample-ctl restart to apply"
    end

    test "list prints each setting and its source", %{script: script} do
      listing =
        ~s({"name":"tz","value":"\\"Etc/UTC\\"","source":"default"}\n) <>
          ~s|{"name":"smtp_password","value":"set (…tery)","source":"config.exs"}\n|

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {listing, 0}}
      ])

      assert {:ok, out} = run(script, ["config", "list"])
      assert out =~ ~r/^tz="Etc\/UTC"\s+\(default\)$/m
      assert out =~ ~r/^smtp_password=set \(…tery\)\s+\(config\.exs\)$/m
      assert [{_, opts}] = eval_calls()
      assert opts[:env] == [{"SAMPLE_CTL_ARGS", ~s(["list"])}]
    end

    test "a value that doesn't fit its type is shown as invalid, with the fault",
         %{script: script} do
      listing =
        ~s({"name":"port","value":"\\"eighty\\"","source":"env SAMPLE_PORT",) <>
          ~s|"fault":"SAMPLE_PORT: must be a port number (1–65535)"}\n|

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {listing, 0}}
      ])

      assert {:ok, out} = run(script, ["config", "list"])

      assert out =~
               ~r/^port="eighty"\s+\(env SAMPLE_PORT\) INVALID: SAMPLE_PORT: must be a port number/m
    end

    test "the release's failure passes its status on", %{script: script} do
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {"", 1}}
      ])

      assert {{:halt, 1}, _} = run(script, ["config", "get", "nope"])
    end
  end

  test "logs -n 50 prints the last 50 lines", %{script: script} do
    Recorder.install([@daemon_up, @running, {["docker", "logs"], {"a line\n", 0}}])

    assert {:ok, out} = run(script, ["logs", "-n", "50"])
    assert out == "a line\n"

    assert Recorder.docker_calls() == [
             ["info"],
             ["container", "inspect", "sample"],
             ["logs", "--tail", "50", "sample"]
           ]

    assert {{:error, "usage: ./sample-ctl logs [-n N]"}, _} = run(script, ["logs", "-n", "x"])
  end

  describe "the app's own commands" do
    test "ping asks the running app through rpc", %{script: script} do
      Recorder.install([@daemon_up, @running, {["docker", "exec"], {"pong\n", 0}}])

      assert {:ok, "pong\n"} = run(script, ["ping"])

      assert List.last(Recorder.docker_calls()) ==
               ["exec", "sample", "/app/bin/sample", "rpc", "Sample.Release.ping()"]
    end

    test "reset-password sends the password by name, never in the argv",
         %{script: script, data: data} do
      Recorder.install(
        [
          @daemon_up,
          @image_present,
          @owned,
          {["docker", "run", "--rm", "--user", "2060:2060"], {"", 0}}
        ],
        answer: "correct-horse"
      )

      assert {:ok, _} = run(script, ["reset-password", "alice"])

      assert [{argv, opts}] = eval_calls()

      assert argv ==
               ["run", "--rm", "--user", "2060:2060", "-v", "#{data}:/data"] ++
                 ["-e", "SAMPLE_CTL_ARGS", "-e", "SAMPLE_CTL_PASSWORD", @ref] ++
                 ["/app/bin/sample", "eval", "Sample.Release.reset_password()"]

      assert opts[:env] == [
               {"SAMPLE_CTL_ARGS", ~s(["alice"])},
               {"SAMPLE_CTL_PASSWORD", "correct-horse"}
             ]

      refute Enum.any?(argv, &(&1 =~ "horse"))
      assert {:prompt_secret, "New password for alice: "} in Recorder.calls()
    end

    test "need the data directory", %{tmp_dir: tmp_dir} do
      script = Recorder.script!(Path.join(tmp_dir, "bare-ctl"))
      Recorder.install()

      assert {{:error, "no data directory yet — ./sample-ctl init [DIR]"}, _} =
               run(script, ["ping"])

      assert Recorder.calls() == []
    end
  end

  describe "env" do
    test "list masks secrets unless --reveal", %{script: script, home: home} do
      File.write!(Path.join(home, "sample.conf"), "PORT=8080\nREGISTRY_TOKEN=abcdefghijkl1234\n")
      Recorder.install()

      assert {:ok, out} = run(script, ["env", "list"])
      assert out =~ ~r/^PORT=8080\s+\(file\)$/m
      assert out =~ ~r/^ADMIN_PORT=4001\s+\(default\)$/m
      assert out =~ ~r/^REGISTRY_TOKEN=set \(…1234\)\s+\(file, unknown to sample-ctl\)$/m
      refute out =~ "abcdefghijkl"

      assert {:ok, revealed} = run(script, ["env", "list", "--reveal"])
      assert revealed =~ "REGISTRY_TOKEN=abcdefghijkl1234"
    end

    test "set edits the file in place and says to restart", %{script: script, home: home} do
      conf = Path.join(home, "sample.conf")
      File.write!(conf, "# mine\nPORT=8080\n")
      Recorder.install()

      assert {:ok, out} = run(script, ["env", "set", "PORT=9090", "ADMIN_PORT=9091"])
      assert File.read!(conf) == "# mine\nPORT=9090\nADMIN_PORT=9091\n"
      assert out =~ "./sample-ctl restart to apply"

      assert {{:error,
               "PHX_HOST is Sample's own configuration now: ./sample-ctl config set phx_host VALUE"},
              _} = run(script, ["env", "set", "PHX_HOST=x"])
    end

    test "unset takes a setting name, matched as written, never a pattern",
         %{script: script, home: home} do
      conf = Path.join(home, "sample.conf")
      File.write!(conf, "# mine\nPORT=8080\nNAME=x\nPORTS=1\n")
      Recorder.install()

      for key <- [".*", "P.RT", "port", "PORT=", "1PORT", ""] do
        assert {{:error, message}, _} = run(script, ["env", "unset", key])
        assert message =~ "is not a valid setting name"
        assert File.read!(conf) == "# mine\nPORT=8080\nNAME=x\nPORTS=1\n"
      end

      assert {:ok, out} = run(script, ["env", "unset", "PORT"])
      assert out =~ "unset PORT"
      assert File.read!(conf) == "# mine\nNAME=x\nPORTS=1\n"
    end
  end

  describe "init" do
    test "creates the data directory, names it in the script, seeds the app's config",
         %{tmp_dir: tmp_dir} do
      script = Recorder.script!(Path.join(tmp_dir, "sample-ctl"))
      home = Path.join(tmp_dir, "new-home")

      listing =
        ~s({"name":"phx_host","value":"nil","source":"default"}\n) <>
          ~s({"name":"phx_scheme","value":"\\"https\\"","source":"config.exs"}\n) <>
          ~s({"name":"tz","value":"\\"Etc/UTC\\"","source":"default"}\n)

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {listing, 0}},
        {["hostname", "-f"], {"pbx.lan\n", 0}},
        {["timedatectl"], {"Europe/Oslo\n", 0}}
      ])

      assert {:ok, out} = run(script, ["init", home])
      assert out =~ "#{script} now uses #{home}"
      assert out =~ "ready: ./sample-ctl start"

      assert {:ok, ^home} = Ctl.Script.data_dir(File.read!(script))
      assert File.dir?(Path.join(home, "data"))

      conf = File.read!(Path.join(home, "sample.conf"))
      assert conf =~ "# Host settings for sample-ctl"
      assert conf =~ "\nPORT=4000\n"
      assert conf =~ "# The admin console's port.\nADMIN_PORT=4001\n"

      args = for {_argv, opts} <- eval_calls(), do: opts[:env]

      # phx_scheme is already set, so only the two at their default are seeded.
      assert args == [
               [{"SAMPLE_CTL_ARGS", ~s(["list"])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","phx_host","\\"pbx.lan\\""])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
             ]
    end

    test "refuses to move an existing data directory without --force", %{
      script: script,
      home: home
    } do
      Recorder.install()

      assert {{:error, message}, _} = run(script, ["init", "/elsewhere"])

      assert message ==
               "this sample-ctl already uses #{home} — ./sample-ctl init --force DIR to point it elsewhere"
    end
  end
end
