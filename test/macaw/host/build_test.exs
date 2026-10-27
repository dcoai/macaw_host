defmodule Macaw.Host.BuildTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  defmodule AppBuild do
    use Macaw.Host.Build, otp_app: :macaw_host
  end

  test "the version is the app's, fixed at compile time" do
    assert AppBuild.version() == Mix.Project.config()[:version]
    assert AppBuild.otp_app() == :macaw_host
  end

  test "the sha is a short commit id or unknown" do
    assert AppBuild.sha() =~ ~r/\A([0-9a-f]{7,12}|unknown)\z/
  end

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

    test "declares the HEAD file and the branch it names", %{tmp_dir: dir} do
      git = Path.join(dir, ".git")
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
    end

    test "a detached HEAD is the one file", %{tmp_dir: dir} do
      git = Path.join(dir, ".git")
      File.mkdir_p!(git)
      File.write!(Path.join(git, "HEAD"), String.duplicate("b", 40) <> "\n")

      assert resources(git) == [Path.join(git, "HEAD")]
    end

    test "a branch only in packed-refs declares packed-refs", %{tmp_dir: dir} do
      git = Path.join(dir, ".git")
      File.mkdir_p!(git)
      File.write!(Path.join(git, "HEAD"), "ref: refs/heads/main\n")

      File.write!(
        Path.join(git, "packed-refs"),
        String.duplicate("c", 40) <> " refs/heads/main\n"
      )

      assert resources(git) == Enum.sort([Path.join(git, "HEAD"), Path.join(git, "packed-refs")])
    end

    test "a worktree's HEAD, and the branch in the common directory", %{tmp_dir: dir} do
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

    test "the checkout is found from the app's directory upward, as in an umbrella",
         %{tmp_dir: dir} do
      File.mkdir_p!(Path.join(dir, ".git"))
      app = Path.join(dir, "apps/web")
      File.mkdir_p!(app)

      assert Macaw.Host.Build.find_git_dir(app) == Path.join(dir, ".git")
      assert Macaw.Host.Build.find_git_dir(Path.join(dir, "none/such")) == Path.join(dir, ".git")
    end

    test "none without a checkout", %{tmp_dir: dir} do
      assert resources(Path.join(dir, ".git")) == []
    end

    test "none when BUILD_SHA names the commit", %{tmp_dir: dir} do
      git = Path.join(dir, ".git")
      File.mkdir_p!(git)
      File.write!(Path.join(git, "HEAD"), String.duplicate("b", 40) <> "\n")

      System.put_env("BUILD_SHA", "0123456789abcdef0123")
      on_exit(fn -> System.delete_env("BUILD_SHA") end)

      assert resources(git) == []
    end
  end
end
