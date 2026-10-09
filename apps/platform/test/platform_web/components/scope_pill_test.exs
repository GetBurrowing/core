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
          scope: :acme,
          propagated_to: nil,
          # nil = let the component pick the size-appropriate default (true at
          # :default size, false at :compact). Tests that care pass it explicitly.
          clickable: nil,
          active: false,
          size: :default,
          # The `phx-value-scope` / `data-scope` PAYLOAD, separable from
          # `:scope` since task 01a00cf1 so a masked rail can emit a
          # per-session placeholder. nil = "caller didn't say", which is
          # every test but the masking one.
          value: nil,
          # Overrides the visible text AND the aria-label together. nil =
          # "caller didn't say"; a caller writing `@mask_names? && …` (the
          # chat surfaces did until task 01a0938b) passes `false`, which is a
          # real value here and is not the same as nil.
          label: nil
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
      value={@value}
      label={@label}
    />
    """)
  end

  # The same render with the `surface` attr DECLARED (task 01a09333-d374
  # stage 3). `render_pill/1` above leaves it out, which is how every call
  # site looked before this stage, so the pair lets a test compare "never
  # heard of surfaces" against each declared value.
  defp render_pill_on(surface, assigns) do
    assigns =
      Map.merge(
        %{
          scope: :acme,
          propagated_to: nil,
          clickable: nil,
          active: false,
          size: :default,
          value: nil,
          label: nil,
          surface: surface
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
      value={@value}
      label={@label}
      surface={@surface}
    />
    """)
  end

  # Every `class` attribute in the render, in document order.
  defp class_lists(html) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("[class]")
    |> Enum.map(fn node -> node |> LazyHTML.attribute("class") |> hd() end)
  end

  # The chip's own class tokens: the first element carrying `text-xs`
  # (the propagated wrapper, the dot and the label span do not).
  defp chip_classes(html) do
    html
    |> class_lists()
    |> Enum.map(&String.split/1)
    |> Enum.find(&("text-xs" in &1))
    |> MapSet.new()
  end

  describe "scopes/0 enum" do
    test "returns the canonical 5-atom list in display order" do
      # The root org has no compiled atom since task 01a116de stage 3: it is
      # install data and is passed by its slug string.
      assert scopes() == [:soylent, :wayne_tech, :sxi, :paragon, :cyberdyne]
    end
  end

  describe "single-scope rendering: each shipped scope renders through the var path (task 01a09333-d374 stage 5)" do
    # Until stage 5 the six shipped scopes wore hand-authored `bg-<slug>` /
    # `text-<slug>-label` / `border-<slug>` utilities. They now take the same
    # slug-agnostic classes as every other org, and their colour arrives in
    # the custom properties `ScopeColorStyles` emits from the org row.
    # Refute the retired class names so a half-done move cannot pass.
    @retired ~w(bg-SLUG text-SLUG-label border-SLUG bg-SLUG-dot bg-SLUG-active hover:bg-SLUG/22)

    for {scope, fragment, label} <- [
          {:soylent, "soylent", "Soylent"},
          {:wayne_tech, "wayne-tech", "Wayne-Tech"},
          {:sxi, "sxi", "SXI"},
          {:paragon, "paragon", "Paragon"},
          {:cyberdyne, "cyberdyne", "Cyberdyne"}
        ] do
      @tag scope: scope, fragment: fragment, label: label
      test "#{scope} renders the var-path utilities and none of its retired classes", %{
        scope: scope,
        fragment: fragment,
        label: label
      } do
        html = render_pill(%{scope: scope})
        tokens = chip_classes(html)

        assert "scope-tint" in tokens
        assert "scope-text" in tokens
        assert "scope-edge" in tokens
        assert "scope-edge-hover" in tokens
        assert html =~ "scope-dot"
        assert html =~ ">#{label}</span>"

        for retired <- @retired do
          refute html =~ String.replace(retired, "SLUG", fragment),
                 "#{scope} still carries #{String.replace(retired, "SLUG", fragment)}"
        end
      end
    end

    test "cyberdyne renders in the active variant" do
      html = render_pill(%{scope: :cyberdyne, active: true})
      assert "scope-active" in chip_classes(html)
      assert html =~ ">Cyberdyne</span>"
    end

    test "cyberdyne renders in the compact variant" do
      html = render_pill(%{scope: :cyberdyne, size: :compact})
      tokens = chip_classes(html)
      assert "scope-tint" in tokens
      assert "scope-text" in tokens
      assert "scope-edge-inset" in tokens
      assert html =~ "scope-dot"
      assert html =~ ">Cyberdyne</span>"
    end

    test "renders without the arrow glyph" do
      html = render_pill(%{scope: :acme})
      refute html =~ "hero-arrow-right"
    end

    test "renders a colored dot as a redundant signal beyond color (WCAG 1.4.1)" do
      html = render_pill(%{scope: :acme})
      assert html =~ "rounded-full"
      assert html =~ ~s(aria-hidden="true")
    end
  end

  describe "the runtime var path — a slug with no hand-authored CSS (task 01a09287 stage 5)" do
    # THE defect this stage fixes. Stage 3 shipped a server-rendered
    # `<style id="org-scope-colors">` block emitting
    # `[data-scope="<slug>"]{--scope-fill:…;--scope-label:…}` for every org,
    # and app.css shipped slug-agnostic `.scope-*` rules that read those
    # properties. Neither was wired to anything: a live probe of /tasks found
    # `document.querySelectorAll('[data-scope]').length === 0`, so a new org
    # fell through to inherited grey while the machinery to colour it sat
    # complete and inert one layer away.
    #
    # A CSS rebuild cannot fix that — the per-slug blocks are hand-authored
    # and there is no generator for an arbitrary slug, which is precisely
    # what app.css says the runtime vars were introduced to solve.

    test "a new org's chip carries data-scope, so the emitted rules can match it" do
      html = render_pill(%{scope: "hueless_co"})

      assert html =~ ~s(data-scope="hueless_co")
    end

    test "a new org takes the slug-agnostic utilities and NO build-time class" do
      html = render_pill(%{scope: "hueless_co"})

      assert html =~ "scope-tint"
      assert html =~ "scope-text"
      assert "scope-edge" in chip_classes(html)
      assert html =~ "scope-dot"
      # The 30% color-mix border class is retired (task 01a09333-d374
      # stage 4): it measured 1.17-1.41:1 against the ground.
      refute html =~ "scope-border"

      # The build-time classes would not exist in the compiled stylesheet for
      # this slug, so emitting them is what produced the grey chip.
      refute html =~ "bg-hueless-co"
      refute html =~ "text-hueless-co-label"
      refute html =~ "border-hueless-co"
    end

    test "the new org's active state reaches the var path, and it has NO hover fill" do
      active = render_pill(%{scope: "hueless_co", active: true})
      assert active =~ "scope-active"
      refute active =~ "bg-hueless-co-active"

      # Task 01a09333-d374 stage 3 retired `.scope-tint-hover`, a 22% alpha
      # tint of the fill: the largest tint alpha that keeps all twelve
      # shipped cells at or above AA is 0.130. Stage 4 moved hover onto the
      # edge, so the only hover class is the edge one, and no Tailwind
      # `hover:` variant (media-gated, dead on touch) appears at all.
      resting = render_pill(%{scope: "hueless_co", clickable: true})
      tokens = chip_classes(resting)
      refute "scope-tint-hover" in tokens
      assert Enum.filter(tokens, &String.contains?(&1, "hover")) == ["scope-edge-hover"]
      refute Enum.any?(tokens, &String.starts_with?(&1, "hover:")), inspect(tokens)
      refute resting =~ "hover:bg-hueless-co/22"
    end

    test "compact has no border on the var path; its edge is an inset box-shadow instead" do
      tokens = chip_classes(render_pill(%{scope: "hueless_co", size: :compact}))

      assert "scope-tint" in tokens
      assert "scope-text" in tokens
      assert "scope-edge-inset" in tokens
      refute "border" in tokens
      refute "scope-edge" in tokens
    end

    test "the six shipped orgs take the same classes as a new org (task 01a09333-d374 stage 5)" do
      # This test used to read "the six shipped orgs are NOT moved onto the
      # var path". Marlowe ruled on 2026-09-13 that they move; the byte gate in
      # `ScopeColorStylesShippedSixTest` is what makes that safe. Here: the
      # six render byte-identical class lists to an org with no history at
      # all, so no slug-specific branch survives in the component.
      new_org = class_lists(render_pill(%{scope: "hueless_co"}))

      for scope <- scopes() do
        assert class_lists(render_pill(%{scope: scope})) == new_org, "#{scope}"
      end
    end

    test "the shipped six still carry data-scope, so the probe is not slug-specific" do
      # data-scope is emitted for EVERY chip. Since stage 5 it is also the
      # ONLY thing that colours the six: their rules are keyed on it.
      assert render_pill(%{scope: :acme}) =~ ~s(data-scope="acme")
      assert render_pill(%{scope: :wayne_tech}) =~ ~s(data-scope="wayne_tech")
    end

    test "data-scope is the STORED slug, not the kebab-cased class fragment" do
      # `:wayne_tech` is the class fragment `wayne-tech` and the org row
      # `wayne_tech`. `ScopeColorStyles` keys its rules on `orgs.slug`, so
      # emitting the class fragment here would produce a `data-scope` that
      # matches no emitted rule — a silent miss, on the one org whose two
      # spellings differ.
      html = render_pill(%{scope: :wayne_tech})

      assert html =~ ~s(data-scope="wayne_tech")
      refute html =~ ~s(data-scope="wayne-tech")
    end

    test "a chip whose LABEL is overridden with no value emits NO data-scope" do
      # The leak `ChatLiveMaskMobileTest` caught on the first cut of this
      # work, reproduced here at the component so it is legible as a
      # component contract rather than as two chat-surface failures.
      #
      # The chat header and the hidden-channels drawer mask by overriding the
      # visible label and handing over the REAL scope (the atom or runtime
      # slug `ChatLive.org_scope/1` resolves from the org row, task 01a0938b)
      # and no `value`. Falling back to `@scope` there wrote `data-scope="wayne_tech"` into a masked session: the underscore
      # spelling, which `refute html =~ "Wayne-Tech"` does not catch, in an
      # attribute, which renders as no text at all and is perfectly legible
      # in a DOM inspector.
      html = render_pill(%{scope: :wayne_tech, label: "Workspace B", clickable: false})

      assert html =~ ">Workspace B</span>"
      refute html =~ "data-scope="

      # The UNDERSCORE spelling is the one that leaked. Since stage 5 the
      # hyphen spelling is gone too: the per-slug class names that spelled it
      # (`bg-wayne-tech`) were retired with the move, so no spelling of the
      # real org survives anywhere in a masked chip, class included.
      #
      # The cost, stated: a masked chip carries no `data-scope`, so none of
      # the emitted rules matches it and it renders uncoloured. Before stage
      # 5 the six kept their colour under masking through those class names.
      refute html =~ "wayne_tech"
      refute html =~ "wayne-tech"
      refute html =~ ">Wayne-Tech</span>"
      refute html =~ ~s(aria-label="Wayne-Tech scope")
    end

    test "a label override does NOT suppress data-scope when masking is off" do
      # The other half, and the reason the guard is `is_binary/1` rather than
      # a nil check. A call site writing `label={@mask_names? && …}` (the
      # chat surfaces did until task 01a0938b) passes the atom `false` when
      # masking is off — if `false` suppressed the attribute, every such
      # unmasked pill would lose its colour and the test above would still
      # pass.
      html = render_pill(%{scope: :wayne_tech, label: false, clickable: false})

      assert html =~ ~s(data-scope="wayne_tech")
    end

    test "an explicit value beats a label override — the tasks rail keeps its colour" do
      # The tasks rail masks by passing BOTH, and must keep emitting the
      # placeholder rather than nothing: `value` is the payload that is safe
      # to spell, so there is no reason to suppress it. Without this the
      # suppression above would silently take the tasks rail's colour with it.
      html = render_pill(%{scope: "soylent", label: "Workspace B", value: "workspace-b"})

      assert html =~ ~s(data-scope="workspace-b")
      assert html =~ ~s(phx-value-scope="workspace-b")
      assert html =~ ">Workspace B</span>"

      # Since stage 5 the six carry no per-slug class name, so the real slug
      # is absent from the whole chip, not only from the two attributes.
      refute html =~ ~s(data-scope="soylent")
      refute html =~ ">Soylent</span>"
      refute html =~ "soylent"
    end

    test "a masked chip emits the PLACEHOLDER slug in data-scope, not the real one" do
      # `data-scope` is fed `@value || @scope`, the same expression as
      # `phx-value-scope`, because it is the same leak class: an attribute
      # value survives `refute html =~ "Soylent"` untouched and is legible
      # in the DOM inspector a screen share is likely to have open.
      #
      # The cost is real and is the right trade: a `[data-scope="soylent"]`
      # rule then matches no element, so a masked chip loses its colour. That
      # is the concession `rail_mask_surfaces_test.exs` already documents for
      # the style block itself.
      html = render_pill(%{scope: "soylent", value: "workspace-b"})

      assert html =~ ~s(data-scope="workspace-b")
      refute html =~ ~s(data-scope="soylent")
    end
  end

  describe "propagated variant" do
    test "renders both chips when propagated_to is set" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme})
      assert html =~ "Soylent"
      assert html =~ "Acme"
    end

    test "renders the hero-arrow-right glyph joining the two chips" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme})
      assert html =~ "hero-arrow-right"
    end

    test "wraps the pair in a propagated container span" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme})
      assert html =~ "scope-pill-propagated"
    end
  end

  describe "click-to-filter wiring (clickable: true, the default)" do
    test "renders as a <button> not a <span>" do
      html = render_pill(%{scope: :acme})
      assert html =~ "<button"
      assert html =~ ~s(type="button")
    end

    test "fires phx-click=\"scope_filter\" with phx-value-scope" do
      html = render_pill(%{scope: :acme})
      assert html =~ ~s(phx-click="scope_filter")
      assert html =~ ~s(phx-value-scope="acme")
    end

    test "includes phx-value-propagated-to when propagated" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme})
      assert html =~ ~s(phx-value-propagated-to="acme")
    end

    test "renders aria-label \"Filter by {scope-name} scope\"" do
      html = render_pill(%{scope: :wayne_tech})
      assert html =~ ~s(aria-label="Filter by Wayne-Tech scope")
    end

    test "applies the project's standard focus-visible-ring class" do
      html = render_pill(%{scope: :acme})
      assert html =~ "focus-visible-ring"
    end

    test "has hover styling on the default (non-active) state" do
      # Hover is on the edge since stage 4, and the six take it since stage 5.
      assert "scope-edge-hover" in chip_classes(render_pill(%{scope: :acme}))
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
      html = render_pill(%{scope: :acme, active: true})
      assert html =~ "hero-check"
    end

    test "applies the full-saturation background via scope-active" do
      # `.scope-active` paints `--scope-fill` with `--scope-active-content`
      # text and the soft outer ring; the resting tint must not appear.
      tokens = chip_classes(render_pill(%{scope: :acme, active: true}))
      assert "scope-active" in tokens
      refute Enum.any?(tokens, &String.starts_with?(&1, "scope-tint"))
      refute "bg-fabrikam-active" in tokens
    end

    test "active utility carries the soft outer ring via box-shadow" do
      css = File.read!("assets/css/app.css")
      assert css =~ ~r/\.scope-active \{[^}]*box-shadow: 0 0 0 2px/
      assert "scope-active" in chip_classes(render_pill(%{scope: :acme, active: true}))
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
      tokens = chip_classes(render_pill(%{scope: :acme, active: true}))
      refute Enum.any?(tokens, &String.contains?(&1, "hover")), inspect(tokens)
    end

    test "yellow-content scope (paragon) takes scope-active; its dark text is emitted per org" do
      # The text colour on the active pill is `--scope-active-content`, chosen
      # by measured contrast in `ScopeColorStyles` and pinned for the six in
      # `ScopeColorStylesShippedSixTest`. The rendered HTML carries the class.
      assert "scope-active" in chip_classes(render_pill(%{scope: :paragon, active: true}))
    end
  end

  describe "compact size variant" do
    test "applies the compact chrome (tighter padding, smaller dot, truncation)" do
      html = render_pill(%{scope: :acme, size: :compact})
      assert html =~ "px-1.5"
      assert html =~ "py-px"
      assert html =~ "size-1.5"
      assert html =~ "truncate max-w-20"
    end

    test "drops the border at compact size (a ring reads as noise in a list)" do
      html = render_pill(%{scope: :acme, size: :compact})
      refute "border" in chip_classes(html)
      refute html =~ "rounded-full border"
    end

    test "keeps text-xs (12px) — density comes from chrome, not type size" do
      html = render_pill(%{scope: :acme, size: :compact})
      assert html =~ "text-xs"
    end

    test "default size is unchanged (bordered, px-2, size-2 dot)" do
      html = render_pill(%{scope: :acme, size: :default})
      assert html =~ "rounded-full border"
      assert html =~ "px-2"
      assert html =~ "size-2"
      refute html =~ "px-1.5"
    end

    test "is non-clickable by default (a ~16px tap target fails WCAG 2.5.8)" do
      html = render_pill(%{scope: :acme, size: :compact})
      refute html =~ "<button"
      assert html =~ "<span"
      refute html =~ "phx-click"
    end

    test "non-clickable compact floors opacity at 0.70 (not 0.55)" do
      html = render_pill(%{scope: :acme, size: :compact})
      assert html =~ "opacity-70"
      refute html =~ "opacity-55"
    end

    test "explicit clickable={true} opts back into a button with an expanded hit area" do
      html = render_pill(%{scope: :acme, size: :compact, clickable: true})
      assert html =~ "<button"
      assert html =~ ~s(phx-click="scope_filter")
      assert html =~ "scope-pill-hit-expand"
    end

    test "active compact keeps the dot + full-saturation fill, no check icon" do
      html = render_pill(%{scope: :acme, size: :compact, active: true})
      refute html =~ "hero-check"
      assert "scope-active" in chip_classes(html)
      assert html =~ "size-1.5"
    end

    test "propagated collapses to the source chip only at compact size" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme, size: :compact})
      refute html =~ "hero-arrow-right"
      refute html =~ "scope-pill-propagated"
      assert html =~ ">Soylent</span>"
      refute html =~ ">Acme</span>"
    end

    test "compact propagated preserves full provenance in aria-label and title" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme, size: :compact})
      assert html =~ ~s(aria-label="Soylent scope, propagated to Acme")
      assert html =~ ~s(title="Soylent → Acme")
    end

    test "propagated at default size still renders both chips + arrow (regression)" do
      html = render_pill(%{scope: :soylent, propagated_to: :acme, size: :default})
      assert html =~ "hero-arrow-right"
      assert html =~ "scope-pill-propagated"
      assert html =~ ">Soylent</span>"
      assert html =~ ">Acme</span>"
    end
  end

  describe "surface: the call site declares which per-surface pair a var-path chip wears (task 01a09333-d374 stage 3)" do
    test "undeclared renders the base-100 pair, byte-identical to an explicit :base_100" do
      for size <- [:default, :compact], clickable <- [true, false] do
        assigns = %{scope: "acme", size: size, clickable: clickable}
        undeclared = render_pill(assigns)

        assert render_pill_on(:base_100, assigns) == undeclared

        tokens = chip_classes(undeclared)
        assert "scope-tint" in tokens
        assert "scope-text" in tokens
        refute "scope-tint-200" in tokens
        refute "scope-text-200" in tokens
      end
    end

    test ":base_200 wears the -200 pair and NOT the base-100 one" do
      tokens = chip_classes(render_pill_on(:base_200, %{scope: "acme"}))

      assert "scope-tint-200" in tokens
      assert "scope-text-200" in tokens
      assert "scope-edge-200" in tokens
      assert "scope-edge-hover-200" in tokens
      refute "scope-tint" in tokens
      refute "scope-text" in tokens
      refute "scope-edge" in tokens
    end

    test ":base_200 at compact size keeps the -200 pair, no border, and the -200 inset edge" do
      tokens = chip_classes(render_pill_on(:base_200, %{scope: "acme", size: :compact}))

      assert "scope-tint-200" in tokens
      assert "scope-text-200" in tokens
      assert "scope-edge-inset-200" in tokens
      refute "border" in tokens
      refute "scope-tint" in tokens
      refute "scope-edge-inset" in tokens
    end

    test "the surface swaps exactly the tint, label and edge classes and nothing else" do
      # Mapping the -200 spellings back onto the base-100 names must
      # reproduce the base-100 render byte for byte, across every chrome
      # variant. If the surface reached anything else (the border width,
      # the dot, an attribute), this reds. Stage 4 added the edge and hover
      # edge classes to the per-surface set.
      surfaced = ~r/\b(scope-(?:tint|text|edge|edge-hover|edge-inset|edge-inset-hover))-200\b/

      for size <- [:default, :compact], clickable <- [true, false], active <- [false, true] do
        assigns = %{scope: "acme", size: size, clickable: clickable, active: active}
        on_200 = render_pill_on(:base_200, assigns)

        mapped = Regex.replace(surfaced, on_200, "\\1")

        assert mapped == render_pill_on(:base_100, assigns),
               "size=#{size} clickable=#{clickable} active=#{active}"
      end
    end

    test "the active pill is the full fill on every surface, so the surface does not reach it" do
      for size <- [:default, :compact] do
        on_100 = render_pill_on(:base_100, %{scope: "acme", active: true, size: size})

        assert render_pill_on(:base_200, %{scope: "acme", active: true, size: size}) == on_100

        tokens = chip_classes(on_100)
        assert "scope-active" in tokens
        refute Enum.any?(tokens, &String.starts_with?(&1, "scope-tint"))
      end
    end

    test "a propagated pair takes the surface on both chips, the shipped target included" do
      # Until stage 5 the `:acme` target stayed on its legacy classes and
      # ignored the surface. It now wears the -200 pair like the source.
      html = render_pill_on(:base_200, %{scope: "acme", propagated_to: :acme})

      chips =
        html
        |> class_lists()
        |> Enum.map(&String.split/1)
        |> Enum.filter(&("text-xs" in &1))

      assert [source, target] = chips

      for chip <- [source, target] do
        assert "scope-tint-200" in chip
        assert "scope-text-200" in chip
        assert "scope-edge-200" in chip
      end

      refute "bg-fabrikam" in target
    end
  end

  describe "the six shipped orgs on the var path (task 01a09333-d374 stage 5)" do
    # Replaces stage 3's "the six legacy slugs do not move" describe and its
    # class fixture rendered at 2fa8c8fb, which pinned the opposite rule and
    # was deleted with the move.

    test "the legacy branch is gone from the component, not just unused" do
      source = File.read!("lib/platform_web/components/scope_pill.ex")

      refute source =~ "@legacy_css_slugs"
      refute source =~ "legacy_css?"
    end

    test "every shipped scope, as an atom or as its stored slug, on every surface and variant, is var-path only" do
      for scope <- scopes(),
          spelling <- [scope, Atom.to_string(scope)],
          surface <- [:base_100, :base_200],
          size <- [:default, :compact],
          active <- [false, true],
          clickable <- [true, false] do
        assigns = %{scope: spelling, size: size, active: active, clickable: clickable}
        html = render_pill_on(surface, assigns)
        at = "#{inspect(spelling)} #{surface} #{size} active=#{active} clickable=#{clickable}"

        # Every colour class on the chip is a var-path one.
        colour_tokens =
          html
          |> chip_classes()
          |> Enum.filter(&String.match?(&1, ~r/^(hover:)?(bg|text|border)-[a-z]/))
          |> Enum.reject(&(&1 in ~w(text-xs text-base-content/60)))

        assert colour_tokens == [], "#{at}: #{inspect(colour_tokens)}"

        expected =
          cond do
            active -> "scope-active"
            surface == :base_100 -> "scope-tint"
            true -> "scope-tint-200"
          end

        assert expected in chip_classes(html), at

        # And the two spellings are indistinguishable to the stylesheet.
        assert class_lists(render_pill_on(surface, Map.put(assigns, :scope, scope))) ==
                 class_lists(
                   render_pill_on(surface, Map.put(assigns, :scope, Atom.to_string(scope)))
                 ),
               at
      end
    end
  end

  describe "app.css: nothing composites a var-path chip's background (task 01a09333-d374 stage 3)" do
    # Asked the way the browser asks it: which rules in app.css apply to the
    # RENDERED chip, and does any of them paint its background with a
    # `color-mix`? `CssRules.matches?/2` resolves `:hover` and other
    # pseudo-classes TOWARDS matching, so a hover fill on any class the chip
    # carries is inside this net too.
    alias Platform.Design.CssRules

    @css_path "assets/css/app.css"

    # `setup`, not `setup_all`: ExUnit refuses `setup_all` inside a
    # describe. Parsing app.css per test costs milliseconds.
    setup do
      %{rules: @css_path |> File.read!() |> CssRules.rules()}
    end

    test "the retired 22% hover rule is gone from the stylesheet", %{rules: rules} do
      refute Enum.any?(rules, &(&1.selector =~ "scope-tint-hover"))
    end

    for surface <- [:base_100, :base_200],
        size <- [:default, :compact],
        clickable <- [true, false] do
      @tag surface: surface, size: size, clickable: clickable
      test "#{surface}, #{size}, clickable=#{clickable}: opaque tint, matching label", %{
        rules: rules,
        surface: surface,
        size: size,
        clickable: clickable
      } do
        {tint_class, tint_var, text_class, label_var} =
          case surface do
            :base_100 ->
              {".scope-tint", "--scope-tint-100", ".scope-text", "--scope-label-100"}

            :base_200 ->
              {".scope-tint-200", "--scope-tint-200", ".scope-text-200", "--scope-label-200"}
          end

        html = render_pill_on(surface, %{scope: "acme", size: size, clickable: clickable})
        matched = Enum.filter(rules, &CssRules.matches?(&1.selector, chip_element(html)))

        backgrounds =
          Enum.filter(
            matched,
            &(CssRules.declares?(&1.body, "background-color") or
                CssRules.declares?(&1.body, "background"))
          )

        # Anti-vacuity: the tint rule itself must be matched, or an empty
        # set would pass the refute below for a broken matcher.
        tint_rule = Enum.find(backgrounds, &(&1.selector == tint_class))

        assert tint_rule,
               "#{tint_class} does not match the rendered chip; matched " <>
                 inspect(Enum.map(matched, & &1.selector))

        assert tint_rule.body =~ "var(#{tint_var})"

        for rule <- backgrounds do
          refute rule.body =~ "color-mix",
                 "#{rule.selector} composites the chip's background: #{rule.body}"
        end

        text_rule = Enum.find(matched, &(&1.selector == text_class))
        assert text_rule, "#{text_class} does not match the rendered chip"
        assert text_rule.body =~ "var(#{label_var})"
      end
    end
  end

  describe "edge and hover on the var path (task 01a09333-d374 stage 4)" do
    # The chip's fill is 1.07-1.14:1 against its ground, so its shape comes
    # from its edge, solved to 3:1 against the page ground. Asked the way the
    # browser asks it: which rules in app.css apply to the RENDERED chip, and
    # what do they declare at rest and on hover? `CssRules.matches?/2`
    # resolves `:hover` and `:focus-visible` towards matching, so every
    # hover rule that could reach the chip is inside the net.
    alias Platform.Design.CssRules

    @css_path "assets/css/app.css"

    # Declarations that would move the chip's fill or its box. A hover that
    # changes any of these either reads as a fill state (retired in stage 3)
    # or reflows the rail row the chip sits in.
    @box_or_fill ~w(background background-color width min-width max-width height
                    min-height max-height padding padding-left padding-right padding-top
                    padding-bottom padding-inline padding-block margin border border-width
                    border-top-width border-right-width border-bottom-width border-left-width
                    border-style outline outline-width outline-offset gap font-size
                    font-weight letter-spacing text-transform)

    setup do
      %{rules: @css_path |> File.read!() |> CssRules.rules()}
    end

    for surface <- [:base_100, :base_200], size <- [:default, :compact] do
      @tag surface: surface, size: size
      test "#{surface}, #{size}: the edge at rest comes from the surface's solved slot, at no layout cost",
           %{rules: rules, surface: surface, size: size} do
        n = slot_suffix(surface)

        for clickable <- [true, false] do
          html = render_pill_on(surface, %{scope: "acme", size: size, clickable: clickable})
          tokens = chip_classes(html)
          matched = Enum.filter(rules, &CssRules.matches?(&1.selector, chip_element(html)))
          at = "#{surface} #{size} clickable=#{clickable}"

          case size do
            :default ->
              # The 1px border is the chip's existing chrome; the edge only
              # colours it.
              assert "border" in tokens, at
              rule = Enum.find(matched, &(&1.selector == edge_class(".scope-edge", surface)))
              assert rule, "#{at}: no rest edge rule matched"
              assert rule.body == "border-color: var(--scope-edge-#{n});", at

            :compact ->
              # Compact has NO border: a border would grow it 2px in both
              # axes. The inset box-shadow draws the same 1px edge inside
              # the box.
              refute "border" in tokens, at

              rule =
                Enum.find(matched, &(&1.selector == edge_class(".scope-edge-inset", surface)))

              assert rule, "#{at}: no rest inset edge rule matched"
              assert rule.body == "box-shadow: inset 0 0 0 1px var(--scope-edge-#{n});", at
          end
        end
      end

      @tag surface: surface, size: size
      test "#{surface}, #{size}: hover and keyboard focus swap only the edge colour, at the same geometry",
           %{rules: rules, surface: surface, size: size} do
        n = slot_suffix(surface)
        html = render_pill_on(surface, %{scope: "acme", size: size, clickable: true})
        element = chip_element(html)
        matched = Enum.filter(rules, &CssRules.matches?(&1.selector, element))
        on_hover = Enum.filter(matched, &String.contains?(&1.selector, ":hover"))

        # Anti-vacuity: the chip's own hover rule is in the matched set.
        hover_class =
          edge_class(
            if(size == :compact, do: ".scope-edge-inset-hover", else: ".scope-edge-hover"),
            surface
          )

        hover_rule = Enum.find(on_hover, &(&1.selector == hover_class <> ":hover"))

        assert hover_rule,
               "#{hover_class}:hover does not match the chip; hover rules matched: " <>
                 inspect(Enum.map(on_hover, & &1.selector))

        # NOTHING that fires on hover touches the fill or the box.
        for rule <- on_hover, property <- @box_or_fill do
          refute CssRules.declares?(rule.body, property),
                 "#{rule.selector} changes #{property} on hover: #{rule.body}"
        end

        focus_rule = Enum.find(matched, &(&1.selector == hover_class <> ":focus-visible"))
        assert focus_rule, "#{hover_class}:focus-visible does not match the chip"

        case size do
          :default ->
            assert properties(hover_rule.body) == ["border-color"]
            assert declared(hover_rule.body, "border-color") == "var(--scope-edge-hover-#{n})"
            # Keyboard users get the same edge change.
            assert focus_rule.body == hover_rule.body

          :compact ->
            assert properties(hover_rule.body) == ["box-shadow"]
            rest = "inset 0 0 0 1px var(--scope-edge-#{n})"
            hover = declared(hover_rule.body, "box-shadow")
            assert hover == "inset 0 0 0 1px var(--scope-edge-hover-#{n})"
            # Same geometry as rest: only the colour variable differs.
            assert String.replace(hover, "--scope-edge-hover-", "--scope-edge-") == rest

            assert String.starts_with?(
                     declared(focus_rule.body, "box-shadow"),
                     "inset 0 0 0 1px var(--scope-edge-hover-#{n}, transparent),"
                   )
        end
      end
    end

    test "the compact focus rule keeps the standard focus ring after the inset edge", %{
      rules: rules
    } do
      # Both are box-shadows at the same specificity, and the scope rule is
      # later in app.css, so without the ring repeated here a compact
      # clickable chip would lose its focus indicator. Pinned to the
      # canonical ring's value so the two cannot drift apart.
      ring =
        rules
        |> Enum.find(&(&1.selector == ".focus-visible-ring:focus-visible"))
        |> Map.fetch!(:body)
        |> declared("box-shadow")

      assert ring =~ "var(--color-focus-ring)"

      for surface <- [:base_100, :base_200] do
        n = slot_suffix(surface)
        selector = edge_class(".scope-edge-inset-hover", surface) <> ":focus-visible"
        rule = Enum.find(rules, &(&1.selector == selector))
        assert rule, "#{selector} is missing"

        # The edge var carries a fallback. Without it, a chip whose edge
        # slot is unset (an org with no colour, or a masked chip with no
        # `data-scope`) makes this whole `box-shadow` invalid at
        # computed-value time, and the focus ring is lost with it.
        assert declared(rule.body, "box-shadow") ==
                 "inset 0 0 0 1px var(--scope-edge-hover-#{n}, transparent), " <> ring
      end
    end

    test "static and active chips carry no hover edge; the active chip keeps its own ring and no edge" do
      for surface <- [:base_100, :base_200], size <- [:default, :compact] do
        static =
          chip_classes(render_pill_on(surface, %{scope: "acme", size: size, clickable: false}))

        refute Enum.any?(static, &String.contains?(&1, "hover")), inspect(static)

        active = chip_classes(render_pill_on(surface, %{scope: "acme", size: size, active: true}))
        assert "scope-active" in active
        refute Enum.any?(active, &String.starts_with?(&1, "scope-edge")), inspect(active)
      end
    end

    test "the six shipped orgs take the edge and hover edge like any org" do
      # Stage 4 left the six on their 30% alpha borders; stage 5 moves them.
      for scope <- scopes(),
          surface <- [:base_100, :base_200],
          size <- [:default, :compact] do
        tokens =
          chip_classes(render_pill_on(surface, %{scope: scope, size: size, clickable: true}))

        rest = if(size == :compact, do: "scope-edge-inset", else: "scope-edge")
        hover = rest <> "-hover"

        assert edge_class(rest, surface) in tokens, "#{scope}: #{inspect(tokens)}"
        assert edge_class(hover, surface) in tokens, "#{scope}: #{inspect(tokens)}"

        refute Enum.any?(tokens, &String.starts_with?(&1, "border-")),
               "#{scope}: #{inspect(tokens)}"
      end
    end
  end

  describe "app.css after the six moved (task 01a09333-d374 stage 5)" do
    alias Platform.Design.CssRules
    alias Platform.Tenancy.ScopeColor

    @css_path "assets/css/app.css"
    @fragments ~w(soylent wayne-tech sxi paragon cyberdyne)

    setup do
      %{css: File.read!(@css_path), rules: @css_path |> File.read!() |> CssRules.rules()}
    end

    test "every chip-only per-slug utility is deleted", %{rules: rules, css: css} do
      # Leaving them reachable next to the var path would let the cascade
      # decide which one paints a chip. Checked on the raw text as well as
      # the parsed rules, so a selector the parser spells differently
      # (the escaped hover one) cannot slip past.
      for fragment <- @fragments,
          pattern <- [
            ~r/\.bg-#{fragment}(-active)?\s*\{/,
            ~r/\.border-#{fragment}\s*\{/,
            ~r/\.text-#{fragment}-label\s*\{/,
            ~r/bg-#{fragment}\\\/22/
          ] do
        refute css =~ pattern, "#{inspect(pattern)} still matches app.css"
      end

      for fragment <- @fragments,
          selector <- [
            ".bg-#{fragment}",
            ".bg-#{fragment}-active",
            ".border-#{fragment}",
            ".hover\\:bg-#{fragment}\\/22:hover",
            ".text-#{fragment}-label",
            "[data-theme=dark] .text-#{fragment}-label"
          ] do
        refute Enum.any?(rules, &(&1.selector == selector)), "#{selector} is still in app.css"
      end
    end

    test "the two non-chip utilities stay, painting exactly the fill the org row now stores",
         %{rules: rules} do
      # `.text-<slug>` is `Tenancy.scope_color/1`'s answer (the inheritance
      # pill, files, recovery, the tasks sidebar and filter breadcrumb) and
      # `.bg-<slug>-dot` is `ChatLive.section_dot_class/1`'s (the chat rail's
      # section dots). Neither is a chip, so neither moved. They are a second
      # copy of the fill, so they are held to the row's.
      Code.require_file(
        Path.expand(
          "../../../priv/repo/migrations/20260921190000_add_color_lightness_to_orgs.exs",
          __DIR__
        )
      )

      pinned =
        Map.new(
          Module.concat(Platform.Repo.Migrations, AddColorLightnessToOrgs).shipped(),
          fn {slug, h, c, l} ->
            {String.replace(slug, "_", "-"), ScopeColor.derive(h, c, l).fill}
          end
        )

      for fragment <- @fragments,
          {selector, property} <- [
            {".text-#{fragment}", "color"},
            {".bg-#{fragment}-dot", "background-color"}
          ] do
        rule = Enum.find(rules, &(&1.selector == selector))
        assert rule, "#{selector} was deleted, and it has non-chip consumers"
        value = declared(rule.body, property)

        assert ScopeColor.composite_painted(value, 1.0, "#000000") ==
                 ScopeColor.composite_painted(Map.fetch!(pinned, fragment), 1.0, "#000000"),
               "#{selector} paints #{value}; the org row stores #{pinned[fragment]}"
      end
    end

    test "the root org has no per-slug utility: it is coloured from its row (task 01a116de stage 3)",
         %{rules: rules} do
      # The shipped root slug's three hand-authored rules are deleted; its dot
      # and swatch read `--scope-fill` through `data-scope` instead.
      for selector <- [".text-fabrikam", ".bg-fabrikam-dot", ".channel-section-swatch--fabrikam"] do
        refute Enum.any?(rules, &(&1.selector == selector)), "#{selector} is still in app.css"
      end

      for {selector, property, value} <- [
            {".channel-section-color-dot--unassigned[data-scope]", "background-color",
             "var(--scope-fill, transparent)"},
            {".channel-section-swatch--own", "background-color",
             "var(--scope-fill, transparent)"},
            {".scope-dot-current", "background-color", "var(--scope-fill, currentColor)"}
          ] do
        rule = Enum.find(rules, &(&1.selector == selector))
        assert rule, "#{selector} is missing from app.css"
        assert declared(rule.body, property) == value
      end
    end
  end

  describe "every call site declares its surface (task 01a09333-d374 stage 3)" do
    # The surface is a property of the CALL SITE. An undeclared site takes
    # `:base_100` silently, which is the same failure an ambient wrapper
    # would have had: wrong ground, still legible-looking. So the inventory
    # is pinned here, and a new `<.scope_pill>` goes red until someone
    # decides which ground it sits on and adds it below.
    test "the inventory is exactly these four sites, each with its declared surface" do
      sites =
        "lib/**/*.{ex,heex}"
        |> Path.wildcard()
        |> Enum.reject(&String.ends_with?(&1, "components/scope_pill.ex"))
        |> Enum.flat_map(fn path ->
          source = path |> File.read!() |> String.replace(~r/<%!--.*?--%>/s, "")

          ~r/<[\w.]*\.scope_pill\s.*?\/>/s
          |> Regex.scan(source)
          |> Enum.map(fn [call] ->
            {Path.relative_to(path, "lib/platform_web"), surface_of(call)}
          end)
        end)
        |> Enum.sort()

      assert sites ==
               Enum.sort([
                 {"live/chat/partials/conversation.ex", ":base_100"},
                 {"live/chat/partials/conversation.ex", ":base_100"},
                 {"live/chat/partials/rail.ex", ":base_200"},
                 {"live/tasks/filters_component.ex", ":base_100"}
               ])
    end
  end

  defp surface_of(call) do
    case Regex.run(~r/\bsurface=\{(:[a-z0-9_]+)\}/, call) do
      [_, surface] -> surface
      nil -> "UNDECLARED"
    end
  end

  defp slot_suffix(:base_100), do: "100"
  defp slot_suffix(:base_200), do: "200"

  defp edge_class(class, :base_100), do: class
  defp edge_class(class, :base_200), do: class <> "-200"

  # The declared property names of a rule body, in order.
  defp properties(body) do
    ~r/(?:^|;)\s*([a-z-]+)\s*:/
    |> Regex.scan(body, capture: :all_but_first)
    |> List.flatten()
  end

  # A declaration's value with its whitespace collapsed, or nil.
  defp declared(body, property) do
    case Regex.run(~r/(?:^|;)\s*#{Regex.escape(property)}\s*:\s*([^;]+)/, body) do
      [_, value] -> value |> String.replace(~r/\s+/, " ") |> String.trim()
      nil -> nil
    end
  end

  # A `CssRules` element for the chip node (the first element carrying
  # `text-xs`), rendered standalone, so no ancestor rule can reach it.
  defp chip_element(html) do
    node =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[class]")
      |> Enum.find(fn node ->
        "text-xs" in (node |> LazyHTML.attribute("class") |> hd() |> String.split())
      end)

    [tag] = LazyHTML.tag(node)
    [attrs] = LazyHTML.attributes(node)
    Platform.Design.CssRules.element(tag, attrs)
  end
end
