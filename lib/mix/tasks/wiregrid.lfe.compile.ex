defmodule Mix.Tasks.Wiregrid.Lfe.Compile do
  use Mix.Task

  @shortdoc "Compiles Wiregrid's optional LFE hot-path modules"

  @moduledoc """
  Compiles every source in `bindings/lfe` into the current Mix build's ebin.

  This task is explicit so Wiregrid does not make LFE a mandatory dependency for
  ordinary Elixir deployments. It requires either `lfec` or `lfe` on PATH.
  """

  @impl true
  def run(_args) do
    Mix.Task.run("compile")
    root = File.cwd!()
    source_dir = Path.join(root, "bindings/lfe")
    out = Path.join(Mix.Project.build_path(), "lib/wiregrid/ebin")
    File.mkdir_p!(out)

    files =
      source_dir
      |> Path.join("*.lfe")
      |> Path.wildcard()
      |> Enum.sort()
      |> prioritize_macros()

    if files == [], do: Mix.raise("no LFE sources found under bindings/lfe")

    cond do
      compiler = System.find_executable("lfec") ->
        Enum.each(files, &run_lfec!(compiler, out, &1))

      lfe = System.find_executable("lfe") ->
        Enum.each(files, &run_lfe!(lfe, out, &1))

      true ->
        Mix.raise("Wiregrid LFE compilation requires `lfec` or `lfe` on PATH")
    end

    Mix.shell().info("Compiled #{length(files)} Wiregrid LFE modules into #{out}")
  end

  defp prioritize_macros(files) do
    Enum.sort_by(files, fn path ->
      if Path.basename(path) == "wiregrid_macros.lfe", do: 0, else: 1
    end)
  end

  defp run_lfec!(compiler, out, file) do
    case System.cmd(compiler, ["-o", out, file], stderr_to_stdout: true) do
      {output, 0} -> if output != "", do: Mix.shell().info(String.trim(output))
      {output, status} -> Mix.raise("lfec failed for #{file} (#{status}):\n#{output}")
    end
  end

  defp run_lfe!(lfe, out, file) do
    escaped_file = escape_lfe_string(file)
    escaped_out = escape_lfe_string(out)

    expression =
      "(progn (c \"#{escaped_file}\" (list (tuple 'outdir \"#{escaped_out}\"))) (halt))"

    case System.cmd(lfe, ["-noshell", "-eval", expression], stderr_to_stdout: true) do
      {output, 0} -> if output != "", do: Mix.shell().info(String.trim(output))
      {output, status} -> Mix.raise("lfe failed for #{file} (#{status}):\n#{output}")
    end
  end

  defp escape_lfe_string(value),
    do: value |> String.replace("\\", "\\\\") |> String.replace("\"", "\\\"")
end
