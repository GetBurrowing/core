defmodule Platform.Design.AppCssImportOrderTest do
  @moduledoc """
  Guards the statement order at the top of `assets/css/app.css` so the
  Burrow Public Sans webfont import actually reaches the browser
  (task 01a15c1d).

  CSS only honours an `@import` that precedes every other statement
  (`@charset` and statement-form `@layer` aside). Before this task the
  `#chat-sidebar {…}` rule sat ABOVE the Google Fonts `@import url(…)`, so
  the import was dead: the browser ignored it in the unminified build and
  lightningcss dropped it outright in the `--minify` (prod) build, leaving
  every `"Public Sans"` font stack falling through to `system-ui`.

  Measured at planning (2026-10-20, tailwind standalone v4.1.12, the version
  pinned in `config/config.exs`) with the url import placed AFTER
  `@import "tailwindcss"`: the unminified build keeps it (1
  `fonts.googleapis` hit) but the `--minify` build drops it (0 hits),
  because tailwind's inlined preflight layers then come first. With the url
  import FIRST, before `@import "tailwindcss"`, both builds keep it. That is
  why assertion 3 pins it ahead of tailwind rather than merely ahead of the
  first style rule.

  The reader below strips `/* … */` comments (outside strings) and splits
  the top level into statements: an at-rule ending in `;`, or any prelude
  followed by a balanced `{…}` block.
  """
  use ExUnit.Case, async: true

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)

  setup_all do
    statements =
      @app_css_path
      |> File.read!()
      |> top_level_statements()

    %{statements: statements}
  end

  test "no @import follows a statement that is not an @import", %{statements: statements} do
    last_import =
      statements
      |> Enum.with_index()
      |> Enum.filter(fn {s, _} -> import?(s) end)
      |> List.last()

    assert last_import, "app.css has no @import statements at all"
    {_, last_idx} = last_import

    offenders =
      statements
      |> Enum.take(last_idx)
      |> Enum.reject(&import?/1)

    assert offenders == [],
           "app.css has non-@import statement(s) before an @import, so the browser " <>
             "(and lightningcss --minify) drops every @import after them. Move these " <>
             "below the @import block:\n" <>
             Enum.map_join(offenders, "\n", &("  " <> excerpt(&1)))
  end

  test "the Google Fonts import loads Public Sans with display=swap", %{statements: statements} do
    font_import = Enum.find(statements, &google_fonts_import?/1)

    assert font_import,
           "app.css has no `@import url(\"https://fonts.googleapis.com/css2?…\")`; " <>
             "the \"Public Sans\" font stacks would fall through to system-ui"

    assert font_import =~ "family=Public+Sans",
           "the Google Fonts import does not request family=Public+Sans: #{excerpt(font_import)}"

    # display=swap renders text in the fallback face while the webfont loads,
    # instead of leaving it invisible (FOIT).
    assert font_import =~ "display=swap",
           "the Google Fonts import is missing display=swap (text would be invisible " <>
             "while the font loads): #{excerpt(font_import)}"
  end

  test "the Google Fonts import comes before @import \"tailwindcss\"", %{statements: statements} do
    font_idx = Enum.find_index(statements, &google_fonts_import?/1)
    tailwind_idx = Enum.find_index(statements, &tailwind_import?/1)

    assert font_idx, "app.css has no Google Fonts @import"
    assert tailwind_idx, ~s(app.css has no @import "tailwindcss")

    assert font_idx < tailwind_idx,
           ~s(the Google Fonts @import must precede @import "tailwindcss": after it, ) <>
             "tailwind's preflight layers come first and `--minify` drops the font import. " <>
             "Found font import at statement #{font_idx}, tailwind at #{tailwind_idx}: " <>
             excerpt(Enum.at(statements, font_idx))
  end

  defp import?(statement), do: String.starts_with?(statement, "@import")

  defp google_fonts_import?(statement),
    do: import?(statement) and statement =~ "fonts.googleapis.com/css2"

  defp tailwind_import?(statement),
    do: Regex.match?(~r/\A@import\s+["']tailwindcss["']/, statement)

  defp excerpt(statement) do
    one_line = statement |> String.replace(~r/\s+/, " ") |> String.trim()

    if String.length(one_line) > 120,
      do: String.slice(one_line, 0, 117) <> "...",
      else: one_line
  end

  # ── top-level statement splitter ──────────────────────────────────────────

  defp top_level_statements(css) do
    css
    |> String.to_charlist()
    |> split([], 0, nil, [])
  end

  # split(rest, current_reversed, depth, quote_char, acc)
  defp split([], cur, _depth, _q, acc), do: Enum.reverse(push(cur, acc))

  # inside a string: copy verbatim until the matching quote (honouring escapes)
  defp split([?\\, c | rest], cur, depth, q, acc) when q != nil,
    do: split(rest, [c, ?\\ | cur], depth, q, acc)

  defp split([q | rest], cur, depth, q, acc) when q != nil,
    do: split(rest, [q | cur], depth, nil, acc)

  defp split([c | rest], cur, depth, q, acc) when q != nil,
    do: split(rest, [c | cur], depth, q, acc)

  # outside a string
  defp split([?/, ?* | rest], cur, depth, nil, acc),
    do: split(skip_comment(rest), cur, depth, nil, acc)

  defp split([c | rest], cur, depth, nil, acc) when c in [?", ?'],
    do: split(rest, [c | cur], depth, c, acc)

  defp split([?{ | rest], cur, depth, nil, acc),
    do: split(rest, [?{ | cur], depth + 1, nil, acc)

  defp split([?} | rest], cur, 1, nil, acc),
    do: split(rest, [], 0, nil, push([?} | cur], acc))

  defp split([?} | rest], cur, depth, nil, acc),
    do: split(rest, [?} | cur], depth - 1, nil, acc)

  defp split([?; | rest], cur, 0, nil, acc),
    do: split(rest, [], 0, nil, push([?; | cur], acc))

  defp split([c | rest], cur, depth, nil, acc),
    do: split(rest, [c | cur], depth, nil, acc)

  defp skip_comment([?*, ?/ | rest]), do: rest
  defp skip_comment([_ | rest]), do: skip_comment(rest)
  defp skip_comment([]), do: []

  defp push(cur, acc) do
    case cur |> Enum.reverse() |> List.to_string() |> String.trim() do
      "" -> acc
      statement -> [statement | acc]
    end
  end
end
