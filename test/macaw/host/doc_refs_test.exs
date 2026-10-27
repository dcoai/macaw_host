defmodule Macaw.Host.DocRefsTest do
  @moduledoc """
  Every function a doc names as `Module.fun/arity` exists, so a moduledoc
  can't point a reader at a function that isn't there (`Config.show/2`,
  when it is `show/1`).
  """

  use ExUnit.Case, async: true

  @ref ~r/`((?:Macaw|Ctl)(?:\.[A-Z]\w*)*)\.([a-z_]\w*[?!]?)\/(\d+)`/

  # Every `Module.fun/arity` the macaw_host application's docs name: {where, ref, module, fun, arity}.
  defp refs do
    {:ok, modules} = :application.get_key(:macaw_host, :modules)

    for module <- modules,
        {:docs_v1, _, _, _, moduledoc, _, entries} = Code.fetch_docs(module),
        doc <- [moduledoc | for({_, _, _, doc, _} <- entries, do: doc)],
        %{"en" => text} <- [doc],
        [ref, mod, fun, arity] <- Regex.scan(@ref, text),
        do: {module, ref, Module.concat([mod]), fun, String.to_integer(arity)}
  end

  @tag verifies: "doc-refs"
  test "every Module.fun/arity a doc names exists" do
    missing =
      for {module, ref, mod, fun, arity} <- refs(),
          not exists?(mod, fun, arity),
          do: "#{inspect(module)}: #{ref}"

    assert missing == []
  end

  @tag verifies: "host-docs"
  test "the references checked are macaw_host's own and the generated script's alike" do
    named = for {_, _, mod, _, _} <- refs(), uniq: true, do: hd(Module.split(mod))
    assert "Macaw" in named
    assert "Ctl" in named

    # A function the generated script doesn't have is caught like one of macaw_host's.
    refute exists?(Ctl.Secret, "mask", 2)
    refute exists?(Macaw.Host.Config, "show", 2)
    assert exists?(Ctl.Secret, "mask", 1)
  end

  defp exists?(module, fun, arity) do
    Code.ensure_loaded?(module) and
      Enum.any?(module.__info__(:functions) ++ module.__info__(:macros), fn {name, a} ->
        Atom.to_string(name) == fun and a == arity
      end)
  end
end
