defmodule Macaw.Host.HealthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Macaw.Host.Health

  @moduletag :tmp_dir

  test "healthy when every check is ok or a warning", %{tmp_dir: dir} do
    report =
      Health.report(
        [
          data_dir: fn -> Health.writable(dir) end,
          proxies: fn -> {:warn, "1 untrusted peer"} end
        ],
        version: "1.0.0",
        build: "abc"
      )

    assert report == %{
             healthy: true,
             version: "1.0.0",
             build: "abc",
             checks: %{data_dir: "ok", proxies: "warning: 1 untrusted peer"}
           }
  end

  test "an unwritable data directory is an error naming it", %{tmp_dir: dir} do
    # A path under a regular file can't be written by anyone, root included
    # (CI runs as root, which ignores a directory's mode).
    File.write!(Path.join(dir, "a_file"), "")
    unwritable = Path.join([dir, "a_file", "data"])

    report = Health.report(data_dir: fn -> Health.writable(unwritable) end)
    refute report.healthy
    assert report.checks.data_dir =~ ~r/^error: .*a_file\/data is not writable/
  end

  test "a check that raises or exits is reported, and the report still answers" do
    report =
      Health.report(
        boom: fn -> raise "database gone" end,
        gone: fn -> exit(:shutdown) end,
        odd: fn -> :maybe end,
        fine: fn -> :ok end
      )

    refute report.healthy
    assert report.checks.boom =~ "database gone"
    assert report.checks.gone =~ "shutdown"
    assert report.checks.odd == "error: check returned :maybe"
    assert report.checks.fine == "ok"
  end

  test "a detail that is not a string is inspected, not a crash" do
    report =
      Health.report(
        db: fn -> {:error, :econnrefused} end,
        peers: fn -> {:warn, %{untrusted: 1}} end
      )

    refute report.healthy
    assert report.checks.db == "error: :econnrefused"
    assert report.checks.peers == "warning: %{untrusted: 1}"
  end

  test "extra may not set :healthy or :checks: refused at the call" do
    error =
      assert_raise ArgumentError, fn ->
        Health.report([db: fn -> {:error, "down"} end], healthy: true, checks: %{}, build: "x")
      end

    assert error.message =~ ":healthy"
    assert error.message =~ ":checks"
    refute error.message =~ ":build"
  end

  test "the deadline is the whole report's, and a check that misses it is timed out" do
    started = System.monotonic_time(:millisecond)

    report =
      Health.report(
        [
          quick: fn -> :ok end,
          slow: fn -> Process.sleep(150) end,
          slower: fn -> Process.sleep(150) end,
          stuck: fn -> Process.sleep(10_000) end,
          stuck_too: fn -> Process.sleep(10_000) end
        ],
        [],
        deadline: 400
      )

    elapsed = System.monotonic_time(:millisecond) - started

    assert report.checks.quick == "ok"
    assert {report.checks.slow, report.checks.slower} == {"ok", "ok"}
    assert report.checks.stuck =~ ~r/^error: timed out/
    assert report.checks.stuck_too =~ ~r/^error: timed out/
    refute report.healthy
    assert elapsed < 1_000
  end

  describe "the plug" do
    def healthy, do: %{healthy: true, checks: %{}}
    def unhealthy, do: %{healthy: false, checks: %{db: "error: down"}}

    test "200 when healthy, 503 when not, as JSON; other paths pass through" do
      ok =
        conn(:get, "/healthz")
        |> Health.Plug.call(Health.Plug.init(report: {__MODULE__, :healthy, []}))

      assert ok.status == 200 and ok.halted
      assert JSON.decode!(ok.resp_body) == %{"healthy" => true, "checks" => %{}}

      bad =
        conn(:get, "/healthz")
        |> Health.Plug.call(Health.Plug.init(report: {__MODULE__, :unhealthy, []}))

      assert bad.status == 503

      other =
        conn(:get, "/") |> Health.Plug.call(Health.Plug.init(report: {__MODULE__, :healthy, []}))

      refute other.halted
    end
  end
end
