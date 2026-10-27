defmodule Macaw.Host.Build do
  @moduledoc """
  An app's build: its version and the commit it was built from, fixed at
  compile time.

      defmodule MyApp.Build do
        use Macaw.Host.Build, otp_app: :my_app
      end

      MyApp.Build.sha()      # "3f639e84a704"
      MyApp.Build.version()  # "1.2.0"

  The SHA is `BUILD_SHA` when the image build sets it, else the app's own
  git checkout's, else `"unknown"`. It is a macro so it runs while the
  *app* compiles, in the app's directory: as a function in this library it
  would read this library's checkout, or nothing.

  When the SHA comes from the checkout, the module declares the checkout's
  `HEAD` file and the ref it names (the branch's file, or `packed-refs`
  when the branch is only packed), and HEAD's reflog, as
  `@external_resource`s, so a new
  commit or a switched branch recompiles it rather than leaving the old
  SHA in an incremental build. They are read as files, never by running
  git, and only those that exist are declared. The checkout is the first
  `.git` found from the app's directory upward (an umbrella's is at its
  root; a worktree's `.git` file is followed), or `git_dir:` when given.
  """

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :otp_app)
    git_dir = Keyword.get(opts, :git_dir)

    quote do
      for resource <- Macaw.Host.Build.git_resources(unquote(git_dir)) do
        @external_resource resource
      end

      @build_sha Macaw.Host.Build.sha_now()
      @build_version Mix.Project.config()[:version]

      @doc "The commit this build was made from."
      def sha, do: @build_sha

      @doc "The app's version."
      def version, do: @build_version

      @doc false
      def otp_app, do: unquote(app)
    end
  end

  @doc false
  # Called at the app's compile time, from its directory.
  def sha_now do
    case System.get_env("BUILD_SHA") do
      sha when is_binary(sha) and sha != "" ->
        String.slice(sha, 0, 12)

      _ ->
        git_sha(System.find_executable("git"))
    end
  end

  @doc false
  # The files whose change means a new commit: none when BUILD_SHA names
  # the commit (the build is then not the checkout's to describe), else the
  # checkout's HEAD and the ref it names, those that exist.
  @spec git_resources(Path.t() | nil) :: [Path.t()]
  def git_resources(git_dir) do
    case System.get_env("BUILD_SHA") do
      sha when is_binary(sha) and sha != "" -> []
      _ -> head_files(git_dir || find_git_dir(File.cwd!()))
    end
  end

  @doc false
  # The nearest `.git` from `dir` upward, or nil.
  @spec find_git_dir(Path.t()) :: Path.t() | nil
  def find_git_dir(dir) do
    dir = Path.expand(dir)
    candidate = Path.join(dir, ".git")
    parent = Path.dirname(dir)

    cond do
      File.exists?(candidate) -> candidate
      parent == dir -> nil
      true -> find_git_dir(parent)
    end
  end

  defp head_files(nil), do: []

  defp head_files(dot_git) do
    git_dir = resolve_git_dir(dot_git)
    head = Path.join(git_dir, "HEAD")

    files =
      case File.read(head) do
        {:ok, "ref: " <> ref} -> [head | ref_files(git_dir, String.trim(ref))]
        {:ok, _detached} -> [head]
        {:error, _} -> []
      end

    # HEAD's reflog grows with every commit, checkout and reset, which also
    # covers a first commit on a branch that was only packed.
    reflog = Path.join(git_dir, "logs/HEAD")
    if files != [] and File.regular?(reflog), do: files ++ [reflog], else: files
  end

  # A worktree's (or submodule's) `.git` is a file naming its git directory.
  defp resolve_git_dir(dot_git) do
    with {:ok, "gitdir: " <> path} <- File.read(dot_git) do
      Path.expand(String.trim(path), Path.dirname(dot_git))
    else
      _ -> dot_git
    end
  end

  # A worktree keeps its HEAD and shares the branches of the common
  # directory its `commondir` names; a branch is a loose file there or a
  # line of `packed-refs`.
  defp ref_files(git_dir, ref) do
    common =
      case File.read(Path.join(git_dir, "commondir")) do
        {:ok, path} -> Path.expand(String.trim(path), git_dir)
        {:error, _} -> git_dir
      end

    loose = Enum.find([Path.join(git_dir, ref), Path.join(common, ref)], &File.regular?/1)
    packed = Path.join(common, "packed-refs")

    cond do
      loose -> [loose]
      File.regular?(packed) -> [packed]
      true -> []
    end
  end

  # System.cmd raises when the executable is missing, so a build image
  # without git (and without BUILD_SHA) is checked for first.
  defp git_sha(nil), do: "unknown"

  defp git_sha(git) do
    case System.cmd(git, ["rev-parse", "--short=12", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> "unknown"
    end
  end
end
