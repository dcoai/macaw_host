# 05 — Build info {#host-build}

`Macaw.Host.Build` gives an app its version and the commit it was built from, fixed at compile time, for its health report and `<app>-ctl status`. Five projects had scattered copies (macaw_compose#33, #47).

```elixir
defmodule MyApp.Build do
  use Macaw.Host.Build, otp_app: :my_app
end

MyApp.Build.sha()      # "3f639e84a704"
MyApp.Build.version()  # "1.2.0"
```

## 1. The macro {#host-build-use}

`use Macaw.Host.Build, otp_app: app` (`:otp_app` required) defines, in the using module:
- `sha/0`: the commit this build was made from (§2);
- `version/0`: the app's version, the `:version` of the Mix project compiling it;
- `otp_app/0`: the app given.

**It is a macro so it runs while the *app* compiles, in the app's directory:** as a function in this library it would read this library's checkout, or nothing. Both values are module attributes, so the release needs neither Mix nor git at run time.

```test:build-version
a module using it with otp_app: :macaw_host has version/0 equal to the Mix project's version and otp_app/0 :macaw_host; sha/0 is 7–12 hex digits or "unknown"
```

## 2. The SHA {#host-build-sha}

`Macaw.Host.Build.sha_now/0`, called while the app compiles, is:
1. `BUILD_SHA`, when the image build sets it non-empty, **shortened to 12 characters;**
2. else the app's own git checkout's `git rev-parse --short=12 HEAD`;
3. else `"unknown"`: when git is not on PATH (it is looked for first, since running a missing executable raises rather than failing; a build image without git and without `BUILD_SHA` failed to compile until this, macaw_compose#47), or git answers with an error (no checkout).

The value is fixed when the using module compiles; nothing recompiles it when the commit changes.

```test:build-sha-env
with BUILD_SHA "0123456789abcdef0123", sha_now/0 is "0123456789ab"
```
