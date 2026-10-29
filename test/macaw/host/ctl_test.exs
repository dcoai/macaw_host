defmodule Macaw.Host.CtlTest do
  @moduledoc """
  The generator itself: the script's shape (the guard, the one line of host
  state, that it parses), the description's and the app commands' checks,
  the `--check` comparison, and the script run as a real program.
  """

  use ExUnit.Case, async: true

  alias Macaw.Host.Ctl
  alias Macaw.Host.Ctl.Description

  @script CtlFixture.script()

  describe "the generated script" do
    @tag verifies: "gen-deterministic"
    test "parses, and is the same every time" do
      assert {:__block__, _, _} = Code.string_to_quoted!(@script)
      assert Ctl.generate(CtlFixture.description(), CtlFixture.app_commands()) == @script
    end

    @tag verifies: "gen-guard-first"
    test "starts with the version guard, before any module" do
      assert "#!/usr/bin/env elixir\n" <> _ = @script
      {:__block__, _, [first, second | _]} = Code.string_to_quoted!(@script)

      assert {:unless, _, [condition, _]} = first
      assert Macro.to_string(condition) =~ ~s|Version.match?(System.version(), ">= 1.18.0")|
      assert {:defmodule, _, [{:__aliases__, _, [:Ctl, :Home]}, _]} = second
    end

    @tag verifies: "gen-one-data-dir"
    test "has exactly one @data_dir line, nil, inside Ctl.Home" do
      lines = Regex.scan(~r/^\s*@data_dir\b.*$/m, @script)
      assert [["  @data_dir nil"]] = lines

      [home] = Regex.run(~r/^defmodule Ctl\.Home do\n.*?^end$/ms, @script)
      assert home =~ "\n  @data_dir nil\n"
    end

    @tag verifies: "gen-description-values"
    test "carries the description's values" do
      # The sample script is loaded once per VM (test/test_helper.exs).
      assert Elixir.Ctl.App.prefix() == "SAMPLE"
      assert Elixir.Ctl.App.ids() == {2060, 2060}
      assert Elixir.Ctl.App.release_bin() == "/app/bin/sample"
    end

    @tag verifies: "gen-no-try"
    test "uses no try, catch or rescue" do
      {_, found} =
        @script
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:try, _, _} = node, acc -> {node, [:try | acc]}
          node, acc -> {node, acc}
        end)

      assert found == []
      refute @script =~ ~r/^\s*rescue\b/m
    end

    @tag verifies: "gen-no-app-commands"
    test "with no app commands of its own" do
      script = Ctl.generate(CtlFixture.description(), nil)
      assert {:__block__, _, expressions} = Code.string_to_quoted!(script)

      # Its Ctl.AppCommands, compiled under a name of its own: the sample
      # script's modules are loaded already, and global.
      [body] =
        for {:defmodule, _, [{:__aliases__, _, [:Ctl, :AppCommands]}, body]} <- expressions,
            do: body

      name = Module.concat(__MODULE__, "NoAppCommands#{System.unique_integer([:positive])}")
      Code.eval_quoted({:defmodule, [], [name, body]})

      assert name.commands() == []
      assert name.run("frob", %{}, []) == {:error, "unknown command: frob"}
    end
  end

  describe "run as a program, in its own elixir process" do
    @tag verifies: "script-env-host-network"
    @tag :tmp_dir
    test "host_network: false refuses NETWORK=host and writes nothing", %{tmp_dir: dir} do
      home = Path.join(dir, "home")
      File.mkdir_p!(home)
      closed = Path.join(dir, "closed-ctl")

      File.write!(
        closed,
        CtlFixture.description()
        |> Keyword.put(:host_network, false)
        |> Ctl.generate(CtlFixture.app_commands())
        |> Elixir.Ctl.Script.put_data_dir(home)
      )

      assert {out, 1} =
               System.cmd("elixir", [closed, "env", "set", "NETWORK=host"],
                 stderr_to_stdout: true
               )

      assert out =~
               "NETWORK=host is not allowed for Sample: its listeners stay inside the container's own network"

      refute File.exists?(Path.join(home, "sample.conf"))
    end

    @tag verifies: "script-help"
    test "help lists the common commands and the app's, and exits 0" do
      {out, status} = System.cmd("elixir", [CtlFixture.path(), "help"], stderr_to_stdout: true)

      assert status == 0
      refute out =~ "warning"
      assert out =~ "./sample-ctl config list | get KEY | set KEY VALUE|@FILE | unset KEY"
      assert out =~ "Sample's own commands:"
      assert out =~ "./sample-ctl reset-password USER"
      assert out =~ "ADMIN_PORT        4001"
    end

    @tag :tmp_dir
    @tag verifies: "gen-bare"
    test "a bare app (no commands, seeds or settings of its own) compiles without a warning",
         %{tmp_dir: dir} do
      description = Keyword.drop(CtlFixture.description(), [:settings, :seeds, :migrate_keys])
      path = Path.join(dir, "bare-ctl")
      File.write!(path, Ctl.generate(description, nil))

      {out, status} = System.cmd("elixir", [path, "help"], stderr_to_stdout: true)

      assert status == 0
      refute out =~ "warning"
      refute out =~ "own commands"
    end

    @tag verifies: "script-unknown"
    test "an unknown command exits 1 with the message on stderr" do
      # Only the script's stderr reaches the output: its stdout is dropped.
      {err, status} =
        System.cmd("sh", ["-c", ~s(elixir "$0" frob 2>&1 >/dev/null), CtlFixture.path()])

      assert status == 1
      assert err =~ "unknown command: frob"
    end
  end

  describe "the description" do
    @tag verifies: "gen-description-faults"
    test "names the fault: missing keys, unknown keys, a value's shape, a redefined setting, no :ctl" do
      assert {:error, ":ctl is missing :release, :uid"} =
               CtlFixture.description() |> Keyword.drop([:release, :uid]) |> Description.new()

      assert {:error, ":ctl has unknown keys: :prot"} =
               Description.new(CtlFixture.description() ++ [prot: 1])

      assert {:error, ":ctl :uid must be \"uid:gid\", both numbers, not \"app\""} =
               Description.new(Keyword.put(CtlFixture.description(), :uid, "app"))

      assert {:error, ":ctl :settings cannot redefine PORT, which every script has"} =
               Description.new(
                 Keyword.put(CtlFixture.description(), :settings, [{"PORT", "1", ""}])
               )

      assert {:error,
              "mix.exs has no :ctl key in its project config (see Macaw.Host.Ctl.Description)"} =
               Description.new(nil)
    end

    @tag verifies: "gen-description-app-keys"
    test "host_network is a boolean; :app_keys are {\"KEY\", \"config_key\"}, never a host setting" do
      put = &Keyword.put(CtlFixture.description(), &1, &2)

      assert {:error, ":ctl :host_network must be true or false, not \"no\""} =
               Description.new(put.(:host_network, "no"))

      assert {:error,
              ":ctl :app_keys must be a list of {\"KEY\", \"config_key\"}, not [{\"smtp\", \"smtp_host\"}]"} =
               Description.new(put.(:app_keys, [{"smtp", "smtp_host"}]))

      assert {:error, ":ctl :app_keys names ADMIN_PORT, which is a host setting"} =
               Description.new(put.(:app_keys, [{"ADMIN_PORT", "admin_port"}]))

      assert {:ok, %{host_network: true, app_keys: [{"SMTP_HOST", "smtp_host"}]}} =
               Description.new(CtlFixture.description())
    end

    @tag verifies: "gen-defaults"
    test "fills in the defaults" do
      {:ok, d} = Description.new(Keyword.drop(CtlFixture.description(), [:settings]), :sample_web)

      assert %{
               title: "Sample",
               release_bin: "/app/bin/sample_web",
               tag: "latest",
               network: "bridge",
               data_home: "/srv/sample",
               app_commands: "ctl/app_commands.ex",
               output: "container/sample-ctl",
               script: "sample-ctl",
               ids: {2060, 2060}
             } = d

      assert Enum.map(d.settings, &elem(&1, 0)) ==
               ~w(PORT NETWORK IMAGE TAG NAME DOCKER_RUN_ARGS)
    end

    @tag verifies: "gen-generate-raises"
    test "generate/2 raises naming the fault" do
      assert_raise ArgumentError, ":ctl is missing :port", fn ->
        Ctl.generate(Keyword.delete(CtlFixture.description(), :port), nil)
      end
    end
  end

  describe "the app commands" do
    @tag verifies: "gen-app-commands-shape"
    test "must define Ctl.AppCommands with commands/0 and run/3" do
      assert {:error, "the app commands file must define Ctl.AppCommands"} =
               Ctl.app_commands("defmodule Ctl.AppCommands.Helpers do\nend\n")

      assert {:error, "the app commands file may define only Ctl.AppCommands, not Other"} =
               Ctl.app_commands("defmodule Other do\nend\n")

      assert {:error, "Ctl.AppCommands must define run/3"} =
               Ctl.app_commands("defmodule Ctl.AppCommands do\n  def commands, do: []\nend\n")
    end

    @tag verifies: "gen-app-commands-guard"
    test "may not replace a generic module or set @data_dir, and must parse" do
      source = CtlFixture.app_commands() <> "\ndefmodule Ctl.Home do\nend\n"

      assert {:error, "the app commands file may define only Ctl.AppCommands, not Ctl.Home"} =
               Ctl.app_commands(source)

      source =
        String.replace(
          CtlFixture.app_commands(),
          "  def commands do",
          "  @data_dir \"/x\"\n  def commands do"
        )

      assert {:error, "Ctl.AppCommands must not set @data_dir" <> _} = Ctl.app_commands(source)

      assert {:error, "Ctl.AppCommands does not parse: line 1" <> _} =
               Ctl.app_commands("defmodule Ctl.AppCommands do\n")
    end

    @tag verifies: "gen-app-commands-stray"
    test "may hold nothing outside the one Ctl.AppCommands module, naming the line" do
      source = File.read!(Path.expand("../../fixtures/ctl/app_commands_stray.ex", __DIR__))

      assert {:error, message} = Ctl.app_commands(source)

      assert message ==
               "the app commands file may hold only the Ctl.AppCommands module; " <>
                 "line 10 is outside it: alias Ctl.AppCommands"

      assert {:error,
              "the app commands file may hold only the Ctl.AppCommands module; " <>
                "line 1 is outside it: :ok"} =
               Ctl.app_commands(":ok\n" <> CtlFixture.app_commands())

      # A submodule belongs inside the module, not beside it: the line after
      # the fixture's last and a blank one.
      line = length(String.split(CtlFixture.app_commands(), "\n")) + 1

      assert {:error,
              "the app commands file may hold only the Ctl.AppCommands module; " <>
                "line " <> rest} =
               Ctl.app_commands(
                 CtlFixture.app_commands() <> "\ndefmodule Ctl.AppCommands.Helpers do\nend\n"
               )

      assert String.starts_with?(rest, "#{line} is outside it: defmodule Ctl.AppCommands.Helpers")

      nested =
        String.replace(
          CtlFixture.app_commands(),
          "  def commands do",
          "  defmodule Helpers do\n    def x, do: 1\n  end\n\n  def commands do"
        )

      assert {:ok, _} = Ctl.app_commands(nested)
    end
  end

  describe "compare/2, for --check" do
    @tag verifies: "gen-compare"
    test "the same text passes; the first line that differs is named, the end of a file too" do
      assert :ok = Ctl.compare(@script, @script)

      edited =
        String.replace(@script, "def stop_timeout, do: \"30\"", "def stop_timeout, do: \"5\"")

      line = edited |> String.split("\n") |> Enum.find_index(&(&1 =~ ~s|do: "5"|)) |> Kernel.+(1)

      assert {:error, message} = Ctl.compare(@script, edited)
      assert message =~ "first at line #{line}:"
      assert message =~ ~s|generated: "  def stop_timeout, do: \\"30\\""|
      assert message =~ ~s|committed: "  def stop_timeout, do: \\"5\\""|

      assert {:error, message} = Ctl.compare(@script, "#!/usr/bin/env elixir\n")
      assert message =~ "first at line 2:"
    end
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 06" do
    defp top_modules(script) do
      {:__block__, _, expressions} = Code.string_to_quoted!(script)
      for {:defmodule, _, [{:__aliases__, _, parts}, _]} <- expressions, do: Module.concat(parts)
    end

    @tag verifies: "host-gen"
    test "the script is the generic modules, the description and the app's own commands, standard library only" do
      # The generic modules, compiled into Macaw.Host.Ctl from priv/ctl.
      for module <- [
            Elixir.Ctl.World,
            Elixir.Ctl.Env,
            Elixir.Ctl.Docker,
            Elixir.Ctl.Commands,
            Elixir.Ctl
          ],
          do: assert(module in top_modules(@script), inspect(module))

      assert Path.wildcard(Path.join(:code.priv_dir(:macaw_host), "ctl/*.eex")) != []

      # The description fills in what is app-specific; the app's commands are spliced in.
      assert @script =~ ~s|def name, do: "sample"|
      assert @script =~ ~s|def run("ping", env, []) do|
      assert @script =~ "Sample's own commands"

      # Standard library only: every module it names outside Ctl is Elixir's own.
      {_, aliases} =
        @script
        |> Code.string_to_quoted!()
        |> Macro.prewalk([], fn
          {:__aliases__, _, [first | _] = parts} = node, acc when first != :Ctl ->
            {node, [Module.concat(parts) | acc]}

          node, acc ->
            {node, acc}
        end)

      for module <- Enum.uniq(aliases) do
        assert {:module, _} = Code.ensure_loaded(module)

        assert :application.get_application(module) in [{:ok, :elixir}, {:ok, :logger}],
               "#{inspect(module)} is not Elixir's own"
      end
    end

    @tag verifies: "host-gen-generate"
    test "build/2 answers the script or the fault; the script is formatted, in module order, ending in a newline" do
      {:ok, checked} = Description.new(CtlFixture.description())

      assert {:ok, @script} = Ctl.build(checked, CtlFixture.app_commands())
      assert {:ok, @script} = Ctl.build(CtlFixture.description(), CtlFixture.app_commands())

      assert {:error, "the app commands file may define only Ctl.AppCommands, not Other.Thing"} =
               Ctl.build(CtlFixture.description(), "defmodule Other.Thing do\nend\n")

      assert {:error, ":ctl is missing :port"} =
               Ctl.build(Keyword.delete(CtlFixture.description(), :port), nil)

      assert String.ends_with?(@script, "\n")
      refute String.ends_with?(@script, "\n\n")
      assert IO.iodata_to_binary(Code.format_string!(@script)) <> "\n" == @script

      assert top_modules(@script) == [
               Elixir.Ctl.Home,
               Elixir.Ctl.App,
               Elixir.Ctl.World,
               Elixir.Ctl.World.Real,
               Elixir.Ctl.Script,
               Elixir.Ctl.Secret,
               Elixir.Ctl.Env,
               Elixir.Ctl.Docker,
               Elixir.Ctl.Commands,
               Elixir.Ctl.AppCommands,
               Elixir.Ctl
             ]
    end

    @tag verifies: "host-gen-head"
    test "the head: the shebang, the do-not-edit comment, and a guard that refuses an old Elixir in one sentence" do
      [head, _] = String.split(@script, "\nunless ", parts: 2)
      assert "#!/usr/bin/env elixir\n" <> comment = head
      assert comment =~ "Generated by `mix macaw.host.ctl`"
      assert comment =~ "never edit this file by hand"

      {:__block__, _, [{:unless, _, [condition, [do: refusal]]} | _]} =
        Code.string_to_quoted!(@script)

      assert Macro.to_string(condition) =~ "Code.ensure_loaded?(JSON)"

      # What a host with an old Elixir sees: the guard's body, run.
      {err, status} =
        System.cmd("sh", ["-c", ~s(elixir -e "$0" 2>&1 >/dev/null), Macro.to_string(refusal)])

      assert status == 1

      assert err =~
               "sample-ctl needs Elixir 1.18 or newer (for its JSON module); this is Elixir #{System.version()}."

      assert err =~ "https://elixir-lang.org/install.html"
    end

    @tag verifies: "host-gen-description"
    test "new/2 checks once and fills in every default; new!/2 raises the first fault" do
      assert {:ok, %{script: "sample-ctl", tag: "latest", settings: [_ | _]}} =
               Description.new(CtlFixture.description())

      assert %{script: "sample-ctl"} = Description.new!(CtlFixture.description())

      # The first fault only: an unknown key before a missing one.
      assert {:error, ":ctl has unknown keys: :prot"} =
               Description.new(Keyword.drop(CtlFixture.description(), [:port]) ++ [prot: 1])

      assert_raise ArgumentError, ":ctl is missing :port", fn ->
        Description.new!(Keyword.delete(CtlFixture.description(), :port))
      end
    end

    @tag verifies: "host-gen-required"
    test "each required key must have its shape" do
      bad = [
        name: "Sample",
        name: "1sample",
        image: "",
        env_prefix: "sample",
        release: "sample.release",
        uid: "2060",
        port: 0,
        port: 65_536,
        port: "4000"
      ]

      for {key, value} <- bad do
        assert {:error, ":ctl " <> message} =
                 Description.new(Keyword.put(CtlFixture.description(), key, value))

        assert message =~ "#{inspect(key)} must be "
        assert message =~ ", not #{inspect(value)}"
      end

      good = [
        name: "my-app_2",
        image: "x",
        env_prefix: "MY_APP2",
        release: "MyApp.Release",
        uid: "0:0",
        port: 65_535
      ]

      for {key, value} <- good,
          do:
            assert({:ok, _} = Description.new(Keyword.put(CtlFixture.description(), key, value)))
    end

    @tag verifies: "host-gen-optional"
    test "each optional key has its default and its shape" do
      required =
        Keyword.take(CtlFixture.description(), [:image, :env_prefix, :release, :uid, :port])

      {:ok, d} = Description.new([name: "my-app"] ++ required)

      assert %{
               title: "My-app",
               otp_app: "my_app",
               release_bin: "/app/bin/my_app",
               tag: "latest",
               network: "bridge",
               container_data: "/data",
               docker_run_args: "--restart unless-stopped",
               stop_timeout: 30,
               data_home: "/srv/my-app",
               seeds: [],
               migrate_keys: [],
               app_commands: "ctl/app_commands.ex",
               output: "container/my-app-ctl"
             } = d

      assert {:ok, %{otp_app: "the_app"}} =
               Description.new([name: "my-app"] ++ required, :the_app)

      assert {:ok, %{app_commands: false}} =
               Description.new(CtlFixture.description() ++ [app_commands: false])

      bad = [
        release_bin: "bin/app",
        container_data: "data",
        stop_timeout: -1,
        data_home: "srv/app",
        seeds: [{"TZ", :timezone}],
        migrate_keys: [{"OLD", "key", :other}],
        settings: [{"lower", "1", "help"}],
        tag: ""
      ]

      for {key, value} <- bad do
        assert {:error, ":ctl " <> _} =
                 Description.new(Keyword.put(CtlFixture.description(), key, value)),
               inspect({key, value})
      end
    end

    @tag verifies: "host-gen-description-faults"
    test "the faults, checked in order, the first answered" do
      assert {:error, ":ctl must be a keyword list, not \"sample\""} = Description.new("sample")

      # Missing before a value's shape.
      assert {:error, ":ctl is missing :release"} =
               CtlFixture.description()
               |> Keyword.delete(:release)
               |> Keyword.put(:uid, "app")
               |> Description.new()

      assert {:error, ":ctl :settings key \"admin_port\" must be an upper-case name"} =
               Description.new(
                 Keyword.put(CtlFixture.description(), :settings, [{"admin_port", "1", ""}])
               )

      assert {:error,
              ":ctl :settings entry {\"A\", \"1\"} must be {\"KEY\", \"default\", \"help\"}"} =
               Description.new(Keyword.put(CtlFixture.description(), :settings, [{"A", "1"}]))
    end

    @tag verifies: "host-gen-derived"
    test "the checked description derives the script, the ids, string keys and the six settings first" do
      {:ok, d} =
        CtlFixture.description()
        |> Keyword.merge(network: "host", tag: "1.2", docker_run_args: "--rm")
        |> Description.new(:sample_web)

      assert d.script == "sample-ctl"
      assert d.ids == {2060, 2060}
      assert d.otp_app == "sample_web"
      assert d.seeds == [{"phx_host", :hostname}, {"phx_scheme", "http"}, {"tz", :timezone}]

      assert [
               {"PORT", "4000", port_help},
               {"NETWORK", "host", network_help},
               {"IMAGE", "registry.example/acme/sample", image_help},
               {"TAG", "1.2", _},
               {"NAME", "sample", _},
               {"DOCKER_RUN_ARGS", "--rm", run_help},
               {"ADMIN_PORT", "4001", "The admin console's port."}
             ] = d.settings

      assert port_help =~ "web port"
      assert network_help =~ "host shares the host's network"
      assert network_help =~ "docker network to join"
      assert image_help =~ "The image, its tag"
      assert run_help =~ "Extra arguments for `docker run`"

      # A checked map goes to build/2 as it is: its otp_app is not re-derived.
      assert {:ok, script} = Ctl.build(d, nil)
      assert script =~ ~s|def release_bin, do: "/app/bin/sample_web"|
    end

    @tag :tmp_dir
    @tag verifies: "host-gen-app-commands"
    test "an app's commands run once the data directory is set, never in place of a common one",
         %{tmp_dir: dir} do
      source = """
      defmodule Ctl.AppCommands do
        def commands do
          [{"env", "env", "would shadow env"}, {"boom", "boom", "exits 3"}]
        end

        def run("env", _env, _args), do: {:error, "the app's env ran"}
        def run("boom", _env, []), do: {:halt, 3}
      end
      """

      path = Path.join(dir, "app-ctl")
      home = Path.join(dir, "home")
      File.mkdir_p!(home)

      script =
        CtlFixture.description() |> Ctl.generate(source) |> Elixir.Ctl.Script.put_data_dir(home)

      File.write!(path, script)

      assert {_, 3} = System.cmd("elixir", [path, "boom"], stderr_to_stdout: true)

      {out, 0} = System.cmd("elixir", [path, "env", "list"], stderr_to_stdout: true)
      refute out =~ "the app's env ran"
      assert out =~ "PORT="

      {help, 0} = System.cmd("elixir", [path, "help"], stderr_to_stdout: true)
      assert help =~ "Sample's own commands:"
      assert help =~ "exits 3"

      assert {:error, "Ctl.AppCommands must define commands/0"} =
               Ctl.app_commands(
                 "defmodule Ctl.AppCommands do\n  def run(_, _, _), do: :ok\nend\n"
               )

      # run_args/1 comes before DOCKER_RUN_ARGS in the run argv.
      {sample, _} = Macaw.Host.Ctl.Recorder.home!(dir, "sample-ctl")
      {:ok, env} = Elixir.Ctl.Env.load(sample, %{})
      argv = Elixir.Ctl.Docker.run_args(env)

      restart = Enum.find_index(argv, &(&1 == "--restart"))
      assert ["-p", "4001:4001", "--restart", "unless-stopped" | _] = Enum.drop(argv, restart - 2)
    end

    @tag verifies: "host-gen-compare"
    test "compare/2 shows (end of file) on the side whose text has ended" do
      # The committed file goes on past the generated script.
      assert {:error, message} = Ctl.compare("a\nb\n", "a\nb\nextra\n")
      assert message =~ "first at line 3:"
      assert message =~ "generated: (end of file)"
      assert message =~ ~s|committed: "extra"|

      # The committed file stops early.
      assert {:error, message} = Ctl.compare(@script, "#!/usr/bin/env elixir\n")
      assert message =~ "first at line 2:"
      assert message =~ ~s|generated: "#"|
      assert message =~ "committed: (end of file)"

      # Only the last newline differs: each side says how it ends.
      assert {:error, message} = Ctl.compare("a\nb\n", "a\nb")
      assert message =~ "first at line 2:"
      assert message =~ ~s|generated: "b"\n|
      assert message =~ ~s|committed: "b" (no newline at the end of the file)|

      assert {:error, message} = Ctl.compare("a\nb", "a\nb\n")
      assert message =~ ~s|generated: "b" (no newline at the end of the file)|
    end
  end
end
