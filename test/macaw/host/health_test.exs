defmodule Macaw.Host.HealthTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias Macaw.Host.Health

  @moduletag :tmp_dir

  @tag verifies: "health-report"
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

  @tag verifies: "health-writable"
  test "an unwritable data directory is an error naming it; a writable one is ok", %{
    tmp_dir: dir
  } do
    assert Health.writable(dir) == :ok

    # A path under a regular file can't be written by anyone, root included
    # (CI runs as root, which ignores a directory's mode).
    File.write!(Path.join(dir, "a_file"), "")
    unwritable = Path.join([dir, "a_file", "data"])

    assert {:error, why} = Health.writable(unwritable)
    assert why =~ ~r/a_file\/data is not writable/

    report = Health.report(data_dir: fn -> Health.writable(unwritable) end)
    refute report.healthy
    assert report.checks.data_dir =~ ~r/^error: .*a_file\/data is not writable/
  end

  @tag verifies: "health-isolation"
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

  @tag verifies: "health-detail"
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

  @tag verifies: "health-extra"
  test "extra may not set :healthy or :checks: refused at the call" do
    error =
      assert_raise ArgumentError, fn ->
        Health.report([db: fn -> {:error, "down"} end], healthy: true, checks: %{}, build: "x")
      end

    assert error.message =~ ":healthy"
    assert error.message =~ ":checks"
    refute error.message =~ ":build"
  end

  @tag verifies: "health-deadline"
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

    @tag verifies: "health-plug"
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

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 04" do
    @tag verifies: "host-health"
    test "one shape: the report the plug serves is the one every ctl status reads", %{
      tmp_dir: dir
    } do
      report =
        Health.report([data_dir: fn -> Health.writable(dir) end], version: "1.2.0", build: "abc")

      assert Map.keys(report) |> Enum.sort() == [:build, :checks, :healthy, :version]

      served =
        conn(:get, "/healthz")
        |> Health.Plug.call(Health.Plug.init(report: {Map, :new, [report]}))

      assert JSON.decode!(served.resp_body) == JSON.decode!(JSON.encode!(report))

      # What the generated script's status reads from the app's rpc.
      {script, _home} = Macaw.Host.Ctl.Recorder.home!(dir, "sample-ctl")

      Macaw.Host.Ctl.Recorder.install([
        {["docker", "info"], {"ok", 0}},
        {["docker", "container", "inspect", "sample"],
         {~s([{"State":{"Running":true},"Config":{"Image":"x"}}]), 0}},
        {["docker", "exec"], {served.resp_body <> "\n", 0}}
      ])

      {:ok, out} =
        ExUnit.CaptureIO.with_io(fn -> Ctl.dispatch(["status"], %{}, script) end)

      assert out =~ "health:   healthy"
      assert out =~ "version:  1.2.0"
    end

    @tag verifies: "host-health-checks"
    test "a check answers :ok, an error or a warning; writable/1 probes the directory and leaves nothing",
         %{tmp_dir: dir} do
      report =
        Health.report(
          fine: fn -> :ok end,
          broken: fn -> {:error, "disk full"} end,
          noted: fn -> {:warn, "1 untrusted peer"} end
        )

      assert report.checks == %{
               fine: "ok",
               broken: "error: disk full",
               noted: "warning: 1 untrusted peer"
             }

      refute report.healthy
      assert Health.report(noted: fn -> {:warn, %{n: 1}} end).healthy

      assert Health.writable(dir) == :ok
      assert File.ls!(dir) == []

      File.write!(Path.join(dir, "a_file"), "")
      unwritable = Path.join([dir, "a_file", "data"])
      assert {:error, why} = Health.writable(unwritable)
      assert why =~ ~r/^#{Regex.escape(unwritable)} is not writable \(.+\)$/
    end

    @tag verifies: "host-health-report"
    test "report/3 maps each name to its result as text, healthy with no checks, extra merged in" do
      assert Health.report([]) == %{healthy: true, checks: %{}}

      assert Health.report([db: fn -> {:error, "down"} end], version: "1.0.0") == %{
               healthy: false,
               version: "1.0.0",
               checks: %{db: "error: down"}
             }

      # Refused at the call, before any check runs.
      error =
        assert_raise ArgumentError, fn ->
          Health.report([ran: fn -> send(self(), :ran) end], checks: %{})
        end

      assert error.message =~ ":checks"
      refute_received :ran
    end

    @tag verifies: "host-health-isolation"
    test "each check runs in a task of its own under Macaw.Host.Health.Tasks, never in the caller" do
      caller = self()

      report =
        Health.report(
          where: fn ->
            send(caller, {:ran_in, self(), Process.get(:"$ancestors")})
            :ok
          end
        )

      assert report.checks.where == "ok"
      assert_received {:ran_in, pid, ancestors}
      refute pid == caller
      assert Process.whereis(Macaw.Host.Health.Tasks) in ancestors

      started = System.monotonic_time(:millisecond)

      report =
        Health.report(
          [one: fn -> Process.sleep(10_000) end, two: fn -> Process.sleep(10_000) end],
          [],
          deadline: 200
        )

      assert System.monotonic_time(:millisecond) - started < 1_000

      assert report.checks.one ==
               "error: timed out (no answer within the report's 200 ms)"

      assert report.checks.two == report.checks.one
    end

    @tag verifies: "host-health-plug"
    test "the plug answers exactly its path, any method, as JSON; its path can be set" do
      opts = Health.Plug.init(report: {__MODULE__, :unhealthy, []}, path: "/up")

      posted = conn(:post, "/up") |> Health.Plug.call(opts)
      assert posted.status == 503 and posted.halted
      assert ["application/json" <> _] = Plug.Conn.get_resp_header(posted, "content-type")

      assert JSON.decode!(posted.resp_body) == %{
               "healthy" => false,
               "checks" => %{"db" => "error: down"}
             }

      other = conn(:get, "/healthz") |> Health.Plug.call(opts)
      refute other.halted
      assert other.status == nil

      assert Health.Plug.init(report: {__MODULE__, :healthy, []}).path == "/healthz"
      assert_raise KeyError, fn -> Health.Plug.init(path: "/up") end
    end
  end
end
