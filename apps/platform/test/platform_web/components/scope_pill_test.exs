defmodule PlatformWeb.Components.ScopePillTest do
  @moduledoc """
  Unit tests for the scope-provenance pill component.

  Covers all 5 scope atoms, the propagated variant, click-to-filter wiring,
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
          clickable: true,
          active: false
        },
        assigns
      )

    rendered_to_string(~H"""
    <.scope_pill
      scope={@scope}
      propagated_to={@propagated_to}
      clickable={@clickable}
      active={@active}
    />
    """)
  end

  describe "scopes/0 enum" do
    test "returns the canonical 5-atom list in display order" do
      assert scopes() == [:fabrikam, :soylent, :wayne_tech, :sxi, :paragon]
    end
  end

  describe "single-scope rendering — each scope renders correct color tokens" do
    test "fabrikam renders with the fabrikam oklch values" do
      html = render_pill(%{scope: :fabrikam})
      assert html =~ "oklch(72%_0.16_50/12%)"
      assert html =~ ">Fabrikam</span>"
    end

    test "soylent renders with the soylent oklch values" do
      html = render_pill(%{scope: :soylent})
      assert html =~ "oklch(65%_0.20_295/12%)"
      assert html =~ ">Soylent</span>"
    end

    test "wayne_tech renders with the wayne_tech oklch values" do
      html = render_pill(%{scope: :wayne_tech})
      assert html =~ "oklch(68%_0.15_240/12%)"
      assert html =~ ">Wayne-Tech</span>"
    end

    test "sxi renders with the sxi oklch values" do
      html = render_pill(%{scope: :sxi})
      assert html =~ "oklch(70%_0.15_162/12%)"
      assert html =~ ">SXI</span>"
    end

    test "paragon renders with the paragon oklch values" do
      html = render_pill(%{scope: :paragon})
      assert html =~ "oklch(80%_0.16_95/12%)"
      assert html =~ ">Paragon</span>"
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
      assert html =~ "hover:bg-[oklch(72%_0.16_50/22%)]"
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

    test "applies the full-saturation background (not 12% color-mix)" do
      html = render_pill(%{scope: :fabrikam, active: true})
      # Active = full-saturation bg, no `/12%` modifier on the bg utility.
      assert html =~ "bg-[oklch(72%_0.16_50)]"
      refute html =~ "bg-[oklch(72%_0.16_50/12%)]"
    end

    test "applies the soft outer ring via box-shadow utility" do
      html = render_pill(%{scope: :fabrikam, active: true})
      assert html =~ "shadow-[0_0_0_2px_oklch(72%_0.16_50/30%)]"
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
      refute html =~ "hover:bg-[oklch(72%_0.16_50/22%)]"
    end

    test "yellow-content scope (paragon) uses dark text for contrast on yellow fill" do
      html = render_pill(%{scope: :paragon, active: true})
      # Active paragon pill should use dark text (oklch(15%...)) on the yellow bg.
      assert html =~ "text-[oklch(15%_0_0)]"
    end
  end
end
