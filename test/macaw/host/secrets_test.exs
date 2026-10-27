defmodule Macaw.Host.SecretsTest do
  use ExUnit.Case, async: true

  alias Macaw.Host.Secrets

  @moduletag :tmp_dir

  @tag verifies: "secrets-once"
  test "generates 64 random bytes once, then returns the same secret", %{tmp_dir: dir} do
    first = Secrets.ensure!(dir, "secret_key_base")
    assert byte_size(Base.decode64!(first)) == 64
    assert Secrets.ensure!(dir, "secret_key_base") == first
    assert Secrets.ensure!(Path.join(dir, "other"), "secret_key_base") != first
  end

  @tag verifies: "secrets-mode"
  test "the file is 0600 and no temporary file is left", %{tmp_dir: dir} do
    Secrets.ensure!(dir, "k", 32)
    assert Bitwise.band(File.stat!(Path.join(dir, "k")).mode, 0o777) == 0o600
    refute File.exists?(Path.join(dir, "k.tmp"))
  end

  @tag verifies: "secrets-mode-check"
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

  @tag verifies: "secrets-put"
  test "put! restores a known secret, and ensure! returns it", %{tmp_dir: dir} do
    :ok = Secrets.put!(dir, "secret_key_base", "restored-value")
    assert Secrets.ensure!(dir, "secret_key_base") == "restored-value"
    assert Bitwise.band(File.stat!(Path.join(dir, "secret_key_base")).mode, 0o777) == 0o600
  end

  @tag verifies: "secrets-crash"
  test "a crash leaves no partial secret, before the first secret or after it", %{tmp_dir: dir} do
    # A stale temporary file from a crash does not stop the first generation.
    File.write!(Path.join(dir, "k.tmp"), "partial")
    secret = Secrets.ensure!(dir, "k")
    assert File.read!(Path.join(dir, "k")) == secret
    refute secret == "partial"

    # What a crash after the temporary write and before the rename leaves:
    # the old secret, still the one returned.
    File.write!(Path.join(dir, "k.tmp"), "half-written")
    assert Secrets.ensure!(dir, "k") == secret
  end

  # Each section's own text, beside the hints inside it.
  describe "the sections of spec 02" do
    @tag verifies: "host-secrets"
    test "a generated secret is kept in the data directory, owner-only, and travels with the data",
         %{tmp_dir: dir} do
      data = Path.join(dir, "data")
      secret = Secrets.ensure!(data, "secret_key_base")
      assert File.read!(Path.join(data, "secret_key_base")) == secret
      assert Bitwise.band(File.stat!(Path.join(data, "secret_key_base")).mode, 0o777) == 0o600

      # A restore of the data directory elsewhere carries the secret with it.
      moved = Path.join(dir, "moved")
      File.cp_r!(data, moved)
      assert Secrets.ensure!(moved, "secret_key_base") == secret
    end

    @tag verifies: "host-secrets-ensure"
    test "ensure!/3 generates the bytes asked for, base64, once; then the file trimmed; another read failure raises",
         %{tmp_dir: dir} do
      short = Secrets.ensure!(dir, "short", 32)
      assert byte_size(Base.decode64!(short)) == 32
      assert byte_size(Base.decode64!(Secrets.ensure!(dir, "default"))) == 64

      :ok = Secrets.put!(dir, "trimmed", "kept\n")
      assert Secrets.ensure!(dir, "trimmed") == "kept"

      File.mkdir_p!(Path.join(dir, "a_directory"))
      assert_raise File.Error, fn -> Secrets.ensure!(dir, "a_directory") end

      assert Secrets.ensure!(Path.join(dir, "one"), "k") !=
               Secrets.ensure!(Path.join(dir, "two"), "k")
    end

    @tag verifies: "host-secrets-write"
    test "a secret is written 0600 beside its temporary file, its directory created when missing",
         %{tmp_dir: dir} do
      data = Path.join([dir, "not", "yet"])
      secret = Secrets.ensure!(data, "k")

      assert File.read!(Path.join(data, "k")) == secret
      assert Bitwise.band(File.stat!(Path.join(data, "k")).mode, 0o777) == 0o600
      refute File.exists?(Path.join(data, "k.tmp"))
    end

    @tag verifies: "host-secrets-mode"
    test "any permission for group or others raises on read, naming the file and its mode",
         %{tmp_dir: dir} do
      path = Path.join(dir, "k")
      Secrets.ensure!(dir, "k")

      for mode <- [0o604, 0o620, 0o601] do
        File.chmod!(path, mode)
        octal = Integer.to_string(mode, 8)

        assert_raise ArgumentError,
                     "#{path} is readable by group or others (mode #{octal}); it must be 0600",
                     fn -> Secrets.ensure!(dir, "k") end
      end
    end

    @tag verifies: "host-secrets-put"
    test "put!/3 writes a known non-empty secret as a generated one is written, and returns :ok",
         %{tmp_dir: dir} do
      data = Path.join(dir, "fresh")
      assert :ok = Secrets.put!(data, "k", "known")
      assert Secrets.ensure!(data, "k") == "known"
      assert Bitwise.band(File.stat!(Path.join(data, "k")).mode, 0o777) == 0o600
      refute File.exists?(Path.join(data, "k.tmp"))

      assert_raise FunctionClauseError, fn -> Secrets.put!(data, "k", "") end
    end
  end
end
