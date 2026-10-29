defmodule Macaw.Host.DatabaseTest do
  @moduledoc """
  The checks and the release function that need a database, against a real
  one: `Macaw.Host.TestRepo`, SQLite in the test's temporary directory, with
  its one migration in `test/support/repo/migrations`. Not async: the repo
  and its configuration are global.
  """

  use ExUnit.Case, async: false

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  alias Macaw.Host.{Health, Release, TestRepo}
  alias Macaw.Host.TestRepo.Probes

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    TestRepo.configure(dir)
    on_exit(fn -> Application.delete_env(:macaw_host, TestRepo) end)
    :ok
  end

  @tag verifies: "health-database"
  test "database/1 is :ok when the repo answers SELECT 1, else the error's message", %{
    tmp_dir: dir
  } do
    start_supervised!(TestRepo)
    assert Health.database(TestRepo) == :ok
    stop_supervised!(TestRepo)

    # A file that isn't a database: the repo can't connect, and the query's error is the answer.
    File.write!(Path.join(dir, "test.db"), String.duplicate("not a database ", 100))
    start_supervised!({TestRepo, queue_target: 50, queue_interval: 100})

    capture_log(fn ->
      assert {:error, message} = Health.database(TestRepo)
      assert message =~ "connection not available"
    end)
  end

  @tag verifies: "health-migrations"
  test "migrations/1 counts the pending migrations, and is :ok once every one has run" do
    start_supervised!(TestRepo)
    assert Health.migrations(TestRepo) == {:error, "1 pending"}

    # Run as a module, not from the file: Release.migrate/1's test compiles the file (see
    # TestRepo.Probes).
    capture_log(fn ->
      Ecto.Migrator.run(TestRepo, [{Probes.version(), Probes}], :up, all: true)
    end)

    assert Health.migrations(TestRepo) == :ok
  end

  @tag verifies: "release-migrate-runs"
  test "migrate/1 runs every migration of the app's repos, then emits ok and migrated" do
    Application.put_env(:rt_db_app, :ecto_repos, [TestRepo])
    on_exit(fn -> Application.delete_env(:rt_db_app, :ecto_repos) end)

    out =
      capture_log(fn ->
        send(self(), {:out, capture_io(fn -> Release.migrate(:rt_db_app) end)})
      end)

    refute out =~ "create table probes"
    assert_received {:out, json}

    assert JSON.decode!(json) == %{
             "ok" => true,
             "migrated" => true,
             "versions" => [20_260_101_000_000]
           }

    # Only what migrating needed was started: the repo is stopped again, and the table is there.
    refute Process.whereis(TestRepo)
    start_supervised!(TestRepo)
    assert Health.migrations(TestRepo) == :ok
    assert {:ok, _} = Ecto.Adapters.SQL.query(TestRepo, "SELECT name FROM probes", [])
  end

  # The release runs migrate in a VM of its own, whose stdout is the answer: run it so, and
  # read nothing but stdout.
  @tag verifies: "release-migrate-quiet"
  test "in a VM of its own, migrate prints one line, its answer, with the versions it applied",
       %{tmp_dir: dir} do
    paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))

    # SQLite: the migrator opens two connections at once, and in WAL mode each sets the
    # journal as it opens, which can find the file locked (a server database never does),
    # so the child's repo keeps a rollback journal.
    code = """
    Application.put_env(:rt_db_app, :ecto_repos, [Macaw.Host.TestRepo])
    Macaw.Host.TestRepo.configure(#{inspect(dir)})
    config = Application.fetch_env!(:macaw_host, Macaw.Host.TestRepo)
    Application.put_env(:macaw_host, Macaw.Host.TestRepo, config ++ [journal_mode: :delete, busy_timeout: 10_000])
    Macaw.Host.Release.migrate(:rt_db_app)
    """

    run = fn -> System.cmd("elixir", Enum.flat_map(paths, &["-pa", &1]) ++ ["-e", code]) end

    assert {first, 0} = run.()
    assert [line] = String.split(first, "\n", trim: true)

    assert JSON.decode!(line) == %{
             "ok" => true,
             "migrated" => true,
             "versions" => [20_260_101_000_000]
           }

    assert {again, 0} = run.()
    assert JSON.decode!(again) == %{"ok" => true, "migrated" => true, "versions" => []}
  end
end
