defmodule PlatformWeb.Chat.CanvasVersionsPanelTest do
  @moduledoc """
  Renders the canvas_overlay + canvas_versions_panel partials and asserts the
  clock-icon affordance + version-row markup are wired correctly (task
  019e0ac0, stage 4).
  """

  use ExUnit.Case, async: true

  import Phoenix.Component, only: [sigil_H: 2]
  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Platform.Chat.Canvas
  alias Platform.Chat.CanvasDocument
  alias PlatformWeb.ChatLive.Partials

  defp build_canvas do
    %Canvas{
      id: "test-canvas-id",
      space_id: "test-space",
      created_by: "test-user",
      title: "Sprint board",
      document: CanvasDocument.new(),
      inserted_at: ~U[2026-05-01 00:00:00Z],
      updated_at: ~U[2026-05-01 00:00:00Z]
    }
  end

  defp render_overlay(canvas, opts \\ []) do
    assigns = %{
      canvas: canvas,
      show_versions_panel: Keyword.get(opts, :show_versions_panel, false),
      canvas_versions: Keyword.get(opts, :canvas_versions, []),
      restore_confirm_revision: Keyword.get(opts, :restore_confirm_revision, nil)
    }

    ~H"""
    <Partials.canvas_overlay
      canvas={@canvas}
      show_versions_panel={@show_versions_panel}
      canvas_versions={@canvas_versions}
      restore_confirm_revision={@restore_confirm_revision}
    />
    """
    |> rendered_to_string()
  end

  describe "canvas_overlay clock-icon affordance" do
    test "renders the clock icon next to the title" do
      html = render_overlay(build_canvas())

      assert html =~ "hero-clock"
      assert html =~ ~s(phx-click="canvas_versions_toggle")
      assert html =~ "Sprint board"
    end

    test "version panel hidden by default" do
      html = render_overlay(build_canvas())
      # The toggle button uses "Version history" as a title attr, but the
      # actual panel header (which only renders when shown) uses the same
      # text inside a <p>. Match the panel-header tag, not the title attr.
      refute html =~ ~s(<p class="text-sm font-semibold">Version history</p>)
    end

    test "version panel renders when show_versions_panel=true" do
      versions = [
        %{
          revision: 3,
          written_at: ~U[2026-05-01 12:00:00.000000Z],
          relative_time: "5m ago",
          author_name: "Alice",
          author_type_badge: "USER",
          author_badge_class: "bg-success/20 text-success",
          op_summary: "set_props on 'embed-1' (1 keys)"
        },
        %{
          revision: 2,
          written_at: ~U[2026-05-01 11:00:00.000000Z],
          relative_time: "1h ago",
          author_name: "agent-bot",
          author_type_badge: "AGENT",
          author_badge_class: "bg-primary/20 text-primary",
          op_summary: "append_child on 'root'"
        },
        %{
          revision: 1,
          written_at: ~U[2026-05-01 10:00:00.000000Z],
          relative_time: "2h ago",
          author_name: "Alice",
          author_type_badge: "USER",
          author_badge_class: "bg-success/20 text-success",
          op_summary: "initial create"
        }
      ]

      html = render_overlay(build_canvas(), show_versions_panel: true, canvas_versions: versions)

      assert html =~ "Version history"
      assert html =~ "v3"
      assert html =~ "v2"
      assert html =~ "v1"
      assert html =~ "5m ago"
      assert html =~ "USER"
      assert html =~ "AGENT"
      assert html =~ "set_props on &#39;embed-1&#39;"
      assert html =~ "initial create"
      assert html =~ ~s(phx-click="canvas_versions_restore_prompt")
    end

    test "renders restore confirmation when restore_confirm_revision matches" do
      versions = [
        %{
          revision: 3,
          written_at: ~U[2026-05-01 12:00:00Z],
          relative_time: "5m ago",
          author_name: "Alice",
          author_type_badge: "USER",
          author_badge_class: "bg-success/20 text-success",
          op_summary: "x"
        }
      ]

      html =
        render_overlay(build_canvas(),
          show_versions_panel: true,
          canvas_versions: versions,
          restore_confirm_revision: 3
        )

      assert html =~ "Replace current canvas with revision 3?"
      assert html =~ ~s(phx-click="canvas_versions_restore_confirm")
      assert html =~ ~s(phx-value-revision="3")
      assert html =~ ~s(phx-click="canvas_versions_restore_cancel")
    end

    test "empty version list renders the empty state" do
      html = render_overlay(build_canvas(), show_versions_panel: true, canvas_versions: [])
      assert html =~ "No version history yet."
    end
  end
end
