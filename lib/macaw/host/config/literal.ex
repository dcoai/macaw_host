defmodule Macaw.Host.Config.Literal do
  @moduledoc """
  The literal `config.exs` on a host's data volume: a map that is parsed,
  never evaluated.

  Anything that isn't a literal (a call, a variable, string interpolation, a
  module attribute) is a fault, and **every** fault is reported at once, each
  with its line. Literals are atoms, strings, numbers (negative ones
  included), lists, maps and tuples of any size. Parsing never creates an
  atom: a name that doesn't already exist is a fault, so a typo can't grow
  the atom table and can't silently become a new setting.
  """

  @doc "The map in `path`, or `%{}` when the file doesn't exist. Raises on any fault."
  @spec read!(Path.t()) :: map()
  def read!(path) do
    case File.read(path) do
      {:ok, text} -> parse!(text, path)
      {:error, :enoent} -> %{}
      {:error, reason} -> raise File.Error, reason: reason, action: "read", path: path
    end
  end

  @doc "Parses a config file's text to a map; raises `ArgumentError` listing every fault."
  @spec parse!(String.t(), Path.t()) :: map()
  def parse!(text, path \\ "config.exs") do
    case parse(text, path) do
      {:ok, map} -> map
      {:error, faults} -> raise ArgumentError, Enum.join(faults, "\n")
    end
  end

  @doc """
  Parses text to a literal map, or `{:error, faults}`, one message per fault.
  Also parses a single value someone typed (`ctl config set`) with
  `parse_value/2`.
  """
  @spec parse(String.t(), Path.t()) :: {:ok, map()} | {:error, [String.t()]}
  def parse(text, path \\ "config.exs") do
    case quoted(text, path) do
      {:ok, {:%{}, _, _} = ast} -> literal(ast, path)
      {:ok, _} -> {:error, ["#{path} must contain a single literal map"]}
      {:error, _} = error -> error
    end
  end

  @doc "Parses one literal value (a string, number, atom, list, map or tuple)."
  @spec parse_value(String.t(), String.t()) :: {:ok, term()} | {:error, [String.t()]}
  def parse_value(text, label \\ "value") do
    with {:ok, ast} <- quoted(text, label), do: literal(ast, label)
  end

  @doc """
  Writes a map as the file's literal text, atomically (a temporary file,
  mode 0600, then a rename), so a crash leaves the old file or the new one,
  never a partial one. `header` is a comment block for the top.
  """
  @spec write!(Path.t(), map(), String.t()) :: :ok
  def write!(path, map, header \\ "") when is_map(map) do
    body =
      map
      |> Enum.sort()
      |> Enum.map_join(",\n", fn {key, value} ->
        # Never truncated, and lists never printed as ~c sigils (a call):
        # either would not read back.
        "  #{inspect(key)} => #{inspect(value, limit: :infinity, printable_limit: :infinity, charlists: :as_lists)}"
      end)

    comments = header |> String.split("\n", trim: true) |> Enum.map_join(&"# #{&1}\n")
    text = comments <> "%{\n" <> body <> "\n}\n"

    File.mkdir_p!(Path.dirname(path))
    tmp = path <> ".tmp"
    # Made 0600 while still empty: the file may hold a password, and there
    # is then no moment when it is readable by others.
    File.write!(tmp, "")
    File.chmod!(tmp, 0o600)
    File.write!(tmp, text)
    File.rename!(tmp, path)
  end

  defp quoted(text, label) do
    case Code.string_to_quoted(text, existing_atoms_only: true, columns: false) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {meta, message, token}} ->
        {:error, ["#{label}:#{meta[:line]}: #{message}#{token}"]}
    end
  end

  # Walks the AST, collecting every fault; values are built only when none.
  defp literal(ast, label) do
    case walk(ast, label) do
      {:ok, value} -> {:ok, value}
      {:error, faults} -> {:error, Enum.reverse(faults)}
    end
  end

  defp walk({:%{}, _, pairs}, label) when is_list(pairs) do
    with {:ok, pairs} <- walk_all(pairs, label), do: {:ok, Map.new(pairs)}
  end

  defp walk({:{}, _, items}, label) when is_list(items) do
    with {:ok, items} <- walk_all(items, label), do: {:ok, List.to_tuple(items)}
  end

  defp walk({:-, _, [n]}, _label) when is_number(n), do: {:ok, -n}
  defp walk(list, label) when is_list(list), do: walk_all(list, label)

  defp walk({a, b}, label) do
    case {walk(a, label), walk(b, label)} do
      {{:ok, a}, {:ok, b}} -> {:ok, {a, b}}
      {x, y} -> {:error, faults(y) ++ faults(x)}
    end
  end

  defp walk(term, _label) when is_atom(term) or is_binary(term) or is_number(term),
    do: {:ok, term}

  defp walk(ast, label) do
    line = ast |> elem(1) |> Keyword.get(:line, "?")
    {:error, ["#{label}:#{line}: not a literal: #{Macro.to_string(ast)}"]}
  end

  defp walk_all(items, label) do
    Enum.reduce(items, {:ok, []}, fn item, acc ->
      case {acc, walk(item, label)} do
        {{:ok, values}, {:ok, value}} -> {:ok, [value | values]}
        {{:ok, _}, {:error, f}} -> {:error, f}
        {{:error, f0}, result} -> {:error, faults(result) ++ f0}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp faults({:error, f}), do: f
  defp faults({:ok, _}), do: []
end
