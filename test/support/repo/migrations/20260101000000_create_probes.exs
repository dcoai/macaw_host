defmodule Macaw.Host.TestRepo.Migrations.CreateProbes do
  @moduledoc """
  The test repo's one migration, as Ecto finds it under the repo's `:priv`.
  Ecto compiles this file each time it runs it, so its body lives in the
  compiled `Macaw.Host.TestRepo.Probes`, which a test that only needs the
  migration run can hand Ecto as a module (see `Macaw.Host.TestRepo`).
  """

  use Ecto.Migration

  defdelegate change, to: Macaw.Host.TestRepo.Probes
end
