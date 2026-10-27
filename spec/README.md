# macaw_host specification

`macaw_host` is the host-side glue every deployable Macaw-family application needs, implemented once: the literal `config.exs` on the data volume, generated secrets, the release entry points the control script calls, health, build info, and the generator of the `<app>-ctl` control script itself. Each Macaw component has its own spec in its own repository (dco-tek/macaw_compose#61); this is `macaw_host`'s. The family's overview, and where the host libraries sit in it, is in [macaw_compose 00 §4](https://gitlab.conet.yarina.org/dco-tek/macaw_compose/-/blob/main/spec/00-overview.md#overview-packaging).

| File | Covers | Status |
|---|---|---|
| [00 — Overview](00-overview.md) | what `macaw_host` holds, the deployable-containers pattern it implements, the data directory, dependencies | |
| [01 — Configuration](01-config.md) | `Macaw.Host.Config`, `Macaw.Host.Config.Literal`, `Macaw.Host.Config.Types`: the literal file, setting types, resolution env > file > default, editing for the ctl | implemented (v0.1.1) |
| [02 — Secrets](02-secrets.md) | `Macaw.Host.Secrets`: generated once, written 0600 atomically, mode checked on read, restorable | implemented (v0.1.1) |
| [03 — Release entry points](03-release.md) | `Macaw.Host.Release`: the ctl protocol, `migrate`, the config commands, `status` | implemented (v0.1.1) |
| [04 — Health](04-health.md) | `Macaw.Host.Health`, `Macaw.Host.Health.Plug`: the check contract, the report, `200`/`503` | implemented (v0.1.1) |
| [05 — Build info](05-build.md) | `Macaw.Host.Build`: the build's SHA and version, fixed when the app compiles | implemented (v0.1.1) |
| [06 — The ctl generator](06-ctl-generator.md) | `mix macaw.host.ctl`, `Macaw.Host.Ctl`, `Macaw.Host.Ctl.Description`, the `Ctl.AppCommands` contract, `Macaw.Host.Ctl.Recorder` | implemented (v0.1.1) |
| [07 — The generated script](07-ctl-script.md) | the `<app>-ctl` script's modules: the one line of host state, the world, secrets, host settings, every docker command line, dispatch | implemented (v0.1.1) |
| [08 — The script's commands](08-ctl-commands.md) | `init` (and `--migrate`), `env`, `config`, `start`, `stop`, `restart`, `update`, `status`, `logs`, `shell`; what an adopting app provides | implemented (v0.1.1) |

Every heading carries an anchor prefixed `host-`, so links into this spec stay stable when a heading is reworded. Each behavioral rule carries a test hint (a fenced block whose info string is `test:<id>`) that says what a test of it must show.
