defmodule PlatformWeb.MeetingLiveRemoveAgentTest do
  @moduledoc """
  Task 01a0e906 stage 3 — the host's "Remove from meeting" button on the
  meeting page, wired to `Meetings.remove_agent_from_call/3` (stage 2).

  The load-bearing assertion is the LiveKit RemoveParticipant REQUEST COUNT,
  not the button: a hidden button proves nothing about a forged event. Every
  "0 requests" below sits beside the host test in this module where the same
  counter reads 1, so a stub that never ran fails here instead of reading as
  a refusal.

  The forged-event tests click with `render_click/3` directly, bypassing the
  rendered DOM, because that is exactly what a crafted websocket frame does:
  `MeetingLive` must hand the call to the context (the one authorization
  seam) and render the refusal, never trust the absence of a button.

  `async: false`: the LiveKit config and the injected Req client are
  application env, and the Req.Test stub is put in SHARED mode because the
  LiveKit call runs in the `start_async/3` task, not the test process.
  """
  use PlatformWeb.ConnCase, async: false

  import Ecto.Query, only: [from: 2]
  import Phoenix.LiveViewTest

  # Narrow import, as in `meeting_live_agent_invite_test.exs`: `connect/2` is
  # called fully qualified because `Phoenix.ConnTest` exports one too.
  import Phoenix.ChannelTest, only: [subscribe_and_join: 3, assert_push: 3, refute_push: 3]

  alias Platform.Accounts.User
  alias Platform.Agents.Agent
  alias Platform.Chat
  alias Platform.Federation
  alias Platform.Meetings
  alias Platform.Meetings.Meeting
  alias Platform.Meetings.Participant, as: MeetingParticipant
  alias Platform.Repo
  alias Platform.Tasks.Project
  alias Platform.Tenancy.OrgMembership

  @remove_path "/twirp/livekit.RoomService/RemoveParticipant"

  # ── LiveKit stub ─────────────────────────────────────────────────────────

  # Every LiveKit call the page makes (CreateRoom, ListParticipants, …) goes
  # through this stub; only RemoveParticipant is counted and scripted.
  defp stub_livekit(remove_fn) do
    {:ok, _} = Application.ensure_all_started(:req)
    test_pid = self()
    Req.Test.set_req_test_to_shared()
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :livekit_test}))

    Req.Test.stub(:livekit_test, fn conn ->
      if conn.request_path == @remove_path do
        send(test_pid, {:livekit_remove, self()})
        remove_fn.(conn)
      else
        Req.Test.json(conn, %{})
      end
    end)

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Platform.LivekitStubPlug.restore_default_req_client()
    end)
  end

  defp ok_stub, do: stub_livekit(fn conn -> Req.Test.json(conn, %{}) end)

  defp remove_requests(acc \\ 0) do
    receive do
      {:livekit_remove, _pid} -> remove_requests(acc + 1)
    after
      0 -> acc
    end
  end

  # ── Fixtures ─────────────────────────────────────────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "remove-agent-lv-#{label}-#{n}@example.com",
        name: "Remove Agent LV #{label} #{n}",
        oidc_sub: "oidc-remove-agent-lv-#{label}-#{n}"
      })

    # `@example.com` keeps the org role at `:member` — no admin bypass.
    Repo.insert!(
      OrgMembership.changeset(%OrgMembership{}, %{
        user_id: user.id,
        org_id: Platform.TenancyFixtures.fabrikam_org_id(),
        role: "member"
      })
    )

    user
  end

  defp space! do
    n = System.unique_integer([:positive])

    {:ok, space} =
      Chat.create_space(%{
        name: "Remove Agent LV Space #{n}",
        slug: "remove-agent-lv-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Remove Agent LV Project #{n}",
          slug: "remove-agent-lv-project-#{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "remove-agent-lv-meeting-#{n}",
        name: "Remove Agent LV Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "removable-lv-agent-#{n}",
        name: "Removable LV Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "remove-lv-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    # `raw_token` is kept because activation is the only moment the
    # plaintext exists; the Undo tests connect a real runtime client with it.
    %{agent: agent, runtime: Federation.get_runtime(activated.id), raw_token: raw_token}
  end

  # A connected, authenticated websocket client for the agent's runtime, on
  # the one topic `RuntimeChannel.join/3` accepts. Same shape as
  # `meeting_live_agent_invite_test.exs`: the `meeting_join` dispatch is
  # observed as a PUSH to a real client, not an in-VM subscribe.
  defp join_runtime_client!(%{runtime: runtime, raw_token: raw_token}) do
    {:ok, socket} =
      Phoenix.ChannelTest.connect(PlatformWeb.RuntimeSocket, %{
        "runtime_id" => runtime.runtime_id,
        "token" => raw_token
      })

    {:ok, _reply, channel} = subscribe_and_join(socket, "runtime:#{runtime.runtime_id}", %{})
    channel
  end

  defp chat_user!(space, user) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now(),
        display_name: user.name
      })

    participant
  end

  defp login(conn, user), do: init_test_session(conn, current_user_id: user.id)

  defp agent_row_selector(row), do: ~s(li[data-participant-id="#{row.id}"])

  defp remove_button_selector(row),
    do: ~s([data-role="meeting-agent-remove"][phx-value-participant-id="#{row.id}"])

  defp reload(row), do: Repo.get!(MeetingParticipant, row.id)

  defp open_agent_rows(space_id, agent_id) do
    Repo.all(
      from(p in MeetingParticipant,
        join: r in Platform.Meetings.Room,
        on: r.id == p.room_id,
        where: r.space_id == ^space_id and p.agent_id == ^agent_id and is_nil(p.left_at)
      )
    )
  end

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    space = space!()
    %{agent: agent} = runtime_agent = roster_agent!(space)
    host_user = user!("host")
    host = chat_user!(space, host_user)

    meeting =
      space
      |> meeting!()
      |> Ecto.Changeset.change(host_participant_id: host.id)
      |> Repo.update!()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

    # The rows the LiveKit webhook leaves behind: the host in the call, and
    # the agent that arrived.
    {:ok, human_row} =
      Meetings.participant_joined(room, %{
        display_name: host_user.name,
        user_id: host_user.id,
        metadata: %{"identity" => "user:#{host_user.id}"}
      })

    {:ok, agent_row} =
      Meetings.participant_joined(room, %{
        display_name: agent.name,
        agent_id: agent.id,
        metadata: %{"identity" => "agent:#{agent.slug}"}
      })

    %{
      space: space,
      agent: agent,
      runtime_agent: runtime_agent,
      host_user: host_user,
      host: host,
      meeting: meeting,
      room: room,
      human_row: human_row,
      agent_row: agent_row
    }
  end

  # ── The host (the positive control for every 0 below) ────────────────────

  describe "the host" do
    test "sees the button on agent rows only; one click is one request and the row is gone",
         %{
           conn: conn,
           space: space,
           agent: agent,
           host_user: host_user,
           meeting: meeting,
           human_row: human_row,
           agent_row: agent_row
         } do
      ok_stub()

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      assert has_element?(view, agent_row_selector(agent_row))
      assert has_element?(view, remove_button_selector(agent_row))

      # The human row renders (positive control) and carries no button,
      # the host's own row included.
      assert has_element?(view, agent_row_selector(human_row))
      refute has_element?(view, remove_button_selector(human_row))

      refute has_element?(
               view,
               ~s(li[data-participant-type="user"] [data-role="meeting-agent-remove"])
             )

      # A real DOM click on the desktop left rail's button (the People tab
      # renders a second copy of the roster).
      view
      |> element(~s([data-role="meeting-left-rail-agents"] ) <> remove_button_selector(agent_row))
      |> render_click()

      html = render_async(view)

      assert remove_requests() == 1
      assert reload(agent_row).left_at != nil
      assert open_agent_rows(space.id, agent.id) == []
      refute has_element?(view, agent_row_selector(agent_row))
      assert html =~ "Removed #{agent.name} from the meeting."
      refute has_element?(view, ~s([data-role="meeting-agent-remove-error"]))
    end

    test "the row reads Leaving… with its button disabled while LiveKit answers",
         %{conn: conn, host_user: host_user, meeting: meeting, agent_row: agent_row} do
      test_pid = self()

      stub_livekit(fn conn ->
        send(test_pid, {:remove_waiting, self()})

        receive do
          :release -> Req.Test.json(conn, %{})
        after
          5_000 -> Req.Test.json(conn, %{})
        end
      end)

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "remove_agent_from_call", %{"participant-id" => agent_row.id})
      assert_receive {:remove_waiting, stub_pid}, 2_000

      assert has_element?(
               view,
               agent_row_selector(agent_row) <> ~s( [data-role="meeting-agent-leaving"])
             )

      assert has_element?(view, remove_button_selector(agent_row) <> "[disabled]")

      send(stub_pid, :release)
      render_async(view)

      refute has_element?(view, agent_row_selector(agent_row))
    end

    test "targeting a human row id makes no request and flashes a refusal",
         %{conn: conn, host_user: host_user, meeting: meeting, human_row: human_row} do
      ok_stub()

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "remove_agent_from_call", %{"participant-id" => human_row.id})
      html = render_async(view)

      assert remove_requests() == 0
      assert reload(human_row).left_at == nil
      assert has_element?(view, agent_row_selector(human_row))
      assert html =~ "That participant can&#39;t be removed."
      refute has_element?(view, ~s([data-role="meeting-agent-remove-error"]))
    end

    test "a LiveKit 500 leaves the row with its failure line and the view alive",
         %{
           conn: conn,
           agent: agent,
           host_user: host_user,
           meeting: meeting,
           agent_row: agent_row
         } do
      stub_livekit(fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"code" => "internal"})
      end)

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "remove_agent_from_call", %{"participant-id" => agent_row.id})
      render_async(view)

      assert remove_requests() == 1
      assert reload(agent_row).left_at == nil

      # The LiveView survived, the row is still there, it says why, and the
      # button is tappable again.
      html = render(view)
      assert has_element?(view, agent_row_selector(agent_row))

      assert has_element?(
               view,
               agent_row_selector(agent_row) <> ~s( [data-role="meeting-agent-remove-error"])
             )

      assert html =~ "Couldn&#39;t remove #{agent.name}. Try again"
      refute has_element?(view, remove_button_selector(agent_row) <> "[disabled]")
      refute has_element?(view, ~s([data-role="meeting-agent-leaving"]))
    end

    test "a malformed payload is a no-op", %{
      conn: conn,
      host_user: host_user,
      meeting: meeting,
      agent_row: agent_row
    } do
      ok_stub()

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "remove_agent_from_call", %{})
      render_click(view, "remove_agent_from_call", %{"participant-id" => 42})
      render_async(view)

      assert remove_requests() == 0
      assert reload(agent_row).left_at == nil
      assert has_element?(view, agent_row_selector(agent_row))
    end
  end

  # ── A non-host member ────────────────────────────────────────────────────

  describe "a non-host member" do
    test "sees no button, and a forged event makes no request and flashes a refusal",
         %{conn: conn, space: space, meeting: meeting, agent_row: agent_row} do
      ok_stub()

      member = user!("member")
      _membership = chat_user!(space, member)

      {:ok, view, _html} = conn |> login(member) |> live(~p"/meetings/#{meeting.slug}")

      # The agent row renders (positive control) with no button on it.
      assert has_element?(view, agent_row_selector(agent_row))
      refute has_element?(view, ~s([data-role="meeting-agent-remove"]))

      render_click(view, "remove_agent_from_call", %{"participant-id" => agent_row.id})
      html = render_async(view)

      assert remove_requests() == 0
      assert reload(agent_row).left_at == nil
      assert has_element?(view, agent_row_selector(agent_row))
      assert html =~ "Only the host can remove agents from this meeting."
      refute has_element?(view, ~s([data-role="meeting-agent-remove-error"]))
    end
  end

  # ── The Undo toast (task 01a0e906 stage 4) ───────────────────────────────
  #
  # The re-invite is observed two ways, both at the far end: a fresh ACTIVE
  # meeting_participants row, and a `meeting_join` PUSHED to a real runtime
  # client. Every "0" in the non-host tests sits beside the host's Undo in
  # this same describe, where the same two counters read 1.

  describe "the Undo toast" do
    defp remove_as_host!(conn, host_user, meeting, agent_row) do
      ok_stub()
      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")
      render_click(view, "remove_agent_from_call", %{"participant-id" => agent_row.id})
      render_async(view)
      assert reload(agent_row).left_at != nil
      view
    end

    defp undo_state(view), do: :sys.get_state(view.pid).socket.assigns.agent_removal_undo

    test "a removal shows the toast naming the agent, with an Undo button",
         %{conn: conn, agent: agent, host_user: host_user, meeting: meeting, agent_row: agent_row} do
      view = remove_as_host!(conn, host_user, meeting, agent_row)

      assert has_element?(view, ~s([data-role="meeting-agent-removed-toast"][role="status"]))

      assert view
             |> element(~s([data-role="meeting-agent-removed-toast"]))
             |> render() =~ "Removed #{agent.name} from the meeting."

      assert has_element?(
               view,
               ~s([data-role="meeting-agent-removed-undo"][phx-click="undo_remove_agent"])
             )

      assert %{agent_id: agent_id} = undo_state(view)
      assert agent_id == agent.id
    end

    test "the host's Undo writes a fresh active row and dispatches meeting_join",
         %{
           conn: conn,
           space: space,
           agent: agent,
           runtime_agent: runtime_agent,
           host_user: host_user,
           meeting: meeting,
           agent_row: agent_row
         } do
      view = remove_as_host!(conn, host_user, meeting, agent_row)
      assert open_agent_rows(space.id, agent.id) == []

      channel = join_runtime_client!(runtime_agent)

      # The payload is ignored; a stray agent id in it must not be used.
      view
      |> element(~s([data-role="meeting-agent-removed-undo"]))
      |> render_click(%{"agent-id" => Ecto.UUID.generate()})

      assert [_fresh] = open_agent_rows(space.id, agent.id)

      assert_push("meeting_join", payload, 1_000)
      assert payload.agent_identity == "agent:#{agent.slug}"
      assert payload.room_name == Meetings.get_active_room(space.id).livekit_room_name

      refute has_element?(view, ~s([data-role="meeting-agent-removed-toast"]))
      assert undo_state(view) == nil
      assert is_pid(channel.channel_pid)
    end

    test "only the matching timer ref hides the toast; a stale ref leaves it showing",
         %{conn: conn, host_user: host_user, meeting: meeting, agent_row: agent_row} do
      view = remove_as_host!(conn, host_user, meeting, agent_row)
      %{ref: ref} = undo_state(view)

      send(view.pid, {:clear_agent_removal_undo, make_ref()})
      assert has_element?(view, ~s([data-role="meeting-agent-removed-toast"]))

      send(view.pid, {:clear_agent_removal_undo, ref})
      refute has_element?(view, ~s([data-role="meeting-agent-removed-toast"]))
      assert undo_state(view) == nil
    end

    test "a non-host forging undo_remove_agent writes no row and dispatches nothing",
         %{
           conn: conn,
           space: space,
           agent: agent,
           runtime_agent: runtime_agent,
           host_user: host_user,
           meeting: meeting,
           agent_row: agent_row
         } do
      host_view = remove_as_host!(conn, host_user, meeting, agent_row)
      assert %{} = undo_state(host_view)

      member = user!("undo-member")
      _membership = chat_user!(space, member)

      {:ok, view, _html} =
        build_conn() |> login(member) |> live(~p"/meetings/#{meeting.slug}")

      channel = join_runtime_client!(runtime_agent)

      # (a) The plain forge: this socket never removed anything, so it has
      # no toast state to act on.
      render_click(view, "undo_remove_agent", %{"agent-id" => agent.id})

      # (b) The host re-check itself: plant the toast state on the
      # non-host's socket, as if it had been set, and forge again. Only
      # `host?/2` stands between this push and a re-invite.
      :sys.replace_state(view.pid, fn state ->
        undo = %{agent_id: agent.id, agent_name: agent.name, ref: make_ref()}
        socket = state.socket
        %{state | socket: %{socket | assigns: Map.put(socket.assigns, :agent_removal_undo, undo)}}
      end)

      render_click(view, "undo_remove_agent", %{})

      assert open_agent_rows(space.id, agent.id) == []
      refute_push("meeting_join", _payload, 300)
      assert is_pid(channel.channel_pid)
    end
  end
end
