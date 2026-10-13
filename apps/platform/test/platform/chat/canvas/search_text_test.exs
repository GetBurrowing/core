defmodule Platform.Chat.Canvas.SearchTextTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Kinds
  alias Platform.Chat.Canvas.SearchText

  describe "extract/1 — registry-driven coverage guard" do
    # This is the guard that cannot silently stop guarding. It walks the WHOLE
    # kind registry, not a hand-picked list, and pins what each kind's own
    # registry example contributes to the search text:
    #
    #   :text   — real prose came out
    #   :marker — the output is nothing but `<!-- skipped: … -->` /
    #             `<!-- unknown-kind: … -->` comments
    #   :empty  — the output is empty
    #
    # `:empty` is not decoration. Four kinds' registry examples carry no text
    # payload at all: `stack`/`row`/`card` examples have no children (and the
    # card example has no title), and the `table` example has empty `columns`
    # and `rows`. Calling those `:text` would claim prose came out when none
    # did, and calling them `:marker` would claim a skip marker was emitted when
    # none was. Both would be false, and a false pin is exactly the kind of
    # quietly-wrong guard this ticket exists to avoid.
    #
    # `prototype` (task 01a1316b-4e46 stage 2) is the 17th: its text is a
    # bundle behind a URL, not document text, so it is a skipped marker.
    # Registering an 18th kind makes this map differ and this test fails until
    # somebody decides, in writing, whether the new kind carries text.
    test "every registered kind's classification is pinned" do
      expected = %{
        "stack" => :empty,
        "row" => :empty,
        "card" => :empty,
        "text" => :text,
        "markdown" => :text,
        "heading" => :text,
        "badge" => :text,
        "image" => :marker,
        "code" => :text,
        "mermaid" => :marker,
        "embed" => :marker,
        "form" => :marker,
        "action_row" => :marker,
        "checklist" => :text,
        "checklist_item" => :text,
        "table" => :empty,
        "prototype" => :marker
      }

      actual =
        Map.new(Kinds.summaries(), fn %{kind: kind, example: example} ->
          {kind, classify(SearchText.extract(document(example)))}
        end)

      # Reachability: the guard must actually have visited the whole registry.
      assert map_size(actual) == 17
      assert map_size(actual) == length(Kinds.all())

      assert actual == expected

      # The six kinds the exporter deliberately skips stay pinned as markers,
      # so the accepted indexing gap is a decision on the record.
      for skipped <- ~w(form action_row embed image mermaid prototype) do
        assert expected[skipped] == :marker
      end
    end
  end

  describe "extract/1 — breadth across text-carrying kinds" do
    test "every text-carrying prop of every handled kind reaches the output" do
      doc =
        document(%{
          "id" => "root",
          "type" => "stack",
          "props" => %{},
          "children" => [
            %{
              "id" => "c1",
              "type" => "card",
              "props" => %{"title" => "zorbling quimbat"},
              "children" => [
                %{
                  "id" => "h1",
                  "type" => "heading",
                  "props" => %{"level" => 2, "value" => "frimsy toadlark"}
                },
                %{
                  "id" => "t1",
                  "type" => "text",
                  "props" => %{"value" => "wumberton glissade"}
                },
                %{
                  "id" => "m1",
                  "type" => "markdown",
                  "props" => %{"content" => "narthex plimbo"}
                },
                %{
                  "id" => "b1",
                  "type" => "badge",
                  "props" => %{"value" => "quantar velish"}
                },
                %{
                  "id" => "co1",
                  "type" => "code",
                  "props" => %{"language" => "elixir", "source" => "snorbit clangwell"}
                }
              ]
            },
            %{
              "id" => "cl1",
              "type" => "checklist",
              "props" => %{"title" => "drumbly hexatone"},
              "children" => [
                %{
                  "id" => "cli1",
                  "type" => "checklist_item",
                  "props" => %{"label" => "vespine crumbolt"}
                }
              ]
            },
            %{
              "id" => "tb1",
              "type" => "table",
              "props" => %{
                "columns" => ["Ingredient"],
                "rows" => [%{"Ingredient" => "yarrow tundish"}]
              }
            }
          ]
        })

      out = SearchText.extract(doc)

      # Nine phrases, nine distinct prop keys on seven distinct kinds. Each
      # phrase is unique nonsense living at exactly one prop, so a passing
      # assertion cannot be satisfied incidentally by a sibling node's render.
      assert out =~ "zorbling quimbat", "card props.title missing"
      assert out =~ "frimsy toadlark", "heading props.value missing"
      assert out =~ "wumberton glissade", "text props.value missing"
      assert out =~ "narthex plimbo", "markdown props.content missing"
      assert out =~ "quantar velish", "badge props.value missing"
      assert out =~ "snorbit clangwell", "code props.source missing"
      assert out =~ "drumbly hexatone", "checklist props.title missing"
      assert out =~ "vespine crumbolt", "checklist_item props.label missing"
      assert out =~ "yarrow tundish", "table props.rows cell missing"

      # Contract: always a plain string, whatever the input shape.
      assert is_binary(SearchText.extract(%Canvas{document: doc}))
      assert SearchText.extract(%Canvas{document: doc}) == out
      assert SearchText.extract(nil) == ""
      assert SearchText.extract(%{"garbage" => true}) == ""
    end
  end

  defp document(root), do: %{"version" => 1, "revision" => 1, "root" => root}

  defp classify(output) do
    trimmed = String.trim(output)

    cond do
      trimmed == "" ->
        :empty

      Regex.match?(~r/\A(?:<!--\s*(?:skipped|unknown-kind):[^>]*-->\s*)+\z/, trimmed) ->
        :marker

      true ->
        :text
    end
  end
end
