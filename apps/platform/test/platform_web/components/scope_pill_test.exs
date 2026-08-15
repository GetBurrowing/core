defmodule PlatformWeb.Components.ScopePillTest do
  @moduledoc """
  Unit tests for the scope-provenance pill component.

  Covers all 6 scope atoms, the propagated variant, click-to-filter wiring,
  non-clickable read-only variant, and the active-filter visual state.

  Follows the precedent in `bottom_nav_test.exs`: assert against rendered DOM
  strings rather than driving a LiveView.
  """
  use ExUnit.Case, async: true
  import Phoenix.Component
  import Phoenix.LiveViewTest
  import PlatformWeb.Components.ScopePill

  defp render_pill(assigns) do
    assigns =
      Map.merge(
        %{
          scope: :fabrikam,
          propagated_to: nil,
          # nil = let the component pick the size-appropriate default (true at
          # :default size, false at :compact). Tests that care pass it explicitly.
          clickable: nil,
          active: false,
          size: :default
        },
        assigns
      )

    rendered_to_string(~H"""
    <.scope_pill
      scope={@scope}
      propagated_to={@propagated_to}
      clickable={@clickable}
      active={@active}
      size={@size}
    />
    """)
  end

  describe "scopes/0 enum" do
    test "returns the canonical 6-atom list in display order" do
      assert scopes() == [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon, :cyberdyne]
    end
  end

  describe "single-scope rendering — each scope renders the named utilities" do
    # The non-active label uses the AA-tuned `text-<scope>-label` token, NOT
    # the bare full-saturation `text-<scope>` (which is below WCAG 1.4.3 on
    # the 12% tint). Assert the FULL label token and refute the bare token so
    # the substring `text-<scope>` ⊂ `text-<scope>-label` can't false-pass.
    # The refute mirrors the active-state pattern at `bg-fabrikam` below.
    test "fabrikam renders with the fabrikam named utility classes" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "bg-fabrikam"
      assert html =~ "text-fabrikam-label"
      refute html =~ ~r{\btext-fabrikam(?![-a-z/])}
      assert html =~ "border-fabrikam"
      assert html =~ ">Fabrikam</span>"
    end

    test "soylent renders with the soylent named utility classes" do
      html = render_pill(%{scope: :soylent})
      assert html =~ "bg-soylent"
      assert html =~ "text-soylent-label"
      refute html =~ ~r{\btext-soylent(?![-a-z/])}
      assert html =~ "border-soylent"
      assert html =~ ">Soylent</span>"
    end

    test "wayne_tech renders with the wayne-tech named utility classes" do
      html = render_pill(%{scope: :wayne_tech})
      assert html =~ "bg-wayne-tech"
      assert html =~ "text-wayne-tech-label"
      refute html =~ ~r{\btext-wayne-tech(?![-a-z/])}
      assert html =~ "border-wayne-tech"
      assert html =~ ">Wayne-Tech</span>"
    end

    test "sxi renders with the sxi named utility classes" do
      html = render_pill(%{scope: :sxi})
      assert html =~ "bg-sxi"
      assert html =~ "text-sxi-label"
      refute html =~ ~r{\btext-sxi(?![-a-z/])}
      assert html =~ "border-sxi"
      assert html =~ ">SXI</span>"
    end

    test "paragon renders with the paragon named utility classes" do
      html = render_pill(%{scope: :paragon})
      assert html =~ "bg-paragon"
      assert html =~ "text-paragon-label"
      refute html =~ ~r{\btext-paragon(?![-a-z/])}
      assert html =~ "border-paragon"
      assert html =~ ">Paragon</span>"
    end

    # Cyberdyne (task 019ffe9d) is the sixth scope. Render-level coverage is
    # the only guard for the sources a cross-source key comparison cannot
    # reach: `slug/1` and `scope_label/1` are NON-TOTAL, so a missing clause
    # raises FunctionClauseError here rather than degrading silently.
    test "cyberdyne renders with the cyberdyne named utility classes" do
      html = render_pill(%{scope: :cyberdyne})
      assert html =~ "bg-cyberdyne"
      assert html =~ "text-cyberdyne-label"
      refute html =~ ~r{\btext-cyberdyne(?![-a-z/])}
      assert html =~ "border-cyberdyne"
      assert html =~ ">Cyberdyne</span>"
    end

    test "cyberdyne renders in the active variant" do
      html = render_pill(%{scope: :cyberdyne, active: true})
      assert html =~ "bg-cyberdyne-active"
      assert html =~ ">Cyberdyne</span>"
    end

    test "cyberdyne renders in the compact variant" do
      html = render_pill(%{scope: :cyberdyne, size: :compact})
      assert html =~ "bg-cyberdyne"
      assert html =~ "text-cyberdyne-label"
      assert html =~ "bg-cyberdyne-dot"
      assert html =~ ">Cyberdyne</span>"
    end

    test "renders without the arrow glyph" do
      html = render_pill(%{scope: :fabrikam})
      refute html =~ "hero-arrow-right"
    end

    test "renders a colored dot as a redundant signal beyond color (WCAG 1.4.1)" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "rounded-full"
      assert html =~ ~s(aria-hidden="true")
    end
  end

  describe "propagated variant" do
    test "renders both chips when propagated_to is set" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam})
      assert html =~ "Soylent"
      assert html =~ "Fabrikam"
    end

    test "renders the hero-arrow-right glyph joining the two chips" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam})
      assert html =~ "hero-arrow-right"
    end

    test "wraps the pair in a propagated container span" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam})
      assert html =~ "scope-pill-propagated"
    end
  end

  describe "click-to-filter wiring (clickable: true, the default)" do
    test "renders as a <button> not a <span>" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "<button"
      assert html =~ ~s(type="button")
    end

    test "fires phx-click=\"scope_filter\" with phx-value-scope" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ ~s(phx-click="scope_filter")
      assert html =~ ~s(phx-value-scope="fabrikam")
    end

    test "includes phx-value-propagated-to when propagated" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam})
      assert html =~ ~s(phx-value-propagated-to="fabrikam")
    end

    test "renders aria-label \"Filter by {scope-name} scope\"" do
      html = render_pill(%{scope: :wayne_tech})
      assert html =~ ~s(aria-label="Filter by Wayne-Tech scope")
    end

    test "applies the project's standard focus-visible-ring class" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "focus-visible-ring"
    end

    test "has hover styling on the default (non-active) state" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "hover:bg-fabrikam/22"
    end
  end

  describe "non-clickable variant (clickable: false)" do
    test "renders as a <span>, not a <button>" do
      html = render_pill(%{scope: :sxi, clickable: false})
      refute html =~ "<button"
      assert html =~ "<span"
    end

    test "has no phx-click attribute" do
      html = render_pill(%{scope: :sxi, clickable: false})
      refute html =~ "phx-click"
    end

    test "applies 0.55 opacity for visual non-interactive distinction" do
      html = render_pill(%{scope: :sxi, clickable: false})
      assert html =~ "opacity-55"
    end

    test "still has an aria-label for screen readers (color is not the only signal)" do
      html = render_pill(%{scope: :sxi, clickable: false})
      assert html =~ ~s(aria-label="SXI scope")
    end
  end

  describe "active-filter state styling (active: true)" do
    test "renders the hero-check icon instead of the colored dot" do
      html = render_pill(%{scope: :fabrikam, active: true})
      assert html =~ "hero-check"
    end

    test "applies the full-saturation background via bg-<scope>-active" do
      html = render_pill(%{scope: :fabrikam, active: true})
      # Active state uses the named utility that bakes in full-saturation
      # bg + contrast-safe text + outer-ring shadow.
      assert html =~ "bg-fabrikam-active"
      # Default-state bg utility must NOT appear on the active pill —
      # the only `bg-fabrikam` substring on the active pill should be the
      # active variant itself.
      refute html =~ ~r{\bbg-fabrikam(?![-a-z/])}
    end

    test "active utility carries the soft outer ring via box-shadow" do
      # The shadow ring is baked into the `bg-<scope>-active` CSS rule in
      # app.css; the rendered HTML only needs the class to be present.
      html = render_pill(%{scope: :fabrikam, active: true})
      assert html =~ "bg-fabrikam-active"
    end

    test "aria-label flips to \"Currently filtered by {scope-name} scope\"" do
      html = render_pill(%{scope: :soylent, active: true})
      assert html =~ ~s(aria-label="Currently filtered by Soylent scope")
    end

    test "aria-pressed=\"true\" on the active button" do
      html = render_pill(%{scope: :soylent, active: true})
      assert html =~ ~s(aria-pressed="true")
    end

    test "aria-pressed=\"false\" on the inactive button" do
      html = render_pill(%{scope: :soylent, active: false})
      assert html =~ ~s(aria-pressed="false")
    end

    test "does not apply hover style when active (active state is terminal)" do
      html = render_pill(%{scope: :fabrikam, active: true})
      refute html =~ "hover:bg-fabrikam/22"
    end

    test "yellow-content scope (paragon) uses bg-paragon-active for dark-text contrast" do
      html = render_pill(%{scope: :paragon, active: true})
      # Active paragon pill should use bg-paragon-active, whose CSS rule
      # bakes in the dark-text contrast token (oklch(15% 0 0)) over the
      # yellow fill. The rendered HTML only carries the class.
      assert html =~ "bg-paragon-active"
    end
  end

  describe "compact size variant" do
    test "applies the compact chrome (tighter padding, smaller dot, truncation)" do
      html = render_pill(%{scope: :fabrikam, size: :compact})
      assert html =~ "px-1.5"
      assert html =~ "py-px"
      assert html =~ "size-1.5"
      assert html =~ "truncate max-w-20"
    end

    test "drops the border at compact size (a ring reads as noise in a list)" do
      html = render_pill(%{scope: :fabrikam, size: :compact})
      refute html =~ "border-fabrikam"
      refute html =~ "rounded-full border"
    end

    test "keeps text-xs (12px) — density comes from chrome, not type size" do
      html = render_pill(%{scope: :fabrikam, size: :compact})
      assert html =~ "text-xs"
    end

    test "default size is unchanged (bordered, px-2, size-2 dot)" do
      html = render_pill(%{scope: :fabrikam, size: :default})
      assert html =~ "rounded-full border"
      assert html =~ "px-2"
      assert html =~ "size-2"
      refute html =~ "px-1.5"
    end

    test "is non-clickable by default (a ~16px tap target fails WCAG 2.5.8)" do
      html = render_pill(%{scope: :fabrikam, size: :compact})
      refute html =~ "<button"
      assert html =~ "<span"
      refute html =~ "phx-click"
    end

    test "non-clickable compact floors opacity at 0.70 (not 0.55)" do
      html = render_pill(%{scope: :fabrikam, size: :compact})
      assert html =~ "opacity-70"
      refute html =~ "opacity-55"
    end

    test "explicit clickable={true} opts back into a button with an expanded hit area" do
      html = render_pill(%{scope: :fabrikam, size: :compact, clickable: true})
      assert html =~ "<button"
      assert html =~ ~s(phx-click="scope_filter")
      assert html =~ "scope-pill-hit-expand"
    end

    test "active compact keeps the dot + full-saturation fill, no check icon" do
      html = render_pill(%{scope: :fabrikam, size: :compact, active: true})
      refute html =~ "hero-check"
      assert html =~ "bg-fabrikam-active"
      assert html =~ "size-1.5"
    end

    test "propagated collapses to the source chip only at compact size" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam, size: :compact})
      refute html =~ "hero-arrow-right"
      refute html =~ "scope-pill-propagated"
      assert html =~ ">Soylent</span>"
      refute html =~ ">Fabrikam</span>"
    end

    test "compact propagated preserves full provenance in aria-label and title" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam, size: :compact})
      assert html =~ ~s(aria-label="Soylent scope, propagated to Fabrikam")
      assert html =~ ~s(title="Soylent → Fabrikam")
    end

    test "propagated at default size still renders both chips + arrow (regression)" do
      html = render_pill(%{scope: :soylent, propagated_to: :fabrikam, size: :default})
      assert html =~ "hero-arrow-right"
      assert html =~ "scope-pill-propagated"
      assert html =~ ">Soylent</span>"
      assert html =~ ">Fabrikam</span>"
    end
  end
end
