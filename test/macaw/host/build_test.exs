defmodule Macaw.Host.BuildTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defmodule AppBuild do
    use Macaw.Host.Build, otp_app: :macaw_host
  end

  @tag verifies: "build-version"
  test "the version is the app's, fixed at compile time, and the sha a short commit id or unknown" do
    assert AppBuild.version() == Mix.Project.config()[:version]
    assert AppBuild.otp_app() == :macaw_host
    assert AppBuild.sha() =~ ~r/\A([0-9a-f]{7,12}|unknown)\z/
  end

  @tag verifies: "build-sha-env"
  test "BUILD_SHA wins, shortened to 12" do
    System.put_env("BUILD_SHA", "0123456789abcdef0123")
    on_exit(fn -> System.delete_env("BUILD_SHA") end)
    assert Macaw.Host.Build.sha_now() == "0123456789ab"
  end

  describe "recompiling when the commit changes" do
    # A module using the macro with `git_dir:`, reporting the external
    # resources it declared, compiled here so the fake checkout exists.
    defp resources(git_dir) do
      name = Module.concat(__MODULE__, "Probe#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(name)} do
        use Macaw.Host.Build, otp_app: :macaw_host, git_dir: #{inspect(git_dir)}
        @declared Module.get_attribute(__MODULE__, :external_resource)
        def declared, do: @declared
      end
      """)

      Enum.sort(name.declared())
    end

    @tag verifies: "build-resources"
    test "declares HEAD, the branch it names, and the reflog, wherever git keeps them",
         %{tmp_dir: dir} do
      # HEAD and the branch it names.
      git = Path.join(dir, "branch/.git")
      File.mkdir_p!(Path.join(git, "refs/heads"))
      File.write!(Path.join(git, "HEAD"), "ref: refs/heads/main\n")
      File.write!(Path.join(git, "refs/heads/main"), String.duplicate("a", 40) <> "\n")

      assert resources(git) ==
               Enum.sort([Path.join(git, "HEAD"), Path.join(git, "refs/heads/main")])

      # With a reflog, that too: it grows with every commit.
      File.mkdir_p!(Path.join(git, "logs"))
      File.write!(Path.join(git, "logs/HEAD"), "a commit\n")

      assert resources(git) ==
               Enum.sort([
                 Path.join(git, "HEAD"),
                 Path.join(git, "refs/heads/main"),
                 Path.join(git, "logs/HEAD")
               ])

      # A detached HEAD is the one file.
      detached = Path.join(dir, "detached/.git")
      File.mkdir_p!(detached)
      File.write!(Path.join(detached, "HEAD"), String.duplicate("b", 40) <> "\n")

      assert resources(detached) == [Path.join(detached, "HEAD")]

      # A branch only in packed-refs declares packed-refs.
      packed = Path.join(dir, "packed/.git")
      File.mkdir_p!(packed)
      File.write!(Path.join(packed, "HEAD"), "ref: refs/heads/main\n")

      File.write!(
        Path.join(packed, "packed-refs"),
        String.duplicate("c", 40) <> " refs/heads/main\n"
      )

      assert resources(packed) ==
               Enum.sort([Path.join(packed, "HEAD"), Path.join(packed, "packed-refs")])

      # A worktree's HEAD, and the branch in the common directory.
      common = Path.join(dir, "main/.git")
      worktree_git = Path.join(common, "worktrees/wt")
      File.mkdir_p!(worktree_git)
      File.mkdir_p!(Path.join(common, "refs/heads/milestone"))
      File.write!(Path.join(common, "refs/heads/milestone/x"), String.duplicate("d", 40) <> "\n")
      File.write!(Path.join(worktree_git, "HEAD"), "ref: refs/heads/milestone/x\n")
      File.write!(Path.join(worktree_git, "commondir"), "../..\n")

      # The worktree's checkout has a .git file naming its git directory.
      checkout = Path.join(dir, "wt")
      File.mkdir_p!(checkout)
      File.write!(Path.join(checkout, ".git"), "gitdir: #{worktree_git}\n")

      assert resources(Path.join(checkout, ".git")) ==
               Enum.sort([
                 Path.join(worktree_git, "HEAD"),
                 Path.join(common, "refs/heads/milestone/x")
               ])
    end

    @tag verifies: "build-resources-none"
    test "none without a checkout or with BUILD_SHA; the checkout is found upward, as in an umbrella",
         %{tmp_dir: dir} do
      # No checkout.
      assert resources(Path.join(dir, "none/.git")) == []

      # BUILD_SHA names the commit.
      git = Path.join(dir, ".git")
      File.mkdir_p!(git)
      File.write!(Path.join(git, "HEAD"), String.duplicate("b", 40) <> "\n")

      System.put_env("BUILD_SHA", "0123456789abcdef0123")
      on_exit(fn -> System.delete_env("BUILD_SHA") end)

      assert resources(git) == []

      # Found from the app's directory upward.
      app = Path.join(dir, "apps/web")
      File.mkdir_p!(app)

      assert Macaw.Host.Build.find_git_dir(app) == Path.join(dir, ".git")
      assert Macaw.Host.Build.find_git_dir(Path.join(dir, "none/such")) == Path.join(dir, ".git")
    end
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 05" do
    # A module using the macro, compiled now, under a name of its own.
    defp compile_build(opts) do
      name = Module.concat(__MODULE__, "Built#{System.unique_integer([:positive])}")

      Code.compile_string("""
      defmodule #{inspect(name)} do
        use Macaw.Host.Build, #{opts}
      end
      """)

      name
    end

    # PATH holding only `bin` (a fake git, or nothing), for the call.
    defp with_path(bin, fun) do
      path = System.get_env("PATH")
      on_exit(fn -> System.put_env("PATH", path) end)
      System.put_env("PATH", bin)
      result = fun.()
      System.put_env("PATH", path)
      result
    end

    defp fake_git(dir, script) do
      bin = Path.join(dir, "bin")
      File.mkdir_p!(bin)
      File.write!(Path.join(bin, "git"), "#!/bin/sh\n" <> script)
      File.chmod!(Path.join(bin, "git"), 0o755)
      bin
    end

    @tag verifies: "host-build"
    test "the version and the commit are fixed when the module compiles" do
      System.put_env("BUILD_SHA", "aaaaaaaaaaaaaaaaaaaa")
      on_exit(fn -> System.delete_env("BUILD_SHA") end)
      built = compile_build("otp_app: :macaw_host")

      System.put_env("BUILD_SHA", "bbbbbbbbbbbbbbbbbbbb")
      assert built.sha() == "aaaaaaaaaaaa"
      assert built.version() == Mix.Project.config()[:version]
    end

    @tag verifies: "host-build-use"
    test "use needs :otp_app and defines sha/0, version/0 and otp_app/0", %{tmp_dir: dir} do
      assert_raise KeyError, fn -> compile_build("git_dir: nil") end

      built = compile_build("otp_app: :some_app, git_dir: #{inspect(Path.join(dir, ".git"))}")
      assert built.otp_app() == :some_app
      assert built.version() == Mix.Project.config()[:version]
      assert is_binary(built.sha())

      assert Enum.sort(built.__info__(:functions)) ==
               Enum.sort(otp_app: 0, sha: 0, version: 0)

      # It runs while the using module compiles, in the directory compiling it:
      # a git that answers with the name of the directory it runs in.
      app = Path.join(dir, "the_app_dir")
      File.mkdir_p!(app)
      git = fake_git(Path.join(dir, "pwd_git"), ~s(echo "${PWD##*/}"\n))
      System.delete_env("BUILD_SHA")
      cwd = File.cwd!()
      File.cd!(app)
      built = with_path(git, fn -> compile_build("otp_app: :some_app") end)
      File.cd!(cwd)
      assert built.sha() == "the_app_dir"
    end

    @tag verifies: "host-build-sha"
    test "sha_now/0: BUILD_SHA when set non-empty, else the checkout's git, else unknown", %{
      tmp_dir: dir
    } do
      System.put_env("BUILD_SHA", "")
      on_exit(fn -> System.delete_env("BUILD_SHA") end)

      answers = fake_git(Path.join(dir, "answers"), ~s(echo "0123456789ab"\n))
      assert with_path(answers, &Macaw.Host.Build.sha_now/0) == "0123456789ab"

      # git answering with an error: no checkout.
      fails =
        fake_git(Path.join(dir, "fails"), "echo 'fatal: not a git repository' >&2\nexit 128\n")

      assert with_path(fails, &Macaw.Host.Build.sha_now/0) == "unknown"

      # git not on PATH.
      empty = Path.join(dir, "empty")
      File.mkdir_p!(empty)
      assert with_path(empty, &Macaw.Host.Build.sha_now/0) == "unknown"

      System.put_env("BUILD_SHA", "fedcba9876543210fedc")
      assert with_path(empty, &Macaw.Host.Build.sha_now/0) == "fedcba987654"
    end

    @tag verifies: "host-build-recompile"
    test "git_resources/1 reads the checkout found from the app's directory upward, without running git",
         %{tmp_dir: dir} do
      git = Path.join(dir, ".git")
      File.mkdir_p!(Path.join(git, "refs/heads"))
      File.write!(Path.join(git, "HEAD"), "ref: refs/heads/main\n")
      File.write!(Path.join(git, "refs/heads/main"), String.duplicate("a", 40) <> "\n")
      app = Path.join(dir, "apps/web")
      File.mkdir_p!(app)

      # git that would fail the test if it ran.
      never = fake_git(Path.join(dir, "never"), "exit 99\n")

      cwd = File.cwd!()
      File.cd!(app)
      found = with_path(never, fn -> Macaw.Host.Build.git_resources(nil) end)
      File.cd!(cwd)

      assert Enum.sort(found) ==
               Enum.sort([Path.join(git, "HEAD"), Path.join(git, "refs/heads/main")])

      # Only files that exist: a ref named but missing declares HEAD alone.
      File.rm!(Path.join(git, "refs/heads/main"))
      assert Macaw.Host.Build.git_resources(git) == [Path.join(git, "HEAD")]
    end
  end
end
