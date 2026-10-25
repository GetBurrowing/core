defmodule PlatformWeb.ChatLivePinnedReorderChromeTest do
  @moduledoc """
  The desktop chrome of the pinned reorder (task 01a1557b stage 2, Burrow
  redesign 25): the grip on pinned conversation rows, the row data the
  stage 3 hook reads, Move up / Move down in the desktop row menu, the
  announcer and the single undo toast. Stage 1's
  `PlatformWeb.ChatLive.PinnedReorderHooks` owns the events.

  Elements are found with `has_element?/2` or `LazyHTML.query/2`, never
  `LazyHTML.filter/2`. Every absence sits beside a presence on the same
  render.

  `async: false`: the Agents row reads a feature flag from application env.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Restrictions
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins
  alias Platform.Tenancy

  @flag_key :agents_goal_surface
  @grip "[data-role=chat-list-row-grip]"

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

  defp channel_in(name) do
    n = System.unique_integer([:positive])
    channel!(%{name: "#{name}#{n}", slug: "pin-chrome-#{n}", org_id: acme().id})
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

  defp dm!(user, other_name) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: true})
    join!(space, user.id, user.name)
    other = join!(space, Ecto.UUID.generate(), other_name)

    {:ok, _} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: other.id,
        content_type: "text",
        content: "hello from #{other_name}"
      })

    space
  end

  defp pin!(user, spaces) do
    for s <- spaces, do: {:ok, _} = Sidebar.set_space_pinned(user.id, s.id, true)
  end

  defp seed_task_pin!(user) do
    {:ok, project} =
      Tasks.create_project(%{name: "Pin Chrome Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: "Pin Chrome Task",
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} = ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)
    space
  end

  # Three pinned channels, A, B and C, in that order.
  defp world(conn) do
    user = member!()
    [a, b, c] = for n <- ~w(ChromeA ChromeB ChromeC), do: channel_in(n)
    pin!(user, [a, b, c])
    %{conn: login(conn, user.id), user: user, a: a, b: b, c: c}
  end

  defp doc(view), do: view |> element("#chat-list") |> render() |> LazyHTML.from_fragment()

  defp count(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> Enum.count()

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  defp stored(user), do: Sidebar.list_pinned_space_ids(user.id)

  defp step(view, space, dir),
    do: render_hook(view, "move_pinned_step", %{"space_id" => space.id, "direction" => dir})

  # ── the grip ────────────────────────────────────────────────────────────

  describe "grip" do
    test "one grip per linked pinned conversation row; none on task, Agents, restricted or unpinned rows",
         %{conn: conn} do
      Application.put_env(:platform, @flag_key, true)
      user = member!()

      # Agents row: a space with a leader agent.
      n = System.unique_integer([:positive])

      agent =
        Repo.insert!(%Agent{slug: "pin-chrome-agent-#{n}", name: "Leader", status: "active"})

      {:ok, agents_space} =
        Chat.create_space(%{
          name: "Agents #{n}",
          slug: "pin-chrome-agents-#{n}",
          kind: "channel",
          goal: "Keep the pins in order",
          leader_agent_id: agent.id
        })

      join!(agents_space, user.id, user.name)

      a = channel_in("GripA")
      b = channel_in("GripB")
      pinned_dm = dm!(user, "Pinned Peer")
      _loose_dm = dm!(user, "Loose Peer")
      _loose = channel_in("GripLoose")

      admin = create_user!()
      plain_member!(admin, acme(), "admin")
      vault = channel_in("GripVault")
      {:ok, _} = Restrictions.restrict_space(vault, ["admin"], admin.id)

      archived = channel_in("GripOld")
      {:ok, _} = Chat.archive_space(archived)

      task_space = seed_task_pin!(user)
      pin!(user, [a, vault, pinned_dm, b])

      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")
      render_click(view, "toggle_archived_section", %{})

      # Presence: every row kind under test really rendered.
      assert has_element?(view, ~s(#chat-list-scroller a[data-row-kind="agents"]))
      assert has_element?(view, "#chat-list-row-#{task_space.id}")

      assert has_element?(
               view,
               "[data-role=chat-list-pinned] [data-role=restricted-channel-row][data-space-id='#{vault.id}']"
             )

      assert count(view, "[data-role=chat-list-spaces] [data-role=chat-list-row]") > 0
      assert count(view, "[data-role=chat-list-direct] [data-role=chat-list-row]") > 0
      assert count(view, "[data-role=chat-list-archived] [data-role=chat-list-row]") > 0

      # Exactly the three linked conversation pins carry a grip, one each.
      assert count(view, @grip) == 3

      for s <- [a, pinned_dm, b] do
        assert count(view, "#chat-list-row-#{s.id}[data-reorder=true] #{@grip}") == 1
      end

      # None anywhere else.
      assert count(view, "#chat-list-row-#{task_space.id} #{@grip}") == 0
      assert count(view, ~s(a[data-row-kind="agents"] #{@grip})) == 0
      assert count(view, "[data-role=restricted-channel-row] #{@grip}") == 0

      for section <- ~w(spaces direct archived) do
        assert count(view, "[data-role=chat-list-#{section}] #{@grip}") == 0
        assert count(view, "[data-role=chat-list-#{section}] [data-reorder]") == 0
      end

      refute has_element?(view, "#chat-list-row-#{task_space.id}[data-reorder]")
      refute has_element?(view, ~s(a[data-row-kind="agents"][data-reorder]))

      # The restricted pin carries its position for the stage 3 hook, and
      # no data-reorder.
      assert has_element?(
               view,
               "[data-role=restricted-channel-row][data-space-id='#{vault.id}'][data-pinned-position='1']"
             )

      refute has_element?(view, "[data-role=restricted-channel-row][data-reorder]")
    end

    test "the grip is hidden at rest; every visibility class it has is lg:", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      classes =
        view
        |> doc()
        |> LazyHTML.query(@grip)
        |> LazyHTML.attribute("class")

      assert length(classes) == 3

      for class <- classes do
        tokens = String.split(class)
        assert "hidden" in tokens

        visibility =
          tokens
          |> Enum.reject(&(&1 == "hidden"))
          |> Enum.filter(
            &Regex.match?(~r/(^|:)(hidden|flex|inline-flex|block|inline|invisible|visible)$/, &1)
          )

        assert "lg:group-hover/row:inline-flex" in visibility
        assert "lg:group-focus-visible/row:inline-flex" in visibility
        assert Enum.all?(visibility, &String.starts_with?(&1, "lg:")), inspect(visibility)
      end
    end

    test "every class token in #chat-list containing hover starts with lg:", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      hover =
        view
        |> doc()
        |> LazyHTML.query("[class]")
        |> LazyHTML.attribute("class")
        |> Enum.flat_map(&String.split/1)
        |> Enum.filter(&String.contains?(&1, "hover"))

      # Positive control: the grip's reveal is among them.
      assert "lg:group-hover/row:inline-flex" in hover
      assert Enum.reject(hover, &String.starts_with?(&1, "lg:")) == []
    end

    test "every row link is group/row relative, pinned or not", %{conn: conn} do
      w = world(conn)
      _loose = channel_in("Loose")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      links = view |> doc() |> LazyHTML.query("a[data-role=chat-list-row]")
      assert Enum.count(links) >= 4

      for class <- LazyHTML.attribute(links, "class") do
        tokens = String.split(class)
        assert "group/row" in tokens and "relative" in tokens, class
      end
    end

    test "data-pinned-position and data-pinned-count for three pins", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for {s, i} <- Enum.with_index([w.a, w.b, w.c]) do
        assert has_element?(
                 view,
                 "#chat-list-row-#{s.id}[data-reorder=true][data-pinned-position='#{i}'][data-pinned-count='3']"
               )
      end

      step(view, w.c, "up")

      for {s, i} <- Enum.with_index([w.a, w.c, w.b]) do
        assert has_element?(view, "#chat-list-row-#{s.id}[data-pinned-position='#{i}']")
      end
    end

    test "with Pinned folded no grip renders", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      assert count(view, @grip) == 3

      view
      |> element(
        "#chat-list button[data-role='chat-list-section-toggle'][data-section='chat-list:pinned']"
      )
      |> render_click()

      assert has_element?(
               view,
               "#chat-list button[data-section='chat-list:pinned'][aria-expanded='false']"
             )

      assert count(view, @grip) == 0
      assert count(view, "[data-reorder]") == 0
    end
  end

  # ── the desktop row menu ───────────────────────────────────────────────

  describe "row menu" do
    test "Move up is disabled on the first conversation and Move down on the last",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_hook(view, "open_row_actions", %{"space_id" => w.a.id})
      dialog = "#chat-row-actions-dialog"
      assert has_element?(view, "#{dialog} button[data-role=row-actions-move-up][disabled]")
      assert has_element?(view, "#{dialog} button[data-role=row-actions-move-down]")
      refute has_element?(view, "#{dialog} button[data-role=row-actions-move-down][disabled]")

      render_hook(view, "open_row_actions", %{"space_id" => w.c.id})
      assert has_element?(view, "#{dialog} button[data-role=row-actions-move-down][disabled]")
      refute has_element?(view, "#{dialog} button[data-role=row-actions-move-up][disabled]")

      render_hook(view, "open_row_actions", %{"space_id" => w.b.id})
      refute has_element?(view, "#{dialog} button[disabled]")
    end

    test "Move down persists the move and closes the dialog", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_hook(view, "open_row_actions", %{"space_id" => w.a.id})

      view
      |> element("#chat-row-actions-dialog button[data-role=row-actions-move-down]")
      |> render_click()

      assert stored(w.user) == [w.b.id, w.a.id, w.c.id]
      refute has_element?(view, "#chat-row-actions-dialog")
      assert lv_assigns(view).row_actions_space_id == nil
    end

    test "no Move items for an unpinned or a task target", %{conn: conn} do
      w = world(conn)
      loose = channel_in("Loose")
      task_space = seed_task_pin!(w.user)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_hook(view, "open_row_actions", %{"space_id" => loose.id})
      assert has_element?(view, "#chat-row-actions-dialog [data-role=pin-control]")
      refute has_element?(view, "#chat-row-actions-dialog [data-role^=row-actions-move]")

      render_hook(view, "open_row_actions", %{"space_id" => task_space.id})
      assert has_element?(view, "#chat-row-actions-dialog [data-role=pinned-task-rail-unpin]")
      refute has_element?(view, "#chat-row-actions-dialog [data-role^=row-actions-move]")
    end

    test "the phone row sheet has no Move up or Move down", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_hook(view, "open_list_sheet", %{"sheet" => "row", "space_id" => w.b.id})
      sheet = "#chat-row-actions-sheet"
      assert has_element?(view, "#{sheet} [data-role=row-actions-pin]")
      refute has_element?(view, "#{sheet} [data-role^=row-actions-move]")
      refute has_element?(view, sheet, "Move up")
      refute has_element?(view, sheet, "Move down")
    end
  end

  # ── undo toast ─────────────────────────────────────────────────────────

  describe "undo toast" do
    test "two moves give exactly one toast; Undo restores the order and removes it",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      refute has_element?(view, "#pinned-undo-toast")

      step(view, w.c, "up")
      step(view, w.c, "up")
      assert stored(w.user) == [w.c.id, w.a.id, w.b.id]

      assert count(view, "#pinned-undo-toast") == 1
      assert count(view, "[data-role=pinned-undo-toast]") == 1
      assert has_element?(view, "#pinned-undo-toast", "Pinned order changed")

      view
      |> element("#pinned-undo-toast button[data-role=pinned-undo-button]", "Undo")
      |> render_click()

      assert stored(w.user) == [w.a.id, w.b.id, w.c.id]
      refute has_element?(view, "#pinned-undo-toast")
    end

    test "the toast is desktop only, with a 44px Undo", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      step(view, w.b, "up")

      assert has_element?(view, "#pinned-undo-toast.hidden.lg\\:flex[role=status]")

      assert has_element?(
               view,
               "#pinned-undo-toast button[type=button][phx-click=undo_pinned_order].min-h-11"
             )
    end

    test "the matching expiry removes the toast", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      step(view, w.b, "up")
      assert has_element?(view, "#pinned-undo-toast")

      %{ref: ref} = lv_assigns(view).pinned_undo
      send(view.pid, {:pinned_undo_expired, ref})

      refute has_element?(view, "#pinned-undo-toast")
    end
  end

  # ── announcer ──────────────────────────────────────────────────────────

  describe "announcer" do
    test "is always rendered, empty at rest", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert has_element?(
               view,
               "#chat-list #pinned-reorder-announcer[role=status][aria-live=polite].sr-only"
             )

      text = view |> doc() |> LazyHTML.query("#pinned-reorder-announcer") |> LazyHTML.text()
      assert String.trim(text) == ""
    end

    test "moving ops from position 3 to 1 says so", %{conn: conn} do
      user = member!()
      a = channel_in("AnnA")
      b = channel_in("AnnB")
      n = System.unique_integer([:positive])
      ops = channel!(%{name: "ops", slug: "pin-chrome-ops-#{n}", org_id: acme().id})
      pin!(user, [a, b, ops])
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      render_hook(view, "move_pinned_row", %{"space_id" => ops.id, "to_position" => 0})

      text = view |> doc() |> LazyHTML.query("#pinned-reorder-announcer") |> LazyHTML.text()
      assert String.trim(text) == "ops moved to position 1 of 3"
    end
  end

  describe "PinnedReorder hook placement (stage 3)" do
    test "#chat-list-rows-pinned carries the hook; Spaces, Direct and Archived rows do not",
         %{conn: conn} do
      w = world(conn)
      _unpinned = channel_in("HookSpaces")
      _dm = dm!(w.user, "Hook Person")
      archived = channel_in("HookArchived")
      {:ok, _} = Chat.archive_space(archived)

      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_hook(view, "toggle_archived_section", %{})

      html = doc(view)

      assert html
             |> LazyHTML.query("#chat-list-rows-pinned[phx-hook=PinnedReorder]")
             |> Enum.count() ==
               1

      # The overlay the hook draws into: its own id, never patched.
      assert html
             |> LazyHTML.query(
               "#chat-list-rows-pinned > #pinned-reorder-overlay[phx-update=ignore][aria-hidden=true]"
             )
             |> Enum.count() == 1

      for section <- ~w(spaces direct archived) do
        rows = LazyHTML.query(html, "#chat-list-rows-#{section}")
        assert Enum.count(rows) == 1, "#chat-list-rows-#{section} should render"
        assert LazyHTML.query(html, "#chat-list-rows-#{section}[phx-hook]") |> Enum.count() == 0

        assert LazyHTML.query(html, "#chat-list-rows-#{section} [phx-hook=PinnedReorder]")
               |> Enum.count() == 0
      end

      # One container in the whole list carries it.
      assert html |> LazyHTML.query("[phx-hook=PinnedReorder]") |> Enum.count() == 1
    end
  end
end
