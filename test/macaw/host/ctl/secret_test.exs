defmodule Macaw.Host.Ctl.SecretTest do
  @moduledoc """
  One masking rule, in two places: `Macaw.Host.Config.mask/2`, which the app
  uses for `config list`, and the generated script's `Ctl.Secret.mask/1`,
  which `env list` uses. Both run over the same values and must agree.
  """

  use ExUnit.Case, async: true

  alias Macaw.Host.Config

  @values [
    nil,
    "",
    "a",
    "abcde",
    "abcdefgh",
    "abcdefghi",
    String.duplicate("x", 15),
    String.duplicate("x", 12) <> "1234",
    "correct-horse-battery",
    String.duplicate("é", 15),
    String.duplicate("é", 12) <> "wxyz"
  ]

  test "the app and the script mask every value alike" do
    for value <- @values do
      assert Config.mask(:secret, value) == Ctl.Secret.mask(value),
             "they disagree on #{inspect(value)}"
    end
  end

  test "the last four show only from 16 characters; unset is unset" do
    shown = Map.new(@values, &{&1, Ctl.Secret.mask(&1)})

    assert shown[nil] == "unset"
    assert shown[""] == "unset"
    assert shown["abcde"] == "set"
    assert shown["abcdefghi"] == "set"
    assert shown[String.duplicate("x", 15)] == "set"
    assert shown[String.duplicate("x", 12) <> "1234"] == "set (…1234)"
    assert shown[String.duplicate("é", 15)] == "set"
    assert shown[String.duplicate("é", 12) <> "wxyz"] == "set (…wxyz)"
  end
end
