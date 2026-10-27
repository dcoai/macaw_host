# 02 — Secrets {#host-secrets}

`Macaw.Host.Secrets` keeps the secrets the system generates itself (`secret_key_base`, signing and sealing keys) in the data directory, readable by their owner only. **A host never holds a secret it must not lose:** the app generates it on first boot, and it travels with the data. An explicit env var still wins, in the app's own configuration. It is macaw's `Secrets.ensure!/3` with one fix, and Snow's restore (macaw_compose#33, #46).

## 1. Generated once {#host-secrets-ensure}

`Macaw.Host.Secrets.ensure!/3` returns the secret stored at `<data_dir>/<name>`:
- **the first time,** when there is no file, it generates `bytes` random bytes (`:crypto.strong_rand_bytes/1`; **64 by default**), encodes them in base64, writes them (§2) and returns them;
- **after that** it returns the file's content, trimmed, the same secret every time;
- a file it can't read for any other reason raises `File.Error`.

Two data directories have two different secrets.

```test:secrets-once
ensure!/2 gives a base64 secret of 64 bytes, the same one on a second call, and a different one for another directory
```

## 2. Written 0600, atomically {#host-secrets-write}

A secret is written to a temporary file beside it (`<path>.tmp`), which is **made 0600 while still empty,** then written, then renamed over the file; the directory is created if missing. So a crash leaves no partial secret, and there is no moment the file is readable by others. (macaw wrote the secret and then set the mode, a readable window under a permissive umask; the class the survey found in uficap, macaw_compose#46.)

A temporary file left by a crash does not stop the next write, and a crash between writing and renaming leaves the old secret in place.

```test:secrets-mode
ensure!/3 leaves the file at mode 0600 and no .tmp file beside it
```

```test:secrets-crash
a stale <name>.tmp holding "partial" doesn't stop the first generation; a .tmp written after a secret exists (a crash before the rename) leaves ensure!/2 returning the old secret
```

## 3. Checked on every read {#host-secrets-mode}

**A secret file with any permission for group or others raises** `ArgumentError` on read, naming the file and its mode: `"<path> is readable by group or others (mode 640); it must be 0600"`. A secret that may have leaked is never used.

```test:secrets-mode-check
after chmod 0640 on a generated secret, ensure!/2 raises ArgumentError matching "k is readable by group or others (mode 640); it must be 0600"
```

## 4. Restorable {#host-secrets-put}

`Macaw.Host.Secrets.put!/3` writes a known secret (a non-empty string) at `<data_dir>/<name>`, the same way a generated one is written (§2), for a restore from backup; `ensure!` then returns it. It returns `:ok`.

```test:secrets-put
put!/3 of "restored-value" then ensure!/2 returns "restored-value", and the file is 0600
```
