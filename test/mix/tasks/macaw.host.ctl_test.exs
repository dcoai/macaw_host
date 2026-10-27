defmodule Mix.Tasks.Macaw.Host.CtlTest do
  @moduledoc """
  `mix macaw.host.ctl` in a sample project: it writes the script, `--check`
  passes on what it wrote and fails, naming the line, once it is edited.
  Not async: a Mix project is pushed and the working directory changes.
  """

  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  setup do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(shell) end)
  end

  @tag verifies: "gen-task"
  test "writes the script, then --check passes, then fails on an edited file", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "ctl"))
    File.write!(Path.join(dir, "ctl/app_commands.ex"), CtlFixture.app_commands())

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MacawHostCtlTaskSample.MixProject do
      use Mix.Project

      def project do
        [app: :sample, version: "0.1.0", ctl: #{inspect(CtlFixture.description())}]
      end
    end
    """)

    Mix.Project.in_project(:sample, dir, fn _module ->
      Mix.Task.rerun("macaw.host.ctl", [])
      assert_received {:mix_shell, :info, ["wrote container/sample-ctl"]}

      script = File.read!("container/sample-ctl")
      assert script == CtlFixture.script()
      assert Bitwise.band(File.stat!("container/sample-ctl").mode, 0o777) == 0o755

      Mix.Task.rerun("macaw.host.ctl", ["--check"])
      assert_received {:mix_shell, :info, ["container/sample-ctl is up to date"]}

      File.write!(
        "container/sample-ctl",
        String.replace(script, "nofile=65536:65536", "nofile=1024")
      )

      error =
        assert_raise Mix.Error, fn -> Mix.Task.rerun("macaw.host.ctl", ["--check"]) end

      assert error.message =~ "container/sample-ctl: the committed script differs"
      assert error.message =~ "nofile=1024"
      assert error.message =~ "Run mix macaw.host.ctl to regenerate it."
    end)
  end

  @tag verifies: "gen-task-no-ctl"
  test "a project without :ctl is told so", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MacawHostCtlTaskBare.MixProject do
      use Mix.Project
      def project, do: [app: :bare, version: "0.1.0"]
    end
    """)

    Mix.Project.in_project(:bare, dir, fn _module ->
      assert_raise Mix.Error, ~r/mix.exs has no :ctl key/, fn ->
        Mix.Task.rerun("macaw.host.ctl", [])
      end
    end)
  end

  @tag verifies: "host-gen-task"
  test "reads :ctl with the project's :app, writes to :output, and names every fault", %{
    tmp_dir: dir
  } do
    description =
      CtlFixture.description()
      |> Keyword.drop([:settings])
      |> Keyword.merge(app_commands: false, output: "out/deep/the-ctl")

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule MacawHostCtlTaskOptions.MixProject do
      use Mix.Project

      def project do
        [app: :sample_web, version: "0.1.0", ctl: #{inspect(description)}]
      end
    end
    """)

    Mix.Project.in_project(:sample_web, dir, fn _module ->
      Mix.Task.rerun("macaw.host.ctl", [])
      assert_received {:mix_shell, :info, ["wrote out/deep/the-ctl"]}

      script = File.read!("out/deep/the-ctl")
      assert Bitwise.band(File.stat!("out/deep/the-ctl").mode, 0o777) == 0o755
      assert script =~ ~s|def release_bin, do: "/app/bin/sample_web"|
      assert script =~ "def commands, do: []"

      assert_raise Mix.Error, "usage: mix macaw.host.ctl [--check]", fn ->
        Mix.Task.rerun("macaw.host.ctl", ["--frob"])
      end

      assert_raise Mix.Error, "usage: mix macaw.host.ctl [--check]", fn ->
        Mix.Task.rerun("macaw.host.ctl", ["extra"])
      end
    end)

    # An app commands file that can't be read, and an invalid description.
    other = Path.join(dir, "other")
    File.mkdir_p!(other)

    File.write!(Path.join(other, "mix.exs"), """
    defmodule MacawHostCtlTaskFaults.MixProject do
      use Mix.Project

      def project do
        [app: :sample, version: "0.1.0", ctl: #{inspect(CtlFixture.description())}]
      end
    end
    """)

    Mix.Project.in_project(:sample, other, fn _module ->
      assert_raise Mix.Error,
                   "cannot read the app commands ctl/app_commands.ex: no such file or directory",
                   fn -> Mix.Task.rerun("macaw.host.ctl", []) end
    end)

    bad = Path.join(dir, "bad")
    File.mkdir_p!(bad)

    File.write!(Path.join(bad, "mix.exs"), """
    defmodule MacawHostCtlTaskBad.MixProject do
      use Mix.Project

      def project do
        [app: :sample_bad, version: "0.1.0", ctl: #{inspect(Keyword.put(CtlFixture.description(), :uid, "app"))}]
      end
    end
    """)

    Mix.Project.in_project(:sample_bad, bad, fn _module ->
      assert_raise Mix.Error, ~s|:ctl :uid must be "uid:gid", both numbers, not "app"|, fn ->
        Mix.Task.rerun("macaw.host.ctl", [])
      end
    end)
  end
end
