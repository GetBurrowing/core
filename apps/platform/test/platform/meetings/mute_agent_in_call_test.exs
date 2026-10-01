defmodule Platform.Meetings.MuteAgentInCallTest do
  @moduledoc """
  Task 01a0f842 stage 5, canvas 01a0f846-cfb1 —
  `Meetings.mute_agent_in_call/4`. NET-NEW: no agent mute control existed
  anywhere on main before this stage.

  Mirrors `RemoveAgentFromCallTest`'s fixtures and `Req.Test` stub pattern
  exactly, since `mute_agent_in_call/4` reuses `remove_agent_from_call/3`'s
  own row-resolution and identity-resolution helpers verbatim — this module
  does not re-derive every row-resolution edge case `RemoveAgentFromCallTest`
  already pins (same code path), only the pieces that are genuinely new:
  the two-request `ListParticipants` + `MutePublishedTrack` wire sequence,
  the `muted_at` write/clear (never `left_at`), and that authorization is
  re-checked independently of which direction (`muted?`) is asked for.

  `async: false`: the LiveKit config and the injected Req client are
  application env.
  """
  use Platform.DataCase, async: false

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

  # ── LiveKit stub ──────────────────────────────────────────────────────────

  defp stub_livekit(response_fn) do
    {:ok, _} = Application.ensure_all_started(:req)
    test_pid = self()
    Application.put_env(:platform, :livekit_req_client, Req.new(plug: {Req.Test, :livekit_test}))

    Req.Test.stub(:livekit_test, fn conn ->
      send(test_pid, {:livekit_request, conn.request_path})
      response_fn.(conn)
    end)

    on_exit(&Platform.LivekitStubPlug.restore_default_req_client/0)
  end

  # Happy-path stub: ListParticipants reports ONE audio track for whatever
  # identity is asked about, MutePublishedTrack always succeeds.
  defp ok_stub do
    stub_livekit(fn conn ->
      case conn.request_path do
        "/twirp/livekit.RoomService/ListParticipants" ->
          Req.Test.json(conn, %{
            "participants" => [
              %{"identity" => "agent:any", "tracks" => [%{"sid" => "TR_1", "type" => "AUDIO"}]}
            ]
          })

        "/twirp/livekit.RoomService/MutePublishedTrack" ->
          Req.Test.json(conn, %{})
      end
    end)
  end

  # A stub that reports the EXACT identity the test cares about, so the
  # MutePublishedTrack body can be asserted precisely.
  defp ok_stub_for(identity, track_sid \\ "TR_1") do
    test_pid = self()

    stub_livekit(fn conn ->
      case conn.request_path do
        "/twirp/livekit.RoomService/ListParticipants" ->
          Req.Test.json(conn, %{
            "participants" => [
              %{"identity" => identity, "tracks" => [%{"sid" => track_sid, "type" => "AUDIO"}]}
            ]
          })

        "/twirp/livekit.RoomService/MutePublishedTrack" ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:mute_body, Jason.decode!(raw)})
          Req.Test.json(conn, %{})
      end
    end)
  end

  # Filtered to the two calls `mute_agent_in_call/4` itself makes — same
  # selective-receive reasoning as `RemoveAgentFromCallTest`'s own
  # `remove_requests/1`: a fixture helper in the SAME test (`active_room!`,
  # via `Meetings.activate_room/1`) can fire an unrelated `CreateRoom`
  # against the stub, and an unfiltered counter would count that noise as
  # if this function had made a request it never made.
  defp requests(acc \\ 0) do
    receive do
      {:livekit_request, "/twirp/livekit.RoomService/ListParticipants"} -> requests(acc + 1)
      {:livekit_request, "/twirp/livekit.RoomService/MutePublishedTrack"} -> requests(acc + 1)
    after
      0 -> acc
    end
  end

  # ── Fixtures (mirrors RemoveAgentFromCallTest) ───────────────────────────

  defp user!(label) do
    n = System.unique_integer([:positive])

    user =
      Repo.insert!(%User{
        email: "mute-agent-#{label}-#{n}@example.com",
        name: "Mute Agent #{label} #{n}",
        oidc_sub: "oidc-mute-agent-#{label}-#{n}"
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
        name: "Mute Agent Space #{n}",
        slug: "mute-agent-space-#{n}",
        kind: "channel"
      })

    space
  end

  defp meeting!(space) do
    n = System.unique_integer([:positive])

    project =
      Repo.insert!(
        Project.changeset(%Project{}, %{
          name: "Mute Agent Project #{n}",
          slug: "mute-agent-project-#{n}",
          org_id: Platform.TenancyFixtures.fabrikam_org_id()
        })
      )

    meeting_id = Platform.Types.UUIDv7.generate()

    {:ok, meeting} =
      %Meeting{id: meeting_id}
      |> Meeting.changeset(%{
        project_id: project.id,
        chat_space_id: space.id,
        slug: "mute-agent-meeting-#{n}",
        name: "Mute Agent Kickoff #{n}",
        livekit_room_name: "meeting-#{meeting_id}"
      })
      |> Repo.insert()

    meeting
  end

  defp roster_agent!(space) do
    n = System.unique_integer([:positive])

    agent =
      Repo.insert!(%Agent{
        slug: "mutable-agent-#{n}",
        name: "Mutable Agent #{n}",
        status: "active"
      })

    {:ok, _entry} = Chat.add_space_agent(space.id, agent.id, role: "member")

    owner = user!("runtime-owner")

    {:ok, runtime} =
      Federation.register_runtime(owner.id, %{
        runtime_id: "mute-rt-#{System.unique_integer([:positive])}"
      })

    {:ok, activated, _raw_token} = Federation.activate_runtime(runtime)
    {:ok, agent} = Federation.link_agent(activated, agent)
    {:ok, _entry} = Chat.ensure_space_agent(space.id, agent.id, role: "member")

    %{agent: agent, runtime: Federation.get_runtime(activated.id)}
  end

  defp chat_user!(space, user, display_name) do
    {:ok, participant} =
      Chat.add_participant(space.id, %{
        participant_type: "user",
        participant_id: user.id,
        joined_at: DateTime.utc_now(),
        display_name: display_name
      })

    participant
  end

  defp set_host!(%Meeting{} = meeting, host_participant_id) do
    meeting
    |> Ecto.Changeset.change(host_participant_id: host_participant_id)
    |> Repo.update!()
  end

  defp active_room!(space) do
    {:ok, room} = Meetings.ensure_room(space.id)
    {:ok, room} = Meetings.activate_room(room)
    room
  end

  defp arrived_agent_row!(room, agent) do
    {:ok, row} =
      Meetings.participant_joined(room, %{
        display_name: agent.name,
        agent_id: agent.id,
        metadata: %{"identity" => "agent:#{agent.slug}"}
      })

    row
  end

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
    %{agent: agent, runtime: runtime} = roster_agent!(space)
    host_user = user!("host")
    host = chat_user!(space, host_user, "Hana Host")
    meeting = space |> meeting!() |> set_host!(host.id)
    room = active_room!(space)
    row = arrived_agent_row!(room, agent)

    %{
      space: space,
      agent: agent,
      runtime: runtime,
      host: host,
      host_user: host_user,
      meeting: meeting,
      room: room,
      row: row
    }
  end

  # ── The happy path ────────────────────────────────────────────────────────

  describe "host mutes/unmutes an agent" do
    test "mutes: ListParticipants then MutePublishedTrack(muted: true), row's muted_at set",
         %{agent: agent, host: host, meeting: meeting, room: room, row: row} do
      ok_stub_for("agent:#{agent.slug}")

      assert {:ok, %{participant: updated, outcome: :muted}} =
               Meetings.mute_agent_in_call(meeting, row.id, host, true)

      assert requests() == 2
      assert_received {:mute_body, body}

      # The MEETING's own room, not `meeting.livekit_room_name` — the
      # wire call addresses `room.livekit_room_name` (the resolved
      # `Platform.Meetings.Room`), the exact same field
      # `remove_agent_from_call/3` wires against.
      assert body == %{
               "room" => room.livekit_room_name,
               "identity" => "agent:#{agent.slug}",
               "track_sid" => "TR_1",
               "muted" => true
             }

      assert updated.id == row.id
      assert %DateTime{} = reload(row).muted_at
      # Muting never removes the row — the whole point of the distinction
      # from `remove_agent_from_call/3`.
      assert reload(row).left_at == nil
    end

    test "unmutes: muted: false in the wire body, row's muted_at cleared",
         %{agent: agent, host: host, meeting: meeting, row: row} do
      row
      |> MeetingParticipant.changeset(%{muted_at: DateTime.utc_now()})
      |> Repo.update!()

      ok_stub_for("agent:#{agent.slug}")

      assert {:ok, %{outcome: :unmuted}} =
               Meetings.mute_agent_in_call(meeting, row.id, host, false)

      assert_received {:mute_body, %{"muted" => false}}
      assert reload(row).muted_at == nil
    end
  end

  # ── Authorization (re-checked independently of direction) ───────────────

  describe "authorization" do
    test "a non-host user is :forbidden, 0 requests, muted_at untouched",
         %{space: space, meeting: meeting, row: row} do
      ok_stub()
      other = chat_user!(space, user!("other"), "Otto Other")

      assert Meetings.mute_agent_in_call(meeting, row.id, other, true) == {:error, :forbidden}
      assert requests() == 0
      assert reload(row).muted_at == nil
    end

    test "a nil actor (a guest) is :forbidden for either direction",
         %{meeting: meeting, row: row} do
      ok_stub()

      assert Meetings.mute_agent_in_call(meeting, row.id, nil, true) == {:error, :forbidden}
      assert Meetings.mute_agent_in_call(meeting, row.id, nil, false) == {:error, :forbidden}
      assert requests() == 0
    end
  end

  # ── Row resolution (same helpers remove_agent_from_call/3 uses) ─────────

  describe "row resolution" do
    test "a human row is :not_an_agent, 0 requests",
         %{host: host, host_user: host_user, meeting: meeting, room: room} do
      ok_stub()

      {:ok, human} =
        Meetings.participant_joined(room, %{
          display_name: "Hana Host",
          user_id: host_user.id,
          metadata: %{"identity" => "user:#{host_user.id}"}
        })

      assert Meetings.mute_agent_in_call(meeting, human.id, host, true) ==
               {:error, :not_an_agent}

      assert requests() == 0
    end

    test "another room's agent row is :not_found, 0 requests",
         %{host: host, meeting: meeting} do
      ok_stub()
      other_space = space!()
      %{agent: other_agent} = roster_agent!(other_space)
      other_row = other_space |> active_room!() |> arrived_agent_row!(other_agent)

      assert Meetings.mute_agent_in_call(meeting, other_row.id, host, true) ==
               {:error, :not_found}

      assert requests() == 0
    end

    test "an already-removed row is :not_found, 0 requests",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      row |> MeetingParticipant.changeset(%{left_at: DateTime.utc_now()}) |> Repo.update!()

      assert Meetings.mute_agent_in_call(meeting, row.id, host, true) == {:error, :not_found}
      assert requests() == 0
    end
  end

  # ── LiveKit failures ─────────────────────────────────────────────────────

  describe "LiveKit failures" do
    test "no published audio track is :no_audio_track, row's muted_at untouched",
         %{agent: agent, host: host, meeting: meeting, row: row} do
      stub_livekit(fn conn ->
        assert conn.request_path == "/twirp/livekit.RoomService/ListParticipants"

        Req.Test.json(conn, %{
          "participants" => [%{"identity" => "agent:#{agent.slug}", "tracks" => []}]
        })
      end)

      assert Meetings.mute_agent_in_call(meeting, row.id, host, true) ==
               {:error, :no_audio_track}

      assert requests() == 1
      assert reload(row).muted_at == nil
    end

    test "unconfigured LiveKit is :livekit_not_configured, 0 requests",
         %{host: host, meeting: meeting, row: row} do
      ok_stub()
      Application.put_env(:platform, :livekit, [])

      assert Meetings.mute_agent_in_call(meeting, row.id, host, true) ==
               {:error, :livekit_not_configured}

      assert requests() == 0
      assert reload(row).muted_at == nil
    end

    test "a transport error on MutePublishedTrack leaves muted_at untouched",
         %{agent: agent, host: host, meeting: meeting, row: row} do
      stub_livekit(fn conn ->
        case conn.request_path do
          "/twirp/livekit.RoomService/ListParticipants" ->
            Req.Test.json(conn, %{
              "participants" => [
                %{
                  "identity" => "agent:#{agent.slug}",
                  "tracks" => [%{"sid" => "TR_1", "type" => "AUDIO"}]
                }
              ]
            })

          "/twirp/livekit.RoomService/MutePublishedTrack" ->
            Req.Test.transport_error(conn, :econnrefused)
        end
      end)

      assert {:error, %Req.TransportError{reason: :econnrefused}} =
               Meetings.mute_agent_in_call(meeting, row.id, host, true)

      assert reload(row).muted_at == nil
    end
  end
end
