defmodule PlatformWeb.Components.Meeting.GalleryTwoUpCssTest do
  @moduledoc """
  CSS guard for the two-person gallery (task 01a1a822 stage 2; design
  direction canvas 01a1a822-6d28-7000-ac6c-f653ccb0616e).

  The layout lives only in app.css, so nothing in a LiveView render can
  tell a two-up stage from a plain two-column grid. These tests pin the
  three things the layout needs: the `gallery-stage` size container, and
  one orientation rule per stage shape, each scoped to
  `[data-gallery-two-up]` so 1-person, 3+-person, bottom-strip and
  canvas-tile layouts cannot be touched by it.

  Each `@container` block is extracted by brace matching, so an assertion
  about a block's selectors and declarations reads only that block.
  """
  use ExUnit.Case, async: true

  @css_path Path.expand("../../../../assets/css/app.css", __DIR__)

  setup_all do
    {:ok, css: File.read!(@css_path)}
  end

  # Body of every `@container <prelude> { ... }` block whose prelude
  # matches `prelude_regex`, braces balanced.
  defp container_blocks(css, prelude_regex) do
    Regex.scan(~r/@container\s+([^{]+)\{/, css, return: :index)
    |> Enum.flat_map(fn [{start, len}, {p_start, p_len}] ->
      prelude = binary_part(css, p_start, p_len)

      if prelude =~ prelude_regex do
        [balanced_body(css, start + len)]
      else
        []
      end
    end)
  end

  defp balanced_body(css, from) do
    rest = binary_part(css, from, byte_size(css) - from)
    take_balanced(rest, 1, [])
  end

  defp take_balanced(<<"}", _::binary>>, 1, acc),
    do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp take_balanced(<<"}", rest::binary>>, d, acc), do: take_balanced(rest, d - 1, ["}" | acc])
  defp take_balanced(<<"{", rest::binary>>, d, acc), do: take_balanced(rest, d + 1, ["{" | acc])

  defp take_balanced(<<c::utf8, rest::binary>>, d, acc),
    do: take_balanced(rest, d, [<<c::utf8>> | acc])

  defp take_balanced(<<>>, _d, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  # Selectors of every rule inside a block body.
  defp selectors(body) do
    ~r/([^{}]+)\{[^{}]*\}/
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [sel] -> String.trim(sel) end)
  end

  test "the gallery stage is a size container named gallery-stage", %{css: css} do
    assert css =~
             ~r/\[data-gallery-stage\]\s*\{[^}]*container-type:\s*size;[^}]*container-name:\s*gallery-stage;/
  end

  test "the landscape rule exists, queries gallery-stage, and is scoped to [data-gallery-two-up]",
       %{css: css} do
    assert [body] = container_blocks(css, ~r/^gallery-stage\s+\(orientation:\s*landscape\)\s*$/)

    sels = selectors(body)
    assert sels != []
    assert Enum.all?(sels, &String.starts_with?(&1, "[data-gallery-two-up]"))

    # Two 16:9 columns, centred, rows no longer stretched.
    assert body =~ ~r/grid-template-columns:\s*repeat\(\s*2,/
    assert body =~ ~r/align-content:\s*center/
    assert body =~ ~r/grid-auto-rows:\s*auto/
    assert body =~ ~r/aspect-ratio:\s*16\s*\/\s*9/
  end

  test "the portrait rule exists, queries gallery-stage, and is scoped to [data-gallery-two-up]",
       %{css: css} do
    assert [body] = container_blocks(css, ~r/^gallery-stage\s+\(orientation:\s*portrait\)\s*$/)

    sels = selectors(body)
    assert sels != []
    assert Enum.all?(sels, &String.starts_with?(&1, "[data-gallery-two-up]"))

    # One column, two equal rows.
    assert body =~ ~r/grid-template-columns:\s*minmax\(0,\s*1fr\)/
    assert body =~ ~r/grid-template-rows:\s*repeat\(\s*2,\s*minmax\(0,\s*1fr\)\)/
  end

  test "no gallery-stage rule reaches outside the two-up grid", %{css: css} do
    for body <- container_blocks(css, ~r/^gallery-stage\b/), sel <- selectors(body) do
      assert String.starts_with?(sel, "[data-gallery-two-up]"),
             "gallery-stage query leaks to #{sel}"
    end
  end
end
