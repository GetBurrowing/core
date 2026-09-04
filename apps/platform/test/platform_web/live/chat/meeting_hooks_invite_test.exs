defmodule PlatformWeb.ChatLive.MeetingHooksInviteTest do
  @moduledoc """
  Task 01a0691d stage 2 — the People tab's invite section on the QUICKMEET.

  `/meetings` had an invite control; the in-chat quickmeet had none. Both
  surfaces now render one `CallShell.invite_section/1` from one
  server-built row model (`MeetingLive.invite_rows/2`), and the quickmeet's
  `quickmeet_invite_agent` event runs the same body `/meetings` runs
  (`MeetingHooks.invite_agent_into_call/3`).

  These tests drive a REAL mounted `ChatLive` through `meeting_join` and
  then through the invite event, rather than calling hook functions
  directly: the surface-level claim is that the row is drawn and the click
  lands, and no unit test of the hook module can see either.

  Every dispatch assertion here is on a topic a real runtime client has
  joined, so a `refute_push` refutes on a channel that a wrongly admitted
  invite WOULD reach.
  """

  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3, refute_push: 3]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Repo

  setup %{conn: conn} do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    user = user!("viewer")

    {:ok, space} =
      Chat.create_space(%{
        name: "Quickmeet Invite #{System.unique_integer([:positive])}",
        slug: "quickmeet-invite-#{System.unique_integer([:positive])}",
        kind: "channel"
      })

    conn = init_test_session(conn, current_user_id: user.id)
    {:ok, conn: conn, user: user, space: space}
  end

  # ── Fixtures (mirroring meeting_live_agent_invite_test.exs) ─────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    Repo.insert!(%User{
      email: "quickmeet-invite-#{label}-#{n}@example.com",
      name: "Quickmeet Invite #{label} #{n}",
      oidc_sub: "oidc-quickmeet-invite-#{label}-#{n}"
    })
  end

  # A roster agent with a linked, activated runtime — the shape
  # `invite_agent/3` requires before it will dispatch anything.
  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "quickmeet-agent-#{n}",
        name: "Quickmeet Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    {:ok, runtime} =
      Federation.register_runtime(user!("runtime-owner").id, %{
        runtime_id: "quickmeet-rt-#{n}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  defp declaring_roster_agent!(space, features) do
    %{runtime: runtime} = ctx = roster_agent!(space)

    {:ok, _runtime} =
      Federation.update_metadata(runtime, %{
        "client_info" => %{"product" => "openclaw", "version" => "0.1.0", "features" => features}
      })

    %{ctx | runtime: Federation.get_runtime(runtime.id)}
  end

  defp join_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    channel
  end

  defp agent_participant_rows(space_id, agent_id) do
    space_id
    |> Meetings.active_participants_for_space()
    |> Enum.filter(&(&1.agent_id == agent_id))
  end

  defp assigns(view), do: :sys.get_state(view.pid).socket.assigns

  # Join the quickmeet from the chat surface. The rail exists only once
  # `:in_meeting` is true, so it is asserted here as the direction control
  # for every "the rail shows X" claim below.
  defp join(conn, space) do
    {:ok, view, _html} = live(conn, ~p"/chat/#{space.slug}")
    render_click(view, "meeting_join", %{})

    assert assigns(view).in_meeting
    assert has_element?(view, "#quickmeet-call-rail")

    view
  end

  defp row_selector(agent_id, state) do
    ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-row"][data-invite-state="#{state}"][data-agent-id="#{agent_id}"])
  end

  defp button_selector(agent_id) do
    ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-button"][data-agent-id="#{agent_id}"])
  end

  defp row_html(view, agent_id) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(~s([data-role="meeting-agent-invite-row"][data-agent-id="#{agent_id}"]))
    |> LazyHTML.to_html()
  end

  describe "the invite section on the quickmeet rail" do
    test "is present with the heading even when the space has no agents",
         %{conn: conn, space: space} do
      assert Chat.list_space_agents(space.id) == []

      view = join(conn, space)

      assert has_element?(view, ~s(#quickmeet-call-rail [data-role="meeting-agent-invite"]))

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-empty"]),
               "No agents in this space yet"
             )

      refute has_element?(view, ~s([data-role="meeting-agent-invite-row"]))
    end

    test "lists the text-only agent disabled, with its reason and no button",
         %{conn: conn, space: space} do
      %{agent: text_only} = declaring_roster_agent!(space, [])

      view = join(conn, space)

      assert has_element?(view, row_selector(text_only.id, "incapable"))

      assert has_element?(
               view,
               row_selector(text_only.id, "incapable") <>
                 ~s( [data-role="meeting-agent-invite-reason"]),
               "No voice runtime online"
             )

      refute has_element?(view, button_selector(text_only.id))

      row = row_html(view, text_only.id)
      refute row =~ "<button"
      refute row =~ "phx-click"
    end

    test "inviting a capable agent with a connected worker dispatches meeting_join and the row turns pending",
         %{conn: conn, space: space} do
      %{agent: voice} = ctx = declaring_roster_agent!(space, ["meeting_voice"])
      _channel = join_runtime_client!(ctx)

      view = join(conn, space)

      assert has_element?(view, row_selector(voice.id, "invitable"))
      assert has_element?(view, button_selector(voice.id))
      refute has_element?(view, button_selector(voice.id) <> ~s([data-invite-pending="true"]))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => voice.id})

      assert_push "meeting_join", _payload, 500
      assert Process.alive?(view.pid)
      assert html =~ "waiting for it to join"
      assert [_row] = agent_participant_rows(space.id, voice.id)

      # The row is the truth surface: the same click that dispatched is
      # what re-labels it, without waiting for a presence round-trip.
      assert has_element?(view, row_selector(voice.id, "pending"))
      assert has_element?(view, button_selector(voice.id) <> ~s([data-invite-pending="true"]))

      assert has_element?(
               view,
               ~s(#quickmeet-call-rail [data-role="meeting-agent-invite-pending"]),
               "Waiting"
             )
    end

    # The refusal is the server's, not the markup's: the id is forged
    # straight at the handler, and the agent's runtime has a real client on
    # its channel so the refutation is on a topic a wrongly admitted invite
    # WOULD reach.
    test "the incapable id is refused server-side: nothing dispatched, no row written",
         %{conn: conn, space: space} do
      %{agent: text_only} = ctx = declaring_roster_agent!(space, [])
      _channel = join_runtime_client!(ctx)

      view = join(conn, space)
      refute has_element?(view, button_selector(text_only.id))

      html = render_click(view, "quickmeet_invite_agent", %{"agent-id" => text_only.id})

      refute_push "meeting_join", _payload, 200
      assert agent_participant_rows(space.id, text_only.id) == []
      assert html =~ "That agent could not be invited."
      refute html =~ "waiting for it to join"

      # Still listed, still blocked, still explained.
      assert has_element?(view, row_selector(text_only.id, "incapable"))
    end
  end
end
