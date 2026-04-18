defmodule Platform.Chat.Canvas.ServerTest do
  use Platform.DataCase, async: false

  alias Platform.Chat
  alias Platform.Chat.Canvas.Server, as: CanvasServer
  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.PubSub, as: ChatPubSub

  defp setup_space_and_participant do
    {:ok, space} =
      Chat.create_space(%{
        name: "Canvas Server Test",
        slug: "cs-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Author",
        joined_at: DateTime.utc_now()
      })

    %{space: space, participant: participant}
  end

  defp create_canvas(space_id, participant_id, overrides \\ %{}) do
    attrs =
      Map.merge(
        %{
          "space_id" => space_id,
          "created_by" => participant_id,
          "title" => "Test"
        },
        overrides
      )

    {:ok, canvas} = Chat.create_canvas(attrs)
    canvas
  end

  setup do
    ctx = setup_space_and_participant()
    canvas = create_canvas(ctx.space.id, ctx.participant.id)

    on_exit(fn -> CanvasServer.stop(canvas.id) end)

    Map.put(ctx, :canvas, canvas)
  end

  describe "apply_patches/3 at head" do
    test "applies a valid patch and bumps revision", %{canvas: canvas} do
      child = %{
        "id" => "t1",
        "type" => "text",
        "props" => %{"value" => "Hello"},
        "children" => []
      }

      assert {:ok, 2} =
               CanvasServer.apply_patches(canvas.id, [{:append_child, "root", child}], 1)

      assert {:ok, %{revision: 2, document: doc}} = CanvasServer.describe(canvas.id)
      assert [%{"id" => "t1"}] = doc["root"]["children"]
    end

    test "applies multiple ops in a single call", %{canvas: canvas} do
      ops = [
        {:append_child, "root",
         %{"id" => "t1", "type" => "text", "props" => %{"value" => "A"}, "children" => []}},
        {:append_child, "root",
         %{"id" => "t2", "type" => "text", "props" => %{"value" => "B"}, "children" => []}}
      ]

      assert {:ok, 2} = CanvasServer.apply_patches(canvas.id, ops, 1)
      assert {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      assert length(doc["root"]["children"]) == 2
    end
  end

  describe "apply_patches/3 with rebase" do
    test "rebases when target still exists", %{canvas: canvas} do
      child = %{
        "id" => "t1",
        "type" => "text",
        "props" => %{"value" => "first"},
        "children" => []
      }

      assert {:ok, 2} =
               CanvasServer.apply_patches(canvas.id, [{:append_child, "root", child}], 1)

      # Stale caller still sees rev=1 but the target "root" still exists.
      assert {:ok, 3} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:set_props, "t1", %{"value" => "second"}}],
                 1
               )

      assert {:ok, %{document: doc}} = CanvasServer.describe(canvas.id)
      assert CanvasDocument.get_node(doc, "t1")["props"]["value"] == "second"
    end

    test "rejects when target was deleted in between", %{canvas: canvas} do
      child = %{
        "id" => "t1",
        "type" => "text",
        "props" => %{"value" => "here"},
        "children" => []
      }

      {:ok, 2} =
        CanvasServer.apply_patches(canvas.id, [{:append_child, "root", child}], 1)

      {:ok, 3} = CanvasServer.apply_patches(canvas.id, [{:delete_node, "t1"}], 2)

      # Stale caller still at rev=2 tries to patch the deleted node.
      assert {:conflict, payload} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:set_props, "t1", %{"value" => "late"}}],
                 2
               )

      assert payload.reason == :target_deleted
      assert payload.offending_node_id == "t1"
      assert payload.current_revision == 3
    end

    test "rejects when base_revision is ahead of current", %{canvas: canvas} do
      assert {:conflict, payload} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:set_props, "root", %{"gap" => 24}}],
                 99
               )

      assert payload.reason == :too_stale
      assert payload.current_revision == 1
    end
  end

  describe "rejection classification" do
    test "illegal child rule becomes :illegal_child", %{canvas: canvas} do
      # checklist only accepts checklist_item children
      {:ok, 2} =
        CanvasServer.apply_patches(
          canvas.id,
          [{:set_props, "root", %{}}],
          1
        )

      {:ok, 3} =
        CanvasServer.apply_patches(
          canvas.id,
          [
            {:replace_document,
             %{
               "version" => 1,
               "revision" => 1,
               "root" => %{
                 "id" => "root",
                 "type" => "checklist",
                 "props" => %{},
                 "children" => []
               },
               "theme" => %{},
               "bindings" => %{},
               "meta" => %{}
             }}
          ],
          2
        )

      bad_child = %{
        "id" => "bad",
        "type" => "text",
        "props" => %{"value" => "nope"},
        "children" => []
      }

      assert {:conflict, payload} =
               CanvasServer.apply_patches(
                 canvas.id,
                 [{:append_child, "root", bad_child}],
                 3
               )

      assert payload.reason == :illegal_child
    end
  end

  describe "PubSub broadcast" do
    test "broadcasts :canvas_patched on the canvas topic", %{canvas: canvas} do
      ChatPubSub.subscribe_canvas(canvas.id)

      child = %{
        "id" => "t1",
        "type" => "text",
        "props" => %{"value" => "Hi"},
        "children" => []
      }

      {:ok, 2} = CanvasServer.apply_patches(canvas.id, [{:append_child, "root", child}], 1)

      assert_receive {:canvas_patched, canvas_id, 2, ops}, 1_000
      assert canvas_id == canvas.id
      assert [{:append_child, "root", _}] = ops
    end
  end

  describe "describe/1" do
    test "returns current document and revision", %{canvas: canvas} do
      assert {:ok, %{document: %{"root" => _}, revision: 1}} = CanvasServer.describe(canvas.id)
    end
  end

  describe "emit_event/2" do
    test "broadcasts a canvas event without mutating the document", %{canvas: canvas} do
      ChatPubSub.subscribe_canvas(canvas.id)
      :ok = CanvasServer.emit_event(canvas.id, %{"name" => "clicked", "node_id" => "button-1"})

      assert_receive {:canvas_event, canvas_id, %{"name" => "clicked"}}, 1_000
      assert canvas_id == canvas.id
    end
  end
end
