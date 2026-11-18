defmodule Platform.Design.PublicBookingScrollGuardTest do
  @moduledoc """
  Guards the public booking page's scroller (task
  01a1eff0-3c29-7000-9b06-f3e8ad78b03f, stage 3).

  `app.css` locks `html, body` to the viewport with `overflow: hidden`
  because the signed-in app shell brings its own inner scrollers.
  `/book/:token` is mounted with `layout: false`, so it has no shell; its
  root `main.cal-guest-wrap` must be the scroll container itself, or a
  phone sees the top of the card and can never reach the times.

  The guard holds both sides:

    * the top-level `.cal-guest-wrap` rule declares a viewport height,
      `overflow-y: auto` (or `scroll`) and contained overscroll, and its
      children do not shrink (the card is `overflow: hidden`, so as a flex
      item its automatic minimum height is 0 and it would be squeezed to
      the viewport and clip instead of scrolling);
    * the global `html, body` rule still declares `overflow: hidden`, so
      the page was not fixed by unlocking every page;
    * in an installed web app the scroller's height matches the standalone
      `html, body` height, so no strip of body shows under it.

  Rules are sliced by selector and context before their bodies are read,
  so a declaration elsewhere in the file cannot satisfy a clause.

  Named mutations, each shown to turn this file red (stage 3 evidence):
  (a) drop `overflow-y: auto` from `.cal-guest-wrap`; (b) drop
  `overflow: hidden` from the global `html, body` rule.
  """
  use ExUnit.Case, async: true

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @standalone "@media all and (display-mode: standalone)"

  setup_all do
    css = @app_css_path |> File.read!() |> strip_comments()
    %{rules: rules(css)}
  end

  test "the public booking page root is its own scroll container", %{rules: rules} do
    body = only_rule(rules, ".cal-guest-wrap", [])

    assert declaration(body, "overflow-y") in ["auto", "scroll"],
           ".cal-guest-wrap must declare overflow-y: auto; got #{inspect(declaration(body, "overflow-y"))}"

    height = declaration(body, "height")

    assert is_binary(height) and height =~ ~r/\b100d?vh\b/,
           ".cal-guest-wrap must declare a viewport height; got #{inspect(height)}"

    assert declaration(body, "overscroll-behavior") == "contain"
    assert declaration(body, "-webkit-overflow-scrolling") == "touch"

    padding = declaration(body, "padding")

    assert is_binary(padding) and padding =~ "env(safe-area-inset-bottom",
           ".cal-guest-wrap's padding must clear the bottom safe area; got #{inspect(padding)}"

    children = only_rule(rules, ".cal-guest-wrap > *", [])
    assert declaration(children, "flex-shrink") == "0"
  end

  test "the global html, body lock is untouched", %{rules: rules} do
    body = only_rule(rules, "html, body", [])

    assert declaration(body, "overflow") == "hidden",
           "the global html, body rule must keep overflow: hidden (signed-in pages rely on it)"

    assert declaration(body, "height") == "100dvh"
  end

  test "in an installed web app the scroller matches the body height", %{rules: rules} do
    shell = only_rule(rules, "html, body, .app-shell-root", [@standalone])
    wrap = only_rule(rules, ".cal-guest-wrap", [@standalone])

    assert declaration(wrap, "height") == declaration(shell, "height")
  end

  defp only_rule(rules, selector, context) do
    case Enum.filter(rules, &(&1.selector == selector and &1.context == context)) do
      [rule] ->
        rule.body

      found ->
        flunk(
          "expected exactly one #{inspect(selector)} rule in #{inspect(context)}, found #{length(found)}"
        )
    end
  end

  defp declaration(block, prop) do
    case Regex.run(~r/(?:^|[;{])\s*#{Regex.escape(prop)}\s*:\s*([^;]+);/m, block) do
      [_, value] -> String.trim(value)
      nil -> nil
    end
  end

  defp strip_comments(text), do: Regex.replace(~r{/\*.*?\*/}s, text, "")

  # Leaf rules of a comment-free stylesheet: %{context, selector, body}, where
  # context is the list of enclosing at-rule preludes. Mirrors
  # bottom_nav_glass_guard_test.exs.
  defp rules(css), do: walk(css, [], "", [], [])

  defp walk("", _stack, _buf, _ctx, acc), do: Enum.reverse(acc)

  defp walk(<<q, rest::binary>>, stack, buf, ctx, acc) when q in [?", ?'] do
    {str, rest} = take_string(rest, q, <<q>>)
    walk(rest, stack, buf <> str, ctx, acc)
  end

  defp walk("{" <> rest, stack, buf, ctx, acc) do
    prelude =
      buf
      |> String.split(~r/[;}]/)
      |> List.last()
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    walk(rest, [{prelude, ctx, false} | mark_parent(stack)], "", ctx ++ [prelude], acc)
  end

  defp walk("}" <> rest, [{prelude, ctx, has_child} | stack], buf, _ctx, acc) do
    acc = if has_child, do: acc, else: [%{context: ctx, selector: prelude, body: buf} | acc]
    walk(rest, stack, "", ctx, acc)
  end

  defp walk(<<c::utf8, rest::binary>>, stack, buf, ctx, acc),
    do: walk(rest, stack, buf <> <<c::utf8>>, ctx, acc)

  defp mark_parent([{p, c, _} | rest]), do: [{p, c, true} | rest]
  defp mark_parent([]), do: []

  defp take_string(<<q, rest::binary>>, q, acc), do: {acc <> <<q>>, rest}

  defp take_string(<<"\\", c, rest::binary>>, q, acc),
    do: take_string(rest, q, acc <> <<"\\", c>>)

  defp take_string(<<c, rest::binary>>, q, acc), do: take_string(rest, q, acc <> <<c>>)
  defp take_string("", _q, acc), do: {acc, ""}
end
