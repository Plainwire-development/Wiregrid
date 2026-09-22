defmodule Mix.Tasks.Wiregrid.Gen.Chat do
  use Mix.Task

  @shortdoc "Generates a tiny Wiregrid.Chat module"

  @moduledoc """
  Generates an opinionated chat façade module.

      mix wiregrid.gen.chat MyApp.Chat
      mix wiregrid.gen.chat MyApp.Chat --instance main_chat --profile small

  The generated module is intended to be added directly to your supervision
  tree. Existing files are never overwritten.
  """

  @switches [instance: :string, profile: :string, message_bytes: :integer]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)
    if invalid != [], do: Mix.raise("invalid options: #{inspect(invalid)}")

    module =
      case positional do
        [name] ->
          validate_module!(name)

        _ ->
          Mix.raise(
            "usage: mix wiregrid.gen.chat MyApp.Chat [--instance chat] [--profile small|balanced|large]"
          )
      end

    profile = opts |> Keyword.get(:profile, "small") |> parse_profile!()
    instance = opts |> Keyword.get(:instance, "chat") |> validate_instance!()
    message_bytes = Keyword.get(opts, :message_bytes, 65_536)

    if message_bytes < 256 or message_bytes > 1_048_576,
      do: Mix.raise("--message-bytes must be between 256 and 1048576")

    path = module_path(module)

    if File.exists?(path), do: Mix.raise("refusing to overwrite existing file #{path}")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, source(module, instance, profile, message_bytes))
    Mix.shell().info("created #{path}")
    Mix.shell().info("add #{module} to your application supervision children")
  end

  defp validate_module!(name) do
    if Regex.match?(~r/^[A-Z][A-Za-z0-9_]*(\.[A-Z][A-Za-z0-9_]*)*$/, name),
      do: name,
      else: Mix.raise("invalid Elixir module name: #{name}")
  end

  defp validate_instance!(name) do
    if Regex.match?(~r/^[a-z][a-z0-9_]{0,63}$/, name),
      do: name,
      else: Mix.raise("--instance must match [a-z][a-z0-9_]{0,63}")
  end

  defp parse_profile!("small"), do: :small
  defp parse_profile!("balanced"), do: :balanced
  defp parse_profile!("large"), do: :large
  defp parse_profile!(other), do: Mix.raise("invalid profile #{inspect(other)}")

  defp module_path(module) do
    file =
      module
      |> String.split(".")
      |> List.last()
      |> Macro.underscore()

    Path.join(["lib", file <> ".ex"])
  end

  defp source(module, instance, profile, message_bytes) do
    """
    defmodule #{module} do
      use Wiregrid.Chat,
        instance: #{inspect(instance)},
        options: [profile: #{inspect(profile)}, cluster: false],
        chat: [max_message_bytes: #{message_bytes}]
    end
    """
  end
end
