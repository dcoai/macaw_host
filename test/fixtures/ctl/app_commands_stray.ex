# An app's commands with code outside Ctl.AppCommands: it would run every
# time the script loads, so the generator refuses it, naming line 10.
defmodule Ctl.AppCommands do
  @moduledoc "Commands, and a stray call below."

  def commands, do: []
  def run(command, _env, _args), do: {:error, "unknown command: #{command}"}
end

alias Ctl.AppCommands
File.rm_rf!("/srv")
