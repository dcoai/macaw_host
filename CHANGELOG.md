# Changelog

## Unreleased

- `config reset` (the script, `Macaw.Host.Release.config_command/5` and `Macaw.Host.Config.reset!/1`): a `config.exs` that no longer parses, which blocks the app's boot and every other `config` command, is set aside as `config.exs.broken` (0600, its bytes intact) and an empty one written, only once the rename has succeeded; the answer is `{"ok":true,"reset":true,"set_aside":"config.exs.broken","restart":"restart to apply"}`. Refused, both files untouched, with no file, a file that parses (`config unset NAME` removes a setting), or a `config.exs.broken` already there, which is never overwritten. `reset` is the one config command that doesn't read the file first. The usage and help name it (spec 01 §6, 03 §3, 07 §8, 08 §4; #15, macaw#92).
- `Ctl.AppCommands.init_flags/0` and `after_init/2`, optional: `init` takes the app's own flags, declared as data (`[{"--user", :value}, {"--quiet", :switch}]`), beside `--force` and `--migrate`, and gives them to `after_init/2` as a map once the data directory is adopted and seeded (or migrated); its answer is init's, and it runs on every successful init, so it must be safe to rerun. An undeclared flag is refused with the usage as before, a value flag without its value with `init <flag> needs a value`, and a flag given twice (`--force` included) with `init takes <flag> once`. `ready:` is now printed after the app's step (spec 06 §4, 08 §2, #14, macaw#92).
- `Ctl.AppCommands.before_start/1`, optional: the app's precondition for `start`, asked once the image and the data are ready and before the container is touched (spec 06 §4, 08 §5, #13, macaw#92).
- **Every generated script changes:** a seventh host setting, `BIND`, the address PORT is published on. On a docker network the run writes `-p BIND:PORT:<container port>`, and BIND defaults to `127.0.0.1` (default closed: only this host, a proxy on it included, reaches the app). The description's new `:bind` key sets the default (an IP address; `"0.0.0.0"` with `network: "host"`). **An adopter whose proxy is on another host states `bind: "0.0.0.0"`** (or its hosts set BIND); otherwise the app stops answering from that host when its script is regenerated. `env set` and `start` refuse a BIND that isn't an IP address, and, with `NETWORK=host`, one other than `0.0.0.0`. `status` prints where the port is published: `published: 127.0.0.1:4000 (this host only)`, `(every interface)`, `(that address)`, or the host's own network (spec 06 §3, spec 07 §5–6, spec 08 §5, §8; #12, macaw#92).

## v0.2.1 (2026-10-29)

Operator output: status, config set and migrate say what an operator needs, plainly (milestone "macaw_host operator output").

- `Release.migrate/1` answers the versions it applied (`"versions": [...]`) with Ecto's log off, so the JSON answer is the only thing on stdout (spec 03 §2, #10, macaw#107).
- `config set` names what a bare word should have been: "not a literal" whether or not the word is a known atom, and, when the setting's type takes the text as a string, how to quote it (spec 01 §1.6, #9, macaw#106).
- `status` pads each level of the app's report to its widest key plus two spaces, so a key never runs into its value, and prints a list as words and nil as a dash, not JSON; `config`'s help line names `@FILE` (spec 07, spec 08 §8, #8, #7).

## v0.2.0 (2026-10-28)

- App hooks in `Ctl.AppCommands`, each optional: `validate/1` (the app's own checks of its host settings, on every `env set`, `start` and throwaway container), `seeds/1` (app config `init` seeds from this host's settings) and `status_lines/1` (host lines in `status`). `status` prints a list of maps one element a line (#1, #5).
- Description keys `host_network` (`false` refuses `NETWORK=host`) and `:app_keys` (names `env set` refuses as the app's own configuration) (#5).
- **Fixed:** the generated script reaches the terminal by path (`/proc/<pid>/fd`), since a child of the BEAM has no `/dev/tty`: `shell` and other `tty: true` commands work again; `prompt_secret/1` turns echo off before asking and refuses without a terminal (#1, #4; collpa#128, #148).
- `Ctl.World.write_local/2`, and `Ctl.Commands.last_object/1` public, for an app's own commands (#4).
- `config set KEY @FILE` in the generated script reads the value from a host file and sends it in the environment, never on a command line; `config get` of a map or a list prints it formatted on several lines. `Ctl.World.read_local/1`, and the Recorder's `:files` option (#1, #3).
- `{:custom, module}` setting types (`Macaw.Host.Config.Type`): the module checks, casts, shows and describes its values, so a secret inside a structure is masked wherever a value is shown, a value that did not check included (#1, #2).
- **Fixed:** `Macaw.Host.Config.put!/4` stores the literal as typed, never the check's result, which could have resolved a reference to a secret into the file (#2).

## v0.1.5 (2026-10-28)

- The macaw logo in the docs and the README (macaw#175).

## v0.1.4 (2026-10-28)

- The README opens with the early-release notice (macaw#174).

## v0.1.3 (2026-10-28)

- Spec and README links to the public home, `github.com/dcoai/macaw_host`, and the install snippet from Hex (macaw#171, #173).
- Package metadata for Hex: the public home, the changelog link, the files shipped, and docs with `ex_doc` (macaw_compose#155).

## v0.1.2 (2026-10-27)

- Adopt surfex; compare/2 marks either text's end; v0.1.2 (part of macaw_compose#65)

## v0.1.1 (2026-10-27)

- macaw_host 0.1.1: the nine gaps found writing its spec

## v0.1.0 (2026-10-26)

- macaw_host 0.1.0: Config, Secrets, Release, Health, Build, the ctl generator
