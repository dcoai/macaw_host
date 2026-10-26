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
  """

  defmacro __using__(opts) do
    app = Keyword.fetch!(opts, :otp_app)

    quote do
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
