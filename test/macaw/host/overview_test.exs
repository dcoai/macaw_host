defmodule Macaw.Host.OverviewTest do
  @moduledoc """
  What spec 00 §3 says of the library as a whole: its Elixir, its
  dependencies by kind, and the one process its application starts.
  """

  use ExUnit.Case, async: true

  @tag verifies: "host-dependencies"
  test "Elixir 1.18 or newer, the standard library at run time, optional plug and ecto_sql, the rest dev or test only, one Task.Supervisor" do
    config = Mix.Project.config()
    assert config[:elixir] == "~> 1.18"
    assert Version.match?("1.18.0", config[:elixir])
    refute Version.match?("1.17.3", config[:elixir])

    # Run time: OTP and Elixir's own applications only.
    assert Macaw.Host.MixProject.application()[:extra_applications] == [:logger, :crypto, :eex]

    by_kind =
      config[:deps]
      |> Enum.map(fn {name, _requirement, opts} -> {name, opts} end)
      |> Enum.group_by(
        fn {_name, opts} -> {opts[:optional] == true, opts[:only]} end,
        &elem(&1, 0)
      )

    assert Enum.sort(by_kind[{true, nil}]) == [:ecto_sql, :plug]
    assert by_kind[{false, [:dev, :test]}] == [:surfex]
    assert Enum.sort(by_kind[{false, :test}]) == [:ecto_sqlite3, :stream_data]

    assert Map.keys(by_kind) |> Enum.sort() == [
             {false, :test},
             {false, [:dev, :test]},
             {true, nil}
           ]

    # No JSON library: JSON is Elixir's own.
    assert {:module, JSON} = Code.ensure_loaded(JSON)
    assert :application.get_application(JSON) == {:ok, :elixir}

    # The application starts one process, the Task.Supervisor health checks run under.
    assert [{_id, pid, :supervisor, [Task.Supervisor]}] =
             Supervisor.which_children(Macaw.Host.Supervisor)

    assert Process.whereis(Macaw.Host.Health.Tasks) == pid
  end
end
