defmodule Macaw.Host.MixProject do
  use Mix.Project

  @version "0.1.1"

  def project do
    [
      app: :macaw_host,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description:
        "Host glue for deployable Phoenix apps: the literal config.exs on the data volume, " <>
          "generated secrets, release tasks, health, build info, and the <app>-ctl generator.",
      package: [licenses: ["MIT"]],
      docs: [main: "readme", extras: ["README.md"]],
      # Fixtures are inputs to the tests (an app's ctl/app_commands.ex), not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def application,
    do: [mod: {Macaw.Host.Application, []}, extra_applications: [:logger, :crypto, :eex]]

  defp deps do
    [
      {:plug, "~> 1.16", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
