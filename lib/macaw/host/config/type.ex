defmodule Macaw.Host.Config.Type do
  @moduledoc """
  A setting type an app defines itself, `{:custom, module}`: a module
  implementing this behavior owns how a value is checked, read from an env
  var, shown and described (collpa#141, macaw_host#1).

  It is for a value the built-in types can't hold: a structure with a secret
  inside, say, an address checked as one, or a block of several fields.
  **`show/1` is used wherever a value of the type is shown**, in `config
  list` and `get`, and on the fault path, for a value that didn't check, so
  a secret inside the structure is never printed. It must show any term.

      defmodule MyApp.AuthBlock do
        @behaviour Macaw.Host.Config.Type

        def check(%{} = block), do: {:ok, block}
        def check(_), do: {:error, "must be a map"}
        def cast(_text), do: {:error, "is set in config.exs, not an env var"}
        def show(%{password: _} = block), do: inspect(%{block | password: "set"})
        def show(other), do: inspect(other)
        def describe, do: "a sign-in block"
      end

  What is stored is always the literal as it was typed; `check/1`'s result
  is the value the app uses, never written back (`Macaw.Host.Config.put!/4`).
  """

  @doc "A value from `config.exs`: `{:ok, value}` or `{:error, why}`."
  @callback check(term()) :: {:ok, term()} | {:error, String.t()}

  @doc "A value from an env var's string: `{:ok, value}` or `{:error, why}`."
  @callback cast(String.t()) :: {:ok, term()} | {:error, String.t()}

  @doc "A value as shown, any term (a value that didn't check included); never a secret."
  @callback show(term()) :: String.t()

  @doc "The type in words, for faults: `\"a sign-in block\"`."
  @callback describe() :: String.t()
end
