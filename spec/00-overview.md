# 00 — Overview {#host-overview}

## 1. What macaw_host holds {#host-holds}

Every deployable project carried the same host-side code, implemented by hand, and the copies had drifted, security fixes included: seven literal-config readers, eight `secret_key_base` generators, seven release modules, four health endpoints, five build-info copies and nine control scripts in three generations (macaw_compose#33). `macaw_host` implements them once:
- **configuration:** the literal `config.exs` on the data volume, parsed and never evaluated, settings resolved env var > file > default ([01](01-config.md));
- **secrets** the system generates itself, kept 0600 in the data directory ([02](02-secrets.md));
- **release entry points** for the control script: one protocol for arguments and answers, `migrate`, the config commands and `status` ([03](03-release.md));
- **health:** named checks in one report shape, and a plug that serves it ([04](04-health.md));
- **build info:** the build's SHA and version, fixed at the app's compile time ([05](05-build.md));
- **the `<app>-ctl` generator:** the single-file host control script, generated from generic modules, the app's description and its own commands ([06](06-ctl-generator.md), [07](07-ctl-script.md), [08](08-ctl-commands.md)).

Backups of the data directory and database were part of the proposal and left this release: two adopters on two database stacks, filed later as Research (macaw_compose#33, owner decision).

## 2. The deployable-containers pattern {#host-pattern}

A deployable app ships a container image and a host-side control script, `<app>-ctl`, and every such app is run the same way. `macaw_host` is the pattern's implementation: the library half runs inside the app's release (01–05), and the generator emits the host half (06–08).

### 2.1 The data directory {#host-data-dir}

Everything a host holds for an app lives in one data directory:

```
<data_dir>/            owned by the host user
├── <app>.conf         host settings only (KEY=value, 0600)
└── data/              bind-mounted into the container; owned by the image's user
    ├── config.exs     app config (a literal map, never evaluated)
    ├── secret_key_base
    └── …              database, files, …
```

- **Host settings vs app config.** `<app>.conf` holds only what docker needs to run the container: IMAGE, TAG, NAME, PORT, NETWORK and DOCKER_RUN_ARGS, plus any host settings the app declares ([07 §5](07-ctl-script.md#host-script-env)). Everything the application itself uses is app config, in `data/config.exs`, owned by the app, traveling and backed up with the data ([01](01-config.md)).
- **Secrets the system can generate are not settings.** The app generates them on first boot into `data/` ([02](02-secrets.md)); an explicit env var still wins. The host never holds a secret it must not lose.
- **The script names the directory in one line:** `@data_dir`, in `Ctl.Home`, the script's first module ([07 §2](07-ctl-script.md#host-script-home)).

### 2.2 Who does what {#host-split}

- The **app** declares its settings and loads them at boot with `Macaw.Host.Config`, generates its secrets with `Macaw.Host.Secrets`, delegates its release module's `config/0` and `status/0` to `Macaw.Host.Release`, builds its health report with `Macaw.Host.Health`, and stamps its build with `Macaw.Host.Build`.
- The **script** runs the container, edits the host settings itself, and asks the app (in a throwaway container, or the running one) for everything about app config and health, through `Macaw.Host.Release`'s protocol ([03 §1](03-release.md#host-release-protocol)).
- What an adopting app's image and CI must provide is in [08 §10](08-ctl-commands.md#host-cmd-adopter).

## 3. Dependencies {#host-dependencies}

- **Runtime:** OTP and Elixir's standard library only (`:logger`, `:crypto`, `:eex`). `JSON` is Elixir's own, so **Elixir 1.18 or newer** is required, and nothing adds a JSON library.
- **Optional:** `plug` (for `Macaw.Host.Health.Plug`, compiled only when Plug is present) and `ecto_sql` (for `Macaw.Host.Release.migrate/1`, `Macaw.Host.Health.database/1` and `Macaw.Host.Health.migrations/1`, which need it at call time) (macaw_compose#33, owner decision).
- **Test only:** `stream_data`.
- **The application** starts one process, a `Task.Supervisor` named `Macaw.Host.Health.Tasks`, under which health checks run ([04 §2](04-health.md#host-health-isolation)).

`macaw_host` sits outside the composition model: `macaw_layers`, `macaw_data`, `macaw_compose` and `macaw_live` never depend on it ([macaw_compose 00 §4](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/00-overview.md#overview-packaging)). It is released by git tag (v0.1.0).

## 4. Known gaps {#host-gaps}

Found while writing this spec from the code (v0.1.0); each section states what the code does, and these are open for the owner's decision:
- **Two maskings disagree.** `Macaw.Host.Config.mask/2` shows a secret's last four characters once it is longer than four bytes, so a five-byte secret shows four of its five ([01 §5](01-config.md#host-config-show)); the script's `Ctl.Secret.mask/1` shows them only past eight bytes ([07 §4](07-ctl-script.md#host-script-secret)).
- **A broken `config.exs` breaks the protocol.** `Macaw.Host.Release.config/3` reads the file with `Macaw.Host.Config.Literal.read!/1`, so a file with faults raises (a stack trace, not one stderr line) ([03 §3](03-release.md#host-release-config)).
- **`config list` shows an env value raw.** A setting set by env var is listed as the env var's string, masked or inspected, not cast to its type nor checked ([03 §3](03-release.md#host-release-config)); and a file key written as a string (`"port" => 1`), which `Macaw.Host.Config.resolve/4` accepts, is listed at its default.
- **A health check's `{:error, detail}` must carry a string.** Any other detail raises in the report itself, which the report otherwise never does ([04 §1](04-health.md#host-health-checks)). Checks run one after another, so the 5 s bound is per check, not per report.
- **The build SHA is fixed when the build module compiles,** and nothing marks the module stale when the commit changes, so an incremental build after a new commit can keep the old SHA ([05 §1](05-build.md#host-build-sha)).
- **`env unset` does not check its key.** The key is matched as a regular expression, so `env unset '.*'` removes every active line ([08 §3](08-ctl-commands.md#host-cmd-env)).
- **The app commands file may hold top-level code.** The check refuses modules other than `Ctl.AppCommands` and its submodules, but not a top-level expression, which would run whenever the script loads ([06 §4](06-ctl-generator.md#host-gen-app-commands)).
- **`init --migrate` is not atomic.** It writes `@data_dir` and the settings file before it stops the container and copies the data; a failure after that leaves the script pointing at the new directory, so a retry needs `init --force --migrate` ([08 §2.2](08-ctl-commands.md#host-cmd-migrate)).
