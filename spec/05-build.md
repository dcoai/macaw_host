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

`use Macaw.Host.Build, otp_app: app` (`:otp_app` required; `:git_dir`, the checkout's `.git`, optional, §3) defines, in the using module:
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

The value is fixed when the using module compiles; §3 makes a new commit recompile it.

## 3. Recompiling on a new commit {#host-build-recompile}

**When the SHA comes from the checkout, the using module declares the checkout's files as `@external_resource`s,** so an incremental build after a commit, a checkout or a reset recompiles it rather than keeping the old SHA (macaw_compose#70). `Macaw.Host.Build.git_resources/1` names them, at the app's compile time:
- the checkout's `.git` is `:git_dir` when given, else the first `.git` found from the app's directory upward (`Macaw.Host.Build.find_git_dir/1`), so an umbrella app finds its root's; a `.git` **file** (a worktree, a submodule) is followed to the directory its `gitdir:` line names;
- the files: its **`HEAD`**; the **ref `HEAD` names**, as a loose file (in the git directory, or in the common directory a worktree's `commondir` names), else `packed-refs` when the branch is only packed; and **HEAD's reflog**, `logs/HEAD`, which grows with every commit, also covering a first commit on a branch that was only packed;
- **only files that exist are declared,** so a build without a checkout declares none;
- **they are read as files, never by running git;**
- **with `BUILD_SHA` set, none are declared:** the SHA is the build's, and those builds are unchanged.

```test:build-resources
with a fake .git given as git_dir: HEAD naming refs/heads/main declares HEAD and refs/heads/main, and logs/HEAD once it exists; a detached HEAD declares HEAD alone; a branch only in packed-refs declares HEAD and packed-refs; a worktree's .git file declares its HEAD and the branch in the common directory
```

```test:build-resources-none
a git_dir that doesn't exist declares nothing; with BUILD_SHA set, a checkout declares nothing; find_git_dir/1 from apps/web finds the .git two levels up
```

```test:build-sha-env
with BUILD_SHA "0123456789abcdef0123", sha_now/0 is "0123456789ab"
```
