defmodule Platform.Design.PhoneComposerCssGuardTest do
  @moduledoc """
  Guards the phone composer (task 01a15f2e-80cd-7000-8990-3b721f8bd938, stage
  2; Saru's canvas 01a15f2f-5a5f-7000-8d85-1e9717443a8b, nodes meas r3/r4,
  type and pal): below lg the chat composer is a 44px glass pill sitting 8px
  above the tab bar, with a one-line placeholder that ends in an ellipsis.

  Rules are read with `Platform.Design.CssRules`, comments stripped, one entry
  per compound selector, with the enclosing at-rule preludes in `at`.

  ## What it pins

    * Anti-vacuity first: the phone block exists and holds the pill rule.
    * DESKTOP IS UNTOUCHED. Every rule naming `.compose-input-area`,
      `.compose-pill-bar`, `.compose-pill-attach` or `.compose-pill-send`
      OUTSIDE `@media (max-width: 1023.98px)` equals `@desktop_snapshot`, a
      literal taken from origin/feat/redesign bbe3a040 (selector, at-rule
      context and comment-free body, in source order). So a phone rule moved
      out of the media block, or any desktop edit, goes red. Comments are
      stripped, so a comment-only edit does not count as a change.
    * The pill's background, backdrop filters and border are the tab bar's
      own strings, read from `.bottom-nav` in the same file, and the pill
      declares no box-shadow. The reduced-transparency fallback is the bar's.
    * Send has no resting glow below lg.
    * The placeholder rule carries `white-space: nowrap` and
      `text-overflow: ellipsis`.
    * No phone composer rule has a `[data-theme` selector or a colour literal.
    * The composer's bottom padding is the 8px gap above the bar.

  Named mutations, each shown red in the stage 2 evidence: (a) drop the
  ellipsis; (b) move the pill background out of the media block; (c) a
  box-shadow on the pill; (d) a border slot other than the bar's; (e) a
  `[data-theme="light"]`-qualified phone rule.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @phone "@media (max-width: 1023.98px)"
  @composer ~r/\.compose-(input-area|pill-bar|pill-attach|pill-send)(?![\w-])/
  @pill_glass ":root .compose-input-area .compose-pill-bar"
  @pill_border ".compose-input-area .compose-pill-bar:not(:focus-within)"
  @colour_literal ~r/#[0-9a-fA-F]{3,8}\b|\brgba?\(|\bhsla?\(|\boklch\(|\boklab\(|\blab\(|\blch\(|\bhwb\(/

  # Every composer rule outside the phone block at origin/feat/redesign
  # bbe3a040, as CssRules reads it. Regenerate only for a deliberate desktop
  # change, and say so in that change.
  #
  # Deliberate change, redesign rung 10 (task 01a1557a-997a stage 2): Send is
  # lit in primary (no cyan literal, no glow) and rests as a subtle icon on
  # the composer's ground, really disabled, with no opacity fade; the light
  # theme's own disabled rule went with the literals (24 -> 23 rules).
  @desktop_snapshot [
    {".compose-input-area", [], "padding: 12px 20px 16px;"},
    {".compose-pill-bar", [],
     "display: flex;\n  flex-wrap: wrap;\n  align-items: center;\n  gap: 10px;\n  container-type: inline-size;\n  background: oklch(0.21 0 0);\n  border: 1px solid rgba(255, 255, 255, 0.08);\n  border-radius: 26px;\n  padding: 8px 8px 8px 18px;\n  \n  transition: border-color 200ms cubic-bezier(0.16, 1, 0.3, 1),\n              box-shadow 200ms cubic-bezier(0.16, 1, 0.3, 1);"},
    {".compose-pill-bar .hidden", [],
     "position: absolute !important;\n  width: 1px !important;\n  height: 1px !important;\n  padding: 0 !important;\n  margin: -1px !important;\n  overflow: hidden !important;\n  clip: rect(0, 0, 0, 0) !important;\n  white-space: nowrap !important;\n  border: 0 !important;"},
    {".compose-pill-bar:focus-within", [],
     "border-color: var(--color-focus-ring);\n  box-shadow: 0 0 0 2px var(--color-focus-ring);"},
    {"[data-theme=\"dark\"] .compose-pill-bar:focus-within", [],
     "border-color: var(--color-focus-ring);\n  box-shadow: 0 0 0 2px var(--color-focus-ring);"},
    {":root:not([data-theme=\"light\"]) .compose-pill-bar:focus-within", [],
     "border-color: var(--color-focus-ring);\n  box-shadow: 0 0 0 2px var(--color-focus-ring);"},
    {"[data-theme=\"dark\"] .compose-pill-bar", [],
     "background: oklch(0.21 0 0);\n  border-color: rgba(255, 255, 255, 0.08);"},
    {":root:not([data-theme=\"light\"]) .compose-pill-bar", [],
     "background: oklch(0.21 0 0);\n  border-color: rgba(255, 255, 255, 0.08);"},
    {"[data-theme=\"light\"] .compose-pill-bar", [],
     "background: oklch(1 0 0);\n  border-color: rgba(0, 0, 0, 0.08);"},
    {"[data-theme=\"light\"] .compose-pill-bar:focus-within", [],
     "border-color: var(--color-focus-ring);\n  box-shadow: 0 0 0 2px var(--color-focus-ring);"},
    {".compose-pill-bar textarea", [],
     "flex: 1;\n  background: none !important;\n  border: none !important;\n  outline: none !important;\n  box-shadow: none !important;\n  border-radius: 0 !important;\n  padding: 4px 0 !important;\n  \n  min-width: 7.5rem;\n  color: inherit;\n  font-size: 14px;\n  line-height: 1.5;"},
    {".compose-pill-bar textarea::placeholder", [], "color: var(--color-subtle);"},
    {".compose-pill-bar textarea", ["@media (hover: none)"], "font-size: 16px;"},
    {".compose-pill-bar", [], "container-type: inline-size;"},
    {".compose-pill-bar textarea", ["@container (max-width: 260px)"],
     "flex-basis: 100%;\n    order: -1;"},
    {".compose-pill-attach", [],
     "width: 32px;\n  height: 32px;\n  border-radius: 50%;\n  display: flex;\n  align-items: center;\n  justify-content: center;\n  flex-shrink: 0;"},
    {".compose-pill-attach", ["@media (hover: none)"], "width: 44px;\n    height: 44px;"},
    {".compose-pill-send", ["@media (hover: none)"],
     "width: 44px !important;\n    height: 44px !important;\n    min-height: 44px !important;"},
    {".compose-pill-send", [],
     "width: 36px;\n  height: 36px;\n  min-height: 36px;\n  border-radius: 50% !important;\n  background: var(--color-primary) !important;\n  color: var(--color-primary-content) !important;\n  display: flex !important;\n  align-items: center !important;\n  justify-content: center !important;\n  flex-shrink: 0;\n  padding: 0 !important;\n  border: none !important;\n  box-shadow: none;\n  transition: transform 200ms cubic-bezier(0.16, 1, 0.3, 1),\n              box-shadow 200ms cubic-bezier(0.16, 1, 0.3, 1),\n              opacity 200ms cubic-bezier(0.16, 1, 0.3, 1),\n              background 200ms cubic-bezier(0.16, 1, 0.3, 1);"},
    {".compose-pill-send:hover:not(:disabled)", [], "transform: scale(1.05);"},
    {".compose-pill-send:active:not(:disabled)", [], "transform: scale(0.95);"},
    {".compose-pill-send:disabled", [],
     "background: transparent !important;\n  color: var(--color-subtle) !important;\n  box-shadow: none;\n  cursor: default;\n  opacity: 1;\n  transform: none;"},
    {":root:not([data-theme=\"light\"]) .compose-pill-bar",
     ["@media (prefers-color-scheme: dark)"],
     "background: oklch(0.21 0 0);\n    border-color: rgba(255, 255, 255, 0.08);"}
  ]

  setup_all do
    rules = CssRules.rules(File.read!(@app_css_path))
    composer = Enum.filter(rules, &(&1.selector =~ @composer))
    phone = Enum.filter(composer, &(List.first(&1.at) == @phone))
    desktop = Enum.reject(composer, &(@phone in &1.at))
    {:ok, rules: rules, phone: phone, desktop: desktop}
  end

  test "anti-vacuity: the phone block is found and holds the glass pill", %{phone: phone} do
    assert phone != []
    assert Enum.any?(phone, &(&1.selector == @pill_glass and &1.at == [@phone]))
    assert Enum.any?(phone, &(&1.selector == @pill_border and &1.at == [@phone]))
    assert length(@desktop_snapshot) == 23
  end

  test "desktop composer rules equal the feat/redesign snapshot", %{desktop: desktop} do
    got = Enum.map(desktop, &{&1.selector, &1.at, &1.body})

    assert got == @desktop_snapshot,
           "desktop composer rules changed (or a phone rule left the max-lg block): " <>
             inspect(List.myers_difference(@desktop_snapshot, got), pretty: true)
  end

  test "the pill's glass is the tab bar's own declarations", %{rules: rules, phone: phone} do
    [bar] = Enum.filter(rules, &(&1.selector == ".bottom-nav" and &1.at == []))
    glass = body!(phone, @pill_glass, [@phone])
    border = body!(phone, @pill_border, [@phone])

    for prop <- ["background", "-webkit-backdrop-filter", "backdrop-filter"] do
      assert decl(bar.body, prop) != nil, "the bar lost #{prop}"
      assert decl(glass, prop) == decl(bar.body, prop), "pill #{prop} differs from the bar's"
    end

    assert decl(border, "border") == decl(bar.body, "border")
    assert decl(border, "border") == "1px solid var(--color-base-300)"

    [bar_fb] =
      Enum.filter(
        rules,
        &(&1.selector == ".bottom-nav" and
            &1.at == ["@media (prefers-reduced-transparency: reduce)"])
      )

    fb = body!(phone, @pill_glass, [@phone, "@media (prefers-reduced-transparency: reduce)"])

    for prop <- ~w(--glass-alpha --glass-blur background -webkit-backdrop-filter backdrop-filter) do
      assert decl(fb, prop) == decl(bar_fb.body, prop), "fallback #{prop} differs from the bar's"
    end
  end

  test "the pill declares no box-shadow and send has no resting glow", %{phone: phone} do
    shadowed =
      for r <- phone,
          r.selector =~ ~r/\.compose-pill-bar(:not\(:focus-within\))?$/,
          CssRules.declares?(r.body, "box-shadow"),
          do: {r.selector, r.at}

    assert shadowed == []

    send = for r <- phone, r.selector == ".compose-input-area .compose-pill-send", do: r.body
    assert Enum.any?(send, &(decl(&1, "box-shadow") == "none"))
  end

  test "the placeholder is one line with an ellipsis", %{phone: phone} do
    body = body!(phone, ".compose-input-area .compose-pill-bar textarea::placeholder", [@phone])
    assert decl(body, "white-space") == "nowrap"
    assert decl(body, "text-overflow") == "ellipsis"
    assert decl(body, "overflow") == "hidden"
  end

  test "no phone composer rule has a data-theme selector or a colour literal",
       %{phone: phone} do
    bad =
      for r <- phone,
          r.selector =~ "[data-theme" or r.body =~ @colour_literal,
          do: {r.selector, r.body}

    assert bad == []
  end

  test "the composer sits 8px above the bar", %{phone: phone} do
    pads =
      phone
      |> Enum.filter(&(&1.selector == ".compose-input-area"))
      |> Enum.map(&decl(&1.body, "padding-bottom"))
      |> Enum.reject(&is_nil/1)

    assert pads == ["calc(8px + var(--bottom-nav-clearance))"]
  end

  defp body!(rules, selector, at) do
    case Enum.filter(rules, &(&1.selector == selector and &1.at == at)) do
      [r] -> r.body
      other -> flunk("expected one #{selector} in #{inspect(at)}, found #{length(other)}")
    end
  end

  defp decl(body, prop) do
    case Regex.run(~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m, body) do
      [_, v] ->
        v
        |> String.replace(~r/\s+/, " ")
        |> String.replace("( ", "(")
        |> String.replace(" )", ")")
        |> String.trim()

      nil ->
        nil
    end
  end
end
