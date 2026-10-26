# macaw_host

Host glue for deployable Phoenix apps, implemented once for the Macaw family's host applications (dco-tek/macaw_compose#33). It is the "deployable containers" pattern's application side: everything a host holds lives in one data directory, app configuration is a literal map on it, and secrets the system can generate are generated there.

| Module | What it does |
|---|---|
| `Macaw.Host.Config` | settings declared once, resolved env var > `config.exs` > default, every fault named at once; `put!`/`delete!` for `<app>-ctl config` |
| `Macaw.Host.Config.Literal` | the literal `config.exs`: parsed, never evaluated, no atoms made; atomic 0600 writes |
| `Macaw.Host.Secrets` | generated secrets: 64 bytes, 0600 before any secret is written, mode checked on every read, restorable |

Part of [Macaw](https://gitlab.conet.yarina.org/dco-tek/macaw_compose) (spec/00 §4, host libraries). Released by git tag.
