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
    test "parses, and is the same every time" do
      assert {:__block__, _, _} = Code.string_to_quoted!(@script)
      assert Ctl.generate(CtlFixture.description(), CtlFixture.app_commands()) == @script
    end

    test "starts with the version guard, before any module" do
      assert "#!/usr/bin/env elixir\n" <> _ = @script
      {:__block__, _, [first, second | _]} = Code.string_to_quoted!(@script)

      assert {:unless, _, [condition, _]} = first
      assert Macro.to_string(condition) =~ ~s|Version.match?(System.version(), ">= 1.18.0")|
      assert {:defmodule, _, [{:__aliases__, _, [:Ctl, :Home]}, _]} = second
    end

    test "has exactly one @data_dir line, nil, inside Ctl.Home" do
      lines = Regex.scan(~r/^\s*@data_dir\b.*$/m, @script)
      assert [["  @data_dir nil"]] = lines

      [home] = Regex.run(~r/^defmodule Ctl\.Home do\n.*?^end$/ms, @script)
      assert home =~ "\n  @data_dir nil\n"
    end

    test "carries the app's commands and the description's values" do
      assert @script =~ "defmodule Ctl.AppCommands do"
      assert @script =~ ~s|def prefix, do: "SAMPLE"|
      assert @script =~ ~s|def ids, do: {2060, 2060}|
      assert @script =~ ~s|def release_bin, do: "/app/bin/sample"|
    end

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

    test "with no app commands of its own" do
      script = Ctl.generate(CtlFixture.description(), nil)
      assert script =~ "def commands, do: []"
      assert {:__block__, _, _} = Code.string_to_quoted!(script)
    end
  end

  describe "run as a program, in its own elixir process" do
    test "help lists the common commands and the app's, and exits 0" do
      {out, status} = System.cmd("elixir", [CtlFixture.path(), "help"], stderr_to_stdout: true)

      assert status == 0
      refute out =~ "warning"
      assert out =~ "./sample-ctl config list | get KEY | set KEY VALUE | unset KEY"
      assert out =~ "Sample's own commands:"
      assert out =~ "./sample-ctl reset-password USER"
      assert out =~ "ADMIN_PORT        4001"
    end

    @tag :tmp_dir
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

    test "an unknown command exits 1 with the message on stderr" do
      {out, status} = System.cmd("elixir", [CtlFixture.path(), "frob"], stderr_to_stdout: true)

      assert status == 1
      assert out =~ "unknown command: frob"
    end
  end

  describe "the description" do
    test "names every missing key" do
      assert {:error, ":ctl is missing :release, :uid"} =
               CtlFixture.description() |> Keyword.drop([:release, :uid]) |> Description.new()
    end

    test "refuses a key it does not know" do
      assert {:error, ":ctl has unknown keys: :prot"} =
               Description.new(CtlFixture.description() ++ [prot: 1])
    end

    test "names a value of the wrong shape" do
      assert {:error, ":ctl :uid must be \"uid:gid\", both numbers, not \"app\""} =
               Description.new(Keyword.put(CtlFixture.description(), :uid, "app"))

      assert {:error, ":ctl :settings cannot redefine PORT, which every script has"} =
               Description.new(
                 Keyword.put(CtlFixture.description(), :settings, [{"PORT", "1", ""}])
               )
    end

    test "a project without :ctl is told so" do
      assert {:error, "mix.exs has no :ctl key" <> _} = Description.new(nil)
    end

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

    test "generate/2 raises naming the fault" do
      assert_raise ArgumentError, ":ctl is missing :port", fn ->
        Ctl.generate(Keyword.delete(CtlFixture.description(), :port), nil)
      end
    end
  end

  describe "the app commands" do
    test "must define Ctl.AppCommands with commands/0 and run/3" do
      assert {:error, "the app commands file must define Ctl.AppCommands"} =
               Ctl.app_commands("defmodule Ctl.AppCommands.Helpers do\nend\n")

      assert {:error, "the app commands file may define only Ctl.AppCommands, not Other"} =
               Ctl.app_commands("defmodule Other do\nend\n")

      assert {:error, "Ctl.AppCommands must define run/3"} =
               Ctl.app_commands("defmodule Ctl.AppCommands do\n  def commands, do: []\nend\n")
    end

    test "may not replace a generic module or set @data_dir" do
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
    end

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

      # A submodule belongs inside the module, not beside it.
      assert {:error,
              "the app commands file may hold only the Ctl.AppCommands module; " <>
                "line 48 is outside it: defmodule Ctl.AppCommands.Helpers" <> _} =
               Ctl.app_commands(
                 CtlFixture.app_commands() <> "\ndefmodule Ctl.AppCommands.Helpers do\nend\n"
               )

      nested =
        String.replace(
          CtlFixture.app_commands(),
          "  def commands do",
          "  defmodule Helpers do\n    def x, do: 1\n  end\n\n  def commands do"
        )

      assert {:ok, _} = Ctl.app_commands(nested)
    end

    test "must parse" do
      assert {:error, "Ctl.AppCommands does not parse: line 1" <> _} =
               Ctl.app_commands("defmodule Ctl.AppCommands do\n")
    end
  end

  describe "compare/2, for --check" do
    test "the same text passes" do
      assert :ok = Ctl.compare(@script, @script)
    end

    test "names the first line that differs" do
      edited =
        String.replace(@script, "def stop_timeout, do: \"30\"", "def stop_timeout, do: \"5\"")

      line = edited |> String.split("\n") |> Enum.find_index(&(&1 =~ ~s|do: "5"|)) |> Kernel.+(1)

      assert {:error, message} = Ctl.compare(@script, edited)
      assert message =~ "first at line #{line}:"
      assert message =~ ~s|generated: "  def stop_timeout, do: \\"30\\""|
      assert message =~ ~s|committed: "  def stop_timeout, do: \\"5\\""|
    end

    test "a truncated file differs at its end" do
      assert {:error, message} = Ctl.compare(@script, "#!/usr/bin/env elixir\n")
      assert message =~ "first at line 2:"
    end
  end
end
