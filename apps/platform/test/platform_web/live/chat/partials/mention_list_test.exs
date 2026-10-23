defmodule PlatformWeb.ChatLive.Partials.MentionListTest do
  @moduledoc """
  The in-flow @mention list (redesign rung 10, stage 3; direction canvas
  01a16233, prototype 01a137f2 `.mention-strip`).

  Rendered on its own, so every case reads the component's markup and
  nothing else: order, the not-in-space line, the empty row, the live
  region, the listbox/option ids the field's ARIA names, and the classes
  that would turn it back into a floating card.
  """
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.ChatLive.Partials.MentionList

  defp person(name),
    do: %{
      name: name,
      display_name: name,
      participant_type: "user",
      avatar_url: nil,
      avatar_seed: name,
      not_in_space: false
    }

  defp agent(name, not_in_space \\ false),
    do: %{
      name: name,
      display_name: name,
      participant_type: "agent",
      avatar_url: nil,
      avatar_seed: name,
      not_in_space: not_in_space
    }

  defp here,
    do: %{
      name: "here",
      display_name: "here",
      participant_type: "broadcast",
      avatar_url: nil,
      avatar_seed: nil,
      not_in_space: false
    }

  defp render_list(suggestions, query \\ nil, open \\ true) do
    assigns = %{suggestions: suggestions, query: query, open: open}

    ~H"""
    <MentionList.mention_list
      id="compose-mention-list"
      suggestions={@suggestions}
      query={@query}
      field_id="compose_text"
      open={@open}
    />
    """
    |> rendered_to_string()
    |> LazyHTML.from_fragment()
  end

  defp q(doc, selector), do: LazyHTML.query(doc, selector)
  defp count(doc, selector), do: doc |> q(selector) |> Enum.count()

  defp names(doc) do
    doc
    |> q("[role=option][data-mention-name]")
    |> Enum.map(fn row -> row |> LazyHTML.attribute("data-mention-name") |> hd() end)
  end

  defp text(doc, selector) do
    doc |> q(selector) |> LazyHTML.text() |> String.replace(~r/\s+/, " ") |> String.trim()
  end

  test "renders agents before people, and here last" do
    doc =
      render_list([
        person("Design Lead"),
        here(),
        agent("Reviewer"),
        person("Ops Lead"),
        agent("Builder")
      ])

    assert names(doc) == ["Reviewer", "Builder", "Design Lead", "Ops Lead", "here"]
  end

  test "is a listbox with numbered option ids, the first highlighted" do
    doc = render_list([agent("Builder"), person("Design Lead")])

    assert count(doc, ~s([data-role="mention-list"] #compose-mention-list[role=listbox])) == 1
    assert count(doc, ~s(#compose-mention-list[aria-label="Mention suggestions"])) == 1

    assert count(doc, "#compose-mention-list > #compose-mention-list-opt-0[role=option]") == 1
    assert count(doc, "#compose-mention-list > #compose-mention-list-opt-1[role=option]") == 1
    assert count(doc, "#compose-mention-list-opt-0[aria-selected=true]") == 1
    assert count(doc, "#compose-mention-list-opt-1[aria-selected=false]") == 1

    # The first row keeps the marker earlier composer tests read.
    assert count(doc, ~s(#compose-mention-list-opt-0[data-mention-suggestion="first"])) == 1
  end

  test "a row's click dispatches chat:insert-mention on the field with the name" do
    doc = render_list([agent("Builder")])
    [click] = doc |> q("#compose-mention-list-opt-0") |> LazyHTML.attribute("phx-click")

    assert click =~ "chat:insert-mention"
    assert click =~ "#compose_text"
    assert click =~ ~s("name":"Builder")
  end

  test "rows carry the kind pill, never a role line or section header" do
    doc = render_list([agent("Builder"), person("Design Lead")])

    assert text(doc, "#compose-mention-list-opt-0 .mention-list-name") == "Builder"
    assert text(doc, "#compose-mention-list-opt-0 .mention-list-kind") == "agent"
    assert text(doc, "#compose-mention-list-opt-1 .mention-list-kind") == "person"
    assert count(doc, "#compose-mention-list-opt-0 [data-avatar-kind=agent]") == 1

    refute LazyHTML.text(doc) =~ ~r/\bAgents\b|\bPeople\b/
  end

  test "an addable agent says it is not in this space; an in-space agent does not" do
    doc = render_list([agent("Builder"), agent("Scout", true)])

    assert text(doc, "#compose-mention-list-opt-1 .mention-list-note") ==
             "Not in this space · adds them"

    assert count(doc, "#compose-mention-list-opt-0 .mention-list-note") == 0
  end

  # Gate case 7005/7009 (stage 5): at 393px the note shared the name's line
  # and ellipsized ("Not in this space · adds the…"), and in the ~221px
  # phone thread list read "N..". The note is the row's SECOND line (canvas
  # 01a16233 rule "Not in this space"): a sibling of the name line, never
  # inside it.
  test "the not-in-space note is a line of its own under the name, not on the name's line" do
    doc = render_list([agent("Northwind Scout", true)])
    row = "#compose-mention-list-opt-0"

    assert count(doc, "#{row} > .mention-list-text > .mention-list-line > .mention-list-name") ==
             1

    assert count(doc, "#{row} > .mention-list-text > .mention-list-line > .mention-list-kind") ==
             1

    assert count(doc, "#{row} > .mention-list-text > .mention-list-note") == 1
    assert count(doc, "#{row} .mention-list-line .mention-list-note") == 0
    assert count(doc, "#{row} > .mention-list-note") == 0

    # The note follows the name line, so it paints under it.
    kids =
      doc
      |> q("#{row} > .mention-list-text > *")
      |> Enum.map(&(&1 |> LazyHTML.attribute("class") |> hd()))

    assert kids == ["mention-list-line", "mention-list-note"]
  end

  # The stylesheet half of the same case: a note that is a line of its own
  # but still `nowrap` + `ellipsis` truncates again in the thread list, and a
  # row with a fixed `height` clips the second line.
  test "the note wraps and never ellipsizes; a row grows to fit it" do
    rules =
      Path.expand("../../../../../assets/css/app.css", __DIR__)
      |> File.read!()
      |> Platform.Design.CssRules.rules()

    decl = fn sel, prop ->
      for r <- rules,
          r.selector == sel,
          [v] <-
            Regex.scan(~r/(?:^|[;{])\s*#{prop}\s*:\s*([^;]+);/m, r.body, capture: :all_but_first),
          do: String.trim(v)
    end

    assert decl.(".mention-list-note", "white-space") == ["normal"]
    assert decl.(".mention-list-note", "text-overflow") == []
    assert decl.(".mention-list-note", "overflow") == []

    # min-height, never height: 50px phone, 40px desktop for a one-line row.
    assert decl.(".mention-list-row", "height") == []
    assert decl.(".mention-list-row", "min-height") == ["50px", "40px"]

    # The text column takes the row's remaining width (so a long name, not
    # the note, is what gives way).
    assert decl.(".mention-list-text", "flex-direction") == ["column"]
    assert decl.(".mention-list-text", "min-width") == ["0"]
  end

  test "here notifies everyone, with a megaphone and no warning ink" do
    doc = render_list([here()])

    assert text(doc, "#compose-mention-list-opt-0 .mention-list-name") == "here"

    assert text(doc, "#compose-mention-list-opt-0 .mention-list-note") ==
             "Notify everyone in the channel"

    assert count(doc, "#compose-mention-list-opt-0 .hero-megaphone") == 1
    refute doc |> q("#compose-mention-list") |> LazyHTML.to_html() =~ "warning"
  end

  test "an empty filter renders one disabled row naming the query" do
    doc = render_list([], "xyz")

    assert count(doc, "[role=option]:not([aria-disabled])") == 0

    assert count(
             doc,
             ~s(#compose-mention-list > [data-role="mention-list-empty"][role=option][aria-disabled=true])
           ) == 1

    assert text(doc, ~s([data-role="mention-list-empty"])) == "No one matches “xyz”"
    assert text(doc, ~s([data-role="mention-list-status"])) == "No one matches"
  end

  test "closed, only the wrapper and its empty live region render" do
    doc = render_list([agent("Builder")], nil, false)
    assert count(doc, ~s([data-role="mention-list"].mention-list)) == 1
    assert count(doc, ~s([data-role="mention-list"] > *)) == 1
    assert count(doc, ~s([data-role="mention-list"] > [data-role="mention-list-status"])) == 1
    assert text(doc, ~s([data-role="mention-list-status"])) == ""
    assert count(doc, "[role=listbox], [role=option]") == 0
  end

  test "the wrapper carries a stable id, open or closed (its morph key)" do
    for open <- [true, false] do
      doc = render_list([agent("Builder")], nil, open)
      assert count(doc, ~s(#compose-mention-list-wrap[data-role="mention-list"])) == 1
    end
  end

  test "no query and no suggestions renders no empty row" do
    doc = render_list([], nil)
    assert count(doc, ~s([data-role="mention-list-empty"])) == 0
    refute MentionList.open?([], nil)
    assert MentionList.open?([], "")
    assert MentionList.open?([agent("Builder")], nil)
  end

  test "a polite, screen-reader-only live region counts agents and people, pluralised" do
    doc = render_list([agent("A"), agent("B"), agent("C"), agent("D"), person("Design Lead")])

    assert count(doc, ~s([data-role="mention-list-status"].sr-only[aria-live=polite])) == 1
    assert text(doc, ~s([data-role="mention-list-status"])) == "4 agents, 1 person"

    # The live region is outside the listbox: a listbox holds options only.
    assert count(doc, ~s(#compose-mention-list [data-role="mention-list-status"])) == 0

    assert MentionList.status_text([agent("A")]) == "1 agent"
    assert MentionList.status_text([person("A"), person("B")]) == "2 people"
    assert MentionList.status_text([agent("A"), here()]) == "1 agent, here"
  end

  test "the list is in flow and flat: no absolute, no shadow, no hover: in any class" do
    doc =
      render_list([agent("Builder"), agent("Scout", true), person("Design Lead"), here()], "d")

    classes =
      doc
      |> q("[class]")
      |> Enum.flat_map(&LazyHTML.attribute(&1, "class"))

    assert classes != []

    for class <- classes do
      refute class =~ "absolute", "#{class} positions the list out of flow"
      refute class =~ "shadow", "#{class} floats the list as a card"
      refute class =~ "hover:", "#{class} paints hover with a utility; hover is CSS-only"
      refute class =~ "fixed", "#{class} positions the list out of flow"
    end

    # Pressed paint is the `active:` utility on the row, base-100 like the
    # highlight.
    assert count(doc, "#compose-mention-list-opt-0.mention-list-row.active\\:bg-base-100") == 1
  end
end
