# 06 — The ctl generator {#host-gen}

Every deployable app ships a host control script, `<app>-ctl`: a single Elixir file, standard library only, that runs the app's container on a host. Nine projects kept a 1,700–3,000-line copy by hand, in three generations, its generic half about 1,000 lines (macaw_compose#33). `macaw_host` generates it instead, from three parts (macaw_compose#48):
- **the generic modules,** EEx templates in `priv/ctl/` compiled into `Macaw.Host.Ctl` (head, world, env, docker, commands, main), taken from astex's script, the reference the pattern names, and reconciled with the other generations;
- **the description,** the `:ctl` key of the app's `mix.exs`, which fills in everything app-specific (§3);
- **the app's own commands,** a source file defining `Ctl.AppCommands`, spliced in as it is (§4).

What the generated script does is [07](07-ctl-script.md) and [08](08-ctl-commands.md).

## 1. The Mix task {#host-gen-task}

`mix macaw.host.ctl` (`Mix.Tasks.Macaw.Host.Ctl.run/1`) generates the app's script:
- it reads the `:ctl` description from the project config, with the project's `:app` as the default `:otp_app` (§3), and the app commands file (`:app_commands`, `"ctl/app_commands.ex"` by default; `false` for none);
- it **writes the script to `:output`** (`"container/<name>-ctl"` by default), creating the directory, **mode 0755,** and says `wrote <path>`;
- **`--check`** (for CI) regenerates in memory and compares with the committed file: `<path> is up to date`, or it fails (`Mix.Error`) with `"<path>: the committed script differs from what the generator makes, first at line N:"`, the generated and committed lines, and `"Run mix macaw.host.ctl to regenerate it."` A script edited by hand, or a generator or app commands changed without regenerating, never ships;
- any other argument fails with `"usage: mix macaw.host.ctl [--check]"`; a project without `:ctl`, an invalid description or app commands file, or an app commands file that can't be read (`"cannot read the app commands <path>: <reason>"`) fails naming it.

```test:gen-task
in a sample project, the task writes container/sample-ctl at mode 0755, equal to Macaw.Host.Ctl.generate/2 of the same inputs; --check then passes; after one line is edited --check fails naming the edited text and "Run mix macaw.host.ctl to regenerate it."
```

```test:gen-task-no-ctl
in a project without :ctl, the task fails matching "mix.exs has no :ctl key"
```

## 2. Generating {#host-gen-generate}

- `Macaw.Host.Ctl.build/2` takes the description (a `:ctl` keyword list, or the map `Macaw.Host.Ctl.Description.new/2` returned) and the source of the app's commands (`nil` for none), checks both, and returns `{:ok, script}` or `{:error, message}`. The script is the generic modules and the app's source, in order, formatted with `Code.format_string!/1`, ending in a newline.
- `Macaw.Host.Ctl.generate/2` is `build/2`, raising `ArgumentError` with the message.
- **Generation is deterministic:** the same inputs give the same bytes, which is what makes `--check` possible.
- **The script parses** as Elixir, compiles **without a warning** (a host would see it on every run), and holds **no `try`, `catch` or `rescue`.**
- With no app commands, the script carries a `Ctl.AppCommands` whose `commands/0` is `[]` and whose `run/3` answers `{:error, "unknown command: <name>"}`.

```test:gen-deterministic
generate/2 of the sample description and commands parses as Elixir and gives the same text twice
```

```test:gen-no-try
the generated script's AST holds no try node, and no line starts with rescue
```

```test:gen-bare
a description without settings, seeds or migrate_keys and no app commands gives a script whose help runs with exit 0, no warning, and no "own commands" section
```

```test:gen-no-app-commands
generate/2 with nil app commands gives a script that parses, whose Ctl.AppCommands has commands/0 [] and answers run("frob", env, []) with {:error, "unknown command: frob"}
```

### 2.1 The generated head {#host-gen-head}

The script starts `#!/usr/bin/env elixir`, then a comment saying it is generated and must not be edited by hand, then the **version guard**, before any module: on an Elixir older than 1.18, or without its `JSON` module, it prints one clear sentence on stderr (`"<app>-ctl needs Elixir 1.18 or newer (for its JSON module); this is Elixir X."` and where to install one) and halts with status 1. **`Ctl.Home` is the first module,** holding the one `@data_dir` line ([07 §2](07-ctl-script.md#host-script-home)).

```test:gen-guard-first
the script starts "#!/usr/bin/env elixir\n"; its first top-level expression is the unless guard on Version.match?(System.version(), ">= 1.18.0"), its second defmodule Ctl.Home
```

```test:gen-one-data-dir
the script has exactly one line matching ^\s*@data_dir, "  @data_dir nil", inside defmodule Ctl.Home … end
```

## 3. The description {#host-gen-description}

`Macaw.Host.Ctl.Description.new/2` checks the `:ctl` description once, so the templates can trust every value, and returns `{:ok, description}` with every default filled in and the values the templates derive, or `{:error, message}` naming the first fault. `Macaw.Host.Ctl.Description.new!/2` raises `ArgumentError` with the message instead.

```elixir
ctl: [
  name: "astex",
  image: "gitlab.conet.yarina.org:5005/dco-tek/astex",
  env_prefix: "ASTEX",
  release: "Astex.Release",
  uid: "2060:2060",
  port: 4000
]
```

### 3.1 Required keys {#host-gen-required}

| Key | What it is | Must be |
|---|---|---|
| `:name` | the app's name: the script is `<name>-ctl`, its settings `<name>.conf` | lower-case letters, digits, `-` and `_`, starting with a letter |
| `:image` | the image, without a tag | a non-empty string |
| `:env_prefix` | the release protocol's prefix: `<PREFIX>_CTL_ARGS` and the like | upper-case letters, digits and `_`, starting with a letter |
| `:release` | the release module whose `config/0` and `status/0` the script calls | a module name as a string, `"MyApp.Release"` |
| `:uid` | the container user's fixed `"uid:gid"` | two numbers, `"2060:2060"` |
| `:port` | the port the app listens on in the container, and the default PORT | an integer in 1–65535 |

### 3.2 Optional keys {#host-gen-optional}

| Key | Default | What it is |
|---|---|---|
| `:title` | the name, capitalized | the app's name in prose |
| `:otp_app` | the project's `:app`, else the name with `-` as `_` | names the release's start script |
| `:release_bin` | `"/app/bin/<otp_app>"` | the release's start script in the image (an absolute path) |
| `:tag` | `"latest"` | the default TAG |
| `:network` | `"bridge"` | the default NETWORK; `"host"` shares the host's |
| `:bind` | `"127.0.0.1"` | the default BIND, the host address PORT is published on ([07 §6](07-ctl-script.md#host-script-docker)); an IP address as a string. **Loopback by default:** a proxy on the same host reaches the app and nothing else does. An app that must be reached from another host widens it here (`bind: "0.0.0.0"`, every interface), or the operator sets BIND. With `network: "host"` it must be `"0.0.0.0"`, since nothing is published |
| `:container_data` | `"/data"` | where the data volume is mounted (an absolute path) |
| `:docker_run_args` | `"--restart unless-stopped"` | the default DOCKER_RUN_ARGS |
| `:stop_timeout` | `30` | seconds `stop` gives the app (an integer, 0 or more) |
| `:data_home` | `"/srv/<name>"` | the data directory `init` offers (an absolute path) |
| `:seeds` | `[]` | app config `init` seeds: `[tz: :timezone, phx_host: :hostname, phx_scheme: "http"]`, each a lower-case config key and `:hostname`, `:timezone` or a literal (a string, integer or atom) |
| `:migrate_keys` | `[]` | `{"OLD_KEY", "config_key", old default}` that `init --migrate` carries from `<name>-env`, the old default `nil`, `:hostname`, `:timezone` or a string |
| `:settings` | `[]` | the app's own host settings, `{"KEY", "default", "help"}`, the key upper-case and not one of the seven every script has |
| `:host_network` | `true` | `false` refuses `NETWORK=host` ([07 §5.4](07-ctl-script.md#host-script-env-validate)), for an app whose listeners must stay off the host's interfaces (a console bound inside the container) |
| `:app_keys` | `[]` | `{"KEY", "config_key"}`: a name that is the app's own configuration, which `env set` refuses with a pointer to `config set` ([08 §3](08-ctl-commands.md#host-cmd-env)); KEY upper-case, never a host setting |
| `:update_note` | `nil` | what `update` prints, as a line of its own, once it has recreated the container from a new image and only then ([08 §7](08-ctl-commands.md#host-cmd-update)): what an operator must know about that step, such as that the new image migrates the data when it starts and rolling back restores code, not data. A non-empty string, or `nil` for nothing; carried into the script as data (`Ctl.App.update_note/0`) |
| `:app_commands` | `"ctl/app_commands.ex"` | the file defining `Ctl.AppCommands`, or `false` for none |
| `:output` | `"container/<name>-ctl"` | where the script is written |

### 3.3 Faults {#host-gen-description-faults}

Checked in this order, the first fault answered:
- **no `:ctl` key:** `"mix.exs has no :ctl key in its project config (see Macaw.Host.Ctl.Description)"`; not a keyword list or map: `":ctl must be a keyword list, not …"`;
- **any key it doesn't know:** `":ctl has unknown keys: :prot"`. A misspelled optional key silently taking its default is the bug this refuses;
- **every missing required key,** named together: `":ctl is missing :release, :uid"`;
- **a value of the wrong shape:** `":ctl :uid must be \"uid:gid\", both numbers, not \"app\""`, and likewise for each key of §3.1 and §3.2 (`:bind` is an address `:inet.parse_strict_address/1` takes: `":ctl :bind must be an IP address as a string, like \"127.0.0.1\" or \"0.0.0.0\", not \"localhost\""`);
- **an `:update_note` that is neither `nil` nor a string with something in it:** `":ctl :update_note must be a non-empty string, or nil, not \"\""`, and likewise for an atom or a string of spaces;
- **a `:bind` other than `"0.0.0.0"` with `network: "host"`:** `":ctl :bind must be \"0.0.0.0\" with network: \"host\", which publishes no port, not \"127.0.0.1\""`. The app listens on the host's own interfaces there, and the script would refuse its own defaults ([07 §5.4](07-ctl-script.md#host-script-env-validate)), so a host-network app states `bind: "0.0.0.0"`;
- **a setting that redefines one of the seven:** `":ctl :settings cannot redefine PORT, which every script has"`; a setting key that isn't upper-case, or an entry that isn't `{"KEY", "default", "help"}`, is named too;
- **an app key that names a host setting:** `":ctl :app_keys names ADMIN_PORT, which is a host setting"` (`env set` would refuse the setting it edits).

```test:gen-description-faults
missing :release and :uid gives ":ctl is missing :release, :uid"; an extra prot: 1 gives ":ctl has unknown keys: :prot"; uid "app" gives the message above; a PORT setting gives the redefine message; nil gives the no-:ctl message
```

```test:gen-description-bind
bind "localhost" gives ":ctl :bind must be an IP address as a string, like \"127.0.0.1\" or \"0.0.0.0\", not \"localhost\"" and a tuple is refused likewise; network "host" without :bind gives the host-network message; network "host" with bind "0.0.0.0" is accepted; bind "::1" is the BIND setting's default
```

```test:gen-description-update-note
update_note "" gives ":ctl :update_note must be a non-empty string, or nil, not \"\"", :migrates and "  " are refused likewise; without it the description has update_note nil and the script def update_note, do: nil; the sample script's Ctl.App.update_note/0 is its description's
```

### 3.4 What the templates are given {#host-gen-derived}

Beside the filled-in keys, the checked description holds:
- `:script`, `"<name>-ctl"`;
- `:ids`, `{uid, gid}` as integers;
- `:otp_app` as a string, and `:seeds` with string keys;
- `:settings`, **the seven every script has, then the app's own,** each with the sentence that explains it in `<name>.conf`:

| Key | Default | |
|---|---|---|
| `PORT` | the `:port` | the web port |
| `NETWORK` | the `:network` | `host` shares the host's network; any other value is a docker network to join, PORT published to the container's port |
| `BIND` | the `:bind` | the address PORT is published on: 127.0.0.1 keeps the app on this host (a proxy on the same host reaches it), 0.0.0.0 publishes it on every interface |
| `IMAGE` | the `:image` | the image, its tag and the container's name |
| `TAG` | the `:tag` | |
| `NAME` | the `:name` | |
| `DOCKER_RUN_ARGS` | the `:docker_run_args` | extra arguments for `docker run` |

```test:gen-description-app-keys
host_network "no" gives ":ctl :host_network must be true or false, not \"no\""; app_keys [{"smtp", "smtp_host"}] the shape message; app_keys naming ADMIN_PORT "names ADMIN_PORT, which is a host setting"; the sample's description has host_network true and its app key
```

```test:gen-defaults
new/2 of the sample description without settings, with otp_app :sample_web: title "Sample", release_bin "/app/bin/sample_web", tag "latest", network "bridge", bind "127.0.0.1", data_home "/srv/sample", app_commands "ctl/app_commands.ex", output "container/sample-ctl", script "sample-ctl", ids {2060, 2060}, and the settings' keys PORT NETWORK BIND IMAGE TAG NAME DOCKER_RUN_ARGS
```

```test:gen-description-values
the generated script carries the description: Ctl.App.prefix/0 "SAMPLE", ids/0 {2060, 2060}, release_bin/0 "/app/bin/sample"
```

`Macaw.Host.Ctl.generate/2` and `build/2` take a map that already holds `:script` and `:ids` as checked, and check anything else with `new/2`; `generate/2` raises naming the fault (`":ctl is missing :port"`).

```test:gen-generate-raises
generate/2 of the sample description without :port raises ArgumentError with exactly ":ctl is missing :port"
```

## 4. The Ctl.AppCommands contract {#host-gen-app-commands}

The app's file holds one module, `Ctl.AppCommands`, **and nothing beside it:** a module of its own is nested inside it (`defmodule Helpers` within `Ctl.AppCommands`), and code outside it, which would run every time the script loads, is refused. The module has:
- **`commands/0`:** `[{name, usage, help}]`, the app's commands. `name` is what is typed (`"asterisk"`), `usage` how `help` shows it (`"asterisk [CLI COMMAND]"`), `help` one sentence. They are listed in `help` under the app's own heading.
- **`run(name, env, args)`:** runs one, returning what the common commands do: `:ok`, `{:error, message}` (printed on stderr, exit 1) or `{:halt, status}`. **It is called only once the data directory is set** ([07 §8](07-ctl-script.md#host-script-main)).
- **optionally `run_args(env)`:** extra `docker run` arguments (more ports, say), placed before DOCKER_RUN_ARGS ([07 §6](07-ctl-script.md#host-script-docker)).
- **optionally `validate(env)`:** `:ok` or `{:error, message}`, the app's own checks of its host settings (a second port is a port, and not PORT), run after the common ones by `Ctl.Env.validate/1`, so on every `env set`, `start` and throwaway container ([07 §5.4](07-ctl-script.md#host-script-env-validate); macaw_host#1).
- **optionally `before_start(env)`:** `:ok` or `{:error, message}`, the app's own precondition for `start` (apu refuses while nobody could sign in), asked once the image and the data are ready and **before the container is removed or run**, so a refusal leaves a running container as it was ([08 §5](08-ctl-commands.md#host-cmd-start)).
- **optionally `init_flags()`:** `[{flag, :switch | :value}]`, init's flags of the app's own (`[{"--user", :value}, {"--auth-file", :value}]`), declared as data; `init` takes them beside its own, and an app's flag named like one of init's own is init's ([08 §2](08-ctl-commands.md#host-cmd-init)). A malformed declaration (a flag without `--`, another kind) fails init loudly.
- **optionally `after_init(env, flags)`:** the app's own step once `init` has adopted and seeded (or migrated) the data directory, `flags` a map of the app's flags given (`%{"--user" => "ann", "--quiet" => true}`, `%{}` for none); its answer is init's: `:ok`, `{:error, message}` or `{:halt, status}`. **It must be safe to rerun:** init can be rerun on an adopted directory (`init --force` with the same `DIR`), and calls it on every successful init. **A value flag's value reaches the app's own code here, in-process;** the script never puts it on a docker command line, and when the app passes it to a container it does so by name, as a secret ([07 §6](07-ctl-script.md#host-script-docker)), since it may be one (a file holding a bind password, say).
- **optionally `seeds(env)`:** `[{config key, value}]`, app config `init` seeds that the app computes from this host's settings (a console URL from its bind and port), after the description's `:seeds` and by the same rule ([08 §2.1](08-ctl-commands.md#host-cmd-seed)).
- **optionally `status_lines(env, report)`:** lines `status` prints with the host's (its other ports, say), after `data:` ([08 §8](08-ctl-commands.md#host-cmd-status)). **`report` is the app's own report** as `status` read it (the last JSON object of `rpc <Release>.status()`, a map with string keys), so a line can say what only the running app knows (apu's plain-HTTP warning); it is `nil` when the app isn't running or didn't answer, and the line then says only what the host's settings know. The hook took only `env` before 0.3.0 (`status_lines/1`); that arity is no longer called, and the generator refuses it (below).

An optional function the app doesn't define is never called, and is called through `apply/3`, so its absence compiles without a warning.

**A name the script already has** (`start`, `config` …) **is never dispatched to it:** the common commands come first.

It builds its docker command lines with `Ctl.Docker` (`exec_args/3`, `rpc_args/2`, `eval_args/3`, `release_args/4`), runs them with `Ctl.Commands.stream/1` or `interactive/1`, checks the container with `Ctl.Commands.ensure_running/1` or `ensure_ready/1`, reads a release's answer with `Ctl.Commands.decode_lines/1` (every line an object) or `Ctl.Commands.last_object/1` (the last JSON object, after any log lines; macaw_host#1), reads and writes files on the host with `Ctl.World.read_local/1` and `write_local/2` (so a test records them), asks with `Ctl.World.prompt/1` and `prompt_secret/1`, and reads what it manages from `Ctl.App`. **A secret goes to the container by name,** through `eval_args/3` or `release_args/4`, never on a command line.

```test:gen-app-commands-secret
the sample's reset-password alice, the password answered at prompt_secret, runs one eval container whose argv is exactly the eval argv of 07 §6 with -e SAMPLE_CTL_ARGS -e SAMPLE_CTL_PASSWORD and Sample.Release.reset_password(), no element of it holding the password, with env [{"SAMPLE_CTL_ARGS", "[\"alice\"]"}, {"SAMPLE_CTL_PASSWORD", <the password>}]
```

`Macaw.Host.Ctl.app_commands/1` checks the file's source, so it can neither replace a generic module nor carry a second `@data_dir`:
- it must parse (`"Ctl.AppCommands does not parse: line N: …"`);
- its top-level modules must be `Ctl.AppCommands` or named under it (`"the app commands file may define only Ctl.AppCommands, not Ctl.Home"`), and `Ctl.AppCommands` must be among them (`"the app commands file must define Ctl.AppCommands"`);
- **its one top-level expression is `defmodule Ctl.AppCommands`:** any other (a call, an `alias`, a literal, a submodule defined beside the module rather than inside it, a second `Ctl.AppCommands`) is refused naming the first such and its line, `"the app commands file may hold only the Ctl.AppCommands module; line N is outside it: <its first line>"` (macaw_compose#70);
- it must define `commands/0` and `run/3` (`"Ctl.AppCommands must define run/3"`);
- it must not set `@data_dir` on any line (`"Ctl.AppCommands must not set @data_dir: the script's one line of host state is in Ctl.Home"`);
- it must not define `status_lines/1`, the hook's arity before 0.3.0, which the script no longer calls: an app still defining it would lose its lines without a word, so it is refused when the script is generated, `"Ctl.AppCommands.status_lines/1 is now status_lines/2 (env, report)"`.

`nil` is the module of no commands (§2).

```test:gen-app-commands-shape
only Ctl.AppCommands.Helpers gives "must define Ctl.AppCommands"; "defmodule Other" gives "may define only Ctl.AppCommands, not Other"; a module with commands/0 and no run/3 gives "must define run/3"
```

```test:gen-app-commands-stray
a fixture with Ctl.AppCommands and then `alias Ctl.AppCommands` and a File.rm_rf! call is refused naming line 10, "alias Ctl.AppCommands"; a bare :ok on line 1 and a Ctl.AppCommands.Helpers defined beside the module are refused likewise; a Helpers module nested inside it is accepted
```

```test:gen-app-commands-guard
the sample commands plus a defmodule Ctl.Home give "may define only Ctl.AppCommands, not Ctl.Home"; the sample commands with an @data_dir line give "must not set @data_dir"; an unterminated module gives "does not parse: line 1"
```

```test:gen-app-commands-status-lines
the sample commands with status_lines(env) in place of status_lines(env, report) give exactly "Ctl.AppCommands.status_lines/1 is now status_lines/2 (env, report)" from app_commands/1, and generate/2 raises ArgumentError with that message; the sample commands as they are are accepted
```

```test:gen-app-last-object
Ctl.Commands.last_object/1 of a log line, a JSON object, a line that isn't JSON and a second object is the second object; of output with no object, nil
```

## 5. Comparing for --check {#host-gen-compare}

`Macaw.Host.Ctl.compare/2` is `:ok` when the committed text is exactly the generated text, else `{:error, message}` naming the first line that differs: `"the committed script differs from what the generator makes, first at line N:"`, then `generated:` and `committed:`, each line `inspect`ed, or `(end of file)` where one text has ended (the newline ending a text's last line starts no line of its own). When every line agrees and only the final newline differs, it names the last line, the side without the newline marked `(no newline at the end of the file)`.

```test:gen-compare
the same text is :ok; one changed line is named with its number and both versions; a file truncated after line 1 differs "first at line 2:"
```

## 6. The recorder {#host-gen-recorder}

`Macaw.Host.Ctl.Recorder` is a recording stand-in for a generated script's `Ctl.World` ([07 §3](07-ctl-script.md#host-script-world)), so an app's tests drive every `<app>-ctl` command without docker on the box and **assert each command's exact docker argv.** It ships in `lib/`, not `test/support/`: a dependency's test support is never compiled into the app that depends on it, and every app's tests then use the one recorder that matches the generated `Ctl.World`. It has no dependencies and does nothing until `install/2` names it in the calling process.

```elixir
# test/test_helper.exs: once per VM, before any test runs, since the
# script's modules (`Ctl`, `Ctl.Env` …) are global.
Macaw.Host.Ctl.Recorder.load!("container/my_app-ctl")

# a test, with `@moduletag :tmp_dir`
{script, _home} = Recorder.home!(tmp_dir, "my_app-ctl")
Recorder.install([{["docker"], {"", 0}}])
Ctl.dispatch(["start"], %{}, script)
```

- `Macaw.Host.Ctl.Recorder.load!/1` loads a generated script's modules without running it: `:ctl_no_main` is set in the process dictionary while the file is required, which keeps its last line from calling `main/1`. A script is loaded once per VM, since its modules are global.
- `Macaw.Host.Ctl.Recorder.install/2` makes this process's `Ctl.World` the recorder, with the canned replies: `{matcher, {output, status}}`, the matcher a list that `[exe | args]` must start with, or a function of `(exe, args)`. **The first matching entry answers; anything unmatched is `{"", 1}`,** a docker that says no. Option `:answer` is what `prompt/1` and `prompt_secret/1` answer (`""` by default); option `:files`, a map of host paths to their text, is what `read_local/1` answers, any other path `{:error, :enoent}`; `write_local/2` writes nothing, is recorded as `{:write_local, path, bytes}` and answers `:ok` (macaw_host#1). A call with `into:` (a streamed one) has its output collected into that collectable.
- `Macaw.Host.Ctl.Recorder.calls/0` is every call so far, in order: `{exe, args, opts}` (the options say where a secret's value travels, in `:env`), `{:sleep, ms}`, `{:prompt, question}`, `{:prompt_secret, question}`. `Macaw.Host.Ctl.Recorder.docker_calls/0` is the argv of each docker call.
- **Everything lives in the calling process's dictionary,** so async tests never see each other's calls.
- `Macaw.Host.Ctl.Recorder.script!/2` writes a minimal script whose `Ctl.Home` names a data directory (or `nil`): the only part of the file the loaded modules read from disk. `Macaw.Host.Ctl.Recorder.home!/2` makes a host under a temporary directory, `home/data/` and a script naming `home`, and returns `{script, home}`.
- `cmd/3`, `sleep/1`, `prompt/1` and `prompt_secret/1` are the `Ctl.World` callbacks it answers.

```test:gen-recorder
with the recorder installed, start records exactly the docker argv sequence of 08 §5 and a {:sleep, 2000}; an unmatched call answers {"", 1}; calls made in another process are not seen
```
