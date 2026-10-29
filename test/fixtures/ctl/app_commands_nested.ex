# An app's commands whose nested module defines what the contract asks of
# Ctl.AppCommands itself: run/3, and status_lines/1, the hook's old arity.
# The top module lacks run/3, so the generator refuses it; a nested module's
# functions are its own, never the contract's.
defmodule Ctl.AppCommands do
  @moduledoc "Commands, with a helper module of the same names."

  defmodule Helpers do
    @moduledoc false

    def run(command, _env, _args), do: {:error, "unknown command: #{command}"}
    def status_lines(_env), do: []
  end

  def commands, do: []
end
