defmodule Macaw.Host.Ctl.LifecycleTest do
  @moduledoc """
  The generated sample script's riskiest commands through `Ctl.dispatch/3`
  with `Macaw.Host.Ctl.Recorder` as `Ctl.World`: `update` replacing the
  script itself (and refusing to), `init --migrate` bringing an older
  setup across, and `shell`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Macaw.Host.Ctl.Recorder

  @moduletag :tmp_dir

  @ref "registry.example/acme/sample:latest"

  @daemon_up {["docker", "info"], {"ok", 0}}
  @image_present {["docker", "image", "inspect", @ref], {"[]", 0}}
  @owned {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "chown"], {"", 0}}
  @pulled {["docker", "pull", @ref], {"pulled\n", 0}}
  @running {["docker", "container", "inspect", "sample"],
            {~s([{"State":{"Running":true,"StartedAt":"2026-10-26T10:00:00Z"},"Config":{"Image":"#{@ref}"}}]),
             0}}

  @id_args ["image", "inspect", "-f", "{{.Id}}", @ref]
  @extract_args ["run", "--rm", @ref, "bin/ctl"]

  defp run(script, argv, sys_env \\ %{}) do
    with_io(fn -> Ctl.dispatch(argv, sys_env, script) end)
  end

  # The image's id before the pull is `before`, after it `later`.
  defp image_ids(before, later) do
    [
      {fn
         "docker", ["image", "inspect", "-f" | _] -> Process.put(:image_id_asked, true) == nil
         _, _ -> false
       end, {before <> "\n", 0}},
      {["docker", "image", "inspect", "-f"], {later <> "\n", 0}}
    ]
  end

  # This host's script: the generated one, naming `home` in `Ctl.Home`.
  defp installed!(tmp_dir) do
    home = Path.join(tmp_dir, "home")
    File.mkdir_p!(Path.join(home, "data"))
    script = Path.join(tmp_dir, "sample-ctl")
    File.write!(script, Ctl.Script.put_data_dir(CtlFixture.script(), home))
    {script, home}
  end

  # A newer script, as an image would carry it: `@data_dir nil`, one change.
  defp newer_script do
    String.replace(
      CtlFixture.script(),
      ~s|def stop_timeout, do: "30"|,
      ~s|def stop_timeout, do: "60"|
    )
  end

  describe "update, when the image carries a different script" do
    @tag verifies: "cmd-update-replace"
    test "writes it with this host's @data_dir, keeps the old one as .bak, hands the restart over",
         %{tmp_dir: tmp_dir} do
      {script, home} = installed!(tmp_dir)
      current = File.read!(script)
      fresh = newer_script()

      Recorder.install(
        [@daemon_up, @pulled, @running, {["docker" | @extract_args], {fresh, 0}}] ++
          image_ids("sha256:old", "sha256:new") ++
          [{[script, "restart"], {"restarted\n", 0}}]
      )

      assert {{:halt, 0}, out} = run(script, ["update"])

      assert Recorder.docker_calls() == [
               ["info"],
               @id_args,
               ["pull", @ref],
               @id_args,
               ["container", "inspect", "sample"],
               @extract_args
             ]

      written = File.read!(script)
      assert written == Ctl.Script.put_data_dir(fresh, home)
      assert {:ok, ^home} = Ctl.Script.data_dir(written)
      assert written =~ ~s|def stop_timeout, do: "60"|
      assert [["  @data_dir " <> _]] = Regex.scan(~r/^\s*@data_dir\b.*$/m, written)
      assert Bitwise.band(File.stat!(script).mode, 0o777) == 0o755

      assert File.read!(script <> ".bak") == current

      assert [{^script, ["restart"], opts}] =
               for({^script, _, _} = call <- Recorder.calls(), do: call)

      assert opts[:env] == [{"SAMPLE_CTL_SELF_UPDATED", "1"}]

      assert out =~ "sample-ctl in #{@ref} differs from this one; updating it"
      assert out =~ "restarted"
      # The new script recreates the container; this one does not.
      refute ["stop", "-t", "30", "sample"] in Recorder.docker_calls()
    end

    @tag verifies: "cmd-update-handed"
    test "the script it hands over to does not update itself again", %{tmp_dir: tmp_dir} do
      {script, _home} = installed!(tmp_dir)
      current = File.read!(script)

      Recorder.install(
        [@daemon_up, @pulled, {["docker" | @extract_args], {newer_script(), 0}}] ++
          image_ids("sha256:same", "sha256:same")
      )

      assert {:ok, _} = run(script, ["update"], %{"SAMPLE_CTL_SELF_UPDATED" => "1"})
      refute @extract_args in Recorder.docker_calls()
      assert File.read!(script) == current
    end
  end

  describe "update refuses to replace the script" do
    setup %{tmp_dir: tmp_dir} do
      {script, home} = installed!(tmp_dir)
      %{script: script, home: home, current: File.read!(script)}
    end

    defp refused(script, current, extract_reply) do
      Recorder.install(
        [@daemon_up, @pulled, {["docker" | @extract_args], extract_reply}] ++
          image_ids("sha256:same", "sha256:same")
      )

      assert {:ok, out} = run(script, ["update"])
      assert @extract_args in Recorder.docker_calls()
      assert File.read!(script) == current
      refute File.exists?(script <> ".bak")
      refute Enum.any?(Recorder.calls(), &match?({^script, _, _}, &1))
      out
    end

    @tag verifies: "cmd-update-refuse"
    test "when the fresh script lacks the line in Ctl.Home, or is no script at all",
         %{script: script, current: current} do
      # The fresh script lacks the @data_dir line.
      fresh = String.replace(newer_script(), "  @data_dir nil\n", "")
      refute fresh =~ ~r/^\s*@data_dir\b/m

      out = refused(script, current, {fresh, 0})

      assert out =~
               "not replacing sample-ctl with the one in #{@ref}: this script has no @data_dir line in Ctl.Home"

      # Its only @data_dir is outside Ctl.Home, as older scripts had it.
      fresh =
        newer_script()
        |> String.replace("  @data_dir nil\n", "")
        |> String.replace(
          "defmodule Ctl.Docker do\n",
          "defmodule Ctl.Docker do\n  @data_dir \"/data\"\n"
        )

      out = refused(script, current, {fresh, 0})
      assert out =~ "this script has no @data_dir line in Ctl.Home"

      # The image has no bin/ctl.
      refused(script, current, {"", 1})

      # bin/ctl prints something that is not this kind of script.
      refused(script, current, {"exec: bin/ctl: not found\n", 0})
    end
  end

  describe "splicing the @data_dir line" do
    @tag verifies: "script-home-only"
    test "an older script whose @data_dir is outside Ctl.Home is never treated as holding one" do
      older = """
      #!/usr/bin/env elixir
      defmodule Ctl.Docker do
        @data_dir "/data"
      end
      """

      assert {:error, "this script has no @data_dir line in Ctl.Home"} =
               Ctl.Script.data_dir(older)

      assert {:error, "this script has no @data_dir line in Ctl.Home"} =
               Ctl.Script.splice(CtlFixture.script(), older)
    end

    @tag verifies: "script-splice-only-home"
    test "only Ctl.Home's line changes, never a same-named attribute elsewhere" do
      fresh =
        String.replace(
          CtlFixture.script(),
          "defmodule Ctl.Docker do\n",
          "defmodule Ctl.Docker do\n  @data_dir \"/data\"\n"
        )

      current = Ctl.Script.put_data_dir(CtlFixture.script(), "/srv/sample")
      assert {:ok, spliced} = Ctl.Script.splice(fresh, current)

      assert {:ok, "/srv/sample"} = Ctl.Script.data_dir(spliced)
      assert spliced =~ "defmodule Ctl.Docker do\n  @data_dir \"/data\"\n"

      assert spliced ==
               String.replace(fresh, "  @data_dir nil\n", "  @data_dir \"/srv/sample\"\n")
    end
  end

  describe "update, when the image's script is this one" do
    @tag verifies: "cmd-update-same"
    test "writes nothing, keeps no .bak, and recreates the container", %{tmp_dir: tmp_dir} do
      {script, home} = installed!(tmp_dir)
      current = File.read!(script)
      data = Path.join(home, "data")

      # The image carries the script as generated: `@data_dir nil`.
      Recorder.install(
        [@daemon_up, @pulled, @running, {["docker" | @extract_args], {CtlFixture.script(), 0}}] ++
          image_ids("sha256:old", "sha256:new") ++
          [@image_present, @owned, {["docker", "run", "-d"], {"id\n", 0}}, {["docker"], {"", 0}}]
      )

      assert {:ok, out} = run(script, ["update"])

      assert File.read!(script) == current
      refute File.exists?(script <> ".bak")
      refute Enum.any?(Recorder.calls(), &match?({^script, _, _}, &1))

      calls = Recorder.docker_calls()
      after_extract = Enum.drop_while(calls, &(&1 != @extract_args))

      assert [
               @extract_args,
               ["info"],
               ["container", "inspect", "sample"],
               ["stop", "-t", "30", "sample"],
               ["rm", "-f", "sample"] | start
             ] =
               after_extract

      assert (["run", "-d", "--name", "sample", "--ulimit", "nofile=65536:65536"] ++
                ["--network", "bridge", "-p", "127.0.0.1:4000:4000", "-v", "#{data}:/data"] ++
                ["-p", "4001:4001", "--restart", "unless-stopped", @ref]) in start

      assert out =~ "new image; recreating sample"
      assert out =~ "sample is running"
    end

    @tag verifies: "cmd-update-unchanged"
    test "with an unchanged image and no container, only says so", %{tmp_dir: tmp_dir} do
      {script, _home} = installed!(tmp_dir)
      current = File.read!(script)

      Recorder.install(
        [@daemon_up, @pulled, {["docker" | @extract_args], {CtlFixture.script(), 0}}] ++
          image_ids("sha256:same", "sha256:same")
      )

      assert {:ok, out} = run(script, ["update"])
      assert out =~ "already on the newest #{@ref}"
      assert File.read!(script) == current
      refute File.exists?(script <> ".bak")
      refute Enum.any?(Recorder.docker_calls(), &match?(["run", "-d" | _], &1))
    end
  end

  describe "init --migrate" do
    setup %{tmp_dir: tmp_dir} do
      old_data = Path.join(tmp_dir, "old-data")
      File.mkdir_p!(old_data)
      File.write!(Path.join(old_data, "sample.db"), "the old database")

      legacy = Path.join(tmp_dir, "sample-env")

      File.write!(legacy, """
      # the older script's settings
      PORT=8080
      DATA=#{old_data}
      PHX_HOST=old.example
      SECRET_KEY_BASE=0123456789abcdef0123456789abcdef
      """)

      script = Recorder.script!(Path.join(tmp_dir, "sample-ctl"))
      %{script: script, legacy: legacy, old_data: old_data, home: Path.join(tmp_dir, "home")}
    end

    @tag verifies: "cmd-migrate"
    test "stops the container, copies the data, carries the effective settings over", %{
      script: script,
      legacy: legacy,
      old_data: old_data,
      home: home
    } do
      data = Path.join(home, "data")

      Recorder.install([
        @daemon_up,
        @image_present,
        @running,
        {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "sh"], {"", 0}},
        {["docker", "run", "--rm", "--user", "2060:2060"],
         {~s({"ok":true,"set":"x","restart":"restart to apply"}\n), 0}},
        {["docker"], {"", 0}},
        {["timedatectl"], {"Europe/Oslo\n", 0}}
      ])

      assert {:ok, out} = run(script, ["init", "--migrate", home])

      # The script names the new directory; the host settings come from the
      # old file (PORT) or the defaults.
      assert {:ok, ^home} = Ctl.Script.data_dir(File.read!(script))
      conf = File.read!(Path.join(home, "sample.conf"))
      assert conf =~ "\nPORT=8080\n"
      assert conf =~ "\nNAME=sample\n"

      calls = Recorder.docker_calls()
      stop = Enum.find_index(calls, &(&1 == ["stop", "-t", "30", "sample"]))

      copy =
        Enum.find_index(
          calls,
          &match?(["run", "--rm", "--user", "0:0", "--entrypoint", "sh" | _], &1)
        )

      assert stop < copy
      assert Enum.at(calls, stop + 1) == ["rm", "-f", "sample"]

      {"docker", copy_argv, copy_opts} =
        Enum.find(
          Recorder.calls(),
          &match?({"docker", ["run", "--rm", "--user", "0:0", "--entrypoint", "sh" | _], _}, &1)
        )

      shell = List.last(copy_argv)

      assert Enum.drop(copy_argv, -1) ==
               ["run", "--rm", "--user", "0:0", "--entrypoint", "sh"] ++
                 ["-v", "#{old_data}:/old:ro", "-v", "#{data}:/data"] ++
                 ["-e", "SECRET_KEY_BASE", @ref, "-c"]

      assert shell =~ "cp -a /old/. /data/"
      assert shell =~ "chown -R 2060:2060 /data"
      refute shell =~ ~r/\b(rm|mv)\b/
      refute Enum.any?(copy_argv, &(&1 =~ "0123456789abcdef"))
      assert copy_opts[:env] == [{"SECRET_KEY_BASE", "0123456789abcdef0123456789abcdef"}]

      # Copied, not moved: the old data is all still there.
      assert File.read!(Path.join(old_data, "sample.db")) == "the old database"

      # PHX_HOST from the old file; TZ, unset there, at the default the old
      # script used: this host's zone.
      sets =
        for {"docker", ["run", "--rm", "--user", "2060:2060" | _], opts} <- Recorder.calls(),
            do: opts[:env]

      assert sets == [
               [{"SAMPLE_CTL_ARGS", ~s(["set","phx_host","\\"old.example\\""])}],
               [{"SAMPLE_CTL_ARGS", ~s(["set","tz","\\"Europe/Oslo\\""])}]
             ]

      refute File.exists?(legacy)
      assert File.exists?(legacy <> ".migrated")
      assert out =~ "was copied, not moved"
    end

    @tag verifies: "cmd-migrate-order"
    test "writes the script and the settings only once the copy has succeeded", %{
      script: script,
      home: home
    } do
      conf = Path.join(home, "sample.conf")
      before = File.read!(script)

      # What the host held when the copy ran.
      copy = fn
        "docker", ["run", "--rm", "--user", "0:0", "--entrypoint", "sh" | _] ->
          Process.put(:at_copy, {File.read!(script), File.exists?(conf)})

        _, _ ->
          false
      end

      Recorder.install([
        @daemon_up,
        @image_present,
        @running,
        {copy, {"", 0}},
        {["docker", "run", "--rm", "--user", "2060:2060"],
         {~s({"ok":true,"set":"x","restart":"restart to apply"}\n), 0}},
        {["docker"], {"", 0}},
        {["timedatectl"], {"Europe/Oslo\n", 0}}
      ])

      assert {:ok, _} = run(script, ["init", "--migrate", home])

      assert [
               ["info"],
               ["image", "inspect", @ref],
               ["info"],
               ["container", "inspect", "sample"],
               ["stop", "-t", "30", "sample"],
               ["rm", "-f", "sample"],
               ["run", "--rm", "--user", "0:0", "--entrypoint", "sh" | _] | _
             ] = Recorder.docker_calls()

      # At the copy, nothing was written yet; after it, both were.
      assert Process.get(:at_copy) == {before, false}
      assert {:ok, ^home} = Ctl.Script.data_dir(File.read!(script))
      assert File.read!(conf) =~ "\nPORT=8080\n"
    end

    @tag verifies: "cmd-migrate-copy-fails"
    test "a failed copy leaves the script and the settings untouched", %{
      script: script,
      legacy: legacy,
      home: home
    } do
      before = File.read!(script)

      Recorder.install([
        @daemon_up,
        @image_present,
        @running,
        {["docker", "run", "--rm", "--user", "0:0", "--entrypoint", "sh"],
         {"cp: cannot stat '/old/.': No such file\n", 1}},
        {["docker"], {"", 0}}
      ])

      assert {{:error, message}, _} = run(script, ["init", "--migrate", home])
      assert message =~ "could not copy"

      assert File.read!(script) == before
      assert {:ok, nil} = Ctl.Script.data_dir(File.read!(script))
      refute File.exists?(Path.join(home, "sample.conf"))
      assert File.exists?(legacy)

      refute Enum.any?(
               Recorder.docker_calls(),
               &match?(["run", "--rm", "--user", "2060:2060" | _], &1)
             )
    end

    @tag verifies: "cmd-migrate-inside"
    test "refuses a data directory inside the old data", %{script: script, old_data: old_data} do
      Recorder.install([@daemon_up, @image_present, {["docker"], {"", 0}}])

      assert {{:error, message}, _} =
               run(script, ["init", "--migrate", Path.join(old_data, "new")])

      assert message =~ "is inside the old data at #{old_data}"
      refute Enum.any?(Recorder.docker_calls(), &match?(["run" | _], &1))
    end

    @tag verifies: "cmd-migrate-nothing"
    test "with nothing to migrate, says so", %{tmp_dir: tmp_dir} do
      script =
        Recorder.script!(
          Path.join([tmp_dir, "elsewhere", "sample-ctl"])
          |> tap(&File.mkdir_p!(Path.dirname(&1)))
        )

      Recorder.install()

      assert {{:error, "nothing to migrate: there is no " <> _}, _} =
               run(script, ["init", "--migrate", Path.join(tmp_dir, "home")])
    end
  end

  describe "shell" do
    @tag verifies: "cmd-shell"
    test "opens /bin/sh in the running container, attached to the terminal; refused when stopped",
         %{tmp_dir: tmp_dir} do
      {script, _home} = installed!(tmp_dir)
      Recorder.install([@daemon_up, @running, {["docker", "exec"], {"", 0}}])

      assert {:ok, _} = run(script, ["shell"])

      assert List.last(Recorder.calls()) ==
               {"docker", ["exec", "-it", "sample", "/bin/sh"], [tty: true]}

      # The container is not running.
      Recorder.install([@daemon_up])

      assert {{:error, "sample is not running — ./sample-ctl start"}, _} = run(script, ["shell"])
      refute Enum.any?(Recorder.docker_calls(), &match?(["exec" | _], &1))
    end
  end
end
