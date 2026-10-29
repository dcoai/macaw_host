# 03 — Release entry points {#host-release}

`Macaw.Host.Release` is the release side of an app's `<app>-ctl`: functions the script runs as `bin/<app> eval` (in a throwaway container, so they work with the app stopped) or `bin/<app> rpc` (asking the running app). Seven projects had their own release module; this is the common core, the protocol macaw's release module used, generalized (macaw_compose#33, #47).

An app's release module delegates to it:

```elixir
defmodule MyApp.Release do
  def migrate, do: Macaw.Host.Release.migrate(:my_app)
  def config, do: Macaw.Host.Release.config(:my_app, MyApp.Settings.specs(), "MY_APP")
  def status, do: Macaw.Host.Release.status(MyApp.Health.report())
end
```

The script calls `<Release>.config()` and `<Release>.status()` by name ([07 §6](07-ctl-script.md#host-script-docker)), so those two are the module's required functions; an app adds its own (a password reset, say) on the same protocol.

## 1. The protocol {#host-release-protocol}

The same for every app:
- **arguments** arrive as a JSON array of strings in the env var `<PREFIX>_CTL_ARGS`, **never on a command line** `ps` can show; a password in `<PREFIX>_CTL_PASSWORD`;
- **output** is **one JSON object per line** on stdout, for the script to read;
- **a failure** is one line on stderr and exit status 1;
- **nothing typed becomes an atom.** Names are matched as strings: `String.to_existing_atom/1` fails under `eval` for atoms the release never loaded, though tests pass, the bug class this module exists to rule out.

The functions of the protocol:
- `Macaw.Host.Release.ctl_args!/1` is the arguments in `<PREFIX>_CTL_ARGS`; when the variable is missing, isn't JSON, isn't an array or holds a non-string, it fails (§1.1) with `"<PREFIX>_CTL_ARGS must be a JSON array of strings"`;
- `Macaw.Host.Release.ctl_password/1` is the password in `<PREFIX>_CTL_PASSWORD`, or `nil`;
- `Macaw.Host.Release.emit/1` prints one map as a JSON line on stdout.

```test:release-eval-atoms
in a fresh VM with only the library's code paths (as bin/<app> eval runs), config set then get of a setting whose name was never loaded as an atom succeeds: the output carries "set":"<name>", then "value":"42"
```

```test:release-bad-args
in a fresh VM, RT_CTL_ARGS "not json" and "[1, 2]" each give exactly "RT_CTL_ARGS must be a JSON array of strings\n" and exit status 1
```

### 1.1 Failing {#host-release-fail}

`Macaw.Host.Release.fail/1` prints its message as one line on stderr and halts the VM with status 1.

## 2. Migrating {#host-release-migrate}

<!-- surfex: release-migrate-runs -->
`Macaw.Host.Release.migrate/1` runs every migration of each of the app's repos (its `:ecto_repos`), up, starting only what migrating needs (`Ecto.Migrator.with_repo/2`), then emits `{"ok": true, "migrated": true, "versions": [...]}`, **the versions it applied,** in order: none when the database is current. **Ecto's own log is off** (`log: false`, `log_migrations_sql: false`, `log_migrator_sql: false`), so what migrating did reaches the caller as data, never as log text before the answer, and the answer is the one line on stdout (§1).

- It **requires `ecto_sql`;** without it, it fails with `"migrate needs ecto_sql, which <app> does not depend on"`.
- An app without `:ecto_repos` configured fails loudly (raising, naming `ecto_repos`), never silently.

```test:release-migrate-quiet
in a VM of its own, migrate of a repo with one pending migration prints exactly one line on stdout, {"ok":true,"migrated":true,"versions":[<the version>]}, and a second run answers versions []
```

```test:release-migrate-no-repos
in a fresh VM, migrate of an app with no :ecto_repos exits non-zero with output naming ecto_repos
```

## 3. The config commands {#host-release-config}

`Macaw.Host.Release.config/3` is `<app>-ctl config`, over the app's literal `config.exs` at `<data_dir>/config.exs` (`:data_dir` from the app's environment, after loading the app). It reads the arguments with `ctl_args!/1`, runs them with `config_command/4`, then emits each answer object or fails with the message.

`Macaw.Host.Release.config_command/5` is the commands, pure apart from the file and its fifth argument, the environment (`System.get_env/0` by default): `{:ok, objects}` or `{:error, message}`. It reads the file with `Macaw.Host.Config.read_file/1`: a missing file is empty, and **a file with faults is the error, every fault on one line,** so `config/3` answers it as the protocol says, one stderr line and exit status 1, never a stack trace (macaw_compose#70). **`reset` alone doesn't read it first:** a file that no longer parses is what it exists to repair.

| Arguments | Answer |
|---|---|
| `["list"]` | one object per declared setting, in declared order: `{name, value, source}` |
| `["get", NAME]` | that setting's `{name, value, source}`, or `"no setting named NAME"` |
| `["set", NAME, VALUE]` | `Macaw.Host.Config.put!/4` ([01 §6](01-config.md#host-config-edit)), then `{"ok": true, "set": NAME, "restart": "restart to apply"}`, or its error |
| `["unset", NAME]` | `Macaw.Host.Config.delete!/3`, then `{"ok": true, "unset": NAME, "restart": "restart to apply"}`, or its error |
| `["reset"]` | `Macaw.Host.Config.reset!/1` ([01 §6](01-config.md#host-config-edit)): a file that no longer parses set aside as `config.exs.broken` and an empty one written, then `{"ok": true, "reset": true, "set_aside": "config.exs.broken", "restart": "restart to apply"}`, or its error (no file, a file that parses, a `config.exs.broken` already there) |
| anything else | `"usage: config list \| get NAME \| set NAME VALUE \| unset NAME \| reset"` |

- **`list` and `get` show each setting as the app would load it,** through `Macaw.Host.Config.resolve_setting/4`, the path `Macaw.Host.Config.load!/3` takes ([01 §3](01-config.md#host-config-resolve)): an env var cast by its type, a file key written as an atom or a string, else the default.
- **A setting's `source`** is `"env <VAR>"` when its env var is set (even empty), else `"config.exs"` when the file has it, else `"default"`.
- **Its `value` is the resolved, typed value, shown:** `Macaw.Host.Config.mask/2` of it, so a secret is masked ([01 §5.1](01-config.md#host-config-mask)), a `{:custom, module}` value is shown by its `show/1` ([01 §2](01-config.md#host-config-types)), and anything else `inspect`ed (`":closed"`, `"8443"` for a port, from the file or from an env var `" 8443 "`).
- **A value that doesn't fit its type** is shown as found (masked likewise) with a fourth key, `fault`, the fault the app's boot would raise (`"RT_MODE: must be one of open, closed"`). The script prints it as invalid ([08 §4](08-ctl-commands.md#host-cmd-config)).
- **Every edit answers "restart to apply":** nothing restarts on its own.
- `VALUE` is a literal as typed: a string value is typed with its quotes (`"\"Europe/Oslo\""`).

```test:release-config-cycle
set port "8443", get port (value "8443", source "config.exs"), list (mode ":closed" from "default"), unset port, get port (source "default")
```

```test:release-config-secret
after set smtp_password "\"correct-horse-battery\"", get smtp_password shows "set (…tery)"
```

```test:release-config-custom
with an auth setting of {:custom, SignInBlock}: set auth to a block holding a 28-character password, then get shows "set (…aple)" and no list value holds the password; a file auth that isn't a block gets "(not a sign-in block)" with a fault naming "must be a sign-in block"
```

```test:release-config-string-key
with %{"port" => 9090} in the file, get port is value "9090" from "config.exs", not the default
```

```test:release-config-env-typed
with RT_PORT " 8080 " and RT_MODE "ajar": list shows port "8080" from "env RT_PORT"; mode "\"ajar\"" from "env RT_MODE" with fault "RT_MODE: must be one of open, closed"; smtp_password "unset" from "default"
```

```test:release-config-broken
in a fresh VM, list, get and set over a config.exs with faults on lines 2 and 3 each print exactly one line naming both faults, no exception, and exit with status 1
```

```test:release-config-reset
reset with no file, then over a file that parses, is refused; over a file that list refuses for its fault it answers exactly %{"ok" => true, "reset" => true, "set_aside" => "config.exs.broken", "restart" => "restart to apply"} (through JSON), the broken bytes are in config.exs.broken, and set port "8443" works again; broken again, reset is refused with "config.exs.broken already exists" and both files are as they were
```

```test:release-config-reset-eval
in a fresh VM, reset over a config.exs with faults prints that one JSON line and exits 0, then set port "8443" answers "set":"port"; broken again, reset exits 1 with "config.exs.broken already exists: move it away first" and config.exs untouched
```

```test:release-config-errors
get "nope" gives {:error, "no setting named nope"}; set mode ":ajar" gives {:error, "must be one of open, closed"}; ["frob"] gives an error starting "usage:"
```

## 4. Status {#host-release-status}

`Macaw.Host.Release.status/1` emits the running app's report (its health report, [04](04-health.md), with version and build) as one JSON line, for `bin/<app> rpc`. The script reads the last JSON object the call prints ([08 §8](08-ctl-commands.md#host-cmd-status)).

```test:release-status
status/1 of %{healthy: true} prints exactly one line, {"healthy":true}
```
