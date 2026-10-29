defmodule Macaw.Host.MixProject do
  use Mix.Project

  @source_url "https://github.com/dcoai/macaw_host"
  @version "0.2.1"

  def project do
    [
      app: :macaw_host,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      description:
        "Host glue for deployable Phoenix apps: the literal config.exs on the data volume, " <>
          "generated secrets, release tasks, health, build info, and the <app>-ctl generator.",
      source_url: @source_url,
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}",
        logo: "brand/logo/macaw_scarlet.svg",
        assets: %{"brand/logo" => "brand/logo"}
      ],
      # Fixtures are inputs to the tests (an app's ctl/app_commands.ex), not tests.
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def application,
    do: [mod: {Macaw.Host.Application, []}, extra_applications: [:logger, :crypto, :eex]]

  # The test repo for the database checks (test/support) is compiled in test only.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Published on Hex from its public home, mirrored from GitLab (dco-tek/macaw/macaw#155).
  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "https://hexdocs.pm/macaw_host/changelog.html"
      },
      files: ~w(lib priv spec mix.exs README.md LICENSE CHANGELOG.md .formatter.exs)
    ]
  end

  defp deps do
    [
      {:plug, "~> 1.16", optional: true},
      {:ecto_sql, "~> 3.12", optional: true},
      {:stream_data, "~> 1.1", only: :test},
      # A real repo for the database checks (Health.database/1, migrations/1, Release.migrate/1).
      {:ecto_sqlite3, "~> 0.17", only: :test},
      # Docs for Hex (macaw_compose#155); dev only.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # Spec, tests and code kept aligned (macaw_compose spec/00 §4.1); dev/test only.
      {:surfex, "~> 0.10.0", only: [:dev, :test], runtime: false}
    ]
  end
end
