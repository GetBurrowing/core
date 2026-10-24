defmodule Platform.Design.TextExemptionGuardTest do
  @moduledoc """
  Holds where the two WCAG-exempt text colours may be used (task 01a15902
  stage 1; direction canvas 01a15902-e3b2, classification rule 2).

  `text-disabled` and `text-decorative` are base-content at 40%, below the
  4.5:1 every other text colour clears. WCAG 1.4.3 exempts text inside an
  inactive control and purely decorative text, and nothing else, so each
  class is only legitimate on an element that IS that thing. Without this
  guard the class becomes the new way to ship faint text.

    * `text-disabled`: bare only inside a HEEx tag literal that carries a
      `disabled` or `aria-disabled` attribute in the same tag. Everywhere else
      (Elixir class helpers outside `~H`, JS class strings) only the variant
      forms `disabled:text-disabled` and `aria-disabled:text-disabled` pass,
      because those paint nothing unless the element is disabled.
    * `text-decorative`: bare only inside a HEEx tag literal carrying
      `aria-hidden="true"`. Elsewhere only `aria-hidden:text-decorative`
      passes.

  The scan covers the five secondary-text grep paths of task 01a15902:
  `apps/platform/lib`, `apps/platform/assets/js`, `apps/social/lib`,
  `apps/game_stream/lib` and `apps/game_stream/assets/js`. A HEEx tag literal
  is a `.heex` file or a `~H` sigil in an `.ex` file. Attribute values (quoted
  strings and `{...}` expressions) are not attributes: a class word `disabled`
  does not make the element disabled.

  The fixture tests below show each branch firing in both directions. Named
  mutation (a), task 01a15902 stage 1: `text-disabled` added to a span with
  no `disabled` in a heex turns the tree test red.
  """
  use ExUnit.Case, async: true

  @root Path.expand("../../../../..", __DIR__)

  @code_dirs [
    {"apps/platform/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/platform/assets/js", "**/*.{js,mjs,ts}"},
    {"apps/social/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/game_stream/lib", "**/*.{ex,exs,heex,eex}"},
    {"apps/game_stream/assets/js", "**/*.{js,mjs,ts}"}
  ]

  # A use of either class, with its variant chain. The lookbehind stops a
  # longer class name (`btn-text-disabled`) or an opacity suffix from
  # matching; the lookahead stops `text-disabled-foo`.
  @use ~r/(?<![\w\/-])((?:[a-z0-9-]+:)*)text-(disabled|decorative)(?![\w-])/

  @gates %{"disabled" => ["disabled", "aria-disabled"], "decorative" => ["aria-hidden"]}

  @tag_start ~r/<[A-Za-z.:][\w.:-]*/

  # ── the scanner ────────────────────────────────────────────────────────

  @doc false
  def offenses(kind, source) when kind in [:heex, :ex, :js] do
    regions = heex_regions(kind, source)

    for [{at, _}, {chain_at, chain_len}, {which_at, which_len}] <-
          Regex.scan(@use, source, return: :index),
        chain = binary_part(source, chain_at, chain_len),
        which = binary_part(source, which_at, which_len),
        not gated_by_variant?(chain, which),
        not gated_by_tag?(source, regions, at, which) do
      {line_of(source, at), "text-#{which}", message(which)}
    end
  end

  defp gated_by_variant?(chain, which) do
    chain |> String.split(":", trim: true) |> Enum.any?(&(&1 in Map.fetch!(@gates, which)))
  end

  defp gated_by_tag?(source, regions, at, which) do
    case Enum.find(regions, fn {s, e} -> at >= s and at < e end) do
      nil ->
        false

      {s, _e} ->
        tag_carries_gate?(enclosing_tag(binary_part(source, s, at - s), source, s), which)
    end
  end

  # The tag literal the offset sits inside, or nil when it sits in text.
  defp enclosing_tag(before, source, region_start) do
    case Regex.scan(@tag_start, before, return: :index) |> List.last() do
      nil ->
        nil

      [{tag_at, _}] ->
        start = region_start + tag_at
        rest = binary_part(source, start, byte_size(source) - start)

        case tag_end(rest) do
          nil -> nil
          len when len > byte_size(before) - tag_at -> binary_part(rest, 0, len)
          _ -> nil
        end
    end
  end

  # Length of the tag up to and including its closing `>`, skipping `>`
  # inside quoted values and `{...}` expressions.
  defp tag_end(text), do: tag_end(text, 0, nil, 0)

  defp tag_end(<<>>, _pos, _quote, _depth), do: nil

  defp tag_end(<<"\\", _, rest::binary>>, pos, q, d) when q != nil,
    do: tag_end(rest, pos + 2, q, d)

  defp tag_end(<<q, rest::binary>>, pos, q, d), do: tag_end(rest, pos + 1, nil, d)
  defp tag_end(<<_, rest::binary>>, pos, q, d) when q != nil, do: tag_end(rest, pos + 1, q, d)

  defp tag_end(<<c, rest::binary>>, pos, nil, d) when c in [?", ?'],
    do: tag_end(rest, pos + 1, c, d)

  defp tag_end(<<"{", rest::binary>>, pos, nil, d), do: tag_end(rest, pos + 1, nil, d + 1)
  defp tag_end(<<"}", rest::binary>>, pos, nil, d), do: tag_end(rest, pos + 1, nil, max(d - 1, 0))
  defp tag_end(<<">", _::binary>>, pos, nil, 0), do: pos + 1
  defp tag_end(<<_, rest::binary>>, pos, nil, d), do: tag_end(rest, pos + 1, nil, d)

  defp tag_carries_gate?(nil, _which), do: false

  defp tag_carries_gate?(tag, "disabled") do
    Regex.match?(~r/\s(disabled|aria-disabled)(?=[\s=\/>]|$)/, attributes_only(tag))
  end

  defp tag_carries_gate?(tag, "decorative") do
    Regex.match?(~r/\saria-hidden=("true"|\{true\})/, tag)
  end

  # The tag with every quoted value and `{...}` expression emptied, so only
  # attribute names remain to match against.
  defp attributes_only(tag) do
    tag
    |> then(&Regex.replace(~r/"(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'/s, &1, "\"\""))
    |> strip_braces()
  end

  defp strip_braces(text) do
    stripped = Regex.replace(~r/\{[^{}]*\}/s, text, "")
    if stripped == text, do: text, else: strip_braces(stripped)
  end

  defp heex_regions(:heex, source), do: [{0, byte_size(source)}]
  defp heex_regions(:js, _source), do: []

  defp heex_regions(:ex, source) do
    heredocs =
      for [_, {s, l}] <- Regex.scan(~r/~H"""(.*?)\n\s*"""/s, source, return: :index),
          do: {s, s + l}

    inline =
      for [_, {s, l}] <- Regex.scan(~r/~H"((?:[^"\\\n]|\\.)*)"/, source, return: :index),
          do: {s, s + l}

    heredocs ++ inline
  end

  defp line_of(source, at), do: source |> binary_part(0, at) |> String.split("\n") |> length()

  defp message("disabled"),
    do:
      "bare text-disabled outside a HEEx tag carrying disabled/aria-disabled; " <>
        "use disabled:text-disabled or aria-disabled:text-disabled, or text-subtle"

  defp message("decorative"),
    do:
      "bare text-decorative outside a HEEx tag carrying aria-hidden=\"true\"; " <>
        "use aria-hidden:text-decorative, or text-subtle"

  defp kind(path) do
    case Path.extname(path) do
      ".heex" -> :heex
      ext when ext in [".ex", ".exs", ".eex"] -> :ex
      _ -> :js
    end
  end

  defp tree do
    for {dir, glob} <- @code_dirs,
        path <- Path.wildcard(Path.join([@root, dir, glob])),
        do: {Path.relative_to(path, @root), File.read!(path)}
  end

  # ── fixtures: each branch, both directions ──────────────────────────────

  defp red?(kind, source), do: offenses(kind, source) != []

  describe "text-disabled" do
    test "bare on an element with no disabled attribute is red" do
      assert red?(:heex, ~s(<span class="text-xs text-disabled">x</span>))
      assert [{1, "text-disabled", _}] = offenses(:heex, ~s(<span class="text-disabled">x</span>))
    end

    test "bare on <button disabled> is green" do
      refute red?(:heex, ~s(<button disabled class="btn text-disabled">Save</button>))

      refute red?(
               :heex,
               ~s(<button\n  type="submit"\n  disabled\n  class="text-disabled"\n>Save</button>)
             )

      refute red?(:heex, ~s(<:col disabled class="text-disabled">x</:col>))
    end

    test "bare on a tag with disabled={...} or aria-disabled is green" do
      refute red?(
               :heex,
               ~s(<.button disabled={@off} class={["btn", @off && "text-disabled"]}>Go</.button>)
             )

      refute red?(:heex, ~s(<a aria-disabled="true" class="text-disabled">Next</a>))
    end

    test "a class word or a value named disabled does not count as the attribute" do
      assert red?(:heex, ~s(<span class="disabled text-disabled">x</span>))
      assert red?(:heex, ~s(<span data-state="disabled" class="text-disabled">x</span>))

      assert red?(
               :heex,
               ~s(<span class={if @x > 1, do: "text-disabled"} title="disabled">x</span>)
             )
    end

    test "bare in the text of a child of a disabled tag is red (not in the tag)" do
      assert red?(:heex, ~s(<button disabled><span class="text-disabled">x</span></button>))
    end

    test "disabled:text-disabled in an Elixir class helper is green; bare there is red" do
      refute red?(:ex, ~s|defp cls, do: "text-sm disabled:text-disabled"|)
      refute red?(:ex, ~s|defp cls, do: "aria-disabled:text-disabled"|)
      refute red?(:ex, ~s|defp cls, do: "hover:disabled:text-disabled"|)
      assert red?(:ex, ~s|defp cls, do: "text-sm text-disabled"|)
    end

    test "inside a ~H sigil the tag rule applies" do
      assert red?(:ex, ~s|~H"""\n<span class="text-disabled">x</span>\n"""|)
      refute red?(:ex, ~s|~H"""\n<button disabled class="text-disabled">x</button>\n"""|)
      assert red?(:ex, ~s|x = ~H"<span class='text-disabled'>x</span>"|)
      refute red?(:ex, ~s|x = ~H"<button disabled class='text-disabled'>x</button>"|)
    end

    test "a JS class string passes only in the variant form" do
      assert red?(:js, ~s|el.className = "text-disabled";|)
      assert red?(:js, ~s|el.innerHTML = `<button disabled class="text-disabled">`;|)
      refute red?(:js, ~s|el.className = "disabled:text-disabled";|)
    end
  end

  describe "text-decorative" do
    test "bare without aria-hidden is red; with aria-hidden=\"true\" is green" do
      assert red?(:heex, ~s(<span class="text-decorative">&middot;</span>))
      assert red?(:heex, ~s(<span aria-hidden="false" class="text-decorative">&middot;</span>))
      refute red?(:heex, ~s(<span aria-hidden="true" class="text-decorative">&middot;</span>))
      refute red?(:heex, ~s(<span class="text-decorative" aria-hidden={true}>&middot;</span>))
    end

    test "aria-hidden:text-decorative passes anywhere; bare outside a tag is red" do
      refute red?(:ex, ~s|defp sep, do: "aria-hidden:text-decorative"|)
      refute red?(:js, ~s|const c = "aria-hidden:text-decorative";|)
      assert red?(:ex, ~s|defp sep, do: "text-decorative"|)
      assert red?(:js, ~s|const c = "text-decorative";|)
    end

    test "the disabled gate does not open text-decorative, nor the reverse" do
      assert red?(:heex, ~s(<button disabled class="text-decorative">x</button>))
      assert red?(:heex, ~s(<span aria-hidden="true" class="text-disabled">x</span>))
      assert red?(:js, ~s|"disabled:text-decorative"|)
    end
  end

  test "longer class names that merely contain the token are not uses" do
    refute red?(:heex, ~s(<span class="btn-text-disabled text-disabled-x">x</span>))
  end

  # ── the tree ───────────────────────────────────────────────────────────

  test "the scan reads the five grep paths (anti-vacuity)" do
    files = tree()
    count = fn prefix -> Enum.count(files, fn {p, _} -> String.starts_with?(p, prefix) end) end

    assert count.("apps/platform/lib/") > 500
    assert count.("apps/platform/assets/js/") > 50
    assert count.("apps/social/lib/") > 20
    assert count.("apps/game_stream/lib/") > 10
    assert count.("apps/game_stream/assets/js/") > 0
    assert Enum.count(files, fn {p, _} -> kind(p) == :heex end) > 20

    # Most HEEx lives in ~H sigils, so the region finder must see them.
    sigils = for {p, src} <- files, kind(p) == :ex, do: length(heex_regions(:ex, src))
    assert Enum.sum(sigils) > 300
  end

  test "every text-disabled and text-decorative in the tree sits where it is exempt" do
    found =
      for {path, source} <- tree(),
          {line, class, why} <- offenses(kind(path), source),
          do: "#{path}:#{line}: #{class}: #{why}"

    assert found == [],
           "WCAG-exempt text colours used where the element is not exempt " <>
             "(direction canvas 01a15902-e3b2, rule 2):\n  " <> Enum.join(found, "\n  ")
  end
end
