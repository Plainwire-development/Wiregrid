defmodule Mix.Tasks.Wiregrid.Migrate do
  use Mix.Task

  @shortdoc "Apply Wiregrid PostgreSQL/Scylla schema files with local CLIs"

  @moduledoc """
  Applies the checked-in migration files using `scripts/db-init.sh`.

      mix wiregrid.migrate postgres
      mix wiregrid.migrate scylla
      mix wiregrid.migrate all

  PostgreSQL uses `DATABASE_URL`. Scylla uses `SCYLLA_HOST` and
  `SCYLLA_PORT`. Production applications may instead call
  `Wiregrid.Storage.bootstrap/1` on a configured running instance.
  """

  @impl true
  def run(args) do
    target = List.first(args) || "all"

    unless target in ["postgres", "scylla", "all"] do
      Mix.raise("usage: mix wiregrid.migrate [postgres|scylla|all]")
    end

    if Mix.shell().cmd("./scripts/db-init.sh #{target}") != 0,
      do: Mix.raise("Wiregrid migration failed")
  end
end
