defmodule PlatformWeb.Components.SheetSwipeCallSiteGuardTest do
  @moduledoc """
  Source guard (task 01a161c4 stage 1): every `<.sheet` call site under
  `lib/platform_web` that sets `swipe_dismiss` also sets `handle_close`.

  `PlatformWeb.Components.Sheet.sheet/1` raises at render when swipe_dismiss
  is set without the handle Close button, but a raise only fires on a sheet
  something renders. This scan covers the call sites no test renders.

  It reads source, so comments and `@moduledoc` / `@doc` heredocs are stripped
  first (a doc that quotes `<.sheet ... swipe_dismiss>` is not a call site),
  and each opening tag is parsed to its own closing `>` with `{...}` and
  quoted attribute values skipped.
  """

  use ExUnit.Case, async: true

  @lib_root Path.expand("../../../lib/platform_web", __DIR__)

  # Anti-vacuity floors. `>=`, not `==`: new sheets landing on other branches
  # must not conflict with this file. At the time of writing: 9 swipe sites,
  # 25+ `<.sheet` tags in total.
  @min_swipe_tags 9
  @min_sheet_tags 20

  test "every <.sheet swipe_dismiss> call site also sets handle_close" do
    tags = all_sheet_tags()
    swipe = Enum.filter(tags, fn {_file, _offset, tag} -> has_attr?(tag, "swipe_dismiss") end)

    assert length(tags) >= @min_sheet_tags,
           "expected >= #{@min_sheet_tags} <.sheet tags under lib/platform_web, found #{length(tags)}: the scan is not seeing the call sites"

    assert length(swipe) >= @min_swipe_tags,
           "expected >= #{@min_swipe_tags} swipe_dismiss sheets, found #{length(swipe)}: the scan is not seeing the call sites"

    offenders =
      for {file, offset, tag} <- swipe, not has_attr?(tag, "handle_close") do
        "#{Path.relative_to(file, @lib_root)} (char #{offset}): #{tag}"
      end

    assert offenders == [],
           """
           swipe_dismiss without handle_close (the drag start point would be a bare
           .sheet-handle with touch-action: auto, so a touch drag gets pointercancel).
           Add handle_close AND a visible aria-hidden title line in the sheet body:

           #{Enum.join(offenders, "\n")}
           """
  end

  test "the tag parser stops at the tag's own > and skips braces and quotes" do
    src = ~S"""
    <.sheet id="a" open={@x > 1} class="b>c" swipe_dismiss
      handle_close
    >
      <p swipe_dismiss>not an attribute of the sheet</p>
    </.sheet>
    <.sheet_action swipe_dismiss />
    <.sheet id="z" swipe_dismiss>body handle_close</.sheet>
    """

    assert [{_, _, first}, {_, _, second}] = tags_in("inline", src)
    assert has_attr?(first, "swipe_dismiss") and has_attr?(first, "handle_close")
    assert has_attr?(second, "swipe_dismiss")
    refute has_attr?(second, "handle_close")
  end

  test "comments and doc heredocs are not call sites" do
    src = ~S'''
    @moduledoc """
    Use `<.sheet ... swipe_dismiss>` here.
    """
    # <.sheet swipe_dismiss>
    <%!-- <.sheet swipe_dismiss> --%>
    <!-- <.sheet swipe_dismiss> -->
    <.sheet id="real" handle_close>x</.sheet>
    '''

    assert [{_, _, tag}] = tags_in("inline", src)
    assert tag =~ ~s(id="real")
  end

  defp all_sheet_tags do
    @lib_root
    |> Path.join("**/*.{ex,heex}")
    |> Path.wildcard()
    |> Enum.flat_map(fn file -> tags_in(file, File.read!(file)) end)
  end

  defp tags_in(file, src) do
    stripped = strip_comments(src)

    ~r/<\.sheet(?=[\s>])/
    |> Regex.scan(stripped, return: :index)
    |> Enum.map(fn [{start, _len}] ->
      {file, start, read_tag(stripped, start)}
    end)
  end

  defp strip_comments(src) do
    src
    |> String.replace(~r/@(?:moduledoc|doc)\s+(?:~[sS])?"""[\s\S]*?"""/, "")
    |> String.replace(~r/<%!--[\s\S]*?--%>/, "")
    |> String.replace(~r/<!--[\s\S]*?-->/, "")
    |> String.replace(~r/^\s*#.*$/m, "")
  end

  # Walks from `<.sheet` to the first `>` at brace depth 0 outside quotes.
  defp read_tag(src, start) do
    src
    |> binary_part(start, byte_size(src) - start)
    |> String.graphemes()
    |> Enum.reduce_while({[], 0, nil}, fn
      ch, {acc, depth, nil} when ch in ["\"", "'"] and depth == 0 ->
        {:cont, {[ch | acc], depth, ch}}

      ch, {acc, depth, q} when q != nil ->
        {:cont, {[ch | acc], depth, if(ch == q, do: nil, else: q)}}

      "{", {acc, depth, nil} ->
        {:cont, {["{" | acc], depth + 1, nil}}

      "}", {acc, depth, nil} ->
        {:cont, {["}" | acc], depth - 1, nil}}

      ">", {acc, 0, nil} ->
        {:halt, {[">" | acc], 0, nil}}

      ch, {acc, depth, nil} ->
        {:cont, {[ch | acc], depth, nil}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> Enum.join()
  end

  # Attribute names only: strip `{...}` and quoted values first so a value
  # containing the word cannot count.
  defp has_attr?(tag, name) do
    bare =
      tag
      |> strip_braces()
      |> String.replace(~r/"[^"]*"|'[^']*'/, "\"\"")

    Regex.match?(~r/(?:^|\s)#{name}(?=[\s=\/>]|$)/, bare)
  end

  defp strip_braces(tag) do
    stripped = String.replace(tag, ~r/\{[^{}]*\}/, "")
    if stripped == tag, do: tag, else: strip_braces(stripped)
  end
end
