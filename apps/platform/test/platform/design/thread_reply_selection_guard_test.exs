defmodule Platform.Design.ThreadReplySelectionGuardTest do
  @moduledoc """
  Holds the phone selection rules on chat messages, thread replies included
  (task 01a1a74e, Isaac Summers' report that thread reply text had no Copy
  and the selection highlight landed in the wrong place on iOS).

  Below 64rem, app.css turns native selection and the touch callout OFF on
  every message (`[phx-hook="MessageGestures"]`), because the hook owns
  press-and-hold there; Copy text in the actions sheet replaces native
  selection. Inline thread replies render inside the parent's hooked root
  and inherit that ON PURPOSE (option A, chosen by the task owner after the
  stage 2 measurement): with reply bodies made selectable, an iOS 27 hold
  never selected the reply's text (the 450ms long-press opens the sheet
  first) and iOS then selected whatever the sheet put under the finger, a
  quick-react emoji with the native edit menu, which is the wrong-place
  highlight again.

  The guard reads app.css from disk (as the other guards in this directory
  do), walks it into leaf rules with their enclosing at-rules, and asserts:

    1. the `[phx-hook="MessageGestures"]` rule inside `@media (width <
       64rem)` still sets `-webkit-touch-callout`, `-webkit-user-select` and
       `user-select` to `none`;
    2. inside that media query, the ONLY rule that turns selection back on
       under the hook is the field exception (`input`, `textarea`,
       `[contenteditable]`, which keeps the thread reply BOX editable):
       nothing re-enables it on a thread reply, its `.msg-text` or
       `.msg-header`, or a message body;
    3. no rule anywhere sets `user-select: text` on a `.thread-reply` or
       anything inside one, so a desktop-scoped rule cannot leak it either.
  """
  use ExUnit.Case, async: true

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @phone "@media (width < 64rem)"
  @hook ~s([phx-hook="MessageGestures"])
  @field_exception ~s{[phx-hook="MessageGestures"] :is(input, textarea, [contenteditable])}

  setup_all do
    {:ok, rules: @app_css_path |> File.read!() |> strip_comments() |> rules()}
  end

  test "(1) messages keep native selection and the callout off on a phone", %{rules: rules} do
    matches = for r <- rules, @phone in r.context, normalize(r.selector) == @hook, do: r

    assert matches != [], "no bare `#{@hook}` rule inside `#{@phone}` in app.css"

    assert Enum.any?(matches, fn r ->
             decls = declarations(r.body)

             decls["-webkit-touch-callout"] == "none" and
               decls["-webkit-user-select"] == "none" and decls["user-select"] == "none"
           end),
           "the `#{@hook}` phone rule no longer turns selection and the callout off: " <>
             inspect(matches)
  end

  test "(2) on a phone only the field exception re-enables selection under the hook",
       %{rules: rules} do
    reenabling =
      for r <- rules,
          @phone in r.context,
          String.contains?(r.selector, @hook),
          selectable?(r),
          do: normalize(r.selector)

    assert reenabling == [@field_exception],
           "expected only the field exception to re-enable selection under the hook " <>
             "below 64rem, got: #{inspect(reenabling)}"
  end

  test "(3) no rule makes a thread reply or anything inside it selectable", %{rules: rules} do
    offenders =
      for r <- rules,
          selectable?(r),
          Regex.match?(~r/\.thread-reply(?![-\w])/, r.selector),
          do: {r.context, normalize(r.selector)}

    assert offenders == [],
           "user-select: text reaches a thread reply: #{inspect(offenders)}"
  end

  test "the walker sees the phone block at all (guards the guard)", %{rules: rules} do
    assert Enum.count(rules, &(@phone in &1.context)) > 1
  end

  defp selectable?(rule) do
    decls = declarations(rule.body)
    "text" in [decls["user-select"], decls["-webkit-user-select"]]
  end

  defp normalize(selector), do: selector |> String.replace(~r/\s+/, " ") |> String.trim()

  defp declarations(body) do
    body
    |> String.split(";")
    |> Enum.flat_map(fn decl ->
      case String.split(decl, ":", parts: 2) do
        [prop, value] -> [{String.trim(prop), value |> String.trim() |> String.downcase()}]
        _ -> []
      end
    end)
    |> Map.new()
  end

  defp strip_comments(text), do: Regex.replace(~r{/\*.*?\*/}s, text, "")

  # Leaf rules of a comment-free stylesheet: %{context, selector, body}, where
  # context is the list of enclosing at-rule preludes (the walker of
  # bottom_nav_glass_guard_test.exs). A block that contains another block is a
  # container (an at-rule), not a rule.
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
