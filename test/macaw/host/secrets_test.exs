defmodule Macaw.Host.SecretsTest do
  use ExUnit.Case, async: true

  alias Macaw.Host.Secrets

  @moduletag :tmp_dir

  test "generates 64 random bytes once, then returns the same secret", %{tmp_dir: dir} do
    first = Secrets.ensure!(dir, "secret_key_base")
    assert byte_size(Base.decode64!(first)) == 64
    assert Secrets.ensure!(dir, "secret_key_base") == first
    assert Secrets.ensure!(Path.join(dir, "other"), "secret_key_base") != first
  end

  test "the file is 0600 and no temporary file is left", %{tmp_dir: dir} do
    Secrets.ensure!(dir, "k", 32)
    assert Bitwise.band(File.stat!(Path.join(dir, "k")).mode, 0o777) == 0o600
    refute File.exists?(Path.join(dir, "k.tmp"))
  end

  test "a secret readable by group or others raises, naming the file and its mode", %{
    tmp_dir: dir
  } do
    Secrets.ensure!(dir, "k")
    File.chmod!(Path.join(dir, "k"), 0o640)

    assert_raise ArgumentError,
                 ~r/k is readable by group or others \(mode 640\); it must be 0600/,
                 fn ->
                   Secrets.ensure!(dir, "k")
                 end
  end

  test "put! restores a known secret, and ensure! returns it", %{tmp_dir: dir} do
    :ok = Secrets.put!(dir, "secret_key_base", "restored-value")
    assert Secrets.ensure!(dir, "secret_key_base") == "restored-value"
    assert Bitwise.band(File.stat!(Path.join(dir, "secret_key_base")).mode, 0o777) == 0o600
  end

  test "a stale temporary file from a crash does not stop the next write", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "k.tmp"), "partial")
    secret = Secrets.ensure!(dir, "k")
    assert File.read!(Path.join(dir, "k")) == secret
  end

  test "a crash between writing and renaming leaves the old secret intact", %{tmp_dir: dir} do
    old = Secrets.ensure!(dir, "k")
    # What a crash after the temporary write and before the rename leaves:
    File.write!(Path.join(dir, "k.tmp"), "half-written")
    assert Secrets.ensure!(dir, "k") == old
  end
end
