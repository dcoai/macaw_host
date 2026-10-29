# 04 — Health {#host-health}

`Macaw.Host.Health` gives an app's health in one shape, which every `<app>-ctl status` reads and `Macaw.Host.Health.Plug` serves. Four projects had a health endpoint, each shaped differently, each ctl `status` depending on its shape (macaw_compose#33, #47).

## 1. Checks {#host-health-checks}

A **check** is a function of no arguments (`Macaw.Host.Health.check()`) returning a **term** (`Macaw.Host.Health.result()`), never text:
- `:ok`: healthy;
- `{:error, detail}`: the app is unhealthy;
- `{:warn, detail}`: worth showing, not a failure.

`detail` is a string for people, shown as it is; any other term (`:econnrefused`, a map) is kept as it is and shown `inspect`ed when the report is worded (§2.2), never a crash of the report (macaw_compose#70). **A detail is never read:** what a check means is its tag, `:ok`, `:warn` or `:error`, whatever its detail says (macaw#188, H1).

**A check that returns a string is refused, not guessed from** (§2.1): `"ok"` is not `:ok`, and a `"warning: …"` is not a warning. Before 0.3.0 the report held its results as text and decided `healthy` from that text; an app's own check is written to return the term.

Built in:
- `Macaw.Host.Health.writable/1`: a directory is writable, shown by writing and removing a probe file in it; else `{:error, "<dir> is not writable (<reason>)"}`;

<!-- surfex: health-database -->
- `Macaw.Host.Health.database/1`: a repo answers `SELECT 1`; else `{:error, <the error's message>}`. Requires `ecto_sql`;

<!-- surfex: health-migrations -->
- `Macaw.Host.Health.migrations/1`: every migration has run; else `{:error, "<n> pending"}`. Requires `ecto_sql`.

```test:health-detail
{:error, :econnrefused} and {:warn, %{untrusted: 1}} are kept as those terms in the report's checks, and to_wire/1 words them "error: :econnrefused" and "warning: %{untrusted: 1}"
```

```test:health-writable
writable/1 of a path under a regular file (unwritable for any user, root included) gives an error naming the path and "is not writable"; of a temporary directory, :ok
```

## 2. The report {#host-health-report}

`Macaw.Host.Health.report/3` runs named checks (a keyword list, name to check) and builds the report; its third argument is options, `:deadline` the whole report's in milliseconds (5000 by default, §2.1):

```elixir
%{healthy: true, version: "1.2.0", build: "3f639e84a704",
  checks: %{database: :ok, migrations: :ok, data_dir: {:warn, "nearly full"}}}
```

- **`checks`** maps each name to its result **as a term**: the check's own `:ok`, `{:warn, detail}` or `{:error, detail}`, or the `{:error, detail}` the report gives a check that failed to answer (§2.1). The report holds no text of its own; text is made at the edge (§2.2);
- **`healthy`** is decided from the terms: true when no result is an error, a warning keeping it healthy (and true with no checks). `Macaw.Host.Health.healthy?/1` is that decision, over a map of results;
- the keyword list `extra` (the version and build, say) is merged into the map. **It may not set `:healthy` or `:checks`,** which the report computes: either raises `ArgumentError` naming them, at the call, before any check runs (a coding error in the app, macaw_compose#70).

```test:health-report
a writable directory and a {:warn, "1 untrusted peer"} check, with version and build: exactly %{healthy: true, version: "1.0.0", build: "abc", checks: %{data_dir: :ok, proxies: {:warn, "1 untrusted peer"}}}, worded by to_wire/1 as %{data_dir: "ok", proxies: "warning: 1 untrusted peer"}
```

```test:health-terms
healthy?/1 of %{} and of an :ok and a warn is true, with an error added false; a {:warn, "error: everything"} check keeps the report healthy and an {:error, "ok"} check makes it unhealthy; over 200 generated maps of :ok, warn and error results (string and atom details), the report keeps each term, is healthy exactly when none is an error, and words each as "ok", "warning: <d>" or "error: <d>" (an atom inspected)
```

```test:health-extra
extra with healthy: and checks: raises ArgumentError naming :healthy and :checks, not the allowed :build
```

### 2.1 A check never crashes the report {#host-health-isolation}

The point of a health check is to answer while something is broken. So **each check runs in its own process,** a task under `Macaw.Host.Health.Tasks` (`Task.Supervisor.async_nolink/2`), never in the caller and never rescued:
- a check that **raises or exits** is reported by its exit reason, `{:error, "<the formatted exit>"}`;
- a check that **returns anything else, a string above all, is refused**: `{:error, "check <name> returned <the value>, not :ok, {:warn, detail} or {:error, detail}"}`, the name and the value `inspect`ed (`check :legacy returned "ok", …`). The report is unhealthy and says which check to fix; the value's text is never read for what it might mean;
- **the report answers within its deadline** (5 s unless `:deadline` says otherwise), whatever its checks do. The checks start together, each in its own task; each is waited for only as long as the deadline leaves, and one that hasn't answered by then is killed and reported `{:error, "timed out (no answer within the report's <deadline> ms)"}`.

A slow check therefore can't starve the others of their time, and a report of many hung checks still answers in the one deadline (they ran one after another, 5 s each, before macaw_compose#70).

```test:health-isolation
checks that raise "database gone", exit(:shutdown), return :maybe and return :ok give an unhealthy report whose results are errors naming "database gone" and "shutdown", {:error, "check :odd returned :maybe, not :ok, {:warn, detail} or {:error, detail}"} and :ok
```

```test:health-string-refused
checks returning "ok" and "warning: 1 untrusted peer" beside an :ok one give an unhealthy report, each {:error, "check <name> returned <the string>, not :ok, …"}; to_wire/1 of a hand-built report whose result is "ok" raises ArgumentError "health check :db's result is \"ok\", not :ok, {:warn, detail} or {:error, detail}", and of a map with no :checks "not a health report …"
```

```test:health-deadline
with deadline: 400, a quick check and two 150 ms checks are :ok, two that sleep 10 s are {:error, "timed out …"}, worded "error: timed out …", and the report answers in under a second
```

### 2.2 Worded at the edge {#host-health-wire}

A report is sent as text in two places, and **only there:** `Macaw.Host.Health.Plug`'s JSON (§3) and `Macaw.Host.Release.status/1`'s line, which `<app>-ctl status` prints ([03 §4](03-release.md#host-release-status), [08 §8](08-ctl-commands.md#host-cmd-status)). Both call `Macaw.Host.Health.to_wire/1`, and an app that sends its report another way (its own controller, its own release line) calls it too.

`Macaw.Host.Health.to_wire/1` gives the report with each result worded, **the wire form unchanged since 0.1:** `:ok` as `"ok"`, `{:warn, detail}` as `"warning: <detail>"` and `{:error, detail}` as `"error: <detail>"`, a detail that is not a string `inspect`ed; `healthy` and every other key as they are. It refuses, with `ArgumentError`:
- **a result that isn't a check's term** (a string in a report built by hand, or a report already worded), naming the check: `health check <name>'s result is <the value>, not :ok, {:warn, detail} or {:error, detail}`;
- **a map that isn't a report**, with no `:healthy` boolean or no `:checks` map: `not a health report (…)`.

```test:health-wire
a report of a writable directory, a {:warn, "1 untrusted peer"} and an {:error, :econnrefused} check, with a version, is served by the plug (503) and printed by Release.status/1 as the same JSON, {"healthy":false,"version":"1.0.0","checks":{"data_dir":"ok","proxies":"warning: 1 untrusted peer","db":"error: :econnrefused"}}
```

## 3. The plug {#host-health-plug}

`Macaw.Host.Health.Plug` serves the report as JSON, its wire form (§2.2). It is compiled only when Plug is present.
- `Macaw.Host.Health.Plug.init/1` takes `report: {module, function, args}` (required), the report's source, called on each request, and `:path`, `"/healthz"` by default.
- `Macaw.Host.Health.Plug.call/2` answers a request whose path is exactly `:path` (any method): `content-type: application/json`, the report as JSON (`Macaw.Host.Health.to_wire/1`, encoded), **`200` when it is healthy and `503` when not,** and the conn halted. Every other request passes on unchanged, so it works as a route or as a plug in an endpoint.

```test:health-plug
GET /healthz with a healthy report is 200, halted, body {"healthy":true,"checks":{}}; with an unhealthy one 503; GET / passes on, not halted
```
