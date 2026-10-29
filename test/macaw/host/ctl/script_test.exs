defmodule Macaw.Host.Ctl.ScriptTest do
  @moduledoc """
  The generated sample script's modules called directly, below the
  commands: the settings file's parsing and in-place editing, and the real
  world's answer for a missing executable.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Macaw.Host.Ctl.Recorder

  describe "the settings file" do
    @tag verifies: "script-env-parse"
    test "parses KEY=value lines as a shell would, and names the first line that isn't one" do
      text = "export A=1\nB=\"x y\"\nC='q'\nD=v # note\n\n# c\n"

      assert {:ok, %{}, [{"A", "1"}, {"B", "x y"}, {"C", "q"}, {"D", "v"}]} =
               Ctl.Env.parse(text)

      assert {:error, "sample.conf line 1 is not KEY=value: nonsense"} =
               Ctl.Env.parse("nonsense")
    end

    @tag verifies: "script-env-edit"
    test "edits one line at a time, keeping every comment" do
      text =
        "# mine\nPORT=8080\n"
        |> Ctl.Env.edit_set("PORT", "9090")
        |> Ctl.Env.edit_set("ADMIN_PORT", "9091")

      assert text == "# mine\nPORT=9090\nADMIN_PORT=9091\n"

      assert Ctl.Env.edit_set("# TAG=x\n", "TAG", "1.2") == "TAG=1.2\n"

      assert Ctl.Env.edit_unset("# PORT=4000\nPORT=8080\n", "PORT") == {"# PORT=4000\n", 1}
    end
  end

  describe "the real world" do
    @tag verifies: "script-world-real"
    @tag :tmp_dir
    test "an executable not on PATH answers {\"\", 127}, never a raise; read_local answers as File.read",
         %{tmp_dir: dir} do
      assert Ctl.World.Real.cmd("macaw-host-no-such-executable", [], []) == {"", 127}

      path = Path.join(dir, "value.exs")
      File.write!(path, "%{a: 1}\n")
      assert Ctl.World.Real.read_local(path) == {:ok, "%{a: 1}\n"}
      assert Ctl.World.Real.read_local(Path.join(dir, "none")) == {:error, :enoent}
    end
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 07" do
    @moduletag :tmp_dir

    @ref "registry.example/acme/sample:latest"

    defp env!(tmp_dir, sys_env \\ %{}) do
      {script, _home} = Recorder.home!(tmp_dir, "sample-ctl")
      {:ok, env} = Ctl.Env.load(script, sys_env)
      env
    end

    @tag verifies: "host-script"
    test "one program: elixir runs it alone, with no Mix project and nothing else", %{
      tmp_dir: dir
    } do
      script = Path.join(dir, "sample-ctl")
      File.cp!(CtlFixture.path(), script)

      {out, 0} = System.cmd("elixir", [script, "help"], cd: dir, stderr_to_stdout: true)
      assert out =~ "sample-ctl — manage the Sample container on a deployment host."
      refute File.exists?(Path.join(dir, "mix.exs"))
    end

    @tag verifies: "host-script-structure"
    test "every failure is a value; only main/3 prints an error", %{tmp_dir: dir} do
      {script, _home} = Recorder.home!(dir, "sample-ctl")
      Recorder.install()

      err =
        capture_io(:stderr, fn ->
          assert {:error, "unknown command: frob" <> _} =
                   with_io(fn -> Ctl.dispatch(["frob"], %{}, script) end) |> elem(0)
        end)

      assert err == ""

      {status, err} = with_io(:stderr, fn -> Ctl.main(["frob"], %{}, script) end)
      assert status == 1
      assert err =~ "unknown command: frob"

      source = CtlFixture.script()
      refute source =~ ~r/^\s*(rescue|catch)\b/m
    end

    @tag verifies: "host-script-home"
    test "the line of host state is read from the text, inside Ctl.Home only" do
      assert Ctl.Home.data_dir() == nil

      text = CtlFixture.script()
      assert {:ok, nil} = Ctl.Script.data_dir(text)

      named = Ctl.Script.put_data_dir(text, "/srv/sample")
      assert {:ok, "/srv/sample"} = Ctl.Script.data_dir(named)
      assert named =~ "\n  @data_dir \"/srv/sample\"\n"

      changed =
        Enum.zip(String.split(text, "\n"), String.split(named, "\n"))
        |> Enum.reject(fn {a, b} -> a == b end)

      assert changed == [{"  @data_dir nil", "  @data_dir \"/srv/sample\""}]

      assert {:error, ~s(the @data_dir line is not nil or a string: "/a" <> "/b")} =
               Ctl.Script.data_dir(
                 String.replace(text, "  @data_dir nil", ~s(  @data_dir "/a" <> "/b"))
               )

      # Indented other than by two spaces, it is not the line.
      assert {:error, "this script has no @data_dir line in Ctl.Home"} =
               Ctl.Script.data_dir(String.replace(text, "  @data_dir nil", "    @data_dir nil"))

      lacking = String.replace(text, "  @data_dir nil\n", "")
      assert {:error, _} = Ctl.Script.splice(lacking, named)
      assert {:error, _} = Ctl.Script.splice(text, lacking)
      assert {:ok, ^named} = Ctl.Script.splice(text, named)
    end

    defmodule FakeWorld do
      def cmd(exe, args, opts) do
        send(self(), {:cmd, exe, args, opts})
        {"faked", 0}
      end

      def sleep(ms), do: send(self(), {:sleep, ms})

      def prompt(q) do
        send(self(), {:prompt, q})
        "typed"
      end

      def prompt_secret(q) do
        send(self(), {:prompt_secret, q})
        "hidden"
      end
    end

    @tag verifies: "host-script-world"
    test "everything outside goes through Ctl.World: the real one by default, a test's under :ctl_world" do
      assert Task.async(fn -> Ctl.World.impl() end) |> Task.await() == Ctl.World.Real

      assert Ctl.World.Real.cmd("sh", ["-c", "echo out; exit 3"], []) == {"out\n", 3}

      assert capture_io("  an answer  \n", fn ->
               send(self(), {:answer, Ctl.World.Real.prompt("Where? ")})
             end) == "Where? "

      assert_received {:answer, "an answer"}

      capture_io("", fn -> send(self(), {:answer, Ctl.World.Real.prompt("Where? ")}) end)
      assert_received {:answer, ""}

      Process.put(:ctl_world, FakeWorld)
      assert Ctl.World.cmd("docker", ["info"], into: "") == {"faked", 0}
      Ctl.World.sleep(10)
      assert Ctl.World.prompt("Q? ") == "typed"
      assert Ctl.World.prompt_secret("P? ") == "hidden"
      assert_received {:cmd, "docker", ["info"], [into: ""]}
      assert_received {:sleep, 10}
      assert_received {:prompt, "Q? "}
      assert_received {:prompt_secret, "P? "}
    end

    @tag verifies: "host-script-secret"
    test "what may be printed: secrets by key, a URL's password, --reveal, and set never echoing",
         %{tmp_dir: dir} do
      for key <- ~w(SECRET_KEY_BASE secret_key_base API_KEY smtp_password GIT_TOKEN APP_SECRET),
          do: assert(Ctl.Secret.secret?(key), key)

      for key <- ~w(PORT KEYS TOKENIZER PASSWORD_HINT), do: refute(Ctl.Secret.secret?(key), key)

      long = "abcdefghijkl1234"
      assert Ctl.Secret.display("API_KEY", long) == "set (…1234)"
      assert Ctl.Secret.display("API_KEY", long, true) == long
      assert Ctl.Secret.display("PORT", "8080") == "8080"

      assert Ctl.Secret.display("database_url", "postgres://app:pw@db/app") ==
               "postgres://app:****@db/app"

      assert Ctl.Secret.display("DATABASE_URL", "postgres://app:pw@db/app", true) ==
               "postgres://app:pw@db/app"

      assert Ctl.Secret.mask("short") == "set"
      assert Ctl.Secret.reveal(["list", "--reveal"]) == {true, ["list"]}
      assert Ctl.Secret.reveal(["list"]) == {false, ["list"]}

      {script, _home} = Recorder.home!(dir, "sample-ctl")
      Recorder.install()

      {:ok, out} =
        with_io(fn -> Ctl.dispatch(["env", "set", "API_TOKEN=#{long}"], %{}, script) end)

      assert out =~ "set API_TOKEN"
      refute out =~ "abcdefghijkl"
    end

    @tag verifies: "host-script-env"
    test "the host settings are the seven every script has, then the app's own" do
      assert Ctl.Env.keys() == ~w(PORT NETWORK BIND IMAGE TAG NAME DOCKER_RUN_ARGS ADMIN_PORT)
      assert Ctl.Env.keys() == Enum.map(Ctl.App.settings(), &elem(&1, 0))
    end

    @tag verifies: "host-script-env-load"
    test "load/2: the data directory, the settings resolved, and what the loaded settings hold",
         %{tmp_dir: dir} do
      {script, home} = Recorder.home!(dir, "sample-ctl")
      conf = Path.join(home, "sample.conf")
      File.write!(conf, "PORT=8080\nTAG=\nNETWORK=host\nCUSTOM=1\nOTHER=2\n")

      {:ok, env} =
        Ctl.Env.load(script, %{
          "PORT" => "9090",
          "NAME" => "",
          "SAMPLE_CTL_SELF_UPDATED" => "1"
        })

      assert env.data_dir == home
      assert env.loaded?
      assert env.self_updated?
      assert {Ctl.Env.get(env, "PORT"), Ctl.Env.source(env, "PORT")} == {"9090", :environment}
      assert {Ctl.Env.get(env, "NETWORK"), Ctl.Env.source(env, "NETWORK")} == {"host", :file}
      # Empty counts as unset, in the file and in the environment.
      assert {Ctl.Env.get(env, "TAG"), Ctl.Env.source(env, "TAG")} == {"latest", :default}
      assert {Ctl.Env.get(env, "NAME"), Ctl.Env.source(env, "NAME")} == {"sample", :default}
      assert env.extra == [{"CUSTOM", "1"}, {"OTHER", "2"}]
      assert env.sys_values == %{"PORT" => "9090"}
      assert env.file_values["PORT"] == "8080"

      assert Ctl.Env.ref(env) == @ref
      assert Ctl.Env.data_path(env) == Path.join(home, "data")
      assert Ctl.Env.legacy_path(env) == Path.join(dir, "sample-env")
      assert Ctl.Env.host_network?(env)

      assert Ctl.Env.app_keys() == %{
               "PHX_HOST" => "phx_host",
               "TZ" => "tz",
               "SMTP_HOST" => "smtp_host"
             }

      # <PREFIX>_DATA_DIR wins over the script's line when set non-empty.
      elsewhere = Path.join(dir, "elsewhere")
      {:ok, env} = Ctl.Env.load(script, %{"SAMPLE_DATA_DIR" => elsewhere})
      assert env.data_dir == elsewhere
      refute env.loaded?
      refute env.self_updated?
      {:ok, env} = Ctl.Env.load(script, %{"SAMPLE_DATA_DIR" => ""})
      assert env.data_dir == home

      # A script not on disk uses the compiled line.
      {:ok, env} = Ctl.Env.load(Path.join(dir, "not-there-ctl"), %{})
      assert env.data_dir == Ctl.Home.data_dir()

      {:ok, env} = Ctl.Env.with_data_dir(env, home, %{})
      assert env.data_dir == home and env.loaded?
    end

    @tag verifies: "host-script-env-file"
    test "the settings file's lines, and render/2 writing it back with its sentences",
         %{tmp_dir: dir} do
      text = """
      # a comment
        PORT=1
      PORT=8080
      _UNDER_1=a\\"b
      Q="say \\"hi\\""
      S='it is'
      U=plain words   # a note
      """

      assert {:ok, %{"PORT" => "8080"}, extra} = Ctl.Env.parse(text)

      assert extra == [
               {"_UNDER_1", "a\\\"b"},
               {"Q", "say \"hi\""},
               {"S", "it is"},
               {"U", "plain words"}
             ]

      assert {:error, "sample.conf line 2 is not KEY=value: 1A=x"} =
               Ctl.Env.parse("A=1\n1A=x\nnonsense\n")

      assert Ctl.Env.read_file(Path.join(dir, "none.conf")) == {:ok, %{}, []}
      assert Ctl.Env.read_file(nil) == {:ok, %{}, []}

      rendered = Ctl.Env.render(%{"PORT" => "8080", "TAG" => "", "NAME" => "a b"}, [{"X", "#1"}])

      assert rendered =~ "# Host settings for sample-ctl"
      assert rendered =~ "A variable set in the environment still wins for a one-off"
      assert rendered =~ "PORT=8080 ./sample-ctl start"

      assert [_header, body] = String.split(rendered, "\n\n# The web port.", parts: 2)

      assert body =~
               ~r/^ Reach Sample at http:\/\/<this host>:PORT\nPORT=8080\nTAG=""\nNAME="a b"\n/

      assert String.ends_with?(rendered, "\n# Other settings, kept as they were.\nX=\"#1\"\n")

      assert {:ok, %{"PORT" => "8080", "TAG" => "", "NAME" => "a b"}, [{"X", "#1"}]} =
               Ctl.Env.parse(rendered)
    end

    @tag verifies: "host-script-env-edit"
    test "edit_set/3 and edit_unset/2 change only the key's own lines" do
      assert Ctl.Env.edit_set("A=1\nexport PORT=1\n# PORT=2", "PORT", "9") ==
               "A=1\nPORT=9\n# PORT=2"

      assert Ctl.Env.edit_set("A=1", "PORT", "9") == "A=1\nPORT=9\n"
      assert Ctl.Env.edit_set("", "PORT", "9") == "PORT=9\n"
      assert Ctl.Env.edit_set("A=1\n", "NAME", "a b") == "A=1\nNAME=\"a b\"\n"

      assert Ctl.Env.edit_unset("PORT=1\n# mine\nPORT=2\nPORTS=3\n", "PORT") ==
               {"# mine\nPORTS=3\n", 2}

      assert Ctl.Env.edit_unset("A=1\n", "PORT") == {"A=1\n", 0}
    end

    @tag verifies: "host-script-env-validate"
    test "validate/1 answers the first problem among PORT and NAME; an empty NETWORK is its default",
         %{tmp_dir: dir} do
      assert :ok = Ctl.Env.validate(env!(dir))

      assert {:error, "PORT must be a port number (1–65535), not \"0\""} =
               Ctl.Env.validate(env!(dir, %{"PORT" => "0", "NAME" => "bad name"}))

      assert {:error, "NAME must be a valid container name (letters, digits, _ . -)"} =
               Ctl.Env.validate(env!(dir, %{"NAME" => "-x"}))

      assert :ok = Ctl.Env.validate(env!(dir, %{"NAME" => "a_b.c-1", "PORT" => "65535"}))

      # An empty NETWORK is unset: it resolves to the default, which validates.
      empty = env!(dir, %{"NETWORK" => ""})
      assert Ctl.Env.get(empty, "NETWORK") == "bridge"
      assert :ok = Ctl.Env.validate(empty)
    end

    @tag verifies: "host-script-env-host"
    test "this host's name and zone, and the values init seeds" do
      Recorder.install([
        {["hostname", "-f"], {"pbx.lan\n", 0}},
        {["timedatectl"], {"Europe/Oslo\n", 0}}
      ])

      assert Ctl.Env.hostname() == "pbx.lan"
      assert Ctl.Env.host_timezone() == "Europe/Oslo"
      assert Ctl.Env.resolve_value(:hostname) == "pbx.lan"
      assert Ctl.Env.resolve_value(:timezone) == "Europe/Oslo"
      assert Ctl.Env.resolve_value("http") == "http"

      # Neither answers: the short host name, and the zone from /etc.
      Recorder.install()
      {:ok, short} = :inet.gethostname()
      assert Ctl.Env.hostname() == List.to_string(short)

      expected =
        case File.read("/etc/timezone") do
          {:ok, text} when text != "" ->
            String.trim(text)

          _ ->
            case File.read_link("/etc/localtime") do
              {:ok, target} -> target |> String.split("/zoneinfo/", parts: 2) |> List.last()
              _ -> "Etc/UTC"
            end
        end

      assert Ctl.Env.host_timezone() == expected

      assert Ctl.Env.present(nil) == nil
      assert Ctl.Env.present("") == nil
      assert Ctl.Env.present("x") == "x"
    end

    @tag verifies: "host-script-docker"
    test "every docker command line, and the queries", %{tmp_dir: dir} do
      env = env!(dir)
      volume = "#{Path.join(env.data_dir, "data")}:/data"

      assert Ctl.Docker.own_data_args(env) ==
               ["run", "--rm", "--user", "0:0", "--entrypoint", "chown", "-v", volume, @ref] ++
                 ["2060:2060", "/data"]

      assert Ctl.Docker.eval_args(env, "X.y()", [{"A", "1"}, {"B", nil}]) ==
               {["run", "--rm", "--user", "2060:2060", "-v", volume, "-e", "A", @ref] ++
                  ["/app/bin/sample", "eval", "X.y()"], [env: [{"A", "1"}]]}

      assert Ctl.Docker.release_args(env, "reset", ["u"], "pw") ==
               Ctl.Docker.eval_args(env, "Sample.Release.reset()", [
                 {"SAMPLE_CTL_ARGS", ~s(["u"])},
                 {"SAMPLE_CTL_PASSWORD", "pw"}
               ])

      assert Ctl.Docker.config_args(env, ["list"]) ==
               Ctl.Docker.release_args(env, "config", ["list"])

      {argv, opts} = Ctl.Docker.migrate_args(env, "/old/data", "k3y")

      assert Enum.drop(argv, -1) ==
               ["run", "--rm", "--user", "0:0", "--entrypoint", "sh", "-v", "/old/data:/old:ro"] ++
                 ["-v", volume, "-e", "SECRET_KEY_BASE", @ref, "-c"]

      assert opts == [env: [{"SECRET_KEY_BASE", "k3y"}]]
      {argv, [env: []]} = Ctl.Docker.migrate_args(env, "/old/data", nil)
      refute "SECRET_KEY_BASE" in argv

      assert Ctl.Docker.stop_args("sample") == ["stop", "-t", "30", "sample"]

      assert Ctl.Docker.rpc_args("sample", "X.y()") == [
               "exec",
               "sample",
               "/app/bin/sample",
               "rpc",
               "X.y()"
             ]

      assert Ctl.Docker.status_args("sample") ==
               Ctl.Docker.rpc_args("sample", "Sample.Release.status()")

      assert Ctl.Docker.logs_args("sample", nil) == ["logs", "-f", "--tail", "100", "sample"]
      assert Ctl.Docker.logs_args("sample", "5") == ["logs", "--tail", "5", "sample"]
      assert Ctl.Docker.exec_args("sample", ["ls"], true) == ["exec", "-it", "sample", "ls"]
      assert Ctl.Docker.exec_args("sample", ["ls"], false) == ["exec", "sample", "ls"]

      # The ulimit is always set; on a named network, PORT is published.
      net = env!(dir, %{"NETWORK" => "backend", "PORT" => "8080"})

      assert [
               "run",
               "-d",
               "--name",
               "sample",
               "--ulimit",
               "nofile=65536:65536",
               "--network",
               "backend",
               "-p",
               "127.0.0.1:8080:4000" | _
             ] =
               Ctl.Docker.run_args(net)

      # The queries, through Ctl.Docker.run/2 alone.
      Recorder.install([{["docker", "info"], {"", 127}}])
      assert Ctl.Docker.ensure_available() == {:error, "docker is not installed or not on PATH"}
      Recorder.install([{["docker", "info"], {"denied", 1}}])
      assert {:error, "cannot talk to the docker daemon" <> _} = Ctl.Docker.ensure_available()

      Recorder.install([
        {["docker", "image", "inspect", "-f"], {"sha256:abc\n", 0}},
        {["docker", "image", "inspect"], {"[]", 0}},
        {["docker", "container", "inspect", "up"], {~s([{"State":{"Running":true}}]), 0}},
        {["docker", "container", "inspect", "down"], {~s([{"State":{"Running":false}}]), 0}},
        {["docker", "rm", "-f"], {"", 0}},
        {["docker", "logs", "--tail", "30"], {"last words\n", 0}},
        {["docker", "run", "--rm", @ref, "bin/ctl"], {"#!/usr/bin/env elixir\n", 0}}
      ])

      assert Ctl.Docker.have_image?(@ref)
      assert Ctl.Docker.image_id(@ref) == "sha256:abc"
      assert Ctl.Docker.container_exists?("down")
      refute Ctl.Docker.container_running?("down")
      assert Ctl.Docker.container_running?("up")
      assert Ctl.Docker.inspect_container("gone") == :none
      refute Ctl.Docker.container_exists?("gone")
      assert Ctl.Docker.remove_container("sample") == :ok
      assert Ctl.Docker.last_words("sample") == "last words\n"
      assert Ctl.Docker.extract_ctl(@ref) == "#!/usr/bin/env elixir\n"
      assert List.last(Recorder.calls()) == {"docker", ["run", "--rm", @ref, "bin/ctl"], []}

      Recorder.install()
      assert Ctl.Docker.image_id(@ref) == nil
      assert Ctl.Docker.extract_ctl(@ref) == nil

      {result, _} = with_io(fn -> Ctl.Docker.pull(@ref, "registry.example/acme/sample") end)

      assert result ==
               {:error,
                "could not pull #{@ref} — is 'docker login registry.example' done on this host?"}
    end

    @tag verifies: "host-script-app"
    test "Ctl.App holds everything app-specific, from the description" do
      assert {Ctl.App.name(), Ctl.App.title(), Ctl.App.script()} ==
               {"sample", "Sample", "sample-ctl"}

      assert {Ctl.App.prefix(), Ctl.App.release()} == {"SAMPLE", "Sample.Release"}
      assert {Ctl.App.release_bin(), Ctl.App.container_data()} == {"/app/bin/sample", "/data"}
      assert {Ctl.App.container_port(), Ctl.App.stop_timeout()} == {"4000", "30"}
      assert {Ctl.App.ids(), Ctl.App.default_home()} == {{2060, 2060}, "/srv/sample"}
      assert List.last(Ctl.App.settings()) == {"ADMIN_PORT", "4001", "The admin console's port."}

      assert Ctl.App.seeds() == [
               {"phx_host", :hostname},
               {"phx_scheme", "http"},
               {"tz", :timezone}
             ]

      assert Ctl.App.migrate_keys() == [
               {"PHX_HOST", "phx_host", :hostname},
               {"TZ", "tz", :timezone}
             ]
    end

    @tag verifies: "host-script-main"
    test "main/3's exit status, dispatch's order and faults, and the help", %{tmp_dir: dir} do
      {script, home} = Recorder.home!(dir, "sample-ctl")

      Recorder.install([
        {["docker", "info"], {"", 0}},
        {["docker", "container", "inspect"], {"", 1}}
      ])

      {status, _} = with_io(fn -> Ctl.main(["stop"], %{}, script) end)
      assert status == 0

      Recorder.install([
        {["docker", "info"], {"", 0}},
        {["docker", "container", "inspect"], {~s([{"State":{"Running":true}}]), 0}},
        {["docker", "exec"], {"", 7}}
      ])

      {status, _} = with_io(fn -> Ctl.main(["ping"], %{}, script) end)
      assert status == 7

      for help <- [[], ["help"], ["-h"], ["--help"]] do
        {:ok, out} = with_io(fn -> Ctl.dispatch(help, %{}, script) end)
        assert out =~ "sample-ctl — manage the Sample container on a deployment host."
      end

      # A fault in the settings is the answer.
      File.write!(Path.join(home, "sample.conf"), "nonsense\n")

      assert {{:error, "sample.conf line 1 is not KEY=value: nonsense"}, _} =
               with_io(fn -> Ctl.dispatch(["status"], %{}, script) end)

      File.rm!(Path.join(home, "sample.conf"))

      assert {{:error, "unknown command: frob\n\n" <> help}, _} =
               with_io(fn -> Ctl.dispatch(["frob"], %{}, script) end)

      assert help =~ "Data directory: #{home}"
      assert help =~ "Sample's own commands:"
      assert help =~ ~r/^  PORT\s+4000$/m
      refute help =~ ~r/^  DOCKER_RUN_ARGS/m
      [commands, _] = String.split(help, "\nThe data directory is", parts: 2)
      assert Enum.all?(String.split(commands, "\n"), &(String.length(&1) <= 78))

      {:ok, env} =
        Ctl.Env.load(Recorder.script!(Path.join(dir, "bare-ctl")), %{"API_TOKEN" => "x"})

      text = Ctl.usage_text(env)
      assert text =~ "Data directory: not set yet — ./sample-ctl init [DIR]"

      {:ok, env} = Ctl.Env.load(script, %{"PORT" => "8080"})
      assert Ctl.usage_text(env) =~ ~r/^  PORT\s+8080$/m

      assert Ctl.script_path() == Path.expand(CtlFixture.path())
    end
  end
end
