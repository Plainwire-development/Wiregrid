defmodule Mix.Tasks.Wiregrid.Ui.Install do
  use Mix.Task

  @shortdoc "Copies the bundled Wiregrid UI kit into your application's static assets"

  @moduledoc """
  Copies the versioned, dependency-free Wiregrid UI assets into a destination.

      mix wiregrid.ui.install
      mix wiregrid.ui.install priv/static/vendor/wiregrid

  Existing files are not overwritten unless `--force` is supplied. The task
  copies the prebuilt bundle, ESM bridge and composable CSS source layers.
  """

  @switches [force: :boolean]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    destination =
      case positional do
        [] -> "priv/static/vendor/wiregrid"
        [path] -> path
        _ -> Mix.raise("usage: mix wiregrid.ui.install [destination] [--force]")
      end

    source = :wiregrid |> :code.priv_dir() |> to_string() |> Path.join("ui")
    destination = Path.expand(destination, File.cwd!())
    force? = Keyword.get(opts, :force, false)

    unless File.dir?(source), do: Mix.raise("bundled Wiregrid UI assets were not found")
    File.mkdir_p!(destination)

    source
    |> files()
    |> Enum.each(fn path ->
      relative = Path.relative_to(path, source)
      target = Path.join(destination, relative)
      File.mkdir_p!(Path.dirname(target))

      if File.exists?(target) and not force? do
        Mix.shell().info("skip    #{Path.relative_to_cwd(target)} (already exists)")
      else
        File.cp!(path, target)
        Mix.shell().info("copy    #{Path.relative_to_cwd(target)}")
      end
    end)
  end

  defp files(root) do
    root
    |> File.ls!()
    |> Enum.sort()
    |> Enum.flat_map(fn name ->
      path = Path.join(root, name)
      if File.dir?(path), do: files(path), else: [path]
    end)
  end
end
