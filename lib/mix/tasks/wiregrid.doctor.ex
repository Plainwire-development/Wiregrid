defmodule Mix.Tasks.Wiregrid.Doctor do
  use Mix.Task

  @shortdoc "Check the local Wiregrid build toolchain"

  @impl true
  def run(_args) do
    run_script!("./scripts/doctor.sh")
  end

  defp run_script!(command) do
    if Mix.shell().cmd(command) != 0, do: Mix.raise("Wiregrid doctor failed")
  end
end
