defmodule PlatformWeb.Files.CanvasPresenceTest do
  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  alias Platform.{Chat, Repo}
  alias Platform.Chat.{Canvas, Presence}
  alias Platform.Files.{Browser, CanvasPreview}
  alias PlatformWeb.Files.CanvasPresence

  setup do
    org = Platform.Tenancy.get_org_by_slug!("globex")
    user = create_user!()
    plain_member!(user, org)
    space = channel!(%{org_id: org.id, kind: "group"})
    p = add_user!(space.id, user.id)

    {:ok, canvas} =
      Chat.create_canvas(%{
        space_id: space.id,
        created_by: p.id,
        title: "Live preview",
        document: %{
          "version" => 1,
          "revision" => 1,
          "root" => %{
            "id" => "root",
            "type" => "text",
            "props" => %{"value" => "Visible document body"}
          }
        }
      })

    viewer = %{user: user, access_scope: Platform.Access.Scope.for_user(user)}
    {:ok, item} = Browser.fetch_item(viewer, {:canvas, canvas.id})

    socket = %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        viewer: viewer,
        browser: %{items: [item]},
        canvas_previews: %{},
        canvas_people: %{},
        canvas_card_timers: %{}
      }
    }

    on_exit(fn -> Platform.Chat.Canvas.Server.stop(canvas.id) end)
    %{user: user, space: space, canvas: canvas, item: item, socket: socket, p: p, viewer: viewer}
  end

  test "identity projection ignores forged metadata, hidden users and duplicate sessions", c do
    roster = [
      %{
        id: "row-a",
        principal_id: "user-a",
        participant_type: "user",
        name: "Visible",
        avatar_url: "safe",
        slot: "blue"
      }
    ]

    meta = %{
      canvas: %{canvas_id: c.canvas.id},
      display_name: "Forged secret",
      avatar_url: "secret"
    }

    presences = %{
      "row-a" => %{metas: [meta, meta]},
      "user-a" => %{metas: [meta]},
      "hidden" => %{metas: [meta]}
    }

    assert CanvasPresence.project(presences, c.canvas.id, roster) == roster
    assert CanvasPresence.project(presences, Ecto.UUID.generate(), roster) == []
  end

  test "leave retention expires deterministically; rejoin invalidates a stale timer", c do
    {:ok, _} =
      Presence.track_in_space(self(), c.space.id, c.user.id, %{
        canvas: %{canvas_id: c.canvas.id, engagement: :viewing}
      })

    socket = CanvasPresence.sync(c.socket)
    assert [%{principal_id: id}] = socket.assigns.canvas_people[c.canvas.id].people
    assert id == c.user.id
    assert socket.assigns.canvas_card_timers == %{}
    Presence.untrack_in_space(self(), c.space.id, c.user.id)
    socket = CanvasPresence.sync(socket)
    assert socket.assigns.canvas_people[c.canvas.id].leaving?
    token = socket.assigns.canvas_card_timers[c.canvas.id].token

    {:ok, _} =
      Presence.track_in_space(self(), c.space.id, c.user.id, %{canvas: %{canvas_id: c.canvas.id}})

    socket = CanvasPresence.sync(socket)
    refute socket.assigns.canvas_people[c.canvas.id].leaving?
    {:halt, same} = CanvasPresence.handle_info({:canvas_card_expire, c.canvas.id, token}, socket)
    assert same.assigns.canvas_people == socket.assigns.canvas_people
    Presence.untrack_in_space(self(), c.space.id, c.user.id)
    socket = CanvasPresence.sync(socket)
    timer = socket.assigns.canvas_card_timers[c.canvas.id]
    Process.cancel_timer(timer.ref)

    {:halt, socket} =
      CanvasPresence.handle_info({:canvas_card_expire, c.canvas.id, timer.token}, socket)

    assert socket.assigns.canvas_people == %{}
  end

  test "removed roster membership and deleted targets clear retained data immediately", c do
    {:ok, _} =
      Presence.track_in_space(self(), c.space.id, c.user.id, %{canvas: %{canvas_id: c.canvas.id}})

    socket = CanvasPresence.sync(c.socket)
    assert map_size(socket.assigns.canvas_people) == 1
    Repo.delete!(c.p)
    socket = CanvasPresence.sync(socket)
    assert socket.assigns.canvas_people == %{}
    assert socket.assigns.canvas_previews == %{}
    assert socket.assigns.canvas_card_timers == %{}
  end

  test "batch query rejects forged space, game and deleted targets", c do
    assert %{nodes: [%{value: "Visible document body"}]} =
             CanvasPreview.batch(c.viewer, [c.item])[c.canvas.id]

    other = channel!(%{org_id: c.space.org_id, kind: "group"})

    foreign =
      Repo.insert!(%Canvas{space_id: other.id, title: "Hidden", document: c.canvas.document})

    fake = %{c.item | id: foreign.id}
    assert CanvasPreview.batch(c.viewer, [fake]) == %{}
    assert CanvasPreview.batch(c.viewer, [%{c.item | id: "not-a-uuid"}]) == %{}
    assert CanvasPreview.batch(c.viewer, [%{c.item | type: :game}]) == %{}
    assert Browser.game_space_ids(c.viewer, [%{c.item | type: :game}]) == []

    game =
      Repo.insert!(%Canvas{
        space_id: c.space.id,
        title: "Game",
        document: %{"root" => %{"type" => "game_stream"}}
      })

    assert Browser.game_space_ids(c.viewer, [%{c.item | id: game.id, type: :game}]) == [
             c.space.id
           ]

    assert Browser.game_space_ids(c.viewer, [%{c.item | id: foreign.id, type: :game}]) == []
    Repo.update!(Ecto.Changeset.change(c.canvas, deleted_at: DateTime.utc_now()))
    assert CanvasPreview.batch(c.viewer, [c.item]) == %{}
  end

  test "connected fullscreen marks viewing; browser listing never tracks its viewer", c do
    conn = build_conn() |> init_test_session(current_user_id: c.user.id)
    {:ok, browser, _} = live(conn, "/files?space=#{c.space.id}&type=canvas")
    send(browser.pid, :sync_canvas_cards)
    _ = render(browser)
    assert Presence.list_space(c.space.id) == %{}
    {:ok, fullscreen, _} = live(conn, "/canvases/#{c.canvas.id}")

    assert Enum.any?(Presence.list_space(c.space.id), fn {_, v} ->
             Enum.any?(v.metas, &(get_in(&1, [:canvas, :canvas_id]) == c.canvas.id))
           end)

    send(browser.pid, :sync_canvas_cards)
    _ = render(browser)
    state = :sys.get_state(browser.pid)
    assert state.socket.assigns.canvas_people[c.canvas.id].people != []
    Process.unlink(fullscreen.pid)
    monitor = Process.monitor(fullscreen.pid)
    GenServer.stop(fullscreen.pid)
    assert_receive {:DOWN, ^monitor, :process, _, _}
  end

  test "only displayed authorized spaces have subscriptions, and permission loss drops them", c do
    other = channel!(%{org_id: c.space.org_id, kind: "group"})
    add_user!(other.id, c.user.id)
    conn = build_conn() |> init_test_session(current_user_id: c.user.id)
    {:ok, view, _} = live(conn, "/files?space=#{c.space.id}&type=canvas")
    send(view.pid, :sync_canvas_cards)
    _ = render(view)
    topics = :sys.get_state(view.pid).socket.assigns.browser_topics
    assert MapSet.member?(topics, Chat.PubSub.space_topic(c.space.id))
    refute MapSet.member?(topics, Chat.PubSub.space_topic(other.id))
    Repo.delete!(c.p)
    send(view.pid, {:participant_left, c.p})
    _ = render(view)
    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.canvas_previews == %{}
    assert socket.assigns.canvas_people == %{}
    refute MapSet.member?(socket.assigns.browser_topics, Chat.PubSub.space_topic(c.space.id))
  end

  test "one bounded document batch and one metadata batch serve multiple cards", c do
    canvases =
      for n <- 1..5,
          do:
            Repo.insert!(%Canvas{
              space_id: c.space.id,
              title: "Batch #{n}",
              document: c.canvas.document
            })

    items = Enum.map(canvases, &%{c.item | id: &1.id})
    handler = "canvas-preview-query-#{System.unique_integer([:positive])}"
    parent = self()

    :telemetry.attach(
      handler,
      [:platform, :repo, :query],
      fn _, _, meta, _ ->
        if String.contains?(meta.query, "SELECT") and
             String.contains?(meta.query, "c0.\"document\"") do
          send(parent, :preview_document_query)
        end
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    previews = CanvasPreview.batch(c.viewer, items)
    assert map_size(previews) == 5
    assert_receive :preview_document_query
    refute_receive :preview_document_query, 0
  end

  test "thumbnail renders passive real text, three faces and authorized overflow", c do
    people =
      for n <- 1..5,
          do: %{
            id: "row#{n}",
            principal_id: "user#{n}",
            name: "Person #{n}",
            avatar_url: nil,
            participant_type: "user",
            slot: "blue"
          }

    html =
      render_component(&PlatformWeb.Files.CanvasCard.thumbnail/1,
        preview: %{nodes: [%{kind: :text, value: "<script>actual text</script>"}], editor: nil},
        presence: %{people: people, leaving?: false}
      )

    doc = LazyHTML.from_fragment(html)
    assert Enum.count(LazyHTML.query(doc, "[data-role=canvas-card-person]")) == 3

    assert LazyHTML.text(LazyHTML.query(doc, "[data-role=canvas-card-overflow]")) |> String.trim() ==
             "+2"

    assert Enum.empty?(LazyHTML.query(doc, "a,script,iframe,form,button,input"))

    assert LazyHTML.text(LazyHTML.query(doc, "[data-role=canvas-preview-content]")) =~
             "actual text"

    assert CanvasPresence.project(
             %{"hidden" => %{metas: [%{canvas: %{canvas_id: c.canvas.id}}]}},
             c.canvas.id,
             people
           ) == []
  end

  test "fullscreen membership is cleared immediately when the viewer leaves the space", c do
    conn = build_conn() |> init_test_session(current_user_id: c.user.id)
    {:ok, view, _} = live(conn, "/canvases/#{c.canvas.id}")
    assert :sys.get_state(view.pid).socket.assigns.fullscreen_presence != nil
    Repo.delete!(c.p)
    send(view.pid, {:participant_left, c.p})
    _ = render(view)
    socket = :sys.get_state(view.pid).socket
    assert socket.assigns.fullscreen_presence == nil
    assert socket.assigns.canvas == nil
    assert Presence.list_space(c.space.id) == %{}
  end

  test "move drops old-space retention even when the viewer can read the destination", c do
    {:ok, _} =
      Presence.track_in_space(self(), c.space.id, c.user.id, %{canvas: %{canvas_id: c.canvas.id}})

    socket = CanvasPresence.sync(c.socket)
    assert socket.assigns.canvas_people[c.canvas.id].people != []
    destination = channel!(%{org_id: c.space.org_id, kind: "group"})
    add_user!(destination.id, c.user.id)
    Repo.update!(Ecto.Changeset.change(c.canvas, space_id: destination.id))
    socket = CanvasPresence.sync(socket)
    assert socket.assigns.canvas_previews[c.canvas.id].space_id == destination.id
    assert socket.assigns.canvas_people == %{}
    assert socket.assigns.canvas_card_timers == %{}
  end

  test "authorized fullscreen updates keep document and revision metadata together", c do
    conn = build_conn() |> init_test_session(current_user_id: c.user.id)
    {:ok, view, _} = live(conn, "/canvases/#{c.canvas.id}")

    document =
      c.canvas.document
      |> Map.put("revision", 2)
      |> put_in(["root", "props", "value"], "Updated document body")

    fresh =
      Repo.update!(Ecto.Changeset.change(c.canvas, document: document, title: "Updated title"))

    send(view.pid, {:canvas_updated, fresh})
    assert has_element?(view, "[data-role=canvas-revision-stamp]", "rev 2")
    assert has_element?(view, "[data-role=canvas-body]", "Updated document body")
    assert :sys.get_state(view.pid).socket.assigns.page_title == "Updated title"
  end
end
