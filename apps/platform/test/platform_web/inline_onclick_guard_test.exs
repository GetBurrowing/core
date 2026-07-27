defmodule PlatformWeb.InlineOnclickGuardTest do
  @moduledoc """
  Corpus-wide ratchet (task 019fa298): no template element may carry both
  `phx-click` and an inline `onclick`.

  `phoenix_live_view` binds its click handler with
  `window.addEventListener(eventName, handler, false)` — BUBBLE phase, on
  `window` (`deps/phoenix_live_view/assets/js/phoenix_live_view/live_socket.js`,
  `bindClick/2`). An inline `onclick` runs at TARGET phase. If it calls
  `event.stopPropagation()` the event never reaches `window` and the
  `phx-click` on that same element is dead; even without
  `stopPropagation` the pairing is a trap, because the next person to add
  one silently kills the LiveView binding with no compiler or test
  signal.

  That is exactly how the stack chevron shipped broken for two months
  with ~15 green `render_click` tests over the very event it had
  disabled — `render_click/3` pushes straight to the server and never
  runs DOM propagation. A markup-level guard is the only thing that can
  see this class of defect, so it lives here as a ratchet rather than as
  one more per-component assertion.

  Scope: every `.heex` template plus every `~H` sigil in a `.ex` module
  under `apps/platform/lib`.
  """
  use ExUnit.Case, async: true

  # test/platform_web -> apps/platform/lib
  @lib_root Path.expand("../../lib", __DIR__)

  # Elements allowed to pair phx-click with an inline onclick. Each entry
  # MUST carry a reason. Empty today: the corpus has exactly one inline
  # onclick left (a file-picker shim that carries no phx-click), so
  # nothing legitimately needs the pairing.
  @allowed []

  defp template_sources do
    heex = Path.wildcard(Path.join(@lib_root, "**/*.heex"))

    sigil_h =
      Path.join(@lib_root, "**/*.ex")
      |> Path.wildcard()
      |> Enum.filter(&String.contains?(File.read!(&1), "~H\""))

    for path <- heex ++ sigil_h, do: {relative(path), File.read!(path)}
  end

  defp relative(path), do: Path.relative_to(path, Path.expand("../..", @lib_root))

  # HEEx comments (`<%!-- --%>`) and HTML comments routinely DESCRIBE the
  # attributes below them — the chevron's own comment named
  # `onclick=stopPropagation` in prose. Scanning them would produce
  # permanent false positives, so they are stripped first. The
  # `positive control` test below proves the stripping does not gut the
  # buffer.
  defp strip_comments(source) do
    source
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/<!--.*?-->/s, "")
  end

  # Collect the text of every element opening tag. Hand-written rather
  # than regex because HEEx attribute values contain `{...}` Elixir
  # interpolations that can hold a bare `>` (`if(a > b, ...)`), which
  # would truncate a naive `<[^>]*>` match mid-tag and hide attributes.
  defp opening_tags(source), do: opening_tags(source, [])

  defp opening_tags(<<>>, acc), do: Enum.reverse(acc)

  defp opening_tags(<<"<", rest::binary>>, acc) do
    case rest do
      <<c, _::binary>> when (c >= ?a and c <= ?z) or (c >= ?A and c <= ?Z) or c == ?. ->
        {tag, remainder} = consume_tag(rest, "", :normal, 0)
        opening_tags(remainder, [tag | acc])

      _ ->
        opening_tags(rest, acc)
    end
  end

  defp opening_tags(<<_::utf8, rest::binary>>, acc), do: opening_tags(rest, acc)

  defp consume_tag(<<>>, acc, _state, _depth), do: {acc, <<>>}

  defp consume_tag(<<c::utf8, rest::binary>>, acc, :normal, depth) do
    cond do
      c == ?> and depth == 0 -> {acc, rest}
      c == ?{ -> consume_tag(rest, acc <> <<c::utf8>>, :normal, depth + 1)
      c == ?} and depth > 0 -> consume_tag(rest, acc <> <<c::utf8>>, :normal, depth - 1)
      c == ?" -> consume_tag(rest, acc <> <<c::utf8>>, {:quote, ?"}, depth)
      # Single quotes only delimit at depth 0. Inside an interpolation
      # they are usually an apostrophe in an Elixir string.
      c == ?' and depth == 0 -> consume_tag(rest, acc <> <<c::utf8>>, {:quote, ?'}, depth)
      true -> consume_tag(rest, acc <> <<c::utf8>>, :normal, depth)
    end
  end

  defp consume_tag(<<c::utf8, rest::binary>>, acc, {:quote, q}, depth) do
    state = if c == q, do: :normal, else: {:quote, q}
    consume_tag(rest, acc <> <<c::utf8>>, state, depth)
  end

  # `(?<![-\w])` keeps `data-onclick` / `phx-click-away` from matching.
  defp phx_click?(tag), do: Regex.match?(~r/(?<![-\w])phx-click[\s=]/, tag)
  defp inline_onclick?(tag), do: Regex.match?(~r/(?<![-\w])onclick\s*=/, tag)

  defp all_tags do
    for {path, source} <- template_sources(),
        tag <- source |> strip_comments() |> opening_tags(),
        do: {path, tag}
  end

  describe "the scanner itself" do
    test "positive control — stripping comments does not empty the buffer" do
      tags = all_tags()

      # If strip_comments/1 ever swallowed whole templates (an unterminated
      # `--%>`, a greedy `.*` instead of `.*?`), every offender check below
      # would pass vacuously. These floors are ~half the real corpus at the
      # time of writing (~4700 tags, ~430 phx-click) — low enough not to
      # churn, high enough that a gutted buffer trips them.
      assert length(tags) > 2000,
             "scanner found only #{length(tags)} opening tags — comment stripping likely ate the corpus"

      assert Enum.count(tags, fn {_, tag} -> phx_click?(tag) end) > 200,
             "scanner found almost no phx-click attributes — it is not reading real templates"
    end

    test "positive control — the detector actually fires on a synthetic offender" do
      offender = ~S|<button phx-click="go" onclick="event.stopPropagation()">x</button>|

      assert [tag] = offender |> strip_comments() |> opening_tags()
      assert phx_click?(tag)
      assert inline_onclick?(tag)
    end

    test "prose describing an onclick is stripped, but the real attribute survives" do
      source = ~S"""
      <%!-- This button uses `onclick=stopPropagation` so its phx-click
            does not bubble. --%>
      <button phx-click="go">x</button>
      <button onclick="pick()">y</button>
      """

      tags = source |> strip_comments() |> opening_tags()

      assert length(tags) == 2
      refute Enum.any?(tags, fn tag -> phx_click?(tag) and inline_onclick?(tag) end)
      assert Enum.count(tags, &inline_onclick?/1) == 1
    end

    test "an interpolation containing `>` does not truncate the tag" do
      source = ~S|<button class={if(@a > @b, do: "x")} phx-click="go" onclick="z()">x</button>|

      assert [tag] = opening_tags(source)
      assert phx_click?(tag)
      assert inline_onclick?(tag), "a bare `>` inside {...} truncated the tag and hid the onclick"
    end

    test "attribute-name boundary — data-onclick and phx-click-away are not matches" do
      refute inline_onclick?(~S|<div data-onclick="x">|)
      refute phx_click?(~S|<div phx-click-away="x">|)
      assert phx_click?(~S|<div phx-click="x">|)
    end
  end

  describe "template corpus" do
    test "no element pairs phx-click with an inline onclick" do
      offenders =
        for {path, tag} <- all_tags(),
            phx_click?(tag),
            inline_onclick?(tag),
            {path, tag} not in @allowed,
            do: {path, tag}

      assert offenders == [], """
      #{length(offenders)} template element(s) carry BOTH phx-click and an inline onclick:

      #{Enum.map_join(offenders, "\n\n", fn {path, tag} -> "  #{path}\n    <#{String.slice(tag, 0, 400) |> String.replace(~r/\s+/, " ")}>" end)}

      These are mutually exclusive. LiveView binds its click handler in the
      BUBBLE phase on `window` (live_socket.js bindClick/2 ->
      window.addEventListener(name, handler, false)). An inline onclick runs
      at TARGET phase; if it stops propagation the event never reaches
      `window` and the phx-click is dead — silently, with no compiler or
      render_click signal.

      Delete the onclick. If you genuinely need both, add the element to
      @allowed in this file WITH a reason.
      """
    end
  end
end
