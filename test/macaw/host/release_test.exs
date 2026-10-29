defmodule Macaw.Host.ReleaseTest do
  use ExUnit.Case, async: true

  alias Macaw.Host.Release

  @moduletag :tmp_dir

  @specs [
    {:port, :port, 4000},
    {:mode, {:enum, [:open, :closed]}, :closed},
    {:smtp_password, :secret, nil}
  ]

  describe "config commands" do
    @tag verifies: "release-config-custom"
    test "a custom value is shown by its show/1 on get, list and a fault", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      specs = @specs ++ [{:auth, {:custom, Macaw.Host.Test.SignInBlock}, nil}]

      assert {:ok, [%{set: "auth"}]} =
               Release.config_command(path, specs, "RT", [
                 "set",
                 "auth",
                 ~s(%{host: "nas", password: "correct-horse-battery-staple"})
               ])

      assert {:ok, [%{value: shown}]} = Release.config_command(path, specs, "RT", ["get", "auth"])
      assert shown =~ "set (…aple)"
      {:ok, list} = Release.config_command(path, specs, "RT", ["list"])
      refute inspect(list) =~ "correct-horse"

      # A value that doesn't check is shown by the type too, with its fault.
      Macaw.Host.Config.Literal.write!(path, %{auth: [password: "correct-horse-battery-staple"]})

      assert {:ok, [%{value: "(not a sign-in block)", fault: fault}]} =
               Release.config_command(path, specs, "RT", ["get", "auth"])

      assert fault =~ "must be a sign-in block"
    end

    @tag verifies: "release-config-cycle"
    test "set, get, list and unset, with the source of each value", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      assert {:ok, [%{ok: true, set: "port", restart: "restart to apply"}]} =
               Release.config_command(path, @specs, "RT", ["set", "port", "8443"])

      assert {:ok, [%{name: :port, value: "8443", source: "config.exs"}]} =
               Release.config_command(path, @specs, "RT", ["get", "port"])

      assert {:ok, list} = Release.config_command(path, @specs, "RT", ["list"])
      assert %{name: :mode, value: ":closed", source: "default"} in list

      assert {:ok, [%{unset: "port"}]} =
               Release.config_command(path, @specs, "RT", ["unset", "port"])

      assert {:ok, [%{source: "default"}]} =
               Release.config_command(path, @specs, "RT", ["get", "port"])
    end

    @tag verifies: "release-config-secret"
    test "a secret is never shown", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      Release.config_command(path, @specs, "RT", [
        "set",
        "smtp_password",
        ~s("correct-horse-battery")
      ])

      assert {:ok, [%{value: "set (…tery)"}]} =
               Release.config_command(path, @specs, "RT", ["get", "smtp_password"])
    end

    @tag verifies: "release-config-string-key"
    test "a file key written as a string is the file's value, not the default", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")
      File.write!(path, ~s(%{"port" => 9090}))

      assert {:ok, [%{name: :port, value: "9090", source: "config.exs"}]} =
               Release.config_command(path, @specs, "RT", ["get", "port"])
    end

    @tag verifies: "release-config-env-typed"
    test "an env value is shown typed, as load! would read it, or as a fault", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      env = %{"RT_PORT" => " 8080 ", "RT_MODE" => "ajar"}

      assert {:ok, list} = Release.config_command(path, @specs, "RT", ["list"], env)

      assert %{name: :port, value: "8080", source: "env RT_PORT"} in list

      assert %{
               name: :mode,
               value: ~s("ajar"),
               source: "env RT_MODE",
               fault: "RT_MODE: must be one of open, closed"
             } in list

      assert %{name: :smtp_password, value: "unset", source: "default"} in list
    end

    @tag verifies: "release-config-errors"
    test "bad input is an answer, not a crash", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      assert {:error, "no setting named nope"} =
               Release.config_command(path, @specs, "RT", ["get", "nope"])

      assert {:error, "must be one of open, closed"} =
               Release.config_command(path, @specs, "RT", ["set", "mode", ":ajar"])

      assert {:error, "usage:" <> _} = Release.config_command(path, @specs, "RT", ["frob"])
    end

    @tag verifies: "release-config-reset"
    test "reset repairs a file that no longer parses, and refuses anything else", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      assert {:error, "there is no config.exs: nothing to reset"} =
               Release.config_command(path, @specs, "RT", ["reset"])

      File.write!(path, "%{port: 8443}")

      assert {:error, "config.exs parses: " <> _} =
               Release.config_command(path, @specs, "RT", ["reset"])

      File.write!(path, "%{\n  port: x\n}")
      assert {:error, _} = Release.config_command(path, @specs, "RT", ["list"])

      assert {:ok, [answer]} = Release.config_command(path, @specs, "RT", ["reset"])

      assert answer |> JSON.encode!() |> JSON.decode!() == %{
               "ok" => true,
               "reset" => true,
               "set_aside" => "config.exs.broken",
               "restart" => "restart to apply"
             }

      assert File.read!(path <> ".broken") == "%{\n  port: x\n}"
      assert {:ok, [_]} = Release.config_command(path, @specs, "RT", ["set", "port", "8443"])

      File.write!(path, "%{port: y}")

      assert {:error, "config.exs.broken already exists" <> _} =
               Release.config_command(path, @specs, "RT", ["reset"])

      assert File.read!(path) == "%{port: y}"
      assert File.read!(path <> ".broken") == "%{\n  port: x\n}"
    end
  end

  @tag verifies: "release-status"
  test "status emits the report as one JSON line" do
    out = ExUnit.CaptureIO.capture_io(fn -> Release.status(%{healthy: true, checks: %{}}) end)
    assert [line] = String.split(out, "\n", trim: true)
    assert out == line <> "\n"
    assert JSON.decode!(line) == %{"healthy" => true, "checks" => %{}}

    # Each check's term worded as text, as the generated script's status reads it.
    report = %{healthy: true, checks: %{proxies: {:warn, "1 untrusted peer"}}}
    out = ExUnit.CaptureIO.capture_io(fn -> Release.status(report) end)
    assert [line] = String.split(out, "\n", trim: true)

    assert JSON.decode!(line) == %{
             "healthy" => true,
             "checks" => %{"proxies" => "warning: 1 untrusted peer"}
           }

    # Text in place of a term is refused, naming the check; not a report at all, too.
    assert_raise ArgumentError, ~r/health check :db's result is "ok"/, fn ->
      Release.status(%{healthy: true, checks: %{db: "ok"}})
    end

    assert_raise ArgumentError, ~r/not a health report/, fn ->
      Release.status(%{healthy: true})
    end
  end

  describe "in a fresh VM, as bin/app eval runs it" do
    # Each runs `elixir` with only this library's and its deps' code paths,
    # the arguments in RT_CTL_ARGS, and nothing loaded that the test loaded:
    # what `bin/<app> eval` gives, and where String.to_existing_atom fails.
    defp eval(code, env) do
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
      args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code]
      System.cmd("elixir", args, env: env, stderr_to_stdout: true)
    end

    @tag verifies: "release-eval-atoms"
    test "config set and get, with a typed name never loaded before", %{tmp_dir: dir} do
      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      specs = [{:rt_never_seen_setting, :integer, 1}]
      Macaw.Host.Release.config(:rt_app, specs, "RT")
      """

      assert {out, 0} = eval(code, [{"RT_CTL_ARGS", ~s(["set", "rt_never_seen_setting", "42"])}])
      assert out =~ ~s("set":"rt_never_seen_setting")

      assert {out, 0} = eval(code, [{"RT_CTL_ARGS", ~s(["get", "rt_never_seen_setting"])}])
      assert out =~ ~s("value":"42")
    end

    @tag verifies: "release-bad-args"
    test "malformed arguments fail with one line on stderr and status 1", %{tmp_dir: dir} do
      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      Macaw.Host.Release.config(:rt_app, [], "RT")
      """

      assert {"RT_CTL_ARGS must be a JSON array of strings\n", 1} =
               eval(code, [{"RT_CTL_ARGS", "not json"}])

      assert {"RT_CTL_ARGS must be a JSON array of strings\n", 1} =
               eval(code, [{"RT_CTL_ARGS", "[1, 2]"}])
    end

    @tag verifies: "release-config-broken"
    test "a broken config.exs fails with one line on stderr and status 1", %{tmp_dir: dir} do
      File.write!(Path.join(dir, "config.exs"), "%{\n  port: x,\n  mode: @doc\n}\n")

      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      Macaw.Host.Release.config(:rt_app, [{:port, :port, 4000}], "RT")
      """

      for args <- [~s(["list"]), ~s(["get", "port"]), ~s(["set", "port", "1"])] do
        assert {out, 1} = eval(code, [{"RT_CTL_ARGS", args}])
        assert [line] = String.split(out, "\n", trim: true)
        assert line =~ "config.exs:2: not a literal: x"
        assert line =~ "config.exs:3: not a literal: @doc"
        refute line =~ "ArgumentError"
      end
    end

    @tag verifies: "release-config-reset-eval"
    test "reset answers one JSON line over a broken config.exs, and set works again",
         %{tmp_dir: dir} do
      broken = "%{\n  port: x,\n  mode: @doc\n}\n"
      File.write!(Path.join(dir, "config.exs"), broken)

      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      Macaw.Host.Release.config(:rt_app, [{:port, :port, 4000}], "RT")
      """

      assert {out, 0} = eval(code, [{"RT_CTL_ARGS", ~s(["reset"])}])
      assert [line] = String.split(out, "\n", trim: true)

      assert JSON.decode!(line) == %{
               "ok" => true,
               "reset" => true,
               "set_aside" => "config.exs.broken",
               "restart" => "restart to apply"
             }

      assert File.read!(Path.join(dir, "config.exs.broken")) == broken

      assert {out, 0} = eval(code, [{"RT_CTL_ARGS", ~s(["set", "port", "8443"])}])
      assert out =~ ~s("set":"port")

      File.write!(Path.join(dir, "config.exs"), broken)
      assert {out, 1} = eval(code, [{"RT_CTL_ARGS", ~s(["reset"])}])
      assert out =~ "config.exs.broken already exists: move it away first"
      assert File.read!(Path.join(dir, "config.exs")) == broken
    end

    @tag verifies: "release-migrate-no-repos"
    test "migrate without a repo configured fails loudly, not silently", %{tmp_dir: _dir} do
      {out, status} = eval("Macaw.Host.Release.migrate(:rt_app_without_repos)", [])
      assert status != 0
      assert out =~ "ecto_repos"
    end

    # Only the VM's stderr: its stdout is dropped.
    defp stderr_of(code) do
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
      args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code]
      System.cmd("sh", ["-c", ~s(elixir "$@" 2>&1 >/dev/null), "sh" | args])
    end

    @tag verifies: "host-release-protocol"
    test "arguments arrive as JSON in an env var, answers leave as JSON lines, a missing variable fails",
         %{tmp_dir: dir} do
      prefix = "RTP#{System.unique_integer([:positive])}"
      System.put_env(prefix <> "_CTL_ARGS", ~s(["get", "port"]))
      System.put_env(prefix <> "_CTL_PASSWORD", "correct-horse")

      on_exit(fn ->
        System.delete_env(prefix <> "_CTL_ARGS")
        System.delete_env(prefix <> "_CTL_PASSWORD")
      end)

      assert Release.ctl_args!(prefix) == ["get", "port"]
      assert Release.ctl_password(prefix) == "correct-horse"
      assert Release.ctl_password(prefix <> "_NONE") == nil

      assert ExUnit.CaptureIO.capture_io(fn -> Release.emit(%{ok: true, set: "port"}) end) ==
               ~s({"ok":true,"set":"port"}\n)

      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      Macaw.Host.Release.config(:rt_app, [], "RT")
      """

      assert {"RT_CTL_ARGS must be a JSON array of strings\n", 1} = stderr_of(code)
      assert {"RT_CTL_ARGS must be a JSON array of strings\n", 1} = eval(code, [])

      assert {"RT_CTL_ARGS must be a JSON array of strings\n", 1} =
               eval(code, [{"RT_CTL_ARGS", ~s({"a": 1})}])
    end

    @tag verifies: "host-release-fail"
    test "fail/1 prints its message as one line on stderr and halts with status 1" do
      assert {"it broke\n", 1} =
               stderr_of(~s|Macaw.Host.Release.fail("it broke"); IO.puts("never")|)

      assert {"it broke\n", 1} =
               eval(~s|Macaw.Host.Release.fail("it broke"); IO.puts("never")|, [])
    end

    @tag verifies: "host-release-migrate"
    test "migrate needs ecto_sql, and an app without :ecto_repos fails loudly" do
      # The code paths of a release without ecto_sql (or ecto).
      paths =
        Path.join(Mix.Project.build_path(), "lib/*/ebin")
        |> Path.wildcard()
        |> Enum.reject(&(&1 =~ ~r{/lib/ecto(_sql)?/}))

      args = Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", "Macaw.Host.Release.migrate(:rt_app)"]

      assert {"migrate needs ecto_sql, which rt_app does not depend on\n", 1} =
               System.cmd("elixir", args, stderr_to_stdout: true)

      {out, status} = eval("Macaw.Host.Release.migrate(:rt_app_without_repos)", [])
      assert status != 0
      assert out =~ "ecto_repos"
    end

    @tag verifies: "host-release-config"
    test "config/3 answers from the app's data directory; config_command/5 shows each setting as the app loads it",
         %{tmp_dir: dir} do
      code = """
      Application.put_env(:rt_app, :data_dir, #{inspect(dir)})
      specs = [{:port, :port, 4000}, {:mode, {:enum, [:open, :closed]}, :closed}]
      Macaw.Host.Release.config(:rt_app, specs, "RT")
      """

      File.write!(Path.join(dir, "config.exs"), "%{port: 8443}")
      assert {out, 0} = eval(code, [{"RT_CTL_ARGS", ~s(["list"])}])

      assert Enum.map(String.split(out, "\n", trim: true), &JSON.decode!/1) == [
               %{"name" => "port", "value" => "8443", "source" => "config.exs"},
               %{"name" => "mode", "value" => ":closed", "source" => "default"}
             ]

      path = Path.join(dir, "config.exs")
      specs = [{:tz, :string, "Etc/UTC"} | @specs]

      # A string value is typed with its quotes; an env var set empty is the source.
      assert {:ok, [%{ok: true, set: "tz", restart: "restart to apply"}]} =
               Release.config_command(path, specs, "RT", ["set", "tz", ~s("Europe/Oslo")], %{})

      assert {:error, _} =
               Release.config_command(path, specs, "RT", ["set", "tz", "Europe/Oslo"], %{})

      assert {:ok, list} = Release.config_command(path, specs, "RT", ["list"], %{"RT_TZ" => ""})
      assert Enum.map(list, & &1.name) == [:tz, :port, :mode, :smtp_password]
      assert %{name: :tz, value: ~s(""), source: "env RT_TZ"} in list
      assert %{name: :port, value: "8443", source: "config.exs"} in list

      assert {:ok, [%{ok: true, unset: "tz", restart: "restart to apply"}]} =
               Release.config_command(path, specs, "RT", ["unset", "tz"], %{})

      assert {:error, "usage: config list | get NAME | set NAME VALUE | unset NAME | reset"} =
               Release.config_command(path, specs, "RT", ["get"], %{})

      File.write!(path, "%{\n  port: x\n}")

      assert {:error, message} = Release.config_command(path, specs, "RT", ["list"], %{})
      assert message == "#{path}:2: not a literal: x"
    end
  end

  @tag verifies: "host-release-status"
  test "status/1 emits the app's own health report, with its version and build, as one JSON line",
       %{tmp_dir: dir} do
    report =
      Macaw.Host.Health.report([data_dir: fn -> Macaw.Host.Health.writable(dir) end],
        version: "1.2.0",
        build: "abc"
      )

    out = ExUnit.CaptureIO.capture_io(fn -> Release.status(report) end)
    assert [line] = String.split(out, "\n", trim: true)

    assert JSON.decode!(line) == %{
             "healthy" => true,
             "version" => "1.2.0",
             "build" => "abc",
             "checks" => %{"data_dir" => "ok"}
           }
  end

  @tag verifies: "host-release"
  test "an app's release module delegates to it, and the script calls its config and status by name",
       %{tmp_dir: dir} do
    defmodule RtSample.Release do
      def config, do: Macaw.Host.Release.config(:rt_sample, [], "RT")
      def status, do: Macaw.Host.Release.status(%{healthy: true, checks: %{}})
    end

    out = ExUnit.CaptureIO.capture_io(fn -> RtSample.Release.status() end)
    assert [line] = String.split(out, "\n", trim: true)
    assert JSON.decode!(line) == %{"healthy" => true, "checks" => %{}}

    # The generated sample script names Sample.Release's two functions.
    {script, _home} = Macaw.Host.Ctl.Recorder.home!(dir, "sample-ctl")
    {:ok, env} = Ctl.Env.load(script, %{})

    assert {argv, _opts} = Ctl.Docker.config_args(env, ["list"])
    assert List.last(argv) == "Sample.Release.config()"
    assert List.last(Ctl.Docker.status_args("sample")) == "Sample.Release.status()"
  end
end
