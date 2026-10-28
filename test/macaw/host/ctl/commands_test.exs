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

  describe "an app command's helpers" do
    @tag verifies: "gen-app-last-object"
    test "last_object/1 is the last JSON object, past log lines" do
      out = ~s(12:00:00 [warning] noise\n{"first":1}\nnot json\n{"second":2}\n)
      assert Ctl.Commands.last_object(out) == %{"second" => 2}
      assert Ctl.Commands.last_object("only logs\n") == nil
    end
  end

  describe "start" do
    @tag verifies: "cmd-start"
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

    @tag verifies: "script-docker-start"
    test "on a bridge network, the run argv publishes the port and mounts the data volume",
         %{script: script, data: data} do
      Recorder.install([@daemon_up, @image_present, @owned, {["docker", "run", "-d"], {"", 0}}])

      run(script, ["start"])

      assert [argv] = for(["run", "-d" | _] = argv <- Recorder.docker_calls(), do: argv)

      assert argv ==
               ["run", "-d", "--name", "sample", "--ulimit", "nofile=65536:65536"] ++
                 ["--network", "bridge", "-p", "4000:4000", "-v", "#{data}:/data"] ++
                 ["-p", "4001:4001", "--restart", "unless-stopped", @ref]
    end

    @tag verifies: "script-docker-host"
    test "on the host's network, the app listens on PORT itself", %{script: script} do
      Recorder.install([@daemon_up, @image_present, @owned, {["docker", "run", "-d"], {"", 0}}])

      run(script, ["start"], %{"NETWORK" => "host", "PORT" => "8080"})

      [argv] = for ["run", "-d" | _] = argv <- Recorder.docker_calls(), do: argv
      assert ["--network", "host", "-e", "PORT=8080", "-v" | _] = Enum.drop(argv, 6)
      refute "-p" in Enum.take(argv, 12)
    end

    @tag verifies: "cmd-start-last-words"
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

  @tag verifies: "cmd-stop"
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

  @tag verifies: "cmd-status"
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
    @set_answer {["docker", "run", "--rm", "--user", "2060:2060"],
                 {~s({"ok":true,"set":"tz","restart":"restart to apply"}\n), 0}}

    @tag verifies: "script-docker-by-name"
    test "the eval argv names the words; their value travels in docker's environment",
         %{script: script, data: data} do
      Recorder.install([@daemon_up, @image_present, @owned, @set_answer])

      run(script, ["config", "set", "tz", ~s("Europe/Oslo")])

      assert [{argv, opts}] = eval_calls()

      assert argv ==
               ["run", "--rm", "--user", "2060:2060", "-v", "#{data}:/data"] ++
                 ["-e", "SAMPLE_CTL_ARGS", @ref | @eval]

      refute Enum.any?(argv, &(&1 =~ "Oslo"))
      assert opts[:env] == [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
    end

    @tag verifies: "cmd-config-set"
    test "set runs the release in a throwaway container; its words travel by name only",
         %{script: script} do
      Recorder.install([@daemon_up, @image_present, @owned, @set_answer])

      assert {:ok, out} = run(script, ["config", "set", "tz", ~s("Europe/Oslo")])

      assert [{argv, opts}] = eval_calls()
      assert ["-e", "SAMPLE_CTL_ARGS"] == Enum.slice(argv, 6, 2)
      assert opts[:env] == [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
      refute Enum.any?(argv, &(&1 =~ "Europe/Oslo"))

      assert out =~ "set tz"
      assert out =~ "Sample's configuration updated — ./sample-ctl restart to apply"
    end

    @tag verifies: "cmd-config-set-file"
    test "set KEY @FILE reads the value on the host; it travels in the env, never in argv",
         %{script: script, tmp_dir: tmp_dir} do
      file = Path.join(tmp_dir, "auth.exs")
      block = ~s(%{sources: [%{name: "nas", bind_password: "correct-horse-battery-staple"}]})

      Recorder.install([@daemon_up, @image_present, @owned, @set_answer],
        files: %{file => block <> "\n\n"}
      )

      assert {:ok, out} = run(script, ["config", "set", "tz", "@" <> file])

      assert {:read_local, ^file} = Enum.find(Recorder.calls(), &match?({:read_local, _}, &1))
      assert [{argv, opts}] = eval_calls()
      refute Enum.any?(argv, &(&1 =~ "correct-horse" or &1 =~ file))
      assert opts[:env] == [{"SAMPLE_CTL_ARGS", JSON.encode!(["set", "tz", block])}]
      assert out =~ "Sample's configuration updated"
    end

    @tag verifies: "cmd-config-set-file-missing"
    test "set KEY @FILE of a file that can't be read is one error, and nothing runs",
         %{script: script} do
      Recorder.install([@daemon_up, @image_present, @owned, @set_answer])

      assert {{:error, message}, _} = run(script, ["config", "set", "tz", "@/nowhere/auth.exs"])

      assert message ==
               ~s(cannot read "/nowhere/auth.exs" for config set tz: no such file or directory)

      assert eval_calls() == []
    end

    @tag verifies: "cmd-config-get-block"
    test "get of a map or a list prints it on several lines, formatted; a scalar stays on one",
         %{script: script} do
      answer =
        ~s|{"name":"auth","value":"%{sources: [%{name: \\"nas\\", bind_password: \\"set (…aple)\\"}, %{type: :local}]}","source":"config.exs","fault":"auth: must be a sign-in block"}\n|

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {answer, 0}}
      ])

      assert {:ok, out} = run(script, ["config", "get", "auth"])

      lines =
        out |> String.split("\n", trim: true) |> Enum.drop_while(&(&1 != "auth (config.exs):"))

      assert hd(lines) == "auth (config.exs):"
      assert "  %{" in lines

      assert Enum.any?(
               lines,
               &(&1 =~ ~r/^      %\{name: "nas", bind_password: "set \(…aple\)"\},?$/)
             )

      assert List.last(lines) == "INVALID: auth: must be a sign-in block"

      scalar = ~s({"name":"tz","value":"\\"Etc/UTC\\"","source":"default"}\n)

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {scalar, 0}}
      ])

      assert {:ok, out} = run(script, ["config", "get", "tz"])
      assert out =~ ~r/^tz="Etc\/UTC"\s+\(default\)$/m
    end

    @tag verifies: "cmd-config-list"
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

    @tag verifies: "cmd-config-invalid"
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

    @tag verifies: "cmd-config-failure"
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

  @tag verifies: "cmd-logs"
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
    @tag verifies: "script-app-dispatch"
    test "ping asks the running app through rpc", %{script: script} do
      Recorder.install([@daemon_up, @running, {["docker", "exec"], {"pong\n", 0}}])

      assert {:ok, "pong\n"} = run(script, ["ping"])

      assert List.last(Recorder.docker_calls()) ==
               ["exec", "sample", "/app/bin/sample", "rpc", "Sample.Release.ping()"]
    end

    @tag verifies: "gen-app-commands-secret"
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

    @tag verifies: "script-app-needs-home"
    test "need the data directory", %{tmp_dir: tmp_dir} do
      script = Recorder.script!(Path.join(tmp_dir, "bare-ctl"))
      Recorder.install()

      assert {{:error, "no data directory yet — ./sample-ctl init [DIR]"}, _} =
               run(script, ["ping"])

      assert Recorder.calls() == []
    end
  end

  describe "env" do
    @tag verifies: "cmd-env-list"
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

    @tag verifies: "cmd-env-set"
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

    @tag verifies: "cmd-env-unset"
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

    @tag verifies: "script-secret"
    test "a secret is masked on output unless --reveal; a URL shows no password",
         %{script: script, home: home} do
      File.write!(Path.join(home, "sample.conf"), "REGISTRY_TOKEN=abcdefghijkl1234\n")
      Recorder.install()

      assert {:ok, out} = run(script, ["env", "list"])
      assert out =~ "REGISTRY_TOKEN=set (…1234)"
      refute out =~ "abcdefghijkl"

      assert {:ok, revealed} = run(script, ["env", "list", "--reveal"])
      assert revealed =~ "REGISTRY_TOKEN=abcdefghijkl1234"

      assert Ctl.Secret.mask_url("postgres://app:pw@db/app") == "postgres://app:****@db/app"
    end

    @tag verifies: "script-env-sources"
    test "each setting resolves from the environment, then the file, then the default",
         %{script: script, home: home} do
      File.write!(Path.join(home, "sample.conf"), "PORT=8080\n")
      Recorder.install()

      assert {:ok, out} = run(script, ["env", "list"])
      assert out =~ ~r/^PORT=8080\s+\(file\)$/m
      assert out =~ ~r/^ADMIN_PORT=4001\s+\(default\)$/m

      Recorder.install([@daemon_up, @image_present, @owned, {["docker", "run", "-d"], {"", 0}}])

      run(script, ["start"], %{"NETWORK" => "host", "PORT" => "8080"})

      assert [argv] = for(["run", "-d" | _] = argv <- Recorder.docker_calls(), do: argv)
      assert ["--network", "host", "-e", "PORT=8080"] == Enum.slice(argv, 6, 4)
    end

    @tag verifies: "script-env-validate"
    test "values are validated before anything is written or run", %{script: script, home: home} do
      conf = Path.join(home, "sample.conf")
      File.write!(conf, "PORT=8080\n")
      Recorder.install()

      assert {{:error, "PORT must be a port number (1–65535), not \"70000\""}, _} =
               run(script, ["env", "set", "PORT=70000"])

      assert File.read!(conf) == "PORT=8080\n"

      Recorder.install([@daemon_up, @image_present, @owned, {["docker"], {"", 0}}])

      assert {{:error, "NAME must be a valid container name (letters, digits, _ . -)"}, _} =
               run(script, ["start"], %{"NAME" => "bad name"})

      assert Recorder.calls() == []
    end
  end

  describe "init" do
    @listing ~s({"name":"phx_host","value":"nil","source":"default"}\n) <>
               ~s({"name":"phx_scheme","value":"\\"https\\"","source":"config.exs"}\n) <>
               ~s({"name":"tz","value":"\\"Etc/UTC\\"","source":"default"}\n)

    defp install_for_init do
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {@listing, 0}},
        {["hostname", "-f"], {"pbx.lan\n", 0}},
        {["timedatectl"], {"Europe/Oslo\n", 0}}
      ])
    end

    @tag verifies: "cmd-init"
    test "creates the data directory, names it in the script, writes the settings",
         %{tmp_dir: tmp_dir} do
      script = Recorder.script!(Path.join(tmp_dir, "sample-ctl"))
      home = Path.join(tmp_dir, "new-home")
      install_for_init()

      assert {:ok, out} = run(script, ["init", home])
      assert out =~ "#{script} now uses #{home}"
      assert out =~ "ready: ./sample-ctl start"

      assert {:ok, ^home} = Ctl.Script.data_dir(File.read!(script))
      assert File.dir?(Path.join(home, "data"))

      conf = File.read!(Path.join(home, "sample.conf"))
      assert String.starts_with?(conf, "# Host settings for sample-ctl")
      assert conf =~ "\nPORT=4000\n"
      assert conf =~ "# The admin console's port.\nADMIN_PORT=4001\n"
    end

    @tag verifies: "cmd-init-seed"
    test "seeds the app's config with this host's values, leaving what is set alone",
         %{tmp_dir: tmp_dir} do
      script = Recorder.script!(Path.join(tmp_dir, "sample-ctl"))
      home = Path.join(tmp_dir, "new-home")
      install_for_init()

      assert {:ok, _} = run(script, ["init", home])

      # phx_scheme is already set, so only the two at their default are seeded.
      assert [
               [{"SAMPLE_CTL_ARGS", ~s(["list"])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","phx_host","\\"pbx.lan\\""])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
             ] = for({_argv, opts} <- eval_calls(), do: opts[:env])

      # Each by name: the values are in docker's environment, never in the argv.
      for {argv, _opts} <- eval_calls() do
        assert ["-e", "SAMPLE_CTL_ARGS"] == Enum.slice(argv, 6, 2)
        refute Enum.any?(argv, &(&1 =~ "pbx.lan" or &1 =~ "Europe/Oslo"))
      end
    end

    @tag verifies: "cmd-init-force"
    test "refuses to move an existing data directory without --force", %{
      script: script,
      home: home
    } do
      Recorder.install()

      assert {{:error, message}, _} = run(script, ["init", "/elsewhere"])

      assert message ==
               "this sample-ctl already uses #{home} — ./sample-ctl init --force DIR to point it elsewhere"

      assert Recorder.calls() == []
    end
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 08" do
    @common ~w(init env config start stop restart update status logs shell)

    @tag verifies: "host-cmd"
    test "the common commands are every script's, each a Ctl.Commands function", %{
      script: script
    } do
      Recorder.install()
      {:ok, help} = run(script, ["help"])

      for command <- @common do
        assert help =~ "./sample-ctl #{command}"
        assert function_exported?(Ctl.Commands, String.to_existing_atom(command), 2)
      end
    end

    @tag verifies: "host-cmd-common"
    test "the data directory, restart to apply, and the helpers an app's commands use",
         %{tmp_dir: tmp_dir, script: script, home: home} do
      bare = Recorder.script!(Path.join(tmp_dir, "bare-ctl"))
      Recorder.install()

      for command <- @common -- ["init", "stop"] do
        assert {{:error, "no data directory yet — ./sample-ctl init [DIR]"}, _} =
                 run(bare, [command])
      end

      # stop needs none.
      Recorder.install([@daemon_up])
      assert {:ok, out} = run(bare, ["stop"])
      assert out =~ "sample is not there"

      # An older setup beside the script is told to migrate.
      older = Path.join(tmp_dir, "older")
      File.mkdir_p!(older)
      File.write!(Path.join(older, "sample-env"), "PORT=8080\n")
      older_script = Recorder.script!(Path.join(older, "sample-ctl"))

      assert {{:error,
               "this sample-ctl keeps its settings in a data directory now: ./sample-ctl init --migrate [DIR]"},
              _} = run(older_script, ["status"])

      # Every edit ends with "restart to apply".
      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {~s({"unset":"tz"}\n), 0}}
      ])

      assert {:ok, out} = run(script, ["env", "set", "PORT=1"])
      assert out =~ "restart to apply"
      assert {:ok, out} = run(script, ["env", "unset", "PORT"])
      assert out =~ "restart to apply"
      assert {:ok, out} = run(script, ["config", "unset", "tz"])
      assert out =~ "restart to apply"

      # The helpers.
      {:ok, env} = Ctl.Env.load(script, %{})
      assert Ctl.Commands.require_home(env) == :ok

      Recorder.install([
        @daemon_up,
        {["docker", "image", "inspect"], {"", 1}},
        {["docker", "pull"], {"", 0}},
        @owned
      ])

      assert {:ok, out} = with_io(fn -> Ctl.Commands.ensure_ready(env) end)
      assert ["pull", @ref] in Recorder.docker_calls()
      assert out =~ "making #{Path.join(home, "data")} the container user's (2060:2060)"

      Recorder.install([@daemon_up])

      assert Ctl.Commands.ensure_running(env) ==
               {:error, "sample is not running — ./sample-ctl start"}

      Recorder.install([{["docker", "ps"], {"listed\n", 4}}])
      assert {{:halt, 4}, "listed\n"} = with_io(fn -> Ctl.Commands.stream(["ps"]) end)
      assert Ctl.Commands.interactive(["exec", "-it", "sample", "sh"]) == {:halt, 1}

      assert {"docker", ["exec", "-it", "sample", "sh"], [tty: true]} =
               List.last(Recorder.calls())

      assert Ctl.Commands.exit_status({"", 0}) == :ok

      assert Ctl.Commands.decode_lines(~s({"a":1}\n{"b":2}\n)) ==
               {:ok, [%{"a" => 1}, %{"b" => 2}]}

      assert Ctl.Commands.decode_lines("[1]\n") ==
               {:error, "Sample.Release answered with a line that is not a JSON object: [1]"}
    end

    @tag verifies: "host-cmd-init"
    test "init's refusals, its question, a directory it can't create, and the files it writes",
         %{tmp_dir: tmp_dir, script: script, home: home} do
      bare = Recorder.script!(Path.join(tmp_dir, "bare-ctl"))
      Recorder.install()

      assert {{:error, "usage: ./sample-ctl init [DIR] [--force] [--migrate]"}, _} =
               run(bare, ["init", "--frob"])

      assert {{:error, "usage: ./sample-ctl init [DIR] [--force] [--migrate]"}, _} =
               run(bare, ["init", "a", "b"])

      # A directory it can't create (a path under a regular file, for root too).
      File.write!(Path.join(tmp_dir, "a_file"), "")
      blocked = Path.join([tmp_dir, "a_file", "home"])
      assert {{:error, message}, _} = run(bare, ["init", blocked])
      assert message =~ "cannot create #{blocked}"
      assert message =~ ~s(sudo install -d -o "$USER" #{blocked})
      assert {:ok, nil} = Ctl.Script.data_dir(File.read!(bare))

      # Asked for, the answer taken.
      answered = Path.join(tmp_dir, "answered")

      Recorder.install(
        [
          @daemon_up,
          @image_present,
          @owned,
          {["docker", "run", "--rm", "--user", "2060:2060"], {"", 0}}
        ],
        answer: answered
      )

      assert {:ok, _} = run(bare, ["init"])

      assert {:prompt, "Where should this host keep Sample's data? [/srv/sample] "} in Recorder.calls()

      assert {:ok, ^answered} = Ctl.Script.data_dir(File.read!(bare))
      assert Bitwise.band(File.stat!(bare).mode, 0o777) == 0o755
      assert Bitwise.band(File.stat!(Path.join(answered, "sample.conf")).mode, 0o777) == 0o600

      # --force points it elsewhere, keeping a settings file that is there.
      elsewhere = Path.join(tmp_dir, "elsewhere")
      File.mkdir_p!(elsewhere)
      File.write!(Path.join(elsewhere, "sample.conf"), "# mine\nPORT=8080\n")

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {"", 0}}
      ])

      assert {:ok, out} = run(script, ["init", "--force", elsewhere])
      assert out =~ "keeping #{Path.join(elsewhere, "sample.conf")}"
      assert File.read!(Path.join(elsewhere, "sample.conf")) == "# mine\nPORT=8080\n"
      assert {:ok, ^elsewhere} = Ctl.Script.data_dir(File.read!(script))
      refute home == elsewhere

      # An empty answer takes the description's data home (a script of its own).
      own_home = Path.join(tmp_dir, "own-home")

      description =
        CtlFixture.description()
        |> Keyword.drop([:seeds, :migrate_keys])
        |> Keyword.put(:data_home, own_home)

      generated = Path.join(tmp_dir, "own-ctl")
      File.write!(generated, Macaw.Host.Ctl.generate(description, nil))
      {out, 0} = System.cmd("sh", ["-c", ~s(elixir "$0" init </dev/null 2>&1), generated])
      assert out =~ "[#{own_home}]"
      assert out =~ "#{generated} now uses #{own_home}"
      # No seeds: ready at once, no docker asked.
      assert out =~ "ready: ./sample-ctl start"
      assert File.dir?(Path.join(own_home, "data"))
    end

    @tag verifies: "host-cmd-seed"
    test "a failed set stops the seeding there", %{tmp_dir: tmp_dir} do
      bare = Recorder.script!(Path.join(tmp_dir, "bare-ctl"))

      listing =
        ~s({"name":"phx_host","value":"nil","source":"default"}\n) <>
          ~s({"name":"tz","value":"nil","source":"default"}\n)

      # The first eval (config list) answers the listing; the next (a set) fails.
      first_eval = fn
        "docker", ["run", "--rm", "--user", "2060:2060" | _] ->
          Process.put(:first_eval, false) != false

        _, _ ->
          false
      end

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {first_eval, {listing, 0}},
        {["docker", "run", "--rm", "--user", "2060:2060"], {"", 1}},
        {["hostname", "-f"], {"pbx.lan\n", 0}}
      ])

      assert {{:halt, 1}, out} = run(bare, ["init", Path.join(tmp_dir, "seeded")])
      refute out =~ "ready:"
      sets = for {_, opts} <- eval_calls(), do: opts[:env]

      assert [
               [{"SAMPLE_CTL_ARGS", ~s(["list"])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","phx_host","\\"pbx.lan\\""])}]
             ] = sets
    end

    @tag verifies: "host-cmd-migrate"
    test "migrate wants an empty data directory, keeps a settings file, takes a named volume, and says the old data stays",
         %{tmp_dir: tmp_dir} do
      dir = Path.join(tmp_dir, "m")
      File.mkdir_p!(dir)

      File.write!(
        Path.join(dir, "sample-env"),
        "PORT=8080\nDATA=sample_data\nTZ=Europe/Oslo\nPHX_HOST=h\n"
      )

      script = Recorder.script!(Path.join(dir, "sample-ctl"))
      home = Path.join(tmp_dir, "new-home")

      ok_answer =
        {["docker", "run", "--rm", "--user", "2060:2060"], {~s({"ok":true,"set":"x"}\n), 0}}

      # data/ already holding something is refused, before any copy.
      File.mkdir_p!(Path.join(home, "data"))
      File.write!(Path.join([home, "data", "x"]), "")
      Recorder.install([@daemon_up, @image_present, {["docker"], {"", 0}}])

      assert {{:error, message}, _} = run(script, ["init", "--migrate", home])

      assert message ==
               "#{Path.join(home, "data")} is not empty — migrate into a fresh data directory"

      refute Enum.any?(Recorder.docker_calls(), &match?(["run" | _], &1))

      # A named volume, and a settings file that is already there.
      File.rm!(Path.join([home, "data", "x"]))
      File.write!(Path.join(home, "sample.conf"), "# mine\nPORT=7070\n")

      Recorder.install([
        @daemon_up,
        @image_present,
        {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "sh"], {"", 0}},
        ok_answer,
        {["docker"], {"", 0}}
      ])

      assert {:ok, out} = run(script, ["init", "--migrate", home])

      [copy] =
        for ["run", "--rm", "--user", "0:0", "--entrypoint", "sh" | _] = a <-
              Recorder.docker_calls(),
            do: a

      assert "sample_data:/old:ro" in copy
      refute "-e" in copy
      assert File.read!(Path.join(home, "sample.conf")) == "# mine\nPORT=7070\n"
      assert out =~ "keeping #{Path.join(home, "sample.conf")}"
      assert out =~ "#{script} now uses #{home}"

      assert out =~
               "The old data at sample_data was copied, not moved: remove it once Sample runs."

      sets = for {_, opts} <- eval_calls(), do: opts[:env]

      assert sets == [
               [{"SAMPLE_CTL_ARGS", ~s(["set","phx_host","\\"h\\""])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
             ]
    end

    @tag verifies: "host-cmd-env"
    test "env get, the shapes set accepts, an unknown key flagged, a new file, unset of nothing, the usage",
         %{script: script, home: home} do
      conf = Path.join(home, "sample.conf")
      Recorder.install()

      # No file yet: set starts it as init would.
      assert {:ok, out} = run(script, ["env", "set", "CUSTOM=1"])
      assert out =~ "set CUSTOM (not a setting sample-ctl knows)"
      assert File.read!(conf) =~ "# Host settings for sample-ctl"
      assert File.read!(conf) =~ "\nCUSTOM=1\n"
      assert Bitwise.band(File.stat!(conf).mode, 0o777) == 0o600

      File.write!(conf, "API_TOKEN=abcdefghijkl1234\nCUSTOM=1\n")
      assert {:ok, "4000\n"} = run(script, ["env", "get", "PORT"])
      assert {:ok, "1\n"} = run(script, ["env", "get", "CUSTOM"])
      assert {:ok, "set (…1234)\n"} = run(script, ["env", "get", "API_TOKEN"])
      assert {:ok, "abcdefghijkl1234\n"} = run(script, ["env", "get", "API_TOKEN", "--reveal"])
      assert {{:error, message}, _} = run(script, ["env", "get", "NOPE"])
      assert message == "NOPE is not set in #{conf}"

      assert {{:error, "expected KEY=VALUE, got PORT\n" <> _}, _} =
               run(script, ["env", "set", "PORT"])

      assert {{:error, "1X is not a valid setting name (letters, digits and _)"}, _} =
               run(script, ["env", "set", "1X=1"])

      # Validated before anything is written: no pair of the set is written.
      assert {{:error, "PORT must be" <> _}, _} = run(script, ["env", "set", "A=1", "PORT=0"])
      assert File.read!(conf) == "API_TOKEN=abcdefghijkl1234\nCUSTOM=1\n"

      assert {:ok, "PORTX is not set in #{conf}; nothing to do\n"} ==
               run(script, ["env", "unset", "PORTX"])

      assert {{:error, "usage: ./sample-ctl env list" <> _}, _} = run(script, ["env", "frob"])
    end

    @tag verifies: "host-cmd-config"
    test "config prints each answer, passes words by name, and has no --reveal", %{script: script} do
      answer =
        ~s({"ok":true,"unset":"tz","restart":"restart to apply"}\n) <>
          ~s({"something":"else"}\n)

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "--rm", "--user", "2060:2060"], {answer, 0}}
      ])

      assert {:ok, out} = run(script, ["config", "unset", "tz"])
      assert out =~ "unset tz\n"
      assert out =~ ~s({"something":"else"}\n)
      assert out =~ "Sample's configuration updated — ./sample-ctl restart to apply"

      assert [{argv, [env: [{"SAMPLE_CTL_ARGS", ~s(["unset","tz"])}]]}] = eval_calls()
      refute Enum.any?(argv, &(&1 =~ "unset"))

      assert {{:error,
               "usage: ./sample-ctl config list | get KEY | set KEY VALUE | set KEY @FILE | unset KEY"},
              _} =
               run(script, ["config", "list", "--reveal"])

      assert {{:error, "usage: ./sample-ctl config" <> _}, _} = run(script, ["config"])
    end

    @tag verifies: "host-cmd-start"
    test "start pulls a missing image, names what to run by hand, and reports a failed run",
         %{script: script, data: data} do
      Recorder.install([
        @daemon_up,
        {["docker", "image", "inspect"], {"", 1}},
        {["docker", "pull"], {"", 0}},
        {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "chown"], {"denied", 1}}
      ])

      assert {{:error, message}, _} = run(script, ["start"])
      assert ["pull", @ref] in Recorder.docker_calls()
      assert message =~ "could not hand #{data} to the container user: denied"
      assert message =~ "sudo chown 2060:2060 #{data}"

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        {["docker", "run", "-d"], {"no such network\n", 125}}
      ])

      assert {{:error, "docker run failed: no such network"}, _} = run(script, ["start"])
      refute Enum.any?(Recorder.docker_calls(), &match?(["rm", "-f" | _], &1))

      Recorder.install([
        @daemon_up,
        @image_present,
        @owned,
        @running,
        {["docker", "rm"], {"", 0}},
        {["docker", "run", "-d"], {"", 0}}
      ])

      assert {:ok, out} = run(script, ["start"])
      assert ["rm", "-f", "sample"] in Recorder.docker_calls()
      assert out =~ "sample is running — ./sample-ctl status shows Sample's health once it is up"
    end

    @tag verifies: "host-cmd-stop"
    test "stop with no container says so; restart stops, then starts", %{script: script} do
      Recorder.install([@daemon_up])
      assert {:ok, "sample is not there\n"} = run(script, ["stop"])

      Recorder.install([@daemon_up, @image_present, @owned, @running, {["docker"], {"", 0}}])
      assert {:ok, _} = run(script, ["restart"])

      calls = Recorder.docker_calls()
      stop = Enum.find_index(calls, &(&1 == ["stop", "-t", "30", "sample"]))
      start = Enum.find_index(calls, &match?(["run", "-d" | _], &1))
      assert stop < start
    end

    @tag verifies: "host-cmd-update"
    test "update with no container syncs without a restart; a script it can't write is left, and it carries on",
         %{script: script, home: home} do
      fresh =
        String.replace(
          CtlFixture.script(),
          ~s|def stop_timeout, do: "30"|,
          ~s|def stop_timeout, do: "60"|
        )

      File.write!(script, Ctl.Script.put_data_dir(CtlFixture.script(), home))

      ids = fn
        "docker", ["image", "inspect", "-f" | _] ->
          Process.put(:ids, (Process.get(:ids) || 0) + 1) == nil

        _, _ ->
          false
      end

      Recorder.install([
        @daemon_up,
        {ids, {"sha256:old\n", 0}},
        {["docker", "image", "inspect", "-f"], {"sha256:new\n", 0}},
        {["docker", "pull"], {"", 0}},
        {["docker", "run", "--rm", @ref, "bin/ctl"], {fresh, 0}}
      ])

      assert {:ok, out} = run(script, ["update"])
      assert out =~ "pulled a new #{@ref}; sample is not there — ./sample-ctl start"
      assert out =~ "sample-ctl in #{@ref} differs from this one; updating it"
      assert File.read!(script) =~ ~s|def stop_timeout, do: "60"|
      refute Enum.any?(Recorder.calls(), &match?({^script, _, _}, &1))

      # A .bak that can't be written (a directory there): the script is left.
      File.write!(script, Ctl.Script.put_data_dir(CtlFixture.script(), home))
      File.rm!(script <> ".bak")
      File.mkdir_p!(script <> ".bak")
      current = File.read!(script)
      Process.delete(:ids)

      Recorder.install([
        @daemon_up,
        {ids, {"sha256:old\n", 0}},
        {["docker", "image", "inspect", "-f"], {"sha256:new\n", 0}},
        {["docker", "pull"], {"", 0}},
        @running,
        {["docker", "run", "--rm", @ref, "bin/ctl"], {fresh, 0}},
        @image_present,
        @owned,
        {["docker"], {"", 0}}
      ])

      assert {:ok, out} = run(script, ["update"])

      assert out =~
               "#{@ref} carries a newer sample-ctl, but #{script} is not writable — leaving it"

      assert out =~ "new image; recreating sample"
      assert File.read!(script) == current
      assert Enum.any?(Recorder.docker_calls(), &match?(["run", "-d" | _], &1))
    end

    @tag verifies: "host-cmd-status"
    test "status reports each state, the image wanted, the settings, and answers :ok whatever the health",
         %{script: script, home: home} do
      Recorder.install([@daemon_up, {["docker", "image", "inspect"], {"", 1}}])
      assert {:ok, out} = run(script, ["status"])
      assert out =~ "state:    not created"
      assert out =~ "wanted:   #{@ref} (not pulled)"
      assert out =~ "settings: #{Path.join(home, "sample.conf")} (none yet — defaults)"
      assert out =~ "data:     #{Path.join(home, "data")}"
      refute out =~ "image:"

      exited =
        {["docker", "container", "inspect", "sample"],
         {~s([{"State":{"Running":false,"Status":"exited"},"Config":{"Image":"x"}}]), 0}}

      Recorder.install([@daemon_up, exited, @image_present])
      assert {:ok, out} = run(script, ["status"])
      assert out =~ "state:    exited"
      assert out =~ "wanted:   #{@ref} (present locally)"

      stopped =
        {["docker", "container", "inspect", "sample"], {~s([{"Config":{"Image":"x"}}]), 0}}

      Recorder.install([@daemon_up, stopped, @image_present])
      assert {:ok, out} = run(script, ["status"])
      assert out =~ "state:    stopped"

      Recorder.install([@daemon_up, @running, @image_present, {["docker", "exec"], {"", 1}}])
      assert {:ok, out} = run(script, ["status"])
      assert out =~ "image:    #{@ref}"
      assert out =~ "started:  2026-10-26T10:00:00Z"
      assert out =~ "app:      not answering yet"

      report = ~s({"healthy":false,"build":"abc","checks":{"db":"error: down"}})

      Recorder.install([
        @daemon_up,
        @running,
        @image_present,
        {["docker", "exec"], {report <> "\n", 0}}
      ])

      assert {:ok, out} = run(script, ["status"])
      assert out =~ "health:   UNHEALTHY"
      assert out =~ ~r/build:\s+abc\nchecks:\n  db:\s+error: down/
    end

    @tag verifies: "host-cmd-logs"
    test "logs follows by default, takes N alone, wants a positive count and a container",
         %{script: script} do
      Recorder.install([@daemon_up, @running, {["docker", "logs"], {"", 0}}])
      assert {:ok, _} = run(script, ["logs"])
      assert List.last(Recorder.docker_calls()) == ["logs", "-f", "--tail", "100", "sample"]

      assert {:ok, _} = run(script, ["logs", "7"])
      assert List.last(Recorder.docker_calls()) == ["logs", "--tail", "7", "sample"]

      for bad <- [["-n", "0"], ["-n", "-3"], ["a", "b", "c"]] do
        assert {{:error, "usage: ./sample-ctl logs [-n N]"}, _} = run(script, ["logs" | bad])
      end

      Recorder.install([@daemon_up])
      assert {{:error, "sample is not there — start it first"}, _} = run(script, ["logs"])
    end
  end
end
