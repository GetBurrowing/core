defmodule PlatformWeb.Chat.CanvasRendererTest do
  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias PlatformWeb.Chat.CanvasRenderer
  alias Platform.Chat.Canvas
  alias Platform.Chat.Canvas.Renderer
  alias Platform.Chat.CanvasDocument

  defp build_canvas(document, overrides \\ %{}) do
    base = %Canvas{
      id: "test-canvas",
      space_id: "test-space",
      created_by: "test-user",
      title: "Test Canvas",
      document: document,
      inserted_at: ~U[2026-01-01 00:00:00Z],
      updated_at: ~U[2026-01-01 00:00:00Z]
    }

    Map.merge(base, overrides)
  end

  defp render_node_html(node) do
    assigns = %{node: node}

    ~H"""
    <Renderer.render_node node={@node} />
    """
    |> rendered_to_string()
  end

  defp render_canvas(canvas, opts \\ %{}) do
    assigns =
      %{canvas: canvas, inline: Map.get(opts, :inline, false)}

    ~H"""
    <CanvasRenderer.canvas_document canvas={@canvas} inline={@inline} />
    """
    |> rendered_to_string()
  end

  describe "canvas_document/1" do
    test "renders a valid canonical document" do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "h1",
            "type" => "heading",
            "props" => %{"value" => "Hello World", "level" => 1},
            "children" => []
          }
        ])

      canvas = build_canvas(doc)
      html = render_canvas(canvas)

      assert html =~ "Hello World"
      assert html =~ "<h1"
      assert html =~ "canvas-doc-test-canvas"
    end

    test "renders a removal placeholder for soft-deleted canvases" do
      canvas =
        build_canvas(CanvasDocument.new(), %{deleted_at: ~U[2026-01-01 00:00:00Z]})

      html = render_canvas(canvas)
      assert html =~ "This canvas was removed"
    end

    test "renders an error shell for invalid documents" do
      canvas = build_canvas(%{"not_a_canvas" => true})
      html = render_canvas(canvas)
      assert html =~ "invalid document"
    end
  end

  describe "Renderer.render_node/1 — kind dispatch" do
    test "renders stack and nested text" do
      node = %{
        "id" => "root",
        "type" => "stack",
        "props" => %{"gap" => 8},
        "children" => [
          %{"id" => "a", "type" => "text", "props" => %{"value" => "Hello"}, "children" => []}
        ]
      }

      html = render_node_html(node)
      assert html =~ "flex flex-col"
      assert html =~ "Hello"
    end

    test "renders row horizontally" do
      node = %{
        "id" => "r",
        "type" => "row",
        "props" => %{"gap" => 4},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "flex flex-row"
    end

    test "renders card with title and children" do
      node = %{
        "id" => "c",
        "type" => "card",
        "props" => %{"title" => "Overview"},
        "children" => [
          %{"id" => "t", "type" => "text", "props" => %{"value" => "inside"}, "children" => []}
        ]
      }

      html = render_node_html(node)
      assert html =~ "Overview"
      assert html =~ "inside"
    end

    test "renders heading with the correct level" do
      node = %{
        "id" => "h",
        "type" => "heading",
        "props" => %{"value" => "Title", "level" => 2},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "<h2"
      assert html =~ "Title"
    end

    test "renders markdown content" do
      node = %{
        "id" => "m",
        "type" => "markdown",
        "props" => %{"content" => "Hello **world**"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "Hello"
      assert html =~ "world"
    end

    test "renders badge" do
      node = %{
        "id" => "b",
        "type" => "badge",
        "props" => %{"value" => "NEW"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "NEW"
    end

    test "renders image" do
      node = %{
        "id" => "i",
        "type" => "image",
        "props" => %{"src" => "/img.png", "alt" => "Preview"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "/img.png"
      assert html =~ "Preview"
    end

    test "renders code with source and language" do
      node = %{
        "id" => "c",
        "type" => "code",
        "props" => %{"language" => "elixir", "source" => "IO.puts(:ok)"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "IO.puts"
      assert html =~ "elixir"
    end

    test "renders mermaid with data-source" do
      node = %{
        "id" => "diag",
        "type" => "mermaid",
        "props" => %{"source" => "graph TD\n  A --> B"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "mermaid-diag"
      assert html =~ "graph TD"
    end

    test "renders table with rows" do
      node = %{
        "id" => "t",
        "type" => "table",
        "props" => %{
          "columns" => ["Name", "Status"],
          "rows" => [%{"Name" => "Alice", "Status" => "Active"}]
        },
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "Alice"
      assert html =~ "Active"
      assert html =~ "Name"
    end

    test "renders checklist with checklist_item children" do
      node = %{
        "id" => "cl",
        "type" => "checklist",
        "props" => %{"title" => "Todo"},
        "children" => [
          %{
            "id" => "ci1",
            "type" => "checklist_item",
            "props" => %{"label" => "First task", "state" => "pending"},
            "children" => []
          },
          %{
            "id" => "ci2",
            "type" => "checklist_item",
            "props" => %{"label" => "Done task", "state" => "complete"},
            "children" => []
          }
        ]
      }

      html = render_node_html(node)
      assert html =~ "Todo"
      assert html =~ "First task"
      assert html =~ "Done task"
    end

    test "renders form with fields" do
      node = %{
        "id" => "f",
        "type" => "form",
        "props" => %{
          "title" => "Feedback",
          "fields" => [
            %{"name" => "notes", "label" => "Notes", "type" => "textarea"}
          ]
        },
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "Feedback"
      assert html =~ "Notes"
      assert html =~ "textarea"
    end

    test "renders action_row with buttons" do
      node = %{
        "id" => "ar",
        "type" => "action_row",
        "props" => %{
          "label" => "Choices",
          "actions" => [
            %{"label" => "Yes", "value" => "yes", "variant" => "primary"},
            %{"label" => "No", "value" => "no"}
          ]
        },
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "Choices"
      assert html =~ "Yes"
      assert html =~ "No"
      assert html =~ "phx-click=\"canvas_action_click\""
    end

    test "renders unknown kind as fallback" do
      node = %{"id" => "x", "type" => "no_such_kind", "props" => %{}, "children" => []}
      html = render_node_html(node)
      assert html =~ "unknown node type"
    end
  end
end
