defmodule Platform.Design.ThreadReplySelectionGuardTest do
  @moduledoc """
  Holds the phone selection rules on chat messages (task 01a1a74e, stage 2,
  Isaac Summers' report that thread reply text could not be selected and the
  highlight landed in the wrong place on iOS).

  Below 64rem, app.css turns native selection and the touch callout OFF on
  every message (`[phx-hook="MessageGestures"]`), because the hook owns
  press-and-hold there. Inline thread replies render inside the parent's
  hooked root and inherited that, so the only selectable thing in an open
  thread was the reply box. Thread reply BODIES are now the exception.

  The guard reads app.css from disk (as the other guards in this directory
  do), walks it into leaf rules with their enclosing at-rules, and asserts:

    1. inside `@media (width < 64rem)`, the rule
       `[phx-hook="MessageGestures"] .thread-reply .msg-text` sets both
       `-webkit-user-select` and `user-select` to `text`;
    2. the `[phx-hook="MessageGestures"]` rule in that block still sets
       `-webkit-touch-callout`, `-webkit-user-select` and `user-select` to
       `none` (main view unchanged);
    3. no rule anywhere sets `user-select: text` on `.msg-header`, or on the
       whole `.thread-reply`, so a selection cannot start on or spill into
       the sender name, AI badge or time.
  """
  use ExUnit.Case, async: true

  @app_css_path Path.expand("../../../assets/css/app.css", __DIR__)
  @phone "@media (width < 64rem)"
  @hook ~s([phx-hook="MessageGestures"])
  @reply_body ~s([phx-hook="MessageGestures"] .thread-reply .msg-text)

  setup_all do
    {:ok, rules: @app_css_path |> File.read!() |> strip_comments() |> rules()}
  end

  test "(1) a thread reply's body is selectable on a phone", %{rules: rules} do
    matches = for r <- rules, @phone in r.context, @reply_body in parts(r.selector), do: r

    assert matches != [],
           "no `#{@reply_body}` rule inside `#{@phone}` in app.css"

    for r <- matches do
      decls = declarations(r.body)
      assert decls["-webkit-user-select"] == "text", inspect(r)
      assert decls["user-select"] == "text", inspect(r)
    end
  end

  test "(2) top-level messages keep native selection and the callout off on a phone",
       %{rules: rules} do
    matches = for r <- rules, @phone in r.context, parts(r.selector) == [@hook], do: r

    assert matches != [], "no bare `#{@hook}` rule inside `#{@phone}` in app.css"

    assert Enum.any?(matches, fn r ->
             decls = declarations(r.body)

             decls["-webkit-touch-callout"] == "none" and
               decls["-webkit-user-select"] == "none" and decls["user-select"] == "none"
           end),
           "the `#{@hook}` phone rule no longer turns selection and the callout off: " <>
             inspect(matches)
  end

  test "(3) no selectable rule reaches the reply header or the whole reply",
       %{rules: rules} do
    offenders =
      for r <- rules,
          decls = declarations(r.body),
          "text" in [decls["user-select"], decls["-webkit-user-select"]],
          part <- parts(r.selector),
          last = part |> String.split(~r/\s*[>+~]\s*|\s+/) |> List.last(),
          String.contains?(last, ".msg-header") or
            Regex.match?(~r/\.thread-reply(?![-\w])/, last),
          do: {r.context, part}

    assert offenders == [],
           "user-select: text reaches the reply header or the whole reply: #{inspect(offenders)}"
  end

  test "the walker sees the phone block at all (guards the guard)", %{rules: rules} do
    assert Enum.count(rules, &(@phone in &1.context)) > 1
  end

  defp parts(selector),
    do: selector |> String.split(",") |> Enum.map(&String.trim/1)

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
