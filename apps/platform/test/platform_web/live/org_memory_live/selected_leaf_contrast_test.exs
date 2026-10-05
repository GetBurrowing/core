defmodule PlatformWeb.OrgMemoryLive.SelectedLeafContrastTest do
  @moduledoc """
  The selected leaf of the Org Memory tree, in both of its forms (a Burrow
  Docs topic and a Pages-tree page), clears WCAG AA text contrast in EVERY
  theme the app ships (task 01a10a44 stage 6).

  ## Why this file exists

  Stage 5 painted the selected leaf `text-[var(--color-interactive)]` on
  `bg-base-300`. The task-level review measured it at 3.27:1 in light
  (#087f93 on #D7D7D7), under the 4.5:1 this 14px text owes. Dark measured
  10.48:1, so reviewing in dark could not see the defect. The fix moved the
  selected ground to `base-100` and left the global `--color-interactive`
  token alone, because that token colours every link in the product.

  ## How the clauses are arranged

  Nothing about the colour pair is typed into this file:

    * the leaf's classes come from RENDERING `NamespaceTree.namespace_tree/1`
      and reading the `aria-current="page"` element, not from the module
      attribute that holds them;
    * the ground token and the text token are read out of those classes;
    * the theme list is read from the daisyUI plugin's `themes:` option and
      cross-checked against the `daisyui-theme` blocks' `name:` lines;
    * each token's value is read from that theme's block (or, for
      `--color-interactive`, the rule that declares it for the theme).

  So reverting the ground to `bg-base-300`, adding a third theme, or retuning
  any token moves the computed ratio instead of leaving a stale pin behind.
  The pure-function tests need no database, hence `async: true`; nothing here
  writes `burrow/` rows.
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [render_component: 2]

  alias Platform.Design.WcagContrast, as: W
  alias PlatformWeb.OrgMemoryLive.NamespaceTree

  @css_path Path.expand("../../../../assets/css/app.css", __DIR__)

  # AA for normal-weight body text. The leaf is `text-sm` (14px) at
  # `font-medium`, which is not "large text" under WCAG.
  @aa_text 4.5

  @org_key "org/page/runbook.md"
  @burrow_key "burrow/page/stacks.md"

  setup_all do
    css = File.read!(@css_path)
    themes = themes!(css)

    {:ok,
     css: css,
     themes: themes,
     colors: Map.new(themes, &{&1, theme_colors!(css, &1)}),
     org_html: render_tree(@org_key),
     burrow_html: render_tree(@burrow_key)}
  end

  test "the converter is sound before any ratio below is trusted" do
    assert_in_delta W.contrast(W.hex("#FFFFFF"), W.hex("#000000")), 21.0, 0.001
    assert W.to_hex(W.parse!("oklch(100% 0 0)")) == "#FFFFFF"
    assert W.to_hex(W.parse!("oklch(0% 0 0)")) == "#000000"
    # The reviewer's failing pair, reproduced: if this does not read 3.27 the
    # instrument disagrees with the measurement that opened this stage.
    assert_in_delta W.contrast(W.hex("#087f93"), W.parse!("oklch(88% 0 0)")), 3.27, 0.01
  end

  test "the theme list is every theme the stylesheet declares", %{css: css, themes: themes} do
    declared =
      Regex.scan(~r/name:\s*"([^"]+)"/, css, capture: :all_but_first)
      |> List.flatten()
      |> Enum.sort()

    assert Enum.sort(themes) == declared,
           "daisyUI `themes:` (#{inspect(themes)}) and the daisyui-theme blocks " <>
             "(#{inspect(declared)}) disagree; a theme exists that this file does not measure."

    assert length(themes) >= 2
  end

  for {kind, key} <- [{"Burrow Docs", @burrow_key}, {"Pages tree", @org_key}] do
    describe "the selected #{kind} leaf" do
      @describetag kind: kind
      @describetag key: key

      setup %{key: key} = ctx do
        html = if key == @burrow_key, do: ctx.burrow_html, else: ctx.org_html
        {:ok, selected: selected_class!(html, key), unselected: unselected_classes(html, key)}
      end

      test "does not sit on base-300, the ground that measured 3.27:1", %{selected: classes} do
        refute "bg-base-300" in classes,
               "the selected leaf is back on bg-base-300: #{Enum.join(classes, " ")}"

        refute "hover:bg-base-300" in classes,
               "hovering the selected leaf would repaint it base-300 and bring the " <>
                 "3.27:1 pair back: #{Enum.join(classes, " ")}"
      end

      test "keeps the canvas's interactive text, weight and aria-current", %{selected: classes} do
        assert text_token!(classes) == "--color-interactive"
        assert "font-medium" in classes
      end

      test "is distinct from an unselected row at rest and on hover", %{
        selected: selected,
        unselected: unselected
      } do
        assert unselected != [], "the fixture rendered no unselected leaf to compare against"

        for row <- unselected do
          refute ground_token!(selected) == hover_token(row),
                 "the selected ground equals the hover ground; the two states read the same"

          assert "ring-edge" in selected
          refute "ring-edge" in row
          refute "font-medium" in row
        end
      end

      test "clears AA in every shipped theme", %{selected: classes, colors: colors} do
        ground = "--color-" <> ground_token!(classes)
        text = text_token!(classes)

        for {theme, tokens} <- colors do
          ratio = W.contrast(Map.fetch!(tokens, text), Map.fetch!(tokens, ground))

          assert ratio >= @aa_text,
                 "#{theme}: #{text} on #{ground} is #{Float.round(ratio, 4)}:1, under " <>
                   "the #{@aa_text}:1 AA floor for this text"
        end
      end
    end
  end

  # ── Render ───────────────────────────────────────────────────────────────

  defp render_tree(selected_key) do
    pages = [
      %{file_key: @org_key, version: 1},
      %{file_key: "org/page/glossary.md", version: 1}
    ]

    burrow_docs = [
      %{
        file_key: @burrow_key,
        title: "Task stacks",
        summary: nil,
        order: 5,
        verified_at: nil,
        index?: false
      },
      %{
        file_key: "burrow/page/spaces.md",
        title: "Spaces",
        summary: nil,
        order: 1,
        verified_at: nil,
        index?: false
      }
    ]

    render_component(&NamespaceTree.namespace_tree/1,
      tree: NamespaceTree.build(pages),
      expanded_prefixes: MapSet.new(["org/", NamespaceTree.burrow_prefix()]),
      selected_file_key: selected_key,
      burrow_docs: burrow_docs
    )
  end

  defp leaves(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("button[data-file-key]")
  end

  defp selected_class!(html, key) do
    selected = Enum.filter(leaves(html), &(Floki.attribute(&1, "aria-current") == ["page"]))

    assert [leaf] = selected, "expected exactly one aria-current leaf, got #{length(selected)}"
    assert Floki.attribute(leaf, "data-file-key") == [key]
    classes(leaf)
  end

  # Unselected leaves of the SAME kind as `key`, so each leaf is compared with
  # its own siblings rather than with the other list.
  defp unselected_classes(html, key) do
    burrow? = String.starts_with?(key, "burrow/")

    html
    |> leaves()
    |> Enum.reject(&(Floki.attribute(&1, "aria-current") == ["page"]))
    |> Enum.filter(fn leaf ->
      [k] = Floki.attribute(leaf, "data-file-key")
      String.starts_with?(k, "burrow/") == burrow?
    end)
    |> Enum.map(&classes/1)
  end

  defp classes(leaf) do
    leaf |> Floki.attribute("class") |> Enum.join(" ") |> String.split()
  end

  # The opaque, unprefixed `bg-<token>` on the element. An alpha modifier
  # would make the ground depend on whatever sits behind the row, which this
  # file does not model, so it flunks rather than measuring a guess.
  defp ground_token!(classes) do
    case Enum.filter(classes, &String.starts_with?(&1, "bg-")) do
      ["bg-" <> token] ->
        refute String.contains?(token, "/"), "the selected ground is translucent: bg-#{token}"
        token

      other ->
        flunk("expected exactly one bg-* ground on the selected leaf, got #{inspect(other)}")
    end
  end

  defp hover_token(classes) do
    Enum.find_value(classes, fn
      "hover:bg-" <> token -> token
      _ -> nil
    end)
  end

  defp text_token!(classes) do
    case Enum.flat_map(classes, &(Regex.run(~r/^text-\[var\((--[a-z0-9-]+)\)\]$/, &1) || [])) do
      [_, token] -> token
      other -> flunk("expected one text-[var(--token)] class, got #{inspect(other)}")
    end
  end

  # ── Stylesheet ───────────────────────────────────────────────────────────

  defp themes!(css) do
    case Regex.run(~r/@plugin "\.\.\/vendor\/daisyui" \{\s*themes:\s*\[([^\]]*)\]/, css,
           capture: :all_but_first
         ) do
      [list] ->
        Regex.scan(~r/"([^"]+)"/, list, capture: :all_but_first) |> List.flatten()

      nil ->
        flunk("no daisyUI `themes:` option in #{@css_path}")
    end
  end

  # Every `--color-*` declared in the theme's block, plus `--color-interactive`
  # for that theme.
  defp theme_colors!(css, theme) do
    block = theme_block!(css, theme)

    Regex.scan(~r/^[^\S\n]*(--color-[a-z0-9-]+):[^\S\n]*([^;\n]+);/m, block,
      capture: :all_but_first
    )
    |> Enum.flat_map(fn [token, value] ->
      value = String.trim(value)
      if String.starts_with?(value, "var("), do: [], else: [{token, W.parse!(value)}]
    end)
    |> Map.new()
    |> Map.put("--color-interactive", interactive!(css, theme))
  end

  defp theme_block!(css, name) do
    css
    |> String.split(~s(@plugin "../vendor/daisyui-theme" {))
    |> Enum.drop(1)
    |> Enum.map(&(&1 |> String.split(~r/^\}/m, parts: 2) |> hd()))
    |> Enum.find(&Regex.match?(~r/name:\s*"#{name}"/, &1))
    |> case do
      nil -> flunk("no daisyui-theme block named #{inspect(name)} in #{@css_path}")
      block -> block
    end
  end

  # The theme's own `[data-theme="<name>"]` declaration wins; otherwise the
  # bare `:root` one. Both are top-level rules closed by a `}` at column 0.
  defp interactive!(css, theme) do
    declared_in = fn selector ->
      Regex.scan(~r/^#{Regex.escape(selector)} \{\n(.*?)^\}/ms, css, capture: :all_but_first)
      |> List.flatten()
      |> Enum.find_value(fn body ->
        case Regex.run(~r/^[^\S\n]*--color-interactive:[^\S\n]*([^;\n]+);/m, body,
               capture: :all_but_first
             ) do
          [value] -> String.trim(value)
          nil -> nil
        end
      end)
    end

    value = declared_in.(~s([data-theme="#{theme}"])) || declared_in.(":root")
    assert value, "no --color-interactive declaration resolves for theme #{theme}"
    W.parse!(value)
  end
end
