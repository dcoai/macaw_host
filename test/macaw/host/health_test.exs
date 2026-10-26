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
