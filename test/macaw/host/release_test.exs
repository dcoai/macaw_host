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

    test "bad input is an answer, not a crash", %{tmp_dir: dir} do
      path = Path.join(dir, "config.exs")

      assert {:error, "no setting named nope"} =
               Release.config_command(path, @specs, "RT", ["get", "nope"])

      assert {:error, "must be one of open, closed"} =
               Release.config_command(path, @specs, "RT", ["set", "mode", ":ajar"])

      assert {:error, "usage:" <> _} = Release.config_command(path, @specs, "RT", ["frob"])
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

    test "migrate without a repo configured fails loudly, not silently", %{tmp_dir: _dir} do
      {out, status} = eval("Macaw.Host.Release.migrate(:rt_app_without_repos)", [])
      assert status != 0
      assert out =~ "ecto_repos"
    end
  end
end
