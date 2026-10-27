# 01 — Configuration {#host-config}

An app's configuration lives on its data volume as `data/config.exs`, a literal map that is read and never evaluated. The app declares its settings once, and each resolves **env var > `config.exs` > default**. Seven projects had written this reader for themselves (macaw_compose#33); `macaw_host` takes macaw's `ConfigFile` and fixes what it got wrong (macaw_compose#46).

## 1. The literal file {#host-config-literal}

`Macaw.Host.Config.Literal` reads and writes the file. A **literal** is an atom (`nil`, `true` and `false` included), a string, a number (negative ones included), a list, a map, or a tuple of any size, nested freely. Anything else is a fault.

### 1.1 Parsing {#host-config-parse}

`Macaw.Host.Config.Literal.parse/2` parses a file's text (its second argument names the file in faults, `"config.exs"` by default) to `{:ok, map}` or `{:error, faults}`:
- **nothing is evaluated.** A call, a variable, a module attribute, string interpolation or a sigil is a fault, `"<file>:<line>: not a literal: <the code>"`;
- **every such fault is reported at once,** in source order, each with its line, so a broken file says everything that is wrong in one message (macaw stopped at the first);
- **negative numbers and tuples of any size are literals** (macaw refused `-1` and three-element tuples, so `%{offset: -5}` failed to load);
- **the text must be a single literal map;** anything else is the one fault `"<file> must contain a single literal map"`;
- **text that does not parse** (a syntax error) is one fault, `"<file>:<line>: <message>"`; the parser stops there, so nothing after it is reported.

```test:literal-reads
%{a: 1, b: -2.5, c: [1, "x", :closed], d: {1, 2, 3}, e: %{f: {:open, nil}}} parses to that map
```

```test:literal-faults
a map holding System.cmd(…), @doc, a variable and "#{1 + 1}" on lines 2–5 gives exactly four faults, each "config.exs:<line>: not a literal: <code>" with its own line
```

```test:literal-not-map
"[a: 1]" gives {:error, ["config.exs must contain a single literal map"]}
```

### 1.2 No atom is made {#host-config-atoms}

**Parsing never creates an atom.** A name that doesn't already exist in the VM (a key `typo_key:`, a value `:ajar`) is a fault (`"<file>:<line>: unsafe atom does not exist: <name>"`), so a typo can't grow the atom table and can't silently become a new setting. Like a syntax error, it stops the parse and is the only fault reported.

```test:literal-no-atom
"%{<a name never used>: 1}" gives one fault containing "unsafe atom", and afterwards String.to_existing_atom/1 of the name still raises
```

### 1.3 Reading a file and a value {#host-config-read}

- `Macaw.Host.Config.Literal.read!/1` returns the map in a file, **`%{}` when the file doesn't exist,** and raises on anything else: `File.Error` when it can't be read, `ArgumentError` listing every fault, one per line.
- `Macaw.Host.Config.Literal.parse!/2` is `parse/2`, raising `ArgumentError` listing every fault.
- `Macaw.Host.Config.Literal.parse_value/2` parses **one** literal value someone typed (any literal, not only a map), with the same rules; its second argument names it in faults, `"value"` by default.

```test:literal-missing
read!/1 of a path that doesn't exist is %{}
```

### 1.4 Writing {#host-config-write}

`Macaw.Host.Config.Literal.write!/3` writes a map as the file's literal text:
- **atomically:** a temporary file beside it (`<path>.tmp`), **made 0600 while still empty,** then written, then renamed over the file. A crash leaves the old file or the new one, never a partial one, and there is no moment the file is readable by others (it may hold a password; macaw wrote first and then set the mode);
- the parent directory is created if missing;
- `header`, if given, is written first, each of its lines as a `# ` comment;
- then `%{`, one `key => value` line per key **in sorted order,** and `}`;
- values are written so they read back: never truncated, and **a list of small integers is written as a list,** never as a `~c"…"` sigil (which is a call, and would not read back; found by the round-trip property, macaw_compose#46).

Write then read is the identity for any map of literals.

```test:literal-write
write!/3 of %{port: 4001, hosts: ["a", "b"], mode: :open, offset: -3, t: {1, 2, 3}} with a two-line header: the file is mode 0600, no .tmp file is left, it starts "# a header\n# second line\n", and read!/1 returns the map
```

```test:literal-round-trip
property: write!/3 then read!/1 returns the same map, for maps of nested lists, 3-tuples, integers, floats, strings, booleans, nil and atoms
```

## 2. Setting types {#host-config-types}

`Macaw.Host.Config.Types` is the types a setting can have, and how a value of each is **checked** from the file (a literal, `Macaw.Host.Config.Types.check/2`) or **cast** from an env var (a string, `Macaw.Host.Config.Types.cast/2`). Both return `{:ok, value}` or `{:error, why}`.

| Type | From the file | From an env var |
|---|---|---|
| `:string`, `:secret` | a string | as it is |
| `:optional_string` | a string or `nil` | as it is; empty is `nil` |
| `:boolean` | `true` or `false` | `true`, `false`, `1` or `0`, any case, trimmed |
| `:integer` | an integer | decimal digits (a sign allowed), trimmed |
| `:pos_integer` | an integer above 0 | the same, above 0 |
| `:port` | an integer in 1–65535 | the same, in 1–65535 |
| `{:enum, [atom]}` | one of the atoms | one of their names, trimmed |
| `:string_list` | a list of strings | comma-separated, each trimmed, empty ones dropped |
| `{:custom, {m, f}}` | whatever `m.f(value)` returns | the same, given the string |

- **An enum name from an env var is compared as a string,** so no atom is made.
- `{:custom, {m, f}}`: `m.f/1` must return `{:ok, value}` or `{:error, message}`.
- A `:secret` is a string that is masked wherever a value is shown (§5).
- `Macaw.Host.Config.Types.describe/1` is a type in words, for faults: `"a port number (1–65535)"`, `"one of [:open, :closed]"`.
- Faults: a file value of the wrong shape is `"must be <describe(type)>"`, except an enum, `"must be one of [:open, :closed]"`, and a list with a non-string, `"must be a list of strings"`; an env value is `"must be <describe(type)>"`, except a boolean, `"must be true or false"`, and an enum, `"must be one of open, closed"` (the names).

```test:types-env
from env vars: :boolean "1" is true, :string_list "a, b,,c" is ["a", "b", "c"], :integer "-5" is -5, {:enum, [:open, :closed]} "open" is :open
```

## 3. Resolution {#host-config-resolve}

An app declares its settings once, as `{name, type, default}` (`Macaw.Host.Config.spec()`), and `Macaw.Host.Config.resolve/4` resolves them from an env map, the file's map and the env var prefix. It is pure: `{:ok, resolved}` or `{:error, faults}`.
- **Each setting resolves env var > `config.exs` > default:**
  - its env var, `<PREFIX>_<NAME>` (`Macaw.Host.Config.env_var/2`, the name upper-cased), wins when it is present, even empty, cast by its type; the source is `:env`;
  - else the file's key, checked by its type; the source is `:file`. A key may be written as an atom or a string;
  - else the default, as declared and unchecked; the source is `:default`.
- **Every fault at once:** every unknown key in the file (`"config.exs: unknown setting :typo_key"`), then every invalid value, in declared order, each named with where it came from (`"APP_PORT: must be a port number (1–65535)"`, `"config.exs debug: must be true or false"`). A boot that fails says everything that is wrong in one message.
- `resolved` maps each name to `%{value: value, source: :env | :file | :default}`.

```test:config-order
with APP_PORT "8080" in env and port 9090 and public_host "example.com" in the file: port is 8080 from :env, public_host "example.com" from :file, debug its default from :default
```

```test:config-all-faults
a bad port and an unknown enum name in env, a non-boolean debug, an unknown typo_key and a non-string list in the file give exactly those five faults, each in the form above
```

## 4. Loading at boot {#host-config-load}

`Macaw.Host.Config.load!/3` reads the file at `:path` and the environment (`:env`, default `System.get_env/0`), resolves with `:env_prefix`, and stores the result under the app:
- a missing file is an empty map; a file that can't be read raises `File.Error`;
- a file with faults raises `ArgumentError` listing them; a resolution with faults raises `ArgumentError`, `"invalid configuration:"` and each fault on its own line;
- the resolved values and the specs are kept in `:persistent_term` under `{Macaw.Host.Config, app}` and read without copying; it returns the resolved map.

Then `Macaw.Host.Config.get/2` is a setting's value and `Macaw.Host.Config.source/2` where it came from. Both raise `ArgumentError` for a name the app didn't declare, `"<app> declares no setting <name>"`. `Macaw.Host.Config.keys/1` is the settings' names in declared order.

```test:config-load
load!/3 with APP_PORT "81" in env and a secret in the file: get(:port) is 81, source(:port) is :env, get of an undeclared name raises "declares no setting :nope"
```

```test:config-load-faults
load!/3 of a file with port 0 and debug 3 raises ArgumentError naming "config.exs port" and "config.exs debug"
```

## 5. Showing values {#host-config-show}

- `Macaw.Host.Config.show/1` is every loaded setting as `{name, shown, source}`, in declared order, the value shown by `mask/2`.
- `Macaw.Host.Config.mask/2` shows a value: a `:secret` that is `nil` is `"unset"`, one of four bytes or fewer `"set"`, any longer one `"set (…<last four>)"`; a value of any other type is `inspect`ed. A secret's value is never shown.

```test:config-show-masks
with smtp_password "hunter2-long-secret" in the file, show/1 holds {:smtp_password, "set (…cret)", :file} and no shown value contains "hunter2"
```

## 6. Editing for the ctl {#host-config-edit}

`<app>-ctl config set` and `unset` change the file through the app ([03 §3](03-release.md#host-release-config)), with these:
- `Macaw.Host.Config.put!/4` sets a setting, by name as typed, to a value as typed. The name is **matched as a string** against the declared names, so nothing typed becomes an atom (`"no setting named prot"`). The value is parsed as a literal (`parse_value/2`; nothing is evaluated) and checked against the setting's type. **An enum value is matched by name,** `open` or `:open`, so a typo answers `"must be one of open, closed"` instead of an atom fault. It returns `{:ok, value}` after writing the file (§1.4, with a header saying the file is a literal map edited with `<app>-ctl config set` and that an env var still wins), or `{:error, why}` with **the file untouched.**
- `Macaw.Host.Config.delete!/3` removes a setting from the file, so it falls back to its env var or default: `:ok`, or `{:error, "no setting named …"}`.

```test:config-put
put!/4 "port" "8443" gives {:ok, 8443} and "mode" ":open" {:ok, :open}; then "port" "70000", "prot" "1" and "public_host" "System.halt()" each give an error, and the file is byte for byte as before and reads %{port: 8443, mode: :open}
```

```test:config-delete
after put!/4 of port, delete!/3 of "port" leaves the file reading %{}
```
