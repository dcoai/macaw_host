# 04 — Health {#host-health}

`Macaw.Host.Health` gives an app's health in one shape, which every `<app>-ctl status` reads and `Macaw.Host.Health.Plug` serves. Four projects had a health endpoint, each shaped differently, each ctl `status` depending on its shape (macaw_compose#33, #47).

## 1. Checks {#host-health-checks}

A **check** is a function of no arguments (`Macaw.Host.Health.check()`) returning:
- `:ok`: healthy;
- `{:error, detail}`: the app is unhealthy; `detail` a string;
- `{:warn, detail}`: worth showing, not a failure; `detail` a string.

Built in:
- `Macaw.Host.Health.writable/1`: a directory is writable, shown by writing and removing a probe file in it; else `{:error, "<dir> is not writable (<reason>)"}`;
- `Macaw.Host.Health.database/1`: a repo answers `SELECT 1`; else `{:error, <the error's message>}`. Requires `ecto_sql`;
- `Macaw.Host.Health.migrations/1`: every migration has run; else `{:error, "<n> pending"}`. Requires `ecto_sql`.

```test:health-writable
writable/1 of a path under a regular file (unwritable for any user, root included) gives an error naming the path and "is not writable"; of a temporary directory, :ok
```

## 2. The report {#host-health-report}

`Macaw.Host.Health.report/2` runs named checks (a keyword list, name to check) and builds the report:

```elixir
%{healthy: true, version: "1.2.0", build: "3f639e84a704",
  checks: %{database: "ok", migrations: "ok", data_dir: "ok"}}
```

- **`checks`** maps each name to its result as text: `"ok"`, `"error: <detail>"` or `"warning: <detail>"`;
- **`healthy`** is true when every check is `"ok"` or a warning (and with no checks);
- the keyword list `extra` (the version and build, say) is merged into the map.

```test:health-report
a writable directory and a {:warn, "1 untrusted peer"} check, with version and build: exactly %{healthy: true, version: "1.0.0", build: "abc", checks: %{data_dir: "ok", proxies: "warning: 1 untrusted peer"}}
```

### 2.1 A check never crashes the report {#host-health-isolation}

The point of a health check is to answer while something is broken. So **each check runs in its own process,** a task under `Macaw.Host.Health.Tasks` (`Task.Supervisor.async_nolink/2`), never in the caller and never rescued:
- a check that **raises or exits** is reported by its exit reason, `"error: <the formatted exit>"`;
- a check that **returns anything else** is `"error: check returned <the value>"`;
- a check that **doesn't answer in 5 s** is killed and reported `"error: no answer in 5 s"`.

Checks run one after another, each with its own 5 s bound.

```test:health-isolation
checks that raise "database gone", exit(:shutdown), return :maybe and return :ok give an unhealthy report whose results name "database gone", "shutdown", "error: check returned :maybe" and "ok"
```

## 3. The plug {#host-health-plug}

`Macaw.Host.Health.Plug` serves the report as JSON. It is compiled only when Plug is present.
- `Macaw.Host.Health.Plug.init/1` takes `report: {module, function, args}` (required), the report's source, called on each request, and `:path`, `"/healthz"` by default.
- `Macaw.Host.Health.Plug.call/2` answers a request whose path is exactly `:path` (any method): `content-type: application/json`, the report as JSON, **`200` when it is healthy and `503` when not,** and the conn halted. Every other request passes on unchanged, so it works as a route or as a plug in an endpoint.

```test:health-plug
GET /healthz with a healthy report is 200, halted, body {"healthy":true,"checks":{}}; with an unhealthy one 503; GET / passes on, not halted
```
