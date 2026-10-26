defmodule Macaw.Host.BuildTest do
  use ExUnit.Case, async: false

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
end
