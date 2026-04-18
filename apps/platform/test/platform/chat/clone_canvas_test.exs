defmodule Platform.Chat.CloneCanvasTest do
  use Platform.DataCase, async: false

  alias Platform.Chat

  defp make_space(name_suffix \\ nil) do
    suffix = name_suffix || "#{System.unique_integer([:positive])}"

    {:ok, space} =
      Chat.create_space(%{
        name: "Clone Test #{suffix}",
        slug: "clone-test-#{suffix}",
        kind: "channel"
      })

    space
  end

  defp make_participant(space_id) do
    {:ok, participant} =
      Chat.add_participant(space_id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Actor",
        joined_at: DateTime.utc_now()
      })

    participant
  end

  defp rich_document do
    %{
      "version" => 1,
      "revision" => 7,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "card-1",
            "type" => "card",
            "props" => %{"title" => "Overview"},
            "children" => [
              %{
                "id" => "text-1",
                "type" => "text",
                "props" => %{"value" => "Hello"},
                "children" => []
              }
            ]
          }
        ]
      },
      "theme" => %{"tone" => "info"},
      "bindings" => %{},
      "meta" => %{"origin" => "test"}
    }
  end

  describe "clone_canvas/3" do
    test "clones a canvas into a different space with fresh ids and reset revision" do
      source_space = make_space("source")
      target_space = make_space("target")
      source_participant = make_participant(source_space.id)
      target_participant = make_participant(target_space.id)

      {:ok, source_canvas} =
        Chat.create_canvas(%{
          "space_id" => source_space.id,
          "created_by" => source_participant.id,
          "title" => "Source",
          "document" => rich_document()
        })

      assert {:ok, cloned} =
               Chat.clone_canvas(source_canvas.id, target_space.id, target_participant.id)

      assert cloned.space_id == target_space.id
      assert cloned.created_by == target_participant.id
      assert cloned.cloned_from == source_canvas.id
      assert cloned.title == "Source"
      assert cloned.id != source_canvas.id

      # Document structure is preserved
      assert cloned.document["theme"]["tone"] == "info"
      assert cloned.document["meta"]["origin"] == "test"

      [card] = cloned.document["root"]["children"]
      assert card["type"] == "card"
      assert card["props"]["title"] == "Overview"

      [text] = card["children"]
      assert text["type"] == "text"
      assert text["props"]["value"] == "Hello"

      # Node ids are regenerated (except root)
      assert cloned.document["root"]["id"] == "root"
      refute card["id"] == "card-1"
      refute text["id"] == "text-1"

      # Revision reset to 1
      assert cloned.document["revision"] == 1
    end

    test "source canvas is untouched after cloning" do
      source_space = make_space("src2")
      target_space = make_space("tgt2")
      source_participant = make_participant(source_space.id)

      {:ok, source_canvas} =
        Chat.create_canvas(%{
          "space_id" => source_space.id,
          "created_by" => source_participant.id,
          "title" => "Original",
          "document" => rich_document()
        })

      {:ok, _clone} =
        Chat.clone_canvas(source_canvas.id, target_space.id, source_participant.id)

      reloaded = Chat.get_canvas(source_canvas.id)
      assert reloaded.id == source_canvas.id
      assert reloaded.space_id == source_space.id
      [card] = reloaded.document["root"]["children"]
      assert card["id"] == "card-1"
    end

    test "returns :source_not_found for missing source" do
      space = make_space("missing-source")
      participant = make_participant(space.id)

      assert {:error, :source_not_found} =
               Chat.clone_canvas(Ecto.UUID.generate(), space.id, participant.id)
    end
  end
end
