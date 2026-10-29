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
- `Macaw.Host.Config.Literal.read/1` is the same without raising: `{:ok, map}` (`%{}` when the file doesn't exist), or `{:error, faults}`, every parse fault or the one `"cannot read <path>: <reason>"`. The ctl's paths read with it, so a broken file is an answer, never a stack trace (macaw_compose#70).
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
| `{:custom, module}` | `module.check(value)` | `module.cast(string)` |
| `{:custom, {m, f}}` | whatever `m.f(value)` returns | the same, given the string |

- **An enum name from an env var is compared as a string,** so no atom is made.
- `{:custom, {m, f}}`: `m.f/1` must return `{:ok, value}` or `{:error, message}`.
- **`{:custom, module}`**: the module implements the `Macaw.Host.Config.Type` behavior (macaw_host#1), and so owns the type: `check/1` (a file value), `cast/1` (an env var's string), `show/1` (how a value is shown, §5) and `describe/0` (the type in words). It is for what the built-in types can't hold: a structure with a secret inside (collpa#141's `auth` block, an LDAP source with its bind password), an address, a block of fields. `show/1` must take any term, since a value that didn't check is shown by it too.
- A `:secret` is a string that is masked wherever a value is shown (§5).
- `Macaw.Host.Config.Types.describe/1` is a type in words, for faults: `"a port number (1–65535)"`, `"one of [:open, :closed]"`.
- Faults: a file value of the wrong shape is `"must be <describe(type)>"`, except an enum, `"must be one of [:open, :closed]"`, and a list with a non-string, `"must be a list of strings"`; an env value is `"must be <describe(type)>"`, except a boolean, `"must be true or false"`, and an enum, `"must be one of open, closed"` (the names).

```test:types-custom-module
{:custom, Macaw.Host.Test.SignInBlock}: check of %{password: "x"} is {:ok, …} and of 3 "must be a sign-in block"; cast is the module's refusal; describe/1 is "a sign-in block"
```

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
- **One setting at a time:** `Macaw.Host.Config.resolve_setting/4` resolves a single spec by the same rules, `{:ok, %{value, source}}`, or `{:error, %{raw, source, fault}}` with the value as found (the env var's string, the file's literal) and the fault as `resolve/4` words it. `resolve/4` is built on it, and so is `<app>-ctl config list` ([03 §3](03-release.md#host-release-config)), so what the ctl shows is what the app boots with.
- A file key that is neither an atom nor a string (a tuple, say) is an unknown setting, named by its inspection.

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
- `Macaw.Host.Config.mask/2` shows a value: a `:secret` by the masking rule (§5.1); a `{:custom, module}` value by `module.show/1`, so a secret inside a structure is masked by the type that knows where it is; a value of any other type is `inspect`ed. A secret's value is never shown, whether the value checked or not.

### 5.1 The masking rule {#host-config-mask}

The one rule for showing a secret, in the app (`Macaw.Host.Config.mask/2`) and in the generated script (`Ctl.Secret.mask/1`, [07 §4](07-ctl-script.md#host-script-secret)) alike:
- **`nil` or empty** is `"unset"`;
- **at least 16 characters** is `"set (…<last four>)"`, so at most a quarter of it shows: enough to tell two keys apart, not enough to use;
- **anything shorter** is `"set"`.

Characters, not bytes, are counted, so a secret of multi-byte characters is masked by the same measure. The two masked differently before (the app showed the last four of any secret past four bytes, most of a five-byte one; the script past eight), and a test runs both over the same values (macaw_compose#70).

```test:config-show-masks
with smtp_password "hunter2-long-secret" in the file, show/1 holds {:smtp_password, "set (…cret)", :file} and no shown value contains "hunter2"
```

```test:config-mask
mask(:secret, …) of nil and "" is "unset", of "abcde" and 15 characters "set", of 12 x's then "1234" "set (…1234)"; mask(:port, 4000) is "4000"
```

```test:config-mask-custom
mask/2 of a sign-in block with a 28-character password shows its host and "set (…aple)", never the password; of :not_a_block, the module's "(not a sign-in block)"
```

```test:mask-agree
Macaw.Host.Config.mask(:secret, v) equals the generated script's Ctl.Secret.mask(v) for nil, "", short, 15-character, 16-character and longer values, multi-byte ones included
```

## 6. Editing for the ctl {#host-config-edit}

`<app>-ctl config set`, `unset` and `reset` change the file through the app ([03 §3](03-release.md#host-release-config)), with these:
- `Macaw.Host.Config.put!/4` sets a setting, by name as typed, to a value as typed. The name is **matched as a string** against the declared names, so nothing typed becomes an atom (`"no setting named prot"`). The value is parsed as a literal (`parse_value/2`; nothing is evaluated) and checked against the setting's type. **An enum value is matched by name,** `open` or `:open`, so a typo answers `"must be one of open, closed"` instead of an atom fault. **A value that isn't a literal** is `"value:1: not a literal: <text>"`, whether or not the word is an atom the VM knows, and, **when the setting's type takes the text as a string** (asked of the type, `Types.check/2`, never a list of string-like types), the answer goes on `"; a string is quoted: config set <name> '"<text>"'"`, a secret's text never repeated, in the fault or the hint (`…`). The `@FILE` form reads the same way. It returns `{:ok, value}`, the checked value, after writing the file (§1.4, with a header saying the file is a literal map edited with `<app>-ctl config set` and that an env var still wins), or `{:error, why}` with **the file untouched.**
  - **What is stored is the literal as typed,** never the check's result (macaw_host#1). A check may normalize, resolving `{:env, "VAR"}` to the secret it names or an address to a tuple; storing that would write the secret into the file in clear text, or a value the file can't hold. An enum is stored as its atom.
- `Macaw.Host.Config.delete!/3` removes a setting from the file, so it falls back to its env var or default: `:ok`, or `{:error, "no setting named …"}`.
- Both read the file with `Macaw.Host.Config.read_file/1`: `{:ok, map}`, or a file with faults as `{:error, message}`, every fault on one line joined by `; `, with the file untouched. Both replace the key whether the file wrote it as an atom or a string.
- `Macaw.Host.Config.reset!/1` **repairs a file that no longer parses,** which blocks the app's boot, `put!/4` and `delete!/3` alike (macaw#92): it sets the file aside beside itself as `config.exs.broken`, made 0600 first (it may hold a password) and renamed with its bytes intact, then writes an empty map (§1.4, with the same header). **The empty file is written only once the rename has succeeded,** so a failed rename (`{:error, "cannot set config.exs aside: <reason>"}`) leaves the broken file where it was, never lost. It returns `{:ok, "config.exs.broken"}`, or `{:error, why}` with **both files untouched:**
  - no file: `"there is no config.exs: nothing to reset"`;
  - a file that parses, which there is nothing to repair in: `"config.exs parses: nothing to reset; config unset NAME removes a setting"`;
  - **a `config.exs.broken` already there,** set aside before and not yet looked at: `"config.exs.broken already exists: move it away first, then config reset again"`. It is never overwritten, and the name never carries a clock: one file set aside at a time, which an operator moves away on purpose.

```test:config-put-bare-word
put!/4 of a bare word for a string setting answers "not a literal" and "a string is quoted: config set public_host '\"nas\"'", for an integer setting no quoting, a word that is no atom the same "not a literal" wording, a secret's text nowhere in the answer, and the file is untouched
```

```test:config-put
put!/4 "port" "8443" gives {:ok, 8443} and "mode" ":open" {:ok, :open}; then "port" "70000", "prot" "1" and "public_host" "System.halt()" each give an error, and the file is byte for byte as before and reads %{port: 8443, mode: :open}
```

```test:config-put-stores-typed
put!/4 of auth as %{host: "nas", password: {:env, VAR}} answers the resolved block and leaves %{auth: %{host: "nas", password: {:env, VAR}}} in the file, the secret nowhere in it; an {m, f} check that halves its value stores 8 for "8" and answers 4
```

```test:config-delete
after put!/4 of port, delete!/3 of "port" leaves the file reading %{}
```

```test:config-reset
reset!/1 of a broken file (mode 0644, holding a password) answers {:ok, "config.exs.broken"}: config.exs.broken holds its bytes, both files are 0600, config.exs reads %{} under the header, and put!/4 works again; broken again, a second reset! is refused with "config.exs.broken already exists: move it away first" and both files are as they were; no file, and a file that parses, are refused and left as they were, no .broken made
```
