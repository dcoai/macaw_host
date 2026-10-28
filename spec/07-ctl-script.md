# 07 — The generated script {#host-script}

What `mix macaw.host.ctl` generates ([06](06-ctl-generator.md)) is one program: `<app>-ctl`, a single-file Elixir script, standard library only, no Mix project and no dependencies. A host needs docker and Elixir 1.18 or newer on PATH, and nothing else. This file is its modules; [08](08-ctl-commands.md) is its commands. In both, `<app>` is the description's `:name`, `<Title>` its `:title`, `<PREFIX>` its `:env_prefix`, and `<Release>` its `:release`.

## 1. Structure {#host-script-structure}

The script's modules, in file order, each with one job:

| Module | Its job |
|---|---|
| `Ctl.Home` | the one line of host state, `@data_dir` (§2) |
| `Ctl.App` | what the script manages: everything app-specific, from the description (§7) |
| `Ctl.World`, `Ctl.World.Real` | the only thing that touches the host: commands, sleep, the terminal (§3) |
| `Ctl.Script` | reads and rewrites the `@data_dir` line in the file on disk (§2) |
| `Ctl.Secret` | what may be printed (§4) |
| `Ctl.Env` | the host settings (§5) |
| `Ctl.Docker` | every docker command line, built in one place (§6) |
| `Ctl.Commands` | the common commands ([08](08-ctl-commands.md)) |
| `Ctl.AppCommands` | the app's own commands ([06 §4](06-ctl-generator.md#host-gen-app-commands)) |
| `Ctl` | `main/1`, dispatch, help (§8) |

**Every failure is a value.** A command returns `:ok`, `{:error, message}` or `{:halt, status}`; only `Ctl.main/3` prints an error, and the script holds no `try`, `catch` or `rescue`.

## 2. The one line of host state {#host-script-home}

The script carries exactly **one line of host state:** `@data_dir`, in `Ctl.Home`, the first module, written `  @data_dir nil` in the generated (and shipped) script and `  @data_dir "/srv/<app>"` once a host has run `init`. `Ctl.Home.data_dir/0` is its compiled value. There are no env files beside the script.

**The file on disk is the truth** (what `init` rewrites and `update` carries into a fresh script), so `Ctl.Script` reads the line from the text, never from the compiled module:
- `Ctl.Script.data_dir/1` is the directory a script's text names: `{:ok, nil | path}`; `{:error, "this script has no @data_dir line in Ctl.Home"}`; or `{:error, "the @data_dir line is not nil or a string: …"}`;
- `Ctl.Script.put_data_dir/2` is the text with the line naming another directory; **only `Ctl.Home` changes;**
- `Ctl.Script.splice/2` is a fresh script with the current script's line in place of its own: what `update` writes. **It is refused when either lacks the line:** a script that can't carry it must not replace one that holds it.

**The line is matched only inside `defmodule Ctl.Home do … end`,** as an attribute indented by two spaces. Scripts from before `Ctl.Home` existed had an unrelated `@data_dir "/data"` elsewhere; matching that would let `update` write an older script over a newer one, which astex's live test caught.

```test:script-home-only
an older script whose only @data_dir is in Ctl.Docker gives "this script has no @data_dir line in Ctl.Home" from data_dir/1 and from splice/2 as current
```

```test:script-splice-only-home
splicing a fresh script that also has @data_dir "/data" in Ctl.Docker with a current one naming /srv/sample changes only Ctl.Home's line: data_dir/1 is /srv/sample, and Ctl.Docker's line is unchanged
```

## 3. The world {#host-script-world}

**Everything that reaches outside the script goes through `Ctl.World`:** running a command (`Ctl.World.cmd/3`, answering `{output, exit status}` like `System.cmd/3`), sleeping (`sleep/1`), reading and writing a file on the host (`read_local/1` and `write_local/2`, answering as `File.read/1` and `File.write/2` do; macaw_host#1), asking at the terminal (`prompt/1`, the answer trimmed or `""`; `prompt_secret/1`, read without echo). The real module, `Ctl.World.Real`, is the default; **a test puts a replacement under `:ctl_world` in its process dictionary** (`Macaw.Host.Ctl.Recorder`, [06 §6](06-ctl-generator.md#host-gen-recorder)) and receives every call instead.

`Ctl.World.Real`:
- an executable not on PATH is `{"", 127}`, the shell's answer, which callers already handle, never a raise;
- `tty: true` hands the terminal itself to the command, since `docker exec -it` refuses the pipes a port gives it: `sh -c 'exec "$0" "$@" <"$TTY_IN" >"$TTY_OUT" 2>&1'`, the two paths in the environment. **The terminal is reached by path, not as `/dev/tty`** (collpa#128, macaw_host#1): the BEAM starts every command in a new session (`setsid`), so a child has no controlling terminal and `/dev/tty` fails there; the BEAM's own stdin and stdout are the terminal, `/proc/<pid>/fd/0` and `/1`. A host without `/proc` uses `/dev/tty`.
- `prompt_secret/1` turns the terminal's echo off (`stty -echo`, on the terminal by path) **before** showing the question, so an answer typed or pasted the moment it appears is never echoed (collpa#148), reads the answer from the BEAM's own stdin, and turns echo back on. **Without a terminal it refuses** with one line on stderr, `"<question> needs a terminal to ask without echoing: run it in one (over ssh, ssh -t)."`, and exit status 1, rather than read an empty password.

```test:script-world-secret
under a pseudo-terminal, prompt_secret("password: ") with "S3cretX" typed once the prompt shows answers "S3cretX", and the terminal shows it once (the answer), never echoed
```

```test:script-world-tty
under a pseudo-terminal, cmd/3 with tty: true runs a command whose stdin and stdout are both terminals
```

```test:script-world-secret-refuses
with stdin from /dev/null, prompt_secret("Admin password: ") exits with status 1 and "Admin password: needs a terminal to ask without echoing"
```

```test:script-world-real
Ctl.World.Real.cmd/3 of an executable not on PATH answers {"", 127} without raising; read_local/1 of a file is {:ok, its text}, of a missing one {:error, :enoent}; write_local/2 writes bytes to a host file and answers :ok
```

## 4. Secrets on output {#host-script-secret}

`Ctl.Secret` decides what may be printed:
- `Ctl.Secret.secret?/1`: `SECRET_KEY_BASE`, and any key ending in `_KEY`, `_SECRET`, `_TOKEN` or `_PASSWORD`, in either case;
- `Ctl.Secret.display/3`: a value as it may be printed for its key. With reveal, the value; `DATABASE_URL` (either case) with its password masked; a secret masked; anything else as it is;
- `Ctl.Secret.mask/1`: a value by the masking rule, the app's own ([01 §5.1](01-config.md#host-config-mask)): `nil` or empty is `"unset"`, 16 characters or more `"set (…<last four>)"`, anything shorter `"set"`;
- `Ctl.Secret.mask_url/1`: a URL with the password in its userinfo replaced by `****` (`postgres://app:****@db/app`), which is what someone checking the setting needs to see;
- `Ctl.Secret.reveal/1` splits `--reveal` out of a command's arguments: `{revealed?, args}`.

**Secrets are masked on output unless `--reveal`, and `set` never echoes a value at all.**

```test:script-secret
env list shows REGISTRY_TOKEN "abcdefghijkl1234" as "set (…1234)" and never its first twelve characters; with --reveal it shows the value; mask_url of "postgres://app:pw@db/app" is "postgres://app:****@db/app"
```

```test:script-secret-mask
Ctl.Secret.mask/1 of nil and "" is "unset"; of "abcde", "abcdefghi", 15 x's and 15 é's "set"; of 12 x's then "1234" "set (…1234)" and of 12 é's then "wxyz" "set (…wxyz)"
```

## 5. Host settings {#host-script-env}

`Ctl.Env` is the host settings: what docker needs to run the container, and nothing the application itself uses (that is `config`, on the data volume). The keys are `Ctl.App.settings/0`'s, in order: the six every script has, then the app's own ([06 §3.4](06-ctl-generator.md#host-gen-derived)). `Ctl.Env.keys/0` is them.

### 5.1 Loading and resolution {#host-script-env-load}

- `Ctl.Env.load/2` takes the script's path and the process environment. **The data directory** is the script file's `@data_dir` line (§2; a script not on disk, a test's, uses the compiled one), unless `<PREFIX>_DATA_DIR` is set non-empty, which wins.
- `Ctl.Env.with_data_dir/3` reads `<data_dir>/<app>.conf` (when there is a directory and the file exists) and **resolves each key: the environment, then the file, then the built-in default, each beating the one before.** **A value that is empty counts as unset** at every level.
- The loaded settings also hold: the file's own values and its keys this script doesn't know (kept, in file order); which keys the environment set; whether the file exists (`loaded?`); and whether this run was handed an update (`<PREFIX>_CTL_SELF_UPDATED` is `"1"`, [08 §7](08-ctl-commands.md#host-cmd-update)).
- `Ctl.Env.get/2` is a key's value; `Ctl.Env.source/2` where it came from, `:environment`, `:file` or `:default`; `Ctl.Env.ref/1` is `IMAGE:TAG`; `Ctl.Env.data_path/1` is `<data_dir>/data`; `Ctl.Env.legacy_path/1` is an older script's settings file beside the script, `<app>-env`; `Ctl.Env.host_network?/1` is NETWORK `host`; `Ctl.Env.app_keys/0` maps the `:migrate_keys`' old keys to their config keys.

```test:script-env-sources
with PORT=8080 in the file and nothing else: env list shows PORT=8080 (file) and ADMIN_PORT=4001 (default); with NETWORK=host and PORT=8080 in the environment, start runs on the host's network on 8080
```

### 5.2 The settings file {#host-script-env-file}

`<app>.conf` is plain `KEY=value` lines (`Ctl.Env.parse/2`, `Ctl.Env.read_file/1`):
- blank lines and `#` comments are skipped, and an `export ` before a key is allowed;
- a key is a shell-style identifier (`Ctl.Env.valid_key?/1`);
- a value wrapped in double quotes loses them, `\"` inside read as `"`; one wrapped in single quotes loses them; an unquoted value ends where a `#` comment starts after whitespace, as in a shell, and is trimmed;
- a later line for a key wins;
- a line that is none of these is a fault, the first one answered: `"<app>.conf line N is not KEY=value: <line>"`;
- a missing file is no settings.

`Ctl.Env.render/2` writes the file for a set of values: a header saying what the file is, how it is read, and that a variable in the environment still wins for a one-off (`PORT=8080 ./<app>-ctl start`); then each known key present, in `keys/0` order, after the sentence that explains it as a comment; then, under `# Other settings, kept as they were.`, the keys this script doesn't know. A value that is empty or holds whitespace, `#` or a quote is double-quoted, `"` escaped.

```test:script-env-parse
parse/2 of "export A=1\nB=\"x y\"\nC='q'\nD=v # note\n\n# c\n" gives A "1", B "x y", C "q", D "v"; "nonsense" gives the line-1 fault
```

### 5.3 Editing in place {#host-script-env-edit}

`env set` and `env unset` edit the file's own text one line at a time, so **a comment someone wrote survives every edit:**
- `Ctl.Env.edit_set/3`: an active `KEY=` line is replaced where it stands; failing that, a commented-out `# KEY=` placeholder is taken over; failing that, the line is appended. Every other byte stays, the trailing newline included;
- `Ctl.Env.edit_unset/2`: every active `KEY=` line is removed, and the count returned; a commented placeholder is a comment and stays.

```test:script-env-edit
setting PORT=9090 and ADMIN_PORT=9091 in "# mine\nPORT=8080\n" gives exactly "# mine\nPORT=9090\nADMIN_PORT=9091\n"; edit_set over "# TAG=x\n" takes the placeholder over; edit_unset leaves a "# KEY=" placeholder in place
```

### 5.4 Validation {#host-script-env-validate}

`Ctl.Env.validate/1` checks the values a command is about to use, before anything is written or run, and answers the first problem:
- PORT a port number, 1–65535 (`"PORT must be a port number (1–65535), not …"`);
- NAME a valid container name, letters, digits, `_`, `.` and `-` (`"NAME must be a valid container name (letters, digits, _ . -)"`);
- NETWORK non-empty.

```test:script-env-validate
env set PORT=70000 is refused with the PORT message and the file is unchanged; start with NAME "bad name" in the environment answers the NAME message and runs no docker command
```

### 5.5 This host {#host-script-env-host}

What `init` seeds and `init --migrate` defaults to:
- `Ctl.Env.hostname/0`: `hostname -f`, else the short host name;
- `Ctl.Env.host_timezone/0`: the host's IANA zone, from `timedatectl show -p Timezone --value`, else `/etc/timezone`, else the `/etc/localtime` link's target after `/zoneinfo/`, else `Etc/UTC`. A container's own zone is UTC, and every time the app stamps would otherwise be in the wrong one;
- `Ctl.Env.resolve_value/1`: `:hostname` and `:timezone` as above, anything else as it is;
- `Ctl.Env.present/1`: a value, or `nil` for `nil` or `""`.

## 6. Docker command lines {#host-script-docker}

**Every docker command line is built in `Ctl.Docker`,** and `Ctl.Docker.run/2` is the only call site, through `Ctl.World`, so a test sees the exact argv of each. **Values that may be secret never appear in an argv:** they are named with `-e KEY`, and their values travel in docker's own environment, the `env:` option the `*_args` functions return beside the argv.

| Function | The argv |
|---|---|
| `Ctl.Docker.run_args/1` | `run -d --name NAME --ulimit nofile=65536:65536`, the network (below), `-v <data_dir>/data:<container_data>`, the app's `run_args/1` if it defines one, DOCKER_RUN_ARGS split on whitespace, `IMAGE:TAG` |
| `Ctl.Docker.own_data_args/1` | `run --rm --user 0:0 --entrypoint chown -v <volume> IMAGE:TAG <uid>:<gid> <container_data>` |
| `Ctl.Docker.eval_args/3` | `run --rm --user <uid>:<gid> -v <volume>`, `-e NAME` for each variable, `IMAGE:TAG <release_bin> eval EXPRESSION` |
| `Ctl.Docker.release_args/4` | `eval_args` of `<Release>.<function>()` with `<PREFIX>_CTL_ARGS` (the args as JSON) and `<PREFIX>_CTL_PASSWORD` |
| `Ctl.Docker.config_args/2` | `release_args` of `config` |
| `Ctl.Docker.migrate_args/3` | `run --rm --user 0:0 --entrypoint sh -v <old data>:/old:ro -v <volume>`, `-e SECRET_KEY_BASE` if one is carried, `IMAGE:TAG -c <copy script>` ([08 §2](08-ctl-commands.md#host-cmd-migrate)) |
| `Ctl.Docker.stop_args/1` | `stop -t <stop_timeout> NAME` |
| `Ctl.Docker.rpc_args/2` | `exec NAME <release_bin> rpc EXPRESSION` |
| `Ctl.Docker.status_args/1` | `rpc_args` of `<Release>.status()` |
| `Ctl.Docker.logs_args/2` | `logs -f --tail 100 NAME` to follow, `logs --tail N NAME` for the last N |
| `Ctl.Docker.exec_args/3` | `exec [-it] NAME COMMAND…` |

- **The network:** on `host`, `--network host -e PORT=<PORT>`, and the app listens on PORT itself; on any other network, `--network NETWORK -p <PORT>:<container port>`.
- **The ulimit is always set:** docker's own unbounded open-file limit reaches the container as about a billion, and the BEAM sizes its port table from it, reserving gigabytes at boot.
- **`eval_args/3`** runs a throwaway container of the image as the container user with the data volume mounted, so it works whether the app runs or not. A variable whose value is `nil` is left out.
- **An `rpc` runs in the app's own node,** which doesn't see this command's environment: nothing secret is passed that way.
- Queries: `ensure_available/0` (`docker info`: `:ok`; on 127 `"docker is not installed or not on PATH"`; otherwise `"cannot talk to the docker daemon — is it running, and are you in the docker group?"`), `have_image?/1`, `image_id/1` (or `nil`), `inspect_container/1` (the record, or `:none`), `container_exists?/1`, `container_running?/1`, `pull/2` (streamed; on failure `"could not pull <ref> — is 'docker login <registry>' done on this host?"`, the registry being the image's first path part), `remove_container/1` (`rm -f NAME`), `last_words/1` (`logs --tail 30 NAME`), `extract_ctl/1` (`run --rm IMAGE:TAG bin/ctl`, its stdout only, or `nil`).

```test:script-docker-start
start on bridge runs exactly: run -d --name sample --ulimit nofile=65536:65536 --network bridge -p 4000:4000 -v <data>:/data -p 4001:4001 --restart unless-stopped registry.example/acme/sample:latest
```

```test:script-docker-host
start with NETWORK host and PORT 8080: the run argv has --network host -e PORT=8080 and no -p before the volume
```

```test:script-docker-by-name
config set tz "Europe/Oslo": the eval argv is run --rm --user 2060:2060 -v <data>:/data -e SAMPLE_CTL_ARGS <ref> /app/bin/sample eval Sample.Release.config(), no argv element contains "Oslo", and the env option is [{"SAMPLE_CTL_ARGS", "[\"set\",\"tz\",\"\\\"Europe/Oslo\\\"\"]"}]
```

## 7. What the script manages {#host-script-app}

`Ctl.App` holds everything app-specific the generic modules need, from the description, so they never spell the app's name; `Ctl.AppCommands` may read it too: `name/0`, `title/0`, `script/0`, `prefix/0`, `release/0`, `release_bin/0`, `container_data/0`, `container_port/0` (a string), `ids/0` (`{uid, gid}`), `default_home/0` (`:data_home`), `stop_timeout/0` (a string), `settings/0`, `seeds/0` and `migrate_keys/0`.

## 8. Dispatch {#host-script-main}

- `Ctl.main/3` runs a command line and **returns its exit status:** 0 for `:ok`; the status of `{:halt, status}`, a child's passed through; for `{:error, message}`, the message printed on stderr and 1. The script's last line halts with it, **unless `:ctl_no_main` is set in the process dictionary,** which lets a test load the file for its modules.
- `Ctl.dispatch/3` loads the settings for the script and the environment (a fault in them is the answer), then: no arguments, `help`, `-h` or `--help` print the help; **the common commands come first** (`init`, `env`, `config`, `start`, `stop`, `restart`, `update`, `status`, `logs`, `shell`), so an app command can never shadow one; any other name listed by `Ctl.AppCommands.commands/0` goes to `Ctl.AppCommands.run/3`, **but only once the data directory is set** (else the answer of `require_home/1`, [08 §1](08-ctl-commands.md#host-cmd-common)); anything else is `"unknown command: <name>"` and the help.
- `Ctl.usage_text/1` is the help: each command with a one-line description, the app's own commands under `<Title>'s own commands:` when it has any, the data directory (or how to set one), and each host setting but DOCKER_RUN_ARGS with its value, secrets masked. Long help wraps at 78 columns.
- `Ctl.script_path/0` is where the script was loaded from, expanded, so `init` and `update` can rewrite it.

```test:script-help
run as a program, help exits 0 without a warning and lists "./sample-ctl config list | get KEY | set KEY VALUE | unset KEY", "Sample's own commands:", "./sample-ctl reset-password USER" and "ADMIN_PORT        4001"
```

```test:script-unknown
run as a program, an unknown command exits 1 with "unknown command: frob" on stderr
```

```test:script-app-needs-home
an app command run by a script with no data directory answers "no data directory yet — ./sample-ctl init [DIR]" and calls nothing
```

```test:script-app-dispatch
with a data directory, the sample's own command ping goes to Ctl.AppCommands.run/3: its last docker call is exec sample /app/bin/sample rpc Sample.Release.ping(), and the answer is the app's output
```
