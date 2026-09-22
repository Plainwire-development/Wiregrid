defmodule Mix.Tasks.Wiregrid.Verify do
  use Mix.Task

  @shortdoc "Run Wiregrid release verification gates"

  @impl true
  def run(_args) do
    if Mix.shell().cmd("./scripts/verify.sh") != 0, do: Mix.raise("Wiregrid verification failed")
  end
end
