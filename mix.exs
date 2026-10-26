defmodule Macaw.Host.MixProject do
  use Mix.Project

  @version "0.1.0-dev"

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
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application, do: [extra_applications: [:logger, :crypto]]

  defp deps do
    [
      {:stream_data, "~> 1.1", only: :test}
    ]
  end
end
