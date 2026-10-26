ExUnit.start()

defmodule CtlFixture do
  @moduledoc """
  The sample app the `<app>-ctl` generator's tests use: its description, its
  own commands (test/fixtures/ctl/app_commands.ex), and the script made of
  them.

  The script's modules (`Ctl`, `Ctl.Env` …) are global to the VM, so it is
  generated and loaded exactly once, here, before any test runs: every test
  then shares the same modules, async or not, and varies the host through
  settings and the environment rather than by loading a second script (which
  would redefine the modules under a running test). What needs a whole
  program, `main/1` and the halt, runs the script in its own `elixir`
  process instead.
  """

  def description do
    [
      name: "sample",
      image: "registry.example/acme/sample",
      env_prefix: "SAMPLE",
      release: "Sample.Release",
      uid: "2060:2060",
      port: 4000,
      settings: [{"ADMIN_PORT", "4001", "The admin console's port."}],
      seeds: [phx_host: :hostname, phx_scheme: "http", tz: :timezone],
      migrate_keys: [{"PHX_HOST", "phx_host", :hostname}, {"TZ", "tz", :timezone}]
    ]
  end

  def app_commands, do: File.read!(Path.expand("fixtures/ctl/app_commands.ex", __DIR__))

  def script, do: Macaw.Host.Ctl.generate(description(), app_commands())

  def path, do: Path.expand("../tmp/ctl/sample-ctl", __DIR__)
end

File.mkdir_p!(Path.dirname(CtlFixture.path()))
File.write!(CtlFixture.path(), CtlFixture.script())
Macaw.Host.Ctl.Recorder.load!(CtlFixture.path())
