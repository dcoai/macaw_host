defmodule Macaw.Host.DocRefsTest do
  @moduledoc """
  Every function a doc names as `Module.fun/arity` exists, so a moduledoc
  can't point a reader at a function that isn't there (`Config.show/2`,
  when it is `show/1`).
  """

  use ExUnit.Case, async: true

  @ref ~r/`((?:Macaw|Ctl)(?:\.[A-Z]\w*)*)\.([a-z_]\w*[?!]?)\/(\d+)`/

  test "every Module.fun/arity a doc names exists" do
    {:ok, modules} = :application.get_key(:macaw_host, :modules)

    missing =
      for module <- modules,
          {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module),
          doc <- [moduledoc | for({_, _, _, doc, _} <- entries, do: doc)],
          %{"en" => text} <- [doc],
          [ref, mod, fun, arity] <- Regex.scan(@ref, text),
          not exists?(Module.concat([mod]), fun, String.to_integer(arity)),
          do: "#{inspect(module)}: #{ref}"

    assert missing == []
  end

  defp exists?(module, fun, arity) do
    Code.ensure_loaded?(module) and
      Enum.any?(module.__info__(:functions) ++ module.__info__(:macros), fn {name, a} ->
        Atom.to_string(name) == fun and a == arity
      end)
  end
end
