defmodule PlatformWeb.Chat.CanvasRendererTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.Chat.CanvasRenderer

  # ---------------------------------------------------------------------------
  # Helpers — pure functions (no rendering required)
  # ---------------------------------------------------------------------------

  describe "url_canvas?/1" do
    test "returns true when url key is present and non-empty" do
      assert CanvasRenderer.url_canvas?(%{"url" => "https://example.com"})
    end

    test "returns false for empty url" do
      refute CanvasRenderer.url_canvas?(%{"url" => ""})
    end

    test "returns false when url key is absent" do
      refute CanvasRenderer.url_canvas?(%{})
    end
  end

  describe "a2ui_canvas?/1" do
    test "returns true when a2ui_content is present and non-empty" do
      assert CanvasRenderer.a2ui_canvas?(%{"a2ui_content" => ~s({"type":"text"})})
    end

    test "returns false for empty a2ui_content" do
      refute CanvasRenderer.a2ui_canvas?(%{"a2ui_content" => ""})
    end

    test "returns false when key is absent" do
      refute CanvasRenderer.a2ui_canvas?(%{})
    end
  end

  describe "canonical_document?/1" do
    test "returns true for a valid canonical doc" do
      assert CanvasRenderer.canonical_document?(%{
               "version" => 1,
               "root" => %{"type" => "stack", "props" => %{}, "children" => []}
             })
    end

    test "returns false when root is missing" do
      refute CanvasRenderer.canonical_document?(%{"version" => 1})
    end

    test "returns false when version is missing" do
      refute CanvasRenderer.canonical_document?(%{
               "root" => %{"type" => "stack", "props" => %{}, "children" => []}
             })
    end

    test "returns false for empty map" do
      refute CanvasRenderer.canonical_document?(%{})
    end
  end

  describe "parse_a2ui/1" do
    test "parses single-line JSON" do
      input = ~s({"type":"text","props":{"value":"hello"}})
      [node] = CanvasRenderer.parse_a2ui(input)
      assert node["type"] == "text"
    end

    test "parses multiple JSONL lines" do
      input = ~s({"type":"text"}\n{"type":"badge"})
      nodes = CanvasRenderer.parse_a2ui(input)
      assert length(nodes) == 2
    end

    test "skips invalid JSON lines" do
      input = "not json\n{\"type\":\"text\"}"
      [node] = CanvasRenderer.parse_a2ui(input)
      assert node["type"] == "text"
    end

    test "returns empty list for nil" do
      assert [] = CanvasRenderer.parse_a2ui(nil)
    end

    test "returns empty list for empty string" do
      assert [] = CanvasRenderer.parse_a2ui("")
    end
  end

  # ---------------------------------------------------------------------------
  # Component rendering helpers
  # ---------------------------------------------------------------------------

  # Render a single render_node call and return the HTML string
  defp render_node(node) do
    assigns = %{}
    rendered_to_string(~H|<CanvasRenderer.render_node node={node} />|)
  end

  # ---------------------------------------------------------------------------
  # render_node — existing node types (smoke tests)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — stack" do
    test "renders a stack container" do
      node = %{"type" => "stack", "props" => %{"gap" => 12}, "children" => []}
      html = render_node(node)
      assert html =~ "flex-col"
    end

    test "renders stack children recursively" do
      node = %{
        "type" => "stack",
        "props" => %{},
        "children" => [
          %{"type" => "text", "props" => %{"value" => "hello"}, "children" => []}
        ]
      }

      html = render_node(node)
      assert html =~ "hello"
    end
  end

  describe "render_node/1 — text" do
    test "renders text value" do
      node = %{"type" => "text", "props" => %{"value" => "Hello world"}, "children" => []}
      html = render_node(node)
      assert html =~ "Hello world"
    end

    test "applies size class" do
      node = %{"type" => "text", "props" => %{"value" => "X", "size" => "xl"}, "children" => []}
      html = render_node(node)
      assert html =~ "text-xl"
    end

    test "applies weight class" do
      node = %{
        "type" => "text",
        "props" => %{"value" => "X", "weight" => "bold"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "font-bold"
    end
  end

  describe "render_node/1 — badge" do
    test "renders badge value" do
      node = %{"type" => "badge", "props" => %{"value" => "NEW"}, "children" => []}
      html = render_node(node)
      assert html =~ "NEW"
      assert html =~ "rounded-full"
    end
  end

  describe "render_node/1 — heading" do
    test "renders h1 at level 1" do
      node = %{
        "type" => "heading",
        "props" => %{"value" => "Title", "level" => 1},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "<h1"
      assert html =~ "Title"
    end

    test "renders h3 at level 3" do
      node = %{
        "type" => "heading",
        "props" => %{"value" => "Sub", "level" => 3},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "<h3"
    end

    test "defaults to h2 when level missing" do
      node = %{"type" => "heading", "props" => %{"value" => "Default"}, "children" => []}
      html = render_node(node)
      assert html =~ "<h2"
    end
  end

  describe "render_node/1 — unknown node" do
    test "renders fallback for unknown type" do
      node = %{"type" => "frobnicator", "props" => %{}, "children" => []}
      html = render_node(node)
      assert html =~ "unknown node type"
      assert html =~ "frobnicator"
    end

    test "renders nothing for nil node" do
      html = render_node(nil)
      assert html == "" or not (html =~ "<")
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — checklist (new, stage 1)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — checklist" do
    test "renders card-checklist container" do
      node = %{
        "type" => "checklist",
        "props" => %{},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "card-checklist"
    end

    test "renders optional title" do
      node = %{
        "type" => "checklist",
        "props" => %{"title" => "Release Tasks"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Release Tasks"
    end

    test "renders progress counter when children present" do
      node = %{
        "type" => "checklist",
        "props" => %{"title" => "Work"},
        "children" => [
          %{
            "type" => "checklist_item",
            "props" => %{"label" => "Item 1", "state" => "complete"},
            "children" => []
          },
          %{
            "type" => "checklist_item",
            "props" => %{"label" => "Item 2", "state" => "pending"},
            "children" => []
          }
        ]
      }

      html = render_node(node)
      assert html =~ "1 / 2 tasks"
    end

    test "renders checklist_item children" do
      node = %{
        "type" => "checklist",
        "props" => %{},
        "children" => [
          %{
            "type" => "checklist_item",
            "props" => %{"label" => "Do the thing", "state" => "pending"},
            "children" => []
          }
        ]
      }

      html = render_node(node)
      assert html =~ "Do the thing"
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — checklist_item (new, stage 1)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — checklist_item" do
    test "renders label" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Write tests", "state" => "pending"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Write tests"
    end

    test "emits data-state attribute" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Active item", "state" => "active"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[data-state="active"]
    end

    test "emits data-state=complete for complete items" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Done", "state" => "complete"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[data-state="complete"]
      assert html =~ "line-through"
      assert html =~ "text-success"
    end

    test "emits data-state=pending for pending items" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Pending", "state" => "pending"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[data-state="pending"]
      refute html =~ "line-through"
    end

    test "defaults to pending state when state prop absent" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "No state prop"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[data-state="pending"]
    end

    test "renders optional note" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Item", "state" => "pending", "note" => "Due tomorrow"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Due tomorrow"
    end

    test "omits note when note prop absent" do
      node = %{
        "type" => "checklist_item",
        "props" => %{"label" => "Item", "state" => "pending"},
        "children" => []
      }

      html = render_node(node)
      refute html =~ "Due"
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — action_row (new, stage 2)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — action_row" do
    test "renders flex container" do
      node = %{
        "type" => "action_row",
        "props" => %{},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "flex"
    end

    test "renders optional label" do
      node = %{
        "type" => "action_row",
        "props" => %{"label" => "Actions"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Actions"
    end

    test "renders action_button children" do
      node = %{
        "type" => "action_row",
        "props" => %{},
        "children" => [
          %{
            "type" => "action_button",
            "props" => %{"label" => "Approve", "event" => "design_approved", "value" => "ok"},
            "children" => []
          }
        ]
      }

      html = render_node(node)
      assert html =~ "Approve"
    end
  end

  # ---------------------------------------------------------------------------
  # render_node/1 — action_button (new, stage 2)
  # ---------------------------------------------------------------------------

  describe "render_node/1 — action_button" do
    test "renders button label" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Approve", "value" => "approved"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Approve"
      assert html =~ "btn"
    end

    test "sets phx-click=canvas_action" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Go", "value" => "go"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[phx-click="canvas_action"]
    end

    test "sets phx-value-value from value prop" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Act", "value" => "my_action"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[phx-value-value="my_action"]
    end

    test "sets phx-value-canvas-id from canvas_id prop" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Act", "value" => "x", "canvas_id" => "canvas-abc-123"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ ~s[phx-value-canvas-id="canvas-abc-123"]
    end

    test "applies primary variant class" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "OK", "value" => "ok", "variant" => "primary"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-primary"
    end

    test "applies danger variant class" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Delete", "value" => "delete", "variant" => "danger"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-error"
    end

    test "applies ghost variant class" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "Cancel", "value" => "cancel", "variant" => "ghost"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-ghost"
    end

    test "defaults to outline for unknown or missing variant" do
      node = %{
        "type" => "action_button",
        "props" => %{"label" => "X", "value" => "x"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "btn-outline"
    end

    test "renders default label when label prop absent" do
      node = %{
        "type" => "action_button",
        "props" => %{"value" => "x"},
        "children" => []
      }

      html = render_node(node)
      assert html =~ "Action"
    end
  end

  # ---------------------------------------------------------------------------
  # flat_nodes_array? / normalize_flat_nodes
  # ---------------------------------------------------------------------------

  describe "flat_nodes_array?/1" do
    test "returns true for non-empty nodes array" do
      assert CanvasRenderer.flat_nodes_array?(%{"nodes" => [%{"type" => "text"}]})
    end

    test "returns false for empty nodes array" do
      refute CanvasRenderer.flat_nodes_array?(%{"nodes" => []})
    end

    test "returns false when nodes key is absent" do
      refute CanvasRenderer.flat_nodes_array?(%{})
    end

    test "returns false for canonical document" do
      refute CanvasRenderer.flat_nodes_array?(%{"version" => 1, "root" => %{"type" => "stack"}})
    end
  end

  describe "normalize_flat_nodes/1" do
    test "wraps flat nodes into a stack root" do
      state = %{
        "nodes" => [
          %{"type" => "text", "value" => "hello"},
          %{"type" => "badge", "value" => "tag"}
        ]
      }

      root = CanvasRenderer.normalize_flat_nodes(state)

      assert root["type"] == "stack"
      assert length(root["children"]) == 2
    end

    test "moves inlined props under props key" do
      state = %{
        "nodes" => [
          %{"type" => "text", "value" => "hello", "size" => "lg"}
        ]
      }

      root = CanvasRenderer.normalize_flat_nodes(state)
      [child] = root["children"]

      assert child["type"] == "text"
      assert child["props"]["value"] == "hello"
      assert child["props"]["size"] == "lg"
      refute Map.has_key?(child, "value")
    end

    test "preserves already-nested props" do
      state = %{
        "nodes" => [
          %{"type" => "text", "props" => %{"value" => "hello"}}
        ]
      }

      root = CanvasRenderer.normalize_flat_nodes(state)
      [child] = root["children"]

      assert child["props"]["value"] == "hello"
    end

    test "normalizes nested children recursively" do
      state = %{
        "nodes" => [
          %{
            "type" => "checklist",
            "title" => "Tasks",
            "children" => [
              %{"type" => "checklist_item", "label" => "Do thing", "state" => "complete"}
            ]
          }
        ]
      }

      root = CanvasRenderer.normalize_flat_nodes(state)
      [checklist] = root["children"]

      assert checklist["props"]["title"] == "Tasks"
      [item] = checklist["children"]
      assert item["props"]["label"] == "Do thing"
      assert item["props"]["state"] == "complete"
    end

    test "returns empty stack for non-nodes state" do
      root = CanvasRenderer.normalize_flat_nodes(%{"foo" => "bar"})
      assert root["type"] == "stack"
      assert root["children"] == []
    end
  end
end
