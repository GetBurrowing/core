defmodule PlatformWeb.ChatLivePinnedOrderTest do
  @moduledoc """
  Pinned keeps the saved order (task 01a1557b stage 1, Burrow redesign 25):
  the pinned conversations render in the user's stored `chat_pinned_spaces`
  order, task pins above them by recency, and every other section by
  recency. `PlatformWeb.ChatLive.PinnedReorderHooks` writes the order
  (`move_pinned_row`, `move_pinned_step`), keeps one undo per burst
  (`undo_pinned_order`, `{:pinned_undo_expired, ref}`) and the announcement.

  Every refusal reads three things: the stored preferences (byte-identical),
  the undo state (nil) and the sidebar topic (nothing broadcast). Each sits
  beside an accepted move on the same fixture that changes all three, so a
  refusal that cannot be seen to fail is not counted.

  `async: false`: the Agents row reads a feature flag from application env,
  held off here so Pinned holds only pins.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.PubSub, as: ChatPubSub
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive.PinnedReorderHooks

  @flag_key :agents_goal_surface
  @pinned_rows "[data-role=chat-list-pinned] [data-role=chat-list-row]"
  @space_rows "[data-role=chat-list-spaces] [data-role=chat-list-row]"

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    Application.put_env(:platform, @flag_key, false)
    :ok
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp acme, do: Tenancy.get_org!(acme_org_id())

  defp member! do
    user = create_user!()
    plain_member!(user, acme())
    user
  end

  defp channel_in(org, name) do
    n = System.unique_integer([:positive])
    channel!(%{name: "#{name}#{n}", slug: "pin-order-#{n}", org_id: org.id})
  end

  defp join!(space, user_id, display_name) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user_id,
        display_name: display_name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp say!(space, content) do
    poster = join!(space, Ecto.UUID.generate(), "Poster")

    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: poster.id,
        content_type: "text",
        content: content
      })

    msg
  end

  # Back-date one message: a lower number is newer, and every fixture time
  # precedes any message a test posts live.
  defp stamp!(msg, seconds) do
    at = DateTime.add(DateTime.utc_now(), -3600 - seconds, :second)

    Repo.update_all(from(m in Platform.Chat.Message, where: m.id == ^msg.id),
      set: [inserted_at: at]
    )
  end

  defp pin!(user, spaces) do
    for s <- spaces, do: {:ok, _} = Sidebar.set_space_pinned(user.id, s.id, true)
  end

  # A member with channels A, B, C pinned in that order.
  defp world(conn) do
    user = member!()
    [a, b, c] = for n <- ~w(PinA PinB PinC), do: channel_in(acme(), n)
    pin!(user, [a, b, c])
    %{conn: login(conn, user.id), user: user, a: a, b: b, c: c}
  end

  defp seed_task_pin!(user) do
    {:ok, project} =
      Tasks.create_project(%{name: "Pin Order Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Pin Order Task",
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} = ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)
    space
  end

  defp ids_in(view, selector) do
    view
    |> element("#chat-list")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-space-id")
  end

  defp pinned_ids(view), do: ids_in(view, @pinned_rows)

  defp keep(list, ids), do: Enum.filter(list, &(&1 in ids))

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp prefs(user), do: Repo.get!(User, user.id).preferences |> Jason.encode!()

  defp move(view, space, to),
    do: render_click(view, "move_pinned_row", %{"space_id" => space.id, "to_position" => to})

  # ── order ───────────────────────────────────────────────────────────────

  describe "rendered order" do
    # (a)
    test "pins stored [C, A, B] with the newest message in B read C, A, B", %{conn: conn} do
      user = member!()
      [a, b, c] = for n <- ~w(PinA PinB PinC), do: channel_in(acme(), n)
      pin!(user, [c, a, b])
      stamp!(say!(c, "oldest"), 30)
      stamp!(say!(a, "older"), 20)
      stamp!(say!(b, "newest"), 10)

      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert pinned_ids(view) == [c.id, a.id, b.id]
    end

    # (b)
    test "a new pinned message does not move its row; an unpinned one does", %{conn: conn} do
      w = world(conn)
      d = channel_in(acme(), "SpaceD")
      e = channel_in(acme(), "SpaceE")
      stamp!(say!(d, "newer"), 10)
      stamp!(say!(e, "older"), 20)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert pinned_ids(view) == [w.a.id, w.b.id, w.c.id]
      assert view |> ids_in(@space_rows) |> keep([d.id, e.id]) == [d.id, e.id]

      say!(w.c, "the last pin wakes up")
      say!(e, "the bottom space wakes up")
      _ = render(view)

      assert pinned_ids(view) == [w.a.id, w.b.id, w.c.id]
      assert hd(ids_in(view, @space_rows)) == e.id
    end

    # (c)
    test "a new pin appends at the end of the conversation run", %{conn: conn} do
      w = world(conn)
      d = channel_in(acme(), "PinD")
      say!(d, "the newest message of all")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_click(view, "toggle_pinned", %{"space_id" => d.id, "pinned" => "true"})

      assert pinned_ids(view) == [w.a.id, w.b.id, w.c.id, d.id]
    end

    # (d)
    test "task pins render above the run and a task id is not movable", %{conn: conn} do
      w = world(conn)
      task_space = seed_task_pin!(w.user)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert pinned_ids(view) == [task_space.id, w.a.id, w.b.id, w.c.id]

      before = prefs(w.user)
      ChatPubSub.subscribe_sidebar(w.user.id)

      move(view, task_space, 0)
      move(view, task_space, 2)

      assert prefs(w.user) == before
      assert lv_assigns(view).pinned_undo == nil
      assert lv_assigns(view).pinned_announcement == nil
      refute_receive :sidebar_changed, 100

      # Positive control on the same fixture: a conversation move does all three.
      move(view, w.c, 0)
      refute prefs(w.user) == before
      assert lv_assigns(view).pinned_undo != nil
      assert_receive :sidebar_changed
    end
  end

  # ── moves ───────────────────────────────────────────────────────────────

  describe "move_pinned_row" do
    # (e)
    test "persists, and a fresh mount renders the new order", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, w.c, 0)

      assert Sidebar.list_pinned_space_ids(w.user.id) == [w.c.id, w.a.id, w.b.id]
      assert pinned_ids(view) == [w.c.id, w.a.id, w.b.id]

      assert lv_assigns(view).pinned_announcement ==
               "#{w.c.name} moved to position 1 of 3"

      {:ok, fresh, _} = live(w.conn, ~p"/chat")
      assert pinned_ids(fresh) == [w.c.id, w.a.id, w.b.id]
    end

    test "an integer string position is accepted, and move_pinned_step moves by one",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, w.a, "2")
      assert pinned_ids(view) == [w.b.id, w.c.id, w.a.id]

      render_click(view, "move_pinned_step", %{"space_id" => w.a.id, "direction" => "up"})
      assert pinned_ids(view) == [w.b.id, w.a.id, w.c.id]

      render_click(view, "move_pinned_step", %{"space_id" => w.b.id, "direction" => "down"})
      assert pinned_ids(view) == [w.a.id, w.b.id, w.c.id]
    end

    # (f)
    test "a ghost id keeps its place in the stored list", %{conn: conn} do
      user = member!()
      [a, g, b, c] = for n <- ~w(PinA Ghost PinB PinC), do: channel_in(acme(), n)
      pin!(user, [a, g, b, c])
      {:ok, _} = Chat.archive_space(g)
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert pinned_ids(view) == [a.id, b.id, c.id]

      # The ghost is stored but not rendered, so it is not in the run and a
      # move naming it is refused. Added after anti-vacuity mutation 6 left
      # the task-id case in (d) green: a task id is never STORED, so
      # `destination_index/3` returns nil for it whatever the run check does.
      # A ghost IS stored, so only the run check refuses it.
      before = prefs(user)
      move(view, g, 2)
      assert prefs(user) == before
      assert lv_assigns(view).pinned_undo == nil

      move(view, c, 0)

      assert Sidebar.list_pinned_space_ids(user.id) == [c.id, a.id, g.id, b.id]
      assert pinned_ids(view) == [c.id, a.id, b.id]
    end

    # (g)
    test "refusals write nothing, arm no undo and broadcast nothing", %{conn: conn} do
      w = world(conn)
      unpinned = channel_in(acme(), "Loose")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      before = prefs(w.user)
      ChatPubSub.subscribe_sidebar(w.user.id)

      for {space, to} <- [
            {unpinned, 0},
            {w.c, -1},
            {w.c, 3},
            {w.c, "x"},
            {w.c, "1.5"},
            {w.c, 2}
          ] do
        move(view, space, to)

        assert prefs(w.user) == before, "#{inspect(to)} wrote"
        assert lv_assigns(view).pinned_undo == nil, "#{inspect(to)} armed undo"
        assert lv_assigns(view).pinned_announcement == nil
      end

      render_click(view, "move_pinned_step", %{"space_id" => w.a.id, "direction" => "up"})
      render_click(view, "move_pinned_step", %{"space_id" => w.c.id, "direction" => "down"})
      render_click(view, "move_pinned_step", %{"space_id" => w.b.id, "direction" => "left"})

      assert prefs(w.user) == before
      assert lv_assigns(view).pinned_undo == nil
      refute_receive :sidebar_changed, 100

      # Positive control: an accepted move on the same view changes all three.
      move(view, w.c, 1)
      refute prefs(w.user) == before
      assert lv_assigns(view).pinned_undo != nil
      assert_receive :sidebar_changed
    end

    # (h)
    test "a move in one view shows in the user's other view without a remount",
         %{conn: conn} do
      w = world(conn)
      {:ok, view1, _} = live(w.conn, ~p"/chat")
      {:ok, view2, _} = live(w.conn, ~p"/chat")

      move(view1, w.c, 0)

      assert pinned_ids(view2) == [w.c.id, w.a.id, w.b.id]
    end

    # (i)
    test "another user's order is untouched", %{conn: conn} do
      w = world(conn)
      other = member!()
      pin!(other, [w.a, w.b, w.c])
      other_before = prefs(other)
      {:ok, other_view, _} = live(login(build_conn(), other.id), ~p"/chat")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, w.c, 0)
      move(view, w.b, 0)

      assert prefs(other) == other_before
      assert pinned_ids(other_view) == [w.a.id, w.b.id, w.c.id]
      assert pinned_ids(view) == [w.b.id, w.c.id, w.a.id]
    end
  end

  # ── undo ────────────────────────────────────────────────────────────────

  describe "undo_pinned_order" do
    # (j)
    test "after two moves restores the list from before the first", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, w.c, 0)
      first = lv_assigns(view).pinned_undo
      move(view, w.b, 0)
      second = lv_assigns(view).pinned_undo

      assert first.previous == [w.a.id, w.b.id, w.c.id]
      assert second.previous == first.previous
      assert second.written == [w.b.id, w.c.id, w.a.id]
      refute second.ref == first.ref

      render_click(view, "undo_pinned_order", %{})

      assert Sidebar.list_pinned_space_ids(w.user.id) == [w.a.id, w.b.id, w.c.id]
      assert pinned_ids(view) == [w.a.id, w.b.id, w.c.id]
      assert lv_assigns(view).pinned_undo == nil
      assert lv_assigns(view).pinned_announcement == "Pinned order restored"
    end

    # (j) The pin-and-unpin-inside-the-window rule lives in
    # `Sidebar.restore_pinned_order/2` (sidebar_test.exs): through the view,
    # any pin change since the burst's last write fails the written-equality
    # check below, so undo is refused before it would restore.
    test "a second session's move inside the window refuses the first's undo",
         %{conn: conn} do
      w = world(conn)
      {:ok, view1, _} = live(w.conn, ~p"/chat")
      {:ok, view2, _} = live(w.conn, ~p"/chat")

      move(view1, w.c, 0)
      _ = render(view2)
      move(view2, w.a, 0)
      after_two = prefs(w.user)

      render_click(view1, "undo_pinned_order", %{})

      assert prefs(w.user) == after_two
      assert Sidebar.list_pinned_space_ids(w.user.id) == [w.a.id, w.c.id, w.b.id]
      assert lv_assigns(view1).pinned_undo == nil

      assert lv_assigns(view1).pinned_announcement ==
               "Pinned order changed elsewhere, undo unavailable"
    end

    test "an unpin inside the window refuses the undo instead of re-pinning", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, w.c, 0)
      render_click(view, "toggle_pinned", %{"space_id" => w.b.id, "pinned" => "false"})
      render_click(view, "undo_pinned_order", %{})

      assert Sidebar.list_pinned_space_ids(w.user.id) == [w.c.id, w.a.id]
      assert lv_assigns(view).pinned_undo == nil
    end

    # (k)
    test "the current ref's expiry ends the burst; a stale ref does not", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      assert PinnedReorderHooks.undo_ms() == 5_000

      move(view, w.c, 0)
      %{ref: ref} = lv_assigns(view).pinned_undo

      send(view.pid, {:pinned_undo_expired, make_ref()})
      _ = render(view)
      assert %{ref: ^ref} = lv_assigns(view).pinned_undo

      send(view.pid, {:pinned_undo_expired, ref})
      _ = render(view)
      assert lv_assigns(view).pinned_undo == nil

      after_move = prefs(w.user)
      render_click(view, "undo_pinned_order", %{})
      assert prefs(w.user) == after_move
      assert pinned_ids(view) == [w.c.id, w.a.id, w.b.id]
    end
  end

  # ── announcement ────────────────────────────────────────────────────────

  describe "announcement" do
    # (l)
    test "carries the masked name while names are masked", %{conn: conn} do
      user = member!()
      globex = Tenancy.get_org_by_slug!("globex")
      plain_member!(user, globex)
      n = System.unique_integer([:positive])
      org_named = channel!(%{name: "Globex", slug: "globex-pin-#{n}", org_id: globex.id})
      other = channel_in(acme(), "PinOther")
      pin!(user, [other, org_named])
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      render_click(view, "toggle_mask_names", %{"masked" => "true"})
      move(view, org_named, 0)

      announcement = lv_assigns(view).pinned_announcement
      assert announcement =~ ~r/ moved to position 1 of 2$/
      refute announcement =~ "Globex"

      shown =
        view
        |> element(
          "#chat-list [data-space-id='#{org_named.id}'] [data-role='chat-list-row-name']"
        )
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()
        |> String.trim()

      assert announcement == "#{shown} moved to position 1 of 2"
    end

    test "a pinned DM announces the person's name", %{conn: conn} do
      w = world(conn)
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})
      join!(dm, w.user.id, w.user.name)
      other = join!(dm, Ecto.UUID.generate(), "Peer Contact")

      {:ok, _} =
        Chat.post_message(%{
          space_id: dm.id,
          participant_id: other.id,
          content_type: "text",
          content: "hi"
        })

      pin!(w.user, [dm])
      {:ok, view, _} = live(w.conn, ~p"/chat")

      move(view, dm, 0)

      assert lv_assigns(view).pinned_announcement == "Peer Contact moved to position 1 of 4"
    end
  end
end
