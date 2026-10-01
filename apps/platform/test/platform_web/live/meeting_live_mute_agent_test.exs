defmodule PlatformWeb.MeetingLiveMuteAgentTest do
  @moduledoc """
  Task 01a0f842 stage 5, canvas 01a0f846-cfb1 — the host's mute button on
  the meeting page, wired to `Meetings.mute_agent_in_call/4`. NET-NEW: no
  agent mute control existed anywhere on main before this stage.

  Mirrors `MeetingLiveRemoveAgentTest`'s structure and `Req.Test` stub
  pattern: the load-bearing assertion is the LiveKit `MutePublishedTrack`
  REQUEST COUNT, not the button — a hidden button proves nothing about a
  forged event.

  `async: false`: the LiveKit config and the injected Req client are
  application env, and the Req.Test stub is in SHARED mode because the
  LiveKit call runs in the `start_async/3` task, not the test process.
  """
  use PlatformWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

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

  @mute_path "/twirp/livekit.RoomService/MutePublishedTrack"
  @list_path "/twirp/livekit.RoomService/ListParticipants"

  # ── LiveKit stub ─────────────────────────────────────────────────────────

  # Every LiveKit call the page makes (CreateRoom, …) goes through this
  # stub. `ListParticipants` always answers with ONE audio track for
  # `identity`, so `MutePublishedTrack` is reachable; only
  # `MutePublishedTrack` is counted and scripted by `mute_fn`.
  defp stub_livekit(identity, mute_fn) do
    {:ok, _} = Application.ensure_all_started(:req)
    test_pid = self()
    Req.Test.set_req_test_to_shared()
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :livekit_test}))

    Req.Test.stub(:livekit_test, fn conn ->
      case conn.request_path do
        @mute_path ->
          send(test_pid, {:livekit_mute, self()})
          mute_fn.(conn)

        @list_path ->
          Req.Test.json(conn, %{
            "participants" => [
              %{"identity" => identity, "tracks" => [%{"sid" => "TR_1", "type" => "AUDIO"}]}
            ]
          })

        _ ->
          Req.Test.json(conn, %{})
      end
    end)

    on_exit(fn ->
      Req.Test.set_req_test_to_private()
      Platform.LivekitStubPlug.restore_default_req_client()
    end)
  end

  defp ok_stub(identity), do: stub_livekit(identity, fn conn -> Req.Test.json(conn, %{}) end)

  defp mute_requests(acc \\ 0) do
    receive do
      {:livekit_mute, _pid} -> mute_requests(acc + 1)
    after
      0 -> acc
    end
  end

  # ── Fixtures (mirrors MeetingLiveRemoveAgentTest) ────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mute-agent-lv-#{label}-#{n}@example.com",
        name: "Mute Agent LV #{label} #{n}",
        oidc_sub: "oidc-mute-agent-lv-#{label}-#{n}"
      })

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
        name: "Mute Agent LV Space #{n}",
        slug: "mute-agent-lv-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Mute Agent LV Project #{n}",
          slug: "mute-agent-lv-project-#{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "mute-agent-lv-meeting-#{n}",
        name: "Mute Agent LV Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "mutable-lv-agent-#{n}",
        name: "Mutable LV Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "mute-lv-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
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

  defp mute_button_selector(row),
    do: ~s([data-role="meeting-agent-mute"][phx-value-participant-id="#{row.id}"])

  defp reload(row), do: Repo.get!(MeetingParticipant, row.id)

  setup do
    original = Application.get_env(:platform, :livekit, [])

    Application.put_env(:platform, :livekit,
      api_key: "test-livekit-key",
      api_secret: "test-livekit-secret-0123456789abcdef",
      url: "wss://livekit.test"
    )

    on_exit(fn -> Application.put_env(:platform, :livekit, original) end)

    space = space!()
    %{agent: agent} = roster_agent!(space)
    host_user = user!("host")
    host = chat_user!(space, host_user)

    meeting =
      space
      |> meeting!()
      |> Ecto.Changeset.change(host_participant_id: host.id)
      |> Repo.update!()

    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)

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
      host_user: host_user,
      host: host,
      meeting: meeting,
      room: room,
      human_row: human_row,
      agent_row: agent_row
    }
  end

  describe "the host" do
    test "sees a Mute button on agent rows only; one click mutes, a second unmutes",
         %{
           conn: conn,
           agent: agent,
           host_user: host_user,
           meeting: meeting,
           human_row: human_row,
           agent_row: agent_row
         } do
      ok_stub("agent:#{agent.slug}")

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      assert has_element?(view, agent_row_selector(agent_row))
      assert has_element?(view, mute_button_selector(agent_row))

      # Never on a human row, the host's own included.
      refute has_element?(view, mute_button_selector(human_row))

      render_click(view, "toggle_agent_mute", %{"participant-id" => agent_row.id})
      render_async(view)

      assert mute_requests() == 1
      assert %DateTime{} = reload(agent_row).muted_at

      assert has_element?(
               view,
               mute_button_selector(agent_row) <>
                 ~s([data-mute-state="muted"][aria-pressed="true"])
             )

      assert has_element?(
               view,
               agent_row_selector(agent_row) <> ~s( [data-role="meeting-agent-muted"])
             )

      # A second click unmutes — same event, the OPPOSITE direction.
      render_click(view, "toggle_agent_mute", %{"participant-id" => agent_row.id})
      render_async(view)

      assert mute_requests() == 1
      assert reload(agent_row).muted_at == nil

      assert has_element?(
               view,
               mute_button_selector(agent_row) <>
                 ~s([data-mute-state="unmuted"][aria-pressed="false"])
             )
    end

    test "the row reads Muting… with its button disabled while LiveKit answers",
         %{conn: conn, agent: agent, host_user: host_user, meeting: meeting, agent_row: agent_row} do
      test_pid = self()

      stub_livekit("agent:#{agent.slug}", fn conn ->
        send(test_pid, {:mute_waiting, self()})

        receive do
          :release -> Req.Test.json(conn, %{})
        after
          5_000 -> Req.Test.json(conn, %{})
        end
      end)

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "toggle_agent_mute", %{"participant-id" => agent_row.id})
      assert_receive {:mute_waiting, stub_pid}, 2_000

      assert has_element?(
               view,
               agent_row_selector(agent_row) <> ~s( [data-role="meeting-agent-muting"])
             )

      assert has_element?(
               view,
               mute_button_selector(agent_row) <> "[disabled]"
             )

      send(stub_pid, :release)
      render_async(view)

      assert %DateTime{} = reload(agent_row).muted_at
    end

    test "a LiveKit failure shows the shared feedback line with Try again, button stays enabled",
         %{conn: conn, agent: agent, host_user: host_user, meeting: meeting, agent_row: agent_row} do
      stub_livekit("agent:#{agent.slug}", fn conn ->
        conn |> Plug.Conn.put_status(500) |> Req.Test.json(%{"code" => "internal"})
      end)

      {:ok, view, _html} = conn |> login(host_user) |> live(~p"/meetings/#{meeting.slug}")

      render_click(view, "toggle_agent_mute", %{"participant-id" => agent_row.id})
      render_async(view)

      assert mute_requests() == 1
      assert reload(agent_row).muted_at == nil

      error_line_selector =
        agent_row_selector(agent_row) <> ~s( [data-role="meeting-agent-mute-error"])

      assert has_element?(view, error_line_selector)

      # `participant_rail/1` renders twice (desktop left rail + phone
      # People tab, per that component's own moduledoc) — both copies
      # carry the identical message, so the FIRST match is representative.
      [error_node | _] =
        view |> render() |> Floki.parse_fragment!() |> Floki.find(error_line_selector)

      assert Floki.text(error_node) =~ "Couldn't mute #{agent.name}."

      # The button reverted to idle/unmuted, not stuck disabled.
      refute has_element?(view, mute_button_selector(agent_row) <> "[disabled]")

      # Retrying re-sends the exact same event. Scoped to the desktop
      # left rail: `participant_rail/1` renders twice on this page (see
      # the Floki lookup above), and a bare selector matches both copies.
      view
      |> element(
        ~s([data-role="meeting-left-rail-agents"] [data-role="meeting-agent-mute-retry"][phx-value-participant-id="#{agent_row.id}"])
      )
      |> render_click()

      render_async(view)
      assert mute_requests() == 1
    end
  end

  describe "authorization" do
    test "a non-host's forged click makes 0 LiveKit requests and the row stays unmuted",
         %{conn: conn, agent: agent, space: space, meeting: meeting, agent_row: agent_row} do
      ok_stub("agent:#{agent.slug}")
      other_user = user!("other")
      _other = chat_user!(space, other_user)

      {:ok, view, _html} = conn |> login(other_user) |> live(~p"/meetings/#{meeting.slug}")

      refute has_element?(view, mute_button_selector(agent_row))

      render_click(view, "toggle_agent_mute", %{"participant-id" => agent_row.id})
      render_async(view)

      assert mute_requests() == 0
      assert reload(agent_row).muted_at == nil
    end
  end
end
