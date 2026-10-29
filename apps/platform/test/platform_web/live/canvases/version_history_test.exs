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
    # The plain embed now renders as itself (task 01a18834 stage 2): the
    # `sandbox=""` srcdoc frame, never a scripted one. The 'unavailable'
    # fallback is pinned by the malformed-ref test below.
    assert has_element?(view, ~s(#canvas-historical-document iframe[sandbox=""][srcdoc]))
    refute has_element?(view, ~s(#canvas-historical-document iframe[sandbox="allow-scripts"]))
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

  test "a stored scripted embed with a malformed ref falls back to the unavailable text", c do
    # Stamping never writes such a ref; an old or hand-edited row can hold one.
    malformed_scripted_embed_in_revision_1!(c.canvas.id)
    {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.canvas.id}")
    preview(view)
    assert has_element?(view, "#canvas-historical-document", "Interactive content is unavailable")
    refute has_element?(view, ~s(#canvas-historical-document iframe[sandbox="allow-scripts"]))
    refute has_element?(view, ~s(#canvas-historical-document [data-role="prototype-canvas"]))
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
    doc =
      update_in(document(), ["root", "children"], &(&1 ++ [malformed_scripted_embed()]))

    passive = VersionHistory.inert_document(doc)

    assert get_in(passive, ["root", "children"]) |> Enum.map(& &1["type"]) == [
             "text",
             "action_row",
             "embed",
             "text"
           ]

    assert passive["root"]["id"] == doc["root"]["id"]
  end

  test "inert projection: scripted refs become preview prototypes; malformed refs stay inert" do
    pid = Ecto.UUID.generate()

    scripted = fn ref ->
      %{
        "id" => "se",
        "type" => "embed",
        "props" => %{
          "srcdoc" => "<p>x</p>",
          "scripts" => true,
          "height" => 300,
          "prototype_ref" => ref
        }
      }
    end

    project = fn node ->
      VersionHistory.inert_document(%{
        "root" => %{"id" => "r", "type" => "stack", "children" => [node]}
      })
      |> get_in(["root", "children"])
      |> hd()
    end

    assert project.(scripted.(%{"prototype_id" => pid, "version" => 2, "sha256" => "ab"})) == %{
             "id" => "se",
             "type" => "prototype",
             "props" => %{
               "prototype_id" => pid,
               "version" => 2,
               "height" => 300,
               "preview" => true
             }
           }

    for bad <- [
          nil,
          %{"prototype_id" => "nope", "version" => 2},
          %{"prototype_id" => pid, "version" => 0},
          %{"prototype_id" => pid, "version" => "2"},
          %{"prototype_id" => pid}
        ] do
      assert %{"type" => "text"} = project.(scripted.(bad)), "projected #{inspect(bad)}"
    end

    # inert_document/1 has no written_at: a follow-latest node keeps following.
    assert project.(%{"id" => "p", "type" => "prototype", "props" => %{"prototype_id" => pid}}) ==
             %{
               "id" => "p",
               "type" => "prototype",
               "props" => %{"prototype_id" => pid, "preview" => true}
             }
  end

  describe "sealed prototype frames in previews (task 01a18834 stage 2)" do
    import Ecto.Query, only: [from: 2]
    import Platform.PrototypeFixtures, only: [scratch_storage!: 1, set_settings!: 1, agent!: 0]
    alias Platform.Prototypes

    setup c do
      scratch_storage!("version_history_preview")
      set_settings!(%{enabled: true, who_may_publish: "members", retention_days: 90})
      prev_sync = Application.get_env(:platform, :canvas_persist_sync)
      Application.put_env(:platform, :canvas_persist_sync, true)
      on_exit(fn -> Application.put_env(:platform, :canvas_persist_sync, prev_sync) end)

      publisher = %{kind: :agent, agent_id: agent!().id, owner_user: nil}

      {:ok, %{prototype: followed}} =
        Prototypes.publish(
          publisher,
          %{org_id: c.space.org_id, name: "Followed"},
          {:files, %{"index.html" => %{"content" => "<p>followed v1</p>"}}}
        )

      {:ok, canvas, _} =
        Chat.create_canvas_with_message(c.space.id, c.p.id, %{
          title: "Scripted history",
          document: %{
            "version" => 1,
            "revision" => 1,
            "root" => %{
              "id" => "root",
              "type" => "stack",
              "children" => [
                %{"id" => "plain", "type" => "embed", "props" => %{"srcdoc" => "<p>plain</p>"}},
                %{
                  "id" => "se",
                  "type" => "embed",
                  "props" => %{"srcdoc" => scripted_html(1), "scripts" => true}
                },
                %{
                  "id" => "follow",
                  "type" => "prototype",
                  "props" => %{"prototype_id" => followed.id}
                }
              ]
            }
          }
        })

      on_exit(fn -> Server.stop(canvas.id) end)

      # Published AFTER revision 1 was written: the live node follows v2, the
      # revision-1 preview must show v1.
      {:ok, %{prototype: followed}} =
        Prototypes.publish(
          publisher,
          %{prototype: followed},
          {:files, %{"index.html" => %{"content" => "<p>followed v2</p>"}}}
        )

      for v <- [2, 3] do
        {:ok, _} =
          Chat.patch_canvas({:user, c.user.id}, canvas, [
            {:set_props, "se", %{"srcdoc" => scripted_html(v)}}
          ])
      end

      {:ok, %{revision: 3, document: doc}} = Server.describe(canvas.id)

      %{"prototype_id" => pid, "version" => 3} =
        Chat.CanvasDocument.get_node(doc, "se")["props"]["prototype_ref"]

      {:ok, scanvas: canvas, embed_pid: pid, followed: followed}
    end

    defp select(view, revision) do
      view |> element("#canvas-history-open") |> render_click()
      view |> element("#canvas-history-select-#{revision}") |> render_click()
    end

    defp in_preview(view, selector),
      do:
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#canvas-historical-document " <> selector)
        |> Enum.to_list()

    test "rev 2 renders v2 sealed, with an info strip and no bridge or controls", c do
      {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.scanvas.id}")
      select(view, 2)

      assert has_element?(view, ~s(#canvas-historical-document[inert] iframe[sandbox=""][srcdoc]))

      assert [frame] =
               in_preview(
                 view,
                 ~s(iframe[src="/proto/#{c.embed_pid}/2/"][sandbox="allow-scripts"])
               )

      assert LazyHTML.attribute(frame, "referrerpolicy") == ["no-referrer"]

      assert has_element?(
               view,
               ~s(#canvas-historical-document [id^="prototype-se"] [data-role="prototype-preview-strip"]),
               "v2"
             )

      assert [strip] =
               in_preview(view, ~s([id^="prototype-se"] [data-role="prototype-preview-strip"]))

      text = strip |> LazyHTML.text() |> String.split() |> Enum.join(" ")
      assert text == "Preview · v2 · read-only — not connected to the room"

      # Positive control for the zero counts below: the LIVE canvas renders
      # the bridge and the bar for this very node.
      {:ok, live_view, _} = live(c.conn, ~p"/canvases/#{c.scanvas.id}")
      assert has_element?(live_view, ~s([data-role="canvas-room-bridge"]))
      assert has_element?(live_view, ~s([data-role="prototype-menu-button"]))

      for sel <- [
            ~s([data-role="canvas-room-bridge"]),
            ~s([phx-hook="CanvasRoomBridge"]),
            ~s([data-canvas-id]),
            ~s([data-role="prototype-bar"]),
            ~s([data-role="prototype-pin"]),
            ~s([data-role="prototype-fullscreen"]),
            ~s([data-role="prototype-open"]),
            ~s([data-role="prototype-menu-button"]),
            ~s([data-role="prototype-version-stamp"])
          ] do
        assert in_preview(view, sel) == [], "preview rendered #{sel}"
      end

      # Both preview frames (the scripted embed and the follow-latest node).
      roots = in_preview(view, ~s([data-role="prototype-canvas"]))
      assert length(roots) == 2

      for root <- roots do
        [class] = LazyHTML.attribute(root, "class")
        assert class =~ "border-dashed"
        assert class =~ "border-edge"
        refute class =~ "opacity"
      end
    end

    test "a follow-latest prototype shows the version that was latest at that revision", c do
      assert c.followed.latest_version == 2
      {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.scanvas.id}")
      select(view, 1)

      assert [_] = in_preview(view, ~s(iframe[src="/proto/#{c.followed.id}/1/"]))
      assert [_] = in_preview(view, ~s(iframe[src="/proto/#{c.embed_pid}/1/"]))
      assert in_preview(view, ~s(iframe[src="/proto/#{c.followed.id}/2/"])) == []
    end

    test "a retention-removed version shows the removed panel without an iframe or action", c do
      Repo.update_all(
        from(v in Platform.Prototypes.Version,
          where: v.prototype_id == ^c.embed_pid and v.version == 2
        ),
        set: [removed_at: DateTime.utc_now()]
      )

      {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.scanvas.id}")
      select(view, 2)

      assert [panel] = in_preview(view, ~s([data-role="prototype-removed"]))
      assert LazyHTML.text(panel) =~ "This version was removed after 90 days."
      assert in_preview(view, ~s(iframe[src^="/proto/#{c.embed_pid}/"])) == []
      assert LazyHTML.query(panel, "button, a") |> Enum.to_list() == []

      assert has_element?(
               view,
               ~s([id^="prototype-se"] [data-role="prototype-preview-strip"]),
               "v2"
             )
    end

    test "forged events and writes while a preview is open change nothing", c do
      {:ok, view, _} = live(c.conn, ~p"/canvases/#{c.scanvas.id}")
      select(view, 2)
      {:ok, before} = Server.describe(c.scanvas.id)

      render_click(view, "canvas_action_click", %{"value" => "x"})
      render_click(view, "canvas_form_submit", %{"value" => "forged"})

      render_hook(view, "canvas_patch", %{
        "operations" => [["set_props", "se", %{"srcdoc" => scripted_html(9)}]]
      })

      assert {:ok, after_} = Server.describe(c.scanvas.id)
      assert after_.revision == before.revision
      assert after_.document == before.document
      assert [_] = in_preview(view, ~s(iframe[src="/proto/#{c.embed_pid}/2/"]))
    end

    test "a patch carrying preview is refused on a live canvas", c do
      {:ok, before} = Server.describe(c.scanvas.id)

      assert {:conflict, %{reason: :schema_violation, message: msg}} =
               Chat.patch_canvas({:user, c.user.id}, c.scanvas, [
                 {:set_props, "follow", %{"preview" => true}}
               ])

      assert msg =~ "preview is set by the server"

      assert {:conflict, %{reason: :schema_violation, message: msg}} =
               Chat.patch_canvas({:user, c.user.id}, c.scanvas, [
                 {:append_child, "root",
                  %{
                    "id" => "forged",
                    "type" => "prototype",
                    "props" => %{
                      "prototype_id" => c.followed.id,
                      "version" => 1,
                      "preview" => true
                    }
                  }}
               ])

      assert msg =~ "preview is set by the server"

      # Positive control: the same write without `preview` lands.
      assert {:ok, _} =
               Chat.patch_canvas({:user, c.user.id}, c.scanvas, [
                 {:set_props, "follow", %{"version" => 1}}
               ])

      {:ok, after_} = Server.describe(c.scanvas.id)
      assert after_.revision == before.revision + 1

      refute Map.has_key?(
               Chat.CanvasDocument.get_node(after_.document, "follow")["props"],
               "preview"
             )
    end
  end

  defp scripted_html(v),
    do: ~s(<!doctype html><html><body><p id="marker">VERSION=#{v}</p></body></html>)

  defp malformed_scripted_embed,
    do: %{
      "id" => "scripted",
      "type" => "embed",
      "props" => %{
        "srcdoc" => "<p>x</p>",
        "scripts" => true,
        "prototype_ref" => %{"prototype_id" => "not-a-uuid", "version" => 1}
      }
    }

  defp malformed_scripted_embed_in_revision_1!(canvas_id) do
    row = Versions.get(canvas_id, 1)
    doc = update_in(row.document, ["root", "children"], &(&1 ++ [malformed_scripted_embed()]))
    row |> Ecto.Changeset.change(document: doc) |> Repo.update!()
  end
end
