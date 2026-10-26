defmodule Macaw.Host.Secrets do
  @moduledoc """
  Secrets the system generates itself (`secret_key_base`, signing and
  sealing keys), kept in the data directory, readable by their owner only.

  A host never holds a secret it must not lose: the app generates it on
  first boot, and it travels with the data. An explicit env var still wins,
  in the app's own configuration.

  - **Generated once**, 64 random bytes by default, base64.
  - **Written atomically:** a temporary file, mode 0600, then a rename, so
    a crash leaves no partial secret and no window where the file is
    readable by others.
  - **Checked on every read:** a file readable by group or others raises,
    naming the file and its mode, rather than using a secret that may have
    leaked.
  - **Restorable:** `put!/3` writes a given secret, for a restore from
    backup.
  """

  import Bitwise

  @doc """
  The secret stored at `data_dir/name`, generating `bytes` random bytes
  (base64) on first use.
  """
  @spec ensure!(Path.t(), String.t(), pos_integer()) :: String.t()
  def ensure!(data_dir, name, bytes \\ 64) do
    path = Path.join(data_dir, name)

    case File.read(path) do
      {:ok, secret} ->
        check_mode!(path)
        String.trim(secret)

      {:error, :enoent} ->
        secret = bytes |> :crypto.strong_rand_bytes() |> Base.encode64()
        write!(path, secret)
        secret

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @doc "Writes a known secret (a restore from backup), the same way a generated one is written."
  @spec put!(Path.t(), String.t(), String.t()) :: :ok
  def put!(data_dir, name, secret) when is_binary(secret) and byte_size(secret) > 0 do
    write!(Path.join(data_dir, name), secret)
  end

  defp write!(path, secret) do
    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    # Created 0600 before any secret is in it, so there is no readable window.
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, secret)
    File.rename!(tmp, path)
  end

  defp check_mode!(path) do
    %File.Stat{mode: mode} = File.stat!(path)

    if (mode &&& 0o077) != 0 do
      raise ArgumentError,
            "#{path} is readable by group or others (mode #{Integer.to_string(mode &&& 0o777, 8)}); it must be 0600"
    end
  end
end
