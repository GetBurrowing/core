defmodule PlatformWeb.Canvases.VersionHistoryTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  alias Platform.{Chat, Repo}
  alias Platform.Chat.Canvas.{Server, Version, Versions}
  alias PlatformWeb.Canvases.VersionHistory

  setup %{conn: conn} do
    org = Platform.Tenancy.get_org_by_slug!("globex")
    user = create_user!()
    plain_member!(user, org)
    space = channel!(%{org_id: org.id})
    p = add_user!(space.id, user.id)

    {:ok, canvas, _} =
      Chat.create_canvas_with_message(space.id, p.id, %{
        title: "History example",
        document: document()
      })

    {:ok, 2} =
      Server.apply_patches(canvas.id, [{:set_props, "text", %{"value" => "Live head"}}], 1)

    on_exit(fn -> Server.stop(canvas.id) end)
    %{conn: login(conn, user.id), canvas: canvas, user: user, p: p, space: space}
  end

  defp document do
    %{
      "version" => 1,
      "revision" => 1,
      "root" => %{
        "id" => "root",
        "type" => "stack",
        "children" => [
          %{"id" => "text", "type" => "text", "props" => %{"value" => "Historical source"}},
          %{
            "id" => "action",
            "type" => "action_row",
            "props" => %{
              "actions" => [%{"label" => "Historical action", "value" => "history-action"}]
            }
          },
          %{
            "id" => "frame",
            "type" => "embed",
            "props" => %{"srcdoc" => "<p>Historical frame</p>", "width" => 400, "height" => 200}
          }
        ]
      }
    }
  end

  defp preview(view) do
    view |> element("#canvas-history-open") |> render_click()
    view |> element("#canvas-history-select-1") |> render_click()
  end

  test "current row is synthesized from canonical head, never from the newest stored row", c do
    import Ecto.Query
    Repo.delete_all(from(v in Version, where: v.canvas_id == ^c.canvas.id and v.revision == 2))
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    view |> element("#canvas-history-open") |> render_click()
    assert has_element?(view, "#canvas-history-row-2[data-current=true]", "Current")
    assert has_element?(view, "#canvas-history-row-1[data-current=false]")
  end

  test "historical preview is inert, cancel writes nothing, confirmed restore retains history",
       c do
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    Chat.PubSub.subscribe_canvas(c.canvas.id)
    preview(view)
    assert has_element?(view, "#canvas-version-preview-banner", "Viewing")
    assert has_element?(view, "#canvas-historical-document[inert]", "Historical source")
    refute has_element?(view, "#canvas-historical-document iframe")
    assert has_element?(view, "#canvas-historical-document", "Interactive content is unavailable")
    render_click(view, "canvas_action_click", %{"value" => "history-action"})
    render_click(view, "canvas_form_submit", %{"value" => "forged"})
    render_click(view, "canvas_patch", %{"operations" => []})
    refute_receive {:canvas_event, _, _}
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    view |> element("#canvas-history-restore") |> render_click()

    assert has_element?(
             view,
             "#canvas-restore-confirmation",
             "Restore this version? The current version stays in history."
           )

    view |> element("#canvas-restore-cancel") |> render_click()
    refute Versions.get(c.canvas.id, 3)
    view |> element("#canvas-history-restore") |> render_click()
    view |> element("#canvas-restore-confirm") |> render_click()
    refute has_element?(view, "#canvas-version-preview-banner")
    assert has_element?(view, "#canvas-history-row-3[data-current=true]", "Current")

    assert has_element?(
             view,
             "#canvas-history-row-3 [data-role=canvas-history-restored-from]",
             "Restored from"
           )

    assert has_element?(view, "[data-role=canvas-body]", "Historical source")
    assert Version.ops(Versions.get(c.canvas.id, 3)) == [["restore_from_revision", 1]]
  end

  test "concurrent changes update head without replacing preview or weakening expected revision",
       c do
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    preview(view)
    view |> element("#canvas-history-restore") |> render_click()

    {:ok, 3} =
      Server.apply_patches(
        c.canvas.id,
        [{:set_props, "text", %{"value" => "Concurrent head"}}],
        2
      )

    assert has_element?(view, "#canvas-historical-document", "Historical source")
    view |> element("#canvas-restore-confirm") |> render_click()
    assert has_element?(view, "#canvas-history-error", "The canvas changed.")
    refute Versions.get(c.canvas.id, 4)
    view |> element("#canvas-history-back-current") |> render_click()
    assert has_element?(view, "[data-role=canvas-body]", "Concurrent head")
  end

  test "org reader sees history and preview but no restore; forged confirmation writes nothing",
       c do
    reader = create_user!()
    plain_member!(reader, Platform.Tenancy.get_org_by_slug!("globex"))
    {:ok, view, _} = live(login(c.conn, reader.id), ~p"/canvases/#{c.canvas.id}")
    preview(view)
    refute has_element?(view, "#canvas-history-restore")
    render_click(view, "canvas_history_restore_prompt")
    render_click(view, "canvas_history_restore_confirm", %{"revision" => 1})
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    refute Versions.get(c.canvas.id, 3)
  end

  test "revoked writer cannot confirm an already open prompt", c do
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    preview(view)
    view |> element("#canvas-history-restore") |> render_click()
    Repo.delete!(c.p)
    view |> element("#canvas-restore-confirm") |> render_click()
    assert has_element?(view, "#canvas-history-error", "could not be restored")
    refute has_element?(view, "#canvas-history-restore")
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
  end

  test "malformed history events cannot crash the viewer or select a document", c do
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    render_click(view, "canvas_history_select", %{"revision" => %{bad: true}})
    render_click(view, "canvas_history_select", %{"revision" => "-1"})
    render_click(view, "canvas_history_restore_confirm", %{"revision" => "1"})
    assert has_element?(view, "[data-role=canvas-body]", "Live head")
    refute has_element?(view, "#canvas-historical-document")
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
  end

  test "source removed after prompting rejects without a new revision", c do
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    preview(view)
    view |> element("#canvas-history-restore") |> render_click()
    Repo.delete!(Versions.get(c.canvas.id, 1))
    view |> element("#canvas-restore-confirm") |> render_click()
    assert has_element?(view, "#canvas-history-error", "could not be restored")
    assert {:ok, %{revision: 2}} = Server.describe(c.canvas.id)
    refute Versions.get(c.canvas.id, 3)
  end

  test "inert projection retains static structure and removes executable nested kinds" do
    doc = document()
    passive = VersionHistory.inert_document(doc)

    assert get_in(passive, ["root", "children"]) |> Enum.map(& &1["type"]) == [
             "text",
             "action_row",
             "text"
           ]

    assert passive["root"]["id"] == doc["root"]["id"]
  end
end
