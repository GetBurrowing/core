defmodule Platform.Design.PressFeedbackGuardTest do
  @moduledoc """
  Holds the press feedback contract (task 01a166be-b5b9, design canvas
  01a167b0 "Press and pending feedback"): hover, pressed and current never
  share a look on the bottom tabs, the desktop rail tiles, the More sheet
  rows and the menu items.

  | control         | hover (hover: hover) | pressed (:active)          | current                     |
  |-----------------|----------------------|----------------------------|-----------------------------|
  | bottom tab      | ink to base-content  | cell scale(0.92) + ink     | primary ink + tinted pill   |
  | rail tile       | icon ink to body     | icon scale(0.92) + ink     | base-300 tile + primary bar |
  | More sheet row  | base-200 fill        | base-300 fill              | no fill, 3px bar, weight 600 |
  | menu item       | base-200 (utility)   | base-300                   | (none exists)               |

  The bottom tab's press scales the whole CELL since the sliding pill
  (the product lead's pick, prototype t1): `.bottom-nav-tab.is-pressed`, set by the
  TabPill hook on pointerdown, over 80ms. It replaced the icon-only scale.

  Reduced motion removes every press scale and keeps the ink. iOS only fires
  `:active` with a touchstart listener, so app.js registers one on document.

  Every rule is read with `Platform.Design.CssRules` (selector lists split,
  at-rules recorded), and each lookup asserts it found exactly one rule
  before it reads a body, so a renamed selector goes red instead of passing
  over nothing.
  """
  use ExUnit.Case, async: true

  alias Platform.Design.CssRules

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @app_js_path Path.expand("../../../assets/js/app.js", __DIR__)
  @nav_pending_path Path.expand("../../../assets/js/lib/nav_pending.js", __DIR__)

  @hover ["@media (hover: hover)"]
  @reduced ["@media (prefers-reduced-motion: reduce)"]

  setup_all do
    css = File.read!(@app_css_path)

    {:ok,
     rules: CssRules.rules(css),
     keyframes: CssRules.keyframes(css),
     app_js: File.read!(@app_js_path),
     nav_pending_js: File.read!(@nav_pending_path)}
  end

  defp one!(rules, at, selector) do
    case Enum.filter(rules, &(&1.selector == selector and &1.at == at)) do
      [r] -> r.body
      other -> flunk("expected one #{inspect(at)} `#{selector}` rule, found #{length(other)}")
    end
  end

  defp decl(body, prop) do
    case Regex.run(~r/(?:^|[;\s{])#{Regex.escape(prop)}:\s*([^;]+);/, body) do
      [_, v] -> String.trim(v)
      nil -> nil
    end
  end

  # A rule body as a comparable set of `prop: value` pairs, transitions
  # dropped (timing is not a look).
  defp look(body) do
    body
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "transition")))
    |> Enum.map(&String.replace(&1, ~r/\s+/, " "))
    |> MapSet.new()
  end

  defp assert_distinct(looks) do
    for {a, la} <- looks, {b, lb} <- looks, a < b do
      assert la != lb, "#{a} and #{b} share a look: #{inspect(MapSet.to_list(la))}"
    end
  end

  describe "bottom tabs" do
    test "hover, pressed and current resolve to different declarations", %{rules: rules} do
      hover =
        one!(
          rules,
          @hover,
          ".bottom-nav-tab:not(.bottom-nav-tab--active):not([data-nav-pending]):hover"
        )

      pressed_ink = one!(rules, [], ".bottom-nav-tab:not(.bottom-nav-tab--active):active")
      pressed_cell = one!(rules, [], ".bottom-nav-tab.is-pressed")
      current = one!(rules, [], ".bottom-nav-tab--active")

      assert decl(hover, "color") == "var(--color-base-content)"
      assert decl(pressed_ink, "color") == "var(--color-base-content)"
      assert decl(pressed_cell, "transform") == "scale(0.92)"
      assert decl(current, "color") == "var(--color-primary)"

      assert_distinct(
        hover: look(hover),
        pressed: MapSet.union(look(pressed_ink), look(pressed_cell)),
        current: look(current)
      )
    end

    test "the cell scales on press over 80ms; the ink press-in is instant", %{rules: rules} do
      active = one!(rules, [], ".bottom-nav-tab:active")
      assert decl(active, "transform") == nil, "the scale is the hook's is-pressed, not :active"
      assert decl(active, "transition") =~ ~r/^color 0ms,\s*transform 80ms$/

      assert decl(one!(rules, [], ".bottom-nav-tab"), "transition") =~
               ~r/transform 80ms$/

      # The icon no longer scales on its own (it would compound to 0.85).
      refute Enum.any?(rules, &(&1.selector =~ ~r/bottom-nav-tab:active \.bottom-nav-icon/))

      # Labels never change size or weight on press.
      refute Enum.any?(rules, &(&1.selector =~ ~r/:active.*\.bottom-nav-label/))
    end
  end

  describe "desktop rail" do
    test "hover is ink-only and no longer shares the current tile's base-300", %{rules: rules} do
      hovers = for r <- rules, r.selector =~ ".icon-rail-tab", r.selector =~ ":hover", do: r
      assert hovers != []

      for r <- hovers do
        assert r.at == @hover, "#{r.selector} must be media-gated"
        assert decl(r.body, "background") == nil, "#{r.selector} paints a fill"
        assert decl(r.body, "background-color") == nil, "#{r.selector} paints a fill"
      end

      hover =
        one!(rules, @hover, ".icon-rail-tab:not(.icon-rail-tab--active):hover .icon-rail-icon")

      pressed_ink =
        one!(rules, [], ".icon-rail-tab:not(.icon-rail-tab--active):active .icon-rail-icon")

      pressed_icon = one!(rules, [], ".icon-rail-tab:active .icon-rail-icon")
      rest = one!(rules, [], ".icon-rail-tab:not(.icon-rail-tab--active) .icon-rail-icon")
      current = one!(rules, [], ".icon-rail-tab--active")
      bar = one!(rules, [], ".icon-rail-tab--active::before")

      assert decl(rest, "color") == "var(--color-subtle)"
      assert decl(hover, "color") == "var(--color-base-content)"
      assert decl(pressed_ink, "color") == "var(--color-base-content)"
      assert decl(pressed_icon, "transform") == "scale(0.92)"
      assert decl(bar, "width") == "3px"

      assert_distinct(
        rest: look(rest),
        hover: look(hover),
        pressed: MapSet.union(look(pressed_ink), look(pressed_icon)),
        current: MapSet.union(look(current), look(bar))
      )
    end

    test "the badge halo stays the tile's own paint", %{rules: rules} do
      tile = one!(rules, [], ".icon-rail-tab")
      assert decl(tile, "--icon-rail-badge-halo") == "var(--color-base-200)"
      current = one!(rules, [], ".icon-rail-tab--active")
      assert decl(current, "--icon-rail-badge-halo") == "var(--color-base-300)"

      # Any rule that fills a tile must move the halo with it.
      for r <- rules,
          r.selector =~ ~r/^\.icon-rail-tab[^ ]*$/,
          not String.contains?(r.selector, "::"),
          fill = decl(r.body, "background") || decl(r.body, "background-color") do
        assert decl(r.body, "--icon-rail-badge-halo") == fill, r.selector
      end
    end
  end

  describe "More sheet rows" do
    test "hover base-200, pressed base-300, current a bar with no fill", %{rules: rules} do
      hover = one!(rules, @hover, ".more-sheet-row:hover")
      pressed = one!(rules, [], ".more-sheet-row:active")
      current = one!(rules, [], ".more-sheet-row--current")
      bar = one!(rules, [], ".more-sheet-row--current::before")

      assert decl(hover, "background-color") == "var(--color-base-200)"
      assert decl(pressed, "background-color") == "var(--color-base-300)"
      assert decl(current, "background-color") == nil
      assert decl(current, "font-weight") == "600"
      assert decl(bar, "background") == "var(--color-base-content)"

      assert_distinct(
        hover: look(hover),
        pressed: look(pressed),
        current: MapSet.union(look(current), look(bar))
      )
    end
  end

  describe "menu items" do
    test "pressed is one step darker than the base-200 hover", %{rules: rules} do
      pressed = one!(rules, [], ~s([role="menu"] [role="menuitem"]:active))
      assert decl(pressed, "background-color") == "var(--color-base-300)"
    end
  end

  describe "reduced motion" do
    test "every press scale is removed, the ink stays", %{rules: rules} do
      scales =
        for r <- rules,
            r.at == [],
            r.selector =~ ":active" or r.selector =~ ".is-pressed",
            # The controls this contract covers; other components own theirs.
            r.selector =~ ~r/bottom-nav|icon-rail|more-sheet|menuitem/,
            t = decl(r.body, "transform"),
            t =~ "scale(",
            do: r.selector

      # Anti-vacuity: the tab's cell press and the rail's icon press are listed.
      assert ".bottom-nav-tab.is-pressed" in scales
      assert ".icon-rail-tab:active .icon-rail-icon" in scales

      for sel <- scales do
        assert decl(one!(rules, @reduced, sel), "transform") == "none", sel
      end

      for r <- rules, r.at == @reduced, r.selector =~ ":active" do
        assert decl(r.body, "color") == nil, "#{r.selector}: reduced motion keeps the ink"
      end
    end
  end

  describe "iOS :active" do
    test "app.js registers one passive document touchstart listener", %{app_js: js} do
      matches =
        Regex.scan(
          ~r/document\.addEventListener\(\s*"touchstart"\s*,\s*\(\)\s*=>\s*\{\s*\}\s*,\s*\{\s*passive:\s*true\s*\}\s*\)/,
          js
        )

      assert length(matches) == 1
    end
  end

  # Stage 2 (canvas 01a167b0 m2, rules 2, 3, 4, 7, 8): the optimistic tab.
  # assets/js/lib/nav_pending.js sets `data-nav-pending` on the tapped control
  # (and the More tab for a More row) and `data-nav-yielded` on the control
  # that was current; these rules are the whole visible contract.
  describe "optimistic navigation" do
    @pulse "nav-pending-pulse 900ms ease-in-out 150ms infinite"

    test "the tapped tab takes the current look and the previous current drops it",
         %{rules: rules} do
      current = one!(rules, [], ".bottom-nav-tab--active")
      pending = one!(rules, [], ".bottom-nav-tab[data-nav-pending]")
      yielded = one!(rules, [], ".bottom-nav-tab--active[data-nav-yielded]")
      rest = one!(rules, [], ".bottom-nav-tab")

      assert decl(pending, "color") == decl(current, "color")
      assert decl(yielded, "color") == decl(rest, "color")

      assert decl(
               one!(rules, [], ".bottom-nav-tab[data-nav-pending] .bottom-nav-label"),
               "font-weight"
             ) ==
               "500"

      assert decl(
               one!(rules, [], ".bottom-nav-tab--active[data-nav-yielded] .bottom-nav-label"),
               "font-weight"
             ) == "400"
    end

    test "the rail tile and its bar move to the tapped tile", %{rules: rules} do
      assert decl(one!(rules, [], ".icon-rail-tab[data-nav-pending]"), "background-color") ==
               "var(--color-base-300)"

      bar = one!(rules, [], ".icon-rail-tab[data-nav-pending]::before")
      assert decl(bar, "width") == "3px"
      assert decl(bar, "animation") == @pulse

      assert decl(one!(rules, [], ".icon-rail-tab--active[data-nav-yielded]"), "background-color") ==
               "var(--color-base-200)"

      assert decl(one!(rules, [], ".icon-rail-tab--active[data-nav-yielded]::before"), "content") ==
               "none"
    end

    test "the indicator pulses 1 -> 0.55 -> 1 over 900ms, only after 150ms",
         %{rules: rules, keyframes: kf} do
      assert decl(
               one!(rules, [], ".bottom-nav-tab[data-nav-pending] .bottom-nav-icon"),
               "animation"
             ) ==
               @pulse

      assert decl(one!(rules, [], ".chat-list-row[data-nav-pending]::before"), "animation") ==
               @pulse

      steps = Map.fetch!(kf, "nav-pending-pulse")
      assert Enum.any?(steps, &(&1.step =~ "50%" and decl(&1.body <> ";", "opacity") == "0.55"))
      assert Enum.any?(steps, &(&1.step =~ "100%" and decl(&1.body <> ";", "opacity") == "1"))
    end

    test "reduced motion: no pulse, a steady 60% after the same 150ms", %{
      rules: rules,
      keyframes: kf
    } do
      for sel <- [
            ".bottom-nav-tab[data-nav-pending] .bottom-nav-icon",
            ".icon-rail-tab[data-nav-pending]::before",
            ".chat-list-row[data-nav-pending]::before"
          ] do
        anim = decl(one!(rules, @reduced, sel), "animation")
        assert anim =~ "nav-pending-steady", sel
        assert anim =~ "150ms", sel
        refute anim =~ "infinite", sel
      end

      [step] = Map.fetch!(kf, "nav-pending-steady")
      assert decl(step.body <> ";", "opacity") == "0.6"
    end

    test "the More sheet leaves on the tap with the row still filled", %{rules: rules} do
      assert decl(one!(rules, [], ".more-sheet-row[data-nav-pending]"), "background-color") ==
               "var(--color-base-300)"

      panel = one!(rules, [], ".more-sheet:has([data-nav-pending]) .sheet-panel")
      assert decl(panel, "transform") == "translateY(100%)"
      assert decl(panel, "transition") =~ ~r/180ms .* 80ms$/
    end

    test "a chat row takes the 3px base-content current bar", %{rules: rules} do
      bar = one!(rules, [], ".chat-list-row[data-nav-pending]::before")
      assert decl(bar, "width") == "3px"
      assert decl(bar, "background") == "var(--color-base-content)"
    end

    test "the module sets the attributes the CSS keys on and app.js installs it",
         %{nav_pending_js: js, app_js: app} do
      assert js =~ ~s{setAttribute("data-nav-pending", "")}
      assert js =~ ~s{setAttribute("data-nav-yielded", "")}
      assert js =~ "export const NAV_PENDING_TIMEOUT_MS = 8000"
      assert app =~ ~r/^installNavPending\(/m
    end
  end
end
