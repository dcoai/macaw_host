defmodule Macaw.Host.Config.Types do
  @moduledoc """
  The setting types `Macaw.Host.Config` understands, and how a value of each
  is read from an environment variable (a string) or checked from
  `config.exs` (a literal).

  | Type | From the file | From an env var |
  |---|---|---|
  | `:string`, `:secret` | a string | as is |
  | `:optional_string` | a string or `nil` | as is; empty is `nil` |
  | `:boolean` | `true` or `false` | `true`, `false`, `1`, `0` |
  | `:integer`, `:pos_integer`, `:port` | an integer in range | decimal digits |
  | `{:enum, [atom]}` | one of the atoms | its name |
  | `:string_list` | a list of strings | comma-separated |
  | `{:custom, {m, f}}` | `m.f(value)` returns `{:ok, v}` or `{:error, message}` | the same, given the string |

  A `:secret` is masked wherever a value is shown (`Macaw.Host.Config.show/2`).
  Enum names from env vars are compared as strings, so no atom is made.
  """

  @type t ::
          :string
          | :secret
          | :optional_string
          | :boolean
          | :integer
          | :pos_integer
          | :port
          | {:enum, [atom()]}
          | :string_list
          | {:custom, {module(), atom()}}

  @doc "Checks a value from `config.exs`: `{:ok, value}` or `{:error, why}`."
  @spec check(t(), term()) :: {:ok, term()} | {:error, String.t()}
  def check(type, value)
  def check(t, v) when t in [:string, :secret] and is_binary(v), do: {:ok, v}
  def check(:optional_string, v) when is_binary(v) or is_nil(v), do: {:ok, v}
  def check(:boolean, v) when is_boolean(v), do: {:ok, v}
  def check(:integer, v) when is_integer(v), do: {:ok, v}
  def check(:pos_integer, v) when is_integer(v) and v > 0, do: {:ok, v}
  def check(:port, v) when is_integer(v) and v in 1..65_535, do: {:ok, v}

  def check({:enum, values}, v) when is_atom(v) do
    if v in values, do: {:ok, v}, else: {:error, "must be one of #{inspect(values)}"}
  end

  def check(:string_list, v) when is_list(v) do
    if Enum.all?(v, &is_binary/1), do: {:ok, v}, else: {:error, "must be a list of strings"}
  end

  def check({:custom, {m, f}}, v), do: apply(m, f, [v])
  def check(type, _v), do: {:error, "must be #{describe(type)}"}

  @doc "Reads a value from an env var's string: `{:ok, value}` or `{:error, why}`."
  @spec cast(t(), String.t()) :: {:ok, term()} | {:error, String.t()}
  def cast(type, text)
  def cast(t, s) when t in [:string, :secret], do: {:ok, s}
  def cast(:optional_string, ""), do: {:ok, nil}
  def cast(:optional_string, s), do: {:ok, s}

  def cast(:boolean, s) do
    case String.downcase(String.trim(s)) do
      v when v in ["true", "1"] -> {:ok, true}
      v when v in ["false", "0"] -> {:ok, false}
      _ -> {:error, "must be true or false"}
    end
  end

  def cast(t, s) when t in [:integer, :pos_integer, :port] do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> check(t, n)
      _ -> {:error, "must be #{describe(t)}"}
    end
  end

  def cast({:enum, values}, s) do
    case Enum.find(values, &(Atom.to_string(&1) == String.trim(s))) do
      nil -> {:error, "must be one of #{Enum.map_join(values, ", ", &Atom.to_string/1)}"}
      v -> {:ok, v}
    end
  end

  def cast(:string_list, s),
    do: {:ok, s |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))}

  def cast({:custom, {m, f}}, s), do: apply(m, f, [s])

  @doc "A type in words, for fault messages."
  @spec describe(t()) :: String.t()
  def describe(:string), do: "a string"
  def describe(:secret), do: "a string"
  def describe(:optional_string), do: "a string or nil"
  def describe(:boolean), do: "true or false"
  def describe(:integer), do: "an integer"
  def describe(:pos_integer), do: "a positive integer"
  def describe(:port), do: "a port number (1–65535)"
  def describe({:enum, values}), do: "one of #{inspect(values)}"
  def describe(:string_list), do: "a list of strings"
  def describe({:custom, {m, f}}), do: "accepted by #{inspect(m)}.#{f}/1"
end
