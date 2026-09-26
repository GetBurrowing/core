defmodule Platform.Branding.ThemeCssTest do
  @moduledoc """
  `Platform.Branding.ThemeCss.render/1` (task
  01a0dbee-f598-7001-b450-7890103f44c4 stage 2). Pure: builds structs, no
  database. The end-to-end half (the row reaching the rendered page) is
  `PlatformWeb.RootLayoutThemeColorsTest`.
  """

  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Platform.Branding.InstallBranding
  alias Platform.Branding.Palette
  alias Platform.Branding.ThemeCss

  @light_sel ~s|:root:not([data-theme]),[data-theme="light"]:not([data-theme-preview])|
  @dark_sel ~s|[data-theme="dark"]:not([data-theme-preview])|
  @os_dark ~s|@media (prefers-color-scheme: dark){:root:not([data-theme="light"])|

  @sentinels %{
    light_action: "#7a3fd1",
    light_surface: "#fbfaf5",
    dark_action: "#9fe870",
    dark_surface: "#10141a"
  }

  defp branding(attrs), do: struct(%InstallBranding{}, attrs)

  # The declarations inside the FIRST block whose selector is exactly `sel`.
  defp block(css, sel) do
    idx = :binary.match(css, sel <> "{") |> elem(0)
    rest = binary_part(css, idx + byte_size(sel) + 1, byte_size(css) - idx - byte_size(sel) - 1)
    [body | _] = String.split(rest, "}", parts: 2)

    body
    |> String.split(";", trim: true)
    |> Map.new(fn decl ->
      [k, v] = String.split(decl, ":", parts: 2)
      {k, v}
    end)
  end

  test "a row with no colours renders nil" do
    assert ThemeCss.render(%InstallBranding{}) == nil
  end

  test "each mode's block carries that mode's derived tokens, in daisy's selector order" do
    css = ThemeCss.render(branding(@sentinels))

    light = block(css, @light_sel)
    dark = block(css, @dark_sel)
    os_dark = block(css, ":root:not([data-theme=\"light\"])")

    assert light ==
             Palette.derive(:light, %{action: "#7a3fd1", surface: "#fbfaf5", accent: nil})

    assert dark == Palette.derive(:dark, %{action: "#9fe870", surface: "#10141a", accent: nil})
    assert os_dark == dark

    assert light["--color-primary"] == "#7a3fd1"
    assert light["--color-base-100"] == "#fbfaf5"
    assert dark["--color-primary"] == "#9fe870"
    assert dark["--color-base-100"] == "#10141a"

    assert Enum.sort(Map.keys(light)) == Enum.sort(ThemeCss.tokens())

    {light_at, _} = :binary.match(css, @light_sel)
    {dark_at, _} = :binary.match(css, @dark_sel <> "{")
    {os_at, _} = :binary.match(css, @os_dark)
    assert light_at < dark_at and dark_at < os_at
    assert String.ends_with?(css, "}}")
  end

  test "never declares the @theme inline keys or any status token" do
    css = ThemeCss.render(branding(@sentinels))

    refute css =~ "--color-edge:"
    refute css =~ "--color-focus-ring:"

    for status <- ~w(info success warning error neutral secondary pipeline-human) do
      refute css =~ "--color-#{status}", "emitted --color-#{status}"
    end

    assert css =~ "--edge:"
    assert css =~ "--focus-ring:"
    assert css =~ "--color-interactive:"
  end

  test "a mode with every slot nil emits no block for that mode" do
    css = ThemeCss.render(branding(%{light_action: "#7a3fd1"}))

    assert css =~ @light_sel
    refute css =~ @dark_sel
    refute css =~ "prefers-color-scheme"
    # The unset light surface resolves to the Suite default.
    assert block(css, @light_sel)["--color-base-100"] == Palette.suite_defaults().light.surface

    css = ThemeCss.render(branding(%{dark_surface: "#10141a"}))
    refute css =~ @light_sel
    assert block(css, @dark_sel)["--color-primary"] == Palette.suite_defaults().dark.action
    assert css =~ @os_dark
  end

  test "an invalid stored value is dropped and logged, never interpolated" do
    hostile = "#fff;}</style><script>alert(1)</script>"

    {css, log} =
      with_log(fn ->
        ThemeCss.render(branding(%{light_action: hostile, dark_action: "#9fe870"}))
      end)

    refute css =~ "script"
    refute css =~ "alert"
    refute css =~ @light_sel
    assert css =~ @dark_sel
    assert log =~ "dropped stored light_action"

    {nil_css, _} = with_log(fn -> ThemeCss.render(branding(%{light_surface: "red"})) end)
    assert nil_css == nil
  end

  test "every emitted value is a lowercase #rrggbb" do
    css = ThemeCss.render(branding(Map.put(@sentinels, :light_accent, "#ABCDEF")))

    values = Regex.scan(~r/:(#[^;]*);/, css) |> Enum.map(&Enum.at(&1, 1))
    assert values != []
    assert Enum.all?(values, &Regex.match?(~r/\A#[0-9a-f]{6}\z/, &1))
    assert block(css, @light_sel)["--color-accent"] == "#abcdef"
  end

  describe "mode_declarations/2 (the admin preview's inline style, stage 4)" do
    test "is exactly the body of the block render/1 emits for that mode" do
      css = ThemeCss.render(branding(@sentinels))

      assert css =~
               "#{@light_sel}{#{ThemeCss.mode_declarations(:light, %{action: "#7a3fd1", surface: "#fbfaf5", accent: nil})}}"

      assert css =~
               "#{@dark_sel}{#{ThemeCss.mode_declarations(:dark, %{action: "#9fe870", surface: "#10141a", accent: nil})}}"
    end

    test "all-nil is nil and a non-hex slot is dropped, never interpolated" do
      assert ThemeCss.mode_declarations(:light, %{action: nil, surface: nil, accent: nil}) == nil

      decl =
        ThemeCss.mode_declarations(:light, %{action: "red;}</style>", surface: nil, accent: nil})

      assert decl == nil or not String.contains?(decl, "</style>")
    end

    test "the saved-theme selectors exclude a data-theme-preview element" do
      css = ThemeCss.render(branding(@sentinels))
      assert css =~ ~s|[data-theme="light"]:not([data-theme-preview]){|
      assert css =~ ~s|[data-theme="dark"]:not([data-theme-preview]){|
    end
  end
end
