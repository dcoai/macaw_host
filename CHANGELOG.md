# Changelog

## Unreleased

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
