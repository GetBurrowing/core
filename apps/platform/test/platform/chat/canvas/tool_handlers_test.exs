defmodule Platform.Chat.Canvas.ToolHandlersTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas.ToolHandlers
  alias Platform.Chat.Canvas.Server, as: CanvasServer

  defp setup_space do
    {:ok, space} =
      Chat.create_space(%{
        name: "Tool Handlers Test",
        slug: "th-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: Ecto.UUID.generate(),
        display_name: "Tester",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp valid_document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 12},
        "children" => [
          %{
            "id" => "h",
            "type" => "heading",
            "props" => %{"value" => "Hello", "level" => 2},
            "children" => []
          }
        ]
      },
      "theme" => %{},
      "bindings" => %{},
      "meta" => %{}
    }
  end

  describe "canvas.create" do
    test "creates a canvas from a valid document" do
      %{space: space, participant: participant} = setup_space()

      args = %{
        "space_id" => space.id,
        "title" => "Created via tool",
        "document" => valid_document()
      }

      context = %{agent_participant_id: participant.id}

      assert {:ok, result} = ToolHandlers.create(args, context)
      assert is_binary(result.canvas_id)
      assert result.kind == "stack"
      assert result.revision == 1

      on_exit(fn -> CanvasServer.stop(result.canvas_id) end)
    end

    test "rejects when document is missing" do
      %{space: space, participant: participant} = setup_space()

      assert {:error, payload} =
               ToolHandlers.create(
                 %{"space_id" => space.id},
                 %{agent_participant_id: participant.id}
               )

      assert payload.recoverable == true
      assert payload.error =~ "document"
    end

    test "auto-fills version/revision/root.id on a minimal agent-emitted doc" do
      %{space: space, participant: participant} = setup_space()

      minimal_doc = %{
        "root" => %{
          "type" => "stack",
          "children" => [
            %{
              "type" => "text",
              "props" => %{"value" => "hello"}
            }
          ]
        }
      }

      args = %{"space_id" => space.id, "title" => "minimal", "document" => minimal_doc}
      context = %{agent_participant_id: participant.id}

      assert {:ok, result} = ToolHandlers.create(args, context)
      assert result.kind == "stack"
      assert result.revision == 1

      {:ok, %{document: doc}} = Platform.Chat.Canvas.Server.describe(result.canvas_id)
      assert doc["version"] == 1
      assert doc["root"]["id"] == "root"
      [text] = doc["root"]["children"]
      assert is_binary(text["id"]) and text["id"] != ""

      on_exit(fn -> Platform.Chat.Canvas.Server.stop(result.canvas_id) end)
    end

    test "accepts a stringified document (MCP client stringification fallback)" do
      %{space: space, participant: participant} = setup_space()

      stringified_doc = Jason.encode!(valid_document())

      args = %{
        "space_id" => space.id,
        "title" => "stringy doc",
        "document" => stringified_doc
      }

      context = %{agent_participant_id: participant.id}

      assert {:ok, result} = ToolHandlers.create(args, context)
      assert result.kind == "stack"

      on_exit(fn -> Platform.Chat.Canvas.Server.stop(result.canvas_id) end)
    end

    test "rejects an invalid document with recoverable=true" do
      %{space: space, participant: participant} = setup_space()

      bad_doc = Map.put(valid_document(), "version", "bogus")

      assert {:error, payload} =
               ToolHandlers.create(
                 %{"space_id" => space.id, "document" => bad_doc},
                 %{agent_participant_id: participant.id}
               )

      assert payload.recoverable == true
      assert payload.error =~ "document invalid"
    end
  end

  describe "canvas.describe" do
    test "returns the current document and revision" do
      %{space: space, participant: participant} = setup_space()

      {:ok, %{canvas_id: canvas_id}} =
        ToolHandlers.create(
          %{"space_id" => space.id, "document" => valid_document()},
          %{agent_participant_id: participant.id}
        )

      on_exit(fn -> CanvasServer.stop(canvas_id) end)

      assert {:ok, payload} =
               ToolHandlers.describe(%{"canvas_id" => canvas_id}, %{})

      assert payload.canvas_id == canvas_id
      assert payload.revision == 1
      assert payload.document["root"]["type"] == "stack"
      assert payload.presence == %{viewing: [], editing: []}
    end

    test "returns error for missing canvas" do
      assert {:error, payload} =
               ToolHandlers.describe(%{"canvas_id" => Ecto.UUID.generate()}, %{})

      assert payload.error =~ "not found"
      assert payload.recoverable == false
    end
  end

  describe "canvas.patch" do
    test "applies valid operations and bumps revision" do
      %{space: space, participant: participant} = setup_space()

      {:ok, %{canvas_id: canvas_id}} =
        ToolHandlers.create(
          %{"space_id" => space.id, "document" => valid_document()},
          %{agent_participant_id: participant.id}
        )

      on_exit(fn -> CanvasServer.stop(canvas_id) end)

      child = %{
        "id" => "new",
        "type" => "text",
        "props" => %{"value" => "fresh"},
        "children" => []
      }

      assert {:ok, payload} =
               ToolHandlers.patch(
                 %{
                   "canvas_id" => canvas_id,
                   "base_revision" => 1,
                   "operations" => [["append_child", "root", child]]
                 },
                 %{}
               )

      assert payload.revision == 2
    end

    test "returns structured conflict on stale revision after deletion" do
      %{space: space, participant: participant} = setup_space()

      {:ok, %{canvas_id: canvas_id}} =
        ToolHandlers.create(
          %{"space_id" => space.id, "document" => valid_document()},
          %{agent_participant_id: participant.id}
        )

      on_exit(fn -> CanvasServer.stop(canvas_id) end)

      # Delete the heading at revision 1, then try to patch it from rev 1.
      {:ok, _} =
        ToolHandlers.patch(
          %{
            "canvas_id" => canvas_id,
            "base_revision" => 1,
            "operations" => [["delete_node", "h"]]
          },
          %{}
        )

      assert {:error, payload} =
               ToolHandlers.patch(
                 %{
                   "canvas_id" => canvas_id,
                   "base_revision" => 1,
                   "operations" => [["set_props", "h", %{"value" => "late"}]]
                 },
                 %{}
               )

      assert payload.recoverable == true
      assert payload.conflict.reason == :target_deleted
      assert payload.suggestion =~ "canvas.describe"
    end

    test "accepts stringified operation args (MCP stringification fallback)" do
      %{space: space, participant: participant} = setup_space()

      {:ok, %{canvas_id: canvas_id}} =
        ToolHandlers.create(
          %{"space_id" => space.id, "document" => valid_document()},
          %{agent_participant_id: participant.id}
        )

      on_exit(fn -> Platform.Chat.Canvas.Server.stop(canvas_id) end)

      stringified_child =
        Jason.encode!(%{
          "id" => "fresh",
          "type" => "text",
          "props" => %{"value" => "hi"},
          "children" => []
        })

      assert {:ok, payload} =
               ToolHandlers.patch(
                 %{
                   "canvas_id" => canvas_id,
                   "base_revision" => 1,
                   "operations" => [["append_child", "root", stringified_child]]
                 },
                 %{}
               )

      assert payload.revision == 2
    end

    test "rejects unrecognized operation shapes" do
      %{space: space, participant: participant} = setup_space()

      {:ok, %{canvas_id: canvas_id}} =
        ToolHandlers.create(
          %{"space_id" => space.id, "document" => valid_document()},
          %{agent_participant_id: participant.id}
        )

      on_exit(fn -> CanvasServer.stop(canvas_id) end)

      assert {:error, payload} =
               ToolHandlers.patch(
                 %{
                   "canvas_id" => canvas_id,
                   "base_revision" => 1,
                   "operations" => [["upsert_node", "whatever"]]
                 },
                 %{}
               )

      assert payload.recoverable == true
      assert payload.error =~ "unrecognized"
    end
  end
end
