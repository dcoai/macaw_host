# macaw_host

> **This software is a very early release, and not ready for general use.**

Public home: [github.com/dcoai/macaw_host](https://github.com/dcoai/macaw_host) · Docs: [hexdocs.pm](https://hexdocs.pm/macaw_host)

Host glue for deployable Phoenix apps, implemented once for the Macaw family's host applications (dco-tek/macaw_compose#33). It is the "deployable containers" pattern's application side: everything a host holds lives in one data directory, app configuration is a literal map on it, and secrets the system can generate are generated there.

| Module | What it does |
|---|---|
| `Macaw.Host.Config` | settings declared once, resolved env var > `config.exs` > default, every fault named at once; `put!`/`delete!` for `<app>-ctl config` |
| `Macaw.Host.Config.Literal` | the literal `config.exs`: parsed, never evaluated, no atoms made; atomic 0600 writes |
| `Macaw.Host.Secrets` | generated secrets: 64 bytes, 0600 before any secret is written, mode checked on every read, restorable |
| `Macaw.Host.Release` | the ctl's `eval`/`rpc` entry points: arguments as JSON in `<PREFIX>_CTL_ARGS`, one JSON object per output line; `migrate`, `config list/get/set/unset`, `status` |
| `Macaw.Host.Health` | named checks in one report shape; `Macaw.Host.Health.Plug` serves it, `200` or `503` |
| `Macaw.Host.Build` | `use Macaw.Host.Build, otp_app: :my_app`: the build's SHA and version, fixed when the app compiles |
| `Macaw.Host.Ctl` | generates the app's `<app>-ctl` from the generic modules in `priv/ctl/`, the `:ctl` description in its `mix.exs` (`Macaw.Host.Ctl.Description`) and its own `Ctl.AppCommands`; `mix macaw.host.ctl` writes it, `--check` fails CI when the committed script differs |
| `Macaw.Host.Ctl.Recorder` | the stand-in for a generated script's `Ctl.World`, so an app's tests assert every command's exact docker argv without docker |

Part of [Macaw](https://github.com/dcoai/macaw) (spec/00 §4, host libraries). Released by git tag.

From Hex:

```elixir
{:macaw_host, "~> 0.1.4"}
```
