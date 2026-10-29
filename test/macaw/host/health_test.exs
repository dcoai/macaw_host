defmodule Macaw.Host.HealthTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

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
             checks: %{data_dir: :ok, proxies: {:warn, "1 untrusted peer"}}
           }

    assert Health.to_wire(report).checks == %{
             data_dir: "ok",
             proxies: "warning: 1 untrusted peer"
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
    assert {:error, detail} = report.checks.data_dir
    assert detail =~ ~r/a_file\/data is not writable/
    assert Health.to_wire(report).checks.data_dir =~ ~r/^error: .*a_file\/data is not writable/
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
    assert {:error, boom} = report.checks.boom
    assert boom =~ "database gone"
    assert {:error, gone} = report.checks.gone
    assert gone =~ "shutdown"

    assert report.checks.odd ==
             {:error, "check :odd returned :maybe, not :ok, {:warn, detail} or {:error, detail}"}

    assert report.checks.fine == :ok

    wire = Health.to_wire(report).checks
    assert wire.boom == "error: " <> boom

    assert wire.odd ==
             "error: check :odd returned :maybe, not :ok, {:warn, detail} or {:error, detail}"

    assert wire.fine == "ok"
  end

  @tag verifies: "health-detail"
  test "a detail that is not a string is inspected, not a crash" do
    report =
      Health.report(
        db: fn -> {:error, :econnrefused} end,
        peers: fn -> {:warn, %{untrusted: 1}} end
      )

    refute report.healthy
    assert report.checks == %{db: {:error, :econnrefused}, peers: {:warn, %{untrusted: 1}}}

    assert Health.to_wire(report).checks == %{
             db: "error: :econnrefused",
             peers: "warning: %{untrusted: 1}"
           }
  end

  @tag verifies: "health-terms"
  test "healthy is decided from the terms: a warning keeps it healthy, an error doesn't" do
    assert Health.healthy?(%{})
    assert Health.healthy?(%{a: :ok, b: {:warn, "noted"}})
    refute Health.healthy?(%{a: :ok, b: {:warn, "noted"}, c: {:error, "down"}})

    # A warning's or an error's detail is never read: a warn saying "error" is healthy,
    # an error saying "ok" is not.
    assert Health.report(w: fn -> {:warn, "error: everything"} end).healthy
    refute Health.report(e: fn -> {:error, "ok"} end).healthy
    refute Health.report(e: fn -> {:error, :ok} end).healthy
  end

  defp result_gen do
    StreamData.one_of([
      StreamData.constant(:ok),
      StreamData.tuple({StreamData.constant(:warn), StreamData.string(:printable)}),
      StreamData.tuple({StreamData.constant(:error), StreamData.string(:printable)}),
      StreamData.tuple({StreamData.constant(:error), StreamData.atom(:alphanumeric)})
    ])
  end

  @tag verifies: "health-terms"
  property "any mix of results: healthy exactly when none is an error, the report keeping each term" do
    check all(
            results <-
              StreamData.map_of(StreamData.atom(:alphanumeric), result_gen(), max_length: 6),
            max_runs: 200
          ) do
      report = Health.report(Enum.map(results, fn {name, r} -> {name, fn -> r end} end))

      assert report.checks == results
      assert report.healthy == not Enum.any?(Map.values(results), &match?({:error, _}, &1))
      assert report.healthy == Health.healthy?(results)

      for {name, r} <- results do
        wire = Health.to_wire(report).checks[name]

        case r do
          :ok -> assert wire == "ok"
          {:warn, d} -> assert wire == "warning: " <> d
          {:error, d} when is_binary(d) -> assert wire == "error: " <> d
          {:error, d} -> assert wire == "error: " <> inspect(d)
        end
      end
    end
  end

  @tag verifies: "health-string-refused"
  test "a check returning a string is refused, naming the check, never read for its meaning" do
    report =
      Health.report(
        legacy: fn -> "ok" end,
        worded: fn -> "warning: 1 untrusted peer" end,
        fine: fn -> :ok end
      )

    refute report.healthy

    assert report.checks.legacy ==
             {:error,
              ~s(check :legacy returned "ok", not :ok, {:warn, detail} or {:error, detail})}

    assert report.checks.worded ==
             {:error,
              ~s(check :worded returned "warning: 1 untrusted peer", not :ok, {:warn, detail} or {:error, detail})}

    assert Health.to_wire(report).checks.legacy ==
             ~s(error: check :legacy returned "ok", not :ok, {:warn, detail} or {:error, detail})

    # A report whose results are already text (built by hand) is refused at the edge,
    # naming the check, never sent as if it were worded.
    error =
      assert_raise ArgumentError, fn ->
        Health.to_wire(%{healthy: true, checks: %{db: "ok"}})
      end

    assert error.message ==
             ~s(health check :db's result is "ok", not :ok, {:warn, detail} or {:error, detail})

    assert_raise ArgumentError, ~r/not a health report/, fn ->
      Health.to_wire(%{healthy: true})
    end
  end

  @tag verifies: "health-wire"
  test "the edges word the terms as before: the plug's JSON and the release's status line", %{
    tmp_dir: dir
  } do
    report =
      Health.report(
        [
          data_dir: fn -> Health.writable(dir) end,
          proxies: fn -> {:warn, "1 untrusted peer"} end,
          db: fn -> {:error, :econnrefused} end
        ],
        version: "1.0.0"
      )

    wire = %{
      "healthy" => false,
      "version" => "1.0.0",
      "checks" => %{
        "data_dir" => "ok",
        "proxies" => "warning: 1 untrusted peer",
        "db" => "error: :econnrefused"
      }
    }

    served =
      conn(:get, "/healthz")
      |> Health.Plug.call(Health.Plug.init(report: {Map, :new, [report]}))

    assert served.status == 503
    assert JSON.decode!(served.resp_body) == wire

    out = ExUnit.CaptureIO.capture_io(fn -> Macaw.Host.Release.status(report) end)
    assert [line] = String.split(out, "\n", trim: true)
    assert JSON.decode!(line) == wire
    assert line == served.resp_body
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

    assert report.checks.quick == :ok
    assert {report.checks.slow, report.checks.slower} == {:ok, :ok}
    wire = Health.to_wire(report).checks
    assert {:error, "timed out" <> _} = report.checks.stuck
    assert wire.stuck =~ ~r/^error: timed out/
    assert wire.stuck_too =~ ~r/^error: timed out/
    refute report.healthy
    assert elapsed < 1_000
  end

  describe "the plug" do
    def healthy, do: %{healthy: true, checks: %{}}
    def unhealthy, do: %{healthy: false, checks: %{db: {:error, "down"}}}

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

      assert JSON.decode!(served.resp_body) == JSON.decode!(JSON.encode!(Health.to_wire(report)))
      assert JSON.decode!(served.resp_body)["checks"] == %{"data_dir" => "ok"}

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
               fine: :ok,
               broken: {:error, "disk full"},
               noted: {:warn, "1 untrusted peer"}
             }

      assert Health.to_wire(report).checks == %{
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
    test "report/3 maps each name to its result as a term, healthy with no checks, extra merged in" do
      assert Health.report([]) == %{healthy: true, checks: %{}}

      report = Health.report([db: fn -> {:error, "down"} end], version: "1.0.0")

      assert report == %{
               healthy: false,
               version: "1.0.0",
               checks: %{db: {:error, "down"}}
             }

      # Worded only at the edge; every other key as it is.
      assert Health.to_wire(report) == %{
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

      assert report.checks.where == :ok
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
               {:error, "timed out (no answer within the report's 200 ms)"}

      assert Health.to_wire(report).checks.one ==
               "error: timed out (no answer within the report's 200 ms)"

      assert report.checks.two == report.checks.one
    end

    @tag verifies: "host-health-wire"
    test "to_wire/1 words each result and leaves every other key; it refuses text and non-reports" do
      report = %{
        healthy: false,
        version: "1.0.0",
        notes: [%{peer: "10.0.0.9"}],
        checks: %{a: :ok, b: {:warn, "noted"}, c: {:error, "down"}, d: {:error, {:closed, 3}}}
      }

      assert Health.to_wire(report) == %{
               healthy: false,
               version: "1.0.0",
               notes: [%{peer: "10.0.0.9"}],
               checks: %{a: "ok", b: "warning: noted", c: "error: down", d: "error: {:closed, 3}"}
             }

      # Worded once: a worded report is text, and text is refused.
      assert_raise ArgumentError,
                   ~r/^health check :[a-d]'s result is "(ok|warning: noted|error: [^"]+)", not :ok/,
                   fn ->
                     report |> Health.to_wire() |> Health.to_wire()
                   end

      for bad <- [{:warn, "x", "y"}, :error, "warning: noted", nil] do
        assert_raise ArgumentError,
                     ~r/health check :x's result is #{Regex.escape(inspect(bad))}/,
                     fn ->
                       Health.to_wire(%{healthy: true, checks: %{x: bad}})
                     end
      end

      for bad <- [%{checks: %{}}, %{healthy: "yes", checks: %{}}, %{healthy: true, checks: []}] do
        assert_raise ArgumentError, ~r/^not a health report/, fn -> Health.to_wire(bad) end
      end
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
