defmodule Wiregrid.UI do
  @moduledoc """
  Framework-neutral chat UI system bundled with Wiregrid.

  The UI is optional and has no runtime dependency on Phoenix, LiveView, npm or
  a JavaScript framework. Applications can serve the prebuilt `wiregrid.css`
  and `wiregrid.js`, consume the ESM bridge, or compose individual CSS layers.

  All public class names are namespaced with `wg-`. Design tokens use `--wg-*`
  variables so applications can theme the kit without recompiling it.
  """

  @css_layers ~w(tokens base layout components chat utilities motion)
  @theme_keys %{
    accent: "--wg-accent",
    accent_hover: "--wg-accent-hover",
    accent_soft: "--wg-accent-soft",
    background: "--wg-bg",
    panel: "--wg-panel",
    panel_2: "--wg-panel-2",
    panel_3: "--wg-panel-3",
    elevated: "--wg-elevated",
    text: "--wg-text",
    muted: "--wg-muted",
    faint: "--wg-faint",
    border: "--wg-border",
    border_strong: "--wg-border-strong",
    danger: "--wg-danger",
    warning: "--wg-warning",
    success: "--wg-success",
    info: "--wg-info",
    radius: "--wg-r-3",
    radius_small: "--wg-r-2",
    radius_large: "--wg-r-4",
    sidebar_width: "--wg-sidebar",
    members_width: "--wg-members",
    header_height: "--wg-header",
    composer_max_height: "--wg-composer-max",
    content_max_width: "--wg-content-max",
    message_max_width: "--wg-message-max",
    avatar_size: "--wg-avatar",
    avatar_small_size: "--wg-avatar-sm",
    control_height: "--wg-control-h",
    font_sans: "--wg-font-sans",
    font_mono: "--wg-font-mono",
    font_size: "--wg-font-base",
    font_size_small: "--wg-font-sm",
    message_gap: "--wg-message-gap",
    message_padding_x: "--wg-message-pad-x",
    message_padding_y: "--wg-message-pad-y",
    shadow: "--wg-shadow",
    shadow_small: "--wg-shadow-sm"
  }

  def css_path, do: asset_path("wiregrid.css")
  def js_path, do: asset_path("wiregrid.js")
  def esm_path, do: asset_path("wiregrid.esm.js")
  def package_path, do: asset_path("package.json")
  def layers_path, do: asset_path("wiregrid.layers.css")
  def presets, do: ~w(midnight soft plainwire)

  def preset_path("plainwire"), do: asset_path(Path.join("themes", "plainwire.css"))

  def preset_path(name) when name in ["midnight", "soft"],
    do: asset_path(Path.join("presets", name <> ".css"))

  def preset_path(_), do: nil

  def css, do: File.read(css_path())
  def javascript, do: File.read(js_path())
  def esm, do: File.read(esm_path())

  @doc "Returns the available composable CSS layers in cascade order."
  def css_layers, do: @css_layers

  @doc "Returns the path for one composable CSS layer."
  def css_layer_path(layer) when layer in @css_layers,
    do: asset_path(Path.join("css", layer <> ".css"))

  def css_layer_path(_), do: nil

  @doc "Reads one composable CSS layer."
  def css_layer(layer) do
    case css_layer_path(to_string(layer)) do
      nil -> {:error, :unknown_css_layer}
      path -> File.read(path)
    end
  end

  @doc "Builds a safe inline CSS variable declaration for a whitelisted theme map."
  def theme_style(theme) when is_list(theme), do: theme |> Map.new() |> theme_style()

  def theme_style(theme) when is_map(theme) do
    Enum.reduce_while(theme, {:ok, []}, fn {key, value}, {:ok, acc} ->
      with {:ok, css_key} <- Map.fetch(@theme_keys, key),
           true <- is_binary(value),
           :ok <- validate_css_value(value) do
        {:cont, {:ok, [css_key <> ":" <> value | acc]}}
      else
        :error -> {:halt, {:error, {:unknown_theme_key, key}}}
        false -> {:halt, {:error, {:invalid_theme_value, key}}}
        {:error, reason} -> {:halt, {:error, {reason, key}}}
      end
    end)
    |> case do
      {:ok, declarations} -> {:ok, declarations |> Enum.reverse() |> Enum.join(";")}
      error -> error
    end
  end

  def theme_style(_), do: {:error, :invalid_theme}

  defp asset_path(name) do
    :wiregrid |> :code.priv_dir() |> to_string() |> Path.join("ui") |> Path.join(name)
  end

  defp validate_css_value(value) do
    down = String.downcase(value)

    cond do
      byte_size(value) == 0 or byte_size(value) > 128 ->
        {:error, :invalid_theme_value}

      String.contains?(value, [";", "{", "}", "<", ">", "\\", "/*", "*/"]) ->
        {:error, :unsafe_theme_value}

      String.contains?(down, ["url(", "@import", "expression(", "javascript:"]) ->
        {:error, :unsafe_theme_value}

      true ->
        :ok
    end
  end
end
