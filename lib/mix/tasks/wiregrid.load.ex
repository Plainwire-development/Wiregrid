defmodule Mix.Tasks.Wiregrid.Load do
  use Mix.Task

  @shortdoc "Run the public-API Wiregrid load harness"

  @impl true
  def run(_args) do
    if Mix.shell().cmd("./scripts/load.sh") != 0, do: Mix.raise("Wiregrid load harness failed")
  end
end
