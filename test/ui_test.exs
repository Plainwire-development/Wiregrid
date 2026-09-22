defmodule Wiregrid.UITest do
  use ExUnit.Case, async: true

  test "bundled UI assets and layers are readable" do
    assert {:ok, css} = Wiregrid.UI.css()
    assert css =~ ".wg-message"
    assert css =~ ".wg-command"
    assert Wiregrid.UI.css_layers() == ~w(tokens base layout components chat utilities motion)
    assert {:ok, chat} = Wiregrid.UI.css_layer(:chat)
    assert chat =~ ".wg-thread"
    assert {:ok, js} = Wiregrid.UI.javascript()
    assert js =~ "textContent"
    assert js =~ "mountComposer"
    refute js =~ "innerHTML ="
    assert {:ok, esm} = Wiregrid.UI.esm()
    assert esm =~ "export default"
  end

  test "theme style only permits known variables and safe values" do
    assert {:ok, style} = Wiregrid.UI.theme_style(accent: "#abcdef", panel: "rgb(1 2 3)")
    assert style =~ "--wg-accent:#abcdef"
    assert {:error, {:unknown_theme_key, :evil}} = Wiregrid.UI.theme_style(evil: "red")

    assert {:error, {:unsafe_theme_value, :accent}} =
             Wiregrid.UI.theme_style(accent: "red;background:url(x)")

    assert {:error, {:unsafe_theme_value, :accent}} =
             Wiregrid.UI.theme_style(accent: "URL(https://x.invalid/a)")
  end
end
