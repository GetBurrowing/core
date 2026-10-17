defmodule Platform.Chat.CanvasPatchTest do
  use ExUnit.Case, async: true

  alias Platform.Chat.CanvasDocument
  alias Platform.Chat.CanvasPatch

  defp base_doc do
    CanvasDocument.new()
    |> put_in(["root", "children"], [
      %{
        "id" => "text-1",
        "type" => "text",
        "props" => %{"value" => "Hello"},
        "children" => []
      },
      %{
        "id" => "card-1",
        "type" => "card",
        "props" => %{"title" => "My Card"},
        "children" => [
          %{
            "id" => "nested-text",
            "type" => "text",
            "props" => %{"value" => "Nested"},
            "children" => []
          }
        ]
      }
    ])
  end

  describe "apply/2 :set_props" do
    test "merges props into a node" do
      doc = base_doc()

      assert {:ok, updated} =
               CanvasPatch.apply(doc, {:set_props, "text-1", %{"weight" => "bold"}})

      node = CanvasDocument.get_node(updated, "text-1")
      assert node["props"]["value"] == "Hello"
      assert node["props"]["weight"] == "bold"
    end

    test "overwrites existing prop key" do
      doc = base_doc()

      assert {:ok, updated} =
               CanvasPatch.apply(doc, {:set_props, "text-1", %{"value" => "World"}})

      node = CanvasDocument.get_node(updated, "text-1")
      assert node["props"]["value"] == "World"
    end

    test "increments revision" do
      doc = base_doc()
      rev_before = CanvasDocument.revision(doc)
      {:ok, updated} = CanvasPatch.apply(doc, {:set_props, "text-1", %{"size" => "lg"}})
      assert CanvasDocument.revision(updated) == rev_before + 1
    end

    test "works on nested nodes" do
      doc = base_doc()

      assert {:ok, updated} =
               CanvasPatch.apply(doc, {:set_props, "nested-text", %{"value" => "Updated"}})

      node = CanvasDocument.get_node(updated, "nested-text")
      assert node["props"]["value"] == "Updated"
    end

    test "returns error for missing node" do
      doc = base_doc()
      assert {:error, msg} = CanvasPatch.apply(doc, {:set_props, "nonexistent", %{}})
      assert msg =~ "nonexistent"
    end
  end

  describe "apply/2 :replace_children" do
    test "replaces all children of a node" do
      doc = base_doc()

      new_children = [
        %{"id" => "new-1", "type" => "badge", "props" => %{"value" => "New"}, "children" => []}
      ]

      assert {:ok, updated} = CanvasPatch.apply(doc, {:replace_children, "root", new_children})
      root = CanvasDocument.get_node(updated, "root")
      assert length(root["children"]) == 1
      assert hd(root["children"])["id"] == "new-1"
    end

    test "can set empty children" do
      doc = base_doc()
      assert {:ok, updated} = CanvasPatch.apply(doc, {:replace_children, "root", []})
      root = CanvasDocument.get_node(updated, "root")
      assert root["children"] == []
    end

    test "returns error for missing node" do
      doc = base_doc()
      assert {:error, msg} = CanvasPatch.apply(doc, {:replace_children, "ghost", []})
      assert msg =~ "ghost"
    end

    test "returns error for invalid children" do
      doc = base_doc()
      bad_children = [%{"type" => "text"}]
      assert {:error, _} = CanvasPatch.apply(doc, {:replace_children, "root", bad_children})
    end
  end

  describe "apply/2 :append_child" do
    test "appends a child node" do
      doc = base_doc()

      new_child = %{
        "id" => "appended",
        "type" => "text",
        "props" => %{"value" => "Appended"},
        "children" => []
      }

      assert {:ok, updated} = CanvasPatch.apply(doc, {:append_child, "root", new_child})
      root = CanvasDocument.get_node(updated, "root")
      assert List.last(root["children"])["id"] == "appended"
    end

    test "returns error for invalid child" do
      doc = base_doc()
      bad_child = %{"type" => "text"}
      assert {:error, _} = CanvasPatch.apply(doc, {:append_child, "root", bad_child})
    end

    test "returns error for missing parent" do
      doc = base_doc()

      new_child = %{"id" => "c", "type" => "text", "props" => %{}, "children" => []}
      assert {:error, msg} = CanvasPatch.apply(doc, {:append_child, "ghost", new_child})
      assert msg =~ "ghost"
    end
  end

  describe "apply/2 :delete_node" do
    test "removes a top-level child node" do
      doc = base_doc()
      assert {:ok, updated} = CanvasPatch.apply(doc, {:delete_node, "text-1"})
      assert is_nil(CanvasDocument.get_node(updated, "text-1"))
      # Other children remain
      assert CanvasDocument.get_node(updated, "card-1")
    end

    test "removes a nested node" do
      doc = base_doc()
      assert {:ok, updated} = CanvasPatch.apply(doc, {:delete_node, "nested-text"})
      assert is_nil(CanvasDocument.get_node(updated, "nested-text"))
      # Parent card remains
      assert CanvasDocument.get_node(updated, "card-1")
    end

    test "cannot delete root" do
      doc = base_doc()
      assert {:error, msg} = CanvasPatch.apply(doc, {:delete_node, "root"})
      assert msg =~ "root"
    end

    test "returns error for missing node" do
      doc = base_doc()
      assert {:error, msg} = CanvasPatch.apply(doc, {:delete_node, "nonexistent"})
      assert msg =~ "nonexistent"
    end

    test "increments revision" do
      doc = base_doc()
      rev_before = CanvasDocument.revision(doc)
      {:ok, updated} = CanvasPatch.apply(doc, {:delete_node, "text-1"})
      assert CanvasDocument.revision(updated) == rev_before + 1
    end
  end

  describe "apply/2 :replace_document" do
    test "replaces entire document" do
      doc = base_doc()
      new_doc = CanvasDocument.new()
      assert {:ok, updated} = CanvasPatch.apply(doc, {:replace_document, new_doc})
      assert updated["root"]["children"] == []
      # Revision should be old_revision + 1
      assert updated["revision"] == doc["revision"] + 1
    end

    test "rejects invalid replacement document" do
      doc = base_doc()
      bad_doc = %{"version" => 0}
      assert {:error, _} = CanvasPatch.apply(doc, {:replace_document, bad_doc})
    end
  end

  describe "apply/2 unsupported operation" do
    test "returns error" do
      doc = base_doc()
      assert {:error, msg} = CanvasPatch.apply(doc, {:unknown_op, "foo"})
      assert msg =~ "unsupported"
    end
  end

  describe "apply_many/2" do
    test "applies multiple operations in order" do
      doc = base_doc()

      ops = [
        {:set_props, "text-1", %{"value" => "First edit"}},
        {:set_props, "text-1", %{"weight" => "bold"}},
        {:append_child, "root",
         %{"id" => "new-node", "type" => "badge", "props" => %{"value" => "✓"}, "children" => []}}
      ]

      assert {:ok, updated} = CanvasPatch.apply_many(doc, ops)
      node = CanvasDocument.get_node(updated, "text-1")
      assert node["props"]["value"] == "First edit"
      assert node["props"]["weight"] == "bold"
      # Each operation increments revision
      assert CanvasDocument.revision(updated) == CanvasDocument.revision(doc) + 3
    end

    test "stops and returns error on first failure" do
      doc = base_doc()

      ops = [
        {:set_props, "text-1", %{"value" => "ok"}},
        {:set_props, "nonexistent", %{"value" => "fail"}},
        {:set_props, "text-1", %{"value" => "should not apply"}}
      ]

      assert {:error, msg} = CanvasPatch.apply_many(doc, ops)
      assert msg =~ "nonexistent"
    end

    test "empty list is a no-op" do
      doc = base_doc()
      assert {:ok, ^doc} = CanvasPatch.apply_many(doc, [])
    end
  end

  describe "apply/2 :set_binding (task 01a1316b-aab0 stage 2)" do
    @vote "(event, ctx) => { ctx.increment('votes.' + event.args.option) }"

    test "sets a handler, defaults the engine to js, and bumps the revision" do
      doc = base_doc()

      assert {:ok, updated} =
               CanvasPatch.apply(
                 doc,
                 {:set_binding, "vote", %{"kind" => "handler", "source" => @vote}}
               )

      assert updated["bindings"]["vote"] == %{
               "kind" => "handler",
               "engine" => "js",
               "source" => @vote
             }

      assert CanvasDocument.revision(updated) == CanvasDocument.revision(doc) + 1
      assert CanvasDocument.handler(updated, "vote")["source"] == @vote
    end

    test "nil deletes the binding" do
      {:ok, doc} =
        CanvasPatch.apply(
          base_doc(),
          {:set_binding, "vote", %{"kind" => "handler", "source" => @vote}}
        )

      assert {:ok, updated} = CanvasPatch.apply(doc, {:set_binding, "vote", nil})
      assert updated["bindings"] == %{}
      assert CanvasDocument.handler(updated, "vote") == nil
    end

    test "a 65 KB source is refused and the document is unchanged" do
      big = "(e, ctx) => {}" <> String.duplicate(" ", 65 * 1024)

      assert {:error, msg} =
               CanvasPatch.apply(
                 base_doc(),
                 {:set_binding, "big", %{"kind" => "handler", "source" => big}}
               )

      assert msg =~ "at most 65536 bytes"

      # 64 KB exactly is accepted (positive control for the cap).
      ok = "(e, ctx) => {}" <> String.duplicate(" ", 65_536 - 14)
      assert byte_size(ok) == 65_536

      assert {:ok, _} =
               CanvasPatch.apply(
                 base_doc(),
                 {:set_binding, "ok", %{"kind" => "handler", "source" => ok}}
               )
    end

    test "bad names, kinds and engines are refused" do
      for {name, binding} <- [
            {"Vote", %{"kind" => "handler", "source" => @vote}},
            {"1vote", %{"kind" => "handler", "source" => @vote}},
            {String.duplicate("a", 65), %{"kind" => "handler", "source" => @vote}},
            {"vote", %{"kind" => "other", "source" => @vote}},
            {"vote", %{"kind" => "handler", "engine" => "lua", "source" => @vote}},
            {"vote", %{"kind" => "handler", "source" => ""}}
          ] do
        assert {:error, "set_binding: " <> _} =
                 CanvasPatch.apply(base_doc(), {:set_binding, name, binding}),
               inspect({name, binding})
      end

      assert {:ok, _} =
               CanvasPatch.apply(
                 base_doc(),
                 {:set_binding, String.duplicate("a", 64),
                  %{"kind" => "handler", "source" => @vote}}
               )
    end

    test "the 33rd handler is refused" do
      doc =
        Enum.reduce(1..32, base_doc(), fn i, doc ->
          {:ok, doc} =
            CanvasPatch.apply(
              doc,
              {:set_binding, "h#{i}", %{"kind" => "handler", "source" => @vote}}
            )

          doc
        end)

      assert map_size(doc["bindings"]) == 32

      assert {:error, msg} =
               CanvasPatch.apply(
                 doc,
                 {:set_binding, "h33", %{"kind" => "handler", "source" => @vote}}
               )

      assert msg =~ "at most 32 handlers"
    end

    test "replace_document with a bad handler binding is refused" do
      bad =
        Map.put(base_doc(), "bindings", %{"Bad Name" => %{"kind" => "handler", "source" => @vote}})

      assert {:error, msg} = CanvasPatch.apply(base_doc(), {:replace_document, bad})
      assert msg =~ "replace_document" and msg =~ "handler name"

      big =
        Map.put(base_doc(), "bindings", %{
          "vote" => %{"kind" => "handler", "source" => String.duplicate("x", 65_537)}
        })

      assert {:error, _} = CanvasPatch.apply(base_doc(), {:replace_document, big})

      good =
        Map.put(base_doc(), "bindings", %{"vote" => %{"kind" => "handler", "source" => @vote}})

      assert {:ok, _} = CanvasPatch.apply(base_doc(), {:replace_document, good})
    end

    test "non-handler bindings stay validated only as a map" do
      doc = Map.put(base_doc(), "bindings", %{"Anything" => %{"x" => 1}})
      assert {:ok, _} = CanvasDocument.validate(doc)
    end

    test "the canvas_patch tool parser accepts set_binding" do
      assert {:ok, [{:set_binding, "vote", %{"kind" => "handler"}}, {:set_binding, "old", nil}]} =
               Platform.Chat.Canvas.ToolHandlers.parse_operations([
                 ["set_binding", "vote", %{"kind" => "handler"}],
                 ["set_binding", "old", nil]
               ])

      assert {:error, _} =
               Platform.Chat.Canvas.ToolHandlers.parse_operations([["set_binding", "x", 3]])
    end
  end
end
