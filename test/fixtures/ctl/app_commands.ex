defmodule Ctl.AppCommands do
  @moduledoc """
  Sample's own commands: a fixture for the generator's tests, written the
  way an app writes its `ctl/app_commands.ex`.
  """

  def commands do
    [
      {"ping", "ping", "asks the running Sample whether it answers"},
      {"remote", "remote", "an IEx shell in the running Sample"},
      {"reset-password", "reset-password USER",
       "sets a new password for USER (asked for, never echoed)"}
    ]
  end

  def run("ping", env, []) do
    with :ok <- Ctl.Commands.ensure_running(env) do
      env
      |> Ctl.Env.get("NAME")
      |> Ctl.Docker.rpc_args("#{Ctl.App.release()}.ping()")
      |> Ctl.Commands.stream()
    end
  end

  def run("remote", env, []) do
    with :ok <- Ctl.Commands.ensure_running(env) do
      env
      |> Ctl.Env.get("NAME")
      |> Ctl.Docker.exec_args([Ctl.App.release_bin(), "remote"], true)
      |> Ctl.Commands.interactive()
    end
  end

  def run("reset-password", env, [user]) do
    with :ok <- Ctl.Commands.ensure_ready(env) do
      password = Ctl.World.prompt_secret("New password for #{user}: ")
      {argv, opts} = Ctl.Docker.release_args(env, "reset_password", [user], password)
      Ctl.Docker.run(argv, opts) |> Ctl.Commands.exit_status()
    end
  end

  def run(command, _env, _args), do: {:error, "usage: ./#{Ctl.App.script()} #{command} …"}

  @doc "The admin console's port, published beside the web port."
  def run_args(env), do: ["-p", "#{Ctl.Env.get(env, "ADMIN_PORT")}:4001"]

  @doc "ADMIN_PORT is a port, and not PORT."
  def validate(env) do
    admin = Ctl.Env.get(env, "ADMIN_PORT")

    case Integer.parse(admin) do
      {n, ""} when n in 1..65_535 ->
        if admin == Ctl.Env.get(env, "PORT"),
          do: {:error, "ADMIN_PORT must differ from PORT (both #{admin})"},
          else: :ok

      _ ->
        {:error, "ADMIN_PORT must be a port number (1–65535), not #{inspect(admin)}"}
    end
  end

  @doc "The admin console's URL, from this host's ADMIN_PORT."
  def seeds(env), do: [admin_url: "http://localhost:#{Ctl.Env.get(env, "ADMIN_PORT")}"]

  @doc "The admin console's port, on status's host lines."
  def status_lines(env), do: ["admin:    port #{Ctl.Env.get(env, "ADMIN_PORT")}"]
end
