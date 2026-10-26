defmodule PlatformWeb.Components.ReplyQuoteClampTest do
  @moduledoc """
  The reply quote's two-line excerpt clamp (task 01a174f5 fix stage).

  Tailwind's `line-clamp-2` works by setting `display: -webkit-box`. A display
  utility in the same class list (`block`, `flex`, `grid`, `inline-block`, ...)
  is emitted later at the same specificity and wins, so the clamp silently
  stops applying: the stage 3 gate measured `display: block` and a four-line
  excerpt. A presence test (`[data-role=...].line-clamp-2`) cannot see that,
  because the class IS present. These tests assert the ABSENCE of the
  overriding class instead, on the helper, on the rendered markup, and on the
  source of every module that renders a reply quote.

  Mutation: re-adding `block` to the clamped excerpt turns this file red.
  """

  use ExUnit.Case, async: true
  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest

  alias PlatformWeb.Components.ReplyQuote

  @display ReplyQuote.display_utilities()

  @quote %{
    status: :visible,
    message_id: "01a17500-0000-7000-8000-000000000001",
    author: "Member",
    at: nil,
    preview: String.duplicate("a long reply that wraps across many lines ", 12)
  }

  # Every module that renders `ReplyQuote.reply_quote/1` or owns its classes.
  @sources [
    "lib/platform_web/components/reply_quote.ex",
    "lib/platform_web/components/chat_message.ex",
    "lib/platform_web/live/chat/partials/composer.ex",
    "lib/platform_web/live/chat/partials/message_context.ex"
  ]

  defp preview_classes(clamp) do
    assigns = %{quote: @quote, clamp: clamp}

    html =
      rendered_to_string(~H"""
      <ReplyQuote.reply_quote quote={@quote} clamp={@clamp} />
      """)

    [node] =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(~s([data-role="reply-quote-preview"]))
      |> Enum.to_list()

    node |> LazyHTML.attribute("class") |> List.first() |> String.split()
  end

  test "the clamped helper list carries line-clamp-2 and no display utility" do
    classes = ReplyQuote.preview_class(true)
    assert "line-clamp-2" in classes
    assert Enum.filter(classes, &(&1 in @display)) == []
  end

  test "the unclamped helper list (the Answering panel) is block and unclamped" do
    classes = ReplyQuote.preview_class(false)
    assert "block" in classes
    refute Enum.any?(classes, &String.starts_with?(&1, "line-clamp"))
  end

  test "the rendered clamped excerpt has line-clamp-2 and no display utility beside it" do
    classes = preview_classes(true)
    assert "line-clamp-2" in classes
    assert Enum.filter(classes, &(&1 in @display)) == [], inspect(classes)
  end

  test "the rendered unclamped excerpt stays full height" do
    classes = preview_classes(false)
    refute "line-clamp-2" in classes
    assert "block" in classes
  end

  test "no class literal in a reply-quote module pairs line-clamp with a display utility" do
    offenders =
      for path <- @sources,
          literal <- Regex.scan(~r/"([^"\n]*line-clamp-\d[^"\n]*)"/, File.read!(path)),
          tokens = literal |> List.last() |> String.split(),
          Enum.any?(tokens, &(&1 in @display)) do
        {path, List.last(literal)}
      end

    assert offenders == [],
           "a display utility beside line-clamp overrides display:-webkit-box: " <>
             inspect(offenders)
  end
end
