# 08 — The script's commands {#host-cmd}

The common commands of every generated `<app>-ctl` (`Ctl.Commands`), as a host runs them; the modules they use are [07](07-ctl-script.md). They follow the deployable-containers pattern, with astex's script as the reference (macaw_compose#33, #48). Each test hint is checked through `Ctl.dispatch/3` with `Macaw.Host.Ctl.Recorder` as the world, asserting the exact docker argv.

## 1. Common rules {#host-cmd-common}

- **Every command returns** `:ok`, `{:error, message}` (printed on stderr, exit 1) or `{:halt, status}` (a child's exit status, passed on) ([07 §8](07-ctl-script.md#host-script-main)).
- **Every command but `init` and `stop` needs the data directory** (`Ctl.Commands.require_home/1`). Without one, an older setup (an `<app>-env` beside the script) is told `"this <app>-ctl keeps its settings in a data directory now: ./<app>-ctl init --migrate [DIR]"`, anything else `"no data directory yet — ./<app>-ctl init [DIR]"`.
- **Every edit ends with "restart to apply". Nothing restarts on its own:** the container reads its settings only at start.
- Helpers, public for `Ctl.AppCommands` too:
  - `Ctl.Commands.ensure_ready/1`: what a throwaway container of the image needs: valid settings ([07 §5.4](07-ctl-script.md#host-script-env-validate)), docker answering, the image present (pulled when missing), and the data volume the container user's (§5);
  - `Ctl.Commands.ensure_running/1`: the data directory, docker, and the container running, else `"<NAME> is not running — ./<app>-ctl start"`;
  - `Ctl.Commands.stream/1`: a docker argv with its output streamed to the terminal; `Ctl.Commands.interactive/1`: one attached to the terminal; `Ctl.Commands.exit_status/1`: `:ok` for status 0, else `{:halt, status}`;
  - `Ctl.Commands.decode_lines/1`: the release protocol's output, one JSON object per line ([03 §1](03-release.md#host-release-protocol)), as `{:ok, objects}`, or `"<Release> answered with a line that is not a JSON object: <line>"`.

## 2. init {#host-cmd-init}

`./<app>-ctl init [DIR] [--force] [--migrate]` sets up this host's data directory (`Ctl.Commands.init/2`):
1. **refused** with the usage for an unknown flag or more than one directory; refused when the script already names a directory and `--force` isn't given (`"this <app>-ctl already uses <dir> — ./<app>-ctl init --force DIR to point it elsewhere"`); with `--migrate`, refused when there is no `<app>-env` beside the script (`"nothing to migrate: there is no <path>"`);
2. **the directory** is `DIR`, or asked for (`"Where should this host keep <Title>'s data? [<data_home>] "`, an empty answer taking the default), expanded;
3. **creates it and its `data/`.** When it can't (creating it may need root, the one thing the script won't do on its own), it fails printing the exact line to run, `sudo install -d -o "$USER" <dir>`, and to run init again;
4. **writes `@data_dir` into the script** (mode 0755), only `Ctl.Home` changing ([07 §2](07-ctl-script.md#host-script-home));
5. **writes `<app>.conf`** (mode 0600) from the settings in effect, **unless it exists,** which is someone's settings and is kept; with `--migrate`, from the old script's host settings over the defaults;
6. prints `"<script> now uses <dir>"`, then **seeds** the app's configuration (§2.1).

With `--migrate`, steps 4–6 wait: the container is stopped and the data copied first (§2.2), and only then are `@data_dir` and `<app>.conf` written and the migration finished.

```test:cmd-init
init <dir> on a script with no directory: the script's data_dir/1 is <dir>, <dir>/data exists, sample.conf starts with the header and holds PORT=4000 and "# The admin console's port.\nADMIN_PORT=4001", and the output says "now uses <dir>" and "ready: ./sample-ctl start"
```

```test:cmd-init-force
init /elsewhere on a script that already names a directory is refused with the --force message, and nothing is called
```

### 2.1 Seeding {#host-cmd-seed}

**The seeds are this host's** (its name, its zone, `Ctl.App.seeds/0`), and **anything already set in the app's configuration is left alone.** With seeds, init makes the throwaway container ready (§1), asks the app for `config list`, and for each seed whose key is at its `default` source runs `config set KEY <value>`, the value resolved ([07 §5.5](07-ctl-script.md#host-script-env-host)) and written as a literal (a string quoted). A failed set stops it there. Seeded, or with no seeds at all, it prints `"ready: ./<app>-ctl start"`.

```test:cmd-init-seed
with phx_host and tz at their default and phx_scheme set in config.exs, init asks list, then sets phx_host to the host's name and tz to the host's zone, each by name in SAMPLE_CTL_ARGS, and leaves phx_scheme alone
```

### 2.2 Migrating an older setup {#host-cmd-migrate}

`init --migrate [DIR]` brings an older layout (settings in `<app>-env` beside the script, data wherever its `DATA` said, a host path or a named volume) into the new one. **Nothing is written until the data is copied:** steps 3–6 run with the settings `<app>.conf` is about to hold, and a failure in any of them leaves the script and the settings file as they were, so a retry is the same command, not `init --force --migrate` (macaw_compose#70):
1. the settings in effect: the old file's known host settings over the defaults (an environment variable still winning), or an existing `<app>.conf`'s;
2. **refused when the new directory is inside the old data** (a host path), since the copy would copy into itself: `"<dir> is inside the old data at <old> — migrate into a directory outside it"`. `DATA` defaults to the description's `:data_home`;
3. settings validated, docker answering, the image present;
4. **the container is stopped and removed first** (§6);
5. **`data/` must be empty:** `"<data> is not empty — migrate into a fresh data directory"`;
6. **the old data is copied, not moved,** in a throwaway root container of the image ([07 §6](07-ctl-script.md#host-script-docker), `migrate_args/3`): the old data mounted **read-only** at `/old`, `cp -a /old/. <container_data>/`, the session key the old settings held (`SECRET_KEY_BASE`) written to `<container_data>/secret_key_base` (0600) **only when none is there,** passed **by name only**, so nobody is signed out; then the whole volume given to the container user (`chown -R`). The copy never removes or moves anything. A failed copy is `"could not copy <old>: <its output>"`;
7. **only now** `@data_dir` is written into the script and `<app>.conf` from the settings of step 1 (§2 steps 4–5, an existing file kept), and `"<script> now uses <dir>"` printed;
8. **settings carry over with the old script's effective values:** for each `:migrate_keys` entry, the old file's value, else **the default the old script used** (`:hostname` and `:timezone` resolved on this host), set in the app's configuration (`config set`); an entry with neither is skipped. Otherwise a setting, say the URL scheme, would silently change under the migration;
9. the old file is renamed `<app>-env.migrated`, and the output says the old data was copied, not moved, and can be removed once the app runs.

`init --migrate` carries old values as strings, so `:migrate_keys` suit string settings (macaw_compose#48).

```test:cmd-migrate
init --migrate <home> with an old PORT, DATA, PHX_HOST and SECRET_KEY_BASE: the script names <home>; sample.conf has PORT=8080 and NAME=sample; stop then rm come before the copy; the copy argv mounts <old>:/old:ro and <data>:/data with -e SECRET_KEY_BASE and no argv element holds the key; the copy script has "cp -a /old/. /data/" and "chown -R 2060:2060 /data" and no rm or mv; the old data is still there; phx_host is set to "old.example" and tz to the host's zone; sample-env is now sample-env.migrated
```

```test:cmd-migrate-order
the docker calls run info, image inspect, info, container inspect, stop, rm, then the copy; when the copy runs the script still has @data_dir nil and there is no sample.conf; afterwards the script names <home> and sample.conf has PORT=8080
```

```test:cmd-migrate-copy-fails
a copy container exiting 1 answers "could not copy …"; the script is byte for byte as before, there is no sample.conf, sample-env is still there, and no config set is run
```

```test:cmd-migrate-inside
init --migrate into a directory inside the old data is refused naming "is inside the old data", and no docker run is made
```

```test:cmd-migrate-nothing
init --migrate with no sample-env beside the script answers "nothing to migrate: there is no …"
```

## 3. env {#host-cmd-env}

`./<app>-ctl env list | get KEY | set KEY=VALUE [KEY=VALUE…] | unset KEY` edits the host settings in place (`Ctl.Commands.env/2`); `--reveal` anywhere shows secrets. Any other shape answers the usage.
- **`list`:** every known key, `KEY=value` and where the value came from (`environment`, `file` or `default`), then every key in the file this script doesn't know, flagged `(file, unknown to <app>-ctl)`, so a typo is visible rather than silently ignored. **Secrets are masked** unless `--reveal` ([07 §4](07-ctl-script.md#host-script-secret)).
- **`get KEY`:** the value, masked likewise; a key neither known nor in the file is `"<KEY> is not set in <path>"`.
- **`set KEY=VALUE…`:** each pair must be `KEY=VALUE` (`"expected KEY=VALUE, got …"`) with a valid name (`"<KEY> is not a valid setting name (letters, digits and _)"`). **A key that is now the app's own configuration is refused with a pointer to `config`** (`"<KEY> is <Title>'s own configuration now: ./<app>-ctl config set <config key> VALUE"`). A key this script doesn't know is accepted (the file is free-form) and flagged `(not a setting <app>-ctl knows)`. The known values are **validated before anything is written** ([07 §5.4](07-ctl-script.md#host-script-env-validate)); then each is set in the file's text ([07 §5.3](07-ctl-script.md#host-script-env-edit)), the file written 0600 (a file not there yet starts as `init` would write it), `set KEY` printed for each, and `"<path> updated — ./<app>-ctl restart to apply"`. **`set` never echoes a value.**
- **`unset KEY`:** KEY must be a setting's name, an upper-case letter then upper-case letters, digits and `_` (`^[A-Z][A-Z0-9_]*$`), else `"<KEY, inspected> is not a valid setting name (A–Z, digits and _, starting with a letter)"` and the file untouched. It removes the key's active lines, **matched as written, never as a pattern** (the key is escaped; before macaw_compose#70 it was a regular expression, and `env unset '.*'` removed every line); when there were none, `"<KEY> is not set in <path>; nothing to do"`; else `unset KEY` and the restart line.

```test:cmd-env-list
with PORT=8080 and REGISTRY_TOKEN=abcdefghijkl1234 in sample.conf: list shows "PORT=8080 (file)", "ADMIN_PORT=4001 (default)" and "REGISTRY_TOKEN=set (…1234) (file, unknown to sample-ctl)", never "abcdefghijkl"; list --reveal shows the token
```

```test:cmd-env-set
set PORT=9090 ADMIN_PORT=9091 over "# mine\nPORT=8080\n" leaves "# mine\nPORT=9090\nADMIN_PORT=9091\n" and says restart to apply; set PHX_HOST=x is refused with the pointer to config set phx_host
```

```test:cmd-env-unset
over "# mine\nPORT=8080\nNAME=x\nPORTS=1\n", unset of ".*", "P.RT", "port", "PORT=", "1PORT" and "" is each refused as not a valid setting name with the file unchanged; unset PORT leaves "# mine\nNAME=x\nPORTS=1\n"
```

## 4. config {#host-cmd-config}

`./<app>-ctl config list | get KEY | set KEY VALUE | unset KEY` is **the app's own configuration,** kept on the data volume (`config.exs`) and **changed by the app itself** (`Ctl.Commands.config/2`): `<Release>.config()` in a throwaway container of the image, as the app's uid ([07 §6](07-ctl-script.md#host-script-docker)), so it works whether or not the app is running.
- **The words travel as JSON in `<PREFIX>_CTL_ARGS`, by name, never on a command line;** the answer is one JSON object per line ([03 §3](03-release.md#host-release-config)).
- **Output:** a setting as `name=value (source)`, and one the app reports with a `fault` (a value that doesn't fit its type, [03 §3](03-release.md#host-release-config)) as `name=value (source) INVALID: <fault>`; `set name`; `unset name`; any other object as its JSON line. After `set` or `unset`: `"<Title>'s configuration updated — ./<app>-ctl restart to apply"`.
- **The release's failure** (its one line on stderr reaching the terminal as it is) **passes its exit status on.**
- **The app masks its secrets itself, and never shows them;** `config` has no `--reveal` (macaw_compose#48).
- `VALUE` is a literal as the app reads it: a string is typed with its quotes, `config set tz '"Europe/Oslo"'`.

```test:cmd-config-set
config set tz "\"Europe/Oslo\"" runs exactly one eval container with -e SAMPLE_CTL_ARGS, carrying ["set","tz","\"Europe/Oslo\""] in its env only, prints "set tz" and "Sample's configuration updated — ./sample-ctl restart to apply"
```

```test:cmd-config-list
config list prints tz="Etc/UTC" (default) and smtp_password=set (…tery) (config.exs), and sent ["list"]
```

```test:cmd-config-invalid
a listing with port "\"eighty\"" from env SAMPLE_PORT and its fault prints port="eighty" (env SAMPLE_PORT) INVALID: SAMPLE_PORT: must be a port number …
```

```test:cmd-config-failure
a release answering exit status 1 makes config get nope answer {:halt, 1}
```

## 5. start {#host-cmd-start}

`./<app>-ctl start` runs the container from the settings (`Ctl.Commands.start/2`):
1. the data directory, valid settings, docker answering;
2. **the image, pulled if missing;**
3. **the data volume handed to the container user.** The image's user has a fixed uid and gid; when `data/` isn't already owned by that uid, **a throwaway root container of the same image** chowns it (root inside it is what docker access amounts to anyway), so **no sudo** is needed on the host. When that fails, it prints the exact line to run by hand, `sudo chown <uid>:<gid> <data>`; when `data/` can't even be created, `sudo install -d -o "$USER" <dir>`;
4. **the container recreated, always:** an existing one is removed (`rm -f`), so every changed setting takes effect. Nothing of value lives in the container; it is all in the data directory;
5. `docker run` ([07 §6](07-ctl-script.md#host-script-docker)); a failure is `"docker run failed: <output>"`;
6. after two seconds, **a container still running** is reported `"<NAME> is running — ./<app>-ctl status shows <Title>'s health once it is up"`; one that exited prints **its last words** (the last 30 log lines) and answers `"<NAME> did not stay up"`.

```test:cmd-start
start makes exactly: info; image inspect <ref>; the chown container; container inspect sample; rm -f sample; the run argv of 07 §6; container inspect sample; and sleeps 2000 ms
```

```test:cmd-start-last-words
a container that is not running after the sleep answers "sample did not stay up", having printed its logs ("boom")
```

## 6. stop and restart {#host-cmd-stop}

- **`./<app>-ctl stop`** (`Ctl.Commands.stop/2`): docker answering; a container that exists is stopped **with a grace period** (`stop -t <stop_timeout>`, 30 s by default) and **removed**, printing `"stopping and removing <NAME> (its data is untouched)"`; when there is none, `"<NAME> is not there"`. **The data is untouched.**
- **`./<app>-ctl restart`** (`Ctl.Commands.restart/2`): the data directory, then stop, then start, which applies changed settings.

```test:cmd-stop
stop makes exactly: info; container inspect sample; stop -t 30 sample; rm -f sample; and says its data is untouched
```

## 7. update {#host-cmd-update}

`./<app>-ctl update` pulls TAG again (`Ctl.Commands.update/2`), comparing the image's id before and after the pull:
- **an unchanged image:** `"already on the newest <ref>"`, and the script is synced with the image's (below), without a restart;
- **a new image and no container:** `"pulled a new <ref>; <NAME> is not there — ./<app>-ctl start"`, and the script synced, without a restart;
- **a new image and a container:** the script synced with the restart handed over (below); when it isn't replaced, `"new image; recreating <NAME>"` and this script restarts the container itself.

**Syncing the script with the image's.** The image carries the script that knows how to run it (`bin/ctl` prints it, [§10](#host-cmd-adopter)):
1. it is extracted (`run --rm IMAGE:TAG bin/ctl`, stdout only). **Anything that isn't this kind of script** (no `bin/ctl`, a failure, text not starting `#!/usr/bin/env elixir`) **is never written over a working one;** nothing is said, and the command goes on;
2. **this host's `@data_dir` line is spliced into it** ([07 §2](07-ctl-script.md#host-script-home)). **Refused when either script lacks the line in `Ctl.Home`**, saying `"not replacing <app>-ctl with the one in <ref>: <why>"`, and the command goes on with this script;
3. compared **by content,** after the splice, which also catches a local copy that has drifted from the image it manages; the same text writes nothing and keeps no backup;
4. a different one is written over this script (mode 0755), **the previous one kept as `<app>-ctl.bak`,** saying `"<app>-ctl in <ref> differs from this one; updating it"` and where the backup is. Overwriting is safe: the running program is already compiled in memory. If the script can't be written, `"<ref> carries a newer <app>-ctl, but <path> is not writable — leaving it"`, and this script carries on;
5. **the restart is handed to the new script:** it runs `<script> restart` with `<PREFIX>_CTL_SELF_UPDATED=1` in its environment, its output streamed, and this process ends with its exit status. The new script, seeing the variable, **does not sync itself again.**

```test:cmd-update-replace
with a new image carrying a different script and a running container: the docker calls are exactly info, image id, pull, image id, container inspect, extract; the script becomes the fresh one with this host's @data_dir (one @data_dir line, mode 0755); <script>.bak is the old one byte for byte; <script> restart is run with SAMPLE_CTL_SELF_UPDATED=1; the answer is {:halt, 0}; this script never stops the container itself
```

```test:cmd-update-handed
with SAMPLE_CTL_SELF_UPDATED=1, update never extracts the image's script and leaves the file as it was
```

```test:cmd-update-refuse
the fresh script lacking the @data_dir line, having it only outside Ctl.Home, an image without bin/ctl, and bin/ctl printing something that isn't a script each leave the script byte for byte, make no .bak and run no script; the first two say "this script has no @data_dir line in Ctl.Home"
```

```test:cmd-update-same
an image carrying this very script (with @data_dir nil): nothing written, no .bak, and with a new image and a container, stop -t 30, rm -f and a fresh run, saying "new image; recreating sample"
```

```test:cmd-update-unchanged
an unchanged image and no container: "already on the newest <ref>", nothing written, no run
```

## 8. status {#host-cmd-status}

`./<app>-ctl status` reports what is running (`Ctl.Commands.status/2`): the data directory, docker answering, then
- `state:` running, docker's own status, stopped, or not created; for a container, its `image:` and `started:`;
- `wanted:` IMAGE:TAG, `(present locally)` or `(not pulled)`;
- `home:`, `settings:` (`(none yet — defaults)` when there is no `<app>.conf`), and `data:`;
- **when it is running, the app's own report,** asked of the running app (`rpc <Release>.status()`, [03 §4](03-release.md#host-release-status)). The report is **the last JSON object** the call prints; anything before it (a warning from the node) is not the answer. `healthy` is shown as `health: healthy` or `UNHEALTHY`, every other key in sorted order, a nested map key by key. An app that doesn't answer is `app: not answering yet`.

`status` answers `:ok` whatever the app's health.

```test:cmd-status
with a running container whose rpc prints "a warning" and then {"healthy":true,"version":"1.2.0","checks":{"database":"ok"}}: the last call is exec sample /app/bin/sample rpc Sample.Release.status(), and the output has "state:    running", "home:     <home>", "health:   healthy", "version:  1.2.0" and "checks:" with "  database:" "ok"
```

## 9. logs and shell {#host-cmd-logs}

- **`./<app>-ctl logs [-n N]`** (`Ctl.Commands.logs/2`): with no argument it **follows** the log (`logs -f --tail 100`); with `-n N` (or `N` alone), N a positive integer, it prints the last N lines. Anything else answers `"usage: ./<app>-ctl logs [-n N]"`; no container answers `"<NAME> is not there — start it first"`.
- **`./<app>-ctl shell`** (`Ctl.Commands.shell/2`): **a shell inside the running container,** `exec -it NAME /bin/sh`, attached to the terminal; refused when it isn't running.

```test:cmd-logs
logs -n 50 makes exactly info, container inspect sample, logs --tail 50 sample, and prints the output; logs -n x answers the usage
```

```test:cmd-shell
shell's last call is {"docker", ["exec", "-it", "sample", "/bin/sh"], [tty: true]}; with the container not running it answers "sample is not running — ./sample-ctl start" and runs no exec
```

## 10. What an adopting app provides {#host-cmd-adopter}

<!-- surfex: class adopter-rule -->

The generated script assumes these of the app, its image and its CI; `macaw_host` doesn't enforce them, and each app's own spec and pipeline hold them (the deployable-containers pattern):
- **The script ships inside the image:** copied to `/app/<app>-ctl`, with a `bin/ctl` that prints it. **The image has no ENTRYPOINT** (an inherited one cleared with `ENTRYPOINT []`), so `docker run --rm IMAGE bin/ctl > <app>-ctl` extracts the copy that matches the image, and `eval_args/3` can run the release.
- **The image's runtime user has the fixed uid and gid** the description's `:uid` names.
- **The release module** (`:release`) defines `config/0` and `status/0` on `Macaw.Host.Release`'s protocol ([03](03-release.md)), and the app's own commands' functions likewise; its start script is `:release_bin`.
- **The app reads its data directory** (`:data_dir` in its environment, the container's `:container_data`), loads its settings with `Macaw.Host.Config` (env var > `config.exs` > default), and generates its secrets there with `Macaw.Host.Secrets`.
- **CI:**
  - `mix macaw.host.ctl --check` fails the pipeline when the committed script differs from a regeneration ([06 §1](06-ctl-generator.md#host-gen-task));
  - a `test:<app>-ctl` job extracts the script from the image just built, `cmp`s it with the repository's copy, and runs `init <dir>` → `config set` → `start` → `status` (the app healthy) → `stop` against it;
  - a merge to `main` runs a publish-only pipeline that re-tags the image the branch pipeline tested as `latest` (`crane tag`, no rebuild), which works because fast-forward merges make main's SHA the tested SHA; every other job opts out. `latest` is the script's default TAG;
  - CI shell is linted for pipes into early-exiting commands (`| grep -q`, `| head`), which fail a job under `pipefail` at random.
