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

  import Phoenix.LiveViewTest
  import Platform.ExternalUserFixtures
  import Platform.TenancyFixtures

  alias Platform.Access.Restrictions
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.Sidebar
  alias Platform.Repo
  alias Platform.Tenancy
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
      assert has_element?(view, "#chat-list[class*='lg:hidden']")
    end

    test "SPACES follow flatten_sections; DIRECT follows the rail's Direct list", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      a = lv_assigns(view)
      expected_spaces = a.sidebar_sections |> Sidebar.flatten_sections() |> Enum.map(& &1.id)
      expected_dms = Enum.map(a.channel_sections.dms, & &1.id)

      html = list_html(view)
      assert expected_spaces != []
      assert w.alpha.id in expected_spaces and w.beta.id in expected_spaces

      assert ids_in(html, "[data-role='chat-list-spaces'] [data-role='chat-list-row']") ==
               expected_spaces

      assert expected_dms == [w.dm.id]

      assert ids_in(html, "[data-role='chat-list-direct'] [data-role='chat-list-row']") ==
               expected_dms

      # Section order by byte position: Spaces before Direct.
      {spaces_at, _} = :binary.match(html, ~s(data-role="chat-list-spaces"))
      {direct_at, _} = :binary.match(html, ~s(data-role="chat-list-direct"))
      assert spaces_at < direct_at
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
      refute has_element?(view, "#{row} [data-role='chat-list-unread-dot']")

      say!(w.alpha, w.poster, "fresh news after leaving")

      assert has_element?(
               view,
               "#{row} [data-role='chat-list-unread-dot'][aria-label='1 unread']"
             )

      assert view |> element("#{row} [data-role='chat-list-excerpt']") |> render() =~
               "Priya: fresh news after leaving"

      # The unread excerpt switches to body text.
      assert has_element?(view, "#{row} [data-role='chat-list-excerpt'].text-base-content")
    end

    test "a deleted newest message falls back to the previous excerpt", %{conn: conn} do
      w = world(conn)
      newest = say!(w.alpha, w.poster, "about to vanish")
      {:ok, view, _} = live(w.conn, ~p"/chat")

      excerpt = "#chat-list [data-space-id='#{w.alpha.id}'] [data-role='chat-list-excerpt']"
      assert view |> element(excerpt) |> render() =~ "about to vanish"

      {:ok, _} = Chat.delete_message(newest)
      _ = render(view)

      html = view |> element(excerpt) |> render()
      assert html =~ "the alpha headline"
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
    test "a channel reads '<author>: <content>', a DM the content only", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      channel_excerpt =
        view
        |> element("#chat-list [data-space-id='#{w.alpha.id}'] [data-role='chat-list-excerpt']")
        |> render()

      assert channel_excerpt =~ "Priya: the alpha headline"

      dm_excerpt =
        view
        |> element("#chat-list [data-space-id='#{w.dm.id}'] [data-role='chat-list-excerpt']")
        |> render()

      assert dm_excerpt =~ "a direct hello"
      refute dm_excerpt =~ "Moore:"

      # A channel with no message has no excerpt and no time.
      refute has_element?(
               view,
               "#chat-list [data-space-id='#{w.beta.id}'] [data-role='chat-list-excerpt']"
             )

      assert has_element?(
               view,
               "#chat-list time[phx-hook='LocalTime']#chat-list-time-#{w.alpha.id}"
             )
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

      # Positive control: before the restriction the member's list shows it.
      {:ok, before, _} = live(login(conn, member.id), ~p"/chat")
      assert list_html(before) =~ marker

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

      for s <- ["zebra crossing numbers", "yonder project notes", "xylophone practice"] do
        assert off =~ s
      end

      assert avatar_text(off, w.org_named.id) == "G"

      mask(view, true)
      on = list_html(view)

      Platform.MaskAssertions.refute_name_anywhere(on, "Globex")

      for s <- ["zebra", "yonder", "xylophone"] do
        refute on =~ s, "excerpt text #{inspect(s)} leaked with the mask on"
      end

      # Every excerpt is the SAME fixed-length placeholder.
      placeholder = ChatList.masked_excerpt()

      for id <- [w.org_named.id, w.atlas.id, w.dm.id] do
        excerpt =
          view
          |> element("#chat-list [data-space-id='#{id}'] [data-role='chat-list-excerpt']")
          |> render()

        assert excerpt =~ placeholder
      end

      # The masked row's avatar is a neutral disc with no initial.
      assert has_element?(
               view,
               "#chat-list [data-space-id='#{w.org_named.id}'] [data-avatar='masked']"
             )

      assert avatar_text(on, w.org_named.id) == ""
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
      assert avatar_text(on, w.atlas.id) == "A"
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

    test "no hover: class inside #chat-list (positive control: active:bg-base-100)",
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
      assert Enum.filter(classes, &String.contains?(&1, "hover:")) == []
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
          {"chat-list-options", "List options: edit order, mask names, archived",
           "hero-ellipsis-horizontal"}
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

      assert html =~ "Priya: the alpha headline"

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
      # its placeholder, and draws the neutral disc.
      search(view, "atlas")
      assert sheet_html(view, "search") =~ "atlas"
      search(view, "workspace")

      assert has_element?(
               view,
               "#chat-list-search-sheet [data-space-id='#{w.org_named.id}'] [data-avatar='masked']"
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

  defp enter_edit(view) do
    open_sheet(view, "options")

    view
    |> element("#chat-list-options-sheet button[data-role='chat-list-option-edit-order']")
    |> render_click()
  end

  describe "row long-press" do
    test "list rows carry the generic RowLongPress hook; Agents and search rows do not",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")

      for id <- [w.alpha.id, w.beta.id, w.dm.id] do
        assert has_element?(
                 view,
                 "#chat-list a[data-role='chat-list-row'][data-space-id='#{id}'][phx-hook='RowLongPress'][data-long-press-event='open_list_sheet'][data-long-press-sheet='row'][data-long-press-space-id='#{id}'][data-editing='false']"
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

    test "a channel's sheet: Pin, Hide channel, Edit order; no Close, no Mute", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      refute has_element?(view, "#{@row_sheet}.sheet-open")

      long_press(view, w.alpha.id)
      assert lv_assigns(view).list_sheet == {:row, w.alpha.id}
      assert has_element?(view, "#{@row_sheet}.sheet-open")

      assert sheet_roles(view) == [
               "row-actions-pin",
               "row-actions-hide",
               "row-actions-edit-order"
             ]

      html = view |> element(@row_sheet) |> render()
      assert html =~ "Pin to top"
      assert html =~ "Hide channel"
      assert html =~ "hidden everywhere until you unhide"
      assert html =~ "Edit order"
      refute html =~ "Mute"
      refute html =~ "Close conversation"

      assert has_element?(
               view,
               "#{@row_sheet} button[data-role='row-actions-pin'][aria-label='Pin to top Alpha']"
             )
    end

    test "a DM's sheet: Pin, Close conversation, Edit order; no Hide", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.dm.id)

      assert sheet_roles(view) == [
               "row-actions-pin",
               "row-actions-close-dm",
               "row-actions-edit-order"
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

    test "Edit order from the row sheet enters the mode and closes the sheet", %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      long_press(view, w.alpha.id)

      view
      |> element("#{@row_sheet} button[data-role='row-actions-edit-order']")
      |> render_click()

      assert lv_assigns(view).sidebar_edit == true
      assert lv_assigns(view).list_sheet == nil
      refute has_element?(view, "#{@row_sheet}.sheet-open")
    end

    test "the options sheet also carries Edit order (long-press is never the only path)",
         %{conn: conn} do
      w = world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      open_sheet(view, "options")

      assert has_element?(
               view,
               "#chat-list-options-sheet button[role='switch'][data-role='chat-list-option-edit-order'][aria-checked='false']",
               "Edit order"
             )

      assert sheet_html(view, "options") =~ "move channels and sections up / down"
    end
  end

  describe "edit order" do
    # Two sub-org sections with two channels each, two pinned conversations,
    # a DM.
    defp edit_world(conn) do
      w = world(conn)
      globex = Tenancy.get_org_by_slug!("globex")
      plain_member!(w.user, globex)
      g1 = channel_in(globex, "Gamma")
      g2 = channel_in(globex, "Delta")
      p1 = channel_in(acme(), "PinOne")
      p2 = channel_in(acme(), "PinTwo")
      _ = Sidebar.set_space_pinned(w.user.id, p1.id, true)
      _ = Sidebar.set_space_pinned(w.user.id, p2.id, true)
      Map.merge(w, %{g1: g1, g2: g2, p1: p1, p2: p2})
    end

    defp arrow(id, dir),
      do:
        "#chat-list [data-role='chat-list-row-wrap'][data-space-id='#{id}'] button[data-role='chat-list-move-#{dir}']"

    test "arrows on Pinned and Spaces rows only, disabled at group ends and section edges",
         %{conn: conn} do
      w = edit_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      refute has_element?(view, "#chat-list button[data-role='chat-list-move-up']")
      # Positive control for the hidden dots below: the DM is unread now.
      assert has_element?(view, "#chat-list [data-role='chat-list-unread-dot']")

      enter_edit(view)
      assert lv_assigns(view).sidebar_edit == true
      refute has_element?(view, "#chat-list-options-sheet.sheet-open")

      assert has_element?(
               view,
               "#chat-list [data-role='chat-list-subtitle']",
               "editing order · tap ⋯ to finish"
             )

      # Pinned: first ↑ and last ↓ disabled.
      assert has_element?(view, "#{arrow(w.p1.id, "up")}[disabled]")
      refute has_element?(view, "#{arrow(w.p1.id, "down")}[disabled]")
      assert has_element?(view, "#{arrow(w.p2.id, "down")}[disabled]")
      assert has_element?(view, "#{arrow(w.p1.id, "up")}[aria-label='Move PinOne up']")

      # Spaces: each sub-org section's ends, per the resolver's sections.
      for %{channels: chans} <- lv_assigns(view).sidebar_sections, chans != [] do
        first = hd(chans)
        last = List.last(chans)
        assert has_element?(view, "#{arrow(first.id, "up")}[disabled]")
        assert has_element?(view, "#{arrow(last.id, "down")}[disabled]")

        if length(chans) > 1 do
          refute has_element?(view, "#{arrow(first.id, "down")}[disabled]")
          refute has_element?(view, "#{arrow(last.id, "up")}[disabled]")
        end
      end

      # The globex section holds exactly Gamma and Delta: a boundary inside
      # the flattened list.
      assert Enum.any?(lv_assigns(view).sidebar_sections, fn %{channels: c} ->
               Enum.sort(Enum.map(c, & &1.id)) == Enum.sort([w.g1.id, w.g2.id])
             end)

      # No arrows on DIRECT rows.
      refute has_element?(view, arrow(w.dm.id, "up"))

      # The arrows are siblings of the link, never inside it.
      doc = view |> element("#chat-list") |> render() |> LazyHTML.from_fragment()
      assert Enum.count(LazyHTML.query(doc, "button[data-role='chat-list-move-up']")) >= 4
      assert Enum.count(LazyHTML.query(doc, "[data-phx-link] button")) == 0
      assert Enum.count(LazyHTML.query(doc, "[data-phx-link][phx-click]")) == 0

      # Long-press is inert while editing; unread dots hide.
      assert has_element?(
               view,
               "#chat-list a[data-space-id='#{w.alpha.id}'][data-editing='true']"
             )

      refute has_element?(view, "#chat-list [data-role='chat-list-unread-dot']")

      assert has_element?(
               view,
               "#chat-list [data-role='chat-list-announcer'][aria-live='polite']"
             )
    end

    test "a Spaces move persists through Sidebar: the reloaded list AND rail show it",
         %{conn: conn} do
      w = edit_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      enter_edit(view)

      [section] =
        Enum.filter(lv_assigns(view).sidebar_sections, fn %{channels: c} ->
          Enum.any?(c, &(&1.id == w.g1.id))
        end)

      [first, second | _] = Enum.map(section.channels, & &1.id)
      view |> element(arrow(first, "down")) |> render_click()

      assert view |> element("#chat-list [data-role='chat-list-announcer']") |> render() =~
               "Moved"

      # A reload: a fresh mount reads the persisted order.
      {:ok, reloaded, _} = live(w.conn, ~p"/chat")

      list_ids =
        ids_in(list_html(reloaded), "[data-role='chat-list-spaces'] [data-role='chat-list-row']")

      assert Enum.find_index(list_ids, &(&1 == second)) <
               Enum.find_index(list_ids, &(&1 == first))

      rail_ids =
        reloaded
        |> element("#chat-sidebar")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[data-channel-id]")
        |> LazyHTML.attribute("data-channel-id")

      assert Enum.find_index(rail_ids, &(&1 == second)) <
               Enum.find_index(rail_ids, &(&1 == first))
    end

    test "a Pinned move persists through Sidebar's pinned order", %{conn: conn} do
      w = edit_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      enter_edit(view)

      before =
        ids_in(list_html(view), "[data-role='chat-list-pinned'] [data-role='chat-list-row']")

      assert before == [w.p1.id, w.p2.id]
      view |> element(arrow(w.p1.id, "down")) |> render_click()

      assert Sidebar.list_pinned_space_ids(w.user.id) |> Enum.filter(&(&1 in [w.p1.id, w.p2.id])) ==
               [w.p2.id, w.p1.id]

      {:ok, reloaded, _} = live(w.conn, ~p"/chat")

      assert ids_in(
               list_html(reloaded),
               "[data-role='chat-list-pinned'] [data-role='chat-list-row']"
             ) ==
               [w.p2.id, w.p1.id]
    end

    test "tapping Edit order again leaves the mode", %{conn: conn} do
      w = edit_world(conn)
      {:ok, view, _} = live(w.conn, ~p"/chat")
      enter_edit(view)
      enter_edit(view)
      assert lv_assigns(view).sidebar_edit == false
      refute has_element?(view, "#chat-list button[data-role='chat-list-move-up']")
    end
  end
end
