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

    test "embed wrapper ids are unique across canvases (morphdom stability)" do
      embed_node = %{
        "id" => "embed",
        "type" => "embed",
        "props" => %{"srcdoc" => "<!doctype html><body>hi</body>"},
        "children" => []
      }

      doc = CanvasDocument.new() |> put_in(["root", "children"], [embed_node])

      html_a = build_canvas(doc, %{id: "canvas-a"}) |> render_canvas(%{inline: true})
      html_b = build_canvas(doc, %{id: "canvas-b"}) |> render_canvas(%{inline: true})

      [id_a] = Regex.run(~r/id="(embed-canvas-[^"]+)"/, html_a, capture: :all_but_first)
      [id_b] = Regex.run(~r/id="(embed-canvas-[^"]+)"/, html_b, capture: :all_but_first)

      # Two chat messages each carrying a canvas with the same node id must
      # not mint the same wrapper DOM id — colliding ids break morphdom's
      # id-keyed matching on stream re-diffs and remount the iframe
      # (task 019f51d1).
      assert id_a != id_b
      assert id_a =~ "canvas-a"
      assert id_b =~ "canvas-b"
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

    test "renders markdown content as HTML, not raw source" do
      node = %{
        "id" => "m",
        "type" => "markdown",
        "props" => %{"content" => "Hello **world**"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "Hello"
      assert html =~ "world"
      # The literal asterisks should NOT appear — Earmark should have
      # converted them to a <strong> tag.
      assert html =~ "<strong>world</strong>"
      refute html =~ "**world**"
    end

    test "markdown bold renders as <strong>" do
      node = %{
        "id" => "m",
        "type" => "markdown",
        "props" => %{"content" => "this is **emphasised** copy"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "<strong>emphasised</strong>"
      refute html =~ "**emphasised**"
    end

    test "markdown link renders as <a href> with target=_blank" do
      node = %{
        "id" => "m",
        "type" => "markdown",
        "props" => %{"content" => "see [the docs](https://example.com)"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(target="_blank")
      assert html =~ "the docs</a>"
      refute html =~ "[the docs]"
    end

    test "markdown bulleted list renders as <ul><li>" do
      node = %{
        "id" => "m",
        "type" => "markdown",
        "props" => %{"content" => "- one\n- two\n- three"},
        "children" => []
      }

      html = render_node_html(node)
      assert html =~ "<ul>"
      assert html =~ "<li>"
      # All three list items should appear inside <li> tags. Earmark puts
      # the text on its own line with surrounding whitespace, so match
      # loosely on each item's text.
      assert html =~ ~r{<li>\s*one\s*</li>}
      assert html =~ ~r{<li>\s*two\s*</li>}
      assert html =~ ~r{<li>\s*three\s*</li>}
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

    test "action_row buttons carry data-role, node-id, and action attrs (task 019f70ff)" do
      node = %{
        "id" => "ar-demo",
        "type" => "action_row",
        "props" => %{
          "actions" => [
            %{"label" => "Approve", "value" => "approve", "variant" => "primary"}
          ]
        },
        "children" => []
      }

      html = render_node_html(node)
      # data-role marker lets tests + future e2e scripts locate action
      # buttons unambiguously. Note we publish the action key as
      # phx-value-action (NOT phx-value-value) — LV's extractMeta reads
      # HTMLButtonElement.value AFTER phx-value-* and clobbers the "value"
      # meta key with the empty string DOM property. See action_row.ex
      # header comment for the full pre-mortem.
      assert html =~ ~s|data-role="canvas-action-button"|
      assert html =~ ~s|phx-value-node-id="ar-demo"|
      assert html =~ ~s|phx-value-action="approve"|
      # Regression guard: phx-value-value would silently clobber to "" on
      # a button element.
      refute html =~ ~s|phx-value-value=|
    end
  end

  describe "canvas_document/1 wiring for action_row (task 019f70ff)" do
    # Both surfaces (inline chat-message and panel/expanded sidebar) render
    # through the same CanvasRenderer + Renderer.render_node pipeline. The
    # fix threads canvas_id through the render tree so action buttons carry
    # `phx-value-canvas-id` regardless of whether an `active_canvas` is set —
    # closing Bug B (empty payload in pinned view) at the source.

    defp action_canvas do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "ar-demo",
            "type" => "action_row",
            "props" => %{
              "actions" => [
                %{"label" => "Approve", "value" => "approve", "variant" => "primary"},
                %{"label" => "Reject", "value" => "reject", "variant" => "danger"}
              ]
            },
            "children" => []
          }
        ])

      build_canvas(doc, %{id: "canvas-under-test"})
    end

    test "inline render surfaces phx-value-canvas-id on every action button" do
      html = render_canvas(action_canvas(), %{inline: true})

      # Both buttons carry the canvas.id. Rendered twice (two actions) so we
      # anchor on the pattern rather than counting exact occurrences.
      assert html =~ ~s|phx-value-canvas-id="canvas-under-test"|
      assert html =~ ~s|phx-value-action="approve"|
      assert html =~ ~s|phx-value-action="reject"|
      assert html =~ ~s|data-role="canvas-action-button"|
    end

    test "panel render surfaces phx-value-canvas-id on every action button" do
      html = render_canvas(action_canvas(), %{inline: false})

      assert html =~ ~s|phx-value-canvas-id="canvas-under-test"|
      assert html =~ ~s|phx-value-action="approve"|
      assert html =~ ~s|phx-value-action="reject"|
      assert html =~ ~s|data-role="canvas-action-button"|
    end

    test "inline wrapper keeps canvas_open on itself; button's own phx-click wins via closestPhxBinding" do
      html = render_canvas(action_canvas(), %{inline: true})

      # The wrapper still carries phx-click="canvas_open" (that's how empty-
      # canvas clicks open the sidebar). The button carries its OWN
      # phx-click="canvas_action_click" AND data-role marker. LV's
      # closestPhxBinding walks up from event.target and resolves the
      # closest phx-click ancestor — since the button has phx-click, the
      # button wins over the wrapper (Bug A no-longer-fires). See extended
      # comment in canvas_renderer.ex for why we do NOT add an onclick
      # stopPropagation on the wrapper (it would kill the button click).
      assert html =~ ~s|phx-click="canvas_open"|
      assert html =~ ~s|phx-click="canvas_action_click"|
      assert html =~ ~s|data-role="canvas-action-button"|
      # Regression guard: no stopPropagation should appear on the wrapper,
      # since it would prevent LV's window-level click listener from firing.
      refute html =~ "stopPropagation"
    end

    test "renders embed as a sandboxed iframe" do
      node = %{
        "id" => "e1",
        "type" => "embed",
        "props" => %{"srcdoc" => "<!doctype html><body>hi</body>"}
      }

      html = render_node_html(node)
      assert html =~ "<iframe"
      # The critical security contract: empty-string sandbox attribute.
      assert html =~ ~s|sandbox=""|
      refute html =~ ~r/sandbox="[^"]+"/
    end

    test "renders unknown kind as fallback" do
      node = %{"id" => "x", "type" => "no_such_kind", "props" => %{}, "children" => []}
      html = render_node_html(node)
      assert html =~ "unknown node type"
    end
  end

  describe "canvas_document/1 sibling interactive kinds regression (task 019f70ff stage 2)" do
    # Stage 1 (commit edc1852b + 3e07a26e) added an onclick stopPropagation
    # guard to the inline canvas wrapper and threaded canvas_id through the
    # render tree. Stage 2 pins down the invariants for the OTHER interactive
    # kinds so a future edit to canvas_renderer.ex / renderer.ex can't silently
    # break form submits or checklist interaction anchors while chasing an
    # action_row fix.

    defp form_canvas do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "f-demo",
            "type" => "form",
            "props" => %{
              "title" => "Feedback",
              "fields" => [
                %{"name" => "notes", "label" => "Notes", "type" => "textarea"},
                %{"name" => "email", "label" => "Email", "type" => "email"}
              ]
            },
            "children" => []
          }
        ])

      build_canvas(doc, %{id: "canvas-form"})
    end

    defp checklist_canvas do
      doc =
        CanvasDocument.new()
        |> put_in(["root", "children"], [
          %{
            "id" => "cl-demo",
            "type" => "checklist",
            "props" => %{"title" => "Todo"},
            "children" => [
              %{
                "id" => "ci-demo",
                "type" => "checklist_item",
                "props" => %{"label" => "Ship stage 2", "state" => "pending"},
                "children" => []
              }
            ]
          }
        ])

      build_canvas(doc, %{id: "canvas-checklist"})
    end

    test "inline form still emits phx-submit=canvas_form_submit + node-id" do
      html = render_canvas(form_canvas(), %{inline: true})

      # The form kind's phx-submit binding is what CanvasHooks.handle_event/3
      # dispatches on. Stage 1 threaded canvas_id into container kinds but did
      # NOT change form.ex — this test locks that in so a future refactor
      # can't drop phx-submit while shuffling wrapper attributes.
      assert html =~ ~s|phx-submit="canvas_form_submit"|
      assert html =~ ~s|phx-value-node-id="f-demo"|
      # The rendered field controls are what the wrapper's onclick guard has
      # to leave alone — assert they made it through.
      assert html =~ ~s|name="form[notes]"|
      assert html =~ ~s|name="form[email]"|
      assert html =~ "<textarea"
    end

    test "panel form still emits phx-submit=canvas_form_submit + node-id" do
      html = render_canvas(form_canvas(), %{inline: false})

      # Panel (non-inline) surface uses the same Renderer.render_node call
      # path, so the same invariants must hold. Duplicated deliberately: the
      # inline vs panel split is where Bug B (task 019f70ff Bug B) hid.
      assert html =~ ~s|phx-submit="canvas_form_submit"|
      assert html =~ ~s|phx-value-node-id="f-demo"|
    end

    test "inline form co-exists with wrapper's phx-click=canvas_open (no stopPropagation regression)" do
      html = render_canvas(form_canvas(), %{inline: true})

      # Stage 1's final commit (3e07a26e) explicitly REVERTED an earlier
      # onclick stopPropagation attempt because it killed action_row button
      # clicks before LV's window-level phx-click listener fired. The
      # runtime mechanism is now purely LV's closestPhxBinding: form
      # submissions dispatch on phx-submit (a different event type than
      # click), so the wrapper's phx-click="canvas_open" doesn't interfere
      # with canvas_form_submit at all.
      #
      # This test locks in the invariants that must hold together:
      #   1. Wrapper still carries phx-click="canvas_open" (that's how empty-
      #      canvas clicks open the sidebar).
      #   2. Form still carries phx-submit="canvas_form_submit".
      #   3. NO stopPropagation appears anywhere in the wrapper markup
      #      (matches the existing action_row wrapper assertion — a future
      #      well-meaning refactor that "protects" form clicks with
      #      stopPropagation would silently break action_row clicks).
      assert html =~ ~s|phx-click="canvas_open"|
      assert html =~ ~s|phx-submit="canvas_form_submit"|
      refute html =~ "stopPropagation"
      # The form's own controls must render inside the wrapper — a broken
      # canvas_id threading (or a wrapper that swallowed children) would
      # collapse this.
      assert html =~ "<textarea"
      assert html =~ ~s|type="email"|
      assert html =~ ~s|type="submit"|
    end

    test "inline checklist_item preserves interaction anchors (data-node-id + data-state)" do
      html = render_canvas(checklist_canvas(), %{inline: true})

      # checklist_item currently renders a passive row (icon + label). Its
      # `data-node-id` and `data-state` attributes are the anchors any future
      # toggle interaction — client-side hook, server-side canvas_patch —
      # would key off of. Stage 1's canvas_id threading routes through
      # kinds/checklist.ex, so a broken thread would silently drop the child
      # node's props before render. Lock that in.
      assert html =~ ~s|data-node-id="ci-demo"|
      assert html =~ ~s|data-state="pending"|
      assert html =~ "Ship stage 2"
      # And the wrapping checklist still shows its title (proves the parent
      # container render didn't collapse under a canvas_id threading bug).
      assert html =~ "Todo"
    end

    test "panel checklist_item preserves interaction anchors (data-node-id + data-state)" do
      html = render_canvas(checklist_canvas(), %{inline: false})

      # Same invariants must hold on the panel surface — see the form test
      # above for why we duplicate across inline/panel.
      assert html =~ ~s|data-node-id="ci-demo"|
      assert html =~ ~s|data-state="pending"|
      assert html =~ "Ship stage 2"
      assert html =~ "Todo"
    end
  end
end
