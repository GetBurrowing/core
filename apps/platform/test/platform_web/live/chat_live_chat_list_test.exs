defmodule PlatformWeb.ChatLiveChatListTest do
  @moduledoc """
  The phone Chat tab: the conversation list at `/chat` (task 01a1557a-8562,
  Burrow redesign rung 6, stage 2).

  Every absence below sits beside its positive control on the same fixture:
  the masked refutes beside the unmasked presence, the hover refute beside a
  class known to be there, the phx-click refute beside a link count. A refute
  that cannot be seen to fail proves nothing.

  `async: false`: the Agents block reads a feature flag from application env.
  """

  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Restrictions
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
  alias PlatformWeb.ChatLive
  alias PlatformWeb.ChatLive.ChatListHooks
  alias PlatformWeb.ChatLive.Partials.ChatList
  alias PlatformWeb.SpaceTopics

  @flag_key :agents_goal_surface

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

  defp channel_in(org, name, slug \\ nil) do
    n = System.unique_integer([:positive])

    channel!(%{name: name, slug: slug || "list-#{n}-#{String.downcase(name)}", org_id: org.id})
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

  defp say!(space, participant, content) do
    {:ok, msg} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    msg
  end

  defp dm!(user, other_name) do
    {:ok, space} = Chat.create_space(%{kind: "dm", is_direct: true})
    me = join!(space, user.id, user.name)
    other = join!(space, Ecto.UUID.generate(), other_name)
    {space, me, other}
  end

  # A world with two channels (one carrying a message), a DM with a message,
  # and the viewer.
  defp world(conn) do
    user = member!()
    alpha = channel_in(acme(), "Alpha")
    beta = channel_in(acme(), "Beta")
    poster = join!(alpha, Ecto.UUID.generate(), "Priya")
    say!(alpha, poster, "the alpha headline")

    {dm, _me, moore} = dm!(user, "Moore")
    say!(dm, moore, "a direct hello")

    %{
      conn: login(conn, user.id),
      user: user,
      alpha: alpha,
      beta: beta,
      dm: dm,
      poster: poster,
      moore: moore
    }
  end

  defp list_html(view) do
    view |> element("#chat-list") |> render()
  end

  defp ids_in(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("data-space-id")
  end

  # The ids in `ids`, in the order `list` holds them.
  defp keep(list, ids), do: Enum.filter(list, &(&1 in ids))

  # Back-date one message: `seconds` back from a fixed hour ago, so a lower
  # number is newer and every fixture time precedes any message a test posts
  # live.
  defp stamp!(msg, seconds) do
    at = DateTime.add(DateTime.utc_now(), -3600 - seconds, :second)

    Repo.update_all(from(m in Platform.Chat.Message, where: m.id == ^msg.id),
      set: [inserted_at: at]
    )
  end

  defp lv_socket(view), do: :sys.get_state(view.pid).socket
  defp lv_assigns(view), do: lv_socket(view).assigns

  @list_banner "#chat-list [data-role='chat-list-notification-banner']"

  # The existing org-derived rule, the same one the rail and the drawer use
  # (Saru, canvas 01a15d7c rev 4): `Globex` names a seeded org and masks; a
  # project-code channel and a person's name do not. Every excerpt becomes
  # one fixed placeholder, and a masked row's avatar a neutral disc.
  defp mask_world(conn) do
    user = member!()
    globex = Tenancy.get_org_by_slug!("globex")
    plain_member!(user, globex)
    org_named = channel_in(globex, "Globex", "globex-#{System.unique_integer([:positive])}")
    atlas = channel_in(acme(), "atlas")
    p1 = join!(org_named, Ecto.UUID.generate(), "Quinn")
    p2 = join!(atlas, Ecto.UUID.generate(), "Quinn")
    say!(org_named, p1, "zebra crossing numbers")
    say!(atlas, p2, "yonder project notes")
    {dm, _me, moore} = dm!(user, "Moore Person")
    say!(dm, moore, "xylophone practice")

    %{
      conn: login(conn, user.id),
      org_named: org_named,
      atlas: atlas,
      dm: dm
    }
  end

  defp mask(view, on?) do
    render_click(view, "toggle_mask_names", %{"masked" => to_string(on?)})
  end

  defp avatar_text(html, space_id) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-space-id="#{space_id}"] [data-role="chat-list-avatar"]))
    |> LazyHTML.text()
    |> String.trim()
  end

  # ── layout and order ────────────────────────────────────────────────────

  describe "GET /chat" do
    test "renders the list in place, with no redirect", %{conn: conn} do
      w = world(conn)

      assert {:ok, view, html} = live(w.conn, ~p"/chat")
      assert html =~ ~s(id="chat-list")
      assert lv_assigns(view).active_space == nil

      list = list_html(view)
      assert list =~ "Chat"
      assert has_element?(view, "#chat-list [data-role='chat-list-subtitle']")
      assert has_element?(view, "#chat-list #chat-list-scroller.clears-tab-bar")
      # Burrow redesign 22 stage 2: the list is the desktop list pane too, so
      # `/chat` no longer hides it at lg (it was `lg:hidden` while the desktop
      # channel rail existed).
      refute has_element?(view, "#chat-list[class*='lg:hidden']")
    end

    test "each section orders by latest message, newest first; Pinned keeps the saved order",
         %{conn: conn} do
      w = world(conn)
      globex = Tenancy.get_org_by_slug!("globex")
      plain_member!(w.user, globex)
      gamma = channel_in(globex, "Gamma")
      delta = channel_in(globex, "Delta")
      {dm2, _me, nash} = dm!(w.user, "Nash")
      pin_one = channel_in(acme(), "PinOne")
      pin_two = channel_in(acme(), "PinTwo")
      _ = Sidebar.set_space_pinned(w.user.id, pin_one.id, true)
      _ = Sidebar.set_space_pinned(w.user.id, pin_two.id, true)

      # The curated orders this stage overrides, read off a first mount.
      {:ok, first, _} = live(w.conn, ~p"/chat")
      a = lv_assigns(first)
      mine = [w.alpha.id, w.beta.id, gamma.id, delta.id]

      curated_spaces =
        a.sidebar_sections |> Sidebar.flatten_sections() |> Enum.map(& &1.id) |> keep(mine)

      rail_dms = a.channel_sections.dms |> Enum.map(& &1.id) |> keep([w.dm.id, dm2.id])

      # Two sub-org sections: Gamma and Delta sit in their own section.
      assert Enum.any?(a.sidebar_sections, fn %{channels: c} ->
               Enum.sort(Enum.map(c, & &1.id)) == Enum.sort([gamma.id, delta.id])
             end)

      assert length(curated_spaces) == 4 and length(rail_dms) == 2

      # Recency the reverse of each curated order. Beta never gets a message,
      # so it goes last whatever its curated place.
      spaces_by_recency = Enum.reverse(curated_spaces -- [w.beta.id])
      dms_by_recency = Enum.reverse(rail_dms)

      posters = %{
        w.alpha.id => w.poster,
        gamma.id => join!(gamma, Ecto.UUID.generate(), "Quinn"),
        delta.id => join!(delta, Ecto.UUID.generate(), "Quinn"),
        w.dm.id => w.moore,
        dm2.id => nash,
        pin_one.id => join!(pin_one, Ecto.UUID.generate(), "Quinn"),
        pin_two.id => join!(pin_two, Ecto.UUID.generate(), "Quinn")
      }

      spaces = Map.new([w.alpha, gamma, delta, w.dm, dm2, pin_one, pin_two], &{&1.id, &1})

      # world/1's own messages (Alpha's, Moore's) go back a day, so only the
      # stamps below decide. Newest first: index 0 gets the latest time.
      # Pinned: PinTwo newer.
      Repo.update_all(
        from(m in Platform.Chat.Message, where: m.space_id in ^[w.alpha.id, w.dm.id]),
        set: [inserted_at: DateTime.add(DateTime.utc_now(), -86_400, :second)]
      )

      for {ids, base} <- [
            {spaces_by_recency, 0},
            {dms_by_recency, 10},
            {[pin_two.id, pin_one.id], 20}
          ],
          {id, i} <- Enum.with_index(ids) do
        msg = say!(Map.fetch!(spaces, id), Map.fetch!(posters, id), "recency #{i}")
        stamp!(msg, base + i)
      end

      # The older DM gets a thread reply, posted now. The rail orders Direct
      # by its newest message of ANY kind (`list_user_conversations/2`), so
      # it lifts that DM; the list's key is the newest TOP-LEVEL message, so
      # it does not. That is what tells a sorted Direct from the rail's.
      [_, older_dm] = dms_by_recency
      [parent] = Chat.list_messages(older_dm, limit: 1)
      {:ok, thread} = Chat.create_thread(older_dm, %{parent_message_id: parent.id})

      {:ok, _} =
        Chat.post_message(%{
          space_id: older_dm,
          participant_id: Map.fetch!(posters, older_dm).id,
          thread_id: thread.id,
          content_type: "text",
          content: "a late thread reply"
        })

      {:ok, view, _} = live(w.conn, ~p"/chat")
      html = list_html(view)

      rail_dms_now =
        lv_assigns(view).channel_sections.dms |> Enum.map(& &1.id) |> keep(dms_by_recency)

      assert rail_dms_now == Enum.reverse(dms_by_recency)

      spaces_dom =
        html |> ids_in("[data-role='chat-list-spaces'] [data-role='chat-list-row']") |> keep(mine)

      assert spaces_dom == spaces_by_recency ++ [w.beta.id]
      refute spaces_dom == curated_spaces

      dms_dom =
        html
        |> ids_in("[data-role='chat-list-direct'] [data-role='chat-list-row']")
        |> keep([w.dm.id, dm2.id])

      assert dms_dom == dms_by_recency
      refute dms_dom == rail_dms_now

      # Pinned is the exception (task 01a1557b): stored order PinOne, PinTwo
      # wins over recency, which would put the newer PinTwo first.
      assert Sidebar.list_pinned_space_ids(w.user.id) |> keep([pin_one.id, pin_two.id]) ==
               [pin_one.id, pin_two.id]

      assert ids_in(html, "[data-role='chat-list-pinned'] [data-role='chat-list-row']") ==
               [pin_one.id, pin_two.id]
    end

    test "a new message moves its conversation to the top of its section without reload",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      spaces = "[data-role='chat-list-spaces'] [data-role='chat-list-row']"
      mine = [w.alpha.id, w.beta.id]

      # Beta has no message, so it is the lowest of the two.
      assert list_html(view) |> ids_in(spaces) |> keep(mine) == [w.alpha.id, w.beta.id]

      other = join!(w.beta, Ecto.UUID.generate(), "Riley")
      say!(w.beta, other, "beta wakes up")

      html = render(view) && list_html(view)
      assert html |> ids_in(spaces) |> keep(mine) == [w.beta.id, w.alpha.id]
      assert hd(ids_in(html, spaces)) == w.beta.id
    end

    test "PINNED leads with the Agents row, then the pinned conversations", %{conn: conn} do
      w = world(conn)
      agent = Repo.insert!(%Agent{slug: "list-lead-#{w.user.id}", name: "Lead", status: "active"})

      agents_space =
        channel!(%{
          name: "Agents",
          slug: "list-agents-#{System.unique_integer([:positive])}",
          goal: "Ship the list",
          leader_agent_id: agent.id,
          org_id: acme().id
        })

      Application.put_env(:platform, @flag_key, true)
      _ = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)

      {:ok, view, _} = live(w.conn, ~p"/chat")
      html = list_html(view)

      assert ids_in(html, "[data-role='chat-list-pinned'] [data-role='chat-list-row']") ==
               [agents_space.id, w.beta.id]

      {pinned_at, _} = :binary.match(html, ~s(data-role="chat-list-pinned"))
      {spaces_at, _} = :binary.match(html, ~s(data-role="chat-list-spaces"))
      assert pinned_at < spaces_at

      # A pinned channel is not listed twice, and the agents space not at all
      # under Spaces.
      spaces = ids_in(html, "[data-role='chat-list-spaces'] [data-role='chat-list-row']")
      refute w.beta.id in spaces
      refute agents_space.id in spaces
    end

    test "PINNED is absent when nothing is pinned and the Agents block is off", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      refute has_element?(view, "#chat-list [data-role='chat-list-pinned']")
      # Positive control: the sibling sections render on the same page.
      assert has_element?(view, "#chat-list [data-role='chat-list-spaces']")
    end
  end

  # ── the desktop landing ─────────────────────────────────────────────────

  describe "chat_viewport" do
    test "below=false patches into the first unrestricted channel", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      [first | _] = lv_assigns(view).channels
      render_hook(view, "chat_viewport", %{"below" => false})

      assert_patch(view, ~p"/chat/#{PlatformWeb.ChatLive.space_nav_target(first)}")
      assert lv_assigns(view).active_space.id == first.id
    end

    test "below=true stays on the list", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      render_hook(view, "chat_viewport", %{"below" => true})

      # Still the list: no patch moved the live action or opened a space.
      assert lv_assigns(view).live_action == :index
      assert lv_assigns(view).active_space == nil
      assert has_element?(view, "#chat-list")
    end

    test "the restricted-deep-link flash keeps /chat even on desktop", %{conn: conn} do
      org = acme()
      member = member!()
      admin = create_user!()
      plain_member!(admin, org, "admin")
      finance = channel_in(org, "Finance")
      _lobby = channel_in(org, "Lobby")
      add_user!(finance.id, admin.id)
      {:ok, _} = Restrictions.restrict_space(finance, ["admin"], admin.id)

      member_conn = login(conn, member.id)
      denied = live(member_conn, ~p"/chat/#{finance.id}")
      assert {:error, {:live_redirect, %{to: "/chat"}}} = denied
      {:ok, view, html} = follow_redirect(denied, member_conn, "/chat")
      assert html =~ "Restricted, ask an admin"

      render_hook(view, "chat_viewport", %{"below" => false})
      assert lv_assigns(view).live_action == :index
      assert lv_assigns(view).active_space == nil
    end

    test "the hook element is on /chat and absent inside a channel", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert has_element?(
               view,
               "#chat-viewport-breakpoint[phx-hook='ViewportBreakpoint'][data-event='chat_viewport'][data-breakpoint='1024']"
             )

      {:ok, inside, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")
      refute has_element?(inside, "#chat-viewport-breakpoint")
    end
  end

  # ── leaving a space ─────────────────────────────────────────────────────

  describe "back to the list" do
    test "releases the space; a message there then counts as unread and updates the excerpt",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")
      assert lv_assigns(view).active_space.id == w.alpha.id
      assert SpaceTopics.held_by?(lv_socket(view), w.alpha.id, :chat_active)

      render_patch(view, ~p"/chat")
      assert lv_assigns(view).active_space == nil

      # `leave_active_space/1` ran: the active-space hold is released. The
      # rail hold stays, which is what still delivers the message below.
      refute SpaceTopics.held_by?(lv_socket(view), w.alpha.id, :chat_active)
      assert SpaceTopics.held_by?(lv_socket(view), w.alpha.id, :chat_rail)

      row = "#chat-list [data-role='chat-list-row'][data-space-id='#{w.alpha.id}']"
      refute has_element?(view, "#{row} [data-role='chat-list-unread-count']")

      say!(w.alpha, w.poster, "fresh news after leaving")

      # A dense channel row: the count pill, never the dot.
      assert view |> element("#{row} [data-role='chat-list-unread-count']") |> render() =~
               "1 unread"

      refute has_element?(view, "#{row} [data-role='chat-list-unread-dot']")

      # The excerpt still updates (recency order reads it) but the channel
      # row draws no preview.
      _ = render(view)
      assert lv_assigns(view).list_excerpts[w.alpha.id].content == "fresh news after leaving"
      refute has_element?(view, "#{row} [data-role='chat-list-excerpt']")
    end

    test "a deleted newest message falls back to the previous excerpt", %{conn: conn} do
      w = world(conn)
      {dm, _me, moore} = dm!(w.user, "Vale")
      _older = say!(dm, moore, "the older line")
      newest = say!(dm, moore, "about to vanish")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      excerpt = "#chat-list [data-space-id='#{dm.id}'] [data-role='chat-list-excerpt']"
      assert view |> element(excerpt) |> render() =~ "about to vanish"

      {:ok, _} = Chat.delete_message(newest)
      _ = render(view)

      html = view |> element(excerpt) |> render()
      assert html =~ "the older line"
      refute html =~ "about to vanish"
    end

    test "the back chevron is a patch link to /chat with no phx-click", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      chevron = "a[data-role='chat-back']"
      assert has_element?(view, "#{chevron}[href='/chat'][data-phx-link='patch']")
      assert has_element?(view, "#{chevron}[aria-label='Back to chat list'] .hero-chevron-left")
      refute has_element?(view, "#{chevron}[phx-click]")

      view |> element(chevron) |> render_click()
      assert_patch(view, ~p"/chat")
      assert has_element?(view, "#chat-list")
    end

    # Task 01a1557a-8562 stage 5 deleted the phone drawer, the channel pills
    # and the pinned strip: the Chat list is the phone's only conversation
    # list. The drawer only rendered while open, so its OPENER is refuted
    # too: with no `toggle_mobile_browser` anywhere, nothing can open it.
    test "a conversation carries no drawer, channel pills or pinned strip", %{conn: conn} do
      w = world(conn)
      _ = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)
      {:ok, view, _} = live(w.conn, ~p"/chat/#{w.alpha.slug}")

      # Positive controls: this IS the conversation (the back chevron renders),
      # and a pin exists, which is what drew the pinned strip before.
      assert has_element?(view, "a[data-role='chat-back']")
      assert lv_assigns(view).active_space.id == w.alpha.id
      assert Enum.any?(lv_assigns(view).channel_sections.pinned, &(&1.id == w.beta.id))

      refute has_element?(view, "#mobile-channel-browser")
      refute has_element?(view, "[phx-click='toggle_mobile_browser']")
      refute has_element?(view, ~s(nav[aria-label="Channel switcher"]))
      refute has_element?(view, ~s([data-role="mobile-pinned-strip"]))
    end
  end

  # ── excerpts ────────────────────────────────────────────────────────────

  describe "excerpts" do
    test "a group reads '<author>: <content>', a DM the content only", %{conn: conn} do
      w = world(conn)
      {:ok, group} = Chat.create_space(%{kind: "group"})
      _ = join!(group, w.user.id, w.user.name)
      sam = join!(group, Ecto.UUID.generate(), "Sam")
      _ = join!(group, Ecto.UUID.generate(), "Alex")
      say!(group, sam, "who has the demo laptop?")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      group_excerpt =
        view
        |> element("#chat-list [data-space-id='#{group.id}'] [data-role='chat-list-excerpt']")
        |> render()

      assert group_excerpt =~ "Sam: who has the demo laptop?"

      dm_excerpt =
        view
        |> element("#chat-list [data-space-id='#{w.dm.id}'] [data-role='chat-list-excerpt']")
        |> render()

      assert dm_excerpt =~ "a direct hello"
      refute dm_excerpt =~ "Moore:"

      assert has_element?(
               view,
               "#chat-list time[phx-hook='LocalTime']#chat-list-time-#{w.dm.id}"
             )

      # A channel row is dense: no excerpt and no time, even with a message.
      for id <- [w.alpha.id, w.beta.id] do
        refute has_element?(
                 view,
                 "#chat-list [data-space-id='#{id}'] [data-role='chat-list-excerpt']"
               )

        refute has_element?(view, "#chat-list-time-#{id}")
      end

      refute list_html(view) =~ "the alpha headline"
    end

    test "an agent DM whose agent has a blank avatar and no colour falls back as the rail does",
         %{conn: conn} do
      w = world(conn)

      agent =
        Repo.insert!(%Agent{
          slug: "list-blank-#{System.unique_integer([:positive])}",
          name: "Blank Bot",
          status: "active",
          avatar_url: "   ",
          color: nil
        })

      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})
      _ = join!(dm, w.user.id, w.user.name)

      {:ok, _} =
        Chat.add_participant(dm.id, %{
          participant_type: "agent",
          participant_id: agent.id,
          display_name: "Blank Bot",
          joined_at: DateTime.utc_now()
        })

      {:ok, view, _} = live(w.conn, ~p"/chat")
      avatar = "#chat-list [data-space-id='#{dm.id}'] [data-role='chat-list-avatar']"

      # The rail's resolvers: a blank avatar is no avatar (no <img>, the
      # initial instead), and no colour is the default "blue" slot.
      assert has_element?(view, "#{avatar}[data-avatar='agent'][data-agent-slot='blue']")
      refute has_element?(view, "#{avatar} img")
      assert view |> element(avatar) |> render() =~ ">B<"

      # Positive control: a real avatar URL does render as an image.
      Repo.update!(Ecto.Changeset.change(agent, avatar_url: "/images/agent-blank.png"))
      {:ok, view2, _} = live(w.conn, ~p"/chat")
      assert has_element?(view2, "#{avatar} img[src='/images/agent-blank.png']")
    end

    # Task 01a18940 stage 1, measured on prod: Brosnan's DM row drew "B" on a
    # blue ring while the message flow showed his image. `load_identities/1`
    # resolves avatars and slots for every DM and group in ONE batch, and the
    # Chat helpers keyed that batch `agent_id => participant.id`, keeping only
    # the LAST row of an agent present in several listed spaces. Here the
    # agent shares groups with the viewer listed before AND after the DM, so
    # the DM row is never the one a last-wins map would keep, and the test
    # asserts that precondition rather than trusting it.
    test "an agent DM keeps its image and slot when the agent is also in listed groups",
         %{conn: conn} do
      w = world(conn)
      url = "/agents/list-batch/avatar?v=BATCH"

      agent =
        Repo.insert!(%Agent{
          slug: "list-batch-#{System.unique_integer([:positive])}",
          name: "Batch Bot",
          status: "active",
          avatar_url: url,
          color: "teal"
        })

      group_with_agent = fn ->
        {:ok, group} = Chat.create_space(%{kind: "group"})
        _ = join!(group, w.user.id, w.user.name)
        {:ok, _} = Chat.add_agent_participant(group.id, agent)
        group
      end

      before_group = group_with_agent.()
      {:ok, dm} = Chat.create_space(%{kind: "dm", is_direct: true})
      _ = join!(dm, w.user.id, w.user.name)
      {:ok, dm_row} = Chat.add_agent_participant(dm.id, agent)
      after_group = group_with_agent.()

      batch =
        [before_group.id, dm.id, after_group.id]
        |> Chat.participants_by_space()
        |> Map.values()
        |> List.flatten()
        |> Enum.filter(&(&1.participant_id == agent.id))

      assert length(batch) == 3
      refute List.last(batch).id == dm_row.id

      avatar = "#chat-list [data-space-id='#{dm.id}'] [data-role='chat-list-avatar']"

      # Fresh /chat and direct entry into the DM (`ensure_loaded/1`) both
      # load identities through the same batch.
      for path <- [~p"/chat", ~p"/chat/#{ChatLive.space_nav_target(dm)}"] do
        {:ok, view, _} = live(w.conn, path)

        assert has_element?(view, "#{avatar}[data-avatar='agent'][data-agent-slot='teal']"),
               "#{path}: the DM row lost the agent's slot"

        assert has_element?(view, ~s(#{avatar} img[src="#{url}"])),
               "#{path}: the DM row lost the agent's image"

        refute view |> element(avatar) |> render() =~ ">B<"
      end

      # Negative arm on the same fixture: no avatar is the agent's initial on
      # its own ring, with no image.
      Repo.update!(Ecto.Changeset.change(agent, avatar_url: nil))
      {:ok, view, _} = live(w.conn, ~p"/chat")
      assert has_element?(view, "#{avatar}[data-avatar='agent'][data-agent-slot='teal']")
      refute has_element?(view, "#{avatar} img")
      assert view |> element(avatar) |> render() =~ ">B<"
    end

    test "a restricted channel renders the restricted row with no excerpt and no link",
         %{conn: conn} do
      org = acme()
      member = member!()
      admin = create_user!()
      plain_member!(admin, org, "admin")
      finance = channel_in(org, "Finance")
      add_user!(finance.id, admin.id)
      admin_p = Enum.find(Chat.list_participants(finance.id), &(&1.participant_id == admin.id))
      marker = "finance-secret-#{System.unique_integer([:positive])}"
      say!(finance, admin_p, marker)

      # Positive control: before the restriction the member's list loads its
      # excerpt (a dense channel row draws none, but the order reads it).
      {:ok, before, _} = live(login(conn, member.id), ~p"/chat")
      assert lv_assigns(before).list_excerpts[finance.id].content == marker

      {:ok, _} = Restrictions.restrict_space(finance, ["admin"], admin.id)

      {:ok, view, _} = live(login(conn, member.id), ~p"/chat")
      html = list_html(view)

      row =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(~s([data-role="restricted-channel-row"][data-space-id="#{finance.id}"]))

      assert Enum.count(row) == 1
      assert LazyHTML.query(row, "a, button") |> Enum.count() == 0
      assert LazyHTML.text(row) =~ "Restricted, ask an admin"
      refute html =~ marker
      refute Map.has_key?(lv_assigns(view).list_excerpts, finance.id)
    end
  end

  # ── masking ─────────────────────────────────────────────────────────────

  describe "mask names" do
    test "masked: no org-derived name and no excerpt text anywhere in #chat-list",
         %{conn: conn} do
      w = mask_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      # Positive control, mask off: every string is in the list.
      off = list_html(view)
      Platform.MaskAssertions.assert_name_anywhere(off, "Globex")

      # Channel rows are dense (no excerpt, no disc), so only the DM's
      # excerpt can carry text into the list.
      assert off =~ "xylophone practice"
      refute off =~ "zebra crossing numbers"

      assert has_element?(
               view,
               "#chat-list [data-space-id='#{w.org_named.id}'] [data-glyph='hash']"
             )

      refute has_element?(
               view,
               "#chat-list [data-space-id='#{w.org_named.id}'] [data-role='chat-list-avatar']"
             )

      mask(view, true)
      on = list_html(view)

      Platform.MaskAssertions.refute_name_anywhere(on, "Globex")

      for s <- ["zebra", "yonder", "xylophone"] do
        refute on =~ s, "excerpt text #{inspect(s)} leaked with the mask on"
      end

      # The DM's excerpt is the fixed-length placeholder.
      excerpt =
        view
        |> element("#chat-list [data-space-id='#{w.dm.id}'] [data-role='chat-list-excerpt']")
        |> render()

      assert excerpt =~ ChatList.masked_excerpt()

      # A masked channel row keeps its glyph (it spells nothing) and still
      # draws no disc and no excerpt.
      for id <- [w.org_named.id, w.atlas.id] do
        assert has_element?(view, "#chat-list [data-space-id='#{id}'] [data-glyph='hash']")

        refute has_element?(
                 view,
                 "#chat-list [data-space-id='#{id}'] [data-role='chat-list-avatar']"
               )

        refute has_element?(
                 view,
                 "#chat-list [data-space-id='#{id}'] [data-role='chat-list-excerpt']"
               )
      end
    end

    test "masked: a project-code channel and a person's name stay verbatim", %{conn: conn} do
      w = mask_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      mask(view, true)
      on = list_html(view)

      # The same pin as sidebar_mask_test.exs's #atlas case: the org rule
      # cannot infer a project code, and a DM's person names no org.
      assert on =~ "atlas"
      assert on =~ "Moore Person"
      assert has_element?(view, "#chat-list [data-space-id='#{w.atlas.id}'] [data-glyph='hash']")
      assert avatar_text(on, w.dm.id) == "M"
    end
  end

  # ── banner ──────────────────────────────────────────────────────────────

  describe "notification banner" do
    test "shows for prompt only, and the dismiss takes it down", %{conn: conn} do
      w = world(conn)

      for state <- ["prompt", "granted", "denied", "unsupported"] do
        {:ok, view, _} = live(w.conn, ~p"/chat")
        render_hook(view, "push_permission_state", %{"state" => state})

        if state == "prompt" do
          assert has_element?(view, @list_banner)

          assert has_element?(
                   view,
                   "#{@list_banner} button.btn-primary[phx-click='enable_notifications']"
                 )

          assert view |> element(@list_banner) |> render() =~ "Enable notifications"
          assert view |> element(@list_banner) |> render() =~ "mentions and DMs, nothing else"
        else
          refute has_element?(view, @list_banner), "banner rendered for #{state}"
        end
      end

      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      assert has_element?(view, @list_banner)

      view
      |> element(
        "#{@list_banner} button[aria-label='Dismiss'][phx-click='dismiss_notification_banner']"
      )
      |> render_click()

      refute has_element?(view, @list_banner)
    end

    test "the banner sits above Pinned on base-100 with border-edge", %{conn: conn} do
      w = world(conn)
      _ = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_hook(view, "push_permission_state", %{"state" => "prompt"})

      assert has_element?(view, "#{@list_banner}.bg-base-100.border-edge")
      html = list_html(view)
      {banner_at, _} = :binary.match(html, "chat-list-notification-banner")
      {pinned_at, _} = :binary.match(html, ~s(data-role="chat-list-pinned"))
      assert banner_at < pinned_at
    end
  end

  # ── empty states ────────────────────────────────────────────────────────

  describe "empty states" do
    test "no channels and no DMs: the whole-list empty state", %{conn: conn} do
      user = create_user!()
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert lv_assigns(view).channels == []
      empty = view |> element("#chat-list [data-role='chat-list-empty']") |> render()
      assert empty =~ "No channels yet."
      assert empty =~ "Create one or ask someone to add you."
      assert has_element?(view, "#chat-list button[phx-click='new_channel_open']")
      refute has_element?(view, "#chat-list [data-role='chat-list-spaces']")
    end

    test "only Spaces empty: its own copy and New channel", %{conn: conn} do
      user = create_user!()
      {dm, _me, other} = dm!(user, "Solo")
      say!(dm, other, "hi")
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert view |> element("#chat-list [data-role='chat-list-spaces-empty']") |> render() =~
               "You&#39;re not in any channels yet."

      assert has_element?(
               view,
               "#chat-list [data-role='chat-list-spaces-empty'] button[phx-click='new_channel_open']"
             )

      # Positive control: Direct is populated on the same page.
      assert has_element?(view, "#chat-list [data-space-id='#{dm.id}']")
    end

    test "only Direct empty: its own copy and New conversation", %{conn: conn} do
      user = member!()
      chan = channel_in(acme(), "Lonely")
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert view |> element("#chat-list [data-role='chat-list-direct-empty']") |> render() =~
               "No conversations yet."

      assert has_element?(
               view,
               "#chat-list [data-role='chat-list-direct-empty'] button[phx-click='new_conversation_open']"
             )

      assert has_element?(view, "#chat-list [data-space-id='#{chan.id}']")
    end
  end

  # ── guards ──────────────────────────────────────────────────────────────

  describe "guards" do
    test "no link in the list carries a phx-click (positive control: links exist)",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      doc = view |> list_html() |> LazyHTML.from_fragment()

      links = LazyHTML.query(doc, "[data-phx-link]")
      assert Enum.count(links) >= 3

      assert LazyHTML.query(doc, "[data-phx-link][phx-click]") |> Enum.count() == 0
    end

    # Burrow redesign 22 stage 2: the desktop list pane hovers, at lg only.
    # Below lg there is still no hover state anywhere in the list.
    test "no phone hover: class inside #chat-list (positive control: active:bg-base-100)",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_hook(view, "push_permission_state", %{"state" => "prompt"})
      html = list_html(view)

      classes =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[class]")
        |> LazyHTML.attribute("class")
        |> Enum.flat_map(&String.split/1)

      assert "active:bg-base-100" in classes

      assert Enum.filter(classes, &String.contains?(&1, "hover:"))
             |> Enum.reject(&String.starts_with?(&1, "lg:hover:")) == []
    end

    test "every row link is at least 44px tall and a whole-row patch", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert has_element?(
               view,
               "#chat-list a[data-role='chat-list-row'][data-space-id='#{w.alpha.id}'][data-phx-link='patch'].min-h-11"
             )
    end
  end

  # ── stage 3: the header sheets ──────────────────────────────────────────

  @sheets %{
    "search" => "#chat-list-search-sheet",
    "new" => "#chat-list-new-sheet",
    "options" => "#chat-list-options-sheet"
  }

  defp open_sheet(view, key) do
    view |> element("#chat-list button[phx-value-sheet='#{key}']") |> render_click()
  end

  defp search(view, query) do
    view
    |> element("#chat-list-search-sheet form[phx-change='list_search']")
    |> render_change(%{"value" => query})
  end

  defp sheet_html(view, key), do: view |> element(@sheets[key]) |> render()

  describe "header sheets" do
    test "each header button opens its sheet; close_list_sheet closes it", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      labels = %{
        "search" => {"chat-list-search", "Search channels and DMs", "hero-magnifying-glass"},
        "new" => {"chat-list-new", "New channel or conversation", "hero-plus"},
        "options" =>
          {"chat-list-options", "List options: mask names, archived", "hero-ellipsis-horizontal"}
      }

      for {key, {role, label, icon}} <- labels do
        button = "#chat-list header button[data-role='#{role}'][aria-label='#{label}']"
        assert has_element?(view, "#{button} .#{icon}")
        assert has_element?(view, "#{button}.size-11")

        refute has_element?(view, "#{@sheets[key]}.sheet-open")
        open_sheet(view, key)
        assert has_element?(view, "#{@sheets[key]}.sheet-open")
        assert lv_assigns(view).list_sheet == String.to_existing_atom(key)

        # Only one sheet is ever open.
        for {other, sel} <- @sheets,
            other != key,
            do: refute(has_element?(view, "#{sel}.sheet-open"))

        render_click(view, "close_list_sheet", %{})
        refute has_element?(view, "#{@sheets[key]}.sheet-open")
        assert lv_assigns(view).list_sheet == nil
      end
    end

    test "every sheet root is lg:hidden and uses the handle as its Close", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for {_key, sel} <- @sheets do
        assert has_element?(view, "#{sel}[class~='lg:hidden']"), "#{sel} lacks lg:hidden"
        assert has_element?(view, "#{sel}[data-swipe-dismiss='true']")
        assert has_element?(view, "#{sel} button.sheet-handle-button[aria-label='Close']")
      end
    end

    test "patching into a space from an open search closes it and clears the query",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "search")
      search(view, "alpha")
      assert lv_assigns(view).list_search_query == "alpha"

      render_patch(view, ~p"/chat/#{w.alpha.slug}")
      assert lv_assigns(view).list_sheet == nil
      assert lv_assigns(view).list_search_query == ""

      render_patch(view, ~p"/chat")
      refute has_element?(view, "#chat-list-search-sheet.sheet-open")
    end
  end

  describe "search sheet" do
    test "groups a channel, a DM and a message hit; the hit is a plain deep link",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "search")

      assert has_element?(
               view,
               "#chat-list-search-input[placeholder='Find channel, DM or message'][maxlength='100'][phx-debounce='200'][phx-hook='SearchFocus'][data-blur-on-scroll='chat-list-search-results']"
             )

      search(view, "alpha")
      html = sheet_html(view, "search")

      assert ids_in(html, "[data-role='chat-list-search-channels'] [data-role='chat-list-row']") ==
               [w.alpha.id]

      # A channel result is the dense row: the glyph, no excerpt.
      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query(
               "[data-role='chat-list-search-channels'] [data-role='chat-list-row'][data-row-shape='dense'] [data-glyph='hash']"
             )
             |> Enum.count() == 1

      refute html =~ "Priya: the alpha headline"

      search(view, "moore")

      assert ids_in(
               sheet_html(view, "search"),
               "[data-role='chat-list-search-direct'] [data-role='chat-list-row']"
             ) ==
               [w.dm.id]

      search(view, "headline")

      hit =
        "#chat-list-search-sheet [data-role='chat-list-search-messages'] a[data-role='chat-list-message-hit']"

      [msg] = Chat.search_messages(w.alpha.id, "headline")
      seg = PlatformWeb.ChatLive.space_nav_target(w.alpha)
      link = "#{hit}[href='/chat/#{seg}?message=#{msg.id}']"
      assert has_element?(view, "#{link}[data-phx-link='patch']")
      refute has_element?(view, "#{hit}[phx-click]")
      assert view |> element(link) |> render() =~ "Priya"
      assert view |> element(link) |> render() =~ "<mark>headline</mark>"

      view |> element(link) |> render_click()
      assert_patch(view, "/chat/#{seg}?message=#{msg.id}")
      assert lv_assigns(view).active_space.id == w.alpha.id
      assert render(view) =~ ~s(data-message-id="#{msg.id}")
      assert lv_assigns(view).list_sheet == nil
    end

    test "an empty query lists recent conversations; a miss says so", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "search")

      recent =
        ids_in(
          sheet_html(view, "search"),
          "[data-role='chat-list-search-recent'] [data-role='chat-list-row']"
        )

      assert Enum.sort(recent) == Enum.sort([w.alpha.id, w.dm.id])
      # Newest first: the DM's message was posted after alpha's.
      assert recent == [w.dm.id, w.alpha.id]

      search(view, "zzqx")

      assert has_element?(
               view,
               "#chat-list-search-sheet [data-role='chat-list-search-no-matches']"
             )

      assert sheet_html(view, "search") =~ "No matches for “zzqx”"
    end

    test "a term below the search threshold shows only name groups", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "search")
      # Punctuation parses to no lexemes: no MESSAGES group, no query run.
      search(view, "!!!")
      refute has_element?(view, "#chat-list-search-sheet [data-role='chat-list-search-messages']")
    end

    test "a restricted channel and a space the reader is not in yield no message hit",
         %{conn: conn} do
      org = acme()
      member = member!()
      admin = create_user!()
      plain_member!(admin, org, "admin")
      finance = channel_in(org, "Finance")
      add_user!(finance.id, admin.id)
      admin_p = Enum.find(Chat.list_participants(finance.id), &(&1.participant_id == admin.id))
      say!(finance, admin_p, "quorumvault plans")
      {:ok, _} = Restrictions.restrict_space(finance, ["admin"], admin.id)

      # A DM between two other people.
      {:ok, foreign} = Chat.create_space(%{kind: "dm", is_direct: true})
      a = join!(foreign, Ecto.UUID.generate(), "Ann")
      _ = join!(foreign, Ecto.UUID.generate(), "Bo")
      say!(foreign, a, "quorumvault secret")

      # Positive control: the same term in a channel the reader may read.
      lobby = channel_in(org, "Lobby")
      lp = join!(lobby, Ecto.UUID.generate(), "Lee")
      say!(lobby, lp, "quorumvault open")

      {:ok, view, _} = live(login(conn, member.id), ~p"/chat")
      open_sheet(view, "search")
      search(view, "quorumvault")

      hits =
        view
        |> sheet_html("search")
        |> ids_in("a[data-role='chat-list-message-hit']")

      assert hits == [lobby.id]
      refute sheet_html(view, "search") =~ "secret"
      refute sheet_html(view, "search") =~ "plans"
    end

    test "the message search's space list drops restricted channels by itself",
         %{conn: conn} do
      # The LiveView test above also passes through the access scope, which
      # denies a restricted channel on its own, so it stays green if this
      # list stops excluding them (mutation probe (a) survived it). This pins
      # the list's own exclusion, independent of the scope.
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      a = lv_assigns(view)

      ids = PlatformWeb.ChatLive.ChatListHooks.searchable_space_ids(a)
      assert w.alpha.id in ids and w.dm.id in ids

      restricted = %{a | restricted_channel_ids: MapSet.new([w.alpha.id])}
      ids = PlatformWeb.ChatLive.ChatListHooks.searchable_space_ids(restricted)
      refute w.alpha.id in ids
      assert w.beta.id in ids
    end

    test "masked: no org-derived name and no snippet text; people and project codes verbatim",
         %{conn: conn} do
      w = mask_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "search")

      # Positive control, unmasked: the same searches carry every string.
      search(view, "zebra")
      Platform.MaskAssertions.assert_name_anywhere(sheet_html(view, "search"), "Globex")
      assert sheet_html(view, "search") =~ "crossing numbers"
      search(view, "xylophone")
      assert sheet_html(view, "search") =~ "practice"

      mask(view, true)
      open_sheet(view, "search")

      search(view, "zebra")
      masked = sheet_html(view, "search")
      Platform.MaskAssertions.refute_name_anywhere(masked, "Globex")
      refute masked =~ "crossing numbers"

      assert has_element?(
               view,
               "#chat-list-search-sheet [data-role='chat-list-message-hit'][data-space-id='#{w.org_named.id}']"
             )

      assert masked =~ ChatList.masked_excerpt()

      # A message hit's author and a DM's name are PEOPLE: the org rule does
      # not mask them, as on the rail and the drawer.
      search(view, "xylophone")
      dm_hit = sheet_html(view, "search")
      assert dm_hit =~ "Moore Person"
      refute dm_hit =~ "practice"

      # A project code is verbatim; the org-derived row is reachable only by
      # its placeholder, and is the dense row: glyph, no disc.
      search(view, "atlas")
      assert sheet_html(view, "search") =~ "atlas"
      search(view, "workspace")

      assert has_element?(
               view,
               "#chat-list-search-sheet [data-space-id='#{w.org_named.id}'] [data-glyph='hash']"
             )

      refute has_element?(
               view,
               "#chat-list-search-sheet [data-space-id='#{w.org_named.id}'] [data-role='chat-list-avatar']"
             )

      search(view, "globex")
      refute has_element?(view, "#chat-list-search-sheet [data-space-id='#{w.org_named.id}']")
    end
  end

  describe "new and options sheets" do
    test "New's rows close the sheet and open the existing flows", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      open_sheet(view, "new")
      assert sheet_html(view, "new") =~ "name, people, your agent"

      view
      |> element("#chat-list-new-sheet button[data-role='chat-list-new-channel']")
      |> render_click()

      assert lv_assigns(view).show_new_channel_modal == true
      assert lv_assigns(view).list_sheet == nil

      open_sheet(view, "new")
      assert sheet_html(view, "new") =~ "DM a person or agent"

      view
      |> element("#chat-list-new-sheet button[data-role='chat-list-new-conversation']")
      |> render_click()

      assert lv_assigns(view).show_new_conversation_modal == true
      assert lv_assigns(view).list_sheet == nil
    end

    test "the options toggles flip mask and archived; the subtitle and Archived follow",
         %{conn: conn} do
      w = world(conn)
      archived = channel_in(acme(), "Old Room")
      {:ok, _} = Chat.archive_space(archived)

      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "options")

      mask_row =
        "#chat-list-options-sheet button[role='switch'][data-role='chat-list-option-mask']"

      archived_row =
        "#chat-list-options-sheet button[role='switch'][data-role='chat-list-option-archived']"

      assert has_element?(view, "#{mask_row}[aria-checked='false']")
      assert has_element?(view, "#{archived_row}[aria-checked='false']")
      refute has_element?(view, "#chat-list [data-role='chat-list-subtitle']", "names masked")

      view |> element(mask_row) |> render_click()
      assert lv_assigns(view).mask_names? == true
      assert has_element?(view, "#{mask_row}[aria-checked='true'] .bg-primary")
      assert has_element?(view, "#chat-list [data-role='chat-list-subtitle']", "names masked")

      refute has_element?(view, "#chat-list [data-role='chat-list-archived']")
      view |> element(archived_row) |> render_click()
      assert lv_assigns(view).archived_open == true
      assert has_element?(view, "#{archived_row}[aria-checked='true']")

      assert has_element?(
               view,
               "#chat-list [data-role='chat-list-archived'] [data-space-id='#{archived.id}']"
             )
    end

    test "no hover: class in the sheets (positive control: their pressed paint)",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for {key, sel} <- @sheets do
        open_sheet(view, key)
        if key == "search", do: search(view, "alpha")

        classes =
          view
          |> element(sel)
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.query("[class]")
          |> LazyHTML.attribute("class")
          |> Enum.flat_map(&String.split/1)

        assert "active:bg-base-200" in classes, "#{sel}: positive control missing"

        assert Enum.filter(classes, &String.contains?(&1, "hover:")) == [],
               "#{sel} carries hover:"

        render_click(view, "close_list_sheet", %{})
      end
    end
  end

  # ── stage 4: the row sheet and Edit order ───────────────────────────────

  @row_sheet "#chat-row-actions-sheet"

  defp long_press(view, space_id) do
    render_hook(view, "open_list_sheet", %{"sheet" => "row", "space_id" => space_id})
  end

  defp sheet_roles(view) do
    view
    |> element(@row_sheet)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("button[data-role]")
    |> LazyHTML.attribute("data-role")
  end

  describe "row long-press" do
    test "list rows carry the generic RowLongPress hook; Agents and search rows do not",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for id <- [w.alpha.id, w.beta.id, w.dm.id] do
        assert has_element?(
                 view,
                 "#chat-list a[data-role='chat-list-row'][data-space-id='#{id}'][phx-hook='RowLongPress'][data-long-press-event='open_list_sheet'][data-long-press-sheet='row'][data-long-press-space-id='#{id}']"
               )
      end

      open_sheet(view, "search")
      search(view, "alpha")
      assert has_element?(view, "#chat-list-search-sheet a[data-role='chat-list-row']")
      refute has_element?(view, "#chat-list-search-sheet a[phx-hook='RowLongPress']")
    end

    test "the Agents row has no long-press", %{conn: conn} do
      w = world(conn)
      agent = Repo.insert!(%Agent{slug: "list-lp-#{w.user.id}", name: "Lead", status: "active"})

      agents_space =
        channel!(%{
          name: "Agents",
          slug: "list-lp-agents-#{System.unique_integer([:positive])}",
          goal: "Ship",
          leader_agent_id: agent.id,
          org_id: acme().id
        })

      Application.put_env(:platform, @flag_key, true)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      agents_row = "#chat-list a[data-role='chat-list-row'][data-space-id='#{agents_space.id}']"
      assert has_element?(view, agents_row)
      refute has_element?(view, "#{agents_row}[phx-hook]")
    end

    test "a channel's sheet: Pin, Hide channel; no Close, no Mute", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      refute has_element?(view, "#{@row_sheet}.sheet-open")

      long_press(view, w.alpha.id)
      assert lv_assigns(view).list_sheet == {:row, w.alpha.id}
      assert has_element?(view, "#{@row_sheet}.sheet-open")

      assert sheet_roles(view) == [
               "row-actions-pin",
               "row-actions-hide"
             ]

      html = view |> element(@row_sheet) |> render()
      assert html =~ "Pin to top"
      assert html =~ "Hide channel"
      assert html =~ "hidden everywhere until you unhide"
      refute html =~ "Mute"
      refute html =~ "Close conversation"

      assert has_element?(
               view,
               "#{@row_sheet} button[data-role='row-actions-pin'][aria-label='Pin to top Alpha']"
             )
    end

    test "a DM's sheet: Pin, Close conversation; no Hide", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.dm.id)

      assert sheet_roles(view) == [
               "row-actions-pin",
               "row-actions-close-dm"
             ]

      html = view |> element(@row_sheet) |> render()
      assert html =~ "Close conversation"
      assert html =~ "hides it until the next message"
      refute html =~ "Hide channel"

      assert has_element?(
               view,
               "#{@row_sheet} button[data-role='row-actions-close-dm'][aria-label='Close conversation Moore']"
             )
    end

    test "a long-press on a space not on the list opens nothing", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, Ecto.UUID.generate())
      assert lv_assigns(view).list_sheet == nil
      refute has_element?(view, "#{@row_sheet}.sheet-open")
    end

    test "Pin writes through toggle_pinned and closes the sheet; the label flips",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.alpha.id)
      view |> element("#{@row_sheet} button[data-role='row-actions-pin']") |> render_click()

      assert w.alpha.id in Sidebar.list_pinned_space_ids(w.user.id)
      assert lv_assigns(view).list_sheet == nil
      refute has_element?(view, "#{@row_sheet}.sheet-open")

      long_press(view, w.alpha.id)

      assert has_element?(
               view,
               "#{@row_sheet} button[data-role='row-actions-pin'][aria-label='Unpin from top Alpha']",
               "Unpin from top"
             )
    end

    test "Hide writes through hide_channel and closes the sheet", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.beta.id)
      view |> element("#{@row_sheet} button[data-role='row-actions-hide']") |> render_click()

      assert MapSet.member?(Platform.Accounts.get_hidden_channel_ids(w.user.id), w.beta.id)
      assert lv_assigns(view).list_sheet == nil

      refute has_element?(
               view,
               "#chat-list a[data-role='chat-list-row'][data-space-id='#{w.beta.id}']"
             )
    end

    test "Close writes through close_dm and closes the sheet", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.dm.id)
      view |> element("#{@row_sheet} button[data-role='row-actions-close-dm']") |> render_click()

      assert Map.has_key?(Platform.Accounts.get_closed_dm_at(w.user.id), w.dm.id)
      assert lv_assigns(view).list_sheet == nil

      refute has_element?(
               view,
               "#chat-list a[data-role='chat-list-row'][data-space-id='#{w.dm.id}']"
             )
    end
  end

  # ── unread weight (task 01a166bf stage 2) ──────────────────────────────

  # `world/1`'s DM is unread (Moore wrote last, the viewer never read it). A
  # second DM where the viewer wrote last is read: own messages never count.
  defp weight_world(conn) do
    w = world(conn)
    {read_dm, me, _} = dm!(w.user, "Okafor")
    say!(read_dm, me, "my own last word")
    Map.put(w, :read_dm, read_dm)
  end

  defp name_sel(id), do: "#chat-list-row-#{id} [data-role='chat-list-row-name']"

  describe "unread weight" do
    test "an unread row's name is font-semibold and a read row's font-normal; the dot only on unread",
         %{conn: conn} do
      w = weight_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert lv_assigns(view).unread_counts[w.dm.id] == 1
      refute Map.has_key?(lv_assigns(view).unread_counts, w.read_dm.id)

      # Unread: semibold, never regular, body colour, dot.
      assert has_element?(view, "#{name_sel(w.dm.id)}.font-semibold.text-base-content")
      refute has_element?(view, "#{name_sel(w.dm.id)}.font-normal")
      assert has_element?(view, "#chat-list-row-#{w.dm.id} [data-role='chat-list-unread-dot']")

      # Read: regular, never semibold, the SAME colour, no dot.
      assert has_element?(view, "#{name_sel(w.read_dm.id)}.font-normal.text-base-content")
      refute has_element?(view, "#{name_sel(w.read_dm.id)}.font-semibold")
      refute has_element?(view, "#{name_sel(w.read_dm.id)}.text-subtle")

      refute has_element?(
               view,
               "#chat-list-row-#{w.read_dm.id} [data-role='chat-list-unread-dot']"
             )
    end

    test "reading a row turns its name regular and drops the dot", %{conn: conn} do
      w = weight_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert has_element?(view, "#{name_sel(w.dm.id)}.font-semibold")
      assert has_element?(view, "#chat-list-row-#{w.dm.id} [data-role='chat-list-unread-dot']")

      view |> element("#chat-list-row-#{w.dm.id}") |> render_click()
      assert lv_assigns(view).active_space.id == w.dm.id

      render_patch(view, ~p"/chat")
      assert lv_assigns(view).active_space == nil

      assert has_element?(view, "#{name_sel(w.dm.id)}.font-normal")
      refute has_element?(view, "#{name_sel(w.dm.id)}.font-semibold")
      refute has_element?(view, "#chat-list-row-#{w.dm.id} [data-role='chat-list-unread-dot']")
    end

    test "an unread row's time is base-content, a read row's text-subtle", %{conn: conn} do
      w = weight_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      unread_time = "#chat-list-time-#{w.dm.id}[data-role='chat-list-row-time']"
      read_time = "#chat-list-time-#{w.read_dm.id}[data-role='chat-list-row-time']"

      assert has_element?(view, "#{unread_time}.text-base-content")
      refute has_element?(view, "#{unread_time}.text-subtle")
      assert has_element?(view, "#{read_time}.text-subtle")
      refute has_element?(view, "#{read_time}.text-base-content")

      # The time follows the excerpt.
      assert has_element?(
               view,
               "#chat-list-row-#{w.dm.id} [data-role='chat-list-excerpt'].text-base-content"
             )

      assert has_element?(
               view,
               "#chat-list-row-#{w.read_dm.id} [data-role='chat-list-excerpt'].text-subtle"
             )
    end
  end

  # ── dense channel rows (Slack # / lock) ─────────────────────────────────

  defp row_sel(id), do: "#chat-list-row-#{id}"

  defp restricted_world(conn) do
    org = acme()
    member = member!()
    admin = create_user!()
    plain_member!(admin, org, "admin")
    vault = channel_in(org, "Vault")
    {:ok, _} = Restrictions.restrict_space(vault, ["admin"], admin.id)
    open = channel_in(org, "Lobby")
    %{conn: conn, member: member, admin: admin, vault: vault, open: open}
  end

  describe "dense channel rows" do
    test "a channel row is one line: a # glyph and the name, no disc, no time, no preview",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      row = row_sel(w.alpha.id)

      # Positive control: alpha HAS a newest message (the order reads it).
      assert lv_assigns(view).list_excerpts[w.alpha.id].content == "the alpha headline"

      assert has_element?(view, "#{row}[data-row-shape='dense'].min-h-11")

      assert has_element?(
               view,
               "#{row} [data-role='chat-list-glyph'][data-glyph='hash'].hero-hashtag.text-subtle"
             )

      assert view |> element("#{row} [data-role='chat-list-row-name']") |> render() =~ "Alpha"
      refute has_element?(view, "#{row} [data-role='chat-list-avatar']")
      refute has_element?(view, "#{row} [data-role='chat-list-excerpt']")
      refute has_element?(view, "#{row} [data-role='chat-list-row-time']")
      refute has_element?(view, "#{row} .hero-lock-closed")
      refute list_html(view) =~ "the alpha headline"
    end

    test "a private channel the reader can open shows the lock, not #", %{conn: conn} do
      w = restricted_world(conn)
      {:ok, view, _} = live(login(w.conn, w.admin.id), ~p"/chat")

      assert MapSet.member?(lv_assigns(view).list_private_ids, w.vault.id)
      refute MapSet.member?(lv_assigns(view).restricted_channel_ids, w.vault.id)

      assert has_element?(
               view,
               "#{row_sel(w.vault.id)} [data-glyph='lock'].hero-lock-closed"
             )

      refute has_element?(view, "#{row_sel(w.vault.id)} .hero-hashtag")
      assert view |> element(row_sel(w.vault.id)) |> render() =~ "Private channel"

      # Control: an unrestricted channel on the same list keeps #.
      assert has_element?(view, "#{row_sel(w.open.id)} [data-glyph='hash'].hero-hashtag")
      refute MapSet.member?(lv_assigns(view).list_private_ids, w.open.id)
    end

    test "a restricted channel shows the no-entry marker, never the lock", %{conn: conn} do
      w = restricted_world(conn)
      {:ok, view, _} = live(login(w.conn, w.member.id), ~p"/chat")

      assert MapSet.member?(lv_assigns(view).restricted_channel_ids, w.vault.id)
      refute MapSet.member?(lv_assigns(view).list_private_ids, w.vault.id)

      row = "#chat-list [data-role='restricted-channel-row'][data-space-id='#{w.vault.id}']"

      assert has_element?(
               view,
               "#{row} [data-glyph='restricted'].hero-no-symbol.text-subtle"
             )

      refute has_element?(view, "#{row} [class*='hero-lock']")
      refute has_element?(view, "#{row} [data-role='chat-list-avatar']")
      refute has_element?(view, "#chat-list-row-#{w.vault.id}")
    end

    test "a group draws hero-user-group in the avatar column and keeps its preview",
         %{conn: conn} do
      w = world(conn)
      {:ok, group} = Chat.create_space(%{kind: "group"})
      _ = join!(group, w.user.id, w.user.name)
      sam = join!(group, Ecto.UUID.generate(), "Sam")
      _ = join!(group, Ecto.UUID.generate(), "Alex")
      say!(group, sam, "who has the demo laptop?")
      {:ok, view, _} = live(w.conn, ~p"/chat")
      row = row_sel(group.id)

      assert has_element?(
               view,
               "#{row} [data-role='chat-list-avatar'][data-avatar='group'] .hero-user-group"
             )

      refute has_element?(view, "#{row} [data-avatar='initial']")
      refute has_element?(view, "#{row} [data-role='chat-list-glyph']")

      assert view |> element("#{row} [data-role='chat-list-excerpt']") |> render() =~
               "Sam: who has the demo laptop?"
    end

    test "a DM keeps its avatar, time and preview", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      row = row_sel(w.dm.id)

      refute has_element?(view, "#{row}[data-row-shape='dense']")
      assert has_element?(view, "#{row} [data-role='chat-list-avatar'][data-avatar='initial']")
      assert avatar_text(list_html(view), w.dm.id) == "M"
      assert has_element?(view, "#{row} [data-role='chat-list-row-time']")

      assert view |> element("#{row} [data-role='chat-list-excerpt']") |> render() =~
               "a direct hello"

      refute has_element?(view, "#{row} [data-role='chat-list-glyph']")
    end

    test "unread: bold name, solid base-content glyph and a neutral count; read: none of it",
         %{conn: conn} do
      w = world(conn)
      _ = join!(w.alpha, w.user.id, w.user.name)
      _ = join!(w.beta, w.user.id, w.user.name)
      # The fixture's headline plus two more: three unread.
      for n <- 1..2, do: say!(w.alpha, w.poster, "news #{n}")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert lv_assigns(view).unread_counts[w.alpha.id] == 3
      refute Map.has_key?(lv_assigns(view).unread_counts, w.beta.id)

      unread = row_sel(w.alpha.id)
      assert has_element?(view, "#{name_sel(w.alpha.id)}.font-semibold")

      assert has_element?(
               view,
               "#{unread} [data-glyph='hash'].hero-hashtag-solid.text-base-content"
             )

      count = "#{unread} [data-role='chat-list-unread-count']"
      assert has_element?(view, "#{count}.bg-base-300.text-base-content")
      refute has_element?(view, "#{count}[class*='primary']")
      assert view |> element(count) |> render() =~ ">3<"
      refute has_element?(view, "#{unread} [data-role='chat-list-unread-dot']")

      read = row_sel(w.beta.id)
      assert has_element?(view, "#{name_sel(w.beta.id)}.font-normal")
      assert has_element?(view, "#{read} [data-glyph='hash'].hero-hashtag.text-subtle")
      refute has_element?(view, "#{read} .hero-hashtag-solid")
      refute has_element?(view, "#{read} [data-role='chat-list-unread-count']")
    end
  end

  # The saved Pinned order is set on desktop only (task 01a1557b); the phone
  # shows it and offers no reorder entry point.
  describe "the phone has no Edit order" do
    test "no Edit order entry point in the phone list or row sheet", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      open_sheet(view, "options")
      # Positive control: the options sheet renders its other switches.
      assert has_element?(view, "#chat-list-options-sheet [data-role='chat-list-option-mask']")
      refute has_element?(view, "[data-role='chat-list-option-edit-order']")
      refute sheet_html(view, "options") =~ "Edit order"
      render_click(view, "close_list_sheet", %{})

      long_press(view, w.alpha.id)
      assert has_element?(view, "#{@row_sheet} [data-role='row-actions-pin']")
      refute has_element?(view, "[data-role='row-actions-edit-order']")
      refute view |> element(@row_sheet) |> render() =~ "Edit order"

      list = list_html(view)
      assert list =~ ~s(data-role="chat-list-row")
      refute list =~ "chat-list-move"
      refute list =~ "chat-list-announcer"
      refute list =~ "data-editing"
      refute list =~ "editing order"
    end
  end

  # ── section folds (task 01a166bf stage 3) ───────────────────────────────

  defp toggle_sel(key),
    do: "#chat-list button[data-role='chat-list-section-toggle'][data-section='#{key}']"

  defp marker_sel(key), do: "#{toggle_sel(key)} [data-role='chat-list-section-unread']"

  defp tap_header(view, key), do: view |> element(toggle_sel(key)) |> render_click()

  defp count_sel(key), do: "#{toggle_sel(key)} [data-role='chat-list-section-count']"

  @fold_spaces_rows "[data-role='chat-list-spaces'] [data-role='chat-list-row']"

  # The trimmed, whitespace-collapsed text of everything `selector` finds
  # (LazyHTML.query descends the whole tree).
  defp query_text(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.text()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  defp collapsed_pref(user),
    do: Platform.Accounts.get_user_preferences(user.id)["chat_collapsed_sections"]

  # Two unread DMs, one carrying three unread messages and one carrying one,
  # plus the viewer's own read DM. Unread CONVERSATIONS: 2; messages: 4.
  defp fold_unread_world(conn) do
    user = member!()
    {busy, _me, a} = dm!(user, "Okafor")
    for n <- 1..3, do: say!(busy, a, "busy note #{n}")
    {quiet, _me, b} = dm!(user, "Lindqvist")
    say!(quiet, b, "one note")
    {read, me, _} = dm!(user, "Haddad")
    say!(read, me, "my own last word")

    %{conn: login(conn, user.id), user: user, busy: busy, quiet: quiet, read: read}
  end

  describe "section folds" do
    test "every list header is a button inside its h2 with aria-expanded and aria-controls",
         %{conn: conn} do
      w = world(conn)
      {:ok, _} = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)
      archived = channel_in(acme(), "Old Room")
      {:ok, _} = Chat.archive_space(archived)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_click(view, "toggle_archived_section", %{})

      for {key, label, h2} <- [
            {"chat-list:pinned", "Pinned", "chat-list-label-pinned"},
            {"chat-list:spaces", "Spaces", "chat-list-label-spaces"},
            {"chat-list:direct", "Direct", "chat-list-label-direct"},
            {"chat-list:archived", "Archived", "chat-list-label-archived"}
          ] do
        section = String.replace_prefix(key, "chat-list:", "")
        sel = "h2##{h2} > button[type='button'][data-section='#{key}']"
        assert has_element?(view, "#{sel}[aria-expanded='true']", label)
        assert has_element?(view, "#{sel}[aria-controls='chat-list-rows-#{section}']")
        assert has_element?(view, "#chat-list #chat-list-rows-#{section}")
        assert has_element?(view, "#{sel} [data-role='chat-list-section-chevron']")
      end
    end

    test "tapping a section header collapses it and it stays collapsed after reload",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='true']")
      assert has_element?(view, "#chat-list-row-#{w.dm.id}")

      tap_header(view, "chat-list:direct")

      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='false']")
      refute has_element?(view, "#chat-list-row-#{w.dm.id}")
      refute has_element?(view, "#chat-list [data-role='chat-list-direct-empty']")
      # Negative control: Spaces is untouched.
      assert has_element?(view, "#{toggle_sel("chat-list:spaces")}[aria-expanded='true']")
      assert has_element?(view, "#chat-list-row-#{w.alpha.id}")

      # The EXISTING store, under the phone's key, and nothing else in it.
      assert collapsed_pref(w.user) == ["chat-list:direct"]

      {:ok, view, _} = live(w.conn, ~p"/chat")
      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='false']")
      refute has_element?(view, "#chat-list-row-#{w.dm.id}")
      assert has_element?(view, "#chat-list-row-#{w.alpha.id}")

      tap_header(view, "chat-list:direct")
      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='true']")
      assert has_element?(view, "#chat-list-row-#{w.dm.id}")
      assert collapsed_pref(w.user) == []
    end

    test "a second session for the same user converges on the fold", %{conn: conn} do
      w = world(conn)
      {:ok, a, _} = live(w.conn, ~p"/chat")
      {:ok, b, _} = live(w.conn, ~p"/chat")

      tap_header(a, "chat-list:direct")
      # B was not touched: the broadcast alone must fold it.
      assert has_element?(b, "#{toggle_sel("chat-list:direct")}[aria-expanded='false']")
      refute has_element?(b, "#chat-list-row-#{w.dm.id}")
      assert has_element?(b, "#{toggle_sel("chat-list:spaces")}[aria-expanded='true']")

      tap_header(b, "chat-list:direct")
      assert has_element?(a, "#{toggle_sel("chat-list:direct")}[aria-expanded='true']")
      assert has_element?(a, "#chat-list-row-#{w.dm.id}")
    end

    test "a collapsed section with unread shows the dot and the unread-conversation count; nothing when read",
         %{conn: conn} do
      w = fold_unread_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert lv_assigns(view).unread_counts[w.busy.id] == 3
      assert lv_assigns(view).unread_counts[w.quiet.id] == 1

      # Open: no marker on the header, the rows carry their own dots.
      refute has_element?(view, marker_sel("chat-list:direct"))

      tap_header(view, "chat-list:direct")
      refute has_element?(view, "#chat-list-row-#{w.busy.id}")
      assert has_element?(view, "#{marker_sel("chat-list:direct")} .bg-primary")

      assert view
             |> element(
               "#{marker_sel("chat-list:direct")} [data-role='chat-list-section-unread-count']"
             )
             |> render() =~ ~r/>\s*2\s*</

      # Read both: the folded header goes quiet.
      for space <- [w.busy, w.quiet] do
        render_patch(view, ~p"/chat/#{PlatformWeb.ChatLive.space_nav_target(space)}")
        render_patch(view, ~p"/chat")
      end

      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='false']")
      refute has_element?(view, marker_sel("chat-list:direct"))
    end

    test "Archived never shows an unread marker when collapsed", %{conn: conn} do
      w = fold_unread_world(conn)
      archived = channel_in(acme(), "Old Room")
      join!(archived, w.user.id, w.user.name)
      poster = join!(archived, Ecto.UUID.generate(), "Priya")
      say!(archived, poster, "an archived note")
      {:ok, _} = Chat.archive_space(archived)

      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_click(view, "toggle_archived_section", %{})
      assert lv_assigns(view).unread_counts[archived.id] == 1
      assert has_element?(view, "#chat-list-row-#{archived.id}")

      tap_header(view, "chat-list:archived")
      tap_header(view, "chat-list:direct")

      assert has_element?(view, "#{toggle_sel("chat-list:archived")}[aria-expanded='false']")
      refute has_element?(view, "#chat-list-row-#{archived.id}")
      refute has_element?(view, marker_sel("chat-list:archived"))
      # Positive control: a folded section with unread does carry the marker.
      assert has_element?(view, marker_sel("chat-list:direct"))
    end

    test "a folded Pinned counts its unread pinned conversations", %{conn: conn} do
      w = fold_unread_world(conn)
      {:ok, _} = Sidebar.set_space_pinned(w.user.id, w.busy.id, true)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      tap_header(view, "chat-list:pinned")
      refute has_element?(view, "#chat-list-row-#{w.busy.id}")

      assert view
             |> element(
               "#{marker_sel("chat-list:pinned")} [data-role='chat-list-section-unread-count']"
             )
             |> render() =~ ~r/>\s*1\s*</

      # The pinned DM left Direct, so Direct is unaffected: still open.
      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='true']")
    end

    test "empty-state sections fold too", %{conn: conn} do
      user = member!()
      {dm, _me, other} = dm!(user, "Moore")
      say!(dm, other, "hello")
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      assert has_element?(view, "#chat-list [data-role='chat-list-spaces-empty']")
      tap_header(view, "chat-list:spaces")
      refute has_element?(view, "#chat-list [data-role='chat-list-spaces-empty']")
      assert has_element?(view, "#{toggle_sel("chat-list:spaces")}[aria-expanded='false']")
    end

    # ── task 01a17493: a folded header shows how many rows it hides ──

    test "a folded quiet Spaces shows \"· N\" for the N rows it renders expanded, and no marker",
         %{conn: conn} do
      user = member!()
      quiet_a = channel_in(acme(), "Quiet A")
      quiet_b = channel_in(acme(), "Quiet B")
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")

      rows = list_html(view) |> ids_in(@fold_spaces_rows)
      n = length(rows)
      assert quiet_a.id in rows and quiet_b.id in rows
      assert n >= 2
      refute has_element?(view, count_sel("chat-list:spaces"))

      tap_header(view, "chat-list:spaces")
      html = list_html(view)
      assert ids_in(html, @fold_spaces_rows) == []

      assert query_text(html, count_sel("chat-list:spaces")) == "· #{n}"
      assert has_element?(view, "#{count_sel("chat-list:spaces")}[aria-hidden='true']")
      refute has_element?(view, marker_sel("chat-list:spaces"))

      assert query_text(html, "#{toggle_sel("chat-list:spaces")} .sr-only") =~
               "#{n} conversations"
    end

    test "a folded Spaces with one unread row shows the count AND the marker, apart",
         %{conn: conn} do
      w = world(conn)
      loud = channel_in(acme(), "Loud Room")
      join!(loud, w.user.id, w.user.name)
      poster = join!(loud, Ecto.UUID.generate(), "Riley")
      say!(loud, poster, "one unread note")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      rows = list_html(view) |> ids_in(@fold_spaces_rows)
      n = length(rows)
      assert loud.id in rows

      assert Enum.count(rows, &(Map.get(lv_assigns(view).unread_counts, &1, 0) > 0)) == 1
      assert n >= 2 and n != 1

      tap_header(view, "chat-list:spaces")
      html = list_html(view)

      assert query_text(html, count_sel("chat-list:spaces")) == "· #{n}"

      assert query_text(
               html,
               "#{marker_sel("chat-list:spaces")} [data-role='chat-list-section-unread-count']"
             ) == "1"

      # Separate elements: the count is not inside the marker, nor the reverse.
      refute has_element?(
               view,
               "#{marker_sel("chat-list:spaces")} [data-role='chat-list-section-count']"
             )

      refute has_element?(
               view,
               "#{count_sel("chat-list:spaces")} [data-role='chat-list-section-unread']"
             )
    end

    test "a folded Pinned counts the Agents row with its pinned rows", %{conn: conn} do
      w = world(conn)
      agent = Repo.insert!(%Agent{slug: "fold-lead-#{w.user.id}", name: "Lead", status: "active"})

      agents_space =
        channel!(%{
          name: "Agents",
          slug: "fold-agents-#{System.unique_integer([:positive])}",
          goal: "Ship the list",
          leader_agent_id: agent.id,
          org_id: acme().id
        })

      Application.put_env(:platform, @flag_key, true)
      _ = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      assert ids_in(list_html(view), "[data-role='chat-list-pinned'] [data-role='chat-list-row']") ==
               [agents_space.id, w.beta.id]

      tap_header(view, "chat-list:pinned")
      assert query_text(list_html(view), count_sel("chat-list:pinned")) == "· 2"
    end

    test "an expanded list renders no count element on any header", %{conn: conn} do
      w = world(conn)
      _ = Sidebar.set_space_pinned(w.user.id, w.beta.id, true)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for key <- ["chat-list:pinned", "chat-list:spaces", "chat-list:direct"] do
        assert has_element?(view, "#{toggle_sel(key)}[aria-expanded='true']")
      end

      refute has_element?(view, "#chat-list [data-role='chat-list-section-count']")
      refute list_html(view) =~ "conversations</span>"

      # Positive control on the same fixture: folding one makes it appear.
      tap_header(view, "chat-list:direct")
      assert query_text(list_html(view), count_sel("chat-list:direct")) == "· 1"
    end

    test "a shown, folded Archived carries no count and no marker", %{conn: conn} do
      w = world(conn)
      archived = channel_in(acme(), "Old Room")
      join!(archived, w.user.id, w.user.name)
      poster = join!(archived, Ecto.UUID.generate(), "Priya")
      say!(archived, poster, "an archived note")
      {:ok, _} = Chat.archive_space(archived)

      {:ok, view, _} = live(w.conn, ~p"/chat")
      render_click(view, "toggle_archived_section", %{})
      assert has_element?(view, "#chat-list-row-#{archived.id}")
      assert lv_assigns(view).unread_counts[archived.id] == 1

      tap_header(view, "chat-list:archived")
      tap_header(view, "chat-list:spaces")

      assert has_element?(view, "#{toggle_sel("chat-list:archived")}[aria-expanded='false']")
      refute has_element?(view, "#chat-list-row-#{archived.id}")
      refute has_element?(view, count_sel("chat-list:archived"))
      refute has_element?(view, marker_sel("chat-list:archived"))
      refute query_text(list_html(view), toggle_sel("chat-list:archived")) =~ "·"
      # Positive control: the folded Spaces beside it does carry a count.
      assert has_element?(view, count_sel("chat-list:spaces"))
    end

    test "a folded Direct with no DMs keeps a bare header: no count, never \"· 0\"",
         %{conn: conn} do
      user = member!()
      _ = channel_in(acme(), "Only Room")
      {:ok, view, _} = live(login(conn, user.id), ~p"/chat")
      assert has_element?(view, "#chat-list [data-role='chat-list-direct-empty']")

      tap_header(view, "chat-list:direct")
      tap_header(view, "chat-list:spaces")
      html = list_html(view)

      assert has_element?(view, "#{toggle_sel("chat-list:direct")}[aria-expanded='false']")
      refute has_element?(view, count_sel("chat-list:direct"))
      header = query_text(html, toggle_sel("chat-list:direct"))
      assert header =~ "Direct"
      refute header =~ "·"
      refute header =~ "0 conversations"
      # Positive control: the folded Spaces on the same fixture counts.
      assert query_text(html, count_sel("chat-list:spaces")) =~ ~r/^· [1-9]\d*$/
    end

    test "the folded count follows a new channel live, N to N+1", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      n = list_html(view) |> ids_in(@fold_spaces_rows) |> length()

      tap_header(view, "chat-list:spaces")
      assert query_text(list_html(view), count_sel("chat-list:spaces")) == "· #{n}"

      fresh = channel_in(acme(), "Freshly Made")
      join!(fresh, w.user.id, w.user.name)
      _ = render(view)

      assert query_text(list_html(view), count_sel("chat-list:spaces")) == "· #{n + 1}"

      assert query_text(list_html(view), "#{toggle_sel("chat-list:spaces")} .sr-only") =~
               "#{n + 1} conversations"

      # And the expanded list agrees with the count it showed.
      tap_header(view, "chat-list:spaces")
      rows = list_html(view) |> ids_in(@fold_spaces_rows)
      assert fresh.id in rows
      assert length(rows) == n + 1
    end
  end

  # ── order hold (task 01a166bf stage 4) ─────────────────────────────────

  @spaces_rows "[data-role='chat-list-spaces'] [data-role='chat-list-row']"

  defp hold(view),
    do: view |> element("#chat-list-scroller") |> render_hook("chat_list_hold", %{})

  defp release(view),
    do: view |> element("#chat-list-scroller") |> render_hook("chat_list_release", %{})

  defp spaces_order(view, mine), do: view |> list_html() |> ids_in(@spaces_rows) |> keep(mine)

  # Channel rows are dense and draw no excerpt, so the live excerpt is read
  # from the assign the order is computed from.
  defp excerpt_content(view, space_id) do
    _ = render(view)

    case lv_assigns(view).list_excerpts[space_id] do
      %{content: content} -> content
      _ -> nil
    end
  end

  describe "order hold" do
    test "the scroller carries the ChatListSettle hook", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      assert has_element?(view, "#chat-list-scroller[phx-hook='ChatListSettle']")
      assert ChatListHooks.hold_timeout_ms() == 10_000
    end

    test "while held, a new message updates the excerpt but not the order; release re-sorts",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      mine = [w.alpha.id, w.beta.id]
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]
      assert excerpt_content(view, w.beta.id) == nil

      hold(view)
      other = join!(w.beta, Ecto.UUID.generate(), "Riley")
      say!(w.beta, other, "beta wakes up while held")
      _ = render(view)

      # Order frozen; excerpt, weight and count live.
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]
      assert excerpt_content(view, w.beta.id) == "beta wakes up while held"
      assert has_element?(view, "#{name_sel(w.beta.id)}.font-semibold")

      assert has_element?(
               view,
               "#chat-list-row-#{w.beta.id} [data-role='chat-list-unread-count']"
             )

      # A second hold inside the same gesture keeps the first snapshot.
      hold(view)
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]

      release(view)
      assert spaces_order(view, mine) == [w.beta.id, w.alpha.id]
      assert lv_assigns(view).list_order_hold == nil
    end

    test "a held list auto-releases on its own timer and ignores a stale one", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      mine = [w.alpha.id, w.beta.id]

      hold(view)
      first_ref = lv_assigns(view).list_hold_ref
      assert is_reference(first_ref)

      # A repeat hold re-arms: the first timer is now stale.
      hold(view)
      ref = lv_assigns(view).list_hold_ref
      assert is_reference(ref) and ref != first_ref

      other = join!(w.beta, Ecto.UUID.generate(), "Riley")
      say!(w.beta, other, "beta wakes up")
      _ = render(view)
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]

      for stale <- [first_ref, make_ref()] do
        send(view.pid, {:chat_list_hold_expired, stale})
        _ = render(view)
        assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]
        assert lv_assigns(view).list_order_hold != nil
      end

      send(view.pid, {:chat_list_hold_expired, ref})
      _ = render(view)
      assert spaces_order(view, mine) == [w.beta.id, w.alpha.id]
      assert lv_assigns(view).list_order_hold == nil
    end

    # Stage 5: a reader scrolling past 10s re-pushes the hold every few
    # seconds. Each re-hold must refresh the timer and KEEP the snapshot, or
    # a refresh mid-scroll would re-sort under the reader.
    test "a re-hold during a hold re-arms the timer and keeps the snapshot", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      mine = [w.alpha.id, w.beta.id]
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]

      # t=0: the gesture starts.
      hold(view)
      first_ref = lv_assigns(view).list_hold_ref
      snapshot = lv_assigns(view).list_order_hold

      # A message lands mid-gesture: recency now says beta first.
      other = join!(w.beta, Ecto.UUID.generate(), "Riley")
      say!(w.beta, other, "beta speaks mid-scroll")
      _ = render(view)
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]

      # t=8s: the client's throttled re-hold, still scrolling.
      hold(view)
      second_ref = lv_assigns(view).list_hold_ref
      assert second_ref != first_ref
      assert lv_assigns(view).list_order_hold == snapshot
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]

      # t=10s: the FIRST timer fires. It is stale; the order stays frozen.
      send(view.pid, {:chat_list_hold_expired, first_ref})
      _ = render(view)
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id]
      assert lv_assigns(view).list_order_hold == snapshot

      release(view)
      assert spaces_order(view, mine) == [w.beta.id, w.alpha.id]
      assert lv_assigns(view).list_order_hold == nil
    end

    test "a new conversation during a hold appends at its section's end", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      hold(view)
      # A name that sorts first and, below, the newest message: recency would
      # put it at the TOP. Held, it goes to the end.
      fresh = channel_in(acme(), "Aardvark")
      _ = render(view)
      poster = join!(fresh, Ecto.UUID.generate(), "Riley")
      say!(fresh, poster, "a fresh channel speaks")
      _ = render(view)

      mine = [w.alpha.id, w.beta.id, fresh.id]
      assert spaces_order(view, mine) == [w.alpha.id, w.beta.id, fresh.id]
      assert List.last(view |> list_html() |> ids_in(@spaces_rows)) == fresh.id
      assert excerpt_content(view, fresh.id) == "a fresh channel speaks"

      release(view)
      assert spaces_order(view, mine) == [fresh.id, w.alpha.id, w.beta.id]
    end

    test "leaving the list for a space drops the hold", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      hold(view)
      assert lv_assigns(view).list_order_hold != nil

      render_patch(view, ~p"/chat/#{w.alpha.slug}")
      assert lv_assigns(view).list_order_hold == nil
      assert lv_assigns(view).list_hold_ref == nil
    end
  end
end
