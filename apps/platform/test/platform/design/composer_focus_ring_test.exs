defmodule Platform.Design.ComposerFocusRingTest do
  @moduledoc """
  Pins the chat composer's focus indicator in `apps/platform/assets/css/app.css`
  (task 01a120c5 stage 5).

  `#compose_text` strips its own chrome, so `.compose-pill-bar:focus-within` is
  the only focus indicator on the most-used input. It used cyan literals, and in
  the dark theme its border-color never applied at all: the theme rule
  `:root:not([data-theme="light"]) .compose-pill-bar` is (0,3,0) and outranked
  the (0,2,0) focus rule, so focus showed only a 10%-alpha halo (about 1.2:1).

  Two independent properties are asserted, because neither can see the other's
  failure:

    * every `:focus-within` rule for the pill reads `var(--color-focus-ring)` and
      carries no colour literal (a slot reference at too low a specificity
      passes this and paints nothing);
    * for each theme, the strongest `:focus-within` selector that matches it
      outranks, by (specificity, source order), every non-focus pill rule that
      matches the same theme and sets border-color or box-shadow (a winning
      selector that still says cyan passes this).

  Rules are parsed from the stylesheet with comments stripped, never matched
  file-wide by value, and an empty extraction raises rather than looping over
  nothing.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../assets/css/app.css", __DIR__)

  setup_all do
    {:ok, rules: pill_rules(File.read!(@css_path))}
  end

  describe "the composer :focus-within rules read the focus-ring slot" do
    test "there is a :focus-within rule matching each theme", %{rules: rules} do
      for theme <- [:dark, :light] do
        assert focus_selectors(rules, theme) != [],
               "no .compose-pill-bar:focus-within selector matches the #{theme} theme"
      end
    end

    test "every :focus-within declaration uses var(--color-focus-ring) and no literal", %{
      rules: rules
    } do
      focus_rules = Enum.filter(rules, fn r -> Enum.any?(r.selectors, &focus?/1) end)
      assert focus_rules != [], "no .compose-pill-bar:focus-within rule was extracted"

      for rule <- focus_rules do
        decls = Map.take(rule.decls, ["border-color", "box-shadow"])

        assert Map.keys(decls) |> Enum.sort() == ["border-color", "box-shadow"],
               "focus rule #{inspect(rule.selectors)} must set both border-color and " <>
                 "box-shadow; it sets #{inspect(rule.decls)}"

        for {prop, value} <- decls do
          assert value =~ "var(--color-focus-ring)",
                 "#{prop} in #{inspect(rule.selectors)} is #{value}, not the focus-ring slot"

          refute value =~ ~r/oklch\(|rgba?\(|#[0-9a-fA-F]{3,8}\b|\b207\b/,
                 "#{prop} in #{inspect(rule.selectors)} carries a colour literal: #{value}"
        end
      end
    end
  end

  describe "the focus rule wins the cascade in each theme" do
    test "dark: the strongest matching :focus-within selector outranks the dark pill rules",
         %{rules: rules} do
      assert_focus_wins(rules, :dark)
    end

    test "light: the strongest matching :focus-within selector outranks the light pill rules",
         %{rules: rules} do
      assert_focus_wins(rules, :light)
    end
  end

  defp assert_focus_wins(rules, theme) do
    best = focus_selectors(rules, theme) |> Enum.max_by(&rank/1)

    competitors =
      for rule <- rules,
          Map.has_key?(rule.decls, "border-color") or Map.has_key?(rule.decls, "box-shadow"),
          sel <- rule.selectors,
          not focus?(sel),
          matches?(sel, theme),
          do: %{sel: sel, spec: specificity(sel), pos: rule.pos}

    assert competitors != [],
           "no non-focus #{theme} .compose-pill-bar rule was extracted; the comparison " <>
             "would be vacuous"

    for c <- competitors do
      assert rank(best) > rank(c),
             "in #{theme}, #{inspect(c.sel)} #{inspect(c.spec)} at offset #{c.pos} beats " <>
               "the strongest focus selector #{inspect(best.sel)} #{inspect(best.spec)} " <>
               "at offset #{best.pos}, so the focus border never paints"
    end
  end

  defp rank(%{spec: spec, pos: pos}), do: {spec, pos}

  defp focus_selectors(rules, theme) do
    for rule <- rules,
        sel <- rule.selectors,
        focus?(sel),
        matches?(sel, theme),
        do: %{sel: sel, spec: specificity(sel), pos: rule.pos}
  end

  defp focus?(sel), do: sel =~ ".compose-pill-bar:focus-within" and sel =~ ~r/focus-within\s*$/

  # A selector with no theme qualifier matches both themes.
  defp matches?(sel, :dark),
    do:
      sel =~ ~s|[data-theme="dark"]| or sel =~ ~s|:not([data-theme="light"])| or
        not themed?(sel)

  defp matches?(sel, :light),
    do:
      (sel =~ ~s|[data-theme="light"]| and not (sel =~ ~s|:not([data-theme="light"])|)) or
        not themed?(sel)

  defp themed?(sel), do: sel =~ "data-theme"

  # {ids, classes + attributes + pseudo-classes}. `:not(x)` contributes only its
  # argument's specificity, which the flat count gives because `:not` itself is
  # excluded. No pill selector has a type selector, so that column is omitted.
  defp specificity(sel) do
    attrs = Regex.scan(~r/\[[^\]]*\]/, sel) |> length()
    rest = Regex.replace(~r/\[[^\]]*\]/, sel, "")
    ids = Regex.scan(~r/#[\w-]+/, rest) |> length()
    classes = Regex.scan(~r/\.[\w-]+/, rest) |> length()
    pseudos = Regex.scan(~r/:(?!not\()[\w-]+/, rest) |> length()
    {ids, attrs + classes + pseudos}
  end

  # Every innermost `selector { decls }` block whose selector list names
  # `.compose-pill-bar` (and not a descendant of it), with its byte offset.
  defp pill_rules(css) do
    stripped = Regex.replace(~r{/\*.*?\*/}s, css, fn m -> String.duplicate(" ", byte_size(m)) end)

    rules =
      Regex.scan(~r/([^{}]+)\{([^{}]*)\}/, stripped, return: :index)
      |> Enum.map(fn [_, {s_at, s_len}, {d_at, d_len}] ->
        selectors =
          binary_part(stripped, s_at, s_len)
          |> String.split(",")
          |> Enum.map(&String.trim/1)

        decls =
          binary_part(stripped, d_at, d_len)
          |> String.split(";")
          |> Enum.flat_map(fn d ->
            case String.split(d, ":", parts: 2) do
              [k, v] -> [{String.trim(k), String.trim(v)}]
              _ -> []
            end
          end)
          |> Map.new()

        %{selectors: selectors, decls: decls, pos: s_at}
      end)
      |> Enum.map(fn r ->
        %{
          r
          | selectors: Enum.filter(r.selectors, &(&1 =~ ~r/\.compose-pill-bar(:focus-within)?$/))
        }
      end)
      |> Enum.reject(&(&1.selectors == []))

    if rules == [], do: raise("no .compose-pill-bar rule extracted from #{@css_path}")
    rules
  end
end
