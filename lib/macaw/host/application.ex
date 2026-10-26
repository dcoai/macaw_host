defmodule Macaw.Host.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    Supervisor.start_link([{Task.Supervisor, name: Macaw.Host.Health.Tasks}],
      strategy: :one_for_one,
      name: Macaw.Host.Supervisor
    )
  end
end
