defmodule PlatformWeb.ChatLiveSpaceSheetTest do
  @moduledoc """
  The phone space header and space sheet (task 01a1557a-8a6d, rung 7): the
  title button that opens `#space-sheet`, the phone Call button, the sheet's
  stage-1 rows (Canvases in this space, Members, Agents, Start a call, Space
  settings), stage 2's pushed pages (Search, Pinned, Threads), stage 3's
  (Goal, Scope), with the header's icon row and mobile scope pill gone below
  lg, and stage 4's Links & files segments, where the title tap now lands.

  Every absence assertion sits beside a presence assertion on the same
  fixture, so an empty render cannot pass it. The mask tests are a matched
  pair: the real name IS in both name nodes with masking off.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Platform.MaskAssertions

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Chat.ActiveAgentStore
  alias Platform.Chat.Pin
  alias Platform.Repo
  alias Platform.Tenancy
  alias Platform.Tenancy.Org

  @title "button[data-role='space-title']"
  @sheet "#space-sheet"
  @call "button[data-role='space-call']"
  @row_canvases "#space-sheet button[data-role='space-sheet-canvases']"
  @row_members "#space-sheet button[data-role='space-sheet-members']"
  @row_agents "#space-sheet button[data-role='space-sheet-agents']"
  @row_call "#space-sheet button[data-role='space-sheet-call']"
  @row_settings "#space-sheet button[data-role='space-sheet-settings']"

  # An org-named channel: the only configuration in which a channel name is
  # masked (see chat_live_mask_title_test.exs).
  @org "Vandelay-Ind"

  # ── fixtures ──────────────────────────────────────────────────────────

  defp user!(tag) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "space-sheet-#{tag}-#{n}@example.com",
      name: "Sheet #{tag} #{n}",
      oidc_sub: "oidc-space-sheet-#{tag}-#{n}"
    })
  end

  defp agent!(name) do
    n = System.unique_integer([:positive])

    Repo.insert!(%Agent{
      slug: "space-sheet-agent-#{n}",
      name: "#{name} #{n}",
      status: "active",
      model_config: %{"primary" => "anthropic/claude-sonnet-4-6"}
    })
  end

  defp space!(kind, attrs \\ %{}) do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(
        Map.merge(%{name: "Sheet Room #{n}", slug: "space-sheet-#{kind}-#{n}", kind: kind}, attrs)
      )

    space
  end

  defp seat_user(space, user) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        display_name: user.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp seat_agent(space, agent) do
    {:ok, p} =
      Chat.add_participant(space.id, %{
        participant_type: "agent",
        participant_id: agent.id,
        display_name: agent.name,
        joined_at: DateTime.utc_now()
      })

    p
  end

  defp open_as(conn, user, space) do
    {:ok, view, html} =
      conn |> init_test_session(current_user_id: user.id) |> live(~p"/chat/#{space.slug}")

    {view, html}
  end

  defp lv_assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # The title opens on the All segment (stage 4); most tests here work on the
  # Space segment, so this helper goes on to it. `tap_title/1` is the bare tap.
  defp tap_title(view), do: view |> element(@title) |> render_click()

  defp open_sheet(view) do
    tap_title(view)
    view |> element("#space-sheet button[data-seg='space']") |> render_click()
  end

  defp sheet_open?(view), do: has_element?(view, "#{@sheet}[data-open='true']")

  defp fragment(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.to_html()
  end

  defp with_meetings(_context) do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)
    :ok
  end

  # ── the title button and the sheet ────────────────────────────────────

  describe "title button" do
    test "renders as one dialog button carrying the name, chevron and people count",
         %{conn: conn} do
      user = user!("title")
      channel = space!("channel")
      seat_user(channel, user)
      seat_user(channel, user!("other"))

      {view, _html} = open_as(conn, user, channel)

      title = view |> element(@title) |> render()
      assert title =~ ~s(aria-haspopup="dialog")
      assert title =~ ~s(aria-expanded="false")
      assert title =~ ~s(phx-click="open_space_sheet")
      assert title =~ ~s(aria-label="Space details, ##{channel.name}")
      assert title =~ "hero-chevron-down"
      assert title =~ "2 people"
      assert title =~ "min-h-11"

      refute sheet_open?(view)
      open_sheet(view)
      assert sheet_open?(view)
      assert lv_assigns(view).space_sheet == :space
      assert view |> element(@title) |> render() =~ ~s(aria-expanded="true")
    end

    test "close_space_sheet closes it", %{conn: conn} do
      user = user!("close")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      assert sheet_open?(view)

      render_click(view, "close_space_sheet", %{})
      refute sheet_open?(view)
      assert lv_assigns(view).space_sheet == nil
    end

    test "switching spaces closes it", %{conn: conn} do
      user = user!("switch")
      a = space!("channel")
      b = space!("channel")
      seat_user(a, user)
      seat_user(b, user)
      {view, _html} = open_as(conn, user, a)

      open_sheet(view)
      assert sheet_open?(view)

      render_patch(view, ~p"/chat/#{b.slug}")
      assert lv_assigns(view).active_space.id == b.id
      assert lv_assigns(view).space_sheet == nil
      refute sheet_open?(view)
    end

    test "unknown pages are ignored and back returns to the Space page", %{conn: conn} do
      user = user!("pages")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      # Shut: a page event does not open it.
      render_click(view, "space_sheet_page", %{"page" => "space"})
      assert lv_assigns(view).space_sheet == nil

      open_sheet(view)
      render_click(view, "space_sheet_page", %{"page" => "nonsense"})
      assert lv_assigns(view).space_sheet == :space

      render_click(view, "space_sheet_back", %{})
      assert lv_assigns(view).space_sheet == :space
    end

    test "the sheet's handle is the Close button and swipe-down is on", %{conn: conn} do
      user = user!("handle")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      # `handle_close` turns the bare handle div into this button; without it
      # a touch swipe-down never closes the sheet (pointercancel).
      assert has_element?(view, "#{@sheet} button.sheet-handle-button[aria-label='Close']")
      assert has_element?(view, "#{@sheet}[data-swipe-dismiss='true']")
      assert has_element?(view, "#{@sheet}[data-on-close='close_space_sheet']")
      assert has_element?(view, "#{@sheet}.lg\\:hidden")
    end
  end

  describe "subtitle" do
    test "a DM with a person says Direct message, not a people count", %{conn: conn} do
      user = user!("dm")
      other = user!("dm-other")
      dm = space!("dm")
      seat_user(dm, user)
      seat_user(dm, other)

      {view, _html} = open_as(conn, user, dm)
      subtitle = view |> element("[data-role='space-title-subtitle']") |> render()

      assert subtitle =~ "Direct message"
      refute subtitle =~ "people"
    end

    test "a DM with an agent shows the agent's status", %{conn: conn} do
      user = user!("agent-dm")
      dm = space!("dm")
      seat_user(dm, user)
      seat_agent(dm, agent!("Helper"))

      {view, _html} = open_as(conn, user, dm)
      subtitle = view |> element("[data-role='space-title-subtitle']") |> render()

      assert subtitle =~ ~r/Online|Offline|Thinking|Agent/
      refute subtitle =~ "Direct message"
      refute subtitle =~ "people"
    end
  end

  # ── rows ──────────────────────────────────────────────────────────────

  describe "rows" do
    test "Space settings closes the sheet and opens the settings modal", %{conn: conn} do
      user = user!("settings")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      assert lv_assigns(view).show_settings == false
      view |> element(@row_settings) |> render_click()

      assert lv_assigns(view).show_settings == true
      assert lv_assigns(view).space_sheet == nil
    end

    # The Members sheet (task 01a1557a-8f80 stage 3): the row's meta is the
    # people count and it opens the phone sheet.
    test "Members closes the sheet and opens the Members sheet", %{conn: conn} do
      user = user!("members")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      refute has_element?(view, "[data-role=members-sheet-body]")
      assert has_element?(view, @row_members, "1 person")
      view |> element(@row_members) |> render_click()

      assert has_element?(view, "#members-sheet.sheet-open [data-role=members-sheet-body]")
      assert lv_assigns(view).space_sheet == nil
    end

    test "Canvases in this space navigates to the scoped browser; no highlight at zero", %{
      conn: conn
    } do
      user = user!("canvases")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      row = view |> element(@row_canvases) |> render()
      assert row =~ "Canvases in this space"
      # The preview is the row's only subtle text; at zero there is none.
      refute row =~ "text-subtle"

      assert lv_assigns(view).show_canvases == false
      view |> element(@row_canvases) |> render_click()

      assert_redirect(view, "/files?space=#{channel.id}&type=canvas")
    end

    test "Members renders in a channel and a group, not in a DM", %{conn: conn} do
      user = user!("members-dm")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      assert has_element?(view, @row_members)
      assert has_element?(view, @row_settings)

      group = space!("group")
      seat_user(group, user)
      {view, _html} = open_as(conn, user, group)
      open_sheet(view)
      assert has_element?(view, @row_members)

      dm = space!("dm")
      seat_user(dm, user)
      seat_user(dm, user!("members-dm-other"))
      {view, _html} = open_as(conn, user, dm)
      open_sheet(view)
      assert has_element?(view, @row_settings)
      refute has_element?(view, @row_members)
    end
  end

  describe "Agents row" do
    test "renders where the Agents entry renders and opens the Agents sheet", %{conn: conn} do
      user = user!("agents")
      channel = space!("channel")
      seat_user(channel, user)
      seat_agent(channel, agent!("Helper"))
      silenced = seat_agent(channel, agent!("Quiet"))
      {:ok, _} = Chat.set_agent_silenced({:user, user.id}, channel.id, silenced.id, true)

      {view, _html} = open_as(conn, user, channel)

      # The desktop entry is the details panel's Agents row (Burrow redesign
      # 22 stage 4 deleted the header button).
      assert render_click(view, "details_open", %{"page" => "space"}) =~
               ~s(data-role="details-agents")

      open_sheet(view)
      # The masters' entry meta: '<awake>/<total> awake · <policy>'.
      assert view |> element(@row_agents) |> render() =~ "1/2 awake · on-mention"

      view |> element(@row_agents) |> render_click()

      assert lv_assigns(view).space_sheet == nil
      assert lv_assigns(view).agents_sheet_open == true
      assert has_element?(view, "#agents-sheet.sheet-open")
      # Opening the sheet arms nothing: the row no longer touches the mutex.
      assert ActiveAgentStore.get_active(channel.id) == nil
    end

    test "is absent where the Agents entry is absent: no agent, and a DM", %{conn: conn} do
      user = user!("no-agent")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      assert has_element?(view, @row_settings)

      refute render_click(view, "details_open", %{"page" => "space"}) =~
               ~s(data-role="details-agents")

      refute has_element?(view, @row_agents)

      dm = space!("dm")
      seat_user(dm, user)
      seat_agent(dm, agent!("Dm"))
      {view, _html} = open_as(conn, user, dm)
      open_sheet(view)
      assert has_element?(view, @row_settings)

      refute render_click(view, "details_open", %{"page" => "space"}) =~
               ~s(data-role="details-agents")

      refute has_element?(view, @row_agents)
    end
  end

  describe "calls" do
    setup :with_meetings

    test "Call and Start a call carry the Meet gate; the desktop Call is desktop-only",
         %{conn: conn} do
      user = user!("call")
      channel = space!("channel")
      seat_user(channel, user)
      {view, html} = open_as(conn, user, channel)

      call = view |> element(@call) |> render()
      assert call =~ ~s(aria-label="Start a call")
      assert call =~ "hero-phone"
      assert call =~ "text-primary"
      assert call =~ "lg:hidden"
      assert call =~ "size-11"
      open_sheet(view)
      assert has_element?(view, @row_call)

      # The desktop Call (Burrow redesign 22 stage 4) sits in the lg-only
      # main-pane header.
      assert fragment(html, ~s([data-role="main-head"].hidden.lg\\:flex #chat-call)) =~ "Call"
    end

    test "Start a call closes the sheet and reaches MeetingHooks; both go while in the call",
         %{conn: conn} do
      user = user!("join")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      view |> element(@row_call) |> render_click()

      assert_push_event(view, "join-meeting", _payload)
      assert lv_assigns(view).in_meeting == true
      assert lv_assigns(view).space_sheet == nil

      open_sheet(view)
      assert has_element?(view, @row_settings)
      refute has_element?(view, @call)
      refute has_element?(view, @row_call)
    end

    test "the header Call fires meeting_join", %{conn: conn} do
      user = user!("header-call")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      view |> element(@call) |> render_click()
      assert_push_event(view, "join-meeting", _payload)
    end

    test "an external user gets neither Call nor Start a call", %{conn: conn} do
      n = System.unique_integer([:positive])

      org =
        %Org{}
        |> Org.changeset(%{
          name: "Tenant #{n}",
          slug: "tenant_sheet_#{n}",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id
        })
        |> Repo.insert!()

      ext = user!("ext")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})
      Tenancy.allow_dm(ext, org)

      channel = space!("channel", %{org_id: org.id})
      seat_user(channel, ext)

      {:ok, view, _html} =
        %{conn | host: "chat.localhost"}
        |> init_test_session(current_user_id: ext.id)
        |> live(~p"/chat/#{channel.slug}")

      assert lv_assigns(view).external? == true
      assert has_element?(view, @title)
      open_sheet(view)
      assert sheet_open?(view)
      assert has_element?(view, @row_settings)
      refute has_element?(view, @call)
      refute has_element?(view, @row_call)
    end
  end

  # ── masking ───────────────────────────────────────────────────────────

  defp org_channel!(user) do
    org = Tenancy.get_org_by_slug("vandelay-ind")

    {:ok, channel} =
      Chat.create_space(%{
        name: @org,
        slug: "vandelay-ind",
        kind: "channel",
        org_id: org && org.id
      })

    seat_user(channel, user)
    channel
  end

  defp name_nodes(view) do
    html = render(view)

    %{
      title: fragment(html, @title),
      sheet_title: fragment(html, "#space-sheet-title"),
      visible_title: fragment(html, "[data-role='space-sheet-title']")
    }
  end

  describe "masking" do
    test "MATCHED PAIR: unmasked, the title button and both sheet titles spell the name",
         %{conn: conn} do
      user = user!("unmasked")
      channel = org_channel!(user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      for {node, html} <- name_nodes(view) do
        assert html != "", "expected #{node} to render"
        assert_name_anywhere(html, @org)
      end
    end

    test "masked, none of the three name nodes spells the name", %{conn: conn} do
      user = user!("masked")
      channel = org_channel!(user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      render_click(view, "toggle_mask_names", %{"masked" => "true"})
      assert lv_assigns(view).mask_names? == true

      for {node, html} <- name_nodes(view) do
        assert html != "", "expected #{node} to render"
        refute_name_anywhere(html, @org)
      end

      assert name_nodes(view).title =~ ~r/aria-label="Space details, #[^"]*workspace/i
    end
  end

  # ── stage 2: Search, Pinned and Threads pages ─────────────────────────

  defp post!(space, participant, content) do
    {:ok, m} =
      Chat.post_message(%{
        space_id: space.id,
        participant_id: participant.id,
        content_type: "text",
        content: content
      })

    m
  end

  defp go_page(view, page), do: render_click(view, "space_sheet_page", %{"page" => page})

  defp row_preview(view, role) do
    view |> element("#space-sheet button[data-role='#{role}']") |> render()
  end

  describe "Space page rows for the pages" do
    test "Search in space is first; Threads and Pinned show no count at zero", %{conn: conn} do
      user = user!("rows2")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      html = view |> element("#space-sheet [data-page='space']") |> render()

      roles =
        Regex.scan(~r/data-role="(space-sheet-[a-z]+)"/, html)
        |> Enum.map(&List.last/1)
        |> Enum.reject(&(&1 == "space-sheet-page"))

      assert hd(roles) == "space-sheet-search"

      assert Enum.take(roles -- ["space-sheet-agents", "space-sheet-members"], 4) ==
               [
                 "space-sheet-search",
                 "space-sheet-canvases",
                 "space-sheet-threads",
                 "space-sheet-pinned"
               ]

      refute row_preview(view, "space-sheet-threads") =~ "text-subtle"
      refute row_preview(view, "space-sheet-pinned") =~ "text-subtle"
    end

    test "back returns to the Space page; unknown pages stay ignored", %{conn: conn} do
      user = user!("back")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      view |> element("#space-sheet button[data-role='space-sheet-threads']") |> render_click()
      assert lv_assigns(view).space_sheet == :threads
      assert has_element?(view, "#space-sheet [data-page='threads']")
      refute has_element?(view, "#space-sheet [data-page='space']")
      assert has_element?(view, "#space-sheet-title", "Threads")

      view |> element("#space-sheet button[data-role='space-sheet-back']") |> render_click()
      assert lv_assigns(view).space_sheet == :space
      assert has_element?(view, "#space-sheet [data-page='space']")
    end

    test "a space switch from a sub-page still shuts the sheet", %{conn: conn} do
      user = user!("switch2")
      a = space!("channel")
      b = space!("channel")
      seat_user(a, user)
      seat_user(b, user)
      {view, _html} = open_as(conn, user, a)
      open_sheet(view)
      go_page(view, "pinned")
      assert lv_assigns(view).space_sheet == :pinned

      render_patch(view, ~p"/chat/#{b.slug}")
      assert lv_assigns(view).space_sheet == nil
      assert lv_assigns(view).space_sheet_pins == []
    end
  end

  describe "Search page" do
    test "submits through search_submit, lists the match, and a tap highlights it",
         %{conn: conn} do
      user = user!("search")
      channel = space!("channel")
      p = seat_user(channel, user)
      hit = post!(channel, p, "the quokka migration is done")
      _miss = post!(channel, p, "nothing relevant")
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      view |> element("#space-sheet button[data-role='space-sheet-search']") |> render_click()

      assert has_element?(
               view,
               "#space-sheet-search-form input[name='search[query]'][phx-hook='SearchFocus']"
             )

      assert has_element?(view, "#space-sheet-title", "Search in ##{channel.name}")

      view
      |> form("#space-sheet-search-form", %{"search" => %{"query" => "quokka"}})
      |> render_change()

      assert has_element?(
               view,
               "#space-sheet [data-role='space-sheet-search-result'][data-message-id='#{hit.id}']"
             )

      assert render(view) =~ "quokka"
      # No second results list: the desktop drawer was deleted (Burrow
      # redesign 22 stage 4).
      refute render(view) =~ "Search Results"

      view
      |> element(
        "#space-sheet [data-role='space-sheet-search-result'][data-message-id='#{hit.id}']"
      )
      |> render_click()

      assert lv_assigns(view).space_sheet == nil
      assert lv_assigns(view).highlighted_message_id == hit.id
    end

    test "no match says so", %{conn: conn} do
      user = user!("search-none")
      channel = space!("channel")
      p = seat_user(channel, user)
      post!(channel, p, "something else")
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      go_page(view, "search")

      view
      |> form("#space-sheet-search-form", %{"search" => %{"query" => "xylophone"}})
      |> render_change()

      assert has_element?(view, "[data-role='space-sheet-search-empty']", "No messages match.")
      refute has_element?(view, "[data-role='space-sheet-search-result']")
    end
  end

  defp pinned_world(user) do
    channel = space!("channel")
    p = seat_user(channel, user)
    first = post!(channel, p, "first pinned excerpt")
    second = post!(channel, p, "second pinned excerpt")
    Repo.insert!(%Pin{space_id: channel.id, message_id: first.id, pinned_by: p.id})
    Repo.insert!(%Pin{space_id: channel.id, message_id: second.id, pinned_by: p.id})
    %{channel: channel, first: first, second: second}
  end

  describe "Pinned page" do
    test "lists excerpts, Unpin removes the row and the pin, and the count follows",
         %{conn: conn} do
      user = user!("pins")
      w = pinned_world(user)
      {view, _html} = open_as(conn, user, w.channel)
      open_sheet(view)
      assert row_preview(view, "space-sheet-pinned") =~ ~r/>\s*2\s*</

      go_page(view, "pinned")
      page = view |> element("#space-sheet [data-page='pinned']") |> render()
      assert page =~ "first pinned excerpt"
      assert page =~ "second pinned excerpt"
      refute page =~ "pinned message"

      view
      |> element(
        "[data-role='space-sheet-pin'][data-message-id='#{w.first.id}'] [data-role='space-sheet-unpin']"
      )
      |> render_click()

      # The broadcast lands on this same LiveView.
      _ = render(view)
      refute has_element?(view, "[data-role='space-sheet-pin'][data-message-id='#{w.first.id}']")
      assert has_element?(view, "[data-role='space-sheet-pin'][data-message-id='#{w.second.id}']")
      refute Repo.get_by(Pin, space_id: w.channel.id, message_id: w.first.id)

      render_click(view, "space_sheet_back", %{})
      assert row_preview(view, "space-sheet-pinned") =~ ~r/>\s*1\s*</

      go_page(view, "pinned")

      view
      |> element(
        "[data-role='space-sheet-pin'][data-message-id='#{w.second.id}'] [data-role='space-sheet-unpin']"
      )
      |> render_click()

      _ = render(view)

      assert has_element?(
               view,
               "[data-role='space-sheet-pins-empty']",
               "Nothing pinned yet. Long-press a message to pin it."
             )

      render_click(view, "space_sheet_back", %{})
      refute row_preview(view, "space-sheet-pinned") =~ "text-subtle"
    end

    test "a pinned row jumps to its message", %{conn: conn} do
      user = user!("pin-jump")
      w = pinned_world(user)
      {view, _html} = open_as(conn, user, w.channel)
      open_sheet(view)
      go_page(view, "pinned")

      view
      |> element(
        "[data-role='space-sheet-pin'][data-message-id='#{w.second.id}'] [data-role='space-sheet-pin-open']"
      )
      |> render_click()

      assert lv_assigns(view).space_sheet == nil
      assert lv_assigns(view).highlighted_message_id == w.second.id
    end

    test "an archived space lists its pins with no Unpin", %{conn: conn} do
      user = user!("pin-archived")
      w = pinned_world(user)
      {:ok, _} = Chat.archive_space(w.channel)
      {view, _html} = open_as(conn, user, w.channel)
      open_sheet(view)
      go_page(view, "pinned")

      assert has_element?(view, "[data-role='space-sheet-pin'][data-message-id='#{w.first.id}']")
      refute has_element?(view, "[data-role='space-sheet-unpin']")
    end
  end

  describe "Threads page" do
    test "lists a thread with its reply count and a tap opens it", %{conn: conn} do
      user = user!("threads")
      channel = space!("channel")
      p = seat_user(channel, user)
      parent = post!(channel, p, "the thread parent line")
      {:ok, thread} = Chat.create_thread(channel.id, %{parent_message_id: parent.id})

      for text <- ["reply one", "reply two"] do
        {:ok, _} =
          Chat.post_message(%{
            space_id: channel.id,
            thread_id: thread.id,
            participant_id: p.id,
            content_type: "text",
            content: text
          })
      end

      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      assert row_preview(view, "space-sheet-threads") =~ ~r/>\s*1\s*</

      go_page(view, "threads")

      row =
        view
        |> element("[data-role='space-sheet-thread'][data-message-id='#{parent.id}']")
        |> render()

      assert row =~ "the thread parent line"
      assert row =~ "2 replies"

      view
      |> element("[data-role='space-sheet-thread'][data-message-id='#{parent.id}']")
      |> render_click()

      assert lv_assigns(view).space_sheet == nil
      assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
    end

    test "no threads says so", %{conn: conn} do
      user = user!("threads-none")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      go_page(view, "threads")

      assert has_element?(view, "[data-role='space-sheet-threads-empty']", "No threads yet.")
    end
  end

  # ── stage 3: Goal, Scope and the phone header ──────────────────────────

  @goal_flag :agents_goal_surface

  defp with_goal_flag(_context) do
    previous = Application.get_env(:platform, @goal_flag)
    Application.put_env(:platform, @goal_flag, true)
    on_exit(fn -> Application.put_env(:platform, @goal_flag, previous) end)
    :ok
  end

  defp make_admin(user) do
    %Platform.Tenancy.OrgMembership{}
    |> Platform.Tenancy.OrgMembership.changeset(%{
      user_id: user.id,
      org_id: Tenancy.get_org_by_slug!("acme").id,
      role: "admin"
    })
    |> Repo.insert!()
  end

  # Every `id` in the rendered document, and the ones that occur twice.
  defp duplicate_ids(html) do
    html
    |> LazyHTML.from_document()
    |> LazyHTML.query("[id]")
    |> LazyHTML.attribute("id")
    |> Enum.frequencies()
    |> Enum.filter(fn {_id, n} -> n > 1 end)
  end

  describe "Goal" do
    setup :with_goal_flag

    test "the row previews the goal and the page renders the goal panel, no duplicate ids",
         %{conn: conn} do
      user = user!("goal")
      leader = agent!("Lead")
      channel = space!("channel", %{goal: "Ship the space sheet", leader_agent_id: leader.id})
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)

      # The desktop strip is gone (Burrow redesign 22 stage 4): the goal
      # renders only on a Goal page.
      refute render(view) =~ ~s(data-role="agents-goal-strip")
      refute render(view) =~ ~s(data-role="agents-goal-sentence")

      open_sheet(view)
      row = row_preview(view, "space-sheet-goal")
      assert row =~ "Ship the space sheet"
      assert row =~ "text-subtle"

      go_page(view, "goal")
      page = view |> element("#space-sheet [data-page='goal']") |> render()
      assert page =~ ~s(data-role="agents-goal-sentence")
      assert page =~ "Ship the space sheet"
      assert has_element?(view, "#space-sheet-title", "Goal")
      assert duplicate_ids(render(view)) == []
    end

    test "an admin with no goal: 'Add a goal', then edit and save from the sheet",
         %{conn: conn} do
      user = user!("goal-admin")
      make_admin(user)
      channel = space!("channel", %{name: "agents-sheet-invite"})
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      assert lv_assigns(view).goal_invite? == true

      open_sheet(view)
      row = row_preview(view, "space-sheet-goal")
      assert row =~ "Add a goal"
      assert row =~ "text-base-content"
      refute row =~ "text-subtle"

      go_page(view, "goal")
      view |> element("#space-sheet [data-role='agents-goal-invite']") |> render_click()
      assert has_element?(view, "#space-sheet [data-role='agents-goal-form']")
      assert duplicate_ids(render(view)) == []

      view
      |> form("#space-sheet [data-role='agents-goal-form']", %{goal: "Close the sheet backlog"})
      |> render_submit()

      assert Repo.reload!(channel).goal == "Close the sheet backlog"
      # The page stays open and re-renders in its read state.
      assert lv_assigns(view).space_sheet == :goal

      assert has_element?(
               view,
               "#space-sheet [data-role='agents-goal-sentence']",
               "Close the sheet backlog"
             )

      refute has_element?(view, "#space-sheet [data-role='agents-goal-form']")
    end

    test "editing with the cadence controls open keeps every id unique", %{conn: conn} do
      user = user!("goal-cadence")
      make_admin(user)
      channel = space!("channel", %{name: "agents-sheet-cadence", goal: "Keep it unique"})
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      assert lv_assigns(view).can_edit_goal? == true

      open_sheet(view)
      go_page(view, "goal")
      render_click(view, "edit_goal", %{})

      # With the details panel's Goal page open too, both copies carry
      # their own prefix.
      html = render_click(view, "details_open", %{"page" => "goal"})
      html = if html =~ ~s(id="details-agents-goal-cadence"), do: html, else: render(view)
      assert html =~ ~s(id="details-agents-goal-cadence")
      assert html =~ ~s(id="space-sheet-agents-goal-cadence")
      assert duplicate_ids(html) == []
    end

    test "no goal and no invitation: no Goal row", %{conn: conn} do
      user = user!("goal-none")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      assert has_element?(view, @row_settings)
      refute has_element?(view, "#space-sheet button[data-role='space-sheet-goal']")
    end
  end

  defp scoped_channel!(user) do
    org = Tenancy.get_org_by_slug("vandelay_ind")
    assert org, "the seeded vandelay_ind org is this fixture's scope"

    {:ok, channel} =
      Chat.create_space(%{
        name: "Sheet Scope #{System.unique_integer([:positive])}",
        slug: "sheet-scope-#{System.unique_integer([:positive])}",
        kind: "channel",
        org_id: org.id
      })

    seat_user(channel, user)
    {channel, org}
  end

  describe "Scope" do
    test "the row previews the org and the switch toggles the scope filter", %{conn: conn} do
      user = user!("scope")
      {channel, org} = scoped_channel!(user)
      {view, _html} = open_as(conn, user, channel)
      assert lv_assigns(view).active_space_scope != nil

      open_sheet(view)
      row = row_preview(view, "space-sheet-scope")
      assert row =~ org.name
      assert row =~ "filter off"

      view |> element("#space-sheet button[data-role='space-sheet-scope']") |> render_click()
      switch = "#space-sheet button[data-role='space-sheet-scope-switch']"
      assert view |> element(switch) |> render() =~ ~s(aria-checked="false")
      assert view |> element(switch) |> render() =~ "Filter to #{org.name} scope"

      view |> element(switch) |> render_click()
      assert lv_assigns(view).scope_filter == lv_assigns(view).active_space_scope
      assert view |> element(switch) |> render() =~ ~s(aria-checked="true")

      view |> element(switch) |> render_click()
      assert lv_assigns(view).scope_filter == nil
    end

    test "MATCHED PAIR: the Scope row and switch spell the org unmasked, and not masked",
         %{conn: conn} do
      user = user!("scope-mask")
      {channel, org} = scoped_channel!(user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)

      row = row_preview(view, "space-sheet-scope")
      assert_name_anywhere(row, org.name)
      go_page(view, "scope")

      assert_name_anywhere(
        view |> element("#space-sheet [data-page='scope']") |> render(),
        org.name
      )

      render_click(view, "toggle_mask_names", %{"masked" => "true"})
      assert lv_assigns(view).mask_names? == true

      page = view |> element("#space-sheet [data-page='scope']") |> render()
      refute_name_anywhere(page, org.name)
      assert page =~ ~r/workspace/i

      render_click(view, "space_sheet_back", %{})
      row = row_preview(view, "space-sheet-scope")
      refute_name_anywhere(row, org.name)
      assert row =~ ~r/workspace/i
    end

    test "absent for a DM, a group and an external user", %{conn: conn} do
      user = user!("scope-absent")
      {channel, _org} = scoped_channel!(user)
      {view, _html} = open_as(conn, user, channel)
      open_sheet(view)
      assert has_element?(view, "#space-sheet button[data-role='space-sheet-scope']")

      for kind <- ["dm", "group"] do
        space = space!(kind)
        seat_user(space, user)
        seat_user(space, user!("scope-#{kind}"))
        {view, _html} = open_as(conn, user, space)
        open_sheet(view)
        assert has_element?(view, @row_settings)
        refute has_element?(view, "#space-sheet button[data-role='space-sheet-scope']")
      end

      n = System.unique_integer([:positive])

      org =
        %Org{}
        |> Org.changeset(%{
          name: "Tenant #{n}",
          slug: "tenant_scope_#{n}",
          parent_org_id: Tenancy.get_org_by_slug!("acme").id
        })
        |> Repo.insert!()

      ext = user!("scope-ext")
      {:ok, _} = Tenancy.mark_membership_external(%{user_id: ext.id, org_id: org.id})
      ext_channel = space!("channel", %{org_id: org.id})
      seat_user(ext_channel, ext)

      {:ok, view, _html} =
        %{conn | host: "chat.localhost"}
        |> init_test_session(current_user_id: ext.id)
        |> live(~p"/chat/#{ext_channel.slug}")

      open_sheet(view)
      assert has_element?(view, @row_settings)
      refute has_element?(view, "#space-sheet button[data-role='space-sheet-scope']")
    end
  end

  describe "phone header" do
    test "below lg: no mobile scope pill, and the desktop header is lg-only", %{conn: conn} do
      user = user!("header")
      {channel, _org} = scoped_channel!(user)
      seat_agent(channel, agent!("Eye"))
      p = seat_user(channel, user!("header-other"))
      m = post!(channel, p, "pin me")
      Repo.insert!(%Pin{space_id: channel.id, message_id: m.id, pinned_by: p.id})
      {view, html} = open_as(conn, user, channel)

      header = fragment(html, "header:has(#chat-title)")
      refute header =~ "chat-header-scope-pill"

      # Burrow redesign 22 stage 4: the desktop controls are the main-pane
      # header's controls, all inside the lg-only branch (Call is covered in
      # "calls", it needs meetings on), and none of the old icon row is left.
      for selector <- ["#chat-title", "#chat-search", "#chat-details"] do
        assert fragment(html, ~s([data-role="main-head"].hidden.lg\\:flex ) <> selector) != "",
               "#{selector} must be lg-only"
      end

      for selector <- [
            "[data-role='agents-open']",
            "[data-role='members-open']",
            ~s(header button[phx-click="settings_open"]),
            ~s(button[phx-click="pin_panel_toggle"]),
            "#chat-search-form"
          ] do
        assert fragment(html, selector) == "", "#{selector} must be gone"
      end

      _ = view
    end
  end

  # ── stage 4: Links & files segments ───────────────────────────────────

  defp attachment!(space, message, filename, content_type) do
    {:ok, att} =
      Chat.create_attachment(%{
        space_id: space.id,
        message_id: message.id,
        filename: filename,
        content_type: content_type,
        byte_size: 2048,
        storage_key: "space-sheet-#{System.unique_integer([:positive])}"
      })

    att
  end

  defp canvas!(space, participant, title) do
    {:ok, canvas} =
      Chat.create_canvas(%{
        "space_id" => space.id,
        "created_by" => participant.id,
        "title" => title,
        "document" => %{
          "version" => 1,
          "revision" => 1,
          "root" => %{"id" => "root", "type" => "stack", "props" => %{}, "children" => []},
          "theme" => %{},
          "bindings" => %{},
          "meta" => %{}
        }
      })

    canvas
  end

  # A channel with one of each kind: a canvas, a PDF, a video file, a site
  # link and a video link.
  defp shared_world(conn) do
    user = user!("links")
    channel = space!("channel")
    p = seat_user(channel, user)
    canvas = canvas!(channel, p, "Sheet plan canvas")
    doc = post!(channel, p, "spec attached")
    pdf = attachment!(channel, doc, "sheet-spec.pdf", "application/pdf")
    clip = post!(channel, p, "screen recording")
    video = attachment!(channel, clip, "walkthrough.mp4", "video/mp4")
    post!(channel, p, "the docs are at https://example.org/docs/sheet")
    post!(channel, p, "demo https://www.youtube.com/watch?v=sheetdemo")
    {view, _html} = open_as(conn, user, channel)

    %{view: view, channel: channel, canvas: canvas, pdf: pdf, video: video}
  end

  defp seg(view, key),
    do: view |> element("#space-sheet button[data-seg='#{key}']") |> render_click()

  defp rows(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#space-sheet [data-role='space-sheet-link-row']")
  end

  defp row_kinds(view), do: view |> rows() |> LazyHTML.attribute("data-kind") |> Enum.sort()

  describe "Links & files" do
    test "the title tap opens on All with the segment strip", %{conn: conn} do
      w = shared_world(conn)
      tap_title(w.view)

      assert lv_assigns(w.view).space_sheet == {:links, :all}

      assert has_element?(
               w.view,
               "#space-sheet [role='tablist'][data-role='space-sheet-segments']"
             )

      tabs =
        w.view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#space-sheet [role='tab']")

      assert LazyHTML.attribute(tabs, "data-seg") == ~w(all canvas file site video space)

      assert has_element?(
               w.view,
               "#space-sheet [role='tab'][data-seg='all'][aria-selected='true']"
             )

      assert has_element?(
               w.view,
               "#space-sheet [role='tab'][data-seg='file'][aria-selected='false']"
             )

      # All groups every kind, under its section label, in the prototype's order.
      groups =
        w.view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#space-sheet [data-page='links'] section")
        |> LazyHTML.attribute("data-group")

      assert groups == ~w(canvas file site video)
      assert render(w.view) =~ "Hosted sites"
      assert row_kinds(w.view) == ~w(canvas file site video video)
    end

    test "each segment lists its one type", %{conn: conn} do
      w = shared_world(conn)
      tap_title(w.view)

      seg(w.view, "canvas")
      assert lv_assigns(w.view).space_sheet == {:links, :canvas}
      assert row_kinds(w.view) == ["canvas"]
      refute render(w.view) =~ "Hosted sites"

      seg(w.view, "file")
      assert row_kinds(w.view) == ["file"]

      assert has_element?(
               w.view,
               "#space-sheet a[href='/chat/attachments/#{w.pdf.id}']",
               "sheet-spec.pdf"
             )

      seg(w.view, "site")
      assert row_kinds(w.view) == ["site"]
      assert has_element?(w.view, "#space-sheet a[href='https://example.org/docs/sheet']")

      seg(w.view, "video")
      assert row_kinds(w.view) == ["video", "video"]
      assert has_element?(w.view, "#space-sheet a[href='/chat/attachments/#{w.video.id}']")

      assert has_element?(
               w.view,
               "#space-sheet a[href='https://www.youtube.com/watch?v=sheetdemo']"
             )

      # The Space segment still reaches every earlier row.
      seg(w.view, "space")
      assert lv_assigns(w.view).space_sheet == :space

      for role <- ~w(search canvases members threads pinned settings) do
        assert has_element?(w.view, "#space-sheet button[data-role='space-sheet-#{role}']"),
               "space-sheet-#{role} missing from the Space segment"
      end
    end

    test "file and link rows are plain external links with no phx-click; canvas rows open the canvas",
         %{conn: conn} do
      w = shared_world(conn)
      tap_title(w.view)

      anchors = w.view |> rows() |> Enum.filter(&(LazyHTML.tag(&1) == ["a"]))
      assert length(anchors) == 4

      for a <- anchors do
        assert LazyHTML.attribute(a, "phx-click") == []
        assert LazyHTML.attribute(a, "target") == ["_blank"]
        assert LazyHTML.attribute(a, "rel") == ["noopener noreferrer"]
      end

      w.view
      |> element(
        "#space-sheet button[data-role='space-sheet-link-row'][data-canvas-id='#{w.canvas.id}']"
      )
      |> render_click()

      assert lv_assigns(w.view).space_sheet == nil
      assert lv_assigns(w.view).active_canvas.id == w.canvas.id
    end

    test "an empty space says so on every Links segment", %{conn: conn} do
      user = user!("links-empty")
      channel = space!("channel")
      seat_user(channel, user)
      {view, _html} = open_as(conn, user, channel)
      tap_title(view)

      for key <- ~w(all canvas file site video) do
        seg(view, key)

        assert has_element?(
                 view,
                 "[data-role='space-sheet-links-empty']",
                 "Nothing shared here yet."
               )

        assert rows(view) |> Enum.to_list() == []
      end
    end

    test "loaded lazily: nothing on mount, once on open, dropped on close", %{conn: conn} do
      w = shared_world(conn)
      assert lv_assigns(w.view).space_sheet_links == nil
      assert lv_assigns(w.view).space_sheet_files == nil

      tap_title(w.view)
      assert length(lv_assigns(w.view).space_sheet_links) == 2
      assert length(lv_assigns(w.view).space_sheet_files) == 2

      render_click(w.view, "close_space_sheet", %{})
      assert lv_assigns(w.view).space_sheet_links == nil
    end
  end

  # ── stage 5: a jump from the sheet scrolls to the message ──────────────
  #
  # Review case 7008 at 4168c11dc: a Search result, a Pinned row and a
  # Threads row each closed the sheet and set the highlight (or expanded the
  # thread) but never scrolled, so the hit stayed off screen. These tests
  # assert the scroll EVENT, which is what was missing; the highlight
  # assertions earlier in this file held wherever the message was.

  defp search_and_open(view, query, message_id) do
    open_sheet(view)
    go_page(view, "search")

    view
    |> form("#space-sheet-search-form", %{"search" => %{"query" => query}})
    |> render_change()

    view
    |> element(
      "#space-sheet [data-role='space-sheet-search-result'][data-message-id='#{message_id}']"
    )
    |> render_click()
  end

  defp fill!(space, participant, n) do
    for i <- 1..n, do: post!(space, participant, "filler message number #{i}")
  end

  describe "jumping scrolls" do
    test "an in-window search result pushes chat:scroll-to-message for it", %{conn: conn} do
      user = user!("jump-search")
      channel = space!("channel")
      p = seat_user(channel, user)
      hit = post!(channel, p, "the wombat estimate is in")
      fill!(channel, p, 10)
      {view, _html} = open_as(conn, user, channel)
      assert MapSet.member?(lv_assigns(view).rendered_message_ids, hit.id)

      search_and_open(view, "wombat", hit.id)

      assert_push_event(view, "chat:scroll-to-message", %{id: hit_id})
      assert hit_id == hit.id
      assert lv_assigns(view).highlighted_message_id == hit.id
      assert lv_assigns(view).space_sheet == nil
    end

    test "a pinned row pushes chat:scroll-to-message for its message", %{conn: conn} do
      user = user!("jump-pin")
      channel = space!("channel")
      p = seat_user(channel, user)
      pinned = post!(channel, p, "pinned for the jump")
      fill!(channel, p, 10)
      Repo.insert!(%Pin{space_id: channel.id, message_id: pinned.id, pinned_by: p.id})
      {view, _html} = open_as(conn, user, channel)

      open_sheet(view)
      go_page(view, "pinned")

      view
      |> element(
        "[data-role='space-sheet-pin'][data-message-id='#{pinned.id}'] [data-role='space-sheet-pin-open']"
      )
      |> render_click()

      assert_push_event(view, "chat:scroll-to-message", %{id: pinned_id})
      assert pinned_id == pinned.id
      assert lv_assigns(view).highlighted_message_id == pinned.id
    end

    test "a threads row scrolls to the parent and expands it; tapping again never collapses it",
         %{conn: conn} do
      user = user!("jump-thread")
      channel = space!("channel")
      p = seat_user(channel, user)
      parent = post!(channel, p, "the thread parent for the jump")
      {:ok, thread} = Chat.create_thread(channel.id, %{parent_message_id: parent.id})

      {:ok, _} =
        Chat.post_message(%{
          space_id: channel.id,
          thread_id: thread.id,
          participant_id: p.id,
          content_type: "text",
          content: "a reply"
        })

      fill!(channel, p, 10)
      {view, _html} = open_as(conn, user, channel)

      for _round <- 1..2 do
        open_sheet(view)
        go_page(view, "threads")

        view
        |> element("[data-role='space-sheet-thread'][data-message-id='#{parent.id}']")
        |> render_click()

        assert_push_event(view, "chat:scroll-to-message", %{id: parent_id})
        assert parent_id == parent.id
        assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
        # No composer focus: it would cancel the smooth scroll (measured) and
        # raise the phone keyboard.
        refute_push_event(view, "focus_inline_thread_compose", %{message_id: _})
      end
    end

    test "a search hit outside the loaded window anchors the window on it", %{conn: conn} do
      user = user!("jump-far")
      channel = space!("channel")
      p = seat_user(channel, user)
      hit = post!(channel, p, "the capybara figure from last month")
      fill!(channel, p, 60)
      {view, _html} = open_as(conn, user, channel)
      # Positive control: the hit is NOT in the loaded window.
      refute MapSet.member?(lv_assigns(view).rendered_message_ids, hit.id)

      search_and_open(view, "capybara", hit.id)

      assert_patch(view, "/chat/#{channel.slug}?message=#{hit.id}")
      assert MapSet.member?(lv_assigns(view).rendered_message_ids, hit.id)
      assert_push_event(view, "chat:scroll-to-message", %{id: hit_id})
      assert hit_id == hit.id
      assert lv_assigns(view).highlighted_message_id == hit.id
    end

    test "a thread whose parent is outside the window anchors on it and opens the thread",
         %{conn: conn} do
      user = user!("jump-far-thread")
      channel = space!("channel")
      p = seat_user(channel, user)
      parent = post!(channel, p, "an old thread parent")
      {:ok, thread} = Chat.create_thread(channel.id, %{parent_message_id: parent.id})

      {:ok, _} =
        Chat.post_message(%{
          space_id: channel.id,
          thread_id: thread.id,
          participant_id: p.id,
          content_type: "text",
          content: "an old reply"
        })

      fill!(channel, p, 60)
      {view, _html} = open_as(conn, user, channel)
      refute MapSet.member?(lv_assigns(view).rendered_message_ids, parent.id)

      open_sheet(view)
      go_page(view, "threads")

      view
      |> element("[data-role='space-sheet-thread'][data-message-id='#{parent.id}']")
      |> render_click()

      assert_patch(view, "/chat/#{channel.slug}?message=#{parent.id}")
      assert_push_event(view, "chat:scroll-to-message", %{id: parent_id})
      assert parent_id == parent.id
      # The expand rides a message to self, handled after the re-entry.
      _ = render(view)
      assert MapSet.member?(lv_assigns(view).expanded_threads, parent.id)
    end
  end

  test "space entry includes only the active readable canvas highlight", %{conn: conn} do
    w = shared_world(conn)
    render_click(w.view, "canvas_open_mobile", %{"canvas-id" => w.canvas.id})
    assert lv_assigns(w.view).active_canvas.id == w.canvas.id
    open_sheet(w.view)
    w.view |> element(@row_canvases) |> render_click()

    assert_redirect(
      w.view,
      "/files?highlight=#{w.canvas.id}&space=#{w.canvas.space_id}&type=canvas"
    )
  end
end
