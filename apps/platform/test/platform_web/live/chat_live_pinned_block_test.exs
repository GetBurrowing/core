defmodule PlatformWeb.ChatLivePinnedBlockTest do
  @moduledoc """
  Render tests for the Pinned section of the Chat list (task 019fd80f stage
  2; desktop since Burrow redesign 22 stage 2).

  The section holds channels, direct messages and pinned task conversations
  in one flat list. A pinned conversation is LIFTED out of its home section
  (Spaces or Direct), not copied, so every test that asserts presence in
  Pinned also asserts absence from the home section.

  Burrow redesign 22 stage 2 deleted the desktop channel rail. Its Pinned
  block's reorder (arrows, drag, edit-mode chrome), its label chrome, and the
  task-first order went with it: inside every Chat list section rows sort by
  recency and there is no manual order (`Partials.ChatList` `## Order`). Those
  cases are deleted.

  `async: false`: the Agents row (first in Pinned) reads a feature flag from
  application env, held off here so Pinned holds only pins.
  """

  use PlatformWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Platform.Accounts.User
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tasks
  alias Platform.Tasks.ChatPins
  alias Platform.Tenancy

  @flag_key :agents_goal_surface

  setup do
    previous = Application.get_env(:platform, @flag_key)
    on_exit(fn -> Application.put_env(:platform, @flag_key, previous) end)
    Application.put_env(:platform, @flag_key, false)
    :ok
  end

  # ── Fixtures ────────────────────────────────────────────────────────────

  defp insert_user(suffix) do
    Repo.insert!(%User{
      email: "pinned-block-#{suffix}@example.com",
      name: "Pinned Block #{suffix}",
      oidc_sub: "oidc-pinned-block-#{suffix}",
      avatar_url: nil
    })
  end

  defp authed(conn) do
    user = insert_user(System.unique_integer([:positive]))
    {init_test_session(conn, current_user_id: user.id), user}
  end

  defp acme_org, do: Tenancy.get_org_by_slug!("acme")

  # A pinned TASK, which is what fills the second pinned block. Different
  # mechanism from a pinned conversation entirely: a row in `task_chat_pins`
  # rather than an entry in the viewer's preferences.
  defp seed_pinned_task_for(user, title) do
    {:ok, project} =
      Tasks.create_project(%{name: "Pinned Label Project #{System.unique_integer([:positive])}"})

    {:ok, task} =
      Tasks.create_task(%{
        project_id: project.id,
        title: title,
        status: "backlog",
        sponsor_user_id: user.id
      })

    {:ok, %{space: space}} = ChatPins.pin(task.id, %{kind: "user", id: user.email}, user.email)
    %{task: task, space: space}
  end

  defp create_channel(slug, attrs \\ %{}) do
    {:ok, ch} =
      Chat.create_space(
        Map.merge(
          %{name: String.capitalize(slug), slug: slug, kind: "channel", org_id: acme_org().id},
          attrs
        )
      )

    ch
  end

  # A DM only reaches the rail through `Chat.list_user_conversations/2`, which
  # joins participants, so the viewer must actually be in it. The other
  # participant's `display_name` is what `sidebar_display_name/2` renders.
  defp create_dm(user, other_name) do
    {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, _} =
      Chat.add_participant(dm.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: other_name,
        joined_at: DateTime.utc_now()
      })

    dm
  end

  defp mount(conn, path \\ ~p"/chat") do
    case live(conn, path) do
      {:error, {:live_redirect, %{to: to}}} -> live(conn, to)
      ok -> ok
    end
  end

  # ── Selectors ───────────────────────────────────────────────────────────
  #
  # Scoped to `#chat-list-scroller`: the search sheet and the popover carry
  # rows with the same data-role.

  @pinned ~s(#chat-list-scroller [data-role="chat-list-pinned"])
  @spaces ~s(#chat-list-scroller [data-role="chat-list-spaces"])
  @direct ~s(#chat-list-scroller [data-role="chat-list-direct"])

  defp row(section, space_id),
    do: ~s(#{section} a[data-role="chat-list-row"][data-space-id="#{space_id}"])

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp q(view, selector), do: view |> doc() |> LazyHTML.query(selector)
  defp count(view, selector), do: view |> q(selector) |> Enum.count()

  defp text(view, selector),
    do: view |> q(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")

  defp class(view, selector),
    do: view |> q(selector) |> LazyHTML.attribute("class") |> List.first()

  # ── 1. A pinned CHANNEL lifts out of Spaces ─────────────────────────────

  describe "pinning a channel" do
    test "renders in Pinned and is ABSENT from Spaces", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      other = create_channel("stays-put")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _} = mount(conn)

      assert has_element?(view, row(@pinned, channel.id))

      refute has_element?(view, row(@spaces, channel.id)),
             "pinned channel is still rendered in Spaces: copied, not lifted"

      assert has_element?(view, row(@spaces, other.id))
      refute has_element?(view, row(@pinned, other.id))
    end

    test "pinning from the row menu lifts the row without a remount", %{conn: conn} do
      {conn, _user} = authed(conn)
      channel = create_channel("menu-pin")
      _landing = create_channel("aaa-landing")

      {:ok, view, _} = mount(conn)
      assert has_element?(view, row(@spaces, channel.id))

      render_hook(view, "open_row_actions", %{"space_id" => channel.id})

      view
      |> element(
        ~s(#chat-row-actions-dialog [data-role="pin-control"][data-space-id="#{channel.id}"])
      )
      |> render_click()

      assert has_element?(view, row(@pinned, channel.id))
      refute has_element?(view, row(@spaces, channel.id))
    end

    test "survives a channel switch, so every recompute site passes the pin set", %{conn: conn} do
      {conn, user} = authed(conn)
      pinned = create_channel("pinned-one")
      elsewhere = create_channel("elsewhere")

      {:ok, _} = Sidebar.set_space_pinned(user.id, pinned.id, true)

      {:ok, view, _} = mount(conn, ~p"/chat/#{pinned.slug}")
      assert has_element?(view, row(@pinned, pinned.id))

      view
      |> element(row(@spaces, elsewhere.id))
      |> render_click()

      assert has_element?(view, row(@spaces, elsewhere.id) <> ~s([aria-current="page"]))
      assert has_element?(view, row(@pinned, pinned.id))
      refute has_element?(view, row(@spaces, pinned.id))
    end
  end

  # ── 2. A pinned DM lifts out of Direct ──────────────────────────────────

  describe "pinning a direct message" do
    test "renders in Pinned and is ABSENT from Direct", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Alex Rivera")
      other_dm = create_dm(user, "Robin Park")

      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, _} = mount(conn)

      assert has_element?(view, row(@pinned, dm.id))

      refute has_element?(view, row(@direct, dm.id)),
             "pinned DM is still rendered in Direct: copied, not lifted"

      assert has_element?(view, row(@direct, other_dm.id))
      refute has_element?(view, row(@pinned, other_dm.id))
    end
  end

  # ── 3. Unpinning returns each to its OWN home section ───────────────────

  describe "unpinning" do
    test "a channel returns to Spaces, not to Direct", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("returns-home")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, false)

      {:ok, view, _} = mount(conn)

      assert has_element?(view, row(@spaces, channel.id))
      refute has_element?(view, row(@direct, channel.id))
      assert count(view, @pinned) == 0
    end

    test "a DM returns to Direct, not to Spaces", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      dm = create_dm(user, "Saru Designer")

      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, false)

      {:ok, view, _} = mount(conn)

      assert has_element?(view, row(@direct, dm.id))
      refute has_element?(view, row(@spaces, dm.id))
      assert count(view, @pinned) == 0
    end
  end

  # ── 4. Row identity ─────────────────────────────────────────────────────

  describe "row identity inside Pinned" do
    test "a channel row carries the hash glyph and a DM row an avatar and its bare name",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("build-log")
      dm = create_dm(user, "Alex Rivera")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)

      {:ok, view, _} = mount(conn)

      channel_row = row(@pinned, channel.id)
      dm_row = row(@pinned, dm.id)

      assert has_element?(
               view,
               ~s(#{channel_row} [data-role="chat-list-glyph"][data-glyph="hash"])
             )

      assert text(view, ~s(#{channel_row} [data-role="chat-list-row-name"])) == "Build-log"

      # The person carries no hash, and its whole name is there (an EMPTY row
      # also has no hash).
      refute has_element?(view, ~s(#{dm_row} [data-role="chat-list-glyph"]))
      assert has_element?(view, ~s(#{dm_row} [data-role="chat-list-avatar"]))
      assert text(view, ~s(#{dm_row} [data-role="chat-list-row-name"])) == "Alex Rivera"

      # One flat list under one heading.
      assert count(view, ~s(#{@pinned} h2)) == 1
    end
  end

  # ── 5. Empty state renders nothing at all ───────────────────────────────

  describe "empty state" do
    test "a user with no pins renders no Pinned section", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("general")
      _dm = create_dm(user, "Unrelated Person")

      {:ok, view, _} = mount(conn)

      # Positive control: the list rendered its other sections and rows.
      assert has_element?(view, row(@spaces, channel.id))
      assert count(view, @pinned) == 0
    end
  end

  # ── The section's label ─────────────────────────────────────────────────

  describe "section label" do
    test "the section is labelled Pinned", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("gen-migration")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _} = mount(conn)

      # Exact equality: a substring check on "Pinned" passes the two-block
      # headings it replaced.
      assert text(view, "#chat-list-label-pinned") == "Pinned"

      assert has_element?(
               view,
               ~s(#chat-list-scroller section[data-role="chat-list-pinned"][aria-labelledby="chat-list-label-pinned"])
             )
    end
  end

  # ── 6. A pinned row is the same row ─────────────────────────────────────

  describe "a pinned row is the same row it is in Spaces" do
    test "a pinned channel row carries the same classes as it does in Spaces", %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("same-row")
      create_channel("aaa-landing")

      {:ok, view, _} = mount(conn)
      unpinned_class = class(view, row(@spaces, channel.id))
      assert unpinned_class, "the channel has no Spaces row"

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, view, _} = mount(conn)
      pinned_class = class(view, row(@pinned, channel.id))

      assert pinned_class == unpinned_class,
             "pinned row classes #{inspect(pinned_class)} differ from Spaces #{inspect(unpinned_class)}"
    end

    test "a pinned row that is the open channel keeps the standard current treatment",
         %{conn: conn} do
      {conn, user} = authed(conn)
      channel = create_channel("active-pin")

      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)

      {:ok, view, _} = live(conn, ~p"/chat/#{channel.slug}")

      current = row(@pinned, channel.id) <> ~s([aria-current="page"])
      assert has_element?(view, current)
      assert class(view, current) =~ "bg-base-300"
    end
  end

  # ── ONE section, three kinds of row (task 019feec6-73d9) ────────────────

  describe "one Pinned section" do
    test "the list renders exactly one Pinned section holding a channel, a person and a task",
         %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("three-kinds")
      dm = create_dm(user, "Alex Rivera")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, dm.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Three Kinds Task")

      {:ok, view, _} = mount(conn)

      # Both kinds of pin in the fixture, so a re-split counts 2 here.
      assert count(view, @pinned) == 1

      assert text(view, ~s(#{row(@pinned, channel.id)} [data-role="chat-list-row-name"])) ==
               "Three-kinds"

      assert text(view, ~s(#{row(@pinned, dm.id)} [data-role="chat-list-row-name"])) ==
               "Alex Rivera"

      assert text(view, ~s(#{row(@pinned, task_space.id)} [data-role="chat-list-row-name"])) ==
               "Three Kinds Task"

      assert count(view, ~s(#{@pinned} a[data-role="chat-list-row"])) == 3
    end

    test "a pinned channel is still LIFTED out of Spaces with a task pinned too", %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("lifted-chan")
      home = create_channel("stays-home")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Lifted Task")

      {:ok, view, _} = mount(conn)

      assert has_element?(view, row(@pinned, channel.id))
      refute has_element?(view, row(@spaces, channel.id))
      assert has_element?(view, row(@spaces, home.id))
      # A task conversation is never in Spaces.
      refute has_element?(view, row(@spaces, task_space.id))
    end
  end

  # ── One glyph for a task conversation ───────────────────────────────────

  describe "the task glyph" do
    test "a pinned task row carries the task avatar and no hash", %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("glyph-chan")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{space: task_space} = seed_pinned_task_for(user, "Glyph Task")

      {:ok, view, _} = live(conn, ~p"/chat/#{channel.slug}")
      task_row = row(@pinned, task_space.id)

      assert has_element?(view, task_row), "no list row rendered for the pinned task"

      assert has_element?(
               view,
               ~s(#{task_row} [data-role="chat-list-avatar"][data-avatar="task"])
             )

      refute has_element?(view, ~s(#{task_row} [data-role="chat-list-glyph"]))
    end

    test "the task row's menu unpins it from Chat", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")
      %{space: task_space} = seed_pinned_task_for(user, "Menu Task")

      {:ok, view, _} = mount(conn)

      menu =
        view
        |> render_hook("open_row_actions", %{"space_id" => task_space.id})
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(
          ~s([data-role="pinned-task-rail-unpin"][data-space-id="#{task_space.id}"])
        )

      assert Enum.count(menu) == 1, "the task row's menu has no Unpin item"
      refute has_element?(view, ~s(#chat-row-actions-dialog [data-role="pin-control"]))
    end
  end

  describe "unread counts inside Pinned" do
    test "a pinned task conversation still resolves its unread", %{conn: conn} do
      {conn, user} = authed(conn)
      create_channel("general")

      %{space: space} = seed_pinned_task_for(user, "Noisy Task")
      seed_unread_for(user, space, 3)

      # Asserted BEFORE the render check: on a fixture with no unread the
      # render assertion below would be vacuous.
      counts = Chat.unread_counts_for_user(user.id)

      assert Map.get(counts, space.id, 0) == 3,
             "fixture produced #{Map.get(counts, space.id, 0)} unread, expected 3"

      {:ok, view, _} = mount(conn)
      task_row = row(@pinned, space.id)

      assert has_element?(view, task_row <> ~s([data-unread="true"]))

      assert has_element?(
               view,
               ~s(#{task_row} [data-role="chat-list-unread-dot"][aria-label="3 unread"])
             )
    end
  end

  describe "the vanishing row" do
    test "completing the task removes its row and nothing marks the departure",
         %{conn: conn} do
      {conn, user} = authed(conn)

      channel = create_channel("outlives-the-task")
      {:ok, _} = Sidebar.set_space_pinned(user.id, channel.id, true)
      %{task: task, space: task_space} = seed_pinned_task_for(user, "Finishing Task")

      {:ok, view, _} = mount(conn)
      assert has_element?(view, row(@pinned, task_space.id))

      {:ok, task} = Tasks.transition_task_status(task, "in_progress")
      {:ok, _task} = Tasks.transition_task_status(task, "done")

      {:ok, view, html} = mount(conn)

      refute has_element?(view, row(@pinned, task_space.id)),
             "a done task's conversation is still pinned in the list"

      # The section survives with the rest of its rows, still as ONE section.
      assert has_element?(view, row(@pinned, channel.id))
      assert count(view, @pinned) == 1

      refute html =~ "task finished"
      refute html =~ "no longer pinned"
    end
  end

  # Real unread for `user` in `space`: the viewer joins with no read cursor,
  # someone else posts. `count_unread/3` excludes the viewer's own messages
  # and `unread_counts_for_user/1` reads off the viewer's participant row, so
  # both participants are required for the count to be non-zero.
  defp seed_unread_for(user, space, count) do
    {:ok, _viewer} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    {:ok, author} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: Ecto.UUID.generate(),
        display_name: "Someone Else",
        joined_at: DateTime.utc_now()
      })

    for n <- 1..count do
      {:ok, _} =
        Chat.post_message(%{
          space_id: space.id,
          participant_id: author.id,
          content_type: "text",
          content: "message #{n}"
        })
    end

    :ok
  end

  # ── Unread weight (task 01a166bf stage 2) ────────────────────────────────

  describe "unread weight in the list" do
    test "unread name semibold, read name regular, across Pinned, Spaces and Direct",
         %{conn: conn} do
      {conn, user} = authed(conn)
      n = System.unique_integer([:positive])

      # Four rows across three sections: Pinned (channel unread, DM read),
      # Direct (DM unread) and Spaces (channel read).
      unread_pin = create_channel("weight-pin-#{n}")
      read_channel = create_channel("weight-read-#{n}")
      unread_dm = create_dm(user, "Unread Person")
      read_dm = create_dm(user, "Read Person")

      for ch <- [unread_pin, read_channel] do
        {:ok, _} =
          Chat.add_participant(ch.id, %{
            participant_type: "user",
            participant_id: user.id,
            display_name: user.name,
            joined_at: DateTime.utc_now()
          })
      end

      post = fn space, from_me? ->
        p =
          Enum.find(Chat.list_participants(space.id), fn p ->
            p.participant_id == user.id == from_me?
          end) ||
            elem(
              Chat.add_participant(space.id, %{
                participant_type: "user",
                participant_id: Ecto.UUID.generate(),
                display_name: "Poster",
                joined_at: DateTime.utc_now()
              }),
              1
            )

        {:ok, _} =
          Chat.post_message(%{
            space_id: space.id,
            participant_id: p.id,
            content_type: "text",
            content: "weight #{n}"
          })
      end

      post.(unread_pin, false)
      post.(read_channel, true)
      post.(unread_dm, false)
      post.(read_dm, true)

      {:ok, _} = Sidebar.set_space_pinned(user.id, unread_pin.id, true)
      {:ok, _} = Sidebar.set_space_pinned(user.id, read_dm.id, true)

      {:ok, view, _} = mount(conn)

      rows = [
        {unread_pin, @pinned, true, "chat-list-unread-count"},
        {read_dm, @pinned, false, "chat-list-unread-dot"},
        {unread_dm, @direct, true, "chat-list-unread-dot"},
        {read_channel, @spaces, false, "chat-list-unread-count"}
      ]

      # Positive control: every row renders where it belongs.
      for {s, section, _, _} <- rows do
        assert has_element?(view, row(section, s.id)), "no list row for #{s.id}"
      end

      for {s, section, unread?, marker} <- rows do
        name = ~s(#{row(section, s.id)} [data-role="chat-list-row-name"])

        if unread? do
          assert has_element?(view, name <> ".font-semibold")
          assert has_element?(view, ~s(#{row(section, s.id)} [data-role="#{marker}"]))
        else
          assert has_element?(view, name <> ".font-normal")
          refute has_element?(view, name <> ".font-semibold")
          refute has_element?(view, ~s(#{row(section, s.id)} [data-role="#{marker}"]))
        end
      end
    end
  end
end
