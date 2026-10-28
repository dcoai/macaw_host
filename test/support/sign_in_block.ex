defmodule Macaw.Host.Test.SignInBlock do
  @moduledoc """
  A custom setting type shaped like Collpa's `auth` block (collpa#141): a
  map whose `:password` is a literal or `{:env, "VAR"}`. Its check resolves
  the reference, as Collpa's does, so it normalizes; its `show/1` masks the
  password, a resolved one or one in a value that didn't check.
  """
  @behaviour Macaw.Host.Config.Type

  @impl true
  def check(%{password: {:env, var}} = block) when is_binary(var) do
    case System.get_env(var) do
      nil -> {:error, "password: #{var} is not set"}
      password -> {:ok, %{block | password: password}}
    end
  end

  def check(%{password: password} = block) when is_binary(password), do: {:ok, block}
  def check(%{} = block) when not is_map_key(block, :password), do: {:ok, block}
  def check(_other), do: {:error, "must be a sign-in block"}

  @impl true
  def cast(_text), do: {:error, "is set in config.exs, not an env var"}

  @impl true
  def show(%{password: password} = block) when is_binary(password),
    do: inspect(%{block | password: Macaw.Host.Config.mask(:secret, password)})

  def show(%{password: _} = block), do: inspect(%{block | password: "(a reference)"})
  def show(%{} = block), do: inspect(block)
  def show(_other), do: "(not a sign-in block)"

  @impl true
  def describe, do: "a sign-in block"
end
